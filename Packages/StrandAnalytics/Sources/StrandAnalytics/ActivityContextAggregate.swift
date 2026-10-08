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
// SETTLED VALUES FOR REST. A still or lying row that follows a walk or a change of position starts with the
// recovery transient (heart rate still falling, RMSSD still rising) for about two minutes. Each such row stores
// its statistics over the settled part too (`hrMeanSettled`, `rmssdSettled` and its components, over
// `[settledFrom, end)`). The heart rate and RMSSD of a class are taken from settled evidence only: a row's settled
// values when it has them, its whole values when nothing settles it (or it predates the field), and nothing from a
// row that is all transient or a ride in a vehicle (not rest). Only when a class has no settled evidence at all is
// it read from those rows instead, and `hrSettled` / `rmssdSettled` say so (`hrMin` / `hrMax` follow the same rows).
// A row's settled values are weighted by how much of `[settledFrom, end)` lies inside the window, so a window that
// covers only a row's transient reads none of them. `unsettledSeconds` is how much of the class sat inside settling
// windows (the part inside the window), `inVehicleSeconds` how much was a ride and `inVehicleHrMean` the rides'
// own heart rate. Movement rows have no settling, so their values are unchanged.
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
    /// Recording duration (seconds) of the window that contributed the most RMSSD beats; nil with no RMSSD.
    /// Carried so a consumer never presents a 60-s window as comparable to a 15-min one (spec §9.5).
    public var rmssdWindowDominantS: Int?
    public var respRateBpm: Double?
    public var stepTicks: Int
    public var cadenceSpm: Double?
    /// ElderNet gait metrics over the class's intervals that carried them (reported, not evidence); nil without.
    public var gait: ActivityGaitSummary? = nil
    /// Seconds of the class inside settling windows after movement or a change of position
    /// (`ActivityContextInterval.settlingSeconds`, scaled to the part inside the window).
    public var unsettledSeconds: Int = 0
    /// Seconds of the class that were a ride in a vehicle (`detail == .inVehicle`).
    public var inVehicleSeconds: Int = 0
    /// Evidence-weighted heart rate over the class's ride seconds alone; nil without a ride. The class's `hrMean`
    /// leaves rides out whenever it has anything else (and then says so through `hrSettled`), so a consumer that
    /// describes a ride reads it here.
    public var inVehicleHrMean: Double? = nil
    /// Whether `hrMean` / `rmssd` came from settled, non-vehicle evidence only (true), or had to fall back to rows
    /// that include the post-transition transient or a ride (false). True when there is no value at all. `hrMin` /
    /// `hrMax` come from the same rows as `hrMean`.
    public var hrSettled: Bool = true
    public var rmssdSettled: Bool = true

    /// Share of the class's seconds inside settling windows.
    public var unsettledShare: Double { seconds > 0 ? min(1, Double(unsettledSeconds) / Double(seconds)) : 0 }
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
            /// Settled (or never unsettled) non-vehicle evidence, and the fallback from everything else.
            var hr = Pool(), hrFallback = Pool()
            var hrMin: Int?, hrMax: Int?, hrMinFallback: Int?, hrMaxFallback: Int?
            var vehicleHr = Pool()
            var rmssd = RRPool(), rmssdFallback = RRPool()
            var unsettled = 0.0, vehicle = 0.0
            var respSum = 0.0, respWeight = 0.0
            var ticks = 0.0
            var cadenceSum = 0.0, cadenceWeight = 0.0
            var gait: GaitTotals?
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
            // The settled part of the row, `[settledFrom, end)`, and how much of it lies inside the window: a row's
            // settled values were measured over that part only, so they are weighted by its overlap with the window,
            // not by the whole row's. A window that sees only the row's transient reads none of its settled values.
            let settledFrom = iv.settledFrom.map { min(max($0, iv.start), iv.end) }
            let settledSpan = settledFrom.map { iv.end - $0 } ?? 0
            let settledShare = settledSpan > 0 ? Double(max(0, hi - max(lo, settledFrom!))) / Double(settledSpan) : 0
            // Settling applies to the row and leaves part of it unread (all transient, or too short a remainder).
            let settling = iv.settlingSeconds ?? 0
            let transient = settling > 0
            if transient {
                if let sf = settledFrom, sf > iv.start {
                    // The settling seconds lie in `[start, settledFrom)`: count the part of that inside the window.
                    let lead = Double(max(0, min(hi, sf) - lo))
                    a.unsettled += lead * min(1, Double(settling) / Double(sf - iv.start))
                } else {
                    a.unsettled += Double(settling) * share
                }
            }
            if iv.isInVehicle { a.vehicle += overlap }
            let plain = !transient && !iv.isInVehicle
            if iv.isInVehicle, let mean = iv.hrMean, iv.hrSamples > 0 {
                a.vehicleHr.add(mean, Double(iv.hrSamples) * share)
            }
            // The extremes go with the pool the row's heart rate went to, so a class's range never comes from rows its
            // mean left out (a settled row's extremes are its whole row's: no settled extremes are stored).
            var rested: Bool?
            if let mean = iv.hrMeanSettled, let n = iv.hrSamplesSettled, n > 0, !iv.isInVehicle, settledShare > 0 {
                a.hr.add(mean, Double(n) * settledShare); rested = true
            } else if let mean = iv.hrMean, iv.hrSamples > 0 {
                if plain { a.hr.add(mean, Double(iv.hrSamples) * share); rested = true }
                else { a.hrFallback.add(mean, Double(iv.hrSamples) * share); rested = false }
            }
            if let rested {
                if let lowest = iv.hrMin {
                    if rested { a.hrMin = min(a.hrMin ?? lowest, lowest) } else { a.hrMinFallback = min(a.hrMinFallback ?? lowest, lowest) }
                }
                if let highest = iv.hrMax {
                    if rested { a.hrMax = max(a.hrMax ?? highest, highest) } else { a.hrMaxFallback = max(a.hrMaxFallback ?? highest, highest) }
                }
            }
            // Scale the sums by the same partial-overlap share the other evidence-weighted terms use: an
            // interval crossing the window edge contributes only its covered fraction of evidence.
            if let sumSq = iv.rrDiffSqSumMs2Settled, let count = iv.rrDiffCountSettled, count > 0, !iv.isInVehicle,
               settledShare > 0 {
                a.rmssd.add(sumSq: sumSq, count: count, share: settledShare, windowS: settledSpan)
            } else if let components = Self.diffComponents(iv) {
                if plain {
                    a.rmssd.add(sumSq: components.sumSq, count: components.count, share: share, windowS: iv.durationSeconds)
                } else {
                    a.rmssdFallback.add(sumSq: components.sumSq, count: components.count, share: share,
                                        windowS: iv.durationSeconds)
                }
            }
            if let r = iv.respRateBpm, iv.respBreaths > 0 {
                let w = Double(iv.respBreaths) * share
                a.respSum += r * w; a.respWeight += w
            }
            a.ticks += Double(iv.stepTicks) * share
            if let c = iv.cadenceSpm { a.cadenceSum += c * overlap; a.cadenceWeight += overlap }
            if let g = iv.gait {
                // The part of the interval inside the window carries its share of the gait windows.
                let part = GaitTotals(summary: g).scaled(share)
                if a.gait == nil { a.gait = part } else { a.gait!.add(part) }
            }
            byClass[iv.activityClass] = a
        }

        let classes = byClass.map { cls, a -> ActivityClassAggregate in
            let settledHr = a.hr.weight > 0
            let hr = settledHr ? a.hr : a.hrFallback
            let rr = a.rmssd.count > 0 ? a.rmssd : a.rmssdFallback
            return ActivityClassAggregate(
                activityClass: cls, seconds: Int(a.seconds.rounded()), intervals: a.intervals,
                meanConfidence: a.seconds > 0 ? a.confidence / a.seconds : 0,
                hrMean: hr.weight > 0 ? hr.sum / hr.weight : nil,
                hrMin: settledHr ? a.hrMin : a.hrMinFallback, hrMax: settledHr ? a.hrMax : a.hrMaxFallback,
                hrSamples: Int(hr.weight.rounded()),
                rmssd: rr.count > 0 ? (rr.sumSq / rr.count).squareRoot() : nil,
                rmssdIntervals: rr.intervals,
                rmssdWindowDominantS: dominantWindowSeconds(rr.durBeats),
                respRateBpm: a.respWeight > 0 ? a.respSum / a.respWeight : nil,
                stepTicks: Int(a.ticks.rounded()),
                cadenceSpm: a.cadenceWeight > 0 ? a.cadenceSum / a.cadenceWeight : nil,
                gait: a.gait.flatMap { $0.isEmpty ? nil : $0.summary },
                unsettledSeconds: Int(a.unsettled.rounded()), inVehicleSeconds: Int(a.vehicle.rounded()),
                inVehicleHrMean: a.vehicleHr.weight > 0 ? a.vehicleHr.sum / a.vehicleHr.weight : nil,
                hrSettled: a.hr.weight > 0 || a.hrFallback.weight == 0,
                rmssdSettled: a.rmssd.count > 0 || a.rmssdFallback.count == 0)
        }.sorted { l, r in
            l.seconds != r.seconds ? l.seconds > r.seconds : l.activityClass.rawValue < r.activityClass.rawValue
        }
        return ActivityWindowSummary(from: from, to: to, coveredSeconds: Int(covered.rounded()), classes: classes)
    }

    /// Evidence-weighted mean.
    private struct Pool {
        var sum = 0.0, weight = 0.0
        mutating func add(_ value: Double, _ w: Double) { sum += value * w; weight += w }
    }

    /// Successive-difference components, the intervals behind them and their beats by recording duration.
    private struct RRPool {
        var sumSq = 0.0, count = 0.0, intervals = 0
        var durBeats: [Int: Double] = [:]
        mutating func add(sumSq s: Double, count c: Int, share: Double, windowS: Int) {
            sumSq += s * share; count += Double(c) * share; intervals += 1
            durBeats[windowS, default: 0] += Double(c) * share
        }
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

    /// Dominant recording duration: the window length that contributed the most RMSSD beats. Ties go to the
    /// longer window, so the label names the definition the number is dominated by. Nil with no RMSSD beats.
    private static func dominantWindowSeconds(_ beatsByDuration: [Int: Double]) -> Int? {
        var dominant: Int?
        var dominantBeats = -1.0
        for (duration, beats) in beatsByDuration.sorted(by: { $0.key < $1.key }) where beats >= dominantBeats {
            dominant = duration; dominantBeats = beats
        }
        return dominant
    }
}
