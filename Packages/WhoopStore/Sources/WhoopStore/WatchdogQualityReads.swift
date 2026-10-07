import Foundation
import GRDB
import WhoopProtocol

/// One PPG-derived heart-rate row exactly as stored: the REAL bpm (not rounded into the `HRSample` Int
/// domain) and the estimator's confidence.
public struct PpgHrRow: Equatable, Sendable {
    public let ts: Int
    public let bpm: Double
    public let conf: Double
    public init(ts: Int, bpm: Double, conf: Double) {
        self.ts = ts; self.bpm = bpm; self.conf = conf
    }
}

/// Additive reads for the Watchdog's sensor-quality feed (`WatchdogQualityFeed`). Read-only; nothing here
/// changes what any existing read returns.
extension WhoopStore {
    /// `ppgHrSample` rows with their confidence, oldest first. `hrSamples` COALESCEs these into the HR stream
    /// without a confidence gate; this read lets a consumer see which seconds are PPG estimates and how good.
    public func ppgHrRows(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [PpgHrRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm, conf FROM ppgHrSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { PpgHrRow(ts: $0["ts"], bpm: $0["bpm"], conf: $0["conf"]) }
        }
    }

    /// Battery rows WITH their charging bit (NULL stays nil), oldest first. `batterySamples` projects
    /// `ts, soc, mv` and drops the bit.
    public func batteryChargingSamples(deviceId: String, from: Int, to: Int,
                                       limit: Int) async throws -> [BatterySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, soc, mv, charging FROM battery
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { BatterySample(ts: $0["ts"], soc: $0["soc"], mv: $0["mv"], charging: $0["charging"]) }
        }
    }

    /// Events whose kind starts with one of `kindPrefixes` (kinds are stored as "NAME(code)"), oldest first.
    /// A day holds thousands of unrelated events (0x7C, battery, haptics…), so a kind filter keeps a 24 h
    /// wear lookback cheap and immune to a row cap. An empty prefix list returns nothing.
    public func events(deviceId: String, from: Int, to: Int, kindPrefixes: [String],
                       limit: Int) async throws -> [WhoopEvent] {
        let prefixes = kindPrefixes.filter { !$0.isEmpty }
        guard !prefixes.isEmpty else { return [] }
        return try syncRead { db in
            let likes = prefixes.map { _ in "kind LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            var args: [DatabaseValueConvertible] = [deviceId, from, to]
            for p in prefixes {
                let escaped = p.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                args.append(escaped + "%")
            }
            args.append(limit)
            return try Row.fetchAll(db, sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND ts >= ? AND ts <= ? AND (\(likes))
                ORDER BY ts ASC, kind ASC LIMIT ?
                """, arguments: StatementArguments(args))
                .map { row in
                    let json: String = row["payloadJSON"]
                    let payload = (try? JSONDecoder().decode(
                        [String: ParsedValue].self,
                        from: Data(json.utf8))) ?? [:]
                    return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
                }
                .filter { e in prefixes.contains { e.kind.hasPrefix($0) } }
        }
    }
}
