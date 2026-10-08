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
    ///
    /// ENGINE FIRST (D4-02 review): when the engine scored this very number this session (`engine` holds the
    /// row's day with the same Charge), its persisted per-night drivers and tier are returned verbatim. Those
    /// were scored against the night's era- and method-scoped as-of baseline, which `repo.days` (merged rows,
    /// no per-day source or method) cannot reproduce, so the sheet then agrees with the headline by
    /// construction. The causal fold below is the fallback (an imported score, a day outside the engine's
    /// scan window, or before the first pass); it is causal but single-method and not era-scoped.
    static func breakdown(days: [DailyMetric],
                          row: DailyMetric,
                          sleepPerfPercent: Double?,
                          hrvBaselineEpoch: Double = 0,
                          recoveryBaselineEpoch: Double = 0,
                          engine: [IntelligenceEngine.Computed] = []) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        if let scored = engineNight(row: row, engine: engine), !scored.drivers.isEmpty {
            return (scored.drivers, scored.confidence)
        }
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
