import Foundation
import GRDB

/// One manual spot HRV reading (`spotHrvReading`, v50): the capture's own half-open `[startTs, endTs)` and
/// its support, so it joins activity context and other measurements by time, and a second reading the same
/// day is a second row instead of overwriting the first.
///
/// The `ctx*` fields are the stored activity context over the capture when the phone had already
/// materialized it at save time (nil otherwise). They are a convenience copy taken at capture: the canonical
/// association is still the time join against `activityContextInterval`, which a later re-derivation updates.
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
    public var ctxClass: String?
    public var ctxPosture: String?
    public var ctxConfidence: Double?
    public var ctxSleep: String?
    public var ctxWear: String?
    public var ctxDecoderVersion: String?
    public var createdAt: Int

    public init(startTs: Int, endTs: Int, rmssd: Double, sdnn: Double? = nil, meanNN: Double? = nil,
                cleanBeats: Int, inputBeats: Int, source: String, methodVersion: String,
                ctxClass: String? = nil, ctxPosture: String? = nil, ctxConfidence: Double? = nil,
                ctxSleep: String? = nil, ctxWear: String? = nil, ctxDecoderVersion: String? = nil,
                createdAt: Int) {
        self.startTs = startTs; self.endTs = endTs; self.rmssd = rmssd; self.sdnn = sdnn; self.meanNN = meanNN
        self.cleanBeats = cleanBeats; self.inputBeats = inputBeats; self.source = source
        self.methodVersion = methodVersion; self.ctxClass = ctxClass; self.ctxPosture = ctxPosture
        self.ctxConfidence = ctxConfidence; self.ctxSleep = ctxSleep; self.ctxWear = ctxWear
        self.ctxDecoderVersion = ctxDecoderVersion; self.createdAt = createdAt
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
                     ctxClass, ctxPosture, ctxConfidence, ctxSleep, ctxWear, ctxDecoderVersion, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [deviceId, r.startTs, r.endTs, r.rmssd, r.sdnn, r.meanNN, r.cleanBeats, r.inputBeats,
                                 r.source, r.methodVersion, r.ctxClass, r.ctxPosture, r.ctxConfidence, r.ctxSleep,
                                 r.ctxWear, r.ctxDecoderVersion, r.createdAt])
        }
    }

    /// Spot readings that START inside `[from, to)`, oldest first.
    public func spotHrvReadings(deviceId: String, from: Int, to: Int) async throws -> [SpotHrvReadingRow] {
        guard to > from else { return [] }
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, rmssd, sdnn, meanNN, cleanBeats, inputBeats, source, methodVersion,
                       ctxClass, ctxPosture, ctxConfidence, ctxSleep, ctxWear, ctxDecoderVersion, createdAt
                FROM spotHrvReading WHERE deviceId = ? AND startTs >= ? AND startTs < ?
                ORDER BY startTs
                """, arguments: [deviceId, from, to]).map {
                SpotHrvReadingRow(startTs: $0["startTs"], endTs: $0["endTs"], rmssd: $0["rmssd"], sdnn: $0["sdnn"],
                                  meanNN: $0["meanNN"], cleanBeats: $0["cleanBeats"], inputBeats: $0["inputBeats"],
                                  source: $0["source"], methodVersion: $0["methodVersion"],
                                  ctxClass: $0["ctxClass"], ctxPosture: $0["ctxPosture"],
                                  ctxConfidence: $0["ctxConfidence"], ctxSleep: $0["ctxSleep"],
                                  ctxWear: $0["ctxWear"], ctxDecoderVersion: $0["ctxDecoderVersion"],
                                  createdAt: $0["createdAt"])
            }
        }
    }
}
