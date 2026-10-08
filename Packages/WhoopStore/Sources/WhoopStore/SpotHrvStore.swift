import Foundation
import GRDB

/// One manual spot HRV reading (`spotHrvReading`, v50): the capture's own half-open `[startTs, endTs)` and
/// its support, so it joins activity context and other measurements by time, and a second reading the same
/// day is a second row instead of overwriting the first.
///
/// The row holds no copy of the activity context. A capture is saved on the live day, whose context is
/// provisional (and usually not yet decoded that far), so any label copied at save time would go stale as the day
/// is derived again. Its context is the time join instead: `spotHrvReadingCtx` (`ActivityContextViews`) at the
/// capture's start, with `ctxProvisional`, or the stored intervals over `[startTs, endTs)`.
public struct SpotHrvReadingRow: Equatable, Sendable {
    public var startTs: Int
    public var endTs: Int
    public var rmssd: Double
    public var sdnn: Double?
    public var meanNN: Double?
    /// Beats that survived cleaning, and beats collected.
    public var cleanBeats: Int
    public var inputBeats: Int
    /// `manual-hrv` for the in-app 60 s reading.
    public var source: String
    /// The analysis that produced `rmssd` (cleaning rules + statistic), so readings from different methods
    /// are never compared as one regime.
    public var methodVersion: String
    public var createdAt: Int

    public init(startTs: Int, endTs: Int, rmssd: Double, sdnn: Double? = nil, meanNN: Double? = nil,
                cleanBeats: Int, inputBeats: Int, source: String, methodVersion: String, createdAt: Int) {
        self.startTs = startTs; self.endTs = endTs; self.rmssd = rmssd; self.sdnn = sdnn; self.meanNN = meanNN
        self.cleanBeats = cleanBeats; self.inputBeats = inputBeats; self.source = source
        self.methodVersion = methodVersion; self.createdAt = createdAt
    }
}

extension WhoopStore {
    /// Save one spot reading under the strap that measured it. Keyed by `(deviceId, startTs)`: saving the same
    /// capture again (a double tap on Save) replaces it, a later capture is a new row.
    public func saveSpotHrvReading(_ r: SpotHrvReadingRow, deviceId: String) async throws {
        guard r.endTs > r.startTs else { throw ActivityContextStoreError.invalidInterval(startTs: r.startTs, endTs: r.endTs) }
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO spotHrvReading
                    (deviceId, startTs, endTs, rmssd, sdnn, meanNN, cleanBeats, inputBeats, source, methodVersion,
                     createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [deviceId, r.startTs, r.endTs, r.rmssd, r.sdnn, r.meanNN, r.cleanBeats, r.inputBeats,
                                 r.source, r.methodVersion, r.createdAt])
        }
    }

    /// Spot readings that START inside `[from, to)`, oldest first.
    public func spotHrvReadings(deviceId: String, from: Int, to: Int) async throws -> [SpotHrvReadingRow] {
        guard to > from else { return [] }
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, rmssd, sdnn, meanNN, cleanBeats, inputBeats, source, methodVersion, createdAt
                FROM spotHrvReading WHERE deviceId = ? AND startTs >= ? AND startTs < ?
                ORDER BY startTs
                """, arguments: [deviceId, from, to]).map {
                SpotHrvReadingRow(startTs: $0["startTs"], endTs: $0["endTs"], rmssd: $0["rmssd"], sdnn: $0["sdnn"],
                                  meanNN: $0["meanNN"], cleanBeats: $0["cleanBeats"], inputBeats: $0["inputBeats"],
                                  source: $0["source"], methodVersion: $0["methodVersion"], createdAt: $0["createdAt"])
            }
        }
    }
}
