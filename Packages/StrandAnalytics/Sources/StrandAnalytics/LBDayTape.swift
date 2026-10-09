import Foundation

/// Unique-minute mean for one civil-day series. Missing is never stored as 0.
public struct LBMinuteBucket: Equatable, Sendable, Codable {
    public var sum: Double = 0
    public var n: Int = 0
    public var lastMinuteUnix: Int = 0

    public var mean: Double? { n > 0 ? sum / Double(n) : nil }

    @discardableResult
    public mutating func addUnique(value: Double, minuteUnix: Int) -> Bool {
        guard value.isFinite, minuteUnix > lastMinuteUnix else { return false }
        sum += value
        n += 1
        lastMinuteUnix = minuteUnix
        return true
    }
}

/// Civil-day Watchdog tape for stub Layer 1 series. `evaluate` never writes 7-day / 60-day snapshots.
///
/// Every fresh minute of a window is filed once per channel, keyed by that minute's own civil day.
/// A minute is filed into rest / effort / unknown only after `contextSettleSeconds`, so a live HR
/// minute whose gravity row has not landed yet is not judged early. An awake minute with no motion
/// evidence (no motion scalar, IMU sample or step tick) is `unknownContext`, never rest.
public struct LBDayTape: Equatable, Sendable, Codable {
    /// Rest pools every awake stationary posture (sit / stand / recumbent). Canonical posture context
    /// does not reach the Watchdog tape, so posture is recorded as unresolved, not guessed.
    public static let restPosturePooledUnresolved = "stationary_awake_posture_unresolved"
    /// Gravity and steps land in the store after live HR. Context waits this long behind `nowUnix`.
    public static let contextSettleSeconds = 5 * 60
    /// Ingest regime of the minutes a tape holds. Rows from different regimes are not comparable
    /// (the legacy rule filed one newest minute per tick and counted no-evidence minutes as rest).
    public static let contextRuleCurrent = "wp8_v3_settled_every_minute"
    /// A tape persisted before `contextRule` existed.
    public static let contextRuleLegacy = "legacy_lastminute"
    /// A legacy tape that this regime then extended: the day mixes both rules.
    public static let contextRuleMixed = "mixed_legacy_lastminute_wp8_v3"

    public var day: String
    public var restHR = LBMinuteBucket()
    public var restHRV = LBMinuteBucket()
    public var restSpO2 = LBMinuteBucket()
    public var effortHR = LBMinuteBucket()
    public var effortHRV = LBMinuteBucket()
    public var effortSpO2 = LBMinuteBucket()
    public var allHR = LBMinuteBucket()
    public var allHRV = LBMinuteBucket()
    public var allSpO2 = LBMinuteBucket()
    /// Awake minutes with no motion evidence. Kept out of rest and effort; counted for provenance.
    public var unknownContextHR = LBMinuteBucket()
    public var unknownContextHRV = LBMinuteBucket()
    public var unknownContextSpO2 = LBMinuteBucket()
    public var sleepSpO2Min: Double?
    public var sleepSpO2N: Int = 0
    public var sleepSpO2LastMinute: Int = 0
    public var activeMinutes: Int = 0
    public var lastActiveMinute: Int = 0
    /// Last minute filed into a context bucket per channel (HR, HRV, SpO2). One minute, one context.
    public var contextWatermark: [Int] = [0, 0, 0]
    /// Posture provenance for the rest buckets.
    public var restPosture: String = LBDayTape.restPosturePooledUnresolved
    /// Which ingest regime filed this day's minutes. Legacy rows decode as `contextRuleLegacy`.
    public var contextRule: String = LBDayTape.contextRuleCurrent

    public init(day: String) { self.day = day }

    /// True when every context minute of the day was filed by the current regime.
    public var currentContextRule: Bool { contextRule == Self.contextRuleCurrent }

    enum CodingKeys: String, CodingKey {
        case day, restHR, restHRV, restSpO2, effortHR, effortHRV, effortSpO2, allHR, allHRV, allSpO2
        case unknownContextHR, unknownContextHRV, unknownContextSpO2
        case sleepSpO2Min, sleepSpO2N, sleepSpO2LastMinute, activeMinutes, lastActiveMinute
        case contextWatermark, restPosture, contextRule
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        func bucket(_ k: CodingKeys) throws -> LBMinuteBucket {
            try c.decodeIfPresent(LBMinuteBucket.self, forKey: k) ?? LBMinuteBucket()
        }
        restHR = try bucket(.restHR)
        restHRV = try bucket(.restHRV)
        restSpO2 = try bucket(.restSpO2)
        effortHR = try bucket(.effortHR)
        effortHRV = try bucket(.effortHRV)
        effortSpO2 = try bucket(.effortSpO2)
        allHR = try bucket(.allHR)
        allHRV = try bucket(.allHRV)
        allSpO2 = try bucket(.allSpO2)
        unknownContextHR = try bucket(.unknownContextHR)
        unknownContextHRV = try bucket(.unknownContextHRV)
        unknownContextSpO2 = try bucket(.unknownContextSpO2)
        sleepSpO2Min = try c.decodeIfPresent(Double.self, forKey: .sleepSpO2Min)
        sleepSpO2N = try c.decodeIfPresent(Int.self, forKey: .sleepSpO2N) ?? 0
        sleepSpO2LastMinute = try c.decodeIfPresent(Int.self, forKey: .sleepSpO2LastMinute) ?? 0
        activeMinutes = try c.decodeIfPresent(Int.self, forKey: .activeMinutes) ?? 0
        lastActiveMinute = try c.decodeIfPresent(Int.self, forKey: .lastActiveMinute) ?? 0
        if let mark = try c.decodeIfPresent([Int].self, forKey: .contextWatermark), mark.count == 3 {
            contextWatermark = mark
        } else {
            // Legacy tape: the newest minute any context bucket already holds.
            contextWatermark = [
                max(restHR.lastMinuteUnix, effortHR.lastMinuteUnix),
                max(restHRV.lastMinuteUnix, effortHRV.lastMinuteUnix),
                max(restSpO2.lastMinuteUnix, effortSpO2.lastMinuteUnix, sleepSpO2LastMinute)
            ]
        }
        restPosture = try c.decodeIfPresent(String.self, forKey: .restPosture)
            ?? Self.restPosturePooledUnresolved
        contextRule = try c.decodeIfPresent(String.self, forKey: .contextRule) ?? Self.contextRuleLegacy
    }

    /// Persisted v1 stored ln(RMSSD). Means in (0, 5) are leftover ln → ms.
    public mutating func migrateHrvFromLnIfNeeded() {
        func lift(_ b: inout LBMinuteBucket) {
            guard b.n > 0, b.mean.map({ $0 > 0 && $0 < 5 }) == true else { return }
            b.sum = exp(b.sum / Double(b.n)) * Double(b.n)
        }
        lift(&restHRV)
        lift(&effortHRV)
        lift(&allHRV)
    }

    /// Ticks that may not train (alert, quality fail, confounded day) still consume their minutes.
    /// A later quiet tick must not back-fill an alerting stretch into the usual.
    public mutating func skipThrough(minuteUnix: Int) {
        let m = minuteUnix - minuteUnix % 60
        for b in [\LBDayTape.restHR, \.restHRV, \.restSpO2, \.effortHR, \.effortHRV, \.effortSpO2,
                  \.allHR, \.allHRV, \.allSpO2, \.unknownContextHR, \.unknownContextHRV,
                  \.unknownContextSpO2] {
            self[keyPath: b].lastMinuteUnix = max(self[keyPath: b].lastMinuteUnix, m)
        }
        contextWatermark = contextWatermark.map { max($0, m) }
        sleepSpO2LastMinute = max(sleepSpO2LastMinute, m)
        lastActiveMinute = max(lastActiveMinute, m)
    }

    /// Files every fresh minute of `window` whose civil day (`dayOf`) is this tape's day.
    /// `dayOf == nil` accepts every minute (single-day callers and tests).
    /// `floor` holds per-channel watermarks of the other day tapes (all-bucket, context). A minute at or
    /// below them was already filed on another civil day (a time-zone change re-maps minutes to days).
    public mutating func ingest(window: WatchdogWindow, nowUnix: Int,
                                lastWorkoutEndUnix: Int = 0,
                                sleepIntervals: [WatchdogSleepInterval] = [],
                                trainUsual: Bool = true,
                                dayOf: ((Int) -> String)? = nil,
                                floor: Watermarks = Watermarks()) -> Bool {
        guard trainUsual else { return false }
        let features = window.resolvedActivityFeatures()
        let evidence = WatchdogActivityFeatures.motionEvidence(window: window)
        let labels = WatchdogActivityClass.labels(logits: window.activityLogits)
        // Post-workout anchors use the live-tail period (exercise class, motion >= chair-still, steps),
        // not the broader fidget-level `moving` that only picks the effort bucket.
        let periods = WatchdogLiveTail.periods(window)
        let n = window.seqLen
        let settledBefore = nowUnix - Self.contextSettleSeconds
        var changed = false
        if contextWatermark.count != 3 { contextWatermark = [0, 0, 0] }

        func minuteUnix(_ i: Int) -> Int {
            let t = window.startUnix + i * WatchdogConfig.gridSeconds
            return t - t % 60
        }
        func row(_ i: Int) -> [Double] { i < features.count ? features[i] : [] }
        func sleepAt(_ i: Int) -> Bool {
            let t = window.startUnix + i * WatchdogConfig.gridSeconds
            if sleepIntervals.contains(where: { $0.contains(t) }) { return true }
            guard i >= 0, i < features.count else { return false }
            return WatchdogActivityFeatures.sleepBit(features[i]) == 1
        }
        func clsAt(_ i: Int) -> WatchdogActivityClass {
            let raw = i < labels.count ? labels[i] : WatchdogActivityClass.unknown.rawValue
            return WatchdogActivityClass.allCases.first(where: { $0.rawValue == raw }) ?? .unknown
        }
        func moving(_ i: Int) -> Bool {
            let r = row(i)
            let occ = r.isEmpty ? 0 : WatchdogActivityFeatures.priorOccupancy(r)
            let loco = r.isEmpty ? 0 : WatchdogActivityFeatures.stepLocomotion(r)
            return occ >= 0.15 || loco >= 0.5
        }
        // Per-minute live-tail period, not the period of the newest minute only.
        let effort: [Bool] = (0..<n).map { i in
            let motion = i < window.motion.count ? window.motion[i] : nil
            return WatchdogLiveTail.period(cls: clsAt(i), motion: motion) == .effort || moving(i)
        }
        func recovering(_ i: Int) -> Bool {
            let t = window.startUnix + i * WatchdogConfig.gridSeconds
            var ended = lastWorkoutEndUnix
            for j in 0..<i where j < periods.count && periods[j] == .effort {
                ended = max(ended, window.startUnix + (j + 1) * WatchdogConfig.gridSeconds)
            }
            guard ended > 0 else { return false }
            return t - ended < WatchdogEventLabeler.postWorkoutSeconds
        }

        // Per-minute sensor quality: a minute whose strap was off or whose heart-rate signal was poor is never rest
        // (it files as unknown context, so it cannot reach a baseline).
        let minuteQuality = WatchdogSignalQuality.assess(window: window)
        enum Context { case sleep, effort, rest, recovering, unknown }
        func context(_ i: Int) -> Context {
            if sleepAt(i) { return .sleep }
            guard i < evidence.count, evidence[i] else { return .unknown }
            if i < minuteQuality.count, minuteQuality[i].onBody == .off || minuteQuality[i].signal == .poor {
                return .unknown
            }
            // Exercise sessions (still minutes between sets included) are effort; their recovery is never rest
            // (rule exercise-session-1).
            switch window.exercise?.phase(at: i) ?? .none {
            case .session: return .effort
            case .recovery: return .recovering
            case .none: break
            }
            if effort[i] { return .effort }
            return recovering(i) ? .recovering : .rest
        }

        func file(_ series: [Double?], channel: Int, mark: Int,
                  all: WritableKeyPath<LBDayTape, LBMinuteBucket>,
                  rest: WritableKeyPath<LBDayTape, LBMinuteBucket>,
                  effortBucket: WritableKeyPath<LBDayTape, LBMinuteBucket>,
                  unknown: WritableKeyPath<LBDayTape, LBMinuteBucket>) {
            guard WatchdogQuality.channelFresh(series, startUnix: window.startUnix, nowUnix: nowUnix,
                                               channel: channel, family: window.family) else { return }
            for i in 0..<min(n, series.count) {
                guard let v = series[i], v.isFinite else { continue }
                let t = minuteUnix(i)
                if let dayOf, dayOf(t) != day { continue }
                if t > floor.all[mark] {
                    changed = self[keyPath: all].addUnique(value: v, minuteUnix: t) || changed
                }
                // Context waits for late motion rows; each minute gets exactly one context.
                guard t + WatchdogConfig.gridSeconds <= settledBefore, t > contextWatermark[mark],
                      t > floor.context[mark] else { continue }
                contextWatermark[mark] = t
                changed = true
                switch context(i) {
                case .sleep:
                    // Sleep HR / HRV stay on DailyMetric nights; tape does not invent sleep RHR.
                    if channel == 5, t > sleepSpO2LastMinute {
                        sleepSpO2Min = sleepSpO2Min.map { min($0, v) } ?? v
                        sleepSpO2N += 1
                        sleepSpO2LastMinute = t
                    }
                case .unknown:
                    _ = self[keyPath: unknown].addUnique(value: v, minuteUnix: t)
                case .effort:
                    _ = self[keyPath: effortBucket].addUnique(value: v, minuteUnix: t)
                    if channel == 0, moving(i), t > lastActiveMinute {
                        activeMinutes += 1
                        lastActiveMinute = t
                    }
                case .rest:
                    _ = self[keyPath: rest].addUnique(value: v, minuteUnix: t)
                case .recovering:
                    break
                }
            }
        }

        file(window.hr, channel: 0, mark: 0, all: \.allHR, rest: \.restHR,
             effortBucket: \.effortHR, unknown: \.unknownContextHR)
        // Native RMSSD ms. Layer 1 `toMath` is the only ln.
        file(window.hrv, channel: 2, mark: 1, all: \.allHRV, rest: \.restHRV,
             effortBucket: \.effortHRV, unknown: \.unknownContextHRV)
        file(window.spo2, channel: 5, mark: 2, all: \.allSpO2, rest: \.restSpO2,
             effortBucket: \.effortSpO2, unknown: \.unknownContextSpO2)
        if changed, contextRule == Self.contextRuleLegacy { contextRule = Self.contextRuleMixed }
        return changed
    }

    /// Per-channel (HR, HRV, SpO2) watermarks: newest minute in the all-bucket and in a context bucket.
    public struct Watermarks: Equatable, Sendable {
        public var all: [Int] = [0, 0, 0]
        public var context: [Int] = [0, 0, 0]
        public init() {}

        /// The newest minute any of `tapes` already holds, per channel.
        public static func across<S: Sequence>(_ tapes: S) -> Watermarks where S.Element == LBDayTape {
            var w = Watermarks()
            for t in tapes {
                let all = [t.allHR.lastMinuteUnix, t.allHRV.lastMinuteUnix, t.allSpO2.lastMinuteUnix]
                for k in 0..<3 {
                    w.all[k] = max(w.all[k], all[k])
                    if k < t.contextWatermark.count { w.context[k] = max(w.context[k], t.contextWatermark[k]) }
                }
            }
            return w
        }
    }

    /// Civil days the window's minutes fall on, oldest first.
    public static func days(of window: WatchdogWindow, dayOf: (Int) -> String) -> [String] {
        var out: [String] = []
        for i in 0..<window.seqLen {
            let t = window.startUnix + i * WatchdogConfig.gridSeconds
            let d = dayOf(t - t % 60)
            if out.last != d && !out.contains(d) { out.append(d) }
        }
        return out
    }

    /// Ingests one window into the tapes of every civil day its minutes touch. Returns changed days.
    @discardableResult
    public static func ingest(window: WatchdogWindow, nowUnix: Int,
                              lastWorkoutEndUnix: Int = 0,
                              sleepIntervals: [WatchdogSleepInterval] = [],
                              trainUsual: Bool = true,
                              into tapes: inout [String: LBDayTape],
                              dayOf: @escaping (Int) -> String) -> [String] {
        guard trainUsual else { return [] }
        var changedDays: [String] = []
        for d in days(of: window, dayOf: dayOf) {
            var tape = tapes[d] ?? LBDayTape(day: d)
            // Absolute-time floor from every other day: a minute is filed on one civil day only,
            // even when a time-zone change re-maps it to a different day string on a later tick.
            let floor = Watermarks.across(tapes.values.lazy.filter { $0.day != d })
            if tape.ingest(window: window, nowUnix: nowUnix, lastWorkoutEndUnix: lastWorkoutEndUnix,
                           sleepIntervals: sleepIntervals, dayOf: dayOf, floor: floor) {
                tapes[d] = tape
                changedDays.append(d)
            }
        }
        return changedDays
    }

    /// A tick that may not train consumes every minute of its window on every day it touches.
    /// Returns the days whose watermarks moved (the caller persists those).
    @discardableResult
    public static func skipThrough(window: WatchdogWindow, into tapes: inout [String: LBDayTape],
                                   dayOf: (Int) -> String) -> [String] {
        var changed: [String] = []
        for d in days(of: window, dayOf: dayOf) {
            let before = tapes[d]
            var tape = before ?? LBDayTape(day: d)
            // Stop at the last minute that belongs to this day so a later day is not pre-consumed.
            var last = window.startUnix
            for i in 0..<window.seqLen {
                let t = window.startUnix + i * WatchdogConfig.gridSeconds
                if dayOf(t - t % 60) == d { last = t }
            }
            tape.skipThrough(minuteUnix: last)
            if tape != before {
                tapes[d] = tape
                changed.append(d)
            }
        }
        return changed
    }

    public func observation(series: LBSeries) -> LBDailyObservation? {
        func publish(_ bucket: LBMinuteBucket, floor: Int, native: Double?) -> LBDailyObservation? {
            guard let native, bucket.n >= floor else { return nil }
            var o = LongitudinalBaseline.observation(
                day: day, native: native, streamPresent: true, sleepHrOnly: false, series: series)
            o.coverage = Double(bucket.n)
            return LongitudinalBaseline.applyCoverageGate(o, series: series)
        }
        switch series {
        case .awakeRestHR:
            return publish(restHR, floor: 8, native: restHR.mean)
        case .awakeRestHRVLn:
            return publish(restHRV, floor: 8, native: restHRV.mean)
        case .awakeRestSpO2Mean:
            return publish(restSpO2, floor: 4, native: restSpO2.mean)
        case .awakeActiveHR:
            return publish(effortHR, floor: 8, native: effortHR.mean)
        case .awakeActiveHRVLn:
            return publish(effortHRV, floor: 8, native: effortHRV.mean)
        case .awakeActiveSpO2Mean:
            return publish(effortSpO2, floor: 4, native: effortSpO2.mean)
        case .continuousHR:
            return publish(allHR, floor: 8, native: allHR.mean)
        case .continuousHRVLn:
            return publish(allHRV, floor: 8, native: allHRV.mean)
        case .continuousSpO2Mean:
            return publish(allSpO2, floor: 4, native: allSpO2.mean)
        case .sleepSpO2Nadir:
            guard let nadir = sleepSpO2Min, sleepSpO2N >= 3 else { return nil }
            var o = LongitudinalBaseline.observation(
                day: day, native: nadir, streamPresent: true, sleepHrOnly: false, series: series)
            o.coverage = Double(sleepSpO2N)
            return LongitudinalBaseline.applyCoverageGate(o, series: series)
        case .wakingActiveMin:
            guard activeMinutes >= 1 else { return nil }
            return LongitudinalBaseline.observation(
                day: day, native: Double(activeMinutes), streamPresent: true,
                sleepHrOnly: false, series: series)
        default:
            return nil
        }
    }
}

/// Rows of one phone-local Layer 1 tape (awake day tape, waking IMU energy) scoped to one device era.
public struct LBDeviceScopedRows<Row: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var deviceId: String
    /// Strap serial the rows were trained on. Nil until the serial is known, then stamped once.
    public var strapSerial: String?
    public var rows: [Row]

    public init(deviceId: String, strapSerial: String?, rows: [Row]) {
        self.deviceId = deviceId
        self.strapSerial = strapSerial
        self.rows = rows
    }
}

/// Key-value access the scope needs (UserDefaults in the app, a dictionary in tests).
public struct LBKeyValueIO {
    public var data: (String) -> Data?
    public var setData: (Data, String) -> Void
    public var string: (String) -> String?
    public var setString: (String, String) -> Void

    public init(data: @escaping (String) -> Data?, setData: @escaping (Data, String) -> Void,
                string: @escaping (String) -> String?, setString: @escaping (String, String) -> Void) {
        self.data = data
        self.setData = setData
        self.string = string
        self.setString = setString
    }
}

/// Device scoping for the phone-local Layer 1 tapes. One strap's minutes never train another's usual.
///
/// The pre-scope global blob is adopted once, by the first device that loads, so an update does not
/// drop the user's history. A tape stamped with one strap serial is archived, not reused, when a
/// different strap answers to the same local device id.
public enum LBDeviceScope {
    public static let tapePrefix = "noop.baseline.daytape.v3."
    public static let imuPrefix = "noop.baseline.imu.v2."
    public static let legacyTapeKeys = ["noop.baseline.daytape.v2", "noop.baseline.daytape.v1"]
    public static let legacyImuKeys = ["noop.baseline.imu.v1"]

    public enum Origin: String, Equatable, Sendable {
        /// This device's own scoped rows.
        case own
        /// The pre-scope global blob, adopted by this device (once per install).
        case legacyAdopted
        /// Nothing stored for this device yet.
        case fresh
        /// A different strap serial owned the stored rows. They were archived; this era starts empty.
        case strapReplaced
    }

    public static func key(prefix: String, deviceId: String) -> String { prefix + deviceId }
    public static func adoptedKey(prefix: String) -> String { prefix + "legacyAdoptedBy" }
    public static func archiveKey(prefix: String, deviceId: String, serial: String) -> String {
        prefix + deviceId + ".strap." + serial
    }

    public static func load<Row>(prefix: String, legacyKeys: [String], deviceId: String,
                                 serial: String?, io: LBKeyValueIO) -> (LBDeviceScopedRows<Row>, Origin) {
        let own = key(prefix: prefix, deviceId: deviceId)
        if let data = io.data(own),
           var stored = try? JSONDecoder().decode(LBDeviceScopedRows<Row>.self, from: data) {
            if let was = stored.strapSerial, let serial, was != serial {
                io.setData(data, archiveKey(prefix: prefix, deviceId: deviceId, serial: was))
                let fresh = LBDeviceScopedRows<Row>(deviceId: deviceId, strapSerial: serial, rows: [])
                save(fresh, prefix: prefix, io: io)
                return (fresh, .strapReplaced)
            }
            if stored.strapSerial == nil, let serial {
                stored.strapSerial = serial
                save(stored, prefix: prefix, io: io)
            }
            return (stored, .own)
        }
        if io.string(adoptedKey(prefix: prefix)) == nil {
            for legacy in legacyKeys {
                guard let data = io.data(legacy),
                      let rows = try? JSONDecoder().decode([Row].self, from: data) else { continue }
                let adopted = LBDeviceScopedRows<Row>(deviceId: deviceId, strapSerial: serial, rows: rows)
                save(adopted, prefix: prefix, io: io)
                io.setString(deviceId, adoptedKey(prefix: prefix))
                return (adopted, .legacyAdopted)
            }
        }
        return (LBDeviceScopedRows<Row>(deviceId: deviceId, strapSerial: serial, rows: []), .fresh)
    }

    public static func save<Row>(_ scoped: LBDeviceScopedRows<Row>, prefix: String, io: LBKeyValueIO) {
        guard let data = try? JSONEncoder().encode(scoped) else { return }
        io.setData(data, key(prefix: prefix, deviceId: scoped.deviceId))
    }
}
