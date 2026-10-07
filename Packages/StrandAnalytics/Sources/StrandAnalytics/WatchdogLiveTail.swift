import Foundation

/// One live period at the end of the 30-minute strip. Every still-now statistic
/// (safety, last pair, contributing, post-workout) reads this tail only.
public enum WatchdogPeriod: String, Equatable, Sendable {
    /// Still / stand, or unknown with measured motion under 0.15.
    case rest
    /// Labeled exercise, or motion ≥ 0.15 (unlabeled run/cycle still counts).
    case effort
    case artifact
    /// No class and no motion sample. Must not look like rest — that is the no-IMU run hole.
    case unknown
}

public struct WatchdogLiveTail: Equatable, Sendable {
    public var startIndex: Int
    public var period: WatchdogPeriod
    public var previousPeriod: WatchdogPeriod?
    /// Unix second at the end of the last effort minute in this window. 0 if none.
    public var lastEffortEndUnix: Int
    public var startUnix: Int
    public var nowUnix: Int

    public var stillNow: Bool { period == .rest }

    public func contains(_ index: Int) -> Bool {
        index >= startIndex
    }

    public func last(_ xs: [Double?]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let lo = min(max(0, startIndex), xs.count)
        for i in stride(from: xs.count - 1, through: lo, by: -1) {
            if let v = xs[i], v.isFinite { return v }
        }
        return nil
    }

    public func slice(_ xs: [Double?]) -> [Double?] {
        guard startIndex > 0, startIndex < xs.count else { return xs }
        return Array(xs[startIndex...])
    }

    public func slice(_ xs: [Double]) -> [Double] {
        guard startIndex > 0, startIndex < xs.count else { return xs }
        return Array(xs[startIndex...])
    }

    public func postWorkout(carryEndUnix: Int, nowUnix: Int) -> Bool {
        guard stillNow else { return false }
        let ended = max(lastEffortEndUnix, carryEndUnix)
        guard ended > 0 else { return false }
        return nowUnix - ended < WatchdogEventLabeler.postWorkoutSeconds
    }

    public static func period(cls: WatchdogActivityClass, motion: Double?) -> WatchdogPeriod {
        if cls == .artifact { return .artifact }
        if WatchdogEventGeometry.isExercise(cls) { return .effort }
        if cls == .still || cls == .stand {
            if let motion, motion >= WatchdogConfig.chairStillOccupancy { return .effort }
            return .rest
        }
        if let motion {
            return motion >= WatchdogConfig.chairStillOccupancy ? .effort : .rest
        }
        return .unknown
    }

    public static func resolve(_ window: WatchdogWindow) -> WatchdogLiveTail {
        let n = max(window.hr.count, window.activityLogits.count, 1)
        let labels = WatchdogActivityClass.labels(logits: window.activityLogits)
        func clsAt(_ i: Int) -> WatchdogActivityClass {
            let raw = i < labels.count ? labels[i] : (labels.last ?? WatchdogActivityClass.unknown.rawValue)
            return WatchdogActivityClass.allCases.first(where: { $0.rawValue == raw }) ?? .unknown
        }
        func periodAt(_ i: Int) -> WatchdogPeriod {
            let motion = i < window.motion.count ? window.motion[i] : window.motion.last ?? nil
            var p = period(cls: clsAt(i), motion: motion)
            if i < window.activityFeatures.count {
                let row = window.activityFeatures[i]
                if WatchdogActivityFeatures.stepLocomotion(row) >= 0.5 { return .effort }
                if WatchdogActivityFeatures.sleepBit(row) == 1, p != .effort, p != .artifact {
                    p = .rest
                }
            }
            return p
        }
        let current = periodAt(n - 1)
        var start = n - 1
        while start > 0, periodAt(start - 1) == current {
            start -= 1
        }
        let previous: WatchdogPeriod? = start > 0 ? periodAt(start - 1) : nil
        var lastEffortIdx: Int?
        for i in 0..<n where periodAt(i) == .effort {
            lastEffortIdx = i
        }
        let lastEffortEnd = lastEffortIdx.map {
            window.startUnix + ($0 + 1) * WatchdogConfig.gridSeconds
        } ?? 0
        return WatchdogLiveTail(
            startIndex: start,
            period: current,
            previousPeriod: previous,
            lastEffortEndUnix: lastEffortEnd,
            startUnix: window.startUnix + start * WatchdogConfig.gridSeconds,
            nowUnix: window.nowUnix
        )
    }

    /// Residual energy on this tail only. The 30-minute median of a finished run does not apply.
    public func energy(obs: [Double?], hat: [Double?], scale: [Double],
                       floor: Double) -> Double {
        let o = slice(obs)
        let h = slice(hat)
        let s: [Double]? = scale.isEmpty ? nil : slice(scale)
        return UniTSRuntime.score(o, h, floor: floor, personal: 0, predicted: s).energy
    }

    public var length: Int { max(0, WatchdogConfig.seqLen - startIndex) }

    public var endedPeriod: Bool { startIndex > 0 }

    public func hrCoverage(_ hr: [Double?]) -> Double {
        let n = max(length, 1)
        let lo = min(max(0, startIndex), hr.count)
        guard lo < hr.count else { return 0 }
        let hit = hr[lo...].filter { $0 != nil }.count
        return Double(hit) / Double(n)
    }

    /// After effort ended, a rest tail without enough current HR is unavailable — not a quiet score.
    public func thinRestCoverage(_ hr: [Double?]) -> Bool {
        guard stillNow, endedPeriod else { return false }
        if length <= 1 { return last(hr) == nil }
        return hrCoverage(hr) + 1e-9 < 0.50
    }

    /// RHR / SpO₂ strips stay inside this rest tail. All-still windows keep builder lookbacks.
    public func clipLookbacks(rhr: [Double?], spo2: [Double?]) -> (rhr: [Double?], spo2: [Double?]) {
        guard stillNow, endedPeriod else { return (rhr, spo2) }
        func clip(_ xs: [Double?]) -> [Double?] {
            xs.enumerated().map { i, v in i >= startIndex ? v : nil }
        }
        return (clip(rhr), clip(spo2))
    }

    public func applyLookbacks(_ window: WatchdogWindow) -> WatchdogWindow {
        var w = window
        let clipped = clipLookbacks(rhr: w.rhr, spo2: w.spo2)
        w.rhr = clipped.rhr
        w.spo2 = clipped.spo2
        return w
    }

    /// Zero occupancy before the rest tail so trailing-mean lift cannot spill from the run.
    public func clipEffortOccupancy(_ occupancy: [Double]) -> [Double] {
        guard stillNow, endedPeriod else { return occupancy }
        return occupancy.enumerated().map { i, v in i >= startIndex ? v : 0 }
    }

    /// Minutes that must not enter residual.energy: finished period, or no-IMU unknown.
    public func maskScored(_ obs: [Double?], window: WatchdogWindow) -> [Double?] {
        let periods = Self.periods(window)
        return obs.enumerated().map { i, v in
            if stillNow, endedPeriod, i < startIndex { return nil }
            if i < periods.count, periods[i] == .unknown { return nil }
            return v
        }
    }

    public static func periods(_ window: WatchdogWindow) -> [WatchdogPeriod] {
        let n = max(window.hr.count, window.activityLogits.count, window.motion.count, 1)
        let labels = WatchdogActivityClass.labels(logits: window.activityLogits)
        return (0..<n).map { i in
            let raw = i < labels.count ? labels[i] : (labels.last ?? WatchdogActivityClass.unknown.rawValue)
            let cls = WatchdogActivityClass.allCases.first(where: { $0.rawValue == raw }) ?? .unknown
            let motion = i < window.motion.count ? window.motion[i] : nil
            var p = period(cls: cls, motion: motion)
            if i < window.activityFeatures.count {
                let row = window.activityFeatures[i]
                if WatchdogActivityFeatures.stepLocomotion(row) >= 0.5 { return .effort }
                if WatchdogActivityFeatures.sleepBit(row) == 1, p != .effort, p != .artifact {
                    p = .rest
                }
            }
            return p
        }
    }
}
