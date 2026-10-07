import Foundation
import WhoopStore

// IllnessBaselines.swift — the personal-baseline z-scores the illness early warning feeds
// `IllnessSignalEngine` / `IllnessDistance` with (BaselineStandard fix C, audit 2026-10-07 "Illness").
//
// What was wrong (AppModel.applyIllnessSignal):
//   • skin z = recentMean / 0.3 on the TRIMODAL `skinTempDevC` column (WHOOP CSV absolute °C, Oura deviation,
//     NOOP deviation): an imported 33.4 °C row read z ≈ 110;
//   • the trust gate was RHR-trusted OR HRV-trusted;
//   • HRV was z-scored on raw ms;
//   • the alert labels used a plain mean of the base while the z used the EWMA fold (two estimators);
//   • the windows were ROWS (the last 2 rows vs 28 rows ending 3 rows ago), and confounded days built the base.
//
// What this does. The recent window is the last 2 CALENDAR days; the base is the 28 calendar days ending 3 days
// before the newest day (one guard day between them, as before). Each metric's base is the standard causal
// Winsorized-EWMA fold (`BaselineStandard.causalFold`) of that window only: ln for HRV (rule 1), SDNN and
// confounded days out (rules 1, 3), restarting at a regime change or reference epoch (rule 6), missing days
// missing (rule 7), standard configs with floors at or above the shared ones (rule 5; skin uses
// `VitalBands.skinTempDeviationCfg`, σ floor 0.376 °C ≥ 0.1). Skin uses deviation rows only (|v| ≤ 5 °C).
// No z below 4 base days (rule 4). The recent value is the mean of the recent days in MODEL space (a geometric
// mean for HRV), and the label deltas are taken against the SAME fold centre as the z.

public enum IllnessBaselines {

    /// Calendar days in the recent window (today and yesterday).
    public static let recentDays = 2
    /// Calendar days between the recent window and the base (kept from the shipped shape).
    public static let guardDays = 1
    /// Calendar days in the base window.
    public static let baseDays = 28

    /// One signal's comparison. `zIllnessward` is oriented so positive = illness-ward (RHR up, HRV down,
    /// respiration up, skin temperature up).
    public struct Signal: Equatable, Sendable {
        public let metric: BaselineStandard.Metric
        /// nil when there is no comparison (no recent value, or the base is not usable).
        public let zIllnessward: Double?
        /// The base fold is usable (≥ 4 valid days, not stale).
        public let usable: Bool
        /// The base fold is trusted (≥ 14 valid days, not stale).
        public let trusted: Bool
        /// Valid base days.
        public let n: Int
        /// The recent value in native units (geometric mean for HRV); nil when no recent day had one.
        public let recent: Double?
        /// The base centre in native units (exp of the ln centre for HRV); nil when not usable.
        public let baseline: Double?

        /// A reading and a usable base: the signal can take part in the engine's corroboration.
        public var present: Bool { zIllnessward != nil }
        /// `recent − baseline` in native units, from the same estimator as the z.
        public var delta: Double? { recent.flatMap { r in baseline.map { r - $0 } } }

        /// The engine's reading: absent when there is no recent value, present-but-not-counted when the base
        /// is not usable (the shipped `present: false` shape), else the oriented z.
        public var engineReading: IllnessSignalEngine.SignalReading? {
            guard recent != nil else { return nil }
            guard let z = zIllnessward else { return IllnessSignalEngine.SignalReading(zIllnessward: 0, present: false) }
            return IllnessSignalEngine.SignalReading(zIllnessward: z)
        }
    }

    public struct Result: Equatable, Sendable {
        public let restingHR: Signal
        public let hrv: Signal
        public let respiration: Signal
        public let skinTemp: Signal
        /// The engine's raise gate: resting-HR AND HRV bases both trusted (was OR).
        public var baselineTrusted: Bool { restingHR.trusted && hrv.trusted }

        /// The four readings for `IllnessSignalEngine.evaluate`.
        public var engineInputs: IllnessSignalEngine.Inputs {
            IllnessSignalEngine.Inputs(restingHR: restingHR.engineReading, skinTemp: skinTemp.engineReading,
                                       hrv: hrv.engineReading, respiration: respiration.engineReading)
        }

        /// The SAME illness-ward z-vector for the parallel `IllnessDistance` read (nil where not present).
        public var distanceFeatures: IllnessDistance.FeatureVector {
            IllnessDistance.FeatureVector(restingHR: restingHR.zIllnessward, rmssd: hrv.zIllnessward,
                                          skinTemp: skinTemp.zIllnessward, respiration: respiration.zIllnessward)
        }
    }

    /// Evaluate the four illness signals. `today` is the newest day of the recent window (defaults to the
    /// newest day in `days`).
    public static func evaluate(days: [DailyMetric], context: BaselineStandard.Context = BaselineStandard.Context(),
                                today: String? = nil) -> Result {
        let newest = today ?? days.map(\.day).max() ?? ""
        func signal(_ metric: BaselineStandard.Metric, illnessUp: Bool,
                    _ pick: (DailyMetric) -> Double?) -> Signal {
            let series = BaselineStandard.series(days, day: \.day, value: pick)
            return evaluate(series: series, metric: metric, newest: newest, illnessUp: illnessUp, context: context)
        }
        return Result(
            restingHR: signal(.restingHR, illnessUp: true) { $0.restingHr.map(Double.init) },
            hrv: signal(.hrvRmssd, illnessUp: false) { $0.avgHrv },
            respiration: signal(.respiration, illnessUp: true) { $0.respRateBpm },
            skinTemp: signal(.skinTempDeviation, illnessUp: true) { BaselineStandard.skinDeviation($0.skinTempDevC) })
    }

    /// One metric's signal from a `[day: native value]` series.
    public static func evaluate(series: [String: Double], metric: BaselineStandard.Metric, newest: String,
                                illnessUp: Bool, context: BaselineStandard.Context) -> Signal {
        let none = Signal(metric: metric, zIllnessward: nil, usable: false, trusted: false, n: 0,
                          recent: nil, baseline: nil)
        guard let end = BaselineStandard.epochDay(newest) else { return none }
        let recentStart = end - (recentDays - 1)
        let baseLast = recentStart - guardDays - 1
        let baseFirst = baseLast - (baseDays - 1)

        // Recent value in model space; an SDNN day is not comparable with an RMSSD base (rule 1).
        var recentModel: [Double] = []
        for d in recentStart...end {
            let k = BaselineStandard.dayKey(d)
            guard context.comparable(k, metric: metric), let v = series[k],
                  BaselineStandard.plausible(v, metric), let x = BaselineStandard.toModel(v, metric) else { continue }
            recentModel.append(x)
        }
        let recentMean = recentModel.isEmpty ? nil : recentModel.reduce(0, +) / Double(recentModel.count)

        // The base: only the 28 base-window days, folded causally and read as of the first recent day, so the
        // guard day and the recent days never enter and a regime change between base and recent resets it.
        var base: [String: Double] = [:]
        for d in baseFirst...baseLast {
            let k = BaselineStandard.dayKey(d)
            if let v = series[k] { base[k] = v }
        }
        // Padded over the whole calendar window, so missing days count as missing (staleness, rule 7).
        let fold = BaselineStandard.causalFold(base, metric: metric, from: BaselineStandard.dayKey(baseFirst),
                                               through: BaselineStandard.dayKey(recentStart), context: context)
        let state = fold.before[BaselineStandard.dayKey(recentStart)] ?? Baselines.emptyState(BaselineStandard.cfg(metric))
        let usable = state.usable
        let z: Double? = (usable ? recentMean : nil).map { m in
            let raw = Baselines.deviation(m, state: state).z
            return illnessUp ? raw : -raw
        }
        return Signal(metric: metric, zIllnessward: z, usable: usable, trusted: state.trusted, n: state.nValid,
                      recent: recentMean.map { BaselineStandard.fromModel($0, metric) },
                      baseline: usable ? BaselineStandard.fromModel(state.baseline, metric) : nil)
    }
}
