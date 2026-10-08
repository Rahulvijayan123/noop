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
    static func breakdown(days: [DailyMetric],
                          row: DailyMetric,
                          sleepPerfPercent: Double?,
                          hrvBaselineEpoch: Double = 0,
                          recoveryBaselineEpoch: Double = 0,
                          dayLogs: [String: LBDayLog] = [:]) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
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
}
