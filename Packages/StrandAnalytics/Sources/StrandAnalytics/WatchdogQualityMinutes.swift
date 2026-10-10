import Foundation
import WhoopProtocol

/// Per-minute optical evidence that only the phone holds (the WHOOP 5/MG v18 aux bytes are not uploaded and are pruned
/// on the phone after about a week): the server's measurement-context record keeps these counts so a reading's
/// quality stays traceable (`POST scores/quality-minutes`, docs/context-watchdog/MEASUREMENT_CONTEXT.md).
/// Observed counts only; the server derives the quality class and canonical reasons from them.
public enum WatchdogQualityMinutes {
    public static let version = "phone-quality-1"
    /// Optical baseline above this (owner's settled p99 is 42) is shadow-logged as `optical_baseline_high`.
    public static let baselineHighShadow = 100

    public struct Row: Equatable, Sendable {
        public var minuteStart: Int
        /// v18 records in the minute.
        public var v18N: Int
        /// Records with the optical amplitude marker (or the flag byte's bit 7 clear).
        public var sentinelN: Int
        /// Highest optical baseline (A or B) seen in the minute; nil when none was reported.
        public var baselineMax: Int?
        /// A minute with no records inside a gap: "paused" (record index +1 across the gap: the strap stopped
        /// recording) or "lost" (index jumped by the gap: records lost in transport). Nil otherwise.
        public var recordGap: String?
        /// Legacy Watchdog quality codes for the minute (`contracts/reason-codes.json` legacy.watchdog_quality).
        public var reasons: [String]
    }

    /// Rows for every minute in `[from, to)` that has records or lies inside a classified gap ≥ 30 s.
    public static func summarize(_ aux: [V18AuxSample], from: Int, to: Int) -> [Row] {
        let sorted = aux.filter { $0.ts >= from && $0.ts < to }.sorted { $0.ts < $1.ts }
        func minute(_ t: Int) -> Int { t - ((t % 60) + 60) % 60 }
        var rows: [Int: Row] = [:]
        for s in sorted {
            let m = minute(s.ts)
            var r = rows[m] ?? Row(minuteStart: m, v18N: 0, sentinelN: 0, baselineMax: nil, recordGap: nil, reasons: [])
            r.v18N += 1
            let sentinel = s.opticalAmpA == 128 || s.opticalAmpB == 128
                || (s.hrQualityFlags.map { $0 & 0x80 == 0 } ?? false)
            if sentinel { r.sentinelN += 1 }
            for b in [s.opticalBaselineA, s.opticalBaselineB].compactMap({ $0 }) {
                r.baselineMax = max(r.baselineMax ?? b, b)
            }
            rows[m] = r
        }
        // Record-index gaps (same rule as WatchdogSignalQuality.assess).
        let indexed = sorted.compactMap { s in s.recordIndex.map { (s.ts, $0) } }
        for (a, b) in zip(indexed, indexed.dropFirst()) where b.0 - a.0 >= WatchdogSignalQuality.notRecordingGapSeconds {
            let kind: String? = b.1 - a.1 == 1 ? "paused" : (b.1 - a.1 > 1 ? "lost" : nil)
            guard let kind else { continue }
            var m = minute(a.0) + 60
            while m + 60 <= b.0 {
                var r = rows[m] ?? Row(minuteStart: m, v18N: 0, sentinelN: 0, baselineMax: nil, recordGap: nil, reasons: [])
                r.recordGap = kind
                rows[m] = r
                m += 60
            }
        }
        for (m, var r) in rows {
            if r.recordGap == "paused" { r.reasons.append("strap_not_recording") }
            if r.recordGap == "lost" { r.reasons.append("transport_gap") }
            if r.v18N > 0, Double(r.sentinelN) / Double(r.v18N) > WatchdogSignalQuality.poorSentinelFrac {
                r.reasons.append("optical_sentinel")
            }
            // Shadow only: a possible loose-contact hint (seen once, 10-08 22:00). Deliberately unmapped in
            // contracts/reason-codes.json, so the server keeps it raw and never surfaces it as a cause.
            if let b = r.baselineMax, b > Self.baselineHighShadow { r.reasons.append("optical_baseline_high") }
            rows[m] = r
        }
        return rows.values.sorted { $0.minuteStart < $1.minuteStart }
    }

    /// The JSON body for `POST scores/quality-minutes` (snake_case, like `scores/placement`).
    public static func body(deviceId: String, rows: [Row]) -> [String: Any] {
        ["device_id": deviceId, "version": version,
         "minutes": rows.map { r -> [String: Any] in
            ["minute_start": r.minuteStart, "v18_n": r.v18N, "sentinel_n": r.sentinelN,
             "baseline_max": r.baselineMax.map { $0 as Any } ?? NSNull(),
             "record_gap": r.recordGap.map { $0 as Any } ?? NSNull(),
             "hr_grade": NSNull(), "beats_grade": NSNull(), "reasons": r.reasons]
         }]
    }
}
