// SleepFeatureEnrichment.swift
//
// The sleep-phenotype enrichment lane (docs/SLEEP_FEATURES_CONTRACT.md):
// one bounded request per claimed day to the sidecar's dedicated
// POST /v1/sleep-features endpoint, and the validated response attached
// verbatim under `snapshot.daily.sleep_features`.
//
// Why a dedicated endpoint and NOT the /v1/infer candidate lane (spec 7.1):
// a bundle of descriptive features is neither a scalar result nor stage
// segments, and the candidate lane has promotion semantics a descriptive
// research feature must never touch. This is an enrichment, not a canonical
// candidate: V2 stays canonical, nothing is promoted, no composite score is
// introduced.
//
// Safety rules (spec 7.4):
//   * OFF unless FRWHOOP_INFERENCE_URL is set (the same dormant default as
//     the candidate lane); an absent sidecar leaves the snapshot
//     byte-identical to today.
//   * Bounded inputs: at most 8 nights, 16 h per night, 60k HR, 60k temp,
//     120k RR beats, 20k breath intervals, 31 history days (the Python
//     contract re-validates every bound; a violation is refused 4xx and the
//     snapshot publishes WITHOUT the key, core results intact).
//   * Bounded wall clock: 3500 ms transport budget around the sidecar's own
//     3000 ms compute budget. A timeout publishes the core snapshot with
//     `sleep_features.status = "timeout"` — never an error, never a hang; the
//     ordinary next eligible scoring pass retries.
//   * One enrichment request per claimed day, inside the payload build (a
//     plain loopback JSON call, not the waveform download / model inference
//     the spec keeps out of the repeatable-read transaction).
//   * The response is structurally validated (status string, nights array,
//     JSON-safe numbers) before it is attached; a malformed response is
//     dropped, not stored.

import Foundation
import WhoopProtocol
import StrandAnalytics

/// One staged night in the enrichment request.
struct SleepFeatureNightInput {
    let nightId: String
    let start: Int
    let end: Int
    let isNap: Bool
    let userEdited: Bool
    let stages: [StageSegment]
}

/// The 31-day sleep/wake history for the regularity block.
struct SleepFeatureHistory {
    /// (day, result_revision) pairs, oldest first — the revision digest is
    /// derived from these so ANY republished day in the window invalidates
    /// the rolling SRI (spec 7.4 freshness).
    let dayRevisions: [(day: String, revision: Int64)]
    /// (day, minuteStartTs, state, valid) — UTC minute grid.
    let minutes: [(day: String, ts: Int, state: Int, valid: Bool)]
}

enum SleepFeatureEnrichment {

    static let algorithmVersion = "nara-sleep-features-1"
    static let schemaVersion = 1
    /// Transport budget around the sidecar's 3000 ms compute budget.
    static let budgetMS = 3500
    static let maxResponseBytes = 8 << 20

    // MARK: - Request assembly (pure; unit-tested)

    struct AssemblyInput {
        let userId: String
        let deviceId: String
        let day: String
        let timezoneId: String
        let inputRevision: Int64
        let intervalStart: Int
        let intervalEnd: Int
        let stageAlgorithmVersion: String
        let nights: [SleepFeatureNightInput]
        let hr: [HRSample]
        let tempCelsius: [(ts: Int, celsius: Double)]
        let beats: [RRInterval]
        let breathTrack: RespBreathTrack
        let history: SleepFeatureHistory?
    }

    /// Build the wire request object. Pure: no I/O, no clock.
    static func buildRequest(_ input: AssemblyInput) -> [String: Any] {
        var nights: [[String: Any]] = []
        nights.reserveCapacity(input.nights.count)
        for n in input.nights {
            nights.append([
                "night_id": n.nightId,
                "start_utc": isoUTC(n.start),
                "end_utc": isoUTC(n.end),
                "is_nap": n.isNap,
                "user_edited": n.userEdited,
                "stages": n.stages.map { ["start": $0.start, "end": $0.end, "stage": $0.stage] },
            ])
        }
        var request: [String: Any] = [
            "schema_version": schemaVersion,
            "algorithm_version": algorithmVersion,
            "context": [
                "user_id": input.userId,
                "device_id": input.deviceId,
                "day": input.day,
                "iana_timezone": input.timezoneId,
                "input_revision": input.inputRevision,
                "interval_start_utc": isoUTC(input.intervalStart),
                "interval_end_utc": isoUTC(input.intervalEnd),
            ],
            "nights": nights,
            "hr_samples": input.hr.map { ["ts": $0.ts, "bpm": Double($0.bpm)] },
            "skin_temp_samples": input.tempCelsius.map { ["ts": $0.ts, "celsius": $0.celsius] },
            "rr_beats": input.beats.map { [
                "ts": $0.ts,
                "rr_ms": Double($0.rrMs),
                "seq": $0.seq,
                "ord": $0.ord ?? NSNull(),
                "src_channel": $0.srcChannel?.rawValue ?? NSNull(),
            ] as [String: Any] },
            "resp_breaths": [
                "intervals": input.breathTrack.intervals.map { ["ts": $0.ts, "seconds": $0.seconds] },
                "runs": input.breathTrack.runs.map { ["start": $0.start, "end": $0.end] },
            ] as [String: Any],
        ]
        if let history = input.history, !history.dayRevisions.isEmpty {
            var digest = ""
            for (day, revision) in history.dayRevisions {
                digest += "\(day):\(revision)|"
            }
            request["history"] = [
                "pair_policy": "elapsed_24h",
                "days": Dictionary(grouping: history.minutes, by: \.day)
                    .sorted(by: { $0.key < $1.key })
                    .map { day, minutes in
                        var ms: [[String: Any]] = []
                        ms.reserveCapacity(minutes.count)
                        for m in minutes.sorted(by: { $0.ts < $1.ts }) {
                            ms.append(["ts": m.ts, "state": m.state, "valid": m.valid])
                        }
                        return ["day": day, "minutes": ms]
                    },
            ] as [String: Any]
            if let context = request["context"] as? [String: Any] {
                var c = context
                c["history_revision_digest"] = sha256Hex(Data(digest.utf8))
                request["context"] = c
            }
        }
        return request
    }

    // MARK: - Response validation (pure; unit-tested)

    /// Structural validation before attaching: the object must be JSON-safe,
    /// carry a known status, and its nights must be a list of objects with the
    /// contract's required keys. Numbers are checked for finiteness by
    /// JSONSerialization's isValidJSONObject only in shape terms; NaN cannot
    /// survive a JSON round-trip from the sidecar (the Python contract
    /// renders NaN as absent), but a hostile/garbled body is refused here
    /// rather than persisted.
    static func validateResponse(_ raw: Data) -> [String: Any]? {
        guard raw.count <= maxResponseBytes else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return nil
        }
        guard obj["schema_version"] as? Int == schemaVersion,
              let status = obj["status"] as? String,
              ["available", "partial", "withheld", "timeout", "error"].contains(status) else {
            return nil
        }
        guard let nights = obj["nights"] as? [[String: Any]] else { return nil }
        for n in nights {
            guard n["night_id"] is String,
                  n["start_utc"] is String,
                  n["end_utc"] is String else {
                return nil
            }
        }
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        return obj
    }

    // MARK: - Call (sidecar transport)

    /// POST /v1/sleep-features through the shared loopback transport.
    /// Returns the validated response object, or nil on ANY failure (the
    /// caller then publishes the snapshot without the key — or, for a
    /// `timeout`/`error` status body, attaches the degraded status document
    /// so the client can say "unavailable right now" instead of nothing).
    static func enrich(request: [String: Any], client: InferenceClient) -> [String: Any]? {
        do {
            guard JSONSerialization.isValidJSONObject(request),
                  let body = try? JSONSerialization.data(withJSONObject: request) else {
                return nil
            }
            let raw = try client.sleepFeatures(body: body, timeoutMSOverride: budgetMS)
            return validateResponse(raw)
        } catch {
            return nil
        }
    }

    // MARK: - History loader (DB; one bounded query)

    /// Load the last `days` published snapshot sleep arrays (newest
    /// result_revision per day) and fold each night's stages to a UTC
    /// 1-minute sleep/wake grid.
    ///
    /// Validity policy (honest wave-1 limitation, machine-readable in the
    /// request's history block): a minute is `valid` when it is inside a
    /// staged session span; sleep/wake comes from the staged labels. Minutes
    /// OUTSIDE staged spans are `valid: false` — the published snapshot
    /// cannot establish a per-minute daytime wear decision, so they are
    /// EXCLUDED rather than marked awake (spec A3: "do not mark every
    /// interval outside the main night as awake"). The SRI gates in the
    /// sidecar then decide whether an SRI window is publishable at all.
    static func loadHistory(db: PostgresClientProtocol, userId: String, deviceId: String,
                            days: Int, todayDay: String) throws -> SleepFeatureHistory? {
        let rows = try db.query("""
            select day::text as day, result_revision::text as rev, payload->'sleep' as sleep
              from public.scoring_snapshots_v2 s
             where user_id = $1::uuid and device_id = $2::uuid
               and day < $3::date
               and day >= ($3::date - make_interval(days => $4::int))
               and result_revision = (
                    select max(result_revision) from public.scoring_snapshots_v2 s2
                     where s2.user_id = s.user_id and s2.device_id = s.device_id
                       and s2.day = s.day)
             order by day
            """, [userId, deviceId, todayDay, String(days)])
        guard !rows.isEmpty else { return nil }
        var dayRevisions: [(day: String, revision: Int64)] = []
        var minutes: [(day: String, ts: Int, state: Int, valid: Bool)] = []
        for row in rows {
            let day = row["day"] ?? ""
            guard let rev = Int64(row["rev"] ?? "") else { continue }
            dayRevisions.append((day, rev))
            guard let sleepText = row["sleep"], !sleepText.isEmpty,
                  let data = sleepText.data(using: .utf8),
                  let nights = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                continue
            }
            for night in nights {
                guard let startAt = night["start_at"] as? String, let endAt = night["end_at"] as? String,
                      let start = unixSeconds(startAt), let end = unixSeconds(endAt),
                      end > start else { continue }
                // The minute grid of the staged span: sleep where staged
                // sleep covers the majority of the minute, wake otherwise.
                var stages: [(start: Int, end: Int, stage: String)] = []
                if let arr = night["stages"] as? [[String: Any]] {
                    for s in arr {
                        if let st = s["start"] as? Int, let en = s["end"] as? Int,
                           let stage = s["stage"] as? String, en > st {
                            stages.append((st, en, stage))
                        }
                    }
                }
                // A published night with NO stage array carries an unknown
                // classification: its span cannot honestly be folded to
                // sleep/wake, and marking it "wake" would fabricate exactly
                // the daytime-awake assumption spec A3 forbids. It contributes
                // NO minutes (the day keeps its revision for the digest, and
                // its span stays excluded from SRI pairing).
                if stages.isEmpty { continue }
                stages.sort { $0.start < $1.start }
                var m = start
                while m + 60 <= end {
                    let sleepSec = stages.filter { $0.stage != "wake" }
                        .reduce(0.0) { acc, s in
                            acc + Double(max(0, min(s.end, m + 60) - max(s.start, m)))
                        }
                    minutes.append((day, m, sleepSec >= 30.0 ? 1 : 0, true))
                    m += 60
                }
            }
        }
        guard !dayRevisions.isEmpty else { return nil }
        return SleepFeatureHistory(dayRevisions: dayRevisions, minutes: minutes)
    }

    static func unixSeconds(_ iso: String) -> Int? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { return Int(d.timeIntervalSince1970) }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: iso).map { Int($0.timeIntervalSince1970) }
    }

    static func isoUTC(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

/// The minimal surface `loadHistory` needs, so its unit tests can run without
/// a database (the same seam `DayScorer` uses for its loader tests).
protocol PostgresClientProtocol {
    func query(_ sql: String, _ params: [String]) throws -> [[String: String]]
}

extension PostgresClient: PostgresClientProtocol {}
