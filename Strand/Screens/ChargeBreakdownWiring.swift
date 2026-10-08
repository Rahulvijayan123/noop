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
// folded HRV baseline the drivers scored with, so the header and the rows agree by construction.
enum ChargeBreakdownWiring {

    /// The ordered Charge driver rows for `row` plus its confidence tier, folded from the visible `days`
    /// history, or nil when the night cannot honestly score (missing HRV or resting HR, or an HRV
    /// baseline that is not yet usable) so the sheet hides rather than showing fabricated rows.
    ///
    /// `sleepPerfPercent` is the Rest composite on a 0-100 scale, divided by 100 here to match
    /// `AnalyticsEngine`'s `sleepPerf` form, so the Sleep row scores against the headline's own input.
    ///
    /// The resting-HR and respiration baselines are passed only when usable. `RecoveryScorer` and
    /// `chargeDrivers` both apply that gate themselves since #1990, so these are belt-and-braces rather
    /// than load-bearing; they are kept because they say the intent at the call site, which is where a
    /// reader looks first.
    ///
    /// CAUSAL (D4-02): the baselines are the engine's as-of fold (`Baselines.chargeBaselinesAsOf`) over the
    /// days strictly BEFORE `row`, never `row` itself or any later day, with the same epochs the engine
    /// uses (`hrvBaselineEpoch` for HRV, `recoveryBaselineEpoch` for resting HR and respiration). A past
    /// day opened from the day picker is therefore explained against the baseline it was scored against,
    /// not one that already absorbed the following weeks.
    static func breakdown(days: [DailyMetric],
                          row: DailyMetric,
                          sleepPerfPercent: Double?,
                          hrvBaselineEpoch: Double = 0,
                          recoveryBaselineEpoch: Double = 0) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        guard let hrv = row.avgHrv, let rhr = row.restingHr else { return nil }
        // PERF: one as-of pass per series over the prior days only; the guard above still runs first.
        // #2315: the recalibration epochs are honoured exactly as the engine does. `0` (no recalibration)
        // folds the full prior history, so a user who never recalibrated sees no epoch effect.
        var hrvByDay: [String: Double?] = [:]
        var rhrByDay: [String: Double?] = [:]
        var respByDay: [String: Double?] = [:]
        for d in days where d.day < row.day {
            hrvByDay[d.day] = d.avgHrv
            rhrByDay[d.day] = d.restingHr.map(Double.init)
            respByDay[d.day] = d.respRateBpm
        }
        hrvByDay[row.day] = row.avgHrv
        rhrByDay[row.day] = row.restingHr.map(Double.init)
        respByDay[row.day] = row.respRateBpm
        let asOf = Baselines.chargeBaselinesAsOf(
            importedHrv: [:], importedRhr: [:], importedResp: [:],
            computedHrv: hrvByDay, computedRhr: rhrByDay, computedResp: respByDay, computedSkin: [:],
            sourceByDay: [:], defaultSource: "", hrvEpoch: hrvBaselineEpoch,
            recoveryEpoch: recoveryBaselineEpoch).byDay[row.day]
        guard let base = asOf?.profile, let hrvBase = base.hrv, hrvBase.usable else { return nil }
        let rhrBase = base.restingHR
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: (rhrBase?.usable ?? false) ? rhrBase : nil,
            respBaseline: base.resp,
            sleepPerf: sleepPerfPercent.map { $0 / 100.0 },
            skinTempDev: row.skinTempDevC)
        return (drivers, ScoreConfidence.charge(recovery: row.recovery, hrvBaseline: hrvBase))
    }
}
