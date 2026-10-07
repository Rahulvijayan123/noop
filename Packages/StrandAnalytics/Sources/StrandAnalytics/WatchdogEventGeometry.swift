import Foundation

/// Live event geometry: UniTS decides **what**; TimesFM helps **when**; memory names repeats.
/// No human event labels. Quality / wrist-off / safety stay device rules.
public struct WatchdogEventDecision: Equatable, Sendable {
    public var label: WatchdogEventLabel
    public var cut: Bool
    public var cutReason: String
    public var explained: Bool

    public init(label: WatchdogEventLabel, cut: Bool, cutReason: String, explained: Bool) {
        self.label = label
        self.cut = cut
        self.cutReason = cutReason
        self.explained = explained
    }
}

public enum WatchdogEventGeometry: Sendable {
    public static let version = "geometry-v2-selflabel"
    public static let persist = 2

    public static func isExercise(_ cls: WatchdogActivityClass) -> Bool {
        switch cls {
        case .walk, .run, .cycleLike, .resistance: return true
        default: return false
        }
    }

    public static func family(of cls: WatchdogActivityClass) -> String {
        WatchdogEventLabeler.family(of: cls)
    }

    /// UniTS: quiet recon means activity-conditioned hat explains the strip.
    public static func explainedByUnits(reconJ: Double) -> Bool {
        reconJ < WatchdogCalibration.tNote
    }

    /// First-session cushion for *labels only*. Does not raise tNote, band eligibility, or notify.
    public static func softExplainedStill(reconJ: Double, breadth: Double, maxAbsR: Double,
                                         hrHot: Bool, spo2Hot: Bool) -> Bool {
        if explainedByUnits(reconJ: reconJ) { return true }
        return reconJ < WatchdogCalibration.tActive
            && breadth < 0.34
            && maxAbsR < 2.5
            && !hrHot
            && !spo2Hot
    }

    /// TimesFM: path leaving while recon may still be quiet.
    public static func forecastOnset(forecastJ: Double, previousForecastJ: Double, aboveTicks: Int) -> Bool {
        _ = previousForecastJ
        return forecastJ >= WatchdogCalibration.tNote && aboveTicks == persist
    }

    public static func unitsRegimeOnset(reconJ: Double, previousReconJ: Double, aboveTicks: Int) -> Bool {
        _ = previousReconJ
        return reconJ >= WatchdogCalibration.tNote && aboveTicks == persist
    }

    /// LiveTail + 20-col family. Last logit alone is not a workout.
    public static func evidencedClass(window: WatchdogWindow, tail: WatchdogLiveTail,
                                      logitCls: WatchdogActivityClass) -> WatchdogActivityClass {
        switch tail.period {
        case .artifact: return .artifact
        case .rest: return (logitCls == .stand) ? .stand : .still
        case .unknown: return .unknown
        case .effort:
            if isExercise(logitCls) { return logitCls }
            let row = window.activityFeatures.last
            if let row, row.count > 14, row[14] >= 0.5 { return .run }
            if let row, row.count > 13, row[13] >= 0.5 { return .walk }
            return logitCls
        }
    }

    public static func what(cls: WatchdogActivityClass, reconJ: Double, forecastJ: Double,
                            safety: Bool, artifact: Bool, postWorkout: Bool, sleep: Bool,
                            hrHot: Bool, breadth: Double, spo2Hot: Bool = false,
                            maxAbsR: Double = .infinity,
                            familyHeld: Bool = true,
                            sleepEdge: Bool = false) -> WatchdogEventLabel {
        if artifact { return .artifactSpike }
        if safety { return .safetyBound }
        if isExercise(cls) && !familyHeld { return .mixedRejected }
        if sleepEdge { return .mixedRejected }
        let explained = explainedByUnits(reconJ: reconJ)
        if isExercise(cls) && explained && familyHeld {
            switch cls {
            case .walk: return .workoutWalk
            case .run: return .workoutRun
            case .cycleLike: return .workoutCycle
            case .resistance: return .workoutLift
            default: break
            }
        }
        if isExercise(cls) {
            return breadth >= 0.45 ? .abnormalMultiDirection : .abnormalStillTachycardia
        }
        let stillish = cls == .still || cls == .stand
        if postWorkout && stillish && reconJ < WatchdogCalibration.tActive { return .postWorkout }
        if stillish && explained && sleep { return .normalSleep }
        if stillish && explained && forecastJ >= WatchdogCalibration.tNote { return .forecastDriftOnly }
        if stillish && softExplainedStill(reconJ: reconJ, breadth: breadth, maxAbsR: maxAbsR,
                                         hrHot: hrHot, spo2Hot: spo2Hot) {
            return sleep ? .normalSleep : .normalStillAwake
        }
        if !explained {
            if spo2Hot && !hrHot { return .abnormalSpo2Still }
            if hrHot && breadth < 0.34 { return .abnormalStillTachycardia }
            return .abnormalMultiDirection
        }
        if sleep { return .normalSleep }
        return .normalStillAwake
    }

    public static func resolve(cls: WatchdogActivityClass,
                               familyStableTicks: Int,
                               previousFamily: String,
                               reconJ: Double,
                               forecastJ: Double,
                               previousReconJ: Double,
                               previousForecastJ: Double,
                               reconAboveTicks: Int,
                               forecastAboveTicks: Int,
                               safety: Bool,
                               artifact: Bool,
                               postWorkout: Bool,
                               sleep: Bool,
                               hrHot: Bool,
                               breadth: Double,
                               eventAgeSeconds: Int,
                               spo2Hot: Bool = false,
                               maxAbsR: Double = .infinity,
                               familyHeld: Bool? = nil,
                               sleepEdge: Bool = false,
                               familyChangedUnix: Int = 0,
                               nowUnix: Int = 0) -> WatchdogEventDecision {
        var unused = WatchdogEventMemory.empty
        return resolve(cls: cls, familyStableTicks: familyStableTicks, previousFamily: previousFamily,
                       reconJ: reconJ, forecastJ: forecastJ, previousReconJ: previousReconJ,
                       previousForecastJ: previousForecastJ, reconAboveTicks: reconAboveTicks,
                       forecastAboveTicks: forecastAboveTicks, safety: safety, artifact: artifact,
                       postWorkout: postWorkout, sleep: sleep, hrHot: hrHot, breadth: breadth,
                       eventAgeSeconds: eventAgeSeconds, spo2Hot: spo2Hot, maxAbsR: maxAbsR,
                       signature: [], memory: &unused, familyHeld: familyHeld, sleepEdge: sleepEdge,
                       familyChangedUnix: familyChangedUnix, nowUnix: nowUnix)
    }

    public static func resolve(cls: WatchdogActivityClass,
                               familyStableTicks: Int,
                               previousFamily: String,
                               reconJ: Double,
                               forecastJ: Double,
                               previousReconJ: Double,
                               previousForecastJ: Double,
                               reconAboveTicks: Int,
                               forecastAboveTicks: Int,
                               safety: Bool,
                               artifact: Bool,
                               postWorkout: Bool,
                               sleep: Bool,
                               hrHot: Bool,
                               breadth: Double,
                               eventAgeSeconds: Int,
                               spo2Hot: Bool,
                               maxAbsR: Double = .infinity,
                               signature: [Double],
                               memory: inout WatchdogEventMemory,
                               familyHeld: Bool? = nil,
                               sleepEdge: Bool = false,
                               familyChangedUnix: Int = 0,
                               nowUnix: Int = 0) -> WatchdogEventDecision {
        let fam = family(of: cls)
        let elapsed = WatchdogEventLabeler.holdElapsedSeconds(
            familyStableTicks: familyStableTicks,
            familyChangedUnix: familyChangedUnix,
            nowUnix: nowUnix)
        let held = familyHeld ?? (elapsed >= WatchdogEventLabeler.familyHoldSeconds)
        let explained = explainedByUnits(reconJ: reconJ)
        var label = what(cls: cls, reconJ: reconJ, forecastJ: forecastJ, safety: safety,
                         artifact: artifact, postWorkout: postWorkout, sleep: sleep,
                         hrHot: hrHot, breadth: breadth, spo2Hot: spo2Hot, maxAbsR: maxAbsR,
                         familyHeld: isExercise(cls) ? held : true,
                         sleepEdge: sleepEdge && !safety)
        if !WatchdogEventMemory.isQuality(label), !signature.isEmpty {
            label = memory.observe(teacher: label, explained: explained, sig: signature)
        }
        var reason = "continue"
        var cut = false
        if eventAgeSeconds >= WatchdogEventLabeler.maxEventSeconds {
            cut = true
            reason = "max-length"
        }
        if unitsRegimeOnset(reconJ: reconJ, previousReconJ: previousReconJ, aboveTicks: reconAboveTicks) {
            cut = true
            reason = "units-regime"
        }
        if forecastOnset(forecastJ: forecastJ, previousForecastJ: previousForecastJ, aboveTicks: forecastAboveTicks) {
            cut = true
            reason = "timesfm-onset"
        }
        if fam != previousFamily && !previousFamily.isEmpty && held {
            cut = true
            reason = "class-hold"
        }
        if artifact, reason != "class-hold" {
            cut = true
            reason = "artifact"
        }
        return WatchdogEventDecision(label: label, cut: cut, cutReason: reason, explained: explained)
    }
}
