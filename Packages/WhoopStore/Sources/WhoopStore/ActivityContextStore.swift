import Foundation
import GRDB

// MARK: - Row types

/// One persisted stretch of constant behavioural context for a device.
///
/// Plain strings and numbers on purpose: `WhoopStore` knows nothing of the analytics taxonomy, so the
/// `StrandAnalytics` adapter (`ActivityContextInterval.storeRow` / `init(row:)`) owns the mapping to and
/// from the typed `ActivityClass` / `PostureClass` / ... enums. `[startTs, endTs)` is half-open unix seconds.
public struct ActivityContextIntervalRow: Equatable, Sendable {
    public var startTs: Int
    public var endTs: Int
    public var activityClass: String
    public var confidence: Double
    public var runnerUp: String?
    public var runnerUpConfidence: Double
    public var evidenceQuality: Double
    public var posture: String?
    public var locomotion: String?
    public var armBehavior: String?
    public var sleepState: String
    public var wearState: String
    public var intensity: Double?
    public var stepTicks: Int
    public var cadenceSpm: Double?
    public var hrSamples: Int
    public var hrMean: Double?
    public var hrMin: Int?
    public var hrMax: Int?
    public var hrSlope: Double?
    public var rmssd: Double?
    public var rrBeats: Int
    public var respRateBpm: Double?
    public var respBreaths: Int

    public init(startTs: Int, endTs: Int, activityClass: String, confidence: Double,
                runnerUp: String? = nil, runnerUpConfidence: Double = 0, evidenceQuality: Double = 0,
                posture: String? = nil, locomotion: String? = nil, armBehavior: String? = nil,
                sleepState: String = "unknown", wearState: String = "unknown",
                intensity: Double? = nil, stepTicks: Int = 0, cadenceSpm: Double? = nil,
                hrSamples: Int = 0, hrMean: Double? = nil, hrMin: Int? = nil, hrMax: Int? = nil,
                hrSlope: Double? = nil, rmssd: Double? = nil, rrBeats: Int = 0,
                respRateBpm: Double? = nil, respBreaths: Int = 0) {
        self.startTs = startTs
        self.endTs = endTs
        self.activityClass = activityClass
        self.confidence = confidence
        self.runnerUp = runnerUp
        self.runnerUpConfidence = runnerUpConfidence
        self.evidenceQuality = evidenceQuality
        self.posture = posture
        self.locomotion = locomotion
        self.armBehavior = armBehavior
        self.sleepState = sleepState
        self.wearState = wearState
        self.intensity = intensity
        self.stepTicks = stepTicks
        self.cadenceSpm = cadenceSpm
        self.hrSamples = hrSamples
        self.hrMean = hrMean
        self.hrMin = hrMin
        self.hrMax = hrMax
        self.hrSlope = hrSlope
        self.rmssd = rmssd
        self.rrBeats = rrBeats
        self.respRateBpm = respRateBpm
        self.respBreaths = respBreaths
    }

    public var durationSeconds: Int { endTs - startTs }
}

/// Ledger entry for a materialized day: which decoder / taxonomy produced its intervals and how far the
/// data reached, so a newer decoder, or a day that was still filling in, is recomputed.
public struct ActivityContextDayRow: Equatable, Sendable {
    /// Local `yyyy-MM-dd`; the same key `dailyMetric.day` uses.
    public var day: String
    /// Unix seconds of the local day's start (inclusive) and end (exclusive).
    public var dayStart: Int
    public var dayEnd: Int
    public var taxonomyVersion: String
    public var decoderVersion: String
    public var ontologyVersion: String
    /// Version of how the decoder's runs became intervals and per-interval statistics.
    public var intervalVersion: String
    /// One past the last second the decoder had data for; nil when the day had none.
    public var dataThrough: Int?
    public var observedSeconds: Int
    public var intervalCount: Int
    public var computedAt: Int

    public init(day: String, dayStart: Int, dayEnd: Int, taxonomyVersion: String, decoderVersion: String,
                ontologyVersion: String, intervalVersion: String, dataThrough: Int? = nil,
                observedSeconds: Int = 0, intervalCount: Int = 0, computedAt: Int) {
        self.day = day
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.taxonomyVersion = taxonomyVersion
        self.decoderVersion = decoderVersion
        self.ontologyVersion = ontologyVersion
        self.intervalVersion = intervalVersion
        self.dataThrough = dataThrough
        self.observedSeconds = observedSeconds
        self.intervalCount = intervalCount
        self.computedAt = computedAt
    }
}

/// Seconds a device spent in one canonical class on one materialized day (`activityContextDayClass`).
public struct ActivityContextDayClassRow: Equatable, Sendable {
    public var day: String
    public var activityClass: String
    public var seconds: Int
    public var intervals: Int

    public init(day: String, activityClass: String, seconds: Int, intervals: Int) {
        self.day = day
        self.activityClass = activityClass
        self.seconds = seconds
        self.intervals = intervals
    }
}

public enum ActivityContextStoreError: Error, Equatable, CustomStringConvertible {
    case invalidInterval(startTs: Int, endTs: Int)
    case intervalsOverlap(startTs: Int)
    case invalidDay(String)

    public var description: String {
        switch self {
        case let .invalidInterval(start, end):
            return "activity context interval [\(start), \(end)) is empty, inverted or longer than \(ActivityContextStore.maxIntervalSeconds) s"
        case let .intervalsOverlap(start):
            return "activity context intervals overlap at \(start)"
        case let .invalidDay(day):
            return "activity context day range is empty or inverted for \(day)"
        }
    }
}

public enum ActivityContextStore {
    /// Longest interval the store accepts. The range reads bound their scan by this, so it is a stored
    /// invariant and not a builder preference; the builder's own cap (900 s) sits well inside it.
    public static let maxIntervalSeconds = 3_600
}

// MARK: - Store

extension WhoopStore {
    /// Replace one day's activity context as a unit: delete the device's intervals in the day's range,
    /// insert the new ones, and upsert the day's ledger row — in a single transaction, so a reader sees
    /// the old day or the new one and a failure leaves the old one untouched.
    ///
    /// `intervals` must be sorted by `startTs`, non-overlapping and each `1...maxIntervalSeconds` long
    /// (anything else throws before the transaction touches data). Intervals are expected inside
    /// `[day.dayStart, day.dayEnd)`; the range that is cleared widens to cover any that are not, so a
    /// re-run can never collide with its own earlier output.
    ///
    /// A ledger row of another `dayStart` that overlaps this day's range is removed with it: after a time-zone
    /// change the same instants belong to a differently-bounded local day, and two ledger rows claiming them
    /// would make "which days are materialized" ambiguous. The intervals themselves were replaced above.
    public func replaceActivityContext(deviceId: String,
                                       day: ActivityContextDayRow,
                                       intervals: [ActivityContextIntervalRow]) async throws {
        guard day.dayEnd > day.dayStart else { throw ActivityContextStoreError.invalidDay(day.day) }
        var previousEnd = Int.min
        for row in intervals {
            guard row.endTs > row.startTs, row.endTs - row.startTs <= ActivityContextStore.maxIntervalSeconds else {
                throw ActivityContextStoreError.invalidInterval(startTs: row.startTs, endTs: row.endTs)
            }
            guard row.startTs >= previousEnd else {
                throw ActivityContextStoreError.intervalsOverlap(startTs: row.startTs)
            }
            previousEnd = row.endTs
        }
        let clearFrom = min(day.dayStart, intervals.first?.startTs ?? day.dayStart)
        let clearTo = max(day.dayEnd, (intervals.last?.startTs).map { $0 + 1 } ?? day.dayEnd)
        var ledger = day
        ledger.intervalCount = intervals.count

        try syncWrite { db in
            try db.execute(sql: """
                DELETE FROM activityContextInterval
                WHERE deviceId = ? AND startTs >= ? AND startTs < ?
                """, arguments: [deviceId, clearFrom, clearTo])
            try db.execute(sql: """
                DELETE FROM activityContextDay
                WHERE deviceId = ? AND dayStart != ? AND dayStart < ? AND dayEnd > ?
                """, arguments: [deviceId, ledger.dayStart, ledger.dayEnd, ledger.dayStart])
            for row in intervals {
                try db.execute(sql: Self.insertIntervalSQL, arguments: Self.arguments(deviceId: deviceId, row: row))
            }
            try db.execute(sql: """
                INSERT INTO activityContextDay
                    (deviceId, dayStart, day, dayEnd, taxonomyVersion, decoderVersion, ontologyVersion,
                     intervalVersion, dataThrough, observedSeconds, intervalCount, computedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, dayStart) DO UPDATE SET
                    day = excluded.day, dayEnd = excluded.dayEnd,
                    taxonomyVersion = excluded.taxonomyVersion, decoderVersion = excluded.decoderVersion,
                    ontologyVersion = excluded.ontologyVersion, intervalVersion = excluded.intervalVersion,
                    dataThrough = excluded.dataThrough, observedSeconds = excluded.observedSeconds,
                    intervalCount = excluded.intervalCount, computedAt = excluded.computedAt
                """, arguments: [deviceId, ledger.dayStart, ledger.day, ledger.dayEnd, ledger.taxonomyVersion,
                                 ledger.decoderVersion, ledger.ontologyVersion, ledger.intervalVersion,
                                 ledger.dataThrough, ledger.observedSeconds, ledger.intervalCount,
                                 ledger.computedAt])
        }
    }

    /// Intervals that overlap `[from, to)`, oldest first. An interval that begins before `from` but is
    /// still running at it is included — that is the one covering `from`.
    public func activityContextIntervals(deviceId: String, from: Int, to: Int) async throws -> [ActivityContextIntervalRow] {
        guard to > from else { return [] }
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.intervalColumns) FROM activityContextInterval
                WHERE deviceId = ? AND startTs >= ? AND startTs < ? AND endTs > ?
                ORDER BY startTs
                """, arguments: [deviceId, from - ActivityContextStore.maxIntervalSeconds, to, from])
                .map(Self.intervalRow(from:))
        }
    }

    /// The interval covering `ts`, or nil when `ts` falls in a gap or on a day not yet materialized.
    public func activityContextInterval(deviceId: String, at ts: Int) async throws -> ActivityContextIntervalRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT \(Self.intervalColumns) FROM activityContextInterval
                WHERE deviceId = ? AND startTs <= ? AND startTs > ? AND endTs > ?
                ORDER BY startTs DESC LIMIT 1
                """, arguments: [deviceId, ts, ts - ActivityContextStore.maxIntervalSeconds, ts])
                .map(Self.intervalRow(from:))
        }
    }

    /// Intervals of one canonical class over `[from, to)`, oldest first ("every walking stretch this week").
    public func activityContextIntervals(deviceId: String, activityClass: String,
                                         from: Int, to: Int) async throws -> [ActivityContextIntervalRow] {
        guard to > from else { return [] }
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.intervalColumns) FROM activityContextInterval
                WHERE deviceId = ? AND activityClass = ? AND startTs >= ? AND startTs < ? AND endTs > ?
                ORDER BY startTs
                """, arguments: [deviceId, activityClass, from - ActivityContextStore.maxIntervalSeconds, to, from])
                .map(Self.intervalRow(from:))
        }
    }

    /// Ledger rows for days whose `day` key is in `from...to` (inclusive `yyyy-MM-dd`), oldest first.
    public func activityContextDays(deviceId: String, from: String, to: String) async throws -> [ActivityContextDayRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, dayStart, dayEnd, taxonomyVersion, decoderVersion, ontologyVersion, intervalVersion,
                       dataThrough, observedSeconds, intervalCount, computedAt
                FROM activityContextDay WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY dayStart
                """, arguments: [deviceId, from, to]).map(Self.dayRow(from:))
        }
    }

    /// The ledger row for one local day, or nil when it has not been materialized.
    public func activityContextDay(deviceId: String, day: String) async throws -> ActivityContextDayRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT day, dayStart, dayEnd, taxonomyVersion, decoderVersion, ontologyVersion, intervalVersion,
                       dataThrough, observedSeconds, intervalCount, computedAt
                FROM activityContextDay WHERE deviceId = ? AND day = ?
                ORDER BY dayStart DESC LIMIT 1
                """, arguments: [deviceId, day]).map(Self.dayRow(from:))
        }
    }

    /// Seconds per canonical class for materialized days in `from...to`, via `activityContextDayClass`.
    public func activityContextDayClassSeconds(deviceId: String, from: String, to: String) async throws -> [ActivityContextDayClassRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, activityClass, seconds, intervals FROM \(ActivityContextViews.dayClassView)
                WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY day, activityClass
                """, arguments: [deviceId, from, to]).map {
                ActivityContextDayClassRow(day: $0["day"], activityClass: $0["activityClass"],
                                           seconds: $0["seconds"], intervals: $0["intervals"])
            }
        }
    }

    /// Forget a device's activity context from `fromDayStart` onward (or entirely when nil), ledger included,
    /// so the materializer re-derives it. For a decoder / taxonomy change and for tests; `deleteAllData`
    /// clears both tables through `DeviceRegistryStore.deviceScopedTables`.
    public func clearActivityContext(deviceId: String, fromDayStart: Int? = nil) async throws {
        try syncWrite { db in
            let floor = fromDayStart ?? Int.min
            try db.execute(sql: "DELETE FROM activityContextInterval WHERE deviceId = ? AND startTs >= ?",
                           arguments: [deviceId, floor])
            try db.execute(sql: "DELETE FROM activityContextDay WHERE deviceId = ? AND dayStart >= ?",
                           arguments: [deviceId, floor])
        }
    }

    /// Forget a device's activity context inside `[from, to)`: the intervals that start there and every ledger
    /// row whose day overlaps the range. Used when another device now owns those days, so the old owner's
    /// rows are not left behind describing time they no longer account for.
    public func clearActivityContext(deviceId: String, from: Int, to: Int) async throws {
        guard to > from else { return }
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM activityContextInterval WHERE deviceId = ? AND startTs >= ? AND startTs < ?",
                           arguments: [deviceId, from, to])
            try db.execute(sql: "DELETE FROM activityContextDay WHERE deviceId = ? AND dayStart < ? AND dayEnd > ?",
                           arguments: [deviceId, to, from])
        }
    }

    /// The newest heart-rate second in `[from, to)`, or nil when the device has none there. One index seek on
    /// the stream's key, unlike `hrFingerprint`, whose COUNT walks the whole range: the materializer asks this
    /// about every day in its horizon on every pass.
    public func newestHeartRateTs(deviceId: String, from: Int, to: Int) async throws -> Int? {
        guard to > from else { return nil }
        return try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT MAX(ts) FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts < ?",
                             arguments: [deviceId, from, to])
        }
    }

    // MARK: Row mapping

    private static let intervalColumns = """
        startTs, endTs, activityClass, confidence, runnerUp, runnerUpConfidence, evidenceQuality, posture, \
        locomotion, armBehavior, sleepState, wearState, intensity, stepTicks, cadenceSpm, hrSamples, hrMean, \
        hrMin, hrMax, hrSlope, rmssd, rrBeats, respRateBpm, respBreaths
        """

    private static let insertIntervalSQL = """
        INSERT INTO activityContextInterval
            (deviceId, startTs, endTs, activityClass, confidence, runnerUp, runnerUpConfidence, evidenceQuality,
             posture, locomotion, armBehavior, sleepState, wearState, intensity, stepTicks, cadenceSpm,
             hrSamples, hrMean, hrMin, hrMax, hrSlope, rmssd, rrBeats, respRateBpm, respBreaths)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    private static func arguments(deviceId: String, row r: ActivityContextIntervalRow) -> StatementArguments {
        [deviceId, r.startTs, r.endTs, r.activityClass, r.confidence, r.runnerUp, r.runnerUpConfidence,
         r.evidenceQuality, r.posture, r.locomotion, r.armBehavior, r.sleepState, r.wearState, r.intensity,
         r.stepTicks, r.cadenceSpm, r.hrSamples, r.hrMean, r.hrMin, r.hrMax, r.hrSlope, r.rmssd, r.rrBeats,
         r.respRateBpm, r.respBreaths]
    }

    private static func intervalRow(from row: Row) -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(
            startTs: row["startTs"], endTs: row["endTs"], activityClass: row["activityClass"],
            confidence: row["confidence"], runnerUp: row["runnerUp"],
            runnerUpConfidence: row["runnerUpConfidence"], evidenceQuality: row["evidenceQuality"],
            posture: row["posture"], locomotion: row["locomotion"], armBehavior: row["armBehavior"],
            sleepState: row["sleepState"], wearState: row["wearState"], intensity: row["intensity"],
            stepTicks: row["stepTicks"], cadenceSpm: row["cadenceSpm"], hrSamples: row["hrSamples"],
            hrMean: row["hrMean"], hrMin: row["hrMin"], hrMax: row["hrMax"], hrSlope: row["hrSlope"],
            rmssd: row["rmssd"], rrBeats: row["rrBeats"], respRateBpm: row["respRateBpm"],
            respBreaths: row["respBreaths"])
    }

    private static func dayRow(from row: Row) -> ActivityContextDayRow {
        ActivityContextDayRow(
            day: row["day"], dayStart: row["dayStart"], dayEnd: row["dayEnd"],
            taxonomyVersion: row["taxonomyVersion"], decoderVersion: row["decoderVersion"],
            ontologyVersion: row["ontologyVersion"], intervalVersion: row["intervalVersion"],
            dataThrough: row["dataThrough"],
            observedSeconds: row["observedSeconds"], intervalCount: row["intervalCount"],
            computedAt: row["computedAt"])
    }
}
