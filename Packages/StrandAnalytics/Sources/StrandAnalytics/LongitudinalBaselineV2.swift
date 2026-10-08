import Foundation

// LongitudinalBaselineV2.swift — the v2.clinical additions to Layer 1: 3-month and long-term copies, the frozen
// anchor, significance-tested trends, drift against the anchor, and the change-point episode.
//
// Design rules (docs/BASELINE_WATCHDOG_V2.md §2):
//   • Every copy is built from days strictly before T (with the 7-day gap of the 60-day copy).
//   • The comparison center is never moved along a trend. Trend is reported; a real ramp therefore shows up as
//     a growing deviation from the anchor instead of being absorbed.
//   • The anchor is deterministic (first 14 clean days of the epoch that fit in 42 calendar days, the
//     PhysiologyContext frozen-reference rule) and only an explicit epoch event moves it.
//   • Nothing here changes which nights train; quality gates and confounder exclusion are the v1 ones.

/// How much history a series' usual rests on.
public enum LBMaturity: String, Equatable, Sendable, Codable {
    /// Fewer than 4 clean days in the 60-day window: nothing shown.
    case none
    /// 4 … (established − 1) clean days: shown as provisional, never alerting.
    case learning
    /// At or above the established count (14, 21 for activity-mix series): may alert.
    case established
    /// Established, an anchor exists, and the long-term copy has ≥ 56 days.
    case mature
}

/// Why an epoch (and so a new anchor) started.
public struct LBReferenceEpoch: Equatable, Sendable, Codable {
    public enum Reason: String, Equatable, Sendable, Codable {
        case deviceFamilyChange = "device_family_change"
        case userReanchor = "user_reanchor"
        case treatmentStart = "treatment_start"
    }
    public var startDay: String
    public var reason: Reason
    /// Days after `startDay` excluded from the new anchor (wash-in). 0 for device change and user re-anchor.
    public var washInDays: Int
    public init(startDay: String, reason: Reason, washInDays: Int = 0) {
        self.startDay = startDay
        self.reason = reason
        self.washInDays = washInDays
    }
}

/// Frozen reference of one series in one epoch.
public struct LBAnchorSnapshot: Equatable, Sendable, Codable {
    public var id: String
    public var epochStartDay: String?
    public var epochReason: String
    public var fromDay: String
    public var toDay: String
    public var center: Double
    public var scale: Double
    public var n: Int
    public var nEff: Double
    /// Lag-1 autocorrelation estimated on the anchor window (bias-corrected); reused for the drift level SE.
    public var phi: Double
    public var centerSE: Double
    public var centerDisplay: Double
    public var bandLoDisplay: Double
    public var bandHiDisplay: Double
}

public struct LBTrendSnapshot: Equatable, Sendable, Codable {
    public var windowDays: Int
    public var n: Int
    /// Math units per week (ln units for HRV) with the Sen CI.
    public var slopePerWeek: Double
    public var lowerPerWeek: Double
    public var upperPerWeek: Double
    /// Display units per week (ms/week for HRV via the center, bpm/week, °C/week …).
    public var slopePerWeekDisplay: Double
    public var p: Double
    /// p < `Params.trendAlpha` AND the Sen CI excludes 0 AND the window change exceeds `Params.trendMinScales`
    /// robust scales.
    public var significant: Bool
    /// +1 rising, −1 falling, 0 not significant.
    public var direction: Int
    /// True when the significant direction is the series' "worse" direction.
    public var worse: Bool
}

public struct LBDriftSnapshot: Equatable, Sendable, Codable {
    public var levelDays: Int
    public var levelN: Int
    /// Median of the last `levelDays` clean days (math space) and its display value.
    public var level: Double
    public var levelDisplay: Double
    public var anchorCenter: Double
    /// level − anchor (math space) and display delta (ms for HRV, bpm, °C …).
    public var diff: Double
    public var diffDisplay: Double
    /// diff / anchor scale (robust SD units).
    public var diffScales: Double
    public var z: Double
    public var p: Double
    public var significant: Bool
    public var direction: Int
    public var worse: Bool
}

public struct LBChangeSnapshot: Equatable, Sendable, Codable {
    public var open: Bool
    /// +1 up, −1 down, 0 none.
    public var direction: Int
    public var onsetDay: String?
    public var alarmDay: String?
    /// Median of (value − pre-change center) since onset, math space.
    public var magnitude: Double?
    public var statisticPos: Double
    public var statisticNeg: Double
    /// The 60-day copy is currently the held pre-change copy.
    public var holdingCopy: Bool
    public var holdUntilDay: String?
    public var worse: Bool

    public static let none = LBChangeSnapshot(open: false, direction: 0, onsetDay: nil, alarmDay: nil,
                                              magnitude: nil, statisticPos: 0, statisticNeg: 0,
                                              holdingCopy: false, holdUntilDay: nil, worse: false)
}

extension LongitudinalBaseline {

    // MARK: v2 parameters

    public enum V2 {
        public static let paramSet = "v2.clinical"
        public static let version90 = "gap7-med-mad-sscorr-90"
        public static let versionHistorical = "gap7-med-mad-sscorr-365"
        public static let lookback90 = 90
        public static let lookbackHistorical = 365
        public static let n90Show = 14
        public static let nHistoricalShow = 28
        public static let nHistoricalMature = 56
        /// Two-sided alpha of the displayed usual band (and `isOffUsual`): the band is a 95 % predictive interval.
        public static let bandAlpha = 0.05
        /// Anchor rule (PhysiologyContext frozen reference): first `anchorDays` clean days that fit within
        /// `anchorMaxSpanDays` calendar days after the epoch start (+ wash-in).
        /// 28 clean days (within 56 calendar days): the anchor's own center SE then roughly matches the 14-day
        /// level's, so a 2 SD sustained shift reaches the drift test's p < 0.005 (a 14-day anchor could not).
        public static let anchorDays = 28
        public static let anchorMaxSpanDays = 56
        /// Drift: median of the last 14 clean days vs the anchor. Significant at p < 0.005 AND ≥ 0.75 anchor
        /// scales AND corroborated (a significant 28- or 90-day trend in the same direction, or a change episode in
        /// the same direction that is open or alarmed after the anchor window) — three requirements, so slow drift
        /// is reported without a daily coin flip.
        public static let driftLevelDays = 14
        public static let driftMinLevelN = 7
        public static let driftAlpha = 0.005
        public static let drift28Alpha = 0.001
        public static let driftPersistAlpha = 0.05
        public static let driftMinScales = 0.75
        /// Trend: autocorrelation-corrected Mann–Kendall p < 0.01, Sen 95 % CI excluding 0, and a fitted change
        /// over the window of at least 0.5 robust scales.
        public static let trendAlpha = 0.01
        public static let trendMinScales = 0.5
        /// Days the pre-change 60-day copy is held after a CUSUM alarm (then the adaptive copy resumes; the
        /// anchor keeps the shift visible).
        public static let changeHoldDays = 28
        /// Out-of-sample tail calibration: ring length, minimum samples for full weight, clamp.
        public static let oosRing = 120
        public static let oosDelayDays = 14
        public static let oosFullWeightN = 60
        public static let oosMaxFactor = 1.6
        public static let cusum = Stats.CusumConfig()
        /// Days after the last logged felt-ill day that the pre-illness snapshot stays the personal reference.
        public static let illnessFreezeRecoveryDays = 14
    }

    // MARK: Final-day enrichment (computed once for T, not inside the replay)

    /// Adds the 3-month and long-term copies, anchor, trends and drift to an evaluation of day T.
    static func enrichV2(_ ev: inout LBEvaluation, tEpoch: Int, series: LBSeries,
                         byDay: [Int: LBDailyObservation], dayLogs: [String: LBDayLog],
                         epochStart: Int?, referenceEpochs: [LBReferenceEpoch],
                         todayMath: Double?, todayNative: Double?) {
        let spec = seriesSpec(series)
        let p = params(for: series)

        func clean(_ e: Int) -> Bool { nightIsClean(e, dayLogs: dayLogs) }
        func pairs(_ lo: Int, _ hi: Int) -> [(epoch: Int, value: Double)] {
            guard lo <= hi else { return [] }
            return (lo...hi).compactMap { e in
                if let es = epochStart, e < es { return nil }
                guard clean(e), let x = trainableMath(byDay[e], series: series) else { return nil }
                return (e, x)
            }
        }
        let hiGap = tEpoch - Params.gapDays - 1

        func snapshot(_ c: Stats.WindowCopy, version: String, held: Bool, lastUpdate: String?) -> LBCopySnapshot {
            let tcrit = Stats.studentTCritical(alpha: V2.bandAlpha, df: c.df)
            let half = tcrit * c.predictiveScale * ev.calibrationFactor
            var s = LBCopySnapshot(center: c.center, spread: c.scale,
                                   centerDisplay: toDisplay(c.center, series: series),
                                   bandLoDisplay: toDisplay(c.center - half, series: series),
                                   bandHiDisplay: toDisplay(c.center + half, series: series),
                                   deltaDisplay: todayNative.flatMap { tn in
                                       todayMath.map { tm in
                                           series.usesLog ? tn - toDisplay(c.center, series: series) : tm - c.center
                                       }
                                   },
                                   z: todayMath.map { ($0 - c.center) / c.scale },
                                   n: c.n, coverage: Double(c.n) / Double(max(1, c.toEpoch - c.fromEpoch + 1)),
                                   lastUpdate: lastUpdate, version: version, held: held)
            s.nEff = c.nEff
            s.predictiveSpread = c.predictiveScale
            s.df = c.df
            s.pToday = todayMath.map { Stats.predictive($0, c).p }
            s.fromDay = isoFromEpochDay(c.fromEpoch)
            s.toDay = isoFromEpochDay(c.toEpoch)
            return s
        }

        // 3-month and long-term copies.
        let p90 = pairs(tEpoch - V2.lookback90, hiGap)
        if let c = Stats.windowCopy(pairs: p90, floor: spec.floor, minN: V2.n90Show,
                                    fromEpoch: tEpoch - V2.lookback90, toEpoch: hiGap) {
            ev.copy90 = snapshot(c, version: V2.version90, held: false,
                                 lastUpdate: p90.last.map { isoFromEpochDay($0.epoch) })
        }
        let pHist = pairs(tEpoch - V2.lookbackHistorical, hiGap)
        if let c = Stats.windowCopy(pairs: pHist, floor: spec.floor, minN: V2.nHistoricalShow,
                                    fromEpoch: tEpoch - V2.lookbackHistorical, toEpoch: hiGap) {
            ev.copyHistorical = snapshot(c, version: V2.versionHistorical, held: false,
                                         lastUpdate: pHist.last.map { isoFromEpochDay($0.epoch) })
        }

        // Anchor.
        let anchorEpoch = currentAnchorEpoch(tEpoch: tEpoch, trialEpochStart: epochStart,
                                             referenceEpochs: referenceEpochs)
        if let a = anchor(series: series, byDay: byDay, dayLogs: dayLogs, tEpoch: tEpoch,
                          epochStart: anchorEpoch.start, reason: anchorEpoch.reason) {
            ev.anchor = a
        }

        // Trends: newest 28 and 90 calendar days of clean days strictly before T, plus T when trainable.
        let worseDir = p.worse
        func isWorse(_ dir: Int) -> Bool {
            switch worseDir {
            case .higher: return dir > 0
            case .lower: return dir < 0
            case .either: return dir != 0
            }
        }
        let refScale = ev.copyLong?.spread ?? ev.anchor?.scale ?? spec.floor
        let refCenter = ev.copyLong?.center ?? ev.anchor?.center
        func trendSnapshot(days: Int) -> LBTrendSnapshot? {
            var pts = pairs(tEpoch - days, tEpoch - 1)
            if let x = todayMath, clean(tEpoch) { pts.append((tEpoch, x)) }
            guard let t = Stats.trend(pairs: pts) else { return nil }
            let fitted = abs(t.slopePerDay) * Double(t.spanDays)
            let ciExcludesZero = t.lowerPerDay > 0 || t.upperPerDay < 0
            let sig = t.p < V2.trendAlpha && ciExcludesZero && fitted >= V2.trendMinScales * refScale
            let dir = sig ? (t.slopePerDay > 0 ? 1 : -1) : 0
            let perWeekDisplay: Double
            if series.usesLog, let c = refCenter {
                perWeekDisplay = toDisplay(c + t.slopePerDay * 7, series: series) - toDisplay(c, series: series)
            } else {
                perWeekDisplay = t.slopePerDay * 7
            }
            return LBTrendSnapshot(windowDays: days, n: t.n, slopePerWeek: t.slopePerDay * 7,
                                   lowerPerWeek: t.lowerPerDay * 7, upperPerWeek: t.upperPerDay * 7,
                                   slopePerWeekDisplay: perWeekDisplay, p: t.p, significant: sig,
                                   direction: dir, worse: isWorse(dir))
        }
        ev.trend28 = trendSnapshot(days: 28)
        ev.trend90 = trendSnapshot(days: 90)

        // Drift: recent level vs anchor. Two levels are tested:
        //   • 14-day median: p < `driftAlpha` (0.005), ≥ `driftMinScales`, AND corroborated by a same-direction
        //     significant trend or change episode (open, or alarmed after the anchor window);
        //   • 28-day median: p < `drift28Alpha` (0.001), ≥ `driftMinScales`; a four-week sustained offset is its
        //     own persistence evidence, so no corroboration is required.
        // φ for both level SEs comes from the 28-day anchor window (a 14-day window cannot estimate it).
        if let a = ev.anchor {
            let anchorEnd = isoEpochDay(a.toDay) ?? Int.min
            func level(days: Int) -> (level: Double, n: Int, se: Double)? {
                var recent = pairs(tEpoch - days + 1, tEpoch - 1).filter { $0.epoch > anchorEnd }
                if let x = todayMath, clean(tEpoch) { recent.append((tEpoch, x)) }
                let vals = recent.map(\.value)
                guard vals.count >= max(V2.driftMinLevelN, days / 2),
                      let lv = PhysiologyContext.RobustStats.median(vals) else { return nil }
                let nEff = Stats.effectiveN(vals.count, phi: a.phi)
                return (lv, vals.count, PhysiologyContext.RobustStats.medianStandardErrorFactor * a.scale / nEff.squareRoot())
            }
            func test(_ l: (level: Double, n: Int, se: Double)) -> (diff: Double, z: Double, p: Double, dir: Int) {
                let se = (l.se * l.se + a.centerSE * a.centerSE).squareRoot()
                let diff = l.level - a.center
                let z = diff / max(se, 1e-12)
                return (diff, z, 2 * (1 - Stats.normalCDF(abs(z))), diff > 0 ? 1 : (diff < 0 ? -1 : 0))
            }
            let l14 = level(days: V2.driftLevelDays)
            let l28 = level(days: 28)
            var chosen: (days: Int, l: (level: Double, n: Int, se: Double), t: (diff: Double, z: Double, p: Double, dir: Int), sig: Bool)?
            if let l = l14 {
                let t = test(l)
                let trendAgrees = [ev.trend28, ev.trend90].contains { $0?.significant == true && $0?.direction == t.dir }
                let changeAgrees = (ev.change.open && ev.change.direction == t.dir)
                    || (ev.carry.lastEpisodeDirection == t.dir && (ev.carry.lastEpisodeAlarmEpoch ?? Int.min) > anchorEnd)
                let sig = t.p < V2.driftAlpha && abs(t.diff) >= V2.driftMinScales * a.scale && (trendAgrees || changeAgrees)
                chosen = (V2.driftLevelDays, l, t, sig)
            }
            if let l = l28 {
                let t = test(l)
                let sig = t.p < V2.drift28Alpha && abs(t.diff) >= V2.driftMinScales * a.scale
                if chosen == nil || (sig && chosen?.sig != true) { chosen = (28, l, t, sig) }
            }
            // Two-stage persistence: a change episode already DETECTED the shift (alarmed after the anchor window,
            // same direction); confirming that it has not reverted needs only p < 0.05 on the 28-day (else 14-day)
            // level and ≥ `driftMinScales`. Detection and confirmation together keep the null rate ≈ 0
            // (calibration tests) while a real sustained shift stays visible after the adaptive copies follow it.
            if chosen?.sig != true, ev.carry.lastEpisodeDirection != 0,
               (ev.carry.lastEpisodeAlarmEpoch ?? Int.min) > anchorEnd,
               let l = l28 ?? l14 {
                let t = test(l)
                if t.dir == ev.carry.lastEpisodeDirection, t.p < V2.driftPersistAlpha,
                   abs(t.diff) >= V2.driftMinScales * a.scale {
                    chosen = (l28 != nil ? 28 : V2.driftLevelDays, l, t, true)
                }
            }
            if let c = chosen {
                let diffDisplay = series.usesLog
                    ? toDisplay(c.l.level, series: series) - toDisplay(a.center, series: series) : c.t.diff
                ev.drift = LBDriftSnapshot(levelDays: c.days, levelN: c.l.n, level: c.l.level,
                                           levelDisplay: toDisplay(c.l.level, series: series), anchorCenter: a.center,
                                           diff: c.t.diff, diffDisplay: diffDisplay, diffScales: c.t.diff / a.scale,
                                           z: c.t.z, p: c.t.p, significant: c.sig, direction: c.sig ? c.t.dir : 0,
                                           worse: c.sig && isWorse(c.t.dir))
            }
        }

        // Maturity.
        let established = ev.establishedLong
        if ev.nLong < Params.nLongShow {
            ev.maturity = .none
        } else if !established {
            ev.maturity = .learning
        } else if ev.anchor != nil, (ev.copyHistorical?.n ?? 0) >= V2.nHistoricalMature {
            ev.maturity = .mature
        } else {
            ev.maturity = .established
        }
    }

    /// The anchor epoch in force at T: the newest of (trial epoch start, reference epochs) on or before T.
    static func currentAnchorEpoch(tEpoch: Int, trialEpochStart: Int?,
                                   referenceEpochs: [LBReferenceEpoch]) -> (start: Int?, reason: String) {
        var best: (Int, String)? = trialEpochStart.map { ($0, LBReferenceEpoch.Reason.treatmentStart.rawValue) }
        for e in referenceEpochs {
            guard let s = isoEpochDay(e.startDay) else { continue }
            let start = s + max(0, e.washInDays)
            guard start <= tEpoch else { continue }
            if best == nil || start > best!.0 { best = (start, e.reason.rawValue) }
        }
        return (best?.0, best?.1 ?? "history_start")
    }

    /// Deterministic frozen anchor: the first `anchorDays` (28) clean trainable days on or after the epoch start
    /// that fit inside `anchorMaxSpanDays` (56) calendar days, all strictly before T − gap (so today's week never builds its
    /// own anchor). Recomputable from the same tape, so persistence is not required for correctness.
    public static func anchor(series: LBSeries, byDay: [Int: LBDailyObservation], dayLogs: [String: LBDayLog],
                              tEpoch: Int, epochStart: Int?, reason: String) -> LBAnchorSnapshot? {
        let spec = seriesSpec(series)
        let last = tEpoch - Params.gapDays - 1
        let candidates: [(epoch: Int, value: Double)] = byDay.keys.sorted().compactMap { e in
            guard e <= last else { return nil }
            if let s = epochStart, e < s { return nil }
            guard nightIsClean(e, dayLogs: dayLogs), let x = trainableMath(byDay[e], series: series) else { return nil }
            return (e, x)
        }
        guard candidates.count >= V2.anchorDays else { return nil }
        for i in 0...(candidates.count - V2.anchorDays) {
            let window = Array(candidates[i..<(i + V2.anchorDays)])
            guard window.last!.epoch - window.first!.epoch + 1 <= V2.anchorMaxSpanDays else { continue }
            guard let c = Stats.windowCopy(pairs: window, floor: spec.floor, minN: V2.anchorDays, trimK: 0,
                                           fromEpoch: window.first!.epoch, toEpoch: window.last!.epoch) else {
                return nil
            }
            let tcrit = Stats.studentTCritical(alpha: V2.bandAlpha, df: c.df)
            let half = tcrit * c.predictiveScale
            let from = isoFromEpochDay(window.first!.epoch), to = isoFromEpochDay(window.last!.epoch)
            return LBAnchorSnapshot(id: "anchor-v1:\(series.rawValue):\(from)",
                                    epochStartDay: epochStart.map(isoFromEpochDay), epochReason: reason,
                                    fromDay: from, toDay: to, center: c.center, scale: c.scale, n: c.n,
                                    nEff: c.nEff, phi: c.phi, centerSE: c.centerSE,
                                    centerDisplay: toDisplay(c.center, series: series),
                                    bandLoDisplay: toDisplay(c.center - half, series: series),
                                    bandHiDisplay: toDisplay(c.center + half, series: series))
        }
        return nil
    }

    /// True while the illness episode that began at `onset` is current: through the last consecutive logged
    /// felt-ill day after onset plus `V2.illnessFreezeRecoveryDays`.
    static func illnessFreezeActive(onset: String, dayLogs: [String: LBDayLog], asOf t: String) -> Bool {
        guard let o = isoEpochDay(onset), let te = isoEpochDay(t) else { return false }
        var lastIll = o
        var e = o + 1
        while e <= te, dayLogs[isoFromEpochDay(e)]?.feltIll == true {
            lastIll = e
            e += 1
        }
        return te <= lastIll + V2.illnessFreezeRecoveryDays
    }

    /// Scores every civil day from the first observation through `through` in ONE pass (the same online
    /// carry chain `evaluate` builds) and returns each day's evaluation. Days in `fullDays` (or every day when
    /// nil) also get the final-day enrichment (90/365-day copies, anchor, trends, drift). No trial overlay; the
    /// day logs and reference epochs are honoured. O(days) instead of `evaluate`-per-day's O(days²).
    public static func replayDaily(series: LBSeries, observations: [LBDailyObservation], through t: String,
                                   dayLogs: [String: LBDayLog] = [:],
                                   referenceEpochs: [LBReferenceEpoch] = [],
                                   fullDays: Set<String>? = nil) -> [LBEvaluation] {
        let byDay = indexByDay(observations, series: series)
        guard let tEpoch = isoEpochDay(t), let start = byDay.keys.min(), start <= tEpoch else { return [] }
        var state = LBCarry.empty
        var out: [LBEvaluation] = []
        out.reserveCapacity(tEpoch - start + 1)
        for d in start...tEpoch {
            let full = fullDays.map { $0.contains(isoFromEpochDay(d)) } ?? true
            let ev = scoreOneDay(tEpoch: d, series: series, byDay: byDay, carry: state, epochStart: nil,
                                 dayLogs: dayLogs, final: full, referenceEpochs: referenceEpochs)
            state = ev.carry
            out.append(ev)
        }
        return out
    }

    /// Out-of-sample tail factor ≥ 1: how much wider the realised |z| tail is than the model's 97.5 % point,
    /// shrunk toward 1 when the ring is short. Never narrows a band.
    static func oosCalibrationFactor(_ ring: [Double]) -> Double {
        let xs = ring.filter(\.isFinite)
        guard xs.count >= 20, let q = PhysiologyContext.RobustStats.quantile(xs, 1 - V2.bandAlpha) else { return 1 }
        let nominal = Stats.normalQuantile(1 - V2.bandAlpha / 2)
        let r = min(V2.oosMaxFactor, max(1, q / nominal))
        let w = min(1, Double(xs.count) / Double(V2.oosFullWeightN))
        return 1 + w * (r - 1)
    }
}
