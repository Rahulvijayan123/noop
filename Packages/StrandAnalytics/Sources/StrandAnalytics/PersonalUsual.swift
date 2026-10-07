import Foundation
import WhoopStore

// PersonalUsual.swift — "your usual" for the surfaces that quote one number against a personal baseline: the
// Today "HRV X% over baseline" insight and the Coach's readiness / context blocks (BaselineStandard fixes H, I).
//
// What was wrong. Today's insight compared tonight's HRV with the plain MEAN of EVERY prior row's `avgHrv`
// (whole history, raw ms, any method), and the Coach quoted "30-day averages" as the mean of the last 30 ROWS
// INCLUDING today. Neither was causal-by-calendar, neither used ln for HRV, and the Coach never said how many
// nights stood behind the number.
//
// What this does. The usual is `BaselineStandard.windowReference`: the median of the 28 CALENDAR days strictly
// before the day (rules 2, 7), HRV on ln and shown via exp (rule 1), SDNN / confounded / pre-epoch / other-regime
// days out (rules 1, 3, 6), and nothing below 4 valid days (rule 4). The count is always returned so a surface
// can say "usual of N nights".

public enum PersonalUsual {

    /// The reference window, in calendar days.
    public static let windowDays = BaselineStandard.referenceWindowDays

    /// The causal usual for `metric` as of `day`: the 28 calendar days strictly before it.
    public static func usual(days: [DailyMetric], metric: BaselineStandard.Metric, asOf day: String,
                             windowDays: Int = windowDays,
                             context: BaselineStandard.Context = BaselineStandard.Context()) -> BaselineStandard.Reference {
        let series: [String: Double]
        switch metric {
        case .hrvRmssd: series = BaselineStandard.series(days, day: \.day, value: \.avgHrv)
        case .restingHR: series = BaselineStandard.series(days, day: \.day) { $0.restingHr.map(Double.init) }
        case .respiration: series = BaselineStandard.series(days, day: \.day, value: \.respRateBpm)
        case .skinTempDeviation:
            series = BaselineStandard.series(days, day: \.day) { BaselineStandard.skinDeviation($0.skinTempDevC) }
        case .skinTempAbsolute: series = BaselineStandard.series(days, day: \.day, value: \.skinTempC)
        }
        return BaselineStandard.windowReference(series, metric: metric, asOf: day, windowDays: windowDays,
                                                context: context)
    }

    /// Today's HRV as a whole-percent difference from the causal 28-day usual (ln median, RMSSD only), or nil:
    /// below 4 usable nights, on an SDNN night, or when the difference is outside the method-mismatch guard.
    public static func hrvDeltaPercent(todayMs: Double, day: String, days: [DailyMetric],
                                       context: BaselineStandard.Context = BaselineStandard.Context()) -> Int? {
        guard context.comparable(day, metric: .hrvRmssd) else { return nil }
        let ref = usual(days: days, metric: .hrvRmssd, asOf: day, context: context)
        return hrvDeltaPercent(todayMs: todayMs, reference: ref)
    }

    /// The percentage against an already-built reference.
    public static func hrvDeltaPercent(todayMs: Double, reference: BaselineStandard.Reference) -> Int? {
        guard todayMs > 0, reference.usable else { return nil }
        return percent(todayMs, centre: reference.centerNative)
    }

    /// The same read when the caller already holds the prior RMSSD values (no dates): their ln median.
    /// Below `BaselineStandard.minUsableDays` values → nil.
    public static func hrvDeltaPercent(todayMs: Double, priorRmssdMs: [Double]) -> Int? {
        let ln = priorRmssdMs.compactMap { BaselineStandard.toModel($0, .hrvRmssd) }
        guard todayMs > 0, ln.count >= BaselineStandard.minUsableDays,
              let med = PhysiologyContext.RobustStats.median(ln) else { return nil }
        return percent(todayMs, centre: exp(med))
    }

    /// The plain-text usual a Coach prompt quotes: "58 ms (28-day usual, median of 25 nights)", or
    /// "still learning (2 of 4 nights)" below the minimum — never a number off fewer than 4 nights.
    public static func phrase(_ ref: BaselineStandard.Reference, unit: String, digits: Int = 0) -> String {
        guard ref.usable else {
            return "still learning (\(ref.n) of \(BaselineStandard.minUsableDays) nights)"
        }
        let v = String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), ref.centerNative)
        return "\(v)\(unit) (\(windowDays)-day usual, median of \(ref.n) nights)"
    }

    /// #696 method-mismatch guard, kept: a real night-to-night move never doubles or halves HRV, so a delta
    /// outside [−50 %, +100 %] is almost always an SDNN-vs-RMSSD (or units) artefact and is not shown. Applied to
    /// the rounded percentage the surface would print.
    static func percent(_ today: Double, centre: Double) -> Int? {
        guard centre > 0 else { return nil }
        let pct = Int(((today - centre) / centre * 100).rounded())
        guard pct <= 100, pct >= -50 else { return nil }
        return pct
    }
}
