import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// MARK: - Metric presentation
//
// How each catalog metric reads on its detail page: which chart, which scale, which colour, how a value
// prints, which statistics sit under the chart, which secondary visuals say something the chart cannot,
// and what the About card explains. One pure table (docs/DESIGN_SYSTEM.md, Chart selection), keyed by the
// descriptor's key and source, so the page has no per-metric switches of its own and every choice here is
// pinned by `MetricPresentationTests`.
//
// Presentation only: nothing here reads, scores or stores data. Values arrive already loaded; the display
// transforms below (kg → lb, °C → °F, a 0–1 efficiency shown as a percentage, Effort on its chosen scale)
// change how a number is drawn, never what is stored.

struct MetricPresentation: Equatable {

    /// The primary chart.
    enum Chart: Equatable {
        /// One score per day on its fixed scale, coloured by the scorer's bands (Charge, Rest), a ramp
        /// (Effort) or one colour.
        case scoreBars(ScoreFill)
        /// A daily total (steps, calories, minutes). `aggregation` decides how a week or month bins.
        case totals(ChartAggregation)
        /// A nightly or daily vital: line + gaps, fitted with a minimum span.
        case line(minSpan: Double)
        /// A percentage on a fixed scale (blood oxygen, sleep efficiency), with an optional rule.
        case fixedPoints(domain: ClosedRange<Double>, reference: Double?, joined: Bool)
        /// A deviation around zero (skin temperature against the personal baseline).
        case diverging
        /// Parts of a whole per night or day.
        case stacked(Stack)
        /// An estimate held until the next one (weekly scores, VO2 max).
        case stepLine(fixed: ClosedRange<Double>?, minSpan: Double)
        /// Irregular readings with a smoothed direction (weight, body composition).
        case sparsePoints(minSpan: Double, references: [Double])
        /// A level on a 1–5 scale (mood).
        case dotStrip
        /// Asleep as a share of need, against 100 %.
        case needBars
    }

    enum ScoreFill: Equatable {
        /// Charge: `RecoveryScorer.bandRedMax` / `bandYellowMax`.
        case charge
        /// Rest-family scores: the same thresholds, the top band in the rest colour.
        case rest
        /// Effort: the continuous `effortTint` ramp on the chosen 0–100 / 0–21 scale.
        case effort
        /// The WHOOP-import day stress, 0–3, in `StressBand` bands.
        case dayStress
        /// A 0–100 score without bands of its own in the app (Mi Band stress).
        case single
    }

    enum Stack: Equatable {
        /// Deep / REM / light minutes with one stage highlighted.
        case sleepStages(highlight: String)
        /// Deep + REM minutes.
        case restorative
        /// Asleep and awake-in-bed minutes.
        case inBed
        /// Heart-rate zone 1–5 minutes.
        case zones
    }

    /// How a value prints. Every style returns the number without its unit; the unit is drawn beside it.
    enum ValueStyle: Equatable {
        case number(decimals: Int)
        /// Minutes as "6 h 42 m".
        case duration
        /// A signed deviation, "+0.3".
        case signed(decimals: Int)
        /// A level on a named scale: a whole level prints its name ("Good"), an average its number ("3.4").
        case level
    }

    /// One statistic cell under the chart, for the visible range.
    enum Stat: Equatable {
        case average
        case low
        case high
        /// Shortest / longest night (durations).
        case shortest
        case longest
        case vsPrevious
        /// The personal typical range (only when the baseline is trusted).
        case typical
        /// Days (or nights) at or above a threshold, e.g. Charge ≥ 67.
        case atLeast(Double)
        /// Nights below a threshold (SpO2 < 95 %).
        case below(Double)
        /// Nights above a signed threshold (skin temperature > +0.5).
        case above(Double)
        /// Readings in the range, labelled by cadence ("Nights", "Days logged", "Readings").
        case count
        case latest
        /// Latest minus the first reading in the range.
        case change
        case total
        case bestDay
        case highestWithDate
        case lowestNight
        case warmest
        case coolest
        case perActiveDay
        case activeDays
        case shareOfSleep
        case mostCommon
        case zoneHighShare
        case metNeed
        case noDebt
        case thisWeek
        case weeklyAverage
        case weeksAtLeast(Double)
        case bestWeek
        case vsAge
    }

    /// A card under the primary chart that says something the chart cannot.
    enum Secondary: Equatable {
        /// Days in each score band over the range.
        case bandMix
        /// Mood check-ins per level.
        case distribution
        /// The average per weekday (3M and longer, where a weekly rhythm can show).
        case weekdayPattern
        /// The strap's banked readings over the last 24 hours (skin temperature, SpO2).
        case banked
        /// The server's intraday series (cloud only).
        case intraday
    }

    /// The personal baseline fold behind a typical band.
    enum Band: Equatable { case hrv, restingHR, resp, skinAbsolute }

    /// How often the series has a value; decides line breaks and how the count reads.
    enum Cadence: Equatable {
        case daily, nightly, weekly, sparse, workoutDays, loggedDays
    }

    enum Tint: Equatable {
        case charge, effort, rest, stress, cyan, purple, amber, rose

        var color: Color {
            switch self {
            case .charge: return StrandPalette.chargeColor
            case .effort: return StrandPalette.effortColor
            case .rest: return StrandPalette.restColor
            case .stress: return StrandPalette.stressColor
            case .cyan: return StrandPalette.metricCyan
            case .purple: return StrandPalette.metricPurple
            case .amber: return StrandPalette.metricAmber
            case .rose: return StrandPalette.metricRose
            }
        }
    }

    let key: String
    let source: String
    let chart: Chart
    let tint: Tint
    let valueStyle: ValueStyle
    let cadence: Cadence
    let defaultRange: ChartRange
    let stats: [Stat]
    let secondary: [Secondary]
    /// The personal typical band (and dashed baseline) to draw once trusted.
    let band: Band?
    /// The whole series is an estimate (on-device step estimate, estimated VO2 max): drawn hollow.
    let isEstimateSeries: Bool
    /// Days from the on-device pipeline (`-noop`) are estimates (calories, steps filled on-device).
    let marksOnDeviceDaysAsEstimates: Bool
    /// Extra series read for display only (sleep need behind asleep time, the other stages, zone minutes).
    let companions: [String]
    /// Draw a "Your age" rule (fitness age, body age).
    let referencesAge: Bool
    /// The scoring guide section the About card opens.
    let scoringSection: ScoreSection?

    var isNightly: Bool { cadence == .nightly }

    /// Sleep efficiency arrives as a 0–1 fraction from the on-device pipeline and as a 0–100 percentage
    /// from a WHOOP export, sometimes in one series. Shown as a percentage either way.
    var normalisesFraction: Bool { key == "sleep_efficiency" }

    /// Bars of daily totals or scores bin by the range; everything else is drawn per day.
    var isBarChart: Bool {
        switch chart {
        case .scoreBars, .totals, .diverging, .stacked, .needBars: return true
        default: return false
        }
    }
}

// MARK: - The table

extension MetricPresentation {

    /// The presentation for one catalog descriptor. Unknown keys get a fitted line.
    static func of(_ metric: MetricDescriptor) -> MetricPresentation {
        of(key: metric.key, source: metric.source, decimals: metric.decimals)
    }

    static func of(key: String, source: String, decimals: Int = 0) -> MetricPresentation {
        let number = ValueStyle.number(decimals: decimals)
        func make(_ chart: Chart, _ tint: Tint, style: ValueStyle? = nil, cadence: Cadence = .daily,
                  range: ChartRange = .month, stats: [Stat], secondary: [Secondary] = [], band: Band? = nil,
                  estimate: Bool = false, onDeviceEstimates: Bool = false, companions: [String] = [],
                  age: Bool = false, scoring: ScoreSection? = nil) -> MetricPresentation {
            MetricPresentation(key: key, source: source, chart: chart, tint: tint, valueStyle: style ?? number,
                               cadence: cadence, defaultRange: range, stats: stats, secondary: secondary,
                               band: band, isEstimateSeries: estimate,
                               marksOnDeviceDaysAsEstimates: onDeviceEstimates, companions: companions,
                               referencesAge: age, scoringSection: scoring)
        }
        let strap = source == "my-whoop"
        let intraday: [Secondary] = strap ? [.intraday] : []
        let vitalStats: [Stat] = [.average, .low, .high, .typical]
        let totalStats: [Stat] = [.average, .total, .bestDay, .vsPrevious]
        let minuteStats: [Stat] = [.total, .perActiveDay, .activeDays, .high]
        let sleepStats: [Stat] = [.average, .shortest, .longest, .vsPrevious]
        let bodyStats: [Stat] = [.latest, .change, .low, .high]
        let weeklyStats: [Stat] = [.latest, .change, .high, .count]

        switch key {
        // Heart
        case "avg_hr":
            return make(.line(minSpan: 10), .rose, stats: [.average, .low, .high, .vsPrevious])
        case "max_hr":
            return make(.line(minSpan: 10), .rose, stats: [.highestWithDate, .average, .low, .vsPrevious])
        case "energy_kcal", "active_kcal":
            return make(.totals(.mean), .amber, stats: totalStats,
                        secondary: key == "energy_kcal" ? intraday : [], onDeviceEstimates: true)
        case "vo2max":
            return make(.stepLine(fixed: nil, minSpan: 5), .charge, cadence: .sparse, range: .half,
                        stats: weeklyStats)
        case "vo2max_est":
            return make(.stepLine(fixed: nil, minSpan: 5), .charge, cadence: .weekly, range: .half,
                        stats: weeklyStats, estimate: true)
        case "fitness_age", "body_age":
            return make(.stepLine(fixed: nil, minSpan: 6), .purple, cadence: .weekly, range: .half,
                        stats: [.latest, .vsAge, .change, .count], age: true)
        case "vitality" where source == "xiaomi-band":
            return make(.line(minSpan: 20), .amber, stats: [.latest, .average, .high, .atLeast(100)])
        case "vitality":
            return make(.stepLine(fixed: 0...100, minSpan: 10), .amber, cadence: .weekly, range: .half,
                        stats: weeklyStats)

        // Charge
        case "recovery":
            return make(.scoreBars(.charge), .charge, stats: [.average, .low, .high, .atLeast(RecoveryScorer.bandYellowMax)],
                        secondary: [.bandMix, .weekdayPattern], scoring: .charge)
        case "hrv":
            return make(.line(minSpan: 20), .purple, cadence: .nightly, stats: vitalStats, secondary: intraday,
                        band: .hrv)
        case "rhr":
            return make(.line(minSpan: 10), .rose, cadence: .nightly,
                        stats: source == "xiaomi-band" ? [.average, .low, .high, .vsPrevious] : vitalStats,
                        secondary: intraday, band: source == "xiaomi-band" ? nil : .restingHR)
        case "resp_rate":
            return make(.line(minSpan: 3), .cyan, cadence: .nightly, stats: vitalStats, secondary: intraday,
                        band: .resp)
        case "spo2":
            return make(.fixedPoints(domain: 85...100, reference: 95, joined: false), .cyan, cadence: .nightly,
                        stats: [.average, .lowestNight, .below(95), .count],
                        secondary: strap ? [.banked] : [])
        case "skin_temp":
            // The deviation form; `forSkinTemp(absolute:)` swaps in the absolute form.
            return make(.diverging, .amber, style: .signed(decimals: max(1, decimals)), cadence: .nightly,
                        stats: [.average, .warmest, .coolest, .above(0.5)], secondary: strap ? [.banked] : [])

        // Rest
        case "sleep_performance":
            return make(.scoreBars(.rest), .rest, cadence: .nightly,
                        stats: [.average, .low, .high, .atLeast(85)], secondary: [.bandMix], scoring: .rest)
        case "sleep_consistency", "sleep_score":
            return make(.scoreBars(.rest), .rest, cadence: .nightly, stats: [.average, .low, .high, .vsPrevious])
        case "in_bed_min":
            return make(.stacked(.inBed), .rest, style: .duration, cadence: .nightly, stats: sleepStats,
                        companions: ["sleep_total_min"])
        case "sleep_total_min":
            return make(.totals(.mean), .rest, style: .duration, cadence: .nightly,
                        stats: [.average, .shortest, .longest, .metNeed], companions: ["sleep_need_min"])
        case "hours_vs_needed_pct":
            return make(.needBars, .rest, cadence: .nightly, stats: [.average, .atLeast(100), .low, .high])
        case "restorative_pct":
            return make(.fixedPoints(domain: 0...60, reference: nil, joined: true), .rest, cadence: .nightly,
                        stats: [.average, .low, .high, .vsPrevious])
        case "restorative_min":
            return make(.stacked(.restorative), .rest, style: .duration, cadence: .nightly,
                        stats: [.average, .low, .high, .vsPrevious], companions: ["sleep_deep_min", "sleep_rem_min"])
        case "sleep_efficiency":
            return make(.fixedPoints(domain: 50...100, reference: 85, joined: true), .rest, cadence: .nightly,
                        stats: [.average, .low, .high, .atLeast(85)])
        case "sleep_deep_min", "sleep_rem_min", "sleep_light_min":
            let stages = ["sleep_deep_min", "sleep_rem_min", "sleep_light_min"]
            return make(.stacked(.sleepStages(highlight: key)), .rest, style: .duration, cadence: .nightly,
                        stats: [.average, .low, .high, .shareOfSleep], companions: stages.filter { $0 != key })
        case "sleep_need_min":
            return make(.line(minSpan: 60), .rest, style: .duration, cadence: .nightly,
                        stats: [.average, .low, .high, .metNeed], companions: ["sleep_total_min"])
        case "sleep_debt_min":
            return make(.totals(.mean), .rose, style: .duration, cadence: .nightly,
                        stats: [.average, .high, .noDebt, .vsPrevious])

        // Effort
        case "strain":
            return make(.scoreBars(.effort), .effort, stats: [.average, .low, .high, .vsPrevious],
                        secondary: [.weekdayPattern], scoring: .effort)
        case "steps", "steps_est":
            return make(.totals(.mean), .cyan, stats: totalStats, secondary: key == "steps" ? intraday : [],
                        estimate: key == "steps_est", onDeviceEstimates: true)
        case "hr_zones13_min", "hr_zones45_min", "strength_min":
            return make(.totals(.sum), .effort, cadence: .workoutDays, range: key == "strength_min" ? .quarter : .month,
                        stats: minuteStats)
        case "hr_zones_all_min":
            return make(.stacked(.zones), .effort, cadence: .workoutDays,
                        stats: [.total, .perActiveDay, .zoneHighShare, .activeDays],
                        companions: (1...5).map { "hr_zone\($0)_min" })
        case "intensity_min":
            return make(.totals(.sum), .effort, range: .quarter,
                        stats: [.thisWeek, .weeklyAverage, .weeksAtLeast(150), .bestWeek])

        // Health
        case "weight", "lean_mass":
            return make(.sparsePoints(minSpan: 2, references: []), .purple, cadence: .sparse,
                        range: key == "weight" ? .quarter : .half, stats: bodyStats)
        case "body_fat":
            return make(.sparsePoints(minSpan: 2, references: []), .purple, cadence: .sparse, range: .half,
                        stats: bodyStats)
        case "bmi":
            return make(.sparsePoints(minSpan: 2, references: [18.5, 25, 30]), .purple, cadence: .sparse,
                        range: .half, stats: bodyStats)
        case "stress" where source == "xiaomi-band":
            return make(.scoreBars(.single), .stress, stats: [.average, .low, .high, .vsPrevious])
        case "stress":
            return make(.scoreBars(.dayStress), .stress, stats: [.average, .atLeast(2), .low, .high])

        // Nutrition
        case "calories_in", "protein_g", "carbs_g", "fat_g":
            return make(.totals(.mean), .amber, cadence: .loggedDays, stats: [.average, .count, .high, .low])

        // Mind
        case "mood":
            return make(.dotStrip, .purple, style: .level, cadence: .loggedDays,
                        stats: [.average, .mostCommon, .count, .vsPrevious], secondary: [.distribution])

        default:
            return make(.line(minSpan: 1), .cyan, stats: [.average, .low, .high, .vsPrevious])
        }
    }

    /// Skin temperature has two forms: absolute temperatures draw as a vital line with a typical band;
    /// deviations from the baseline as bars around zero. The series picks one kind per window.
    func forSkinTemp(absolute: Bool) -> MetricPresentation {
        guard key == "skin_temp", absolute else { return self }
        return MetricPresentation(key: key, source: source, chart: .line(minSpan: 1), tint: tint,
                                  valueStyle: .number(decimals: 1), cadence: cadence, defaultRange: defaultRange,
                                  stats: [.average, .low, .high, .typical], secondary: secondary,
                                  band: .skinAbsolute, isEstimateSeries: false, marksOnDeviceDaysAsEstimates: false,
                                  companions: [], referencesAge: false, scoringSection: nil)
    }

    /// Metrics that only arrive with a WHOOP export (no on-device column), so an empty page says where they
    /// come from instead of asking for a strap.
    static let exportOnlyKeys: Set<String> = [
        "avg_hr", "max_hr", "in_bed_min", "hours_vs_needed_pct", "sleep_consistency", "restorative_pct",
        "restorative_min", "sleep_need_min", "sleep_debt_min", "hr_zones13_min", "hr_zones45_min",
        "hr_zones_all_min", "strength_min", "stress",
    ]

    /// The one line inside an empty chart frame, per source.
    var emptyMessage: String {
        switch source {
        case "apple-health": return String(localized: "No Apple Health readings yet")
        case "xiaomi-band": return String(localized: "No Mi Band readings yet")
        case "nutrition-csv": return String(localized: "No food log imported yet")
        case "noop-mood": return String(localized: "No check-ins yet")
        case MetricCatalog.combinedStepsSource: return String(localized: "No steps yet")
        default:
            if Self.exportOnlyKeys.contains(key) { return String(localized: "Comes from a WHOOP export") }
            switch cadence {
            case .weekly: return String(localized: "Appears after a week of wear")
            default: return String(localized: "No readings yet")
            }
        }
    }
}

// MARK: - Display transform and formatting

/// The unit preferences that change how a metric draws. Display-only.
struct MetricUnitContext: Equatable {
    var system: UnitSystem = .metric
    var temperature: TemperatureUnit = .celsius
    var effortScale: EffortScale = .hundred
}

extension MetricPresentation {

    /// A stored value as it is drawn: converted to the chosen unit system and scale.
    func display(_ stored: Double, units: MetricUnitContext, unitLabel: String) -> Double {
        if normalisesFraction, stored <= 1.5 { return stored * 100 }
        if key == "strain" { return UnitFormatter.effortValue(stored, scale: units.effortScale) }
        switch unitLabel {
        case "kg":
            return units.system == .imperial ? UnitFormatter.kgToPounds(stored) : stored
        case "°C":
            guard units.temperature == .fahrenheit else { return stored }
            return VitalBands.isAbsoluteSkinTemp(stored) || key != "skin_temp"
                ? UnitFormatter.celsiusToFahrenheit(stored)
                : UnitFormatter.celsiusDeltaToFahrenheit(stored)
        default:
            return stored
        }
    }

    /// The same conversion for a difference between two stored values (no °F offset).
    func displayDelta(_ storedDelta: Double, units: MetricUnitContext, unitLabel: String) -> Double {
        if key == "strain" { return UnitFormatter.effortValue(storedDelta, scale: units.effortScale) }
        switch unitLabel {
        case "kg": return units.system == .imperial ? UnitFormatter.kgToPounds(storedDelta) : storedDelta
        case "°C": return units.temperature == .fahrenheit ? UnitFormatter.celsiusDeltaToFahrenheit(storedDelta) : storedDelta
        default: return storedDelta
        }
    }

    /// The unit drawn beside a value, in the chosen system. Nil for unit-less values and durations (whose
    /// text carries "h" and "m"), and for scores whose fixed axis already says the scale (Effort, day
    /// stress, mood).
    func unit(catalogUnit: String, units: MetricUnitContext) -> String? {
        if valueStyle == .duration { return nil }
        switch catalogUnit {
        case "", "/100", "/21", "/3", "/5": return nil
        case "kg": return UnitFormatter.massUnit(units.system)
        case "°C": return UnitFormatter.temperatureUnit(units.temperature)
        default: return catalogUnit
        }
    }

    /// The unit on the chart's value axis: hours for durations, else the value's unit.
    func axisUnit(catalogUnit: String, units: MetricUnitContext) -> String? {
        if valueStyle == .duration { return String(localized: "h") }
        return unit(catalogUnit: catalogUnit, units: units)
    }

    /// A displayed value as text, without its unit: "62", "8,420", "6 h 42 m", "+0.3".
    func text(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        switch valueStyle {
        case .number(let decimals):
            return value.formatted(.number.precision(.fractionLength(decimals)))
        case .duration:
            return UnitFormatter.durationFromMinutes(value)
        case .level:
            if value == value.rounded() { return MetricMood.label(Int(value)) }
            return value.formatted(.number.precision(.fractionLength(1)))
        case .signed(let decimals):
            let rounded = (value * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
            let body = abs(rounded).formatted(.number.precision(.fractionLength(decimals)))
            if rounded == 0 { return body }
            return (rounded > 0 ? "+" : "−") + body
        }
    }

    /// A displayed value with its unit: "62 ms", "6 h 42 m", "97 %".
    func textWithUnit(_ value: Double, unit: String?) -> String {
        let number = text(value)
        guard let unit, !unit.isEmpty, number != "—" else { return number }
        return "\(number) \(unit)"
    }

    /// A signed difference between two displayed values: "+4 ms", "−12 m", "+3 pts". A percentage
    /// changes in points, never by a percent of itself.
    func deltaText(_ delta: Double, unit: String?) -> String {
        let parts = deltaParts(delta, unit: unit)
        return parts.unit.map { "\(parts.value) \($0)" } ?? parts.value
    }

    /// `deltaText` as its number and its unit, for cells that draw the unit smaller beside the number.
    func deltaParts(_ delta: Double, unit: String?) -> (value: String, unit: String?) {
        guard delta.isFinite else { return ("—", nil) }
        let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "")
        let suffix: String? = unit == "%" ? String(localized: "pts") : unit
        switch valueStyle {
        case .duration:
            return (sign + UnitFormatter.durationFromMinutes(abs(delta)), nil)
        case .number(let decimals), .signed(let decimals):
            let shown = abs(delta).formatted(.number.precision(.fractionLength(decimals)))
            if shown == (0.0).formatted(.number.precision(.fractionLength(decimals))) { return (shown, suffix) }
            return (sign + shown, suffix)
        case .level:
            let shown = abs(delta).formatted(.number.precision(.fractionLength(1)))
            if shown == (0.0).formatted(.number.precision(.fractionLength(1))) { return (shown, suffix) }
            return (sign + shown, suffix)
        }
    }

    /// The value-axis labels for this metric's chart.
    func axisFormat() -> @Sendable (Double) -> String {
        switch valueStyle {
        case .duration: return ChartValueAxis.hoursFromMinutes
        // Whole numbers; the axis adds the decimals its step needs when two ticks would print alike.
        case .number: return ChartValueAxis.integer
        case .signed: return ChartValueAxis.decimals(1)
        case .level: return ChartValueAxis.integer
        }
    }
}

// MARK: - Score bands

enum MetricScoreBands {
    /// Charge bands from the scorer's own thresholds.
    static var charge: ScoreBands {
        ScoreBands([
            .init(upperBound: RecoveryScorer.bandRedMax, color: StrandPalette.statusCritical, name: String(localized: "Low")),
            .init(upperBound: RecoveryScorer.bandYellowMax, color: StrandPalette.statusWarning, name: String(localized: "Moderate")),
            .init(upperBound: .infinity, color: StrandPalette.chargeColor, name: String(localized: "High")),
        ])
    }

    /// Rest-family scores on the same thresholds, the top band in the rest colour.
    static var rest: ScoreBands {
        ScoreBands([
            .init(upperBound: RecoveryScorer.bandRedMax, color: StrandPalette.statusCritical, name: String(localized: "Low")),
            .init(upperBound: RecoveryScorer.bandYellowMax, color: StrandPalette.statusWarning, name: String(localized: "Moderate")),
            .init(upperBound: .infinity, color: StrandPalette.restColor, name: String(localized: "High")),
        ])
    }

    /// The WHOOP-import day stress (0–3) on `StressBand`'s cut-offs (1 and 2).
    static var dayStress: ScoreBands {
        ScoreBands([
            .init(upperBound: 1, color: StrandPalette.statusPositive, name: String(localized: "Low")),
            .init(upperBound: 2, color: StrandPalette.statusWarning, name: String(localized: "Medium")),
            .init(upperBound: .infinity, color: StrandPalette.statusCritical, name: String(localized: "High")),
        ])
    }

    static func bands(for fill: MetricPresentation.ScoreFill) -> ScoreBands? {
        switch fill {
        case .charge: return charge
        case .rest: return rest
        case .dayStress: return dayStress
        case .effort, .single: return nil
        }
    }
}

// MARK: - Statistics (pure)

/// Everything the statistics need for the visible range, already in display units.
struct MetricStatsInput {
    /// The range's readings, ascending by day key. Daily values for steps (not buckets).
    var window: [(day: String, value: Double)]
    /// The comparison window's values (the existing previous-window rule).
    var previous: [Double]
    var typical: ClosedRange<Double>?
    /// Asleep minutes by day (shares of sleep, need met).
    var asleepByDay: [String: Double] = [:]
    /// Sleep need minutes by day.
    var needByDay: [String: Double] = [:]
    /// Zone 1–5 minutes by day.
    var zonesByDay: [String: [Double]] = [:]
    var age: Int?
    var unit: String?
}

enum MetricStats {

    /// The StatGrid cells for `presentation`, in its order.
    static func items(_ p: MetricPresentation, input: MetricStatsInput) -> [StatItem] {
        p.stats.map { item(for: $0, p: p, input: input) }
    }

    static func item(for stat: MetricPresentation.Stat, p: MetricPresentation, input: MetricStatsInput) -> StatItem {
        let values = input.window.map(\.value).filter(\.isFinite)
        let unit = input.unit
        func cell(_ label: String, _ value: Double?, detail: String? = nil) -> StatItem {
            StatItem(label, value: value.map { p.text($0) }, unit: value == nil ? nil : unit, detail: detail)
        }
        func counted(_ label: String, _ n: Int?, detail: String? = nil) -> StatItem {
            StatItem(label, value: n.map { $0.formatted() }, detail: detail)
        }
        let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let lowest = input.window.filter { $0.value.isFinite }.min { $0.value < $1.value }
        let highest = input.window.filter { $0.value.isFinite }.max { $0.value < $1.value }

        switch stat {
        case .average:
            if case .totals = p.chart, p.cadence != .nightly { return cell(averageLabel(p), mean) }
            return cell(String(localized: "Average"), mean)
        case .low:
            return cell(String(localized: "Low"), lowest?.value, detail: lowest.map { shortDate($0.day) })
        case .high:
            return cell(String(localized: "High"), highest?.value, detail: highest.map { shortDate($0.day) })
        case .shortest:
            return cell(String(localized: "Shortest"), lowest?.value, detail: lowest.map { shortDate($0.day) })
        case .longest:
            return cell(String(localized: "Longest"), highest?.value, detail: highest.map { shortDate($0.day) })
        case .lowestNight:
            return cell(String(localized: "Lowest"), lowest?.value, detail: lowest.map { shortDate($0.day) })
        case .warmest:
            return cell(String(localized: "Warmest"), highest?.value, detail: highest.map { shortDate($0.day) })
        case .coolest:
            return cell(String(localized: "Coolest"), lowest?.value, detail: lowest.map { shortDate($0.day) })
        case .highestWithDate:
            return cell(String(localized: "Highest"), highest?.value, detail: highest.map { shortDate($0.day) })
        case .bestDay:
            return cell(String(localized: "Best day"), highest?.value, detail: highest.map { shortDate($0.day) })
        case .vsPrevious:
            guard let mean, !input.previous.isEmpty else {
                return StatItem(String(localized: "vs previous"), value: nil)
            }
            let prev = input.previous.reduce(0, +) / Double(input.previous.count)
            let delta = p.deltaParts(mean - prev, unit: unit)
            return StatItem(String(localized: "vs previous"), value: delta.value, unit: delta.unit)
        case .typical:
            guard let band = input.typical else { return StatItem(String(localized: "Typical"), value: nil) }
            return StatItem(String(localized: "Typical"), value: "\(p.text(band.lowerBound))–\(p.text(band.upperBound))",
                            unit: unit)
        case .atLeast(let threshold):
            let n = values.filter { $0 >= threshold }.count
            return counted(thresholdLabel(p, "≥", threshold), values.isEmpty ? nil : n,
                           detail: values.isEmpty ? nil : String(localized: "of \(values.count)"))
        case .below(let threshold):
            let n = values.filter { $0 < threshold }.count
            return counted(thresholdLabel(p, "<", threshold), values.isEmpty ? nil : n,
                           detail: values.isEmpty ? nil : String(localized: "of \(values.count)"))
        case .above(let threshold):
            let n = values.filter { $0 > threshold }.count
            return counted(thresholdLabel(p, ">", threshold), values.isEmpty ? nil : n,
                           detail: values.isEmpty ? nil : String(localized: "of \(values.count)"))
        case .count:
            return counted(countLabel(p), values.count)
        case .latest:
            let last = input.window.last
            return cell(String(localized: "Latest"), last?.value, detail: last.map { shortDate($0.day) })
        case .change:
            guard let first = input.window.first, let last = input.window.last, input.window.count > 1 else {
                return StatItem(String(localized: "Change"), value: nil)
            }
            let delta = p.deltaParts(last.value - first.value, unit: unit)
            return StatItem(String(localized: "Change"), value: delta.value, unit: delta.unit,
                            detail: String(localized: "since \(shortDate(first.day))"))
        case .total:
            return cell(String(localized: "Total"), values.isEmpty ? nil : values.reduce(0, +))
        case .perActiveDay:
            let active = values.filter { $0 > 0 }
            return cell(String(localized: "Per workout day"),
                        active.isEmpty ? nil : active.reduce(0, +) / Double(active.count))
        case .activeDays:
            return counted(String(localized: "Workout days"), values.filter { $0 > 0 }.count)
        case .shareOfSleep:
            let shares = input.window.compactMap { row -> Double? in
                guard let asleep = input.asleepByDay[row.day], asleep > 0 else { return nil }
                return row.value / asleep * 100
            }
            let share = shares.isEmpty ? nil : shares.reduce(0, +) / Double(shares.count)
            return StatItem(String(localized: "Share of sleep"), value: share.map { $0.formatted(.number.precision(.fractionLength(0))) },
                            unit: share == nil ? nil : "%")
        case .mostCommon:
            let levels = values.map { Int($0.rounded()) }
            let counts = Dictionary(levels.map { ($0, 1) }, uniquingKeysWith: +)
            let top = counts.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
            return StatItem(String(localized: "Most common"), value: top.map { MetricMood.label($0.key) },
                            detail: top.map { String(localized: "\($0.value) days") })
        case .zoneHighShare:
            let days = input.window.compactMap { input.zonesByDay[$0.day] }.filter { $0.count == 5 }
            let total = days.reduce(0) { $0 + $1.reduce(0, +) }
            let high = days.reduce(0) { $0 + $1[3] + $1[4] }
            let share = total > 0 ? high / total * 100 : nil
            return StatItem(String(localized: "Zones 4-5"), value: share.map { $0.formatted(.number.precision(.fractionLength(0))) },
                            unit: share == nil ? nil : "%")
        case .metNeed:
            if p.key == "sleep_total_min" {
                let met = input.window.compactMap { row -> Bool? in
                    input.needByDay[row.day].map { row.value >= $0 }
                }
                return counted(String(localized: "Need met"), met.isEmpty ? nil : met.filter { $0 }.count,
                               detail: met.isEmpty ? nil : String(localized: "of \(met.count)"))
            }
            let met = input.window.compactMap { row -> Bool? in
                input.asleepByDay[row.day].map { $0 >= row.value }
            }
            return counted(String(localized: "Need met"), met.isEmpty ? nil : met.filter { $0 }.count,
                           detail: met.isEmpty ? nil : String(localized: "of \(met.count)"))
        case .noDebt:
            return counted(String(localized: "No debt"), values.isEmpty ? nil : values.filter { $0 <= 0.5 }.count,
                           detail: values.isEmpty ? nil : String(localized: "of \(values.count)"))
        case .thisWeek:
            let weeks = weeklyTotals(input.window)
            return cell(String(localized: "This week"), weeks.last?.total)
        case .weeklyAverage:
            let weeks = weeklyTotals(input.window)
            return cell(String(localized: "Weekly avg"),
                        weeks.isEmpty ? nil : weeks.map(\.total).reduce(0, +) / Double(weeks.count))
        case .weeksAtLeast(let threshold):
            let weeks = weeklyTotals(input.window)
            return counted(String(localized: "Weeks ≥ \(p.text(threshold))"),
                           weeks.isEmpty ? nil : weeks.filter { $0.total >= threshold }.count,
                           detail: weeks.isEmpty ? nil : String(localized: "of \(weeks.count)"))
        case .bestWeek:
            let best = weeklyTotals(input.window).max { $0.total < $1.total }
            return cell(String(localized: "Best week"), best?.total, detail: best.map { shortDate($0.monday) })
        case .vsAge:
            guard let age = input.age, age > 0, let last = input.window.last?.value else {
                return StatItem(String(localized: "vs your age"), value: nil)
            }
            let delta = p.deltaParts(last - Double(age), unit: unit)
            return StatItem(String(localized: "vs your age"), value: delta.value, unit: delta.unit)
        }
    }

    static func averageLabel(_ p: MetricPresentation) -> String {
        switch p.cadence {
        case .loggedDays: return String(localized: "Per logged day")
        case .workoutDays: return String(localized: "Per workout day")
        default: return String(localized: "Daily avg")
        }
    }

    static func countLabel(_ p: MetricPresentation) -> String {
        switch p.cadence {
        case .nightly: return String(localized: "Nights")
        case .loggedDays: return String(localized: "Days logged")
        case .weekly, .sparse: return String(localized: "Readings")
        case .workoutDays: return String(localized: "Workout days")
        case .daily: return String(localized: "Days")
        }
    }

    static func thresholdLabel(_ p: MetricPresentation, _ comparator: String, _ threshold: Double) -> String {
        let noun = p.cadence == .nightly ? String(localized: "Nights") : String(localized: "Days")
        let value: String
        switch p.valueStyle {
        case .signed: value = p.text(threshold)
        default: value = threshold.formatted(.number.precision(.fractionLength(threshold == threshold.rounded() ? 0 : 1)))
        }
        let suffix = p.chart.isPercentScale ? " %" : ""
        return "\(noun) \(comparator) \(value)\(suffix)"
    }

    /// Calendar weeks (Monday start) and their totals, ascending.
    static func weeklyTotals(_ rows: [(day: String, value: Double)]) -> [(monday: String, total: Double)] {
        var totals: [String: Double] = [:]
        for row in rows {
            guard let monday = mondayKey(row.day) else { continue }
            totals[monday, default: 0] += row.value
        }
        return totals.keys.sorted().map { ($0, totals[$0] ?? 0) }
    }

    static func mondayKey(_ day: String) -> String? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let date = LocalCalendarDate(year: y, month: m, day: d)
        let weekdayFromMonday = ((date.daysSinceEpoch + 3) % 7 + 7) % 7
        return date.adding(days: -weekdayFromMonday).key
    }

    /// "30 Sep" for a stored day key, read as a calendar day in the viewer's zone.
    static func shortDate(_ day: String) -> String {
        guard let date = ChartDay.date(forKey: day) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

extension MetricPresentation.Chart {
    /// Charts whose values are percentages (thresholds print with "%").
    var isPercentScale: Bool {
        switch self {
        case .fixedPoints, .needBars: return true
        case .scoreBars(let fill): return fill == .charge || fill == .rest
        default: return false
        }
    }
}

// MARK: - Mood levels

enum MetricMood {
    static func label(_ level: Int) -> String {
        switch level {
        case 1: return String(localized: "Awful")
        case 2: return String(localized: "Low")
        case 3: return String(localized: "Okay")
        case 4: return String(localized: "Good")
        case 5: return String(localized: "Great")
        default: return "\(level)"
        }
    }

    static var labels: [Int: String] { Dictionary(uniqueKeysWithValues: (1...5).map { ($0, label($0)) }) }

    static func color(_ level: Int) -> Color {
        switch level {
        case 1: return StrandPalette.statusCritical
        case 2: return StrandPalette.metricAmber
        case 3: return StrandPalette.textSecondary
        case 4: return StrandPalette.metricCyan
        default: return StrandPalette.chargeColor
        }
    }
}

// MARK: - Readout context line (pure)

enum MetricReadoutContext {

    /// The line under the value when nothing is selected: a short summary of the recent past.
    ///
    /// - `points`: the displayed values, ascending (bars: what the bars show).
    static func idle(_ p: MetricPresentation, rows: [(day: String, value: Double)],
                     windowRows: [(day: String, value: Double)], windowCount: Int,
                     typical: ClosedRange<Double>?, unit: String?, age: Int?, bin: Calendar.Component,
                     note: String?) -> String? {
        if let note { return note }
        guard let last = rows.last else { return nil }
        if windowCount > 0, windowCount < 3 {
            return windowCount == 1 ? String(localized: "1 reading") : String(localized: "\(windowCount) readings")
        }
        switch p.chart {
        case .stepLine, .sparsePoints:
            if p.referencesAge, let age, age > 0 {
                let diff = last.value - Double(age)
                if abs(diff) < 0.5 { return String(localized: "Same as your age") }
                let years = Int(abs(diff).rounded())
                return diff < 0 ? String(localized: "\(years) yrs below your age")
                                : String(localized: "\(years) yrs above your age")
            }
            // The change across the visible range, the same span as the Change statistic.
            if let first = windowRows.first, let newest = windowRows.last, windowRows.count > 1 {
                return String(localized: "\(p.deltaText(newest.value - first.value, unit: unit)) since \(MetricStats.shortDate(first.day))")
            }
            return nil
        case .dotStrip:
            return nil
        default:
            break
        }
        if bin != .day {
            if p.aggregation == .sum {
                return bin == .month ? String(localized: "Month total") : String(localized: "Week total")
            }
            return bin == .month ? String(localized: "Monthly average") : String(localized: "Weekly average")
        }
        let recent = trailing(rows, days: 7)
        if p.cadence == .workoutDays {
            // Minutes exist on workout days only, so the last week (ending today) reads as its total.
            let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))
            let startKey = start.map { ChartDay.key(for: $0) } ?? ""
            let total = rows.filter { $0.day >= startKey }.map(\.value).reduce(0, +)
            return String(localized: "\(p.textWithUnit(total, unit: unit)) in the last 7 days")
        }
        guard !recent.isEmpty else { return nil }
        let mean = recent.reduce(0, +) / Double(recent.count)
        if let typical, p.band != nil {
            return String(localized: "7-day avg \(p.textWithUnit(mean, unit: unit)) · typical \(p.text(typical.lowerBound))–\(p.text(typical.upperBound))")
        }
        return String(localized: "7-day avg \(p.textWithUnit(mean, unit: unit))")
    }

    /// The line under a scrubbed value: how it compares with the personal typical range, else nothing.
    static func selected(_ p: MetricPresentation, value: Double?, typical: ClosedRange<Double>?, unit: String?,
                         bin: Calendar.Component, aggregation: ChartAggregation?) -> String? {
        if bin != .day {
            if aggregation == .sum {
                return bin == .month ? String(localized: "Month total") : String(localized: "Week total")
            }
            return bin == .month ? String(localized: "Monthly average") : String(localized: "Weekly average")
        }
        guard let value, let typical else { return nil }
        if typical.contains(value) { return String(localized: "Within your typical range") }
        let edge = value < typical.lowerBound ? typical.lowerBound : typical.upperBound
        return String(localized: "\(p.deltaText(value - edge, unit: unit)) outside typical")
    }

    /// The values of the last `days` calendar days ending at the newest row.
    static func trailing(_ rows: [(day: String, value: Double)], days: Int) -> [Double] {
        guard let lastKey = rows.last?.day, let last = ChartDay.date(forKey: lastKey),
              let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: last) else { return [] }
        let startKey = ChartDay.key(for: start)
        return rows.filter { $0.day >= startKey }.map(\.value)
    }
}

// MARK: - About copy

extension MetricPresentation {

    /// The About card's paragraphs: what the metric is, how it is measured, and the caveats that used to
    /// sit under the hero and the chart.
    func about(title: String, catalogDescription: String?) -> [String] {
        var out: [String] = []
        if let catalogDescription { out.append(catalogDescription) }
        switch key {
        case "recovery":
            out.append(String(localized: "Charge is scored each morning from your heart rate variability against your own baseline, with resting heart rate, last night's Rest and breathing rate. Bars are coloured by band: below 34 low, 34 to 66 moderate, 67 and above high."))
        case "hrv":
            out.append(String(localized: "RMSSD is your headline HRV, the beat-to-beat change measured overnight. SDNN is the overall spread across the night, averaged over 5-minute windows, so it reads higher. They are different measures and are kept apart."))
            out.append(String(localized: "The shaded band is your typical range and the dashed line your baseline, both from your own nights once at least 14 are in."))
        case "rhr":
            out.append(String(localized: "Resting heart rate is your lowest calm heart rate overnight. Lower usually means better recovered. The band is your typical range once 14 nights are in."))
        case "resp_rate":
            out.append(String(localized: "Breaths per minute while asleep, estimated from your heartbeat. It is usually very steady, so a change of one or two breaths can matter."))
        case "spo2":
            out.append(String(localized: "Blood oxygen is read in short windows while you sleep. Hollow points are the strap's own estimate and are not verified."))
            out.append(String(localized: "Every reading shows what the strap banked over the last 24 hours, so there are no readings while you are awake."))
        case "skin_temp":
            out.append(String(localized: "Skin temperature is shown as the difference from your own baseline, warmer above zero and cooler below. When nights carry a measured temperature it is shown instead, in the unit you chose in Settings."))
            out.append(String(localized: "The strap takes a skin temperature every second while it is on your wrist. Every reading is 5-minute averages; a gap means it was off your wrist or had not synced yet."))
        case "sleep_performance":
            out.append(String(localized: "Rest scores last night's sleep against what you needed: duration, efficiency, deep and REM sleep, and timing."))
        case "sleep_efficiency":
            out.append(String(localized: "The share of time in bed you were asleep. 85 % and above is generally considered good."))
        case "sleep_total_min", "in_bed_min", "sleep_need_min", "sleep_debt_min", "restorative_min",
             "sleep_deep_min", "sleep_rem_min", "sleep_light_min":
            out.append(String(localized: "Each night is dated by the morning you woke up."))
        case "strain":
            out.append(String(localized: "Effort is your cardiovascular load for the day, from time spent in heart-rate zones, on a 0-100 scale (or 0-21 if you chose the WHOOP scale in Settings)."))
        case "steps", "steps_est":
            out.append(String(localized: "Bars are daily at W and M, weekly averages at 3M, and monthly averages at 6M and longer, each averaged over the days that have a count."))
            if key == "steps_est" {
                out.append(String(localized: "These are estimates from your strap's motion, calibrated to your phone, and are drawn as estimates."))
            }
        case "energy_kcal":
            out.append(String(localized: "A WHOOP export carries total energy, including the energy you burn at rest. Days computed on this iPhone carry an estimate of active energy only and are drawn as estimates."))
        case "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min":
            out.append(String(localized: "Only days with a workout carry minutes, so averages are per workout day. At 3M and longer each bar is a week or a month."))
        case "vo2max_est":
            out.append(String(localized: "Estimated each week from your resting heart rate and profile. The line breaks where the estimation method changed or was not recorded."))
        case "fitness_age", "body_age":
            out.append(String(localized: "Updated weekly from your heart and activity data. The dashed line is your age from your profile."))
        case "stress":
            if source == "my-whoop" {
                out.append(String(localized: "Day stress here comes from a WHOOP export, derived from that day's resting heart rate and HRV. The Stress screen has the live version."))
            }
        case "mood":
            out.append(String(localized: "One check-in a day, from awful to great. Self-reported and not a clinical measure."))
        default:
            break
        }
        out.append(String(localized: "Moves with lists other metrics whose daily values rise and fall with this one over the visible range (Pearson r of at least 0.30 over at least 10 shared days). It shows association, not cause."))
        return out
    }
}
