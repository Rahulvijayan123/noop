
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

    /// Score one claimed day: load inputs, compute, and return both the
    /// legacy payload (engine_publish_legacy_fenced) and the v2 snapshot
    /// payload (publish_scoring_snapshot_v2) built from the same DayResult.
    func scoreAndBuildPayloads(claim: Claim) throws -> (legacy: [String: Any], snapshot: [String: Any]) {
        let tz = TimeZone(identifier: claim.timezoneId) ?? TimeZone(identifier: "UTC")!
        let offsetSeconds = tz.secondsFromGMT()

        guard let dayStart = dayStartUnix(claim.day, tz) else {
            throw ScoringError(description: "invalid day \(claim.day)")
        }
        let nightStart = dayStart - 30 * 3600
        let nightEnd = dayStart + 54 * 3600
        let dayEnd = dayStart + 24 * 3600

        let hr = try loadHR(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let rr = try loadRR(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let resp = try loadResp(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let gravity = try loadGravity(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let skinTemp = try loadSkinTemp(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let spo2 = try loadSpo2(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let events = try loadEvents(userId: claim.userId, deviceId: claim.deviceId, from: nightStart, to: nightEnd)
        let dayHr = try loadHR(userId: claim.userId, deviceId: claim.deviceId, from: dayStart, to: dayEnd)
        let dayGravity = try loadGravity(userId: claim.userId, deviceId: claim.deviceId, from: dayStart, to: dayEnd)
        let profile = try loadProfile(userId: claim.userId)
        let baselines = try loadBaselines(userId: claim.userId, deviceId: claim.deviceId, before: claim.day)

        let computedAt = isoNow()

        // Not enough samples to score honestly: publish no_data results with
        // real coverage numbers, never zero-filled physiology.
        guard hr.count >= 200 else {
            FileHandle.standardError.write("frwhoop-worker: day \(claim.day) device \(claim.deviceId.prefix(8)) no_data: hr=\(hr.count) rr=\(rr.count) window=[\(nightStart),\(nightEnd)) tz=\(claim.timezoneId)\n".data(using: .utf8)!)
            let coverage: [String: Any] = [
                "hr": ["received": hr.count], "rr": ["received": rr.count],
            ]
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
            let snapshot: [String: Any] = [
                "sleep": [] as [[String: Any]],
                "coverage": coverage,
                "daily": daily,
                "dataThrough": iso(nightEnd),
                "timezone": claim.timezoneId,
                "status": "no_data",
            ]
            return (legacy, snapshot)
        }

        let result = AnalyticsEngine.analyzeDay(
            day: claim.day,
            hr: hr, rr: rr, resp: resp, gravity: gravity,
            dayHr: dayHr, dayGravity: dayGravity,
            skinTemp: skinTemp, skinTempFamily: .whoop5,
            spo2: spo2,
            profile: profile,
            baselines: baselines,
            tzOffsetSeconds: offsetSeconds
        )

        let daily = legacyDaily(from: result, claim: claim, computedAt: computedAt)
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

        var sleepSessions: [[String: Any]] = []
        for n in nights {
            var s: [String: Any] = [:]
            if let id = n["id"] { s["id"] = id }
            if let start = n["start_at"] { s["start_at"] = start }
            if let end = n["end_at"] { s["end_at"] = end }
            s["stages"] = n["stages"] ?? ([] as [String])
            sleepSessions.append(s)
        }
        let coverage: [String: Any] = [
            "hr": ["received": hr.count], "rr": ["received": rr.count],
        ]
        let snapshot: [String: Any] = [
            "sleep": sleepSessions,
            "coverage": coverage,
            "daily": daily,
            "dataThrough": iso(nightEnd),
            "timezone": claim.timezoneId,
            "status": "available",
        ]
        return (legacy, snapshot)
    }

    // MARK: - Payload shaping

    private func legacyDaily(from result: AnalyticsEngine.DayResult, claim: Claim, computedAt: String) -> [String: Any] {
        let d = result.daily
        var daily: [String: Any] = [
            "user_id": claim.userId,
            "day": claim.day,
            "source_device_id": claim.deviceId,
            "algorithm_version": "frwhoop-server-1",
            "computed_at": computedAt,
        ]
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
        if let v = d.skinTempC { daily["skin_temp_c"] = v }
        if let v = result.nightlySkinTempC { daily["skin_temp_c"] = v }
        if let v = d.spo2Pct { daily["spo2_pct"] = v }
        daily["provenance"] = [
            "scope": "hrv_sleep", "scorer": "frwhoop-scoring-service",
            "computation_mode": "retrospective",
        ] as [String: Any]
        return daily
    }

    private func legacyNights(from result: AnalyticsEngine.DayResult, claim: Claim, computedAt: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for session in result.sleepSessions {
            let stages = AnalyticsEngine.encodeStages(session.stages) ?? "[]"
            let inBedSeconds = Double(session.end - session.start)
            let asleepMinutes = inBedSeconds / 60.0 * session.efficiency
            let awakeMinutes = inBedSeconds / 60.0 - asleepMinutes
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

    private func loadBaselines(userId: String, deviceId: String, before day: String) throws -> AnalyticsEngine.ProfileBaselines {
        let rows = try db.query("""
            select hrv_rmssd_ms::text hrv, resting_hr_bpm::text rhr, resp_rate_bpm::text resp,
                   skin_temp_c::text st
            from public.server_daily_scores
            where user_id=$1::uuid and algorithm_version='frwhoop-server-1' and day < $2::date
              and day > $2::date - 30
            order by day desc limit 14
            """, [userId, day])
        var hrvs: [Double] = [], rhrs: [Double] = [], resps: [Double] = [], sts: [Double] = []
        for r in rows {
            if let v = Double(r["hrv"] ?? "") { hrvs.append(v) }
            if let v = Double(r["rhr"] ?? "") { rhrs.append(v) }
            if let v = Double(r["resp"] ?? "") { resps.append(v) }
            if let v = Double(r["st"] ?? "") { sts.append(v) }
        }
        func baseline(_ vals: [Double]) -> BaselineState? {
            guard vals.count >= 3 else { return nil }
            let mean = vals.reduce(0, +) / Double(vals.count)
            let sd = (vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(vals.count)).squareRoot()
            return BaselineState(baseline: mean, spread: max(sd, 1e-9), nValid: vals.count,
                                 nightsSinceUpdate: 0, status: .trusted)
        }
        return AnalyticsEngine.ProfileBaselines(
            hrv: baseline(hrvs), restingHR: baseline(rhrs),
            resp: baseline(resps), skinTemp: baseline(sts)
        )
    }

    // MARK: - Time helpers

    private func dayStartUnix(_ day: String, _ tz: TimeZone) -> Int? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return nil }
        return Int(d.timeIntervalSince1970)
    }

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
