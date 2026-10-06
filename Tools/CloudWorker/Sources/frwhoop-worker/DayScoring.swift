import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Loads one day's scoring inputs from the projected stream tables and runs
/// the exact `AnalyticsEngine.analyzeDay` the app runs — same math, hosted.
struct DayScorer {
    let db: PostgresClient

    struct Claim {
        let userId: String
        let deviceId: String
        let day: String             // YYYY-MM-DD
        let timezoneId: String
        let inputRevision: Int64
        let leaseToken: String
        let runId: String
        let measurementRevision: Int64
    }

    struct ScoringError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Pure, DB-free helpers (unit-tested in DayScoringAdapterTests)

    /// Local calendar-day start ("yyyy-MM-dd" → local midnight in `tz`).
    /// The parse happens IN the day's own timezone, so on a DST spring-forward
    /// day the local midnight is 05:00 UTC (not a fixed 00:00 UTC / +86400).
    static func dayStartUnix(_ day: String, tz: TimeZone) -> Int? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return nil }
        return Int(d.timeIntervalSince1970)
    }

    /// Start of the NEXT local calendar day after `dayStart` in `tz`.
    /// Calendar arithmetic (never `dayStart + 86400`): on a 23 h DST day the
    /// next local midnight is 23 h later, on a 25 h day it is 25 h later.
    static func nextDayStartUnix(after dayStart: Int, tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let d = Date(timeIntervalSince1970: TimeInterval(dayStart))
        guard let next = cal.date(byAdding: .day, value: 1, to: d) else {
            return dayStart + 86_400
        }
        return Int(next.timeIntervalSince1970)
    }

    /// The snapshot's `dataThrough` (unix seconds), derived from the OBSERVED
    /// inputs, never from a fixed window endpoint.
    ///   - `maxObservedTs` is the maximum timestamp actually present among the
    ///     loaded streams for the day/night window (nil when no stream loaded
    ///     anything).
    ///   - `fallbackTs` is the start of the claimed day — used when a window has
    ///     no samples at all ("we know nothing newer than the day start").
    ///   - The result is clamped to `now` so clock-skewed device timestamps can
    ///     never emit a FUTURE `dataThrough`, and floored at `fallbackTs`.
    static func dataThroughUnix(maxObservedTs: Int?, fallbackTs: Int, now: Int) -> Int {
        let observed = maxObservedTs ?? fallbackTs
        return min(max(observed, fallbackTs), now)
    }

    /// Typed snapshot status — exactly one of `available` / `partial` / `no_data`
    /// (the DB enforces `coalesce(p_payload->>'status','') in
    /// ('available','partial','no_data')` in `publish_scoring_snapshot_v2`).
    ///
    /// Documented rule:
    ///   - `no_data`   — fewer than `minHRSamples` (200) HR samples in the night
    ///                  window: nothing can be staged or scored. (Same hard gate
    ///                  the previous implementation used, now also the typed rule.)
    ///   - `partial`   — HR is present but the score is incomplete: (a) no sleep
    ///                  session was detected, or (b) a staging-required stream
    ///                  (RR or gravity) is empty. The night has physiology but
    ///                  the sleep/HRV result cannot be complete.
    ///   - `available` — HR present AND ≥ 1 sleep session detected AND RR and
    ///                  gravity both non-empty.
    ///
    /// resp / skinTemp / spo2 / steps feed SECONDARY metrics (resp rate, skin
    /// temp, SpO2, step/calorie totals) and are device-dependent (a WHOOP 5/MG
    /// banks no SpO2, a WHOOP 4.0 no band sleep state); their absence never
    /// downgrades the core sleep/HRV status. Their real counts are still
    /// reported in `coverage` for every stream loaded.
    static func classifyStatus(hrCount: Int, rrCount: Int, respCount: Int,
                               gravityCount: Int, detectedSessionCount: Int) -> String {
        if hrCount < DayScorer.minHRSamples { return "no_data" }
        guard detectedSessionCount > 0 else { return "partial" }
        if rrCount <= 0 || gravityCount <= 0 { return "partial" }
        return "available"
    }

    /// Minimum night-window HR samples below which a day cannot be staged at all.
    static let minHRSamples = 200

    /// Human/debug reasons behind a `partial` status (never emitted for
    /// `available`). Mirrors `classifyStatus` so the status and its reasons can
    /// never disagree.
    static func partialReasons(rrCount: Int, gravityCount: Int,
                               detectedSessionCount: Int) -> [String] {
        var reasons: [String] = []
        if detectedSessionCount <= 0 { reasons.append("no_sleep_session") }
        if rrCount <= 0 { reasons.append("rr_empty") }
        if gravityCount <= 0 { reasons.append("gravity_empty") }
        return reasons
    }

    /// Mirror of the SQL midnight-closure boundary (G2-attestation item 3). The
    /// authoritative boundary math lives in `scoring_enqueue_due_day_closure` using
    /// Postgres `AT TIME ZONE` (pg_timezone_names DST rules, identical to
    /// `scoring_day_segments`); this pure helper pins the worker-side predicate
    /// that mirrors it: a day is due for closure when its LOCAL midnight (computed
    /// with `dayStartUnix`, calendar-correct across DST) plus the settle window has
    /// passed.
    static func closureDue(yesterdayLocalMidnightUnix: Int, nowUnix: Int, settleSeconds: Int) -> Bool {
        nowUnix >= yesterdayLocalMidnightUnix + settleSeconds
    }

    /// The skin-temp scale family that wrote a device's rows — never hardcoded.
    /// Mirrors the app exactly: `DeviceFamily.forRegistryDevice(model:brand:)
    /// ?? .whoop5` (Strand/Data/IntelligenceEngine.swift:3159). `deviceFamily`
    /// is `public.devices.device_family` (e.g. "WHOOP 4.0", "WHOOP 5.0 / MG",
    /// "WHOOP 5B00384569", "WHOOPSITO", "WHOOP", ""). The worker has no `brand`
    /// column, so `source_kind == "whoop"` is the only positive WHOOP-brand
    /// signal; any other source kind carries no brand and defers to
    /// `forRegistryModel` (nil brand → model label alone decides, which yields
    /// `.whoop4` only for "4.0"/"WHOOP 4.0" and `.whoop5` for everything else).
    /// A missing device row (both nil) coalesces to `.whoop5`, matching the app.
    static func skinTempFamilyForDevice(deviceFamily: String?, sourceKind: String?) -> DeviceFamily {
        let brand: String? = (sourceKind == "whoop") ? "WHOOP" : nil
        return DeviceFamily.forRegistryDevice(model: deviceFamily, brand: brand) ?? .whoop5
    }

    /// The main (longest in-bed span) sleep session for a day; ties keep the
    /// FIRST such session so the pick is deterministic across runs.
    static func mainSleepSession(_ sessions: [SleepSession]) -> SleepSession? {
        var best: SleepSession?
        for s in sessions {
            if best == nil || (s.end - s.start) > (best!.end - best!.start) {
                best = s
            }
        }
        return best
    }

    /// Summed minutes per stage for a session's stage segments. The nightly
    /// light/deep/REM totals are accepted by `internal.engine_ingest_scored`'s
    /// sleep-night upsert and computed identically on the phone and the worker.
    static func stageMinutes(_ stages: [StageSegment]) -> (light: Double, deep: Double, rem: Double) {
        var light = 0.0, deep = 0.0, rem = 0.0
        for seg in stages {
            let mins = Double(seg.end - seg.start) / 60.0
            switch seg.stage {
            case "light": light += mins
            case "deep": deep += mins
            case "rem": rem += mins
            default: break  // "wake" minutes are not a stage total
            }
        }
        return (light, deep, rem)
    }

    /// Compact spec-4.4 daily attestation the v2 scoring pass writes AFTER a
    /// successful snapshot publish (G2-attestation item 2). Only what the pass
    /// actually observed is populated; everything it cannot know is an explicit
    /// `not_measured` marker — nothing is fabricated, and the record never
    /// claims a continuity verdict. The `status`/`statusReasons`/`coverage`/
    /// `dataThrough` come verbatim from the published snapshot; projection
    /// completion is factual because the publish succeeded before this is built.
    static func dayAttestation(claim: Claim, snapshot: [String: Any],
                               resultRevision: Int64, algorithmVersion: String,
                               asOf: Int = Int(Date().timeIntervalSince1970)) -> [String: Any] {
        let tz = TimeZone(identifier: claim.timezoneId) ?? TimeZone(identifier: "UTC")!
        let dayStart = dayStartUnix(claim.day, tz: tz) ?? 0
        let dayEnd = nextDayStartUnix(after: dayStart, tz: tz)
        let coverage = snapshot["coverage"] as? [String: Any] ?? [:]
        let status = snapshot["status"] as? String ?? "unknown"
        let statusReasons = snapshot["statusReasons"] as? [String] ?? []
        let dataThrough = snapshot["dataThrough"] as? String ?? ""
        return [
            "identity": [
                "user_id": claim.userId,
                "device_id": claim.deviceId,
                "day": claim.day,
                "timezone_id": claim.timezoneId,
                "calendar_policy_version": "job-calendar-1",
                "day_start_unix": dayStart,
                "day_end_unix": dayEnd,
                "input_revision": claim.inputRevision,
                "as_of_unix": asOf,
                "algorithm_version": algorithmVersion,
            ],
            "status": status,
            "statusReasons": statusReasons,
            "dataThrough": dataThrough,
            "acquisition": [
                // Per-stream received counts + the night window bounds are what the
                // pass measured. Durations/gaps/rejected/duplicate/off-body/unknown
                // are NOT derivable from the counts the pass loads, so they stay
                // explicit not_measured markers.
                "streams": coverage,
                "coverage_durations": "not_measured",
                "rejected": "not_measured",
                "duplicates": "not_measured",
                "missing_intervals": "not_measured",
                "largest_gap_s": "not_measured",
                "off_body_s": "not_measured",
                "unknown_s": "not_measured",
            ],
            "handoff": [
                "phone_watermarks": "not_measured",
                "durably_accepted_ids": "not_measured",
                "worker_backlog": "not_measured",
            ],
            "archive": [
                "manifest_refs": "not_measured",
                "hash_verification": "not_measured",
                "last_archived_event": "not_measured",
            ],
            "projection": [
                "input_revision": claim.inputRevision,
                "completed": true,
                "snapshot_result_revision": resultRevision,
                "algorithm_version": algorithmVersion,
            ],
            "context": [
                "wear": "not_measured",
                "placement": "not_measured",
                "source_arbitration": "not_measured",
            ],
        ]
    }

    // MARK: - SpO₂ strap estimate

    /// The snapshot `daily` keys for the strap's own SpO₂ estimate: the app's gated nightly mean over the
    /// readings that fall inside the detected sleep (`AnalyticsEngine.nightlySpo2CandidateMean`, so the
    /// phone and the server cannot disagree), and how many readings it rests on. Empty when no in-band
    /// reading lies inside a session.
    ///
    /// Always under its own keys, never `spo2_pct`: the strap reports a percentage-like byte that
    /// independent checks do not agree on, so it is a labelled estimate, not a calibrated blood-oxygen value.
    static func spo2EstimateKeys(sessions: [SleepSession], readings: [V18AuxSample]) -> [String: Any] {
        guard let night = AnalyticsEngine.nightlySpo2CandidateMean(sessions, aux: readings) else { return [:] }
        return ["spo2_candidate_pct": night.mean, "spo2_candidate_samples": night.samples]
    }

    // MARK: - R-R transport selection + intraday HRV

    /// Transports that can be scored on their own. A strap writes the SAME heartbeats through several of
    /// them and the typed table keeps every copy: WHOOP 5/MG strap history (5) and live BLE (7); WHOOP 4.0
    /// type-47 history (8), type-40 live (9) and standard BLE (10).
    private static let scorableTransports: Set<RRSourceChannel> =
        [.whoop5Historical, .whoop5Standard, .whoop4Historical, .whoop4Realtime, .whoop4Standard]

    /// Keeps ONE strap transport per UTC hour, the fuller one (ties go to the lower channel number).
    ///
    /// Reading every transport sums each beat twice, so the night's beat-time is ~2x the wall clock and the
    /// #1118 over-count gate (`SleepStager.sessionHrvOverCounted`) withholds the night's RMSSD, which keeps
    /// the HRV baseline, and with it Charge, from ever calibrating. The app avoids this in
    /// `WhoopStore.rrIntervals` by pinning the whole window to the lowest transport present. This is the
    /// same rule per hour: the strap-history transport trails the live one by minutes to an hour until the
    /// next offload, so a whole-window pin would drop the freshest beats, which only the live transport has.
    ///
    /// Hours with no strap transport at all (Oura rings, unlabelled legacy rows) pass through untouched.
    /// In an hour that has one, unlabelled rows are dropped as copies of it, and a type-40 live (6) beat
    /// never scores alone, both as in the app.
    static func oneTransportPerHour(_ rr: [RRInterval]) -> [RRInterval] {
        var counts: [Int: [RRSourceChannel: Int]] = [:]
        for beat in rr {
            guard let ch = beat.srcChannel, scorableTransports.contains(ch) || ch == .whoop5Realtime else { continue }
            counts[beat.ts / 3_600, default: [:]][ch, default: 0] += 1
        }
        let keep: [Int: RRSourceChannel?] = counts.mapValues { byChannel in
            byChannel.filter { scorableTransports.contains($0.key) }
                .max { ($0.value, -$0.key.rawValue) < ($1.value, -$1.key.rawValue) }?.key
        }
        return rr.filter { beat in
            guard let pick = keep[beat.ts / 3_600] else { return true }
            return pick != nil && beat.srcChannel == pick
        }
    }

    /// Width of one intraday HRV slot, in seconds. The worker re-scores a day within minutes of new beats
    /// arriving, so a slot is filled in as soon as its data is uploaded.
    static let hrvSlotSeconds = 900

    /// Clean beats a slot needs to publish: about a minute. `HRVAnalyzer.minBeats` (20) alone would let a
    /// slot still filling, or one that is nearly all dropout, publish an RMSSD built from seconds of data.
    static let hrvSlotMinCleanBeats = 60

    /// One RMSSD per `hrvSlotSeconds` of `[from, to)`: `[slotStartUnix, rmssdMs, cleanBeats]`, oldest first.
    /// A slot with too little data, too much noise, or more beat-time than wall clock (a duplicated feed)
    /// is left out rather than published as a number nobody can trust.
    ///
    /// RMSSD is the same gap-aware statistic as the nightly value, with the spot reading's noise gate
    /// (`defaultSpotMaxRejectedFraction`). It is a short-window reading taken whenever the wearer happens
    /// to be, not a resting baseline: wrist R-R is much noisier awake than asleep (posture, motion, talking),
    /// so it must not feed Charge or the nightly baseline, and `cleanBeats` is there so a reader can weigh it.
    static func hrvSlots(rr: [RRInterval], from: Int, to: Int) -> [[Any]] {
        var bySlot: [Int: [RRInterval]] = [:]
        for beat in rr where beat.ts >= from && beat.ts < to {
            bySlot[beat.ts / hrvSlotSeconds, default: []].append(beat)
        }
        return bySlot.keys.sorted().compactMap { slot -> [Any]? in
            let beats = bySlot[slot] ?? []
            let ms = beats.map { Double($0.rrMs) }
            guard HRVAnalyzer.rrCoverage(tsSec: beats.map(\.ts), rrMs: ms) <= HRVAnalyzer.coveragePlausibleCeiling else { return nil }
            let r = HRVAnalyzer.analyze(rawRR: ms, maxRejectedFraction: HRVAnalyzer.defaultSpotMaxRejectedFraction)
            guard let rmssd = r.rmssd, r.nClean >= hrvSlotMinCleanBeats else { return nil }
            return [slot * hrvSlotSeconds, (rmssd * 10).rounded() / 10, r.nClean]
        }
    }

    /// The 15-min slot starts that actually have a PUBLISHED HRV point, from
    /// the `hrvSlots` points `[slotStartUnix, rmssdMs, cleanBeats]` (audit
    /// P3-2: the attach path must emit `contexts.hrv_slots` only where an HRV
    /// result exists — never every activity-covered slot).
    static func hrvSlotStarts(fromPoints points: [[Any]]) -> Set<Int> {
        Set(points.compactMap { $0.first as? Int })
    }

    // MARK: - Candidate (shadow/active) input assembly
    //
    // The candidate lane needs the day's inputs, but it must call the sidecar with
    // NO transaction open (see CandidateStage.swift). So the input snapshot is
    // assembled here, while the inputs are already in memory, and handed to the
    // stage after the canonical transaction has committed.

    /// The bucket width of an observation's identity. Store timestamps are whole
    /// unix seconds (WhoopProtocol/Streams.swift:89), so the bucket IS the second.
    static let observationBucketSeconds = 1

    /// One heartbeat as a candidate provider receives it.
    struct CandidateBeat {
        /// The stored interval timestamp (whole unix seconds).
        let ts: Int
        let rrMs: Int
        /// Packet order within the observation, when the row carries one.
        let seq: Int
        let ord: Int?
        let srcChannel: Int?
        /// Interval END under the "`ts` is the interval start" convention.
        let tsEndSeconds: Double
        /// Best-effort sub-second END, reconstructed by accumulating within one
        /// same-second observation bucket. INFORMATIONAL: the authoritative
        /// production path uses run-based adjacency on the whole-second `ts`, so a
        /// provider must not treat this as the store's truth.
        let tsEndReconstructedSeconds: Double

        var json: JSONValue {
            var obj: [String: JSONValue] = [
                "ts": .int(ts),
                "rr_ms": .int(rrMs),
                "seq": .int(seq),
                "ts_end_seconds": .double(tsEndSeconds),
                "ts_end_reconstructed_seconds": .double(tsEndReconstructedSeconds),
            ]
            if let ord { obj["ord"] = .int(ord) }
            if let srcChannel { obj["src_channel"] = .int(srcChannel) }
            return .object(obj)
        }
    }

    /// One heart-rate sample as the `sleep_boundary` provider receives it. The
    /// adapter accepts `[[ts, bpm], ...]` or `[{ts, bpm}, ...]`
    /// (`sleep_boundary.py:_read_samples`); the compact pair form is used here.
    struct CandidateHRSample {
        let ts: Int
        let bpm: Int
        var json: JSONValue { .array([.int(ts), .int(bpm)]) }
    }

    /// One R-R row as the `sleep_stage` provider receives it. The adapter accepts
    /// `[[ts, rr_ms, seq, ord, ts_suspect], ...]` or dicts
    /// (`sleep_stage.py:_read_rr`); the compact positional form is used here.
    struct CandidateRRRow {
        let ts: Int
        let rrMs: Int
        let seq: Int
        let ord: Int?
        let tsSuspect: Int
        var json: JSONValue {
            .array([.int(ts), .int(rrMs), .int(seq), .int(ord ?? 0), .int(tsSuspect)])
        }
    }

    /// A user sleep edit read from `public.scoring_history_inputs_v3`
    /// (`kind = 'sleep_edit'`), the same rows the phone's manual bounds come from.
    /// `payload` is the raw jsonb (`originalStart`, `originalEnd`, `start`, `end`,
    /// `isNap`, `dismissed`, optional `stages`).
    struct CandidateSleepEdit {
        let entity: String
        let revision: Int64
        let payload: JSONValue

        /// The edit's own accepted bounds, when the payload carries them.
        var start: Int? { payload.member("start")?.doubleValue.map { Int($0) } }
        var end: Int? { payload.member("end")?.doubleValue.map { Int($0) } }

        /// The `user_edit` object sent to a provider. `sleep_boundary.py:410-417`
        /// withholds `blocked_input / user_edit_present` whenever this is present,
        /// which is the intended behaviour: a user-corrected session outranks any
        /// candidate.
        var json: JSONValue {
            .object(["entity": .string(entity), "revision": .int(Int(revision)),
                     "payload": payload])
        }
    }

    /// Everything the candidate lane needs for one claimed day.
    ///
    /// Assembly is MODE-GATED (audit DD-2): the scoring lane resolves the four
    /// per-metric selections first, and the per-stream arrays below are only built
    /// for metrics whose mode is not `off`. When nothing is enabled, `assembled`
    /// is false and every array is empty, so off mode costs the selection reads and
    /// nothing else.
    struct CandidateInputs {
        let userId: String
        let deviceId: String
        let day: String
        let inputRevision: Int64
        /// The interval the candidate covers (unix seconds): the main sleep
        /// session when one was detected (that is the span the canonical nightly
        /// HRV is computed over), otherwise the claimed calendar day.
        let intervalStart: Int
        let intervalEnd: Int
        /// When this claim's snapshot was sealed. Candidate debt newer than this
        /// means new input arrived while the claim was being scored.
        let claimSealedAt: Date
        let status: String
        let canonicalAvgHrv: Double?
        let canonicalSdnn: Double?
        /// Content version of the profile row the day was scored with. Populated
        /// whenever the candidate lane is on (spec section 4 requires the inputs to
        /// identify the profile version).
        let profileVersion: String?
        /// Content version of the user's sleep edits for this day: `"none"` when
        /// the day carries no corrections, otherwise a digest of the edit rows.
        let correctionsVersion: String?
        /// The metric modes that are NOT `off` for this user (the cheap check).
        let enabledMetrics: Set<String>
        /// False when the candidate lane is off or no metric is enabled: nothing
        /// was assembled and `input(for:)` returns nil for every metric.
        let assembled: Bool
        /// Observation-identity-deduped beats, ordered by (ts, seq, ord).
        let hrvBeats: [CandidateBeat]
        /// RR rows read before dedup (diagnostics only).
        let hrvInputRows: Int
        /// True when the beats' timestamps are whole seconds only.
        let hrvTimestampResolution: String
        /// HR samples for `sleep_boundary` (empty unless that metric is enabled).
        let hrSamples: [CandidateHRSample]
        /// The same R-R rows for `sleep_stage` (empty unless enabled).
        let rrRows: [CandidateRRRow]
        /// The accepted session bounds the sleep metrics are scored over.
        let sleepWindowStart: Int?
        let sleepWindowEnd: Int?
        /// The user's sleep edits for this day, newest first (empty when none).
        let sleepEdits: [CandidateSleepEdit]
        /// `age` / `gender` for the `sleep_stage` model card, when known.
        /// `gender` is ALREADY sleepecg-encoded (see `sleepecgGender`), because the
        /// adapter's `SubjectData.gender` is `int | None` and a string raises.
        let age: Int?
        let gender: Int?

        /// Rows the provider actually receives (diagnostics).
        var inputRowCount: Int { hrvBeats.count }

        /// The `user_edit` object for a provider, or nil when the day has none.
        var userEdit: JSONValue? {
            guard let first = sleepEdits.first else { return nil }
            return .object(["edits": .array(sleepEdits.map { $0.json }),
                            "primary": first.json])
        }

        /// The accepted sleep bounds the sleep metrics are scored over.
        ///
        /// A USER-CORRECTED session outranks the detected one, so the highest-
        /// revision edit's own bounds win when it has usable ones; otherwise the
        /// detected session (or the day window) is used. Keeping this here — rather
        /// than at the DB-facing call site — is what makes the rule testable
        /// without a database.
        var effectiveSleepWindow: (start: Int, end: Int)? {
            if let newest = sleepEdits.max(by: { $0.revision < $1.revision }),
               let start = newest.start, let end = newest.end, end > start {
                return (start, end)
            }
            guard let start = sleepWindowStart, let end = sleepWindowEnd, end > start else {
                return nil
            }
            return (start, end)
        }

        /// The metrics this day has BOTH a selection and a usable payload for.
        var metrics: [String] {
            guard assembled else { return [] }
            return CandidateStage.metrics.filter { input(for: $0) != nil }
        }

        /// The metric-specific `input` object for `POST /v1/infer`, or nil when no
        /// payload can be built (the stage then skips the metric without calling).
        func input(for metric: String) -> JSONValue? {
            guard assembled, enabledMetrics.contains(metric) else { return nil }
            switch metric {
            case "hrv":
                guard !hrvBeats.isEmpty else { return nil }
                return DayScorer.hrvInput(beats: hrvBeats, windowStart: intervalStart,
                                          windowEnd: intervalEnd, inputRows: hrvInputRows,
                                          timestampResolution: hrvTimestampResolution)
            case "sleep_boundary":
                guard !hrSamples.isEmpty else { return nil }
                let window = effectiveSleepWindow ?? (intervalStart, intervalEnd)
                return DayScorer.sleepBoundaryInput(
                    hr: hrSamples, windowStart: window.start, windowEnd: window.end,
                    userEdit: userEdit)
            case "sleep_stage":
                guard !rrRows.isEmpty else { return nil }
                let window = effectiveSleepWindow ?? (intervalStart, intervalEnd)
                return DayScorer.sleepStageInput(
                    rr: rrRows, windowStart: window.start, windowEnd: window.end,
                    age: age, gender: gender, userEdit: userEdit)
            default:
                return nil
            }
        }

        /// The state used when the candidate lane is off: nothing assembled, and no
        /// metric can produce a payload.
        static func disabled(userId: String, deviceId: String, day: String,
                             inputRevision: Int64, intervalStart: Int, intervalEnd: Int,
                             claimSealedAt: Date, status: String,
                             canonicalAvgHrv: Double?, canonicalSdnn: Double?) -> CandidateInputs {
            CandidateInputs(
                userId: userId, deviceId: deviceId, day: day, inputRevision: inputRevision,
                intervalStart: intervalStart, intervalEnd: intervalEnd,
                claimSealedAt: claimSealedAt, status: status,
                canonicalAvgHrv: canonicalAvgHrv, canonicalSdnn: canonicalSdnn,
                profileVersion: nil, correctionsVersion: nil,
                enabledMetrics: [], assembled: false,
                hrvBeats: [], hrvInputRows: 0, hrvTimestampResolution: "whole_seconds",
                hrSamples: [], rrRows: [], sleepWindowStart: nil, sleepWindowEnd: nil,
                sleepEdits: [], age: nil, gender: nil)
        }
    }

    /// Deduplicate retransmitted beats by PHYSICAL OBSERVATION IDENTITY, never by
    /// RR value alone (spec section 5): the key is the 1 s bucket of `ts` plus the
    /// interval, packet sequence, in-packet order and source channel. Two genuine
    /// beats in the same second with the same interval therefore survive as two
    /// rows, while a byte-identical retransmission collapses to one. The first
    /// occurrence wins, so the order is stable.
    static func dedupByObservationIdentity(_ beats: [RRInterval]) -> [RRInterval] {
        var seen = Set<String>()
        var out: [RRInterval] = []
        out.reserveCapacity(beats.count)
        for beat in beats {
            let bucket = beat.ts / observationBucketSeconds
            let key = "\(bucket)|\(beat.rrMs)|\(beat.seq)|\(beat.ord.map(String.init) ?? "-")|"
                + "\(beat.srcChannel.map { String($0.rawValue) } ?? "-")"
            if seen.insert(key).inserted { out.append(beat) }
        }
        return out
    }

    /// Map RR rows to provider beats, ordered by (ts, seq, ord) — the original
    /// series order the gap-aware adjacency rule depends on.
    static func candidateBeats(_ beats: [RRInterval]) -> [CandidateBeat] {
        let ordered = beats.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            if a.ts != b.ts { return a.ts < b.ts }
            if a.seq != b.seq { return a.seq < b.seq }
            return (a.ord ?? Int.min) < (b.ord ?? Int.min)
        }.map { $0.element }

        // Sub-second END reconstruction: within one (bucket, channel) group, the
        // first interval ends at ts + rr, and each next interval ends where the
        // previous one did plus its own rr. Purely informational (see CandidateBeat).
        var reconstructed: [Double] = []
        reconstructed.reserveCapacity(ordered.count)
        var previousEnd: Double?
        var previousKey: String?
        for beat in ordered {
            let key = "\(beat.ts / observationBucketSeconds)|\(beat.srcChannel?.rawValue ?? -1)"
            let end: Double
            if key == previousKey, let prev = previousEnd {
                end = prev + Double(beat.rrMs) / 1000.0
            } else {
                end = Double(beat.ts) + Double(beat.rrMs) / 1000.0
            }
            reconstructed.append(end)
            previousEnd = end
            previousKey = key
        }

        return ordered.enumerated().map { index, beat in
            CandidateBeat(ts: beat.ts, rrMs: beat.rrMs, seq: beat.seq, ord: beat.ord,
                          srcChannel: beat.srcChannel?.rawValue,
                          tsEndSeconds: Double(beat.ts) + Double(beat.rrMs) / 1000.0,
                          tsEndReconstructedSeconds: reconstructed[index])
        }
    }

    /// The HRV provider's `config` block. Defaults are the SHIPPED production
    /// rules (hrv-neurokit findings section 5a/5d), so a shadow comparison is
    /// apples-to-apples with the canonical nightly value; the spec's alternative
    /// rule set is selectable by changing these values, not by changing the code.
    static func hrvConfig() -> [String: JSONValue] {
        [
            "window_sec": .int(300),                 // SleepStager.swift:3012 (tumbling)
            "min_clean_beats": .int(HRVAnalyzer.minBeats),          // 20 (HRVAnalyzer.swift:33)
            "min_pairs": .int(1),
            "min_coverage": .double(0.0),
            "splice_tolerance_s": .double(3.0),      // IntradaySeries.Tuning.spliceToleranceSeconds
            "rr_min_ms": .double(300),               // HRVAnalyzer.rrMinMs
            "rr_max_ms": .double(2000),              // HRVAnalyzer.rrMaxMs
            "malik_threshold": .double(HRVAnalyzer.ectopicThreshold),   // 0.20
            "malik_radius": .int(HRVAnalyzer.ectopicWindowRadius),      // 2
            "coverage_floor": .double(HRVAnalyzer.coveragePlausibleFloor),
            "coverage_ceiling": .double(HRVAnalyzer.coveragePlausibleCeiling),
            "beat_accuracy_tolerance_s": .double(HRVAnalyzer.beatAccuracyToleranceS),
            "beat_accuracy_min_fraction": .double(HRVAnalyzer.beatAccuracyMinFraction),
            "max_rejected_fraction": .null,          // no nightly gate in shipped code
            "aggregation": .string("mean_over_windows"),   // SleepStager.swift:2972 (not median)
            "pooling": .string("sum_sq_and_pairs"),        // spec section 5
        ]
    }

    /// The aggregation the `hrv` provider must apply. TOP-LEVEL on purpose
    /// (audit S-1): the provider's parser reads a top-level `aggregation` key, and
    /// its own default is `"window"`, which would score only the interval's FIRST
    /// 5-minute window and report that as the nightly value. The same string is
    /// mirrored into `config` for back-compat with payloads that only read config.
    static let hrvAggregation = "mean_over_windows"

    /// The exact `input` object the `hrv` provider expects (plan "Sidecar HTTP
    /// contract" + hrv-neurokit findings section 6b).
    static func hrvInput(beats: [CandidateBeat], windowStart: Int, windowEnd: Int,
                         inputRows: Int, timestampResolution: String) -> JSONValue {
        .object([
            "beats": .array(beats.map { $0.json }),
            "window": .object([
                "start_sec": .int(windowStart),
                "end_sec": .int(windowEnd),
                "inclusive": .bool(true),   // matches HRVAnalyzer.analyze(_:windowStart:windowEnd:)
            ]),
            // TOP-LEVEL, so the provider cannot fall back to its "window" default.
            "aggregation": .string(hrvAggregation),
            "config": .object(hrvConfig()),
            "timestamp_convention": .string("interval_end_seconds"),
            "timestamp_resolution": .string(timestampResolution),
            "observation_identity": .object([
                "dedup_key": .array([.string("ts_bucket_1s"), .string("rr_ms"), .string("seq"),
                                     .string("ord"), .string("src_channel")]),
                "input_rows": .int(inputRows),
                "deduped_rows": .int(beats.count),
                "bucket_seconds": .int(observationBucketSeconds),
            ]),
        ])
    }

    // MARK: - Sleep provider payloads (adapter contracts, read from the package)

    /// The `input` object for `sleep_boundary` (`hypnospy.hr-boundary.v1`).
    ///
    /// Contract mirrored from
    /// `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/providers/sleep_boundary.py`:
    ///   * `hr` — REQUIRED. `[[ts, bpm], ...]` or `[{ts, bpm}, ...]`
    ///     (`_read_samples`, lines 130-150). Empty raises `missing_hr`.
    ///   * `window` — optional `{start_utc, end_utc}`. It OVERRIDES the context
    ///     interval as the in-bed interval for this call (lines 343-353), which is
    ///     what the worker wants: the context interval is the coarse day/recompute
    ///     range, the window is the accepted session.
    ///   * `wake_ts_utc` — optional; defaults to the interval end (line 357).
    ///   * `analysis_day` — deliberately NOT sent. The provider derives the
    ///     analysis day from `wake_ts_utc` in the IANA zone and RAISES
    ///     `analysis_day_mismatch` when a supplied day disagrees (lines 359-363).
    ///     Omitting it removes a whole class of avoidable `error` results.
    ///   * `user_edit` — when present the provider withholds
    ///     `blocked_input / user_edit_present` (lines 410-417): a user-corrected
    ///     session outranks any candidate.
    static func sleepBoundaryInput(hr: [CandidateHRSample], windowStart: Int, windowEnd: Int,
                                   userEdit: JSONValue?) -> JSONValue {
        var obj: [String: JSONValue] = [
            "hr": .array(hr.map { $0.json }),
            "window": .object([
                "start_utc": .string(isoUTC(windowStart)),
                "end_utc": .string(isoUTC(windowEnd)),
            ]),
            // The wake end of the accepted session; the provider's analysis day
            // follows from it in the request's IANA timezone.
            "wake_ts_utc": .string(isoUTC(windowEnd)),
        ]
        if let userEdit { obj["user_edit"] = userEdit }
        return .object(obj)
    }

    /// The `input` object for `sleep_stage` (`sleepecg.wrn-gru-mesa.v1`).
    ///
    /// Contract mirrored from
    /// `Tools/InferenceWorker/src/frwhoop_inference/frwhoop_sleep/providers/sleep_stage.py`:
    ///   * `rr` — REQUIRED. `[[ts, rr_ms, seq, ord, ts_suspect], ...]` or dicts
    ///     (`_read_rr`, lines 95-126). Empty raises `missing_rr`; rows outside the
    ///     window raise `no_rr_in_window`.
    ///   * `window` — `{start_utc, end_utc}`; defaults to the context interval
    ///     (lines 416-426). Sent explicitly so the stage covers the accepted
    ///     session, not the coarse day range.
    ///   * `age` / `gender` — optional model-card inputs (lines 451, 509).
    ///   * `user_edit` — NOT part of this adapter's contract (it reads only
    ///     `rr`/`window`/`age`/`gender`), so it is echoed for provenance only.
    ///     The package has no stage-side suppression rule; the boundary provider is
    ///     the one that refuses to score over a user's edit.
    static func sleepStageInput(rr: [CandidateRRRow], windowStart: Int, windowEnd: Int,
                                age: Int?, gender: Int?, userEdit: JSONValue?) -> JSONValue {
        var obj: [String: JSONValue] = [
            "rr": .array(rr.map { $0.json }),
            "window": .object([
                "start_utc": .string(isoUTC(windowStart)),
                "end_utc": .string(isoUTC(windowEnd)),
            ]),
        ]
        if let age { obj["age"] = .int(age) }
        // sleepecg's `SubjectData.gender` is `int | None` (`Gender.FEMALE = 0`,
        // `Gender.MALE = 1`); a STRING here raises inside the adapter and is
        // swallowed into `withheld / insufficient_coverage`. Absent stays absent so
        // the adapter masks the column (`test_missing_age_and_gender_...`).
        if let gender { obj["gender"] = .int(gender) }
        if let userEdit { obj["user_edit"] = userEdit }
        return .object(obj)
    }

    /// The provider-facing UTC timestamp form (`2026-10-01T08:00:00Z`), matching
    /// the adapters' `parse_ts` expectations.
    static func isoUTC(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Map `profiles.sex_model` to sleepecg's integer gender.
    ///
    /// `profiles.sex_model` is TEXT restricted to `'male' | 'female' | 'nonbinary'`,
    /// while the `sleep_stage` adapter builds `sleepecg.io.sleep_readers.SubjectData`,
    /// whose `gender` field is `int | None` ("stored as an integer as defined by
    /// `Gender`", with `Gender.FEMALE = 0` and `Gender.MALE = 1`). Sending the raw
    /// string makes every staged run raise, and the adapter's per-run `except`
    /// swallows it into `skipped="provider_error"` -> the metric reports
    /// `withheld / insufficient_coverage` for EVERY user with a sex set.
    ///
    /// So: `male -> 1`, `female -> 0`, and nil for `nonbinary` / absent / unknown
    /// (sleepecg treats a missing gender as "mask the column", which is the honest
    /// answer for a sex model the reference model was not trained on).
    static func sleepecgGender(sexModel: String?) -> Int? {
        switch (sexModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "male": return 1
        case "female": return 0
        default: return nil
        }
    }

    /// Map raw HR rows to provider samples (ordered by ts).
    static func candidateHRSamples(_ hr: [HRSample]) -> [CandidateHRSample] {
        hr.sorted { $0.ts < $1.ts }.map { CandidateHRSample(ts: $0.ts, bpm: $0.bpm) }
    }

    /// Map R-R rows to provider rows (ordered by ts, seq, ord — the order the
    /// stage adapter itself re-sorts to).
    static func candidateRRRows(_ beats: [RRInterval]) -> [CandidateRRRow] {
        beats.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            if a.ts != b.ts { return a.ts < b.ts }
            if a.seq != b.seq { return a.seq < b.seq }
            return (a.ord ?? Int.min) < (b.ord ?? Int.min)
        }.map { _, beat in
            CandidateRRRow(ts: beat.ts, rrMs: beat.rrMs, seq: beat.seq, ord: beat.ord, tsSuspect: 0)
        }
    }

    /// The metrics that are NOT `off` for this user (audit DD-2's cheap check).
    /// Pure, so the gate is unit-testable without a database.
    static func enabledMetrics(from selections: [String: SelectedProvider]) -> Set<String> {
        var out = Set<String>()
        for metric in CandidateStage.metrics {
            if let selection = selections[metric], !selection.isOff { out.insert(metric) }
        }
        return out
    }

    // MARK: - ACTIVE PROMOTION PLUMBING (pure; unreachable while defaults are `off`)

    /// Replace the canonical nightly HRV with an `active`-mode provider value and
    /// record its provenance in the snapshot payload.
    ///
    /// `snapshot` is free-form jsonb (`publish_scoring_snapshot_v2` stores it
    /// verbatim), so the provenance lands there; the legacy daily row keeps its
    /// column contract and only `hrv_rmssd_ms` changes. A nil substitution returns
    /// both payloads UNCHANGED — which is what every shipped configuration does,
    /// because `physiology_provider_defaults` seeds all four metrics `off`.
    static func applyActiveHrvSubstitution(
        snapshot: [String: Any], legacy: [String: Any],
        substitution: CandidateStage.ActiveHrvSubstitution?
    ) -> (snapshot: [String: Any], legacy: [String: Any]) {
        guard let substitution else { return (snapshot, legacy) }
        var snapshot = snapshot
        var legacy = legacy
        var snapshotDaily = (snapshot["daily"] as? [String: Any]) ?? [:]
        var legacyDaily = (legacy["daily_metrics"] as? [[String: Any]])?.first ?? [:]
        snapshotDaily["hrv_rmssd_ms"] = substitution.value
        legacyDaily["hrv_rmssd_ms"] = substitution.value
        snapshotDaily["hrv_provenance"] = [
            "mode": substitution.mode,
            "provider_id": substitution.providerId,
            "provider_version": substitution.providerVersion,
            "adapter_version": substitution.adapterVersion,
            "config_version": substitution.configVersion,
            "input_sha256": substitution.inputSHA256,
            "canonical_source": "provider",
            "fallback": "legacy_hrv_analyzer",
        ] as [String: Any]
        snapshot["daily"] = snapshotDaily
        if var metrics = legacy["daily_metrics"] as? [[String: Any]], !metrics.isEmpty {
            metrics[0] = legacyDaily
            legacy["daily_metrics"] = metrics
        }
        return (snapshot, legacy)
    }

    // MARK: - Score one claimed day

    /// One scored day: both canonical payloads, the dense intraday series, and the candidate-lane inputs.
    /// `candidates` is always present; the candidate stage decides whether to use
    /// it (it is unused whenever FRWHOOP_INFERENCE_URL is unset).
    struct ScoredDay {
        let legacy: [String: Any]
        let snapshot: [String: Any]
        let series: [String: Any]?
        let candidates: CandidateInputs
    }

    // MARK: - Candidate input assembly (mode-gated)

    /// Build the candidate inputs for one scored day, assembling ONLY the streams
    /// whose metric mode is not `off` (audit DD-2).
    ///
    /// `enabled` empty means every metric is `off` (or the lane is off): the
    /// function returns `.disabled` and touches no stream, so the off path costs
    /// exactly the selection reads the caller already made.
    private func buildCandidateInputs(claim: Claim, status: String,
                                      canonicalAvgHrv: Double?, canonicalSdnn: Double?,
                                      intervalStart: Int, intervalEnd: Int,
                                      hr: [HRSample], rr: [RRInterval],
                                      sleepWindow: (start: Int, end: Int)?,
                                      claimSealedAt: Date,
                                      enabled: Set<String>) throws -> CandidateInputs {
        guard !enabled.isEmpty else {
            return .disabled(userId: claim.userId, deviceId: claim.deviceId, day: claim.day,
                             inputRevision: claim.inputRevision,
                             intervalStart: intervalStart, intervalEnd: intervalEnd,
                             claimSealedAt: claimSealedAt, status: status,
                             canonicalAvgHrv: canonicalAvgHrv, canonicalSdnn: canonicalSdnn)
        }

        // HRV needs the observation-identity dedup + ordering.
        var hrvBeats: [CandidateBeat] = []
        if enabled.contains("hrv") {
            hrvBeats = Self.candidateBeats(Self.dedupByObservationIdentity(rr))
        }
        // sleep_stage consumes the SAME R-R rows (no dedup: the adapter does its
        // own run splitting and reports ts_suspect itself).
        var rrRows: [CandidateRRRow] = []
        if enabled.contains("sleep_stage") {
            rrRows = Self.candidateRRRows(rr)
        }
        // sleep_boundary consumes HR.
        var hrSamples: [CandidateHRSample] = []
        if enabled.contains("sleep_boundary") {
            hrSamples = Self.candidateHRSamples(hr)
        }
        // Corrections are only meaningful to the sleep metrics.
        let sleepEnabled = enabled.contains("sleep_boundary") || enabled.contains("sleep_stage")
        var edits: [CandidateSleepEdit] = []
        var correctionsVersion: String? = nil
        var profileVersion: String? = nil
        var age: Int? = nil
        var gender: Int? = nil
        if sleepEnabled {
            edits = try loadSleepEdits(userId: claim.userId, deviceId: claim.deviceId,
                                       day: claim.day)
            correctionsVersion = Self.correctionsVersion(edits)
            let profile = try loadProfileMeta(userId: claim.userId)
            profileVersion = profile.version
            age = profile.age
            gender = profile.gender
        } else {
            // HRV does not consume the profile or the corrections, but the request
            // context still has to identify them (spec section 4), so record the
            // version strings without paying for the edit rows.
            //
            // `corrections_version` is DELIBERATELY the literal "none" here, even
            // when the day HAS sleep edits: corrections do not enter the HRV
            // computation at all (they only re-bound sleep sessions), so claiming a
            // digest of them would imply the HRV candidate depended on input it
            // never read. A metric that starts consuming corrections must stop
            // reporting "none" on this branch.
            profileVersion = try loadProfileMeta(userId: claim.userId).version
            correctionsVersion = "none"
        }

        // The window stored is the DETECTED one; a user edit overrides it inside
        // `CandidateInputs.effectiveSleepWindow` (one source of truth).
        return CandidateInputs(
            userId: claim.userId, deviceId: claim.deviceId, day: claim.day,
            inputRevision: claim.inputRevision,
            intervalStart: intervalStart, intervalEnd: intervalEnd,
            claimSealedAt: claimSealedAt, status: status,
            canonicalAvgHrv: canonicalAvgHrv, canonicalSdnn: canonicalSdnn,
            profileVersion: profileVersion, correctionsVersion: correctionsVersion,
            enabledMetrics: enabled, assembled: true,
            hrvBeats: hrvBeats, hrvInputRows: rr.count,
            hrvTimestampResolution: "whole_seconds",
            hrSamples: hrSamples, rrRows: rrRows,
            sleepWindowStart: sleepWindow?.start, sleepWindowEnd: sleepWindow?.end,
            sleepEdits: edits, age: age, gender: gender)
    }

    /// Content version of the day's sleep edits: `"none"` when the user has not
    /// corrected this day, otherwise a digest over the rows' identity, revision and
    /// payload. Deliberately content-derived (there is no version column on
    /// `scoring_history_inputs_v3`), so a changed edit always changes the string.
    static func correctionsVersion(_ edits: [CandidateSleepEdit]) -> String {
        guard !edits.isEmpty else { return "none" }
        var canonical: [String] = []
        for edit in edits {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = (try? encoder.encode(edit.payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
            canonical.append("\(edit.entity)|\(edit.revision)|\(payload)")
        }
        return "sleep_edit1:\(sha256Hex(Data(canonical.joined(separator: "\n").utf8)).prefix(16))"
    }

    // MARK: - Candidate plan + corrections loaders

    /// The four per-metric selections for a user.
    ///
    /// Uses `db.query` (a bare statement) rather than the store's
    /// `callFunctionForJSON`, because on the v2 path this runs INSIDE the
    /// claim/publish snapshot transaction and a nested BEGIN/COMMIT would end that
    /// transaction early.
    func loadCandidateSelections(userId: String) throws -> [String: SelectedProvider] {
        var out: [String: SelectedProvider] = [:]
        for metric in CandidateStage.metrics {
            let rows = try db.query(PhysiologyCandidateSQL.selectedProvider, [userId, metric])
            guard let text = rows.first?.values.first, !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            let mode = (obj["mode"] as? String) ?? "off"
            let providerId = (obj["provider_id"] as? String) ?? ""
            if mode == "off" || providerId.isEmpty { continue }
            out[metric] = SelectedProvider(
                providerId: providerId,
                providerVersion: (obj["provider_version"] as? String) ?? "unknown",
                configVersion: (obj["config_version"] as? String) ?? "unknown",
                mode: mode)
        }
        return out
    }

    /// The user's sleep edits for one day, newest revision first.
    ///
    /// Source: `public.scoring_history_inputs_v3` with `kind='sleep_edit'` — the
    /// same table the phone's manual bounds are written to. The latest row per
    /// `entity` wins, and a `deleted` row removes that entity's edit.
    func loadSleepEdits(userId: String, deviceId: String, day: String) throws -> [CandidateSleepEdit] {
        let rows = try db.query("""
            select distinct on (entity)
                   entity,
                   revision::text as revision,
                   deleted::text as deleted,
                   payload::text as payload
              from public.scoring_history_inputs_v3
             where user_id = $1::uuid and device_id = $2::uuid and kind = 'sleep_edit'
               and effective_day = $3::date
             order by entity, revision desc
            """, [userId, deviceId, day])
        var out: [CandidateSleepEdit] = []
        for row in rows {
            if isTrue(row["deleted"]) { continue }
            let text = row["payload"] ?? ""
            guard !text.isEmpty, let data = text.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            out.append(CandidateSleepEdit(entity: row["entity"] ?? "",
                                          revision: Int64(row["revision"] ?? "") ?? 0,
                                          payload: JSONValue(any: obj)))
        }
        // Newest revision first, so `sleepEdits.first` is the authoritative edit.
        return out.sorted { $0.revision > $1.revision }
    }

    /// The profile row's content version plus the model-card fields the
    /// `sleep_stage` adapter accepts (`age`, `gender`).
    ///
    /// There is no profile version column, so the version is derived from the
    /// fields the scorer actually uses (plus `updated_at`), which changes whenever
    /// any of them changes. `"none"` when the user has no profile row.
    func loadProfileMeta(userId: String) throws -> (version: String, age: Int?, gender: Int?) {
        let rows = try db.query("""
            select coalesce(date_of_birth::text,'') dob,
                   coalesce(sex_model,'') sex,
                   coalesce(height_cm::text,'') h,
                   coalesce(weight_kg::text,'') w,
                   coalesce(timezone,'') tz,
                   coalesce(updated_at::text,'') updated
              from public.profiles where id = $1::uuid
            """, [userId])
        guard let r = rows.first else { return ("none", nil, nil) }
        var age: Int? = nil
        let dob = r["dob"] ?? ""
        if !dob.isEmpty {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: String(dob.prefix(10))) {
                age = max(1, Int(Date().timeIntervalSince(d) / 86400.0 / 365.25))
            }
        }
        let sex = r["sex"] ?? ""
        // sleepecg-encoded (0/1/null); the raw `sex_model` string is NOT a valid
        // SubjectData.gender. The VERSION digest still uses the raw string, so a
        // change of sex_model always changes the version even when the encoded
        // value stays nil (e.g. nonbinary -> unknown).
        let gender = Self.sleepecgGender(sexModel: sex)
        let canonical = [dob, sex, r["h"] ?? "", r["w"] ?? "", r["tz"] ?? "", r["updated"] ?? ""]
            .joined(separator: "|")
        let version = "profile1:\(sha256Hex(Data(canonical.utf8)).prefix(16))"
        return (version, age, gender)
    }

    /// Score one claimed day: load inputs, compute, and return both the
    /// legacy payload (engine_publish_legacy_fenced) and the v2 snapshot
    /// payload (publish_scoring_snapshot_v2) built from the same DayResult, the
    /// candidate-lane input snapshot, and the dense intraday series.
    ///
    /// `series` is the day's dense intraday series (`IntradaySeries`) in the shape
    /// `publish_metric_series_v1` takes, computed from the streams already loaded for the snapshot. It is
    /// nil when the day has too little heart rate to score or `buildSeries` is false. It is derived data
    /// for a separate table and never part of the snapshot.
    ///
    /// `candidateLane` is false when the worker has no inference client at all
    /// (FRWHOOP_INFERENCE_URL unset). In that case NOTHING candidate-related runs:
    /// no selection read, no per-stream assembly, no digest — the canonical path is
    /// byte-identical to the pre-migration worker.
    func scoreAndBuildPayloads(claim: Claim, buildSeries: Bool = true, candidateLane: Bool = false)
        throws -> ScoredDay {
        // The claim's snapshot was sealed just before this call, so "now" is the
        // claim's input revision time for the candidate-debt freshness check.
        let claimSealedAt = Date()
        let tz = TimeZone(identifier: claim.timezoneId) ?? TimeZone(identifier: "UTC")!

        // Calendar-correct day bounds (DST-safe). dayStart/dayEnd are local
        // midnights in the claim's timezone; on a 23 h / 25 h DST day they are
        // NOT 86400 s apart. The night window keeps its fixed offsets (see
        // below) and is only a read bound — never a dataThrough endpoint.
        guard let dayStart = Self.dayStartUnix(claim.day, tz: tz) else {
            throw ScoringError(description: "invalid day \(claim.day)")
        }
        let dayEnd = Self.nextDayStartUnix(after: dayStart, tz: tz)
        // Night window offsets, stated explicitly:
        //   - nightStart is 30 h before local midnight — the same lookback the
        //     app reads (StrandAnalytics/Sources/StrandAnalytics/StreamReadCap.swift:50,
        //     `lookbackSeconds = 30 * 3_600`), so the previous evening's sleep
        //     onset is inside the window. A fixed hour offset is deliberate:
        //     it is a superset read bound, not a day boundary.
        //   - nightEnd is 54 h after local midnight — a deliberately wide
        //     superset bound so a late wake the next morning is never truncated.
        let nightStart = dayStart - 30 * 3_600
        let nightEnd = dayStart + 54 * 3_600

        // Candidate plan (audit DD-2): resolve the four per-metric modes FIRST, with
        // plain reads on the connection the caller already owns, so nothing but the
        // selection query runs when the lane is off or every metric is `off`. This
        // must NOT open its own transaction: on the v2 path this code runs inside
        // the claim/publish snapshot transaction.
        let candidateSelections: [String: SelectedProvider]
        let candidateEnabled: Set<String>
        if candidateLane {
            candidateSelections = try loadCandidateSelections(userId: claim.userId)
            candidateEnabled = Self.enabledMetrics(from: candidateSelections)
        } else {
            candidateSelections = [:]
            candidateEnabled = []
        }

        let hr = try loadHR(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let rr = try loadRR(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let resp = try loadResp(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let gravity = try loadGravity(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let skinTemp = try loadSkinTemp(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let spo2 = try loadSpo2(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let events = try loadEvents(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let spo2Estimates = try loadSpo2Estimates(userId: claim.userId, deviceId: claim.deviceId,
                                                  from: nightStart, to: nightEnd)
        // The strap's OWN band sleep_state, the same raw stream the phone's
        // primary path reads (store.sleepStateSamples, IntelligenceEngine.swift:1428).
        let sleepState = try loadSleepState(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let steps = try loadSteps(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let dayHr = try loadHR(userId: claim.userId, deviceId: claim.deviceId, from: dayStart, to: dayEnd)
        let dayGravity = try loadGravity(userId: claim.userId, deviceId: claim.deviceId, from: dayStart, to: dayEnd)
        let daySteps = try loadSteps(userId: claim.userId, deviceId: claim.deviceId, from: dayStart, to: dayEnd)

        // Wear gating, mirroring the phone call site (IntelligenceEngine.swift:1369):
        // pair WRIST_OFF/WRIST_ON events into off-wrist [start, end) intervals.
        let wristOff = AnalyticsEngine.offWristIntervals(events: events, windowEnd: nightEnd, hr: hr)

        // Device family that wrote the streams — never hardcoded `.whoop5`
        // (F11/5). A missing device row degrades to `.whoop5` like the app.
        let deviceRow = try loadDeviceRow(deviceId: claim.deviceId)
        let skinFamily = Self.skinTempFamilyForDevice(deviceFamily: deviceRow?.deviceFamily,
                                                      sourceKind: deviceRow?.sourceKind)

        let profile = try loadProfile(userId: claim.userId)
        let baselines = try loadBaselines(userId: claim.userId, deviceId: claim.deviceId, before: claim.day)

        let computedAt = isoNow()
        let now = Int(Date().timeIntervalSince1970)

        // Real coverage numbers for EVERY stream loaded (not just hr/rr), and
        // dataThrough derived from the OBSERVED inputs (never a future bound).
        var coverage = coverageJSON(hr: hr.count, rr: rr.count, resp: resp.count, gravity: gravity.count,
                                    skinTemp: skinTemp.count, spo2: spo2.count, events: events.count,
                                    sleepState: sleepState.count, steps: steps.count,
                                    dayHr: dayHr.count, daySteps: daySteps.count, dayGravity: dayGravity.count,
                                    nightWindow: (nightStart, nightEnd))
        coverage["spo2StrapEstimate"] = ["received": spo2Estimates.count]
        var observedTs: [Int] = []
        observedTs.append(contentsOf: hr.map { $0.ts })
        observedTs.append(contentsOf: rr.map { $0.ts })
        observedTs.append(contentsOf: resp.map { $0.ts })
        observedTs.append(contentsOf: gravity.map { $0.ts })
        observedTs.append(contentsOf: skinTemp.map { $0.ts })
        observedTs.append(contentsOf: spo2.map { $0.ts })
        observedTs.append(contentsOf: events.map { $0.ts })
        observedTs.append(contentsOf: sleepState.map { $0.ts })
        observedTs.append(contentsOf: steps.map { $0.ts })
        observedTs.append(contentsOf: dayHr.map { $0.ts })
        observedTs.append(contentsOf: daySteps.map { $0.ts })
        observedTs.append(contentsOf: dayGravity.map { $0.ts })
        let dataThrough = iso(Self.dataThroughUnix(maxObservedTs: observedTs.max(),
                                                   fallbackTs: dayStart, now: now))

        // Not enough samples to score honestly: publish a no_data result with
        // the same typed-status rule and real coverage, never zero-filled
        // physiology. The legacy payload keeps the identity/provenance keys
        // `internal.engine_publish_legacy_fenced` validates.
        guard hr.count >= Self.minHRSamples else {
            let status = Self.classifyStatus(hrCount: hr.count, rrCount: rr.count, respCount: resp.count,
                                             gravityCount: gravity.count, detectedSessionCount: 0)
            FileHandle.standardError.write("frwhoop-worker: day \(claim.day) device \(claim.deviceId.prefix(8)) \(status): hr=\(hr.count) rr=\(rr.count) window=[\(nightStart),\(nightEnd)) tz=\(claim.timezoneId)\n".data(using: .utf8)!)
            let daily: [String: Any] = [
                "user_id": claim.userId, "day": claim.day,
                "source_device_id": claim.deviceId,
                "algorithm_version": "frwhoop-server-1",
                "computed_at": computedAt,
                "provenance": ["scope": "hrv_sleep", "scorer": "frwhoop-scoring-service",
                               "computation_mode": "retrospective"],
            ]
            let legacy: [String: Any] = [
                "user_id": claim.userId, "device_id": claim.deviceId, "day": claim.day,
                "input_revision": claim.inputRevision, "lease_token": claim.leaseToken,
                "run_id": claim.runId, "algorithm_version": "frwhoop-server-1",
                "revision_protocol": "fenced_snapshot_v1",
                "calendar": ["policy_version": "job-calendar-1", "timezone_id": claim.timezoneId],
                "daily_metrics": [daily],
                "sleep_nights": [] as [[String: Any]],
            ]
            var snapshot: [String: Any] = [
                "sleep": [] as [[String: Any]],
                "coverage": coverage,
                "daily": daily,
                "dataThrough": dataThrough,
                "timezone": claim.timezoneId,
                "status": status,
            ]
            if status != "available" {
                snapshot["statusReasons"] = ["hr_too_sparse"]
            }
            let sparseCandidates = try buildCandidateInputs(
                claim: claim, status: status, canonicalAvgHrv: nil, canonicalSdnn: nil,
                intervalStart: dayStart, intervalEnd: dayEnd,
                hr: hr, rr: rr, sleepWindow: nil, claimSealedAt: claimSealedAt,
                enabled: candidateEnabled)
            return ScoredDay(legacy: legacy, snapshot: snapshot, series: nil,
                             candidates: sparseCandidates)
        }

        // The activity lane's epochs for this day, read once: the energy model takes them as context (it never
        // reclassifies activity) and the snapshot's activity document is built from the same rows below.
        let publishedActivity = Self.readPublishedActivityEpochs(
            db: db, userId: claim.userId, deviceId: claim.deviceId, day: claim.day,
            dayStart: dayStart, dayEnd: dayEnd)

        let result = AnalyticsEngine.analyzeDay(
            day: claim.day,
            hr: hr, rr: rr, resp: resp, gravity: gravity,
            steps: steps, dayHr: dayHr, daySteps: daySteps, dayGravity: dayGravity,
            skinTemp: skinTemp, skinTempFamily: skinFamily,
            spo2: spo2,
            profile: profile,
            baselines: baselines,
            // Offset on the CLAIMED day (DST-correct), not the offset "now".
            tzOffsetSeconds: tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(dayStart))),
            // Zone-correct half-open [start, end) day bounds for the day-bucketing
            // filters (repair-daybucket, contract C2): the legacy fixed-offset +
            // 86,400 window re-buckets the boundary hour onto the wrong day on DST
            // transition days. LocalDayWindows is the same helper the app uses, so
            // the worker and the app agree; on every non-DST day this is
            // byte-identical to the old math. Nil (unreachable for a valid claim
            // day) falls back to the old fixed-offset behavior.
            dayWindow: LocalDayWindows(timeZone: tz).window(ofDayKey: claim.day),
            wristOff: wristOff,
            bandSleepState: sleepState,
            // Stage nights with SleepStagerV2, as the app does (`PuffinExperiment.experimentalSleepV2Enabled`
            // defaults on). `analyzeDay`'s parameter defaults to V1 for pure-function callers, and this call
            // used to take that default, so a server-scored night was staged by a different recipe than the
            // same night on the phone.
            useSleepStagerV2: true,
            activityEpochs: publishedActivity.epochs,
            // A day still in progress counts resting energy only up to now; a finished day is unaffected.
            energyAsOf: now
        )

        let status = Self.classifyStatus(hrCount: hr.count, rrCount: rr.count, respCount: resp.count,
                                         gravityCount: gravity.count, detectedSessionCount: result.sleepSessions.count)
        let daily = legacyDaily(from: result, claim: claim, computedAt: computedAt)
        var snapshotDaily = self.snapshotDaily(from: result, claim: claim, computedAt: computedAt)
        // Free-form snapshot jsonb only: the legacy daily row has no slot for it.
        let slots = Self.hrvSlots(rr: rr, from: dayStart, to: dayEnd)
        if !slots.isEmpty {
            snapshotDaily["hrv_series"] = ["slot_s": Self.hrvSlotSeconds, "points": slots] as [String: Any]
        }
        snapshotDaily.merge(Self.spo2EstimateKeys(sessions: result.sleepSessions, readings: spo2Estimates)) { _, new in new }
        // Optional activity context (C10): attach the day's latest published
        // activity epochs beside hrv_series. Missing/partial activity NEVER
        // fails scoring: absent key == old behavior (spec §10 "Preserve old
        // clients and snapshots with no activity_context field").
        // hrv_slots are pinned to the slots that actually PUBLISHED an HRV
        // point (audit P3-2) — never every epoch-covered slot.
        Self.attachActivityContext(to: &snapshotDaily, db: db,
                                   userId: claim.userId, deviceId: claim.deviceId,
                                   day: claim.day,
                                   dayStart: dayStart, dayEnd: dayEnd,
                                   hrvSlotStarts: Self.hrvSlotStarts(fromPoints: slots),
                                   published: publishedActivity,
                                   sleepIntervals: result.sleepSessions.flatMap {
                                       DayStateSpan.asleep(stages: $0.stages, start: $0.start, end: $0.end)
                                   }.map { (start: $0.start, end: $0.end) })
        let nights = legacyNights(from: result, claim: claim, computedAt: computedAt)

        let legacy: [String: Any] = [
            "user_id": claim.userId, "device_id": claim.deviceId, "day": claim.day,
            "input_revision": claim.inputRevision, "lease_token": claim.leaseToken,
            "run_id": claim.runId, "algorithm_version": "frwhoop-server-1",
            "revision_protocol": "fenced_snapshot_v1",
            "calendar": ["policy_version": "job-calendar-1", "timezone_id": claim.timezoneId],
            "daily_metrics": [daily],
            "sleep_nights": nights,
        ]

        // The v2 snapshot payload's sleep entries carry the full nightly
        // shape: the snapshot contract requires id/start_at/end_at/stages,
        // and the legacy refresh that republishes server_sleep_nights also
        // reads is_nap and the minute fields from the same entries.
        var sleepSessions: [[String: Any]] = []
        for n in nights {
            var s: [String: Any] = [:]
            for k in ["id", "start_at", "end_at", "is_nap", "in_bed_min", "asleep_min",
                      "awake_min", "light_min", "deep_min", "rem_min", "efficiency",
                      "resting_hr_bpm", "hrv_rmssd_ms"] {
                if let v = n[k] { s[k] = v }
            }
            if n["is_nap"] == nil { s["is_nap"] = false }
            // The v2 snapshot contract requires `stages` as an ARRAY; the
            // legacy night rows carry the encoded string, so decode it here.
            var stages: [Any] = []
            if let str = n["stages"] as? String, let data = str.data(using: String.Encoding.utf8),
               let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                stages = arr
            }
            s["stages"] = stages
            sleepSessions.append(s)
        }
        var snapshot: [String: Any] = [
            "sleep": sleepSessions,
            "coverage": coverage,
            "daily": snapshotDaily,
            "dataThrough": dataThrough,
            "timezone": claim.timezoneId,
            "status": status,
        ]
        if status != "available" {
            snapshot["statusReasons"] = Self.partialReasons(rrCount: rr.count,
                                                            gravityCount: gravity.count,
                                                            detectedSessionCount: result.sleepSessions.count)
        }

        var series: [String: Any]?
        if buildSeries {
            // The night-window streams run past the day on both sides; the builder keeps `[dayStart, dayEnd)`.
            let built = IntradaySeries.build(IntradaySeries.Inputs(
                dayStart: dayStart, dayEnd: dayEnd, hr: dayHr, rr: rr, gravity: dayGravity, steps: daySteps,
                profile: profile, restingHR: result.daily.restingHr, energy: result.energy))
            series = IntradaySeries.payload(dayStart: dayStart, dayEnd: dayEnd, series: built)
        }

        // Candidate-lane inputs. The interval is the MAIN sleep session when one
        // was detected — that is the span the canonical nightly HRV aggregates
        // over — and the claimed calendar day otherwise. The beats are the same
        // transport-filtered rows the canonical path scored, deduplicated by
        // observation identity (spec section 5).
        let candidateInterval: (start: Int, end: Int)
        if let main = Self.mainSleepSession(result.sleepSessions), main.end > main.start {
            candidateInterval = (main.start, main.end)
        } else {
            candidateInterval = (dayStart, dayEnd)
        }
        let candidates = try buildCandidateInputs(
            claim: claim, status: status,
            canonicalAvgHrv: result.daily.avgHrv, canonicalSdnn: result.daily.avgSdnn,
            intervalStart: candidateInterval.start, intervalEnd: candidateInterval.end,
            hr: hr, rr: rr,
            sleepWindow: (candidateInterval.start, candidateInterval.end),
            claimSealedAt: claimSealedAt, enabled: candidateEnabled)
        return ScoredDay(legacy: legacy, snapshot: snapshot, series: series, candidates: candidates)
    }

    // MARK: - Payload shaping

    /// Real coverage numbers for EVERY stream loaded (not just hr/rr). Each
    /// count is the actual sample count fetched for that stream's window; the
    /// night window bounds are included so a consumer can see coverage density.
    private func coverageJSON(hr: Int, rr: Int, resp: Int, gravity: Int, skinTemp: Int, spo2: Int,
                              events: Int, sleepState: Int, steps: Int, dayHr: Int, daySteps: Int,
                              dayGravity: Int, nightWindow: (start: Int, end: Int)) -> [String: Any] {
        [
            "hr": ["received": hr],
            "rr": ["received": rr],
            "resp": ["received": resp],
            "gravity": ["received": gravity],
            "skinTemp": ["received": skinTemp],
            "spo2": ["received": spo2],
            "events": ["received": events],
            "bandSleepState": ["received": sleepState],
            "steps": ["received": steps],
            "dayHr": ["received": dayHr],
            "daySteps": ["received": daySteps],
            "dayGravity": ["received": dayGravity],
            "nightWindow": ["start": iso(nightWindow.start), "end": iso(nightWindow.end)],
        ]
    }

    private func legacyDaily(from result: AnalyticsEngine.DayResult, claim: Claim, computedAt: String) -> [String: Any] {
        let d = result.daily
        var daily: [String: Any] = [
            "user_id": claim.userId,
            "day": claim.day,
            "source_device_id": claim.deviceId,
            "algorithm_version": "frwhoop-server-1",
            "computed_at": computedAt,
        ]
        // Only keys `internal.engine_ingest_scored` reads (quoted in the F11
        // deliverable); every key below has a direct column in its daily upsert.
        if let v = d.totalSleepMin { daily["sleep_total_min"] = v }
        if let v = d.efficiency { daily["sleep_efficiency"] = v }
        if let v = d.deepMin { daily["sleep_deep_min"] = v }
        if let v = d.remMin { daily["sleep_rem_min"] = v }
        if let v = d.lightMin { daily["sleep_light_min"] = v }
        if let v = d.disturbances { daily["disturbances"] = v }
        if let v = d.restingHr { daily["resting_hr_bpm"] = v }
        if let v = d.avgHrv { daily["hrv_rmssd_ms"] = v }
        if let v = d.avgSdnn { daily["hrv_sdnn_ms"] = v }
        if let v = d.respRateBpm { daily["resp_rate_bpm"] = v }
        if let v = d.skinTempDevC { daily["skin_temp_dev_c"] = v }
        // Prefer the wear-gated nightly mean; fall back to the daily surface.
        if let v = result.nightlySkinTempC { daily["skin_temp_c"] = v }
        else if let v = d.skinTempC { daily["skin_temp_c"] = v }
        if let v = d.spo2Pct { daily["spo2_pct"] = v }
        // Day-level sleep windows from the main (longest) detected session.
        // sleep_in_bed_min / sleep_awake_min / sleep_onset_at / wake_onset_at
        // are read by internal.engine_ingest_scored's daily upsert.
        if let main = Self.mainSleepSession(result.sleepSessions) {
            let inBedMinutes = Double(main.end - main.start) / 60.0
            daily["sleep_in_bed_min"] = inBedMinutes
            daily["sleep_awake_min"] = inBedMinutes * (1.0 - main.efficiency)
            daily["sleep_onset_at"] = iso(main.start)
            daily["wake_onset_at"] = iso(main.end)
        }
        daily["confidence"] = confidenceJSON(from: result)
        daily["provenance"] = [
            "scope": "hrv_sleep", "scorer": "frwhoop-scoring-service",
            "computation_mode": "retrospective",
        ] as [String: Any]
        return daily
    }

    /// The v2 snapshot's `daily` object: the legacy contract keys PLUS the
    /// DayResult fields that have no slot in the legacy server_daily_scores
    /// contract. The snapshot's `daily` is free-form jsonb
    /// (`publish_scoring_snapshot_v2` stores the payload verbatim), so
    /// steps / exerciseCount / activeKcalEst / spo2Red / spo2Ir / recovery /
    /// strain / restScore land here, not in the legacy daily.
    private func snapshotDaily(from result: AnalyticsEngine.DayResult, claim: Claim, computedAt: String) -> [String: Any] {
        let d = result.daily
        var daily = legacyDaily(from: result, claim: claim, computedAt: computedAt)
        if let v = d.steps { daily["steps"] = v }
        if let v = d.exerciseCount { daily["exerciseCount"] = v }
        if let v = d.activeKcalEst { daily["activeKcalEst"] = v }
        if let energy = result.energy { daily["energy"] = Self.energyJSON(energy) }
        if let v = d.spo2Red { daily["spo2Red"] = v }
        if let v = d.spo2Ir { daily["spo2Ir"] = v }
        if let v = d.sleepHrOnly { daily["sleepHrOnly"] = v }
        if let v = result.recovery { daily["recovery"] = v }
        if let v = result.strain { daily["strain"] = v }
        if let v = result.restScore { daily["restScore"] = v }
        return daily
    }

    /// The snapshot's `energy` object: the day's resting / active split and what stands behind it. Compact on
    /// purpose — the per-minute timeline reaches consumers through the calories series, not the snapshot.
    /// Free-form jsonb alongside `activeKcalEst` (which equals `total_kcal`), so older readers are unaffected.
    static func energyJSON(_ e: DayEnergy) -> [String: Any] {
        func rounded(_ value: Double, _ places: Int = 2) -> Double {
            let scale = pow(10.0, Double(places))
            return (value * scale).rounded() / scale
        }
        var out: [String: Any] = [
            "model_version": e.modelVersion,
            "feature_version": e.featureVersion,
            "rmr_kcal_day": rounded(e.rmrKcalPerDay, 1),
            "rmr_source": e.rmrSource.rawValue,
            "resting_kcal": rounded(e.restingKcal),
            "resting_gap_kcal": rounded(e.restingGapKcal),
            "active_kcal": rounded(e.activeKcal),
            "workout_kcal": rounded(e.workoutKcal),
            "total_kcal": rounded(e.totalKcal),
            "sleep_min": e.sleepMinutes,
            "sedentary_min": e.sedentaryMinutes,
            "light_min": e.lightMinutes,
            "moderate_min": e.moderateMinutes,
            "high_min": e.highMinutes,
            "expected_min": e.expectedMinutes,
            "coverage_min": e.coverageMinutes,
            "gap_min": e.gapMinutes,
            "confidence": rounded(e.confidence, 3),
            "evidence_min": e.evidenceMinutes,
            "workouts": e.workouts.map { w -> [String: Any] in
                var item: [String: Any] = ["start": w.start, "end": w.end, "active_kcal": rounded(w.activeKcal),
                                           "confidence": rounded(w.confidence, 3)]
                if let met = w.averageMET { item["average_met"] = rounded(met, 2) }
                return item
            },
        ]
        if let v = e.projectedTotalKcal { out["projected_total_kcal"] = rounded(v) }
        if let v = e.averageMET { out["average_met"] = rounded(v, 3) }
        if let v = e.peakMET { out["peak_met"] = rounded(v, 2) }
        return out
    }

    /// What the activity lane published for one day: the latest result revision's epochs and the model
    /// provenance its `activity_context` document records. Read once per scoring pass and shared by the
    /// energy model (which reads the epochs as context, never recomputes them) and the document attach.
    struct PublishedActivityEpochs {
        var epochs: [ActivityEpoch] = []
        var modelVersion = ""
        var preprocessingVersion = ""
        var ontologyVersion = "v1"
        var maxEnd: Int
    }

    /// The day's latest published activity epochs, or none when the lane has not run, the tables are
    /// unreadable (the read runs under a savepoint, so a failure cannot abort the scoring transaction) or the
    /// day has no epochs. Never throws: activity context is optional input to scoring.
    static func readPublishedActivityEpochs(db: PostgresClient, userId: String, deviceId: String,
                                            day: String, dayStart: Int, dayEnd: Int) -> PublishedActivityEpochs {
        let rows: [[String: String]]
        do {
            rows = try db.isolatingFailures { try db.query("""
                with latest as (
                  select result_revision from public.activity_context_epochs
                   where user_id = $1::uuid and device_id = $2::uuid
                     and start_ts >= $3::bigint and start_ts < $4::bigint
                   order by result_revision desc
                   limit 1
                )
                select start_ts::text, end_ts::text, motion_label, posture,
                       exercise_session, sleep_state, exertion_context, wear_state,
                       confidence::text, observed_s::text, valid_s::text,
                       model_version, preprocessing_version, ontology_version,
                       fingerprint, result_revision::text
                from public.activity_context_epochs
                where user_id = $1::uuid and device_id = $2::uuid
                  and start_ts >= $3::bigint and start_ts < $4::bigint
                  and result_revision = (select result_revision from latest)
                order by start_ts
                """, [userId, deviceId, String(dayStart), String(dayEnd)]) }
        } catch {
            FileHandle.standardError.write(
                "day \(day): activity attach skipped (epoch read failed): \(error)\n".data(using: .utf8)!)
            return PublishedActivityEpochs(maxEnd: dayStart)
        }

        var out = PublishedActivityEpochs(maxEnd: dayStart)
        for r in rows {
            guard let s = Int(r["start_ts"] ?? ""), let e = Int(r["end_ts"] ?? "") else { continue }
            if let mv = r["model_version"], !mv.isEmpty { out.modelVersion = mv }
            if let pv = r["preprocessing_version"], !pv.isEmpty { out.preprocessingVersion = pv }
            if let ov = r["ontology_version"], !ov.isEmpty { out.ontologyVersion = ov }
            out.maxEnd = max(out.maxEnd, e)
            out.epochs.append(ActivityEpoch(
                startTs: s, endTs: e,
                motion: MotionLabel(rawValue: r["motion_label"] ?? "") ?? .unknown,
                posture: PostureLabel(rawValue: r["posture"] ?? "") ?? .unknown,
                exercise: ExerciseState(rawValue: r["exercise_session"] ?? "") ?? .unknown,
                sleepState: SleepStateLabel(rawValue: r["sleep_state"] ?? "") ?? .unknown,
                exertion: ExertionContext(rawValue: r["exertion_context"] ?? "") ?? .unknown,
                wear: WearState(rawValue: r["wear_state"] ?? "") ?? .unknown,
                confidence: Double(r["confidence"] ?? "") ?? 0,
                observedS: Int(r["observed_s"] ?? "") ?? 0,
                validS: Int(r["valid_s"] ?? "") ?? 0))
        }
        return out
    }

    /// Attach the C10 `activity_context` document to the snapshot `daily`
    /// object by reading the day's latest published activity epochs
    /// (`activity_context_epochs`) plus the day's sleep sessions
    /// (`public.sessions` kind='sleep') and rebuilding the compact document
    /// with the SHARED StrandAnalytics policy/join
    /// (`ActivityLane.activityDocument`) — the same fold the app and the
    /// activity lane use, so the scoring snapshot and the live lane never
    /// diverge (docs/ARCHITECTURE.md §4).
    ///
    /// Fail-safe by contract: any read/build error leaves the key ABSENT and
    /// only logs, so the scoring lane never depends on the activity lane
    /// (missing/partial activity never fails scoring). Scoring runs these reads
    /// inside its fenced transaction, where a failed statement would abort the
    /// whole transaction, so each read runs under a savepoint.
    static func attachActivityContext(to daily: inout [String: Any],
                                      db: PostgresClient,
                                      userId: String, deviceId: String,
                                      day: String,
                                      dayStart: Int, dayEnd: Int,
                                      hrvSlotStarts: Set<Int>? = nil,
                                      published: PublishedActivityEpochs? = nil,
                                      sleepIntervals: [(start: Int, end: Int)]? = nil) {
        let published = published ?? readPublishedActivityEpochs(
            db: db, userId: userId, deviceId: deviceId, day: day, dayStart: dayStart, dayEnd: dayEnd)
        let epochs = published.epochs
        guard !epochs.isEmpty else { return }  // absent key == old behavior
        let modelVersion = published.modelVersion
        let preprocessingVersion = published.preprocessingVersion
        let ontologyVersion = published.ontologyVersion
        let maxEnd = published.maxEnd

        // The epochs above come from the raw-IMU job. A stream-day job for the same day shares the table and
        // counts its own revisions, so it must not be picked here.
        let inputRevision: Int64
        do {
            let jobRows = try db.isolatingFailures { try db.query("""
                select input_revision::text as rev from public.activity_context_jobs
                 where user_id = $1::uuid and device_id = $2::uuid and day = $3::date
                   and algorithm_version <> $4
                 order by input_revision desc
                 limit 1
                """, [userId, deviceId, day, ActivityContextDays.streamsAlgorithmVersion]) }
            inputRevision = Int64(jobRows.first?["rev"] ?? "") ?? 0
        } catch {
            inputRevision = 0
        }

        // The night being scored, staged: its sleep epochs. `public.sessions` was read here once; the
        // current scoring lane no longer writes nights to it, so a caller without the night gets none.
        let asleep: [(start: Int, end: Int)] = sleepIntervals ?? []

        guard let doc = try? ActivityLane.activityDocument(
            epochs: epochs, sleepIntervals: asleep,
            dayStart: dayStart, dayEnd: dayEnd,
            inputRevision: inputRevision,
            modelVersion: modelVersion,
            preprocessingVersion: preprocessingVersion,
            dataThrough: maxEnd,
            hrvSlots: (hrvSlotStarts ?? []).sorted(),
            ontologyVersion: ontologyVersion) else {
            FileHandle.standardError.write(
                "day \(day): activity attach skipped (document build failed)\n".data(using: .utf8)!)
            return
        }
        daily["activity_context"] = doc
    }

    private func confidenceJSON(from result: AnalyticsEngine.DayResult) -> [String: Any] {
        [
            "charge": result.chargeConfidence.rawValue,
            "effort": result.effortConfidence.rawValue,
            "rest": result.restConfidence.rawValue,
        ]
    }

    private func legacyNights(from result: AnalyticsEngine.DayResult, claim: Claim, computedAt: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for session in result.sleepSessions {
            let stages = AnalyticsEngine.encodeStages(session.stages) ?? "[]"
            let inBedSeconds = Double(session.end - session.start)
            let asleepMinutes = inBedSeconds / 60.0 * session.efficiency
            let awakeMinutes = inBedSeconds / 60.0 - asleepMinutes
            let (lightMin, deepMin, remMin) = Self.stageMinutes(session.stages)
            var n: [String: Any] = [
                "user_id": claim.userId,
                "device_id": claim.deviceId,
                "period_day": claim.day,
                "start_at": iso(session.start),
                "end_at": iso(session.end),
                "is_nap": false,
                "in_bed_min": inBedSeconds / 60.0,
                "asleep_min": asleepMinutes,
                "awake_min": awakeMinutes,
                "efficiency": session.efficiency,
                "light_min": lightMin,
                "deep_min": deepMin,
                "rem_min": remMin,
                "stages": stages,
                "hypnogram": [] as [String],
                "algorithm_version": "frwhoop-server-1",
                "computed_at": computedAt,
                "id": "sleep-\(claim.deviceId)-\(session.start)",
            ]
            if let v = session.restingHR { n["resting_hr_bpm"] = v }
            if let v = session.avgHRV { n["hrv_rmssd_ms"] = v }
            out.append(n)
        }
        return out
    }

    // MARK: - Stream loaders

    private func loadHR(userId: String, deviceId: String, from: Int, to: Int) throws -> [HRSample] {
        let rows = try db.query("""
            select ts::text, bpm::text from public.noop_hr_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, [userId, deviceId, String(from), String(to)])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let bpm = Int(r["bpm"] ?? "") else { return nil }
            return HRSample(ts: Int(ts), bpm: bpm)
        }
    }

    private func loadRR(userId: String, deviceId: String, from: Int, to: Int) throws -> [RRInterval] {
        let rows = try db.query("""
            select ts::text, "rrMs"::text, seq::text, ord::text,
                   coalesce("srcChannel"::text,'') as ch
            from public.noop_rr_intervals
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
              and ("srcChannel" is null or "srcChannel" <> \(RRSourceChannel.spo2Ibi.rawValue))
              and ("tsSuspect" is null or "tsSuspect" <> 1)
            order by ts, seq
            """, [userId, deviceId, String(from), String(to)])
        let beats: [RRInterval] = rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let rrMs = Int(r["rrMs"] ?? "") else { return nil }
            let ch = Int(r["ch"] ?? "").flatMap { RRSourceChannel(rawValue: $0) }
            let seq = Int(r["seq"] ?? "") ?? 0
            let ord = Int(r["ord"] ?? "")
            return RRInterval(ts: Int(ts), rrMs: rrMs, srcChannel: ch, ord: ord, seq: seq)
        }
        return Self.oneTransportPerHour(beats)
    }

    private func loadResp(userId: String, deviceId: String, from: Int, to: Int) throws -> [RespSample] {
        let rows = try db.query("""
            select ts::text, raw::text from public.noop_resp_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, [userId, deviceId, String(from), String(to)])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let raw = Int(r["raw"] ?? "") else { return nil }
            return RespSample(ts: Int(ts), raw: raw)
        }
    }

    private func loadGravity(userId: String, deviceId: String, from: Int, to: Int) throws -> [GravitySample] {
        let rows = try db.query("""
            select ts::text, x::text, y::text, z::text, "dynAccel"::text
            from public.noop_gravity_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, [userId, deviceId, String(from), String(to)])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""),
                  let x = Double(r["x"] ?? ""), let y = Double(r["y"] ?? ""), let z = Double(r["z"] ?? "")
            else { return nil }
            let dyn = Double(r["dynAccel"] ?? "")
            return GravitySample(ts: Int(ts), x: x, y: y, z: z, dynAccel: dyn)
        }
    }

    private func loadSkinTemp(userId: String, deviceId: String, from: Int, to: Int) throws -> [SkinTempSample] {
        let rows = try db.query("""
            select ts::text, raw::text, "aux1Raw"::text, "aux2Raw"::text
            from public.noop_skin_temp_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, [userId, deviceId, String(from), String(to)])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let raw = Int(r["raw"] ?? "") else { return nil }
            let a1 = Int(r["aux1Raw"] ?? "")
            let a2 = Int(r["aux2Raw"] ?? "")
            return SkinTempSample(ts: Int(ts), raw: raw, aux1Raw: a1, aux2Raw: a2)
        }
    }

    private func loadSpo2(userId: String, deviceId: String, from: Int, to: Int) throws -> [SpO2Sample] {
        let rows = try db.query("""
            select ts::text, red::text, ir::text from public.noop_spo2_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, [userId, deviceId, String(from), String(to)])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let red = Int(r["red"] ?? ""), let ir = Int(r["ir"] ?? "") else { return nil }
            return SpO2Sample(ts: Int(ts), red: red, ir: ir)
        }
    }

    /// The strap's event log. The SpO₂ strap-estimate readings share the table (one row per second, a few
    /// hundred a night) and are read by `loadSpo2Estimates`; they are not events the scorer should see.
    private func loadEvents(userId: String, deviceId: String, from: Int, to: Int) throws -> [WhoopEvent] {
        let rows = try db.query("""
            select ts::text, kind, "payloadJSON" from public.noop_events
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
              and kind <> $5
            order by ts
            """, [userId, deviceId, String(from), String(to), Spo2StrapEstimate.eventKind])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let kind = r["kind"], !kind.isEmpty else { return nil }
            var payload: [String: ParsedValue] = [:]
            if let json = r["payloadJSON"], !json.isEmpty, let data = json.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for (k, v) in obj {
                    if let b = v as? Bool { payload[k] = .bool(b) }
                    else if let i = v as? Int { payload[k] = .int(i) }
                    else if let d = v as? Double { payload[k] = .double(d) }
                    else if let s = v as? String { payload[k] = .string(s) }
                }
            }
            return WhoopEvent(ts: Int(ts), kind: kind, payload: payload)
        }
    }

    /// The strap's OWN band sleep_state samples (ts, state) — the same raw
    /// stream the phone reads first for `bandSleepState`
    /// (store.sleepStateSamples, IntelligenceEngine.swift:1428). Absent on a
    /// WHOOP 4.0 (no band_sleep_state stream) → empty, which is honest.
    private func loadSleepState(userId: String, deviceId: String, from: Int, to: Int) throws -> [(ts: Int, state: Int)] {
        let rows = try db.query("""
            select ts::text, state::text from public.noop_sleep_state_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, [userId, deviceId, String(from), String(to)])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let state = Int(r["state"] ?? "") else { return nil }
            return (ts: Int(ts), state: state)
        }
    }

    /// The strap's SpO₂ estimate readings the phone journaled as event rows (`Spo2StrapEstimate`), as the aux
    /// samples the nightly gate reduces. A row whose payload is not an in-band whole percent is dropped.
    private func loadSpo2Estimates(userId: String, deviceId: String, from: Int, to: Int) throws -> [V18AuxSample] {
        let rows = try db.query("""
            select ts::text, "payloadJSON" from public.noop_events
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
              and kind = $5
            order by ts
            """, [userId, deviceId, String(from), String(to), Spo2StrapEstimate.eventKind])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let json = r["payloadJSON"],
                  let percent = Spo2StrapEstimate.percent(fromPayloadJSON: json) else { return nil }
            return V18AuxSample(ts: Int(ts), auxByte82: percent)
        }
    }

    private func loadSteps(userId: String, deviceId: String, from: Int, to: Int) throws -> [StepSample] {
        let rows = try db.query("""
            select ts::text, counter::text, coalesce("activityClass"::text,'') as ac
            from public.noop_step_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, [userId, deviceId, String(from), String(to)])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let counter = Int(r["counter"] ?? "") else { return nil }
            let ac = Int(r["ac"] ?? "")
            return StepSample(ts: Int(ts), counter: counter, activityClass: ac)
        }
    }

    /// The device row for `deviceId` (public.devices), or nil when the row is
    /// missing — the caller then degrades to the app's `.whoop5` coalesce.
    private func loadDeviceRow(deviceId: String) throws -> (deviceFamily: String?, sourceKind: String?)? {
        let rows = try db.query("""
            select coalesce(device_family,'') df, coalesce(source_kind,'') sk
            from public.devices where id=$1::uuid
            """, [deviceId])
        guard let r = rows.first else { return nil }
        let df = r["df"] ?? ""
        let sk = r["sk"] ?? ""
        return (df.isEmpty ? nil : df, sk.isEmpty ? nil : sk)
    }

    // MARK: - Profile + baselines

    private func loadProfile(userId: String) throws -> UserProfile {
        let rows = try db.query("""
            select coalesce(height_cm::text,'') h, coalesce(weight_kg::text,'') w,
                   coalesce(date_of_birth::text,'') dob, coalesce(sex_model,'nonbinary') sex
            from public.profiles where id=$1::uuid
            """, [userId])
        guard let r = rows.first else { return UserProfile() }
        var age = 30.0
        let dob = r["dob"] ?? ""
        if !dob.isEmpty {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: String(dob.prefix(10))) {
                age = max(1, Date().timeIntervalSince(d) / 86400.0 / 365.25)
            }
        }
        let sexRaw = r["sex"] ?? ""
        let sex = sexRaw.isEmpty ? "nonbinary" : sexRaw
        return UserProfile(
            weightKg: Double(r["w"] ?? "") ?? 70.0,
            heightCm: Double(r["h"] ?? "") ?? 170.0,
            age: age,
            sex: sex,
            measuredRmrKcalPerDay: loadMeasuredRmr(userId: userId)
        )
    }

    /// The wearer's measured resting metabolic rate (indirect calorimetry), kcal/day, from the active row of
    /// `energy_user_calibration` (`params.measured_rmr_kcal_per_day`). Optional input: nil when the table,
    /// the row or the key is missing or unreadable — the estimator then uses the population equation. The read
    /// runs under a savepoint, so it can never abort scoring's transaction, and the estimator itself ignores
    /// an implausible value (outside 800...5000 kcal/day).
    private func loadMeasuredRmr(userId: String) -> Double? {
        let rows: [[String: String]]
        do {
            rows = try db.isolatingFailures { try db.query("""
                select params->>'measured_rmr_kcal_per_day' as rmr
                from public.energy_user_calibration
                where user_id = $1::uuid and status = 'active'
                limit 1
                """, [userId]) }
        } catch {
            return nil
        }
        return Self.parseMeasuredRmr(rows.first?["rmr"])
    }

    static func parseMeasuredRmr(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespaces)),
              value.isFinite, value >= 800, value <= 5000 else { return nil }
        return value
    }

    /// Folds each metric's nightly history through the PRODUCTION baseline fold
    /// (`Baselines.foldHistory` + the app's `Baselines.metricCfg`), so the
    /// cold-start/trust policy (calibrating → provisional → trusted → stale;
    /// minNightsSeed=4, minNightsTrust=14, staleDays=14 — Baselines.swift:98-102)
    /// is honoured instead of always claiming `.trusted`.
    ///
    /// The cfg for each metric is taken from `Baselines.metricCfg` (the app's
    /// own table — Baselines.swift:205-213), never invented here:
    ///   - "hrv":         MetricCfg(minVal: 5.0, maxVal: 250.0, floorSpread: 5.0,  halfLifeB: 14.0, halfLifeS: 21.0)  (Baselines.swift:206-207)
    ///   - "resting_hr":  MetricCfg(minVal: 30.0, maxVal: 120.0, floorSpread: 2.0, halfLifeB: 14.0, halfLifeS: 21.0)  (Baselines.swift:208-209)
    ///   - "resp":        MetricCfg(minVal: 4.0, maxVal: 40.0, floorSpread: 0.5,  halfLifeB: 14.0, halfLifeS: 21.0)  (Baselines.swift:210-211)
    ///   - "skin_temp":   MetricCfg(minVal: 20.0, maxVal: 42.0, floorSpread: 0.3, halfLifeB: 14.0, halfLifeS: 21.0)  (Baselines.swift:212-213)
    ///
    /// History window: 120 days back (enough to reach the 14 valid nights a
    /// `.trusted` status needs), ascending so the fold runs oldest → newest.
    /// `dayKeys` are passed so the epoch-aware fold drops nights dated before a
    /// recalibration epoch; the worker persists no epoch (no UserDefaults), so
    /// today that variant degrades to the plain fold — the honest default.
    private func loadBaselines(userId: String, deviceId: String, before day: String) throws -> AnalyticsEngine.ProfileBaselines {
        let rows = try db.query("""
            select day::text d, hrv_rmssd_ms::text hrv, resting_hr_bpm::text rhr,
                   resp_rate_bpm::text resp, skin_temp_c::text st
            from public.server_daily_scores
            where user_id=$1::uuid and algorithm_version='frwhoop-server-1'
              and day >= $2::date - 120 and day < $2::date
            order by day asc
            """, [userId, day])
        let dayKeys = rows.map { $0["d"] ?? "" }
        func fold(_ key: String, _ col: String) throws -> BaselineState {
            guard let cfg = Baselines.metricCfg[key] else {
                throw ScoringError(description: "Baselines.metricCfg missing key \(key)")
            }
            let values = rows.map { Double($0[col] ?? "") }
            return Baselines.foldHistory(values, dayKeys: dayKeys, cfg: cfg)
        }
        return AnalyticsEngine.ProfileBaselines(
            hrv: try fold("hrv", "hrv"),
            restingHR: try fold("resting_hr", "rhr"),
            resp: try fold("resp", "resp"),
            skinTemp: try fold("skin_temp", "st")
        )
    }

    // MARK: - Time helpers

    private func iso(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func isoNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date())
    }
}
