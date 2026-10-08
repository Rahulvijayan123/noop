// SleepFeatureRhythmHistory.swift
//
// The bounded multi-day rhythm history for the sleep-features request (spec-02 §3 / §4,
// docs/spec-02/CONTRACT.md §5.1 `rhythm_history`): hourly UTC bins of converted skin
// temperature, worn heart rate and gravity movement over at most 35 local days.
//
// WHERE THE AGGREGATION HAPPENS (and why not a raw-table query)
// -------------------------------------------------------------
// Re-aggregating 35 days of 1 Hz rows per scoring pass is far too expensive inside the
// scoring transaction: measured on production for one owner day (2026-10-06, ~85 k rows per
// stream), the three-stream minute aggregate (temperature median, HR presence, gravity
// one-second adjacencies) took 13.7 s cold (≈ 5 000 pages read) and 0.49 s warm. That
// transaction holds the job row and, with the input gate, the per-user `scoring-inputs-v2`
// advisory lock uploads need (docs: server-compute-tiering / perf notes), so 35 such days
// are out of the question there.
//
// Instead each day is aggregated ONCE, near the source, from the rows its OWN scoring pass
// already loaded (the 84 h night window covers the whole local day): `buildDay` folds them
// to minute bins (the CONTRACT §5.1 minute rules) and rolls the minutes into UTC-hour bins.
// The result is published inside that day's snapshot under the top-level key `rhythmDay`.
// The published snapshot IS the per-day, per-revision cache: a late upload re-scores the
// day (the invalidation trigger and the day-closure pass), which republishes its bins under
// a new `result_revision`. A later day's request then reads the past 34 days' bins with ONE
// bounded, indexed query (`loadDays`: one index probe per day on
// `scoring_snapshot_read_v2`; measured 1.6 ms warm on production for the owner) — no raw
// stream is read again. The claim day itself comes from the pass's in-memory rows.
//
// Temperature is kept in the RAW register domain per bin (median of valid minute medians)
// and converted once, at assembly, with ONE conversion for the whole history: WHOOP 5/MG
// centidegrees (`raw / 100`, the conversion `skinTempCelsius` uses), or the WHOOP 4.0
// provisional affine map with ONE history-wide anchor (a per-pass anchor would shift every
// day's offset and fake a rhythm). The affine map is monotone, so the median commutes with
// it exactly. Days of different device families are never mixed silently: the history is
// marked `mixed` and the sidecar returns `mixed_devices`.

import Foundation
import WhoopProtocol
import StrandAnalytics

enum SleepFeatureRhythmHistory {

    static let historySchema = "rhythm-history-1"
    static let daySchema = "rhythm-day-1"
    /// Top-level snapshot payload key that carries the day's own bins.
    static let snapshotKey = "rhythmDay"
    static let binSeconds = 3600
    /// The request carries at most this many local days (the claim day included).
    static let maxDays = 35

    /// The minute / hour rules. Any change is a new `rulesVersion`: published days built
    /// under other rules are ignored (never mixed), and the version enters the digest.
    struct Rules: Equatable {
        static let rulesVersion = "rhythm-rules-1"
        var minuteMinDistinctSeconds = 30
        var wornMinuteMinHRSeconds = 30
        var hrPlausibleBpm: ClosedRange<Int> = 20...250
        var skinTempPlausibleC: ClosedRange<Double> = 28.0...42.0
        var movementThresholdG = SleepStager.gravityStillThresholdG
        var movementMinuteMinAdjacencies = 30

        var wire: [String: Any] {
            [
                "rules_version": Rules.rulesVersion,
                "minute_min_distinct_seconds": minuteMinDistinctSeconds,
                "worn_minute_min_hr_seconds": wornMinuteMinHRSeconds,
                "hr_plausible_bpm": [hrPlausibleBpm.lowerBound, hrPlausibleBpm.upperBound],
                "skin_temp_plausible_c": [skinTempPlausibleC.lowerBound, skinTempPlausibleC.upperBound],
                "movement_threshold_g": movementThresholdG,
                "movement_minute_min_adjacencies": movementMinuteMinAdjacencies,
                "temp_minute_value": "median_of_in_band_seconds",
                "hour_temp_value": "median_of_valid_minute_medians",
                "hour_hr_value": "mean_of_valid_minute_means",
                "hour_movement_value": "60 * moving_adjacencies / eligible_adjacencies",
                "worn_evidence": "hr_seconds_in_minute",
            ]
        }

        /// Deterministic text of the rules for the revision digest.
        var digestText: String {
            "\(Rules.rulesVersion);\(minuteMinDistinctSeconds);\(wornMinuteMinHRSeconds);"
                + "\(hrPlausibleBpm.lowerBound)-\(hrPlausibleBpm.upperBound);"
                + "\(skinTempPlausibleC.lowerBound)-\(skinTempPlausibleC.upperBound);"
                + "\(movementThresholdG);\(movementMinuteMinAdjacencies)"
        }
    }

    /// One UTC-hour bin. A signal the hour did not support is nil (never 0).
    struct Bin: Equatable {
        let start: Int
        /// Median of the valid minute medians, in the device's RAW register domain.
        var skinTempRaw: Double?
        var skinTempValidMinutes: Int
        var hrMeanBpm: Double?
        var hrValidMinutes: Int
        var movementSPerMin: Double?
        var movementValidMinutes: Int
    }

    /// One local day's bins with its identity.
    struct Day: Equatable {
        let day: String
        let timezone: String
        let dayStart: Int
        let dayEnd: Int
        /// `DeviceFamily.rawValue` of the pass that built the bins.
        let deviceFamily: String
        let rulesVersion: String
        /// Snapshot `result_revision` for a published day; the claim's input revision for the
        /// claim day built in memory.
        var revision: Int64
        let bins: [Bin]
    }

    // MARK: - Build one day from in-memory rows (pure)

    /// In-band raw range for a sample to count toward a temperature minute, per family. The
    /// 5/MG register is centidegrees, so the 28–42 °C plausibility band is exact here; the
    /// 4.0's anchor is unknown per sample, so its raw worn band applies and the °C band is
    /// applied to the converted hour at assembly.
    static func inBandRaw(_ raw: Int, family: DeviceFamily, rules: Rules) -> Bool {
        switch family {
        case .whoop5:
            let c = Double(raw) / 100.0
            return rules.skinTempPlausibleC.contains(c)
        case .whoop4:
            return raw >= Whoop4SkinTemp.wornMinRaw && raw <= Whoop4SkinTemp.wornMaxRaw
        }
    }

    /// Fold the pass's rows into the local day's UTC-hour bins (bins whose start lies in
    /// `[dayStart, dayEnd)`; a bin always aggregates its whole UTC hour).
    ///
    /// Minute rules (CONTRACT §5.1): a minute is WORN with ≥ 30 distinct plausible-HR
    /// seconds. Temperature minute = median raw of its in-band distinct seconds, valid when
    /// worn with ≥ 30 of them. HR minute = mean of its plausible seconds, valid when worn.
    /// Movement minute = moving seconds among TRUE one-second gravity adjacencies (t−1, t)
    /// (‖Δg‖ ≥ threshold, the stager's stillness threshold), valid when worn with ≥ 30
    /// adjacencies. Duplicate seconds collapse (first wins); nothing is interpolated.
    static func buildDay(day: String, timezoneId: String, dayStart: Int, dayEnd: Int,
                         family: DeviceFamily, revision: Int64,
                         hr: [HRSample], skinTemp: [SkinTempSample], gravity: [GravitySample],
                         rules: Rules = Rules()) -> Day {
        let lo = ceilHour(dayStart)
        let hi = ceilHour(dayEnd)
        let nMinutes = max(0, (hi - lo) / 60)
        func minuteIndex(_ ts: Int) -> Int? {
            guard ts >= lo, ts < hi else { return nil }
            return (ts - lo) / 60
        }

        // HR: distinct plausible seconds per minute and their bpm sum.
        var hrSeconds = [Int](repeating: 0, count: nMinutes)
        var hrSum = [Double](repeating: 0, count: nMinutes)
        var lastTs = Int.min
        for s in ascending(hr, lo, hi, { $0.ts }) {
            guard s.ts != lastTs else { continue }
            lastTs = s.ts
            guard rules.hrPlausibleBpm.contains(s.bpm), let m = minuteIndex(s.ts) else { continue }
            hrSeconds[m] += 1
            hrSum[m] += Double(s.bpm)
        }
        let worn = hrSeconds.map { $0 >= rules.wornMinuteMinHRSeconds }

        // Temperature: in-band raws per minute (distinct seconds).
        var tempRaws = [[Int]](repeating: [], count: nMinutes)
        lastTs = Int.min
        for s in ascending(skinTemp, lo, hi, { $0.ts }) {
            guard s.ts != lastTs else { continue }
            lastTs = s.ts
            guard inBandRaw(s.raw, family: family, rules: rules), let m = minuteIndex(s.ts) else { continue }
            tempRaws[m].append(s.raw)
        }

        // Movement: true one-second adjacencies (t-1, t), attributed to t's minute.
        var eligible = [Int](repeating: 0, count: nMinutes)
        var moving = [Int](repeating: 0, count: nMinutes)
        var prev: GravitySample?
        for g in ascending(gravity, lo - 1, hi, { $0.ts }) {
            if let p = prev, p.ts == g.ts { continue }
            defer { prev = g }
            guard let p = prev, g.ts == p.ts + 1, let m = minuteIndex(g.ts) else { continue }
            let dx = g.x - p.x, dy = g.y - p.y, dz = g.z - p.z
            eligible[m] += 1
            if (dx * dx + dy * dy + dz * dz).squareRoot() >= rules.movementThresholdG { moving[m] += 1 }
        }

        var bins: [Bin] = []
        var hourStart = lo
        while hourStart < hi {
            let m0 = (hourStart - lo) / 60
            var tempMedians: [Double] = []
            var hrMeans: [Double] = []
            var movValid = 0, movMoving = 0, movEligible = 0
            for m in m0..<min(m0 + 60, nMinutes) where worn[m] {
                if tempRaws[m].count >= rules.minuteMinDistinctSeconds {
                    tempMedians.append(median(tempRaws[m].map { Double($0) }))
                }
                hrMeans.append(hrSum[m] / Double(hrSeconds[m]))
                if eligible[m] >= rules.movementMinuteMinAdjacencies {
                    movValid += 1
                    movMoving += moving[m]
                    movEligible += eligible[m]
                }
            }
            if !tempMedians.isEmpty || !hrMeans.isEmpty || movValid > 0 {
                bins.append(Bin(
                    start: hourStart,
                    skinTempRaw: tempMedians.isEmpty ? nil : median(tempMedians),
                    skinTempValidMinutes: tempMedians.count,
                    hrMeanBpm: hrMeans.isEmpty ? nil : hrMeans.reduce(0, +) / Double(hrMeans.count),
                    hrValidMinutes: hrMeans.count,
                    movementSPerMin: movValid > 0 && movEligible > 0
                        ? 60.0 * Double(movMoving) / Double(movEligible) : nil,
                    movementValidMinutes: movValid))
            }
            hourStart += binSeconds
        }
        return Day(day: day, timezone: timezoneId, dayStart: dayStart, dayEnd: dayEnd,
                   deviceFamily: family.rawValue, rulesVersion: Rules.rulesVersion,
                   revision: revision, bins: bins)
    }

    // MARK: - Snapshot record (the per-day cache)

    /// The `rhythmDay` object published in the day's own snapshot payload.
    static func snapshotJSON(_ d: Day) -> [String: Any] {
        [
            "schema": daySchema,
            "rules_version": d.rulesVersion,
            "day": d.day,
            "timezone": d.timezone,
            "day_start_utc": d.dayStart,
            "day_end_utc": d.dayEnd,
            "device_family": d.deviceFamily,
            "temp_scale": "raw_register",
            "bins": d.bins.map { b -> [String: Any] in
                [
                    "start": b.start,
                    "skin_temp_raw": nullable(b.skinTempRaw.map { round3($0) }),
                    "skin_temp_valid_minutes": b.skinTempValidMinutes,
                    "hr_mean_bpm": nullable(b.hrMeanBpm.map { round3($0) }),
                    "hr_valid_minutes": b.hrValidMinutes,
                    "movement_s_per_min": nullable(b.movementSPerMin.map { round3($0) }),
                    "movement_valid_minutes": b.movementValidMinutes,
                ]
            },
        ]
    }

    /// Parse a published `rhythmDay` (nil for another schema / rules version, or malformed).
    static func parseSnapshotDay(_ obj: [String: Any], revision: Int64) -> Day? {
        guard obj["schema"] as? String == daySchema,
              obj["rules_version"] as? String == Rules.rulesVersion,
              let day = obj["day"] as? String, let tz = obj["timezone"] as? String,
              let ds = intValue(obj["day_start_utc"]), let de = intValue(obj["day_end_utc"]),
              de > ds, de - ds <= 26 * 3600,
              let family = obj["device_family"] as? String,
              let rawBins = obj["bins"] as? [[String: Any]] else { return nil }
        var bins: [Bin] = []
        for b in rawBins {
            guard let start = intValue(b["start"]), start % binSeconds == 0,
                  start > ds - binSeconds, start < de else { return nil }
            bins.append(Bin(
                start: start,
                skinTempRaw: doubleValue(b["skin_temp_raw"]),
                skinTempValidMinutes: intValue(b["skin_temp_valid_minutes"]) ?? 0,
                hrMeanBpm: doubleValue(b["hr_mean_bpm"]),
                hrValidMinutes: intValue(b["hr_valid_minutes"]) ?? 0,
                movementSPerMin: doubleValue(b["movement_s_per_min"]),
                movementValidMinutes: intValue(b["movement_valid_minutes"]) ?? 0))
        }
        return Day(day: day, timezone: tz, dayStart: ds, dayEnd: de, deviceFamily: family,
                   rulesVersion: Rules.rulesVersion, revision: revision, bins: bins)
    }

    // MARK: - History loader (DB; one bounded indexed query)

    /// One index probe per day on `scoring_snapshot_read_v2` (newest `result_revision` of
    /// each day under the claimed algorithm), returning only the small `rhythmDay` object.
    static let loadSQL = """
        select d.day::date::text as day, x.rev, x.rhythm
          from generate_series($3::date - $4::int, $3::date - 1, interval '1 day') as d(day)
          cross join lateral (
                select s.result_revision::text as rev, (s.payload->'rhythmDay')::text as rhythm
                  from public.scoring_snapshots_v2 s
                 where s.user_id = $1::uuid and s.device_id = $2::uuid
                   and s.day = d.day::date and s.algorithm_version = $5::text
                 order by s.result_revision desc
                 limit 1) x
         order by 1
        """

    /// The published days before `todayDay` (at most `maxDays − 1`), oldest first. A day
    /// whose newest snapshot carries no `rhythmDay` (published before this feature, or by a
    /// pass without the enrichment) or other rules is absent — never back-filled from an
    /// older revision.
    static func loadDays(db: PostgresClientProtocol, userId: String, deviceId: String,
                         todayDay: String, algorithmVersion: String,
                         days: Int = maxDays - 1) throws -> [Day] {
        let rows = try db.query(loadSQL, [userId, deviceId, todayDay, String(days), algorithmVersion])
        var out: [Day] = []
        for row in rows {
            guard let rev = Int64(row["rev"] ?? ""), let text = row["rhythm"], !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let day = parseSnapshotDay(obj, revision: rev),
                  day.day == row["day"] else { continue }
            out.append(day)
        }
        return out.sorted { $0.dayStart < $1.dayStart }
    }

    // MARK: - Request assembly (pure)

    static let whoop5Identity = "whoop5-centidegree"

    /// The `rhythm_history` wire object (CONTRACT §5.1), or nil when no day has bins.
    ///
    /// Duplicate days keep the newest revision; at most `maxDays` days (the newest) are
    /// sent. Temperature is converted here with ONE conversion per family for the whole
    /// history; a converted hour outside the plausible °C band is null. Days from different
    /// device families make the history `mixed` (the sidecar then withholds the phase).
    static func assemble(days input: [Day], rules: Rules = Rules()) -> [String: Any]? {
        var byDay: [String: Day] = [:]
        for d in input where d.rulesVersion == Rules.rulesVersion {
            if let have = byDay[d.day], have.revision >= d.revision { continue }
            byDay[d.day] = d
        }
        let days = Array(byDay.values.sorted { $0.dayStart < $1.dayStart }.suffix(maxDays))
        guard days.contains(where: { !$0.bins.isEmpty }) else { return nil }

        // One anchor for every WHOOP 4.0 day: the median of their hourly raw medians (the
        // per-pass anchor would shift each day's offset). Too few hours -> the global anchor.
        let w4Raws = days.filter { $0.deviceFamily == DeviceFamily.whoop4.rawValue }
            .flatMap { $0.bins.compactMap(\.skinTempRaw) }
        let w4Anchor = w4Raws.count >= 24 ? median(w4Raws) : Whoop4SkinTemp.anchorRaw
        func identity(_ family: String) -> String {
            family == DeviceFamily.whoop4.rawValue
                ? "whoop4-provisional-affine:anchor=\(round3(w4Anchor)):slope=\(Whoop4SkinTemp.provisionalSlopeCPerRaw)"
                : whoop5Identity
        }
        func celsius(_ raw: Double, family: String) -> Double {
            family == DeviceFamily.whoop4.rawValue
                ? Whoop4SkinTemp.anchorCelsius + (raw - w4Anchor) * Whoop4SkinTemp.provisionalSlopeCPerRaw
                : raw / 100.0
        }
        let families = Set(days.filter { !$0.bins.isEmpty }.map(\.deviceFamily))
        let mixed = families.count > 1
        let topFamily = mixed ? "mixed" : (families.first ?? days[0].deviceFamily)
        let topIdentity = mixed ? "mixed" : identity(topFamily)

        var digestText = ""
        var wireDays: [[String: Any]] = []
        for d in days {
            digestText += "\(d.day):\(d.revision)|"
            let bins: [[String: Any]] = d.bins.map { b in
                var c: Double? = b.skinTempRaw.map { celsius($0, family: d.deviceFamily) }
                if let v = c, !(v.isFinite && rules.skinTempPlausibleC.contains(v)) { c = nil }
                return [
                    "start": b.start,
                    "skin_temp_c": nullable(c.map { round3($0) }),
                    "skin_temp_valid_minutes": c == nil ? 0 : min(60, b.skinTempValidMinutes),
                    "hr_mean_bpm": nullable(b.hrMeanBpm.map { round3($0) }),
                    "hr_valid_minutes": b.hrMeanBpm == nil ? 0 : min(60, b.hrValidMinutes),
                    "movement_s_per_min": nullable(b.movementSPerMin.map { round3(min(60, max(0, $0))) }),
                    "movement_valid_minutes": b.movementSPerMin == nil ? 0 : min(60, b.movementValidMinutes),
                ]
            }
            wireDays.append([
                "day": d.day,
                "timezone": d.timezone,
                "revision": d.revision,
                "day_start_utc": d.dayStart,
                "day_end_utc": d.dayEnd,
                "device_family": d.deviceFamily,
                "conversion_identity": identity(d.deviceFamily),
                "bins": bins,
            ])
        }
        digestText += "identity=\(topIdentity)|rules=\(rules.digestText)"
        return [
            "schema": historySchema,
            "device_family": topFamily,
            "conversion_identity": topIdentity,
            "bin_seconds": binSeconds,
            "rules": rules.wire,
            "revision_digest": sha256Hex(Data(digestText.utf8)),
            "days": wireDays,
        ]
    }

    // MARK: - Helpers

    /// The rows with `lo <= ts < hi`, ascending by `ts`. The loaders return rows ordered by `ts`,
    /// so the common path is one linear order check plus two binary searches and a slice; only
    /// unordered input is filtered and stably sorted (ties keep input order, so "first wins").
    static func ascending<T>(_ rows: [T], _ lo: Int, _ hi: Int, _ ts: (T) -> Int) -> ArraySlice<T> {
        var ordered = true
        var last = Int.min
        for r in rows {
            let t = ts(r)
            if t < last { ordered = false; break }
            last = t
        }
        guard ordered else {
            let kept = rows.enumerated().filter { ts($0.element) >= lo && ts($0.element) < hi }
            return ArraySlice(kept.sorted { (ts($0.element), $0.offset) < (ts($1.element), $1.offset) }
                .map(\.element))
        }
        func lowerBound(_ x: Int) -> Int {
            var a = 0, b = rows.count
            while a < b {
                let m = (a + b) / 2
                if ts(rows[m]) < x { a = m + 1 } else { b = m }
            }
            return a
        }
        return rows[lowerBound(lo)..<lowerBound(hi)]
    }

    static func ceilHour(_ ts: Int) -> Int {
        let r = ts % binSeconds
        return r == 0 ? ts : ts - r + (ts >= 0 ? binSeconds : 0)
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// A JSON value: the number, or `null` (never 0) when absent.
    static func nullable(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }

    static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double, d.rounded() == d { return Int(d) }
        return nil
    }

    static func doubleValue(_ v: Any?) -> Double? {
        if v is NSNull { return nil }
        if let d = v as? Double, d.isFinite { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
