import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Charge breakdown wiring (pure, testable)
//
// The fold-and-score wiring behind the "What shaped it" sheet, lifted out of the two views that had
// byte-identical private copies of it (TodayView.chargeBreakdown / CoupledView.chargeBreakdown). They
// differed only in which row they display and where their sleep-performance number comes from, both of
// which are inputs, so one function serves both.
//
// Extracted so it can be TESTED. Living inside a `View` struct as a private method meant the only way to
// exercise it was to render the view, so the iOS side of this path had no test at all while the Android
// twin did. Kotlin twin: `TodayScoring.recoveryChargeDrivers`.
//
// Pure: no SwiftUI state, no I/O, no store access. Nothing here invents a number. The drivers come from
// `RecoveryScorer.chargeDrivers` and the tier is SURFACED from `ScoreConfidence.charge` against the same
// folded HRV baseline the drivers scored with, so the header and the rows agree by construction. The folds
// are `ChargeBaselines.asOf`, the engine's own causal Charge baselines (BaselineStandard fix A).
enum ChargeBreakdownWiring {

    /// The ordered Charge driver rows for `row` plus its confidence tier, scored against the baselines AS OF
    /// the row's night (BaselineStandard fix A: the same causal, ln-HRV `ChargeBaselines.asOf` the engine
    /// scores the headline with, so a past night's rows never see that night or any later one), or nil when
    /// the night cannot honestly score (missing HRV or resting HR, or an HRV baseline that is not yet usable)
    /// so the sheet hides rather than showing fabricated rows.
    ///
    /// `sleepPerfPercent` is the Rest composite on a 0-100 scale, divided by 100 here to match
    /// `AnalyticsEngine`'s `sleepPerf` form, so the Sleep row scores against the headline's own input.
    ///
    /// The epochs are the two Recalibrate epochs (HRV, and the Charge-wide recovery one for resting HR /
    /// respiration / skin), and `dayLogs` the morning logs whose confounded nights stay out of the folds,
    /// exactly as the engine passes them. The skin row reads the stored deviation only when it IS a deviation
    /// (`BaselineStandard.skinDeviation`): an imported row's column holds an absolute wrist °C.
    ///
    /// ENGINE FIRST (D4-02 review): when the engine scored this very number this session (`engine` holds the
    /// row's day with the same Charge), its persisted per-night drivers and tier are returned verbatim, so the
    /// sheet agrees with the headline by construction. The causal fold below is the fallback (an imported
    /// score, a day outside the engine's scan window, or before the first pass).
    static func breakdown(days: [DailyMetric],
                          row: DailyMetric,
                          sleepPerfPercent: Double?,
                          hrvBaselineEpoch: Double = 0,
                          recoveryBaselineEpoch: Double = 0,
                          dayLogs: [String: LBDayLog] = [:],
                          engine: [IntelligenceEngine.Computed] = []) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        if let scored = engineNight(row: row, engine: engine), !scored.drivers.isEmpty {
            return (scored.drivers, scored.confidence)
        }
        guard let hrv = row.avgHrv, let rhr = row.restingHr else { return nil }
        // #2315: fold with the recalibration epochs, exactly as the engine does, so these rows and the tier
        // score against the same post-Recalibrate nights as the headline. `0` = no recalibration.
        var context = BaselineStandard.Context(dayLogs: dayLogs)
        for m in BaselineStandard.Metric.allCases {
            context.epochs[m] = m == .hrvRmssd ? hrvBaselineEpoch : recoveryBaselineEpoch
        }
        func series(_ pick: (DailyMetric) -> Double?) -> [String: Double] {
            BaselineStandard.series(days, day: \.day, value: pick)
        }
        let resolved = ChargeBaselines.asOf(ChargeBaselines.Inputs(
            hrvMerged: series(\.avgHrv),
            rhrMerged: series { $0.restingHr.map(Double.init) },
            respMerged: series(\.respRateBpm),
            skinAbsolute: series(\.skinTempC),
            context: context, through: row.day))
        let baselines = resolved.baselines(for: row.day)
        guard let hrvBase = baselines.hrv, hrvBase.usable else { return nil }
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: baselines.restingHR,
            respBaseline: baselines.resp,
            sleepPerf: sleepPerfPercent.map { $0 / 100.0 },
            skinTempDev: BaselineStandard.skinDeviation(row.skinTempDevC),
            hrvScale: baselines.hrvScale)
        return (drivers, ScoreConfidence.charge(recovery: row.recovery, hrvBaseline: hrvBase))
    }

    /// The engine's computed night for `row`, only when it carries the SAME Charge the row shows (so its
    /// drivers / tier explain this number, not a vendor import that won the merge). The tolerance absorbs a
    /// storage round-trip only; any real difference is a different score.
    static func engineNight(row: DailyMetric, engine: [IntelligenceEngine.Computed]) -> IntelligenceEngine.Computed? {
        guard let shown = row.recovery,
              let c = engine.first(where: { $0.day == row.day }),
              let scored = c.recovery, abs(scored - shown) < 0.05 else { return nil }
        return c
    }

    /// The Charge confidence tier for `row` (D4-V02 review: the watch chip on Today). The engine's own
    /// per-night tier when it scored this number; else `ScoreConfidence.charge` against the CAUSAL HRV
    /// baseline, folded from the days strictly before `row` with the recalibration epoch, never from `row`
    /// itself or later days, so a past day opened from the picker keeps the tier it was scored with. With
    /// no row (nothing to show yet) the forward-looking end-of-history fold is the honest "today" state.
    static func chargeConfidence(days: [DailyMetric], row: DailyMetric?, hrvBaselineEpoch: Double,
                                 engine: [IntelligenceEngine.Computed] = []) -> ScoreConfidence {
        if let row, let scored = engineNight(row: row, engine: engine) { return scored.confidence }
        let prior = row.map { r in days.filter { $0.day < r.day } } ?? days
        let hrvBase = Baselines.foldHistory(prior.map(\.avgHrv), dayKeys: prior.map(\.day),
                                            cfg: Baselines.hrvCfg, baselineEpoch: hrvBaselineEpoch)
        return ScoreConfidence.charge(recovery: row?.recovery, hrvBaseline: hrvBase)
    }
}
