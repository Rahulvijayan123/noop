import Foundation

/// Running daily movement-energy tape. Same Layer 1 copies as other series; never mixed with HR or steps.
/// Samples are counted once (`ts` must be newer than `lastTs`). Minutes are unique unix minutes.
public struct LBImuDayAccumulator: Equatable, Sendable, Codable {
    public var day: String
    public var energySum: Double
    public var sampleCount: Int
    public var lastTs: Int
    public var minuteKeys: [Int]

    public init(day: String, energySum: Double = 0, sampleCount: Int = 0,
                lastTs: Int = 0, minuteKeys: [Int] = []) {
        self.day = day
        self.energySum = energySum
        self.sampleCount = sampleCount
        self.lastTs = lastTs
        self.minuteKeys = minuteKeys
    }

    public var meanEnergy: Double? {
        guard sampleCount > 0 else { return nil }
        return energySum / Double(sampleCount)
    }

    public var minutes: Double { Double(Set(minuteKeys).count) }

    public var observation: LBDailyObservation {
        guard let mean = meanEnergy else {
            return LBDailyObservation(day: day, value: nil, qualityStatus: .missing,
                                      qualityReason: .unknown, streamPresent: false)
        }
        var o = LongitudinalBaseline.observation(
            day: day, native: mean, streamPresent: true, sleepHrOnly: false, series: .wakingImuEnergy)
        o.coverage = minutes
        return LongitudinalBaseline.applyCoverageGate(o, series: .wakingImuEnergy)
    }

    /// Adds only samples with `ts > lastTs`. Returns whether anything changed.
    @discardableResult
    public mutating func add(_ samples: [WatchdogIMUSample]) -> Bool {
        var maxTs = lastTs
        var seen = Set(minuteKeys)
        var changed = false
        for s in samples {
            guard s.ts > lastTs else { continue }
            energySum += LBImuDaily.sampleEnergy(s)
            sampleCount += 1
            if s.ts > maxTs { maxTs = s.ts }
            seen.insert(s.ts / 60)
            changed = true
        }
        guard changed else { return false }
        lastTs = maxTs
        minuteKeys = seen.sorted()
        return true
    }
}

public enum LBImuDaily {
    public static func sampleEnergy(_ s: WatchdogIMUSample) -> Double {
        if let d = s.dynAccel, d.isFinite { return abs(d) }
        let mag = (s.x * s.x + s.y * s.y + s.z * s.z).squareRoot()
        return abs(mag - 1.0)
    }

    /// Mean |dynAccel| (or | |g| − 1 |) over samples newer than `afterTs`.
    public static func dayEnergy(from samples: [WatchdogIMUSample],
                                 afterTs: Int = 0) -> (energy: Double, minutes: Double, maxTs: Int)? {
        var acc = LBImuDayAccumulator(day: "", lastTs: afterTs)
        guard acc.add(samples), let mean = acc.meanEnergy else { return nil }
        if afterTs == 0 && acc.sampleCount < 8 { return nil }
        return (mean, acc.minutes, acc.lastTs)
    }

    /// 100 Hz window → one day increment. Cadence is a feature, not a physiological gate.
    public static func dayEnergy(from features: ImuActivityFeatures,
                                 minutes: Double) -> (energy: Double, minutes: Double)? {
        guard features.sampleCount >= 8, minutes > 0, features.accelEnergyG.isFinite else { return nil }
        return (max(0, features.accelEnergyG), minutes)
    }

    public static func merge(existing: LBDailyObservation?,
                             day: String,
                             energy: Double,
                             minutes: Double) -> LBDailyObservation {
        let priorMin = existing?.coverage ?? 0
        let priorVal = existing?.value ?? 0
        let totalMin = priorMin + minutes
        let mean: Double
        if priorMin > 0, existing?.value != nil {
            mean = (priorVal * priorMin + energy * minutes) / max(totalMin, 1)
        } else {
            mean = energy
        }
        var o = LongitudinalBaseline.observation(
            day: day, native: mean, streamPresent: true, sleepHrOnly: false, series: .wakingImuEnergy)
        o.coverage = totalMin
        return LongitudinalBaseline.applyCoverageGate(o, series: .wakingImuEnergy)
    }
}
