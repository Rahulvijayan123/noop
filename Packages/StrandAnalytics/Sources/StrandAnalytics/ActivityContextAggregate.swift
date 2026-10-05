import Foundation

// ActivityContextAggregate.swift — "what did HR / HRV / breathing look like while the wearer was doing X?"
//
// The stored intervals each carry their own measurements. Rolling them up by canonical class answers the
// question downstream consumers actually ask (the coach, a scoring model choosing which HRV windows are
// comparable): resting HRV is the HRV of the *still* intervals, not of a day that included a commute.
//
// Weighting is by the amount of evidence, not the number of intervals: heart rate by its sample count,
// HRV by its clean beats, breathing by its breath intervals, cadence by seconds. An interval that crosses
// the window's edge contributes in proportion to the part inside it. Measurements are never invented:
// a class with no HRV-grade interval reports no HRV.

public struct ActivityClassAggregate: Equatable, Sendable {
    public var activityClass: ActivityClass
    public var seconds: Int
    public var intervals: Int
    /// Seconds-weighted belief that the wearer was in this class's family.
    public var meanConfidence: Double
    public var hrMean: Double?
    public var hrMin: Int?
    public var hrMax: Int?
    public var hrSamples: Int
    /// Beat-weighted RMSSD over the class's HRV-grade intervals.
    public var rmssd: Double?
    /// Intervals that contributed an RMSSD.
    public var rmssdIntervals: Int
    public var respRateBpm: Double?
    public var stepTicks: Int
    public var cadenceSpm: Double?
}

public struct ActivityWindowSummary: Equatable, Sendable {
    public var from: Int
    public var to: Int
    /// Seconds of `[from, to)` that stored intervals account for (any class, including unknown).
    public var coveredSeconds: Int
    /// Largest share first; ties broken by class code so the order is stable.
    public var classes: [ActivityClassAggregate]

    public var windowSeconds: Int { max(0, to - from) }
    public var coverage: Double { windowSeconds > 0 ? Double(coveredSeconds) / Double(windowSeconds) : 0 }

    public func aggregate(for c: ActivityClass) -> ActivityClassAggregate? { classes.first { $0.activityClass == c } }
}

public enum ActivityContextAggregator {

    public static func summarize(_ intervals: [ActivityContextInterval], from: Int, to: Int) -> ActivityWindowSummary {
        struct Acc {
            var seconds = 0.0, confidence = 0.0
            var intervals = 0
            var hrSum = 0.0, hrWeight = 0.0
            var hrMin: Int?, hrMax: Int?
            var rmssdSum = 0.0, rmssdWeight = 0.0, rmssdIntervals = 0
            var respSum = 0.0, respWeight = 0.0
            var ticks = 0.0
            var cadenceSum = 0.0, cadenceWeight = 0.0
        }
        var byClass: [ActivityClass: Acc] = [:]
        var covered = 0.0

        for iv in intervals {
            let lo = max(iv.start, from), hi = min(iv.end, to)
            guard hi > lo, iv.end > iv.start else { continue }
            let overlap = Double(hi - lo)
            let share = overlap / Double(iv.end - iv.start)
            covered += overlap
            var a = byClass[iv.activityClass] ?? Acc()
            a.seconds += overlap
            a.confidence += iv.confidence * overlap
            a.intervals += 1
            if let mean = iv.hrMean, iv.hrSamples > 0 {
                let w = Double(iv.hrSamples) * share
                a.hrSum += mean * w; a.hrWeight += w
            }
            if let lowest = iv.hrMin { a.hrMin = min(a.hrMin ?? lowest, lowest) }
            if let highest = iv.hrMax { a.hrMax = max(a.hrMax ?? highest, highest) }
            if let r = iv.rmssd, iv.rrBeats > 0 {
                let w = Double(iv.rrBeats) * share
                a.rmssdSum += r * w; a.rmssdWeight += w; a.rmssdIntervals += 1
            }
            if let r = iv.respRateBpm, iv.respBreaths > 0 {
                let w = Double(iv.respBreaths) * share
                a.respSum += r * w; a.respWeight += w
            }
            a.ticks += Double(iv.stepTicks) * share
            if let c = iv.cadenceSpm { a.cadenceSum += c * overlap; a.cadenceWeight += overlap }
            byClass[iv.activityClass] = a
        }

        let classes = byClass.map { cls, a in
            ActivityClassAggregate(
                activityClass: cls, seconds: Int(a.seconds.rounded()), intervals: a.intervals,
                meanConfidence: a.seconds > 0 ? a.confidence / a.seconds : 0,
                hrMean: a.hrWeight > 0 ? a.hrSum / a.hrWeight : nil, hrMin: a.hrMin, hrMax: a.hrMax,
                hrSamples: Int(a.hrWeight.rounded()),
                rmssd: a.rmssdWeight > 0 ? a.rmssdSum / a.rmssdWeight : nil, rmssdIntervals: a.rmssdIntervals,
                respRateBpm: a.respWeight > 0 ? a.respSum / a.respWeight : nil,
                stepTicks: Int(a.ticks.rounded()),
                cadenceSpm: a.cadenceWeight > 0 ? a.cadenceSum / a.cadenceWeight : nil)
        }.sorted { l, r in
            l.seconds != r.seconds ? l.seconds > r.seconds : l.activityClass.rawValue < r.activityClass.rawValue
        }
        return ActivityWindowSummary(from: from, to: to, coveredSeconds: Int(covered.rounded()), classes: classes)
    }
}
