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
//
// RMSSD DOES NOT AVERAGE. RMSSD is sqrt(mean(ΔNN²)) — a root-mean-square, not a mean — so combining two
// intervals' RMSSD by averaging the two already-square-rooted numbers (even weighted by beats) is simply
// the wrong formula: sqrt(a) and sqrt(b) do not combine into sqrt(a+b) by averaging. The ONLY correct way
// to combine RMSSD across intervals is to recombine their shared successive-difference components —
// sqrt(Σ rrDiffSqSumMs2 / Σ rrDiffCount) — which is exactly `ActivityContextInterval.rrDiffSqSumMs2` /
// `rrDiffCount`. This never invents a cross-interval difference: each interval's components were formed
// gap-aware from ITS OWN beats only (`HRVAnalyzer.rmssdSumSquaresGapAware`), so summing the pairs never
// creates a successive difference across the boundary between two intervals, let alone across the real
// gap of missing data that can sit between them.
//
// SDNN IS NOT ROLLED UP HERE, DELIBERATELY. SDNN is the spread of every NN interval in a window, not a
// successive-difference statistic, and it changes substantially with recording duration — a longer window
// captures more of the slow HR drift SDNN is sensitive to. Combining SDNN across windows of different
// span (which is what an interval rollup would do: a 90 s interval next to a 12 min one) produces a number
// that is not comparable to either input's SDNN, so this aggregator does not report one. A caller that
// needs a comparable SDNN wants `HRVWindow`'s canonical fixed-duration windows instead.

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
            var rmssdSumSq = 0.0, rmssdDiffCount = 0.0, rmssdIntervals = 0
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
            if let components = Self.diffComponents(iv) {
                // Scale the sum by the same partial-overlap share the other evidence-weighted terms use:
                // an interval crossing the window edge contributes only its covered fraction of evidence.
                a.rmssdSumSq += components.sumSq * share
                a.rmssdDiffCount += Double(components.count) * share
                a.rmssdIntervals += 1
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
                rmssd: a.rmssdDiffCount > 0 ? (a.rmssdSumSq / a.rmssdDiffCount).squareRoot() : nil,
                rmssdIntervals: a.rmssdIntervals,
                respRateBpm: a.respWeight > 0 ? a.respSum / a.respWeight : nil,
                stepTicks: Int(a.ticks.rounded()),
                cadenceSpm: a.cadenceWeight > 0 ? a.cadenceSum / a.cadenceWeight : nil)
        }.sorted { l, r in
            l.seconds != r.seconds ? l.seconds > r.seconds : l.activityClass.rawValue < r.activityClass.rawValue
        }
        return ActivityWindowSummary(from: from, to: to, coveredSeconds: Int(covered.rounded()), classes: classes)
    }

    /// `iv`'s own successive-difference components, for the correct cross-interval RMSSD recombination
    /// above. When `iv` carries them directly (built or re-derived since `rrDiffSqSumMs2`/`rrDiffCount`
    /// existed) they are used as-is. A row written before those columns existed carries only the legacy
    /// summary (`rmssd`, `rrBeats`): its components are recovered by assuming its clean beats were fully
    /// contiguous (`count == rrBeats − 1`, the common case — a Malik rejection inside one interval is rare
    /// and this is the only information a legacy row retains), so it still recombines correctly instead of
    /// being silently dropped from the rollup. nil when `iv` has no RMSSD at all.
    private static func diffComponents(_ iv: ActivityContextInterval) -> (sumSq: Double, count: Int)? {
        if iv.rrDiffCount > 0 { return (iv.rrDiffSqSumMs2, iv.rrDiffCount) }
        guard let r = iv.rmssd else { return nil }
        let count = iv.rrBeats - 1
        guard count >= 1 else { return nil }
        return (r * r * Double(count), count)
    }
}
