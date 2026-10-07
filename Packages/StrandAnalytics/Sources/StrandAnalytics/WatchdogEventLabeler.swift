import Foundation

public enum WatchdogEventLabel: String, Equatable, Sendable, Codable, CaseIterable {
    case wristOff = "wrist_off"
    case gap
    case artifactSpike = "artifact_spike"
    case workoutWalk = "workout_walk"
    case workoutRun = "workout_run"
    case workoutCycle = "workout_cycle"
    case workoutLift = "workout_lift"
    case postWorkout = "post_workout"
    case normalSleep = "normal_sleep"
    case normalStillAwake = "normal_still_awake"
    case forecastDriftOnly = "forecast_drift_only"
    case abnormalStillTachycardia = "abnormal_still_tachycardia"
    case abnormalMultiDirection = "abnormal_multi_direction"
    case abnormalSpo2Still = "abnormal_spo2_still"
    case safetyBound = "safety_bound"
    case mixedRejected = "mixed_rejected"
}

public struct WatchdogEvent: Equatable, Sendable, Codable {
    public var eventId: String
    public var label: WatchdogEventLabel
    public var t0: Int
    public var t1: Int
    public var family: String
    public var cutReason: String

    public init(eventId: String, label: WatchdogEventLabel, t0: Int, t1: Int,
                family: String = "whoop4", cutReason: String = "") {
        self.eventId = eventId
        self.label = label
        self.t0 = t0
        self.t1 = t1
        self.family = family
        self.cutReason = cutReason
    }

    public func contains(_ unix: Int) -> Bool { unix >= t0 && unix < t1 }
}

public enum WatchdogEventLabeler: Sendable {
    public static let postWorkoutSeconds = 20 * 60
    public static let familyHoldMinutes = 2
    public static let familyHoldSeconds = familyHoldMinutes * 60
    public static let sleepEdgeSeconds = 5 * 60
    public static let maxEventSeconds = 45 * 60

    public static func familyHeld(nowUnix: Int, changedUnix: Int) -> Bool {
        if changedUnix <= 0 { return true }
        return nowUnix - changedUnix >= familyHoldSeconds
    }

    public static func holdElapsedSeconds(familyStableTicks: Int,
                                          familyChangedUnix: Int,
                                          nowUnix: Int) -> Int {
        if familyChangedUnix > 0, nowUnix > familyChangedUnix {
            return nowUnix - familyChangedUnix
        }
        return max(0, familyStableTicks) * WatchdogConfig.tickSeconds
    }

    public static func sleepIntervalOpen(_ intervals: [WatchdogSleepInterval], unix: Int) -> Bool {
        intervals.contains { $0.contains(unix) }
    }

    public static func sleepIntervalEdge(_ intervals: [WatchdogSleepInterval], unix: Int) -> Bool {
        intervals.contains { iv in
            abs(unix - iv.startUnix) < sleepEdgeSeconds || abs(unix - iv.endUnix) < sleepEdgeSeconds
        }
    }

    public static func wearerDisplay(_ label: WatchdogEventLabel, lastCommitted: String) -> String {
        if label == .mixedRejected {
            if lastCommitted.isEmpty || lastCommitted == WatchdogEventLabel.mixedRejected.rawValue {
                return ""
            }
            return lastCommitted
        }
        return label.rawValue
    }

    /// Wearer banner. Tokens and mixed_rejected never print.
    public static func wearerPhrase(_ label: WatchdogEventLabel, lastCommitted: String = "") -> String {
        if label == .mixedRejected {
            if let prev = WatchdogEventLabel(rawValue: lastCommitted), prev != .mixedRejected {
                return wearerPhrase(prev)
            }
            return "Settling"
        }
        switch label {
        case .wristOff: return "Off wrist"
        case .gap: return "Waiting"
        case .artifactSpike: return "Noisy motion"
        case .workoutWalk: return "Walking"
        case .workoutRun: return "Running"
        case .workoutCycle: return "Cycling"
        case .workoutLift: return "Lifting"
        case .postWorkout: return "After exercise"
        case .normalSleep: return "Asleep"
        case .normalStillAwake: return "Still"
        case .forecastDriftOnly: return "Looking ahead"
        case .abnormalStillTachycardia, .abnormalMultiDirection, .abnormalSpo2Still:
            return "A bit unlike usual"
        case .safetyBound: return "Checking a reading"
        case .mixedRejected: return "Settling"
        }
    }

    public static func family(of cls: WatchdogActivityClass) -> String {
        switch cls {
        case .walk: return "walk"
        case .run, .cycleLike: return "endurance"
        case .resistance: return "resistance"
        case .still, .stand: return "still"
        case .artifact: return "artifact"
        case .unknown: return "other"
        }
    }

    /// Device facts only — not a second exclusive table. Workout names wait on the 2 min hold in `what`.
    public static func liveHint(window: WatchdogWindow, lastWorkoutEndUnix: Int,
                                unavailable: WatchdogUnavailable? = nil) -> WatchdogEventLabel {
        if unavailable == .wristOff { return .wristOff }
        if unavailable != nil { return .gap }
        let tail = WatchdogLiveTail.resolve(window)
        if WatchdogActivityRuntime.isArtifact(window.activityLogits, from: tail.startIndex) {
            return .artifactSpike
        }
        if lastWorkoutEndUnix > 0,
           window.nowUnix - lastWorkoutEndUnix < postWorkoutSeconds,
           tail.stillNow {
            return .postWorkout
        }
        if tail.period == .effort { return .mixedRejected }
        let sleep = sleepIntervalOpen(window.sleepIntervals, unix: window.nowUnix)
            || (window.activityFeatures.last.map { WatchdogActivityFeatures.sleepBit($0) == 1 } ?? false)
        if sleep { return .normalSleep }
        return .normalStillAwake
    }

    public static func earlyAllowed(_ label: WatchdogEventLabel) -> Bool {
        switch label {
        case .workoutWalk, .workoutRun, .workoutCycle, .workoutLift,
             .postWorkout, .artifactSpike, .gap, .wristOff, .mixedRejected:
            return false
        default:
            return true
        }
    }

    public static func bandEligible(_ label: WatchdogEventLabel) -> Bool {
        WatchdogBand.learnable(label)
    }

    /// Sidecar / session usuals. Forecast-drift may still write on rest (point 7). Band does not.
    public static func sidecarEligible(_ label: WatchdogEventLabel) -> Bool {
        switch label {
        case .normalSleep, .normalStillAwake, .forecastDriftOnly:
            return true
        default:
            return false
        }
    }

    /// Device facts only. Workout names require UniTS `explained` — never a calendar or a human click.
    public static func labelMinute(wristOff: Bool, gap: Bool, artifact: Bool,
                                   cls: WatchdogActivityClass, postWorkout: Bool,
                                   sleep: Bool, safety: Bool,
                                   explainedWorkout: Bool) -> WatchdogEventLabel {
        if wristOff { return .wristOff }
        if gap { return .gap }
        if artifact { return .artifactSpike }
        if safety { return .safetyBound }
        if explainedWorkout {
            switch cls {
            case .walk: return .workoutWalk
            case .run: return .workoutRun
            case .cycleLike: return .workoutCycle
            case .resistance: return .workoutLift
            default: break
            }
        }
        if postWorkout && (cls == .still || cls == .stand) { return .postWorkout }
        if sleep { return .normalSleep }
        return .normalStillAwake
    }

    /// Cut a run of minute labels into events. Same label + C8 max length.
    public static func cutEvents(minuteLabels: [WatchdogEventLabel], startUnix: Int,
                                 grid: Int = 60, family: String = "whoop4") -> [WatchdogEvent] {
        guard !minuteLabels.isEmpty else { return [] }
        var out: [WatchdogEvent] = []
        var i = 0
        var seq = 0
        while i < minuteLabels.count {
            let lab = minuteLabels[i]
            var j = i + 1
            while j < minuteLabels.count && minuteLabels[j] == lab
                    && (j - i) * grid < maxEventSeconds {
                j += 1
            }
            seq += 1
            out.append(WatchdogEvent(eventId: "\(lab.rawValue)-\(seq)", label: lab,
                                     t0: startUnix + i * grid, t1: startUnix + j * grid,
                                     family: family, cutReason: j - i >= familyHoldMinutes || lab != .normalStillAwake
                                     ? "label-run" : "short"))
            i = j
        }
        return out
    }

    public static func windowAccepted(events: [WatchdogEvent], windowStart: Int, windowEnd: Int) -> Bool {
        let hit = events.filter { $0.t1 > windowStart && $0.t0 < windowEnd }
        if hit.contains(where: { $0.label == .mixedRejected }) { return false }
        let ids = Set(hit.map(\.eventId))
        return ids.count == 1
    }
}
