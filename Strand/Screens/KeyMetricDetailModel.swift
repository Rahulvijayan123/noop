import Foundation
import StrandAnalytics
import WhoopStore

// KeyMetricDetailModel.swift — which metrics open the simplified key-metric screen (`KeyMetricDetailView`: the
// latest measured value, one history chart, the server's explanation), where each one's values come from, and the
// pure rules behind that screen. Every other metric keeps `MetricDetailView`'s full dossier. The ids, periods,
// value sources and measured-or-estimated labels are the table in docs/METRIC_INSIGHTS.md.

// MARK: - Catalog

/// The metric drill-downs that are the simplified key-metric screen, and the server metrics that explain each.
///
/// `MetricDetailView.body` consults `entry(for:)` first, so every entry point that pushes a metric detail (the
/// Explore list, Today's tiles and cards, Trends, Sleep, Health, `TabRoute`) reaches the same screen.
enum KeyMetricCatalog {

    struct Entry: Equatable, Sendable {
        /// `MetricDescriptor.key`.
        let catalogKey: String
        /// `MetricDescriptor.source`. The server explains the strap's own data (`server_daily_scores`, the scoring
        /// snapshot and the context layer), so only the strap's descriptor is routed: another source's resting HR
        /// (a Mi Band import) or Apple Health's steps are different data and keep their dossiers.
        let source: String
        /// What the screen shows: one metric, or the sides of a switch at the top (HRV: RMSSD, then SDNN), the
        /// first shown on arrival. Each side has its own value, chart and explanation.
        let metrics: [MetricInsightMetric]

        /// The screen's title (a switch's sides share theirs).
        var title: String { metrics.first?.title ?? "" }
    }

    static let entries: [Entry] = [
        Entry(catalogKey: "rhr", source: "my-whoop", metrics: [.restingHeartRate]),
        Entry(catalogKey: "hrv", source: "my-whoop", metrics: [.hrvRmssd, .hrvSdnn]),
        Entry(catalogKey: "skin_temp", source: "my-whoop", metrics: [.skinTemp]),
        Entry(catalogKey: "resp_rate", source: "my-whoop", metrics: [.respRate]),
        Entry(catalogKey: "spo2", source: "my-whoop", metrics: [.spo2]),
        Entry(catalogKey: "stable_awake_hr", source: "my-whoop", metrics: [.heartRate]),
        // The strap's step count. Apple Health's and the Mi Band's steps are imports, and the WHOOP 4.0 motion
        // estimate (`steps_est`) and the fused 30-day view are not what the server's `daily.steps` holds.
        Entry(catalogKey: "steps", source: "my-whoop", metrics: [.steps]),
        Entry(catalogKey: "energy_kcal", source: "my-whoop", metrics: [.calories]),
    ]

    /// The routing entry for `metric`, nil when it keeps the full dossier.
    static func entry(for metric: MetricDescriptor) -> Entry? {
        entries.first { $0.catalogKey == metric.key && $0.source == metric.source }
    }

    /// Whether the phone stores a series for `metric`. False only for a screen that reads the server alone (stable
    /// awake heart rate): its Explore row must not be marked empty for want of a local series.
    static func hasLocalSeries(_ metric: MetricDescriptor) -> Bool {
        guard let entry = entry(for: metric) else { return true }
        return entry.metrics.contains { !$0.series.isServerOnly }
    }
}

// MARK: - Metrics

/// Where one key metric's values come from (docs/METRIC_INSIGHTS.md, "value the screen shows (app)").
enum KeyMetricSeries: Equatable, Sendable {
    /// The descriptor's own `Repository.exploreSeries` read: its merged daily column, with imported values winning
    /// over computed ones per day (resting HR, RMSSD, respiratory rate, calories).
    case explore
    /// The nightly SDNN index, `DailyMetric.avgSdnn` (`KeyMetricValues.sdnn`).
    case sdnn
    /// The absolute wrist temperature (`KeyMetricValues.absoluteSkinTemp`), never the baseline deviation
    /// `exploreSeries("skin_temp")` returns.
    case absoluteSkinTemp
    /// `spo2Pct` through `exploreSeries`, the nights it lacks filled from the strap's unverified candidate while
    /// that display is on (`PuffinExperiment.spo2CandidateDisplayEnabled`), exactly as the dossier fills them.
    case spo2WithCandidate
    /// One series of the server's physiology context history (`KeyMetricValues.contextDaily`).
    case contextHistory(seriesKey: String)
    /// The Steps page's own read, `Repository.resolvedSeries` (the strap's count, then its computed sibling),
    /// not `exploreSeries`.
    case resolved

    /// True when the values exist only on the server.
    var isServerOnly: Bool {
        if case .contextHistory = self { return true }
        return false
    }
}

/// Whether a key metric is a measurement or an estimate, as its screen labels it.
enum KeyMetricMeasurement: Equatable, Sendable {
    case measured
    /// Derived rather than read off a sensor: respiratory rate from heartbeat timing, steps from the step
    /// counter, calories from heart rate.
    case estimated
    /// The strap's blood-oxygen candidate: an estimate that has not been checked against a reference.
    case estimatedUnverified

    /// The screen's label; nil for a measurement.
    var label: String? {
        switch self {
        case .measured: return nil
        case .estimated: return String(localized: "Estimated")
        case .estimatedUnverified: return String(localized: "Estimated, unverified")
        }
    }
}

extension MetricInsightMetric {
    /// The screen's title (docs/METRIC_INSIGHTS.md). The HRV sides are named by `switchLabel` under their shared
    /// screen's title.
    var title: String {
        switch self {
        case .restingHeartRate: return String(localized: "Resting heart rate")
        case .hrvRmssd, .hrvSdnn: return String(localized: "Heart rate variability")
        case .skinTemp: return String(localized: "Wrist temperature")
        case .respRate: return String(localized: "Respiratory rate")
        case .spo2: return String(localized: "Blood oxygen")
        case .heartRate: return String(localized: "Stable awake heart rate")
        case .steps: return String(localized: "Steps")
        case .calories: return String(localized: "Calories")
        }
    }

    /// The side's name on a switch; the title for a metric that has no switch.
    var switchLabel: String {
        switch self {
        case .hrvRmssd: return String(localized: "RMSSD")
        case .hrvSdnn: return String(localized: "SDNN")
        default: return title
        }
    }

    var series: KeyMetricSeries {
        switch self {
        case .restingHeartRate, .hrvRmssd, .respRate, .calories: return .explore
        case .hrvSdnn: return .sdnn
        case .skinTemp: return .absoluteSkinTemp
        case .spo2: return .spo2WithCandidate
        case .heartRate: return .contextHistory(seriesKey: KeyMetricValues.stableAwakeHeartRateSeries)
        case .steps: return .resolved
        }
    }

    var measurement: KeyMetricMeasurement {
        switch self {
        case .restingHeartRate, .hrvRmssd, .hrvSdnn, .skinTemp, .heartRate: return .measured
        case .respRate, .steps, .calories: return .estimated
        case .spo2: return .estimatedUnverified
        }
    }

    /// Whether zero is a reading. Zero steps on a worn day is a real 0; a zero heart rate, temperature or calorie
    /// total is a placeholder for a period that was not measured.
    var keepsZero: Bool { self == .steps }

    /// The chart's least air above and below the readings, in display units: enough that a steady stretch still
    /// has height, small enough that a narrow-range signal (a wrist temperature, blood oxygen) is not squashed
    /// into a flat line.
    var minimumPad: Double {
        switch self {
        case .restingHeartRate, .hrvRmssd, .hrvSdnn, .heartRate: return 3
        case .skinTemp: return 0.3
        case .respRate: return 0.5
        case .spo2: return 1
        case .steps: return 500
        case .calories: return 100
        }
    }

    /// The most history the source can serve, in days; nil for the phone's own series. The context history
    /// route serves 120 days per read, so the longer range chips would only ever draw an empty stretch.
    var historyDays: Int? {
        series.isServerOnly ? PhysiologyContextRepository.maxHistoryDays : nil
    }
}

// MARK: - Values

/// The pure reads behind the series that are not a plain Explore series.
enum KeyMetricValues {

    /// The context layer's daily heart rate in stable awake five-minute windows (contracts.md §5).
    static let stableAwakeHeartRateSeries = "heart_rate.stable_awake_5min"

    /// How many recent days the live context is read for: the days the retrospective pass may not have reached.
    static let liveContextDays = 7

    /// The nightly SDNN index per night, ascending.
    static func sdnn(_ days: [DailyMetric]) -> [(day: String, value: Double)] {
        days.compactMap { row in row.avgSdnn.map { (day: row.day, value: $0) } }.sorted { $0.day < $1.day }
    }

    /// The absolute wrist temperature per night, ascending: `skinTempC`, else an absolute that a WHOOP CSV import
    /// wrote into `skinTempDevC` (#622: that column holds either kind). A baseline deviation is never used,
    /// whatever the Settings choice: this screen is the temperature itself.
    static func absoluteSkinTemp(_ days: [DailyMetric]) -> [(day: String, value: Double)] {
        days.compactMap { row in
            let absolute = [row.skinTempC, row.skinTempDevC].compactMap { $0 }.first(where: VitalBands.isAbsoluteSkinTemp)
            return absolute.map { (day: row.day, value: $0) }
        }.sorted { $0.day < $1.day }
    }

    /// `primary` with the days it lacks filled from `fallback`, ascending. A day `primary` holds is never
    /// replaced, and only the first value of a day is kept.
    static func filling(_ primary: [(day: String, value: Double)],
                        from fallback: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        var byDay: [String: Double] = [:]
        for row in primary + fallback where byDay[row.day] == nil { byDay[row.day] = row.value }
        return byDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
    }

    /// One value per day of `seriesKey`, ascending, from the context history's daily values. The retrospective
    /// value wins where a day has both (it is computed once the day is complete, and the day read serves it
    /// first); among values of the same mode, the one with the most support (windows, then seconds). Values that
    /// are not finite and positive are left out.
    static func contextDaily(_ values: [PhysiologyContext.DailyValue],
                             seriesKey: String) -> [(day: String, value: Double)] {
        func rank(_ v: PhysiologyContext.DailyValue) -> (Int, Int, Int) {
            (v.mode == .retrospective ? 1 : 0, v.supportCount, v.supportS)
        }
        var best: [String: PhysiologyContext.DailyValue] = [:]
        for v in values where v.seriesKey == seriesKey && v.value.isFinite && v.value > 0 {
            guard let current = best[v.day] else { best[v.day] = v; continue }
            if rank(v) > rank(current) || (rank(v) == rank(current) && v.regimeKey < current.regimeKey) {
                best[v.day] = v
            }
        }
        return best.values.sorted { $0.day < $1.day }.map { (day: $0.day, value: $0.value) }
    }

    /// One `GET scores/context/history` read: inclusive local days in one processing mode.
    struct ContextRead: Equatable, Sendable {
        let from: String
        let to: String
        let mode: PhysiologyContext.ProcessingMode
    }

    /// The context history reads behind a day series whose latest complete day is `lastDay`: the retrospective
    /// values over the route's longest range, and the live values of the last `liveContextDays` days.
    static func contextReads(through lastDay: String) -> [ContextRead] {
        let longest = PhysiologyContextRepository.maxHistoryDays
        return [
            ContextRead(from: PhysiologyContextDates.key(lastDay, minusDays: longest - 1) ?? lastDay, to: lastDay,
                        mode: .retrospective),
            ContextRead(from: PhysiologyContextDates.key(lastDay, minusDays: liveContextDays - 1) ?? lastDay,
                        to: lastDay, mode: .causalLive),
        ]
    }
}

// MARK: - Format

/// How one key metric's values read on its screen, with the reader's unit preferences (display only).
struct KeyMetricFormatter {
    let metric: MetricInsightMetric
    let descriptor: MetricDescriptor
    var system: UnitSystem = .metric
    var temperature: TemperatureUnit = .celsius
    var locale: Locale = AppLanguage.activeLocale

    /// "8,123": a whole number grouped the way the app language groups it, for the count metrics.
    static func count(_ value: Double, locale: Locale) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0)))
    }

    /// The value with its unit: "52 bpm", "34.2 °C", "8,123 steps", "2,350 kcal".
    func text(_ value: Double) -> String {
        switch metric {
        case .steps:
            let count = Self.count(value, locale: locale)
            return String(localized: "\(count) steps")
        case .calories:
            return "\(Self.count(value, locale: locale)) \(descriptor.unit)"
        default:
            return descriptor.format(value, system: system, temperature: temperature)
        }
    }

    /// The headline's number and its unit, set apart so the unit can be smaller. The whole text when its unit
    /// cannot be told apart.
    func parts(_ value: Double) -> (number: String, unit: String?) {
        let text = text(value)
        switch metric {
        case .steps, .calories:
            let number = Self.count(value, locale: locale)
            guard text.hasPrefix(number + " "), text.count > number.count + 1 else { return (text, nil) }
            return (number, String(text.dropFirst(number.count + 1)))
        default:
            return KeyMetricHistory.splitUnit(text, unit: descriptor.displayUnit(system: system,
                                                                                 temperature: temperature))
        }
    }

    /// Where a value sits on the chart's value axis: the wrist temperature in the reader's unit (the axis labels
    /// are plain numbers), everything else as stored.
    func plotted(_ value: Double) -> Double {
        metric == .skinTemp && temperature == .fahrenheit ? UnitFormatter.celsiusToFahrenheit(value) : value
    }
}

// MARK: - History

/// The measured nights or days behind the screen and the chart's windowing and gap rules. Day keys are
/// `yyyy-MM-dd` calendar days handled in UTC, like every other day-keyed chart in the app.
enum KeyMetricHistory {

    /// One measured night (keyed by the day it ends) or day.
    struct Reading: Equatable, Identifiable, Sendable {
        /// `yyyy-MM-dd`.
        let day: String
        /// The day at 00:00 UTC (the chart's x position).
        let date: Date
        let value: Double
        var id: String { day }
    }

    /// The range chips, shortest first.
    static let ranges: [ExploreRange] = [.week, .month, .quarter, .half, .year, .all]
    static let defaultRange: ExploreRange = .month

    private static var calendar: Calendar { PhysiologyContextDates.calendar }

    /// The chips for a source that serves at most `historyDays` days (nil: every chip). ALL always stays.
    static func ranges(historyDays: Int?) -> [ExploreRange] {
        guard let historyDays else { return ranges }
        return ranges.filter { ($0.days ?? 0) <= historyDays }
    }

    /// The measured periods of a series, ascending, one per day. A period with no reading is simply absent, and so
    /// is a non-finite or negative value. Zero is a reading only where `keepsZero` says so (steps); anywhere else
    /// it is a placeholder, dropped so a missing period reads as missing, never as zero. `before` (a `yyyy-MM-dd`
    /// key) leaves out that day and every later one.
    static func measured(_ series: [(day: String, value: Double)], keepsZero: Bool = false,
                         before: String? = nil) -> [Reading] {
        var byDay: [String: Reading] = [:]
        for row in series where row.value.isFinite && (row.value > 0 || (keepsZero && row.value == 0)) {
            guard byDay[row.day] == nil, let date = PhysiologyContextDates.date(row.day) else { continue }
            if let before, row.day >= before { continue }
            byDay[row.day] = Reading(day: row.day, date: date, value: row.value)
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// The readings `metric`'s screen shows: its zero rule, and for a day metric only the complete local days
    /// before `today` (`yyyy-MM-dd`), because today is still running. A night is keyed by the day it ends, so last
    /// night carries today's key and stays.
    static func measured(_ series: [(day: String, value: Double)], for metric: MetricInsightMetric,
                         today: String) -> [Reading] {
        measured(series, keepsZero: metric.keepsZero, before: metric.period == .day ? today : nil)
    }

    /// The headline: the latest measured period, nil when nothing has been measured.
    static func latestMeasured(_ series: [(day: String, value: Double)], keepsZero: Bool = false,
                               before: String? = nil) -> Reading? {
        measured(series, keepsZero: keepsZero, before: before).last
    }

    /// The calendar days a range shows: the trailing `range.days` days ending at the latest measured period (so a
    /// stale-but-present history still draws), or first through last measured period for ALL. A single reading's
    /// ALL still spans a week so the chart has an axis to sit on. Nil when nothing has been measured.
    static func domain(_ readings: [Reading], range: ExploreRange) -> ClosedRange<Date>? {
        guard let first = readings.first, let last = readings.last else { return nil }
        if let days = range.days, days > 0 {
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: last.date) ?? last.date
            return start...last.date
        }
        guard first.date < last.date else {
            return (calendar.date(byAdding: .day, value: -6, to: last.date) ?? last.date)...last.date
        }
        return first.date...last.date
    }

    /// The readings inside `domain`.
    static func window(_ readings: [Reading], domain: ClosedRange<Date>?) -> [Reading] {
        guard let domain else { return [] }
        return readings.filter { domain.contains($0.date) }
    }

    /// Calendar days in `domain`, inclusive.
    static func dayCount(_ domain: ClosedRange<Date>) -> Int {
        (calendar.dateComponents([.day], from: domain.lowerBound, to: domain.upperBound).day ?? 0) + 1
    }

    /// Runs of consecutive measured periods. A run breaks wherever one or more calendar days between two readings
    /// have none, so the line never bridges a period that was not measured (and never dips to zero).
    static func runs(_ readings: [Reading]) -> [[Reading]] {
        var runs: [[Reading]] = []
        for reading in readings {
            if let previous = runs.last?.last,
               calendar.dateComponents([.day], from: previous.date, to: reading.date).day == 1 {
                runs[runs.count - 1].append(reading)
            } else {
                runs.append([reading])
            }
        }
        return runs
    }

    /// Whole days between the first and last reading (0 for one reading or none).
    static func spanDays(_ readings: [Reading]) -> Int {
        guard let first = readings.first, let last = readings.last else { return 0 }
        return calendar.dateComponents([.day], from: first.date, to: last.date).day ?? 0
    }

    /// Whether a range chip is selectable (the #943 rule the full dossier uses): a longer range unlocks only once
    /// the history would show more than the chip below it, so thin history cannot be stretched under a 1Y label.
    /// W and ALL never lock, and with no history nothing locks. A chip outside `ranges` is never selectable.
    static func isUnlocked(_ range: ExploreRange, spanDays: Int, hasHistory: Bool,
                           among ranges: [ExploreRange] = ranges) -> Bool {
        guard ranges.contains(range) else { return false }
        guard hasHistory else { return true }
        switch range {
        case .week, .all: return true
        case .month:      return spanDays > ExploreRange.week.rawValue
        case .quarter:    return spanDays > ExploreRange.month.rawValue
        case .half:       return spanDays > ExploreRange.quarter.rawValue
        case .year:       return spanDays > ExploreRange.half.rawValue
        case .twoWeeks, .threeWeeks: return false
        }
    }

    /// The chart's value range: the window's own values with a little air (at least `minimumPad` either side, in
    /// the plotted units), so a flat week still has height. The floor is zero, never below it.
    static func valueDomain(_ values: [Double], minimumPad: Double = 3) -> ClosedRange<Double>? {
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let pad = max((hi - lo) * 0.15, minimumPad)
        return max(0, lo - pad)...(hi + pad)
    }

    /// `metric.format`'s text split into the number and its unit, so the headline can set the unit smaller. When
    /// the text does not end in the unit it is returned whole.
    static func splitUnit(_ formatted: String, unit: String) -> (number: String, unit: String?) {
        let suffix = " " + unit
        guard !unit.isEmpty, formatted.hasSuffix(suffix), formatted.count > suffix.count else { return (formatted, nil) }
        return (String(formatted.dropLast(suffix.count)), unit)
    }
}

// MARK: - Copy

/// The key-metric screen's own words for its period: a night metric speaks of measured nights, a day metric of
/// full days. In one place so the checks can read every string the screen may show.
enum KeyMetricCopy {
    /// The headline's label.
    static func latest(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Latest measured night")
        case .day: return String(localized: "Latest full day")
        }
    }

    static func noneYet(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "No measured nights yet")
        case .day: return String(localized: "No measured days yet")
        }
    }

    static func reading(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Reading your nights…")
        case .day: return String(localized: "Reading your days…")
        }
    }

    static func nothingToChart(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "No measured nights to chart yet.")
        case .day: return String(localized: "No measured days to chart yet.")
        }
    }

    /// The chart's caption at rest: how many periods of the range were measured.
    static func measured(_ count: Int, of total: Int, _ period: MetricInsightPeriod) -> String {
        switch period {
        case .night:
            return count == 1 ? String(localized: "1 of \(total) nights measured")
                : String(localized: "\(count) of \(total) nights measured")
        case .day:
            return count == 1 ? String(localized: "1 of \(total) days measured")
                : String(localized: "\(count) of \(total) days measured")
        }
    }

    /// VoiceOver's hint on the chart.
    static func adjustHint(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Swipe up or down to move through the nights.")
        case .day: return String(localized: "Swipe up or down to move through the days.")
        }
    }

    /// The chart's x axis.
    static func axis(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Night")
        case .day: return String(localized: "Day")
        }
    }

    /// Every period-dependent string above, for both periods (for the copy checks).
    static var allPeriodText: [String] {
        MetricInsightPeriod.allCases.flatMap { period in
            [latest(period), noneYet(period), reading(period), nothingToChart(period), measured(1, of: 7, period),
             measured(5, of: 7, period), adjustHint(period), axis(period)]
        }
    }
}

// MARK: - Dates

/// Day labels for the key-metric screen, formatted in UTC (day keys are calendar days; a local zone west of UTC
/// would otherwise print the previous day) with the app language's words.
enum KeyMetricDates {
    static func format(_ date: Date, template: String, locale: Locale = AppLanguage.activeLocale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// "Tue, 6 Oct 2026": a night (the day it ends) or a day.
    static func long(_ date: Date) -> String { format(date, template: "EEEdMMMyyyy") }

    /// "Tue, 6 Oct", with the year when asked.
    static func short(_ date: Date, includeYear: Bool) -> String {
        format(date, template: includeYear ? "EEEdMMMyyyy" : "EEEdMMM")
    }

    /// "6 Oct 2026" for a `yyyy-MM-dd` key; nil when it is not one.
    static func day(_ key: String, locale: Locale = AppLanguage.activeLocale) -> String? {
        PhysiologyContextDates.date(key).map { format($0, template: "dMMMyyyy", locale: locale) }
    }
}
