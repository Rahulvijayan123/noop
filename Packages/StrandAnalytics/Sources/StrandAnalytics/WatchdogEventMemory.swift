import Foundation

/// Self-supervised event names. UniTS / TimesFM teach; no human accept / reject / cut-nudge.
/// Centroids are EMA of residual signatures — not Core ML training.
public struct WatchdogEventPrototype: Equatable, Sendable, Codable {
    public var label: WatchdogEventLabel
    public var mean: [Double]
    public var n: Int

    public init(label: WatchdogEventLabel, mean: [Double], n: Int) {
        self.label = label
        self.mean = mean
        self.n = n
    }
}

public struct WatchdogEventMemory: Equatable, Sendable, Codable {
    public var prototypes: [WatchdogEventPrototype]
    public static let empty = WatchdogEventMemory(prototypes: [])
    public static let dim = 14
    public static let matureN = 4
    public static let gain = 0.18
    public static let matchTau = 0.55

    public init(prototypes: [WatchdogEventPrototype] = []) {
        self.prototypes = prototypes
    }

    public static func familySlot(_ cls: WatchdogActivityClass) -> Int {
        switch cls {
        case .still, .stand: return 0
        case .walk: return 1
        case .run, .cycleLike: return 2
        case .resistance: return 3
        case .artifact, .unknown: return 4
        }
    }

    public static func signature(d: [Double], reconJ: Double, forecastJ: Double,
                                 cls: WatchdogActivityClass, spo2Abs: Double) -> [Double] {
        var s = Array(repeating: 0.0, count: dim)
        for i in 0..<min(6, d.count) { s[i] = d[i] }
        s[6] = tanh(reconJ)
        s[7] = tanh(forecastJ)
        s[8 + familySlot(cls)] = 1
        s[13] = min(spo2Abs, 4) / 4
        return s
    }

    public static func distance(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return .infinity }
        var acc = 0.0
        for i in 0..<n { acc += (a[i] - b[i]) * (a[i] - b[i]) }
        return sqrt(acc / Double(n))
    }

    public static func isQuality(_ lab: WatchdogEventLabel) -> Bool {
        lab == .wristOff || lab == .gap || lab == .artifactSpike
            || lab == .safetyBound || lab == .mixedRejected
    }

    public static func isExplainedFamily(_ lab: WatchdogEventLabel) -> Bool {
        switch lab {
        case .workoutWalk, .workoutRun, .workoutCycle, .workoutLift,
             .postWorkout, .normalSleep, .normalStillAwake, .forecastDriftOnly:
            return true
        default:
            return false
        }
    }

    public static func isAbnormal(_ lab: WatchdogEventLabel) -> Bool {
        lab == .abnormalStillTachycardia || lab == .abnormalMultiDirection || lab == .abnormalSpo2Still
    }

    public static func isWorkout(_ lab: WatchdogEventLabel) -> Bool {
        lab == .workoutWalk || lab == .workoutRun || lab == .workoutCycle || lab == .workoutLift
    }

    public static func compatible(teacher: WatchdogEventLabel, candidate: WatchdogEventLabel,
                                  explained: Bool) -> Bool {
        if isQuality(teacher) || isQuality(candidate) { return false }
        if teacher == .forecastDriftOnly { return candidate == .forecastDriftOnly }
        if isWorkout(teacher) { return candidate == teacher }
        if teacher == .postWorkout || teacher == .normalSleep || teacher == .normalStillAwake {
            return candidate == teacher
        }
        if explained { return false }
        return isAbnormal(teacher) && isAbnormal(candidate)
    }

    public static func learnable(_ lab: WatchdogEventLabel, explained: Bool) -> Bool {
        if isQuality(lab) { return false }
        return explained ? isExplainedFamily(lab) : isAbnormal(lab)
    }

    public func nearestMature(_ sig: [Double]) -> (WatchdogEventLabel, Double)? {
        var best: (WatchdogEventLabel, Double)?
        for p in prototypes where p.n >= Self.matureN {
            let dist = Self.distance(sig, p.mean)
            if best == nil || dist < best!.1 {
                best = (p.label, dist)
            }
        }
        return best
    }

    /// Teacher is UniTS/TimesFM `what`. Memory may only rename inside the same explained/abnormal family.
    public mutating func observe(teacher: WatchdogEventLabel, explained: Bool,
                                 sig: [Double]) -> WatchdogEventLabel {
        var out = teacher
        if let (lab, dist) = nearestMature(sig), dist < Self.matchTau,
           Self.compatible(teacher: teacher, candidate: lab, explained: explained) {
            out = lab
        }
        learn(label: out, explained: explained, sig: sig)
        return out
    }

    public mutating func learn(label: WatchdogEventLabel, explained: Bool, sig: [Double]) {
        guard Self.learnable(label, explained: explained), sig.count == Self.dim else { return }
        if let i = prototypes.firstIndex(where: { $0.label == label }) {
            var p = prototypes[i]
            p.mean = zip(p.mean, sig).map { (1 - Self.gain) * $0 + Self.gain * $1 }
            p.n += 1
            prototypes[i] = p
        } else {
            prototypes.append(WatchdogEventPrototype(label: label, mean: sig, n: 1))
        }
    }
}
