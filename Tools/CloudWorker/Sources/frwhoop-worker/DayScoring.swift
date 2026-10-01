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

    // MARK: - Score one claimed day

    /// Score one claimed day: load inputs, compute, and return both the
    /// legacy payload (engine_publish_legacy_fenced) and the v2 snapshot
    /// payload (publish_scoring_snapshot_v2) built from the same DayResult.
    func scoreAndBuildPayloads(claim: Claim) throws -> (legacy: [String: Any], snapshot: [String: Any]) {
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

        let hr = try loadHR(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let rr = try loadRR(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let resp = try loadResp(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let gravity = try loadGravity(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let skinTemp = try loadSkinTemp(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let spo2 = try loadSpo2(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let events = try loadEvents(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
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
        let coverage = coverageJSON(hr: hr.count, rr: rr.count, resp: resp.count, gravity: gravity.count,
                                    skinTemp: skinTemp.count, spo2: spo2.count, events: events.count,
                                    sleepState: sleepState.count, steps: steps.count,
                                    dayHr: dayHr.count, daySteps: daySteps.count, dayGravity: dayGravity.count,
                                    nightWindow: (nightStart, nightEnd))
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
            return (legacy, snapshot)
        }

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
            wristOff: wristOff,
            bandSleepState: sleepState
        )

        let status = Self.classifyStatus(hrCount: hr.count, rrCount: rr.count, respCount: resp.count,
                                         gravityCount: gravity.count, detectedSessionCount: result.sleepSessions.count)
        let daily = legacyDaily(from: result, claim: claim, computedAt: computedAt)
        let snapshotDaily = self.snapshotDaily(from: result, claim: claim, computedAt: computedAt)
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
        return (legacy, snapshot)
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
        if let v = d.spo2Red { daily["spo2Red"] = v }
        if let v = d.spo2Ir { daily["spo2Ir"] = v }
        if let v = d.sleepHrOnly { daily["sleepHrOnly"] = v }
        if let v = result.recovery { daily["recovery"] = v }
        if let v = result.strain { daily["strain"] = v }
        if let v = result.restScore { daily["restScore"] = v }
        return daily
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
            order by ts, seq
            """, [userId, deviceId, String(from), String(to)])
        return rows.compactMap { r in
            guard let ts = Int64(r["ts"] ?? ""), let rrMs = Int(r["rrMs"] ?? "") else { return nil }
            let ch = Int(r["ch"] ?? "").flatMap { RRSourceChannel(rawValue: $0) }
            let seq = Int(r["seq"] ?? "") ?? 0
            let ord = Int(r["ord"] ?? "")
            return RRInterval(ts: Int(ts), rrMs: rrMs, srcChannel: ch, ord: ord, seq: seq)
        }
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

    private func loadEvents(userId: String, deviceId: String, from: Int, to: Int) throws -> [WhoopEvent] {
        let rows = try db.query("""
            select ts::text, kind, "payloadJSON" from public.noop_events
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, [userId, deviceId, String(from), String(to)])
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
            sex: sex
        )
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
