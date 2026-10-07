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
    /// Sum of squared successive NN differences behind `rmssd` (ms²), UNROUNDED; 0 when `rmssd` is nil or
    /// the row predates this column (v49). See `ActivityContextInterval.rrDiffSqSumMs2`.
    public var rrDiffSqSumMs2: Double
    /// Successive-difference pairs behind `rrDiffSqSumMs2`; 0 when `rmssd` is nil or the row predates v49.
    public var rrDiffCount: Int
    public var respRateBpm: Double?
    public var respBreaths: Int
    // v50: run-level fields the interval builder carries through. nil / 0 reads as "not recorded" (a row
    // written before v50, or by a builder that does not fill the field yet).
    /// Inside the night's in-bed window (lying awake in bed is not the same context as lying on a couch).
    public var inBed: Bool?
    /// The decoder's overall uncertainty over the interval, 0...1.
    public var uncertainty: Double?
    /// The evidence experts that shaped the interval, comma-separated codes (e.g. `hart,eldernet`).
    public var experts: String?
    /// Transition events folded inside the interval.
    public var transitionCount: Int
    /// Seconds of shorter fragments absorbed into the interval.
    public var absorbedSeconds: Int
    /// Seconds of no data immediately before the interval (nil when unknown).
    public var precededByGapS: Int?
    /// Seconds after a change of posture before the interval is settled (nil when not applicable).
    public var settlingSeconds: Int?

    public init(startTs: Int, endTs: Int, activityClass: String, confidence: Double,
                runnerUp: String? = nil, runnerUpConfidence: Double = 0, evidenceQuality: Double = 0,
                posture: String? = nil, locomotion: String? = nil, armBehavior: String? = nil,
                sleepState: String = "unknown", wearState: String = "unknown",
                intensity: Double? = nil, stepTicks: Int = 0, cadenceSpm: Double? = nil,
                hrSamples: Int = 0, hrMean: Double? = nil, hrMin: Int? = nil, hrMax: Int? = nil,
                hrSlope: Double? = nil, rmssd: Double? = nil, rrBeats: Int = 0,
                rrDiffSqSumMs2: Double = 0, rrDiffCount: Int = 0,
                respRateBpm: Double? = nil, respBreaths: Int = 0,
                inBed: Bool? = nil, uncertainty: Double? = nil, experts: String? = nil,
                transitionCount: Int = 0, absorbedSeconds: Int = 0, precededByGapS: Int? = nil,
                settlingSeconds: Int? = nil) {
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
        self.rrDiffSqSumMs2 = rrDiffSqSumMs2
        self.rrDiffCount = rrDiffCount
        self.respRateBpm = respRateBpm
        self.respBreaths = respBreaths
        self.inBed = inBed
        self.uncertainty = uncertainty
        self.experts = experts
        self.transitionCount = transitionCount
        self.absorbedSeconds = absorbedSeconds
        self.precededByGapS = precededByGapS
        self.settlingSeconds = settlingSeconds
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
    // v50 provenance. nil on a row written before v50 ("derived before provenance was recorded").
    /// Feature schema of the decoder input (`ActivityStateVersions.featureSchema`).
    public var featureSchema: String?
    /// The short-window motion encoder whose windows shaped the day (HART today), when any did.
    public var encoderId: String?
    public var encoderVersion: String?
    /// Inertia-1 / ElderNet evidence stamps (`ActivityStateVersions.motionHeads` / `.gaitQuality`).
    public var motionHeads: String?
    public var gaitQuality: String?
    /// The decoder config's tag (HR reference, gait lane and its server mode, personal profile).
    public var configTag: String?
    /// Fingerprint of the day's whole decode input when it was derived; compared on later passes and launches.
    public var inputFingerprint: String?
    /// `provisional` while the day was live or its sleep not settled when it was derived, else `final`.
    public var finality: String
    /// `causal`: every second was decoded from its past only (the phone's decoder never looks ahead).
    public var decodeMode: String
    /// Whether time outside logged sleep was read as awake (a finished day) or unknown (a live one).
    public var sleepKnownOutsideSessions: Bool?

    public static let provisional = "provisional"
    public static let final = "final"
    public static let causal = "causal"

    public var isFinal: Bool { finality == Self.final }

    public init(day: String, dayStart: Int, dayEnd: Int, taxonomyVersion: String, decoderVersion: String,
                ontologyVersion: String, intervalVersion: String, dataThrough: Int? = nil,
                observedSeconds: Int = 0, intervalCount: Int = 0, computedAt: Int,
                featureSchema: String? = nil, encoderId: String? = nil, encoderVersion: String? = nil,
                motionHeads: String? = nil, gaitQuality: String? = nil, configTag: String? = nil,
                inputFingerprint: String? = nil, finality: String = ActivityContextDayRow.provisional,
                decodeMode: String = ActivityContextDayRow.causal, sleepKnownOutsideSessions: Bool? = nil) {
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
        self.featureSchema = featureSchema
        self.encoderId = encoderId
        self.encoderVersion = encoderVersion
        self.motionHeads = motionHeads
        self.gaitQuality = gaitQuality
        self.configTag = configTag
        self.inputFingerprint = inputFingerprint
        self.finality = finality
        self.decodeMode = decodeMode
        self.sleepKnownOutsideSessions = sleepKnownOutsideSessions
    }
}

/// One of the decoder's typed transition events (`activityContextTransition`), kept durably beside the
/// intervals so a short real change of position survives the interval builder's smoothing.
public struct ActivityContextTransitionRow: Equatable, Sendable {
    /// Unix seconds the decoder flagged the event.
    public var ts: Int
    /// `ActivityTransitionKind` code, e.g. `sit_to_stand_like`.
    public var kind: String
    public var probability: Double
    /// Back-dated start of the movement, when the decoder reports one.
    public var onsetTs: Int?
    /// Which part of the decoder flagged it, when reported.
    public var source: String?
    public var decoderVersion: String

    public init(ts: Int, kind: String, probability: Double, onsetTs: Int? = nil, source: String? = nil,
                decoderVersion: String) {
        self.ts = ts; self.kind = kind; self.probability = probability
        self.onsetTs = onsetTs; self.source = source; self.decoderVersion = decoderVersion
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
    case transitionOutsideDay(ts: Int)

    public var description: String {
        switch self {
        case let .invalidInterval(start, end):
            return "activity context interval [\(start), \(end)) is empty, inverted or longer than \(ActivityContextStore.maxIntervalSeconds) s"
        case let .intervalsOverlap(start):
            return "activity context intervals overlap at \(start)"
        case let .invalidDay(day):
            return "activity context day range is empty or inverted for \(day)"
        case let .transitionOutsideDay(ts):
            return "activity context transition at \(ts) lies outside the day being replaced"
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
    /// Replace one day's activity context as a unit: delete the device's intervals and transition events in
    /// the day's range, insert the new ones, and upsert the day's ledger row — in a single transaction, so a
    /// reader sees the old day or the new one and a failure leaves the old one untouched.
    ///
    /// `intervals` must be sorted by `startTs`, non-overlapping and each `1...maxIntervalSeconds` long
    /// (anything else throws before the transaction touches data). Intervals are expected inside
    /// `[day.dayStart, day.dayEnd)`; the range that is cleared widens to cover any that are not, so a
    /// re-run can never collide with its own earlier output. `transitions` are the decoder's events for the
    /// same day; any outside the cleared range throw too, so one day's write can never touch another's.
    ///
    /// A ledger row of another `dayStart` that overlaps this day's range is removed with it: after a time-zone
    /// change the same instants belong to a differently-bounded local day, and two ledger rows claiming them
    /// would make "which days are materialized" ambiguous. The intervals themselves were replaced above.
    ///
    /// `otherIds` hands the day over: each one's intervals, events and ledger rows inside the day's range are
    /// deleted in the SAME transaction, so the day is never described twice (the new owner's rows and an old
    /// owner's) and never by nobody (the old owner's cleared, the new owner's write failed).
    public func replaceActivityContext(deviceId: String,
                                       day: ActivityContextDayRow,
                                       intervals: [ActivityContextIntervalRow],
                                       transitions: [ActivityContextTransitionRow] = [],
                                       clearingOtherIds otherIds: [String] = []) async throws {
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
        for event in transitions where event.ts < clearFrom || event.ts >= clearTo {
            throw ActivityContextStoreError.transitionOutsideDay(ts: event.ts)
        }
        var ledger = day
        ledger.intervalCount = intervals.count
        let others = otherIds.filter { $0 != deviceId }

        try syncWrite { db in
            for id in others {
                try Self.clear(db, deviceId: id, from: day.dayStart, to: day.dayEnd)
            }
            try db.execute(sql: """
                DELETE FROM activityContextInterval
                WHERE deviceId = ? AND startTs >= ? AND startTs < ?
                """, arguments: [deviceId, clearFrom, clearTo])
            try db.execute(sql: """
                DELETE FROM activityContextTransition
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                """, arguments: [deviceId, clearFrom, clearTo])
            try db.execute(sql: """
                DELETE FROM activityContextDay
                WHERE deviceId = ? AND dayStart != ? AND dayStart < ? AND dayEnd > ?
                """, arguments: [deviceId, ledger.dayStart, ledger.dayEnd, ledger.dayStart])
            for row in intervals {
                try db.execute(sql: Self.insertIntervalSQL, arguments: Self.arguments(deviceId: deviceId, row: row))
            }
            for event in transitions {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO activityContextTransition
                        (deviceId, ts, kind, probability, onsetTs, source, decoderVersion)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [deviceId, event.ts, event.kind, event.probability, event.onsetTs,
                                     event.source, event.decoderVersion])
            }
            try db.execute(sql: """
                INSERT INTO activityContextDay
                    (deviceId, dayStart, day, dayEnd, taxonomyVersion, decoderVersion, ontologyVersion,
                     intervalVersion, dataThrough, observedSeconds, intervalCount, computedAt,
                     featureSchema, encoderId, encoderVersion, motionHeads, gaitQuality, configTag,
                     inputFingerprint, finality, decodeMode, sleepKnownOutsideSessions)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, dayStart) DO UPDATE SET
                    day = excluded.day, dayEnd = excluded.dayEnd,
                    taxonomyVersion = excluded.taxonomyVersion, decoderVersion = excluded.decoderVersion,
                    ontologyVersion = excluded.ontologyVersion, intervalVersion = excluded.intervalVersion,
                    dataThrough = excluded.dataThrough, observedSeconds = excluded.observedSeconds,
                    intervalCount = excluded.intervalCount, computedAt = excluded.computedAt,
                    featureSchema = excluded.featureSchema, encoderId = excluded.encoderId,
                    encoderVersion = excluded.encoderVersion, motionHeads = excluded.motionHeads,
                    gaitQuality = excluded.gaitQuality, configTag = excluded.configTag,
                    inputFingerprint = excluded.inputFingerprint, finality = excluded.finality,
                    decodeMode = excluded.decodeMode, sleepKnownOutsideSessions = excluded.sleepKnownOutsideSessions
                """, arguments: [deviceId, ledger.dayStart, ledger.day, ledger.dayEnd, ledger.taxonomyVersion,
                                 ledger.decoderVersion, ledger.ontologyVersion, ledger.intervalVersion,
                                 ledger.dataThrough, ledger.observedSeconds, ledger.intervalCount,
                                 ledger.computedAt, ledger.featureSchema, ledger.encoderId,
                                 ledger.encoderVersion, ledger.motionHeads, ledger.gaitQuality,
                                 ledger.configTag, ledger.inputFingerprint, ledger.finality,
                                 ledger.decodeMode, ledger.sleepKnownOutsideSessions])
        }
    }

    /// Record what a pass found for a day whose stored context is already the current decode: the input
    /// fingerprint it was checked against and whether the day is now final. Nothing else in the row, and no
    /// interval, changes. Returns false when the device has no ledger row for `dayStart`.
    @discardableResult
    public func updateActivityContextDayStatus(deviceId: String, dayStart: Int, inputFingerprint: String?,
                                               finality: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE activityContextDay SET inputFingerprint = ?, finality = ?
                WHERE deviceId = ? AND dayStart = ?
                """, arguments: [inputFingerprint, finality, deviceId, dayStart])
            return db.changesCount > 0
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
                SELECT \(Self.dayColumns)
                FROM activityContextDay WHERE deviceId = ? AND day >= ? AND day <= ?
                ORDER BY dayStart
                """, arguments: [deviceId, from, to]).map(Self.dayRow(from:))
        }
    }

    /// The ledger row for one local day, or nil when it has not been materialized.
    public func activityContextDay(deviceId: String, day: String) async throws -> ActivityContextDayRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT \(Self.dayColumns)
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

    /// Forget a device's activity context from `fromDayStart` onward (or entirely when nil), ledger and
    /// transition events included, so the materializer re-derives it. For a decoder / taxonomy change and for
    /// tests; `deleteAllData` clears every table through `DeviceRegistryStore.deviceScopedTables`.
    public func clearActivityContext(deviceId: String, fromDayStart: Int? = nil) async throws {
        try syncWrite { db in
            let floor = fromDayStart ?? Int.min
            try db.execute(sql: "DELETE FROM activityContextInterval WHERE deviceId = ? AND startTs >= ?",
                           arguments: [deviceId, floor])
            try db.execute(sql: "DELETE FROM activityContextTransition WHERE deviceId = ? AND ts >= ?",
                           arguments: [deviceId, floor])
            try db.execute(sql: "DELETE FROM activityContextDay WHERE deviceId = ? AND dayStart >= ?",
                           arguments: [deviceId, floor])
        }
    }

    /// Forget a device's activity context inside `[from, to)`: the intervals and transition events that start
    /// there and every ledger row whose day overlaps the range. Used when another device now owns those days,
    /// so the old owner's rows are not left behind describing time they no longer account for.
    public func clearActivityContext(deviceId: String, from: Int, to: Int) async throws {
        try await clearActivityContext(deviceIds: [deviceId], from: from, to: to)
    }

    /// `clearActivityContext(deviceId:from:to:)` for several ids in ONE transaction: a day that lost its heart
    /// rate (or its owner) is forgotten under every id at once or not at all.
    public func clearActivityContext(deviceIds: [String], from: Int, to: Int) async throws {
        guard to > from, !deviceIds.isEmpty else { return }
        try syncWrite { db in
            for id in deviceIds { try Self.clear(db, deviceId: id, from: from, to: to) }
        }
    }

    private static func clear(_ db: Database, deviceId: String, from: Int, to: Int) throws {
        try db.execute(sql: "DELETE FROM activityContextInterval WHERE deviceId = ? AND startTs >= ? AND startTs < ?",
                       arguments: [deviceId, from, to])
        try db.execute(sql: "DELETE FROM activityContextTransition WHERE deviceId = ? AND ts >= ? AND ts < ?",
                       arguments: [deviceId, from, to])
        try db.execute(sql: "DELETE FROM activityContextDay WHERE deviceId = ? AND dayStart < ? AND dayEnd > ?",
                       arguments: [deviceId, to, from])
    }

    // MARK: Transition events

    /// The decoder's transition events flagged inside `[from, to)`, oldest first.
    public func activityContextTransitions(deviceId: String, from: Int, to: Int) async throws -> [ActivityContextTransitionRow] {
        guard to > from else { return [] }
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, kind, probability, onsetTs, source, decoderVersion FROM activityContextTransition
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts, kind
                """, arguments: [deviceId, from, to]).map {
                ActivityContextTransitionRow(ts: $0["ts"], kind: $0["kind"], probability: $0["probability"],
                                             onsetTs: $0["onsetTs"], source: $0["source"],
                                             decoderVersion: $0["decoderVersion"])
            }
        }
    }

    /// How many transition events fall inside `[startTs, endTs)` — "did the wearer change position during this
    /// interval / measurement window". `minProbability` drops weak flags.
    public func activityContextTransitionCount(deviceId: String, from startTs: Int, to endTs: Int,
                                               minProbability: Double = 0) async throws -> Int {
        guard endTs > startTs else { return 0 }
        return try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM activityContextTransition
                WHERE deviceId = ? AND ts >= ? AND ts < ? AND probability >= ?
                """, arguments: [deviceId, startTs, endTs, minProbability]) ?? 0
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

    // MARK: Decode-input witness

    /// Cheap witness over everything the phone's day decode reads from this database for `[from, to)`, so the
    /// materializer can tell, without decoding, that a day it derived earlier (in this launch or a previous one)
    /// now has different input.
    ///
    /// - `streamIds`: the raw ids the day's streams are read under. Each contributes its
    ///   `dayStreamFingerprint` (PPG HR, R-R, motion, steps, skin temperature, band sleep, events), its measured
    ///   heart rate (`hrSample`, which that witness does not count) and the wrist events the decode reaches back
    ///   `eventReachBackS` for (a WRIST_OFF before midnight opens a span that runs into the day).
    /// - `sleepIds`: the ids sleep sessions are read under (raw and computed). Every session overlapping the day
    ///   is folded with its bounds, adjusted start, edit flags and staging, so a re-staged or edited night counts.
    /// - `workoutIds`: the ids workouts are read under. Bounds and sport.
    ///
    /// COUNT/MAX index walks for the streams and a handful of rows for sleep and workouts; nothing is decoded.
    /// Opaque: only ever compared to an earlier value of itself.
    public func activityContextInputFingerprint(streamIds: [String], sleepIds: [String], workoutIds: [String],
                                                from: Int, to: Int, eventReachBackS: Int = 6 * 3_600) async throws -> String {
        guard to > from else { return "" }
        var parts: [String] = []
        for id in streamIds {
            let streams = try await dayStreamFingerprint(deviceId: id, from: from, to: to)
            let extra: String = try syncRead { db in
                let hr = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts < ?
                    """, arguments: [id, from, to])
                let ev = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM event
                    WHERE deviceId = ? AND ts >= ? AND ts < ?
                    """, arguments: [id, from - eventReachBackS, from])
                return "h\(hr?["c"] as Int? ?? 0):\(hr?["m"] as Int? ?? 0)|eb\(ev?["c"] as Int? ?? 0):\(ev?["m"] as Int? ?? 0)"
            }
            parts.append("\(id)=\(streams)|\(extra)")
        }
        let sleepDigest: UInt64 = try syncRead { db in
            var h = Self.fnvOffset
            for id in sleepIds {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT startTs, endTs, startTsAdjusted, userEdited, stagingSparse, stagesJSON FROM sleepSession
                    WHERE deviceId = ? AND startTs >= ? AND startTs < ?
                    ORDER BY startTs
                    """, arguments: [id, from - 2 * 86_400, to + 86_400])
                for row in rows {
                    let start: Int = row["startTs"], end: Int = row["endTs"]
                    let adjusted: Int? = row["startTsAdjusted"]
                    guard end > from, min(start, adjusted ?? start) < to else { continue }
                    Self.fold("\(id)|\(start)|\(end)|\(adjusted ?? -1)|\(row["userEdited"] as Int? ?? 0)|"
                              + "\(row["stagingSparse"] as Int? ?? -1)|\(row["stagesJSON"] as String? ?? "-");", into: &h)
                }
            }
            return h
        }
        let workoutDigest: UInt64 = try syncRead { db in
            var h = Self.fnvOffset
            for id in workoutIds {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT startTs, endTs, sport FROM workout
                    WHERE deviceId = ? AND startTs >= ? AND startTs < ?
                    ORDER BY startTs, sport
                    """, arguments: [id, from - 2 * 86_400, to])
                for row in rows {
                    let start: Int = row["startTs"], end: Int = row["endTs"]
                    guard end > from else { continue }
                    Self.fold("\(id)|\(start)|\(end)|\(row["sport"] as String);", into: &h)
                }
            }
            return h
        }
        return "acx1|" + parts.joined(separator: "||") + "|sl\(String(sleepDigest, radix: 16))|wk\(String(workoutDigest, radix: 16))"
    }

    private static let fnvOffset: UInt64 = 0xcbf29ce484222325

    private static func fold(_ text: String, into h: inout UInt64) {
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    }

    // MARK: Row mapping

    private static let intervalColumns = """
        startTs, endTs, activityClass, confidence, runnerUp, runnerUpConfidence, evidenceQuality, posture, \
        locomotion, armBehavior, sleepState, wearState, intensity, stepTicks, cadenceSpm, hrSamples, hrMean, \
        hrMin, hrMax, hrSlope, rmssd, rrBeats, rrDiffSqSumMs2, rrDiffCount, respRateBpm, respBreaths, \
        inBed, uncertainty, experts, transitionCount, absorbedSeconds, precededByGapS, settlingSeconds
        """

    private static let dayColumns = """
        day, dayStart, dayEnd, taxonomyVersion, decoderVersion, ontologyVersion, intervalVersion, \
        dataThrough, observedSeconds, intervalCount, computedAt, featureSchema, encoderId, encoderVersion, \
        motionHeads, gaitQuality, configTag, inputFingerprint, finality, decodeMode, sleepKnownOutsideSessions
        """

    private static let insertIntervalSQL = """
        INSERT INTO activityContextInterval
            (deviceId, startTs, endTs, activityClass, confidence, runnerUp, runnerUpConfidence, evidenceQuality,
             posture, locomotion, armBehavior, sleepState, wearState, intensity, stepTicks, cadenceSpm,
             hrSamples, hrMean, hrMin, hrMax, hrSlope, rmssd, rrBeats, rrDiffSqSumMs2, rrDiffCount,
             respRateBpm, respBreaths, inBed, uncertainty, experts, transitionCount, absorbedSeconds,
             precededByGapS, settlingSeconds)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    private static func arguments(deviceId: String, row r: ActivityContextIntervalRow) -> StatementArguments {
        [deviceId, r.startTs, r.endTs, r.activityClass, r.confidence, r.runnerUp, r.runnerUpConfidence,
         r.evidenceQuality, r.posture, r.locomotion, r.armBehavior, r.sleepState, r.wearState, r.intensity,
         r.stepTicks, r.cadenceSpm, r.hrSamples, r.hrMean, r.hrMin, r.hrMax, r.hrSlope, r.rmssd, r.rrBeats,
         r.rrDiffSqSumMs2, r.rrDiffCount, r.respRateBpm, r.respBreaths, r.inBed, r.uncertainty, r.experts,
         r.transitionCount, r.absorbedSeconds, r.precededByGapS, r.settlingSeconds]
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
            rmssd: row["rmssd"], rrBeats: row["rrBeats"],
            rrDiffSqSumMs2: row["rrDiffSqSumMs2"] ?? 0, rrDiffCount: row["rrDiffCount"] ?? 0,
            respRateBpm: row["respRateBpm"], respBreaths: row["respBreaths"],
            inBed: row["inBed"], uncertainty: row["uncertainty"], experts: row["experts"],
            transitionCount: row["transitionCount"] ?? 0, absorbedSeconds: row["absorbedSeconds"] ?? 0,
            precededByGapS: row["precededByGapS"], settlingSeconds: row["settlingSeconds"])
    }

    private static func dayRow(from row: Row) -> ActivityContextDayRow {
        ActivityContextDayRow(
            day: row["day"], dayStart: row["dayStart"], dayEnd: row["dayEnd"],
            taxonomyVersion: row["taxonomyVersion"], decoderVersion: row["decoderVersion"],
            ontologyVersion: row["ontologyVersion"], intervalVersion: row["intervalVersion"],
            dataThrough: row["dataThrough"],
            observedSeconds: row["observedSeconds"], intervalCount: row["intervalCount"],
            computedAt: row["computedAt"], featureSchema: row["featureSchema"], encoderId: row["encoderId"],
            encoderVersion: row["encoderVersion"], motionHeads: row["motionHeads"],
            gaitQuality: row["gaitQuality"], configTag: row["configTag"],
            inputFingerprint: row["inputFingerprint"],
            finality: row["finality"] ?? ActivityContextDayRow.provisional,
            decodeMode: row["decodeMode"] ?? ActivityContextDayRow.causal,
            sleepKnownOutsideSessions: row["sleepKnownOutsideSessions"])
    }
}
