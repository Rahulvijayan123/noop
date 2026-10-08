import Foundation
import StrandAnalytics

// KeyMetricScreenModel.swift — the pure rules behind the key-metric screen's period control, its shaded range,
// its 24-hour view and its words (`KeyMetricDetailView`). Nothing here reads a store or draws.
//
// Two kinds of shaded range sit behind the readings, never mixed:
//   • the person's USUAL range (Layer 1, `LongitudinalBaseline.vitalVerdict`): the same band the Monitor list, the
//     Home ring and the server's explanations use, for each night or day it was computed on. Only the metrics the
//     app has a usual for (docs/METRIC_INSIGHTS.md) get one.
//   • the RECENT range: the middle 80% of the person's previous 30 measured nights or days, for the metrics the
//     app shows no usual for (SDNN, blood oxygen, stable awake heart rate, calories). It is never called "usual".
// Neither is a safety range, and the screen says so.
//
// The 24-hour view shows the server's 5-minute window estimates (the physiology context layer), each with the
// context it was taken in. A window without an accepted estimate is left out, never drawn as zero.

// MARK: - Periods

/// What the period control offers: the 5-minute windows of one day, or a range of measured nights or days.
enum KeyMetricPeriod: Hashable, Sendable {
    case hours24
    case range(ExploreRange)

    var range: ExploreRange? {
        if case .range(let r) = self { return r }
        return nil
    }
}

extension MetricInsightMetric {
    /// The context-layer metric whose 5-minute windows the 24-hour view shows; nil when the screen has no such
    /// view. Resting heart rate, temperature, breathing, blood oxygen, steps and calories are nightly or daily
    /// values whose windows are not the same measurement, so they keep to the multi-day views.
    var windowMetric: PhysiologyContext.MetricKind? {
        switch self {
        case .hrvRmssd: return .hrvRmssd
        case .hrvSdnn: return .hrvSdnn
        case .heartRate: return .heartRate
        default: return nil
        }
    }

    /// The Layer 1 series that is this metric's usual (docs/METRIC_INSIGHTS.md, "the person's usual"); nil for
    /// the metrics the app shows no usual for, which compare with recent periods instead.
    var usualSeries: LBSeries? {
        switch self {
        case .restingHeartRate: return .sleepRHR
        case .hrvRmssd: return .sleepHRVLn
        case .skinTemp: return .sleepTemp
        case .respRate: return .sleepResp
        case .steps: return .wakingSteps
        case .hrvSdnn, .spo2, .heartRate, .calories: return nil
        }
    }

    /// The 24-hour view's starting context: sleep for the night metrics, stable awake for the day one.
    var defaultWindowContext: KeyMetricWindowFilter {
        period == .night ? .sleep : .stableAwake
    }
}

enum KeyMetricPeriods {
    /// The period chips for a metric, shortest first: the 24-hour view where there is one, then ranges a source
    /// can serve (the context history serves 120 days, so stable awake heart rate stops at 90).
    static func periods(for metric: MetricInsightMetric) -> [KeyMetricPeriod] {
        let longest: ExploreRange = (metric.historyDays ?? .max) >= 365 ? .year : .quarter
        if metric.windowMetric != nil {
            return [.hours24, .range(.week), .range(.month), .range(longest)]
        }
        return [.range(.week), .range(.month), .range(.quarter), .range(longest)].uniqued()
    }

    /// The period a screen opens on: 30 nights or days, the view that shows the shaded range best.
    static let defaultPeriod: KeyMetricPeriod = .range(.month)

    /// The chip's label: "24 hours", "7 nights", "30 days", "1 year".
    static func label(_ period: KeyMetricPeriod, _ p: MetricInsightPeriod) -> String {
        switch period {
        case .hours24: return String(localized: "24 hours")
        case .range(let r):
            switch r {
            case .year: return String(localized: "1 year")
            default:
                let n = r.days ?? 0
                return p == .night ? String(localized: "\(n) nights") : String(localized: "\(n) days")
            }
        }
    }

    /// Whether a period chip can be chosen. The 24-hour view always can (it says when it has nothing); a range
    /// follows the #943 rule the history card used (`KeyMetricHistory.isUnlocked`).
    static func isUnlocked(_ period: KeyMetricPeriod, spanDays: Int, hasHistory: Bool) -> Bool {
        switch period {
        case .hours24: return true
        case .range(let r):
            return KeyMetricHistory.isUnlocked(r, spanDays: spanDays, hasHistory: hasHistory,
                                               among: [.week, .month, .quarter, .year])
        }
    }

    /// A locked choice shows as the longest unlocked period below it, without overwriting the choice.
    static func coerced(_ period: KeyMetricPeriod, among periods: [KeyMetricPeriod],
                        isUnlocked: (KeyMetricPeriod) -> Bool) -> KeyMetricPeriod {
        guard !isUnlocked(period), let index = periods.firstIndex(of: period) else { return period }
        return periods[..<index].last(where: isUnlocked) ?? periods.first(where: isUnlocked) ?? period
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Shaded range

/// The range drawn behind the multi-day readings.
struct KeyMetricBand: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Layer 1: the person's usual for each night or day.
        case usual
        /// The middle 80% of the previous `KeyMetricBands.recentCount` measured periods.
        case recent
    }

    /// One period's range, in stored units.
    struct Span: Equatable, Sendable {
        let day: String
        let date: Date
        let low: Double
        let high: Double
    }

    let kind: Kind
    /// Ascending. A usual band has one span per period it was computed for; a recent band one span per drawn day
    /// edge (it is the same range across the chart).
    let spans: [Span]

    /// The range on the latest span.
    var latest: Span? { spans.last }
}

/// Where a reading sits against the shaded range.
enum KeyMetricPlacement: Equatable, Sendable {
    case within, above, below
    /// A usual that is not trusted yet (Layer 1 "learning").
    case learning
    /// No range to compare with.
    case none

    static func of(_ value: Double, low: Double, high: Double) -> KeyMetricPlacement {
        value > high ? .above : value < low ? .below : .within
    }
}

enum KeyMetricBands {
    /// How many earlier measured periods the recent range is built from, and the fewest it needs.
    static let recentCount = 30
    static let recentMinimum = 7

    /// The 10th and 90th percentiles (linear interpolation), nil for fewer than `recentMinimum` values.
    static func middle80(_ values: [Double]) -> (low: Double, high: Double)? {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count >= recentMinimum else { return nil }
        func quantile(_ q: Double) -> Double {
            let position = q * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
            let fraction = position - Double(lower)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        }
        return (quantile(0.1), quantile(0.9))
    }

    /// The recent range of a window: the middle 80% of the `recentCount` measured periods before the window's
    /// latest reading (never including it), drawn flat across the window. Nil without enough history.
    static func recent(_ readings: [KeyMetricHistory.Reading],
                       window: [KeyMetricHistory.Reading]) -> KeyMetricBand? {
        guard let last = window.last, let first = window.first else { return nil }
        let earlier = readings.filter { $0.day < last.day }.suffix(recentCount)
        guard let range = middle80(earlier.map(\.value)) else { return nil }
        let spans = [first, last].map { KeyMetricBand.Span(day: $0.day, date: $0.date, low: range.low, high: range.high) }
        return KeyMetricBand(kind: .recent, spans: first.day == last.day ? [spans[0]] : spans)
    }

    /// The usual band from each period's Layer 1 verdict, ascending; periods without a trusted usual are left out
    /// (the band has a gap there rather than a guess). Every key metric is a positive quantity, so a band whose
    /// centre minus its spread falls below zero (thin step history, say) is drawn from zero.
    static func usual(_ verdicts: [String: LBVitalVerdict]) -> KeyMetricBand? {
        let spans = verdicts.compactMap { day, v -> KeyMetricBand.Span? in
            guard v.state != .learning, let lo = v.bandLo, let hi = v.bandHi, lo.isFinite, hi.isFinite, hi >= lo,
                  hi > 0, let date = PhysiologyContextDates.date(day) else { return nil }
            return KeyMetricBand.Span(day: day, date: date, low: max(0, lo), high: hi)
        }.sorted { $0.day < $1.day }
        return spans.isEmpty ? nil : KeyMetricBand(kind: .usual, spans: spans)
    }

    /// The periods to compute a usual for: every measured one in a short window; in a long one about
    /// `maxEvaluations` evenly spread, always including the latest (each costs a Layer 1 replay).
    static let maxEvaluations = 45
    static func usualDays(_ window: [KeyMetricHistory.Reading]) -> [String] {
        guard window.count > maxEvaluations else { return window.map(\.day) }
        let stride = Int((Double(window.count) / Double(maxEvaluations)).rounded(.up))
        var days = Swift.stride(from: window.count - 1, through: 0, by: -stride).map { window[$0].day }
        days.reverse()
        return days
    }

    /// Where `value` on `day` sits: against that day's usual span when the band is a usual, else the recent range.
    static func placement(_ value: Double, day: String, band: KeyMetricBand?,
                          verdicts: [String: LBVitalVerdict]) -> KeyMetricPlacement {
        guard let band else { return .none }
        switch band.kind {
        case .usual:
            guard let v = verdicts[day] else { return .none }
            if v.state == .learning { return .learning }
            guard let lo = v.bandLo, let hi = v.bandHi else { return .none }
            return .of(value, low: lo, high: hi)
        case .recent:
            guard let span = band.latest else { return .none }
            return .of(value, low: span.low, high: span.high)
        }
    }
}

// MARK: - Summary

enum KeyMetricSummary {
    /// The median of `values` (the mean of the middle two for an even count); nil when empty.
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

// MARK: - 24-hour view

/// The context a 5-minute window was taken in, from the server's sleep detection, stable-awake eligibility and
/// activity composition. An estimate, and the screen labels it so.
enum KeyMetricWindowContext: String, CaseIterable, Sendable {
    case sleep
    case stableAwake
    case moving
    case awake
    case mixed
    case unknown

    var name: String {
        switch self {
        case .sleep: return String(localized: "Sleep")
        case .stableAwake: return String(localized: "Stable awake")
        case .moving: return String(localized: "Moving")
        case .awake: return String(localized: "Awake")
        case .mixed: return String(localized: "Mixed")
        case .unknown: return String(localized: "Unknown")
        }
    }

    /// Activity labels that mean the wrist was moving (PhysiologyContextWording.activityLabel's set).
    static let movingLabels: Set<String> = [
        "walking", "brisk_walking", "running", "stepping", "cycling", "other_movement", "light_activity",
        "vigorous_activity",
    ]

    /// Sleep first (the sleep detector's state), then stable awake (the server's own eligibility), then a
    /// dominant moving label, then mixed (partly asleep, or no single activity label), then plain awake.
    static func of(_ e: PhysiologyContext.MeasurementEnvelope) -> KeyMetricWindowContext {
        switch e.sleepWear.sleepState {
        case .asleep: return .sleep
        case .mixed: return .mixed
        case .unknown: return .unknown
        case .awake: break
        }
        if e.verdict(.stableAwakeRest)?.state == .eligible { return .stableAwake }
        if let label = e.activity.dominantLabel, movingLabels.contains(label) { return .moving }
        if e.activity.mixed || e.activity.dominantLabel == nil { return .mixed }
        return .awake
    }
}

/// The 24-hour view's context chips.
enum KeyMetricWindowFilter: String, CaseIterable, Hashable, Sendable {
    case all, sleep, stableAwake

    var name: String {
        switch self {
        case .all: return String(localized: "All")
        case .sleep: return KeyMetricWindowContext.sleep.name
        case .stableAwake: return KeyMetricWindowContext.stableAwake.name
        }
    }

    func admits(_ context: KeyMetricWindowContext) -> Bool {
        switch self {
        case .all: return true
        case .sleep: return context == .sleep
        case .stableAwake: return context == .stableAwake
        }
    }
}

/// One accepted 5-minute estimate.
struct KeyMetricWindowReading: Equatable, Identifiable, Sendable {
    let id: String
    let start: Int
    let end: Int
    let value: Double
    let context: KeyMetricWindowContext
    /// The observed share of the window's input signal, when the server reported one.
    let coverage: Double?

    var mid: Date { Date(timeIntervalSince1970: TimeInterval(start + end) / 2) }
}

/// A stretch of the activity lane: consecutive windows with one context.
struct KeyMetricContextSpan: Equatable, Identifiable, Sendable {
    let start: Int
    let end: Int
    let context: KeyMetricWindowContext
    var id: Int { start }
}

enum KeyMetricWindows {
    /// The 5-minute window envelopes of `metric`: window aggregates (never a nightly or session value), inside
    /// `interval`, one per window id (the first document's wins), ascending by start.
    static func envelopes(_ documents: [PhysiologyContextDocument], metric: PhysiologyContext.MetricKind,
                          in interval: PhysiologyContext.Interval) -> [PhysiologyContext.MeasurementEnvelope] {
        var seen = Set<String>()
        return documents.flatMap(\.envelopes).filter { e in
            e.metric == metric && e.method.aggregation == .window && !MeasurementContextSelection.isNightly(e)
                && interval.contains(e.support.start) && seen.insert(e.id).inserted
        }.sorted { ($0.support.start, $0.id) < ($1.support.start, $1.id) }
    }

    /// The accepted estimates: a finite positive value whose signal passed the quality checks (fully, or with
    /// stated limitations). A window that failed them, or had no signal, is a gap.
    static func readings(_ envelopes: [PhysiologyContext.MeasurementEnvelope]) -> [KeyMetricWindowReading] {
        envelopes.compactMap { e in
            guard let v = e.value, v.isFinite, v > 0,
                  e.validity.state == .valid || e.validity.state == .degraded else { return nil }
            return KeyMetricWindowReading(id: e.id, start: e.support.start, end: e.support.end, value: v,
                                          context: KeyMetricWindowContext.of(e), coverage: e.validity.coverage)
        }
    }

    /// The activity lane: every window's context (accepted or not, so the lane shows where the strap knew the
    /// context even when the estimate was rejected), joined where adjacent windows share one.
    static func lane(_ envelopes: [PhysiologyContext.MeasurementEnvelope]) -> [KeyMetricContextSpan] {
        var spans: [KeyMetricContextSpan] = []
        for e in envelopes {
            let context = KeyMetricWindowContext.of(e)
            if let last = spans.last, last.context == context, e.support.start - last.end <= 60 {
                spans[spans.count - 1] = KeyMetricContextSpan(start: last.start, end: max(last.end, e.support.end),
                                                              context: context)
            } else {
                spans.append(KeyMetricContextSpan(start: e.support.start, end: e.support.end, context: context))
            }
        }
        return spans
    }

    /// The local days whose documents a 24-hour view reads, and its interval. A night metric shows noon to noon
    /// around the night ending on `day` (the documents of the day before and the day); a day metric shows `day`
    /// itself, midnight to midnight.
    static func span(day: String, period: MetricInsightPeriod,
                     timeZone: TimeZone) -> (days: [String], interval: PhysiologyContext.Interval)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let utc = PhysiologyContextDates.date(day) else { return nil }
        let parts = PhysiologyContextDates.calendar.dateComponents([.year, .month, .day], from: utc)
        guard let midnight = calendar.date(from: parts) else { return nil }
        switch period {
        case .night:
            guard let previous = PhysiologyContextDates.key(day, minusDays: 1),
                  let start = calendar.date(byAdding: .hour, value: -12, to: midnight),
                  let end = calendar.date(byAdding: .hour, value: 12, to: midnight) else { return nil }
            return ([previous, day], PhysiologyContext.Interval(Int(start.timeIntervalSince1970),
                                                                Int(end.timeIntervalSince1970)))
        case .day:
            guard let end = calendar.date(byAdding: .day, value: 1, to: midnight) else { return nil }
            return ([day], PhysiologyContext.Interval(Int(midnight.timeIntervalSince1970),
                                                      Int(end.timeIntervalSince1970)))
        }
    }

    /// The x range the chart shows for `filter`: the whole interval, except sleep, which zooms to the sleep
    /// windows (half an hour of air either side) when there are any.
    static func domain(interval: PhysiologyContext.Interval, readings: [KeyMetricWindowReading],
                       filter: KeyMetricWindowFilter) -> ClosedRange<Date> {
        let whole = Date(timeIntervalSince1970: TimeInterval(interval.start))...Date(timeIntervalSince1970: TimeInterval(interval.end))
        guard filter == .sleep else { return whole }
        let sleep = readings.filter { $0.context == .sleep }
        guard let first = sleep.first, let last = sleep.last else { return whole }
        let lo = max(interval.start, first.start - 1_800), hi = min(interval.end, last.end + 1_800)
        return Date(timeIntervalSince1970: TimeInterval(lo))...Date(timeIntervalSince1970: TimeInterval(hi))
    }

    /// The person's reference for the day's stable-awake median of `metric` (the server's comparison of
    /// `<metric>.stable_awake_5min`), when one is ready. The 24-hour view draws its centre as a line beside the
    /// stable-awake windows; sleep windows have no window-level reference, so they get none.
    static func stableAwakeReference(_ documents: [PhysiologyContextDocument],
                                     metric: PhysiologyContext.MetricKind)
        -> PhysiologyContext.ReferenceComparison? {
        guard let series = PhysiologyContext.ContextReferences.stableAwakeSeriesKey(
            metric: metric, config: PhysiologyContext.ReferenceConfig()) else { return nil }
        let comparisons = documents.flatMap(\.comparisons).filter { $0.seriesKey == series }
        guard let reference = MeasurementContextSelection.headlineReference(comparisons),
              reference.status == .ready || reference.status == .provisional,
              let center = reference.center, center.isFinite, center > 0 else { return nil }
        return reference
    }
}

// MARK: - Copy

/// Every string the key-metric screen adds, in one place so the wording checks can read them all.
enum KeyMetricScreenCopy {

    static func median(count: Int, _ period: MetricInsightPeriod) -> String {
        switch period {
        case .night:
            return count == 1 ? String(localized: "1 measured night")
                : String(localized: "Median of \(count) measured nights")
        case .day:
            return count == 1 ? String(localized: "1 measured day")
                : String(localized: "Median of \(count) measured days")
        }
    }

    static func windowMedian(count: Int, filter: KeyMetricWindowFilter) -> String {
        switch filter {
        case .all: return String(localized: "Median of \(count) readings, all contexts")
        case .sleep: return String(localized: "Median of \(count) sleep readings")
        case .stableAwake: return String(localized: "Median of \(count) stable awake readings")
        }
    }

    static func usualNow(_ range: String) -> String { String(localized: "Your usual range: \(range)") }
    static func recentRange(_ range: String, _ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Your recent range: \(range) (previous 30 nights)")
        case .day: return String(localized: "Your recent range: \(range) (previous 30 days)")
        }
    }
    static func usualLearning(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Your usual range appears after a few more measured nights")
        case .day: return String(localized: "Your usual range appears after a few more measured days")
        }
    }
    static func recentLearning(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "A recent range appears after 7 measured nights")
        case .day: return String(localized: "A recent range appears after 7 measured days")
        }
    }

    static func placement(_ p: KeyMetricPlacement, kind: KeyMetricBand.Kind) -> String? {
        switch (p, kind) {
        case (.within, .usual): return String(localized: "Within your usual range")
        case (.above, .usual): return String(localized: "Above your usual range")
        case (.below, .usual): return String(localized: "Below your usual range")
        case (.within, .recent): return String(localized: "Within your recent range")
        case (.above, .recent): return String(localized: "Above your recent range")
        case (.below, .recent): return String(localized: "Below your recent range")
        case (.learning, _): return String(localized: "Usual range still being learned")
        case (.none, _): return nil
        }
    }

    static func bandLegend(_ kind: KeyMetricBand.Kind) -> String {
        switch kind {
        case .usual: return String(localized: "Your usual range")
        case .recent: return String(localized: "Your recent range")
        }
    }

    static var reading: String { String(localized: "Reading") }
    static var noReading: String { String(localized: "No reading") }
    static var gapNote: String { String(localized: "not drawn as zero") }
    static var activityLane: String { String(localized: "Activity context · estimated") }
    static var stableAwakeReference: String { String(localized: "Your usual stable awake median") }

    static func windowCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 usable reading · gaps stay visible")
            : String(localized: "\(count) usable readings · gaps stay visible")
    }

    static func measuredCount(_ count: Int, of total: Int, _ period: MetricInsightPeriod) -> String {
        String(localized: "\(KeyMetricCopy.measured(count, of: total, period)) · gaps stay visible")
    }

    static func noWindows(_ filter: KeyMetricWindowFilter) -> String {
        switch filter {
        case .all: return String(localized: "No 5-minute readings for this day yet.")
        case .sleep: return String(localized: "No sleep readings for this night yet.")
        case .stableAwake: return String(localized: "No stable awake readings for this day yet.")
        }
    }

    static func windowsSummaryEmpty(_ filter: KeyMetricWindowFilter) -> String {
        switch filter {
        case .all: return String(localized: "No 5-minute readings to summarise")
        case .sleep: return String(localized: "No sleep readings to summarise")
        case .stableAwake: return String(localized: "No stable awake readings to summarise")
        }
    }

    static var windowsNeedCloud: String {
        String(localized: "The 24-hour view needs cloud sync: its 5-minute readings are prepared on the server.")
    }
    static var windowsLoading: String { String(localized: "Reading the day's 5-minute windows…") }
    static var windowsPending: String { String(localized: "The day's 5-minute readings are still being prepared.") }

    static func usableSignal(_ share: Double) -> String {
        String(localized: "\(PhysiologyContextWording.percent(share)) usable signal")
    }

    // Disclosures and their rows.
    static var method: String { String(localized: "Data & method") }
    static var readings: String { String(localized: "Readings") }
    static var compareHeartRate: String { String(localized: "Compare heart rate") }
    static var compareRestingHeartRate: String { String(localized: "Compare resting heart rate") }
    static var heartRateMatching: String { String(localized: "Heart rate · matching windows") }
    static var restingHeartRateNights: String { String(localized: "Resting heart rate · same nights") }

    static var rowMetric: String { String(localized: "Metric") }
    static var rowSource: String { String(localized: "Source") }
    static var rowShaded: String { String(localized: "Shaded range") }
    static var rowComparison: String { String(localized: "Comparison") }
    static var rowContext: String { String(localized: "Context") }
    static var rowMissing: String { String(localized: "Missing readings") }
    static var rowTime: String { String(localized: "Time") }
    static var rowNight: String { String(localized: "Night") }
    static var rowDay: String { String(localized: "Day") }

    static var shadedUsual: String {
        String(localized: "Your usual range for each night or day, from your own history. Not a safety range.")
    }
    static func shadedRecent(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Middle 80% of your previous 30 measured nights. Not a safety range.")
        case .day: return String(localized: "Middle 80% of your previous 30 measured days. Not a safety range.")
        }
    }
    static var comparisonUsual: String {
        String(localized: "The same personal baseline the Monitor and your explanation use")
    }
    static var comparisonRecent: String {
        String(localized: "Your own recent history; no usual range is kept for this metric")
    }
    static func missing(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "A night without a reading is a gap, never zero")
        case .day: return String(localized: "A day without a reading is a gap, never zero")
        }
    }
    static var windowsMissing: String {
        String(localized: "Windows that did not pass quality checks are left out, never zero")
    }
    static var windowsContext: String {
        String(localized: "Estimated from the sleep detector, motion and steps")
    }
    static var windowsComparisonStableAwake: String {
        String(localized: "The line is your usual median of stable awake windows")
    }
    static var windowsComparisonOther: String {
        String(localized: "Single windows have no usual range; compare nights in the 7- and 30-night views")
    }
    static var sourceStrap: String { String(localized: "Your strap") }
    static var sourceServer: String { String(localized: "Your strap, processed on the server") }
    static var rowMeasurement: String { String(localized: "Measured or estimated") }
    static var windowsAllNoRange: String {
        String(localized: "Contexts are shown below the chart; there is no combined range")
    }
    static var localTime: String { String(localized: "Local time") }
    static var heartRateAxis: String { String(localized: "Heart rate (bpm)") }
    static var fiveMinute: String { String(localized: "5-minute windows") }

    /// The reading's grain on the panel: one value per night or per day.
    static func grain(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Nightly")
        case .day: return String(localized: "Daily")
        }
    }

    /// The chart's value-axis name, before its unit.
    static func chartName(_ metric: MetricInsightMetric) -> String {
        switch metric {
        case .restingHeartRate: return String(localized: "Resting heart rate")
        case .hrvRmssd, .hrvSdnn: return String(localized: "HRV")
        case .skinTemp: return String(localized: "Wrist temperature")
        case .respRate: return String(localized: "Breathing rate")
        case .spo2: return String(localized: "Blood oxygen")
        case .heartRate: return String(localized: "Heart rate")
        case .steps: return String(localized: "Steps")
        case .calories: return String(localized: "Calories")
        }
    }

    /// How the remembered interest names the metric: HRV as a whole, whichever side was open.
    static func memoryName(_ metric: MetricInsightMetric) -> String {
        switch metric {
        case .hrvRmssd, .hrvSdnn: return String(localized: "heart rate variability (HRV)")
        default: return metric.title
        }
    }

    /// What one reading is, for the method rows.
    static func metricDescription(_ metric: MetricInsightMetric, windows: Bool) -> String {
        if windows {
            switch metric {
            case .hrvRmssd: return String(localized: "Pulse-derived RMSSD in 5-minute windows")
            case .hrvSdnn: return String(localized: "Pulse-derived SDNN in 5-minute windows")
            default: return String(localized: "Heart rate in 5-minute windows")
            }
        }
        switch metric {
        case .restingHeartRate: return String(localized: "Your resting heart rate, one value per night")
        case .hrvRmssd: return String(localized: "Pulse-derived RMSSD, one value per night")
        case .hrvSdnn: return String(localized: "Nightly SDNN index (5-minute SDNN, averaged)")
        case .skinTemp: return String(localized: "Wrist skin temperature during sleep (not core temperature)")
        case .respRate: return String(localized: "Breathing rate estimated from heartbeat timing during sleep")
        case .spo2: return String(localized: "Blood oxygen estimate during sleep, not yet verified")
        case .heartRate: return String(localized: "Median heart rate in stable awake 5-minute windows, per day")
        case .steps: return String(localized: "Steps counted by your strap, per full day")
        case .calories: return String(localized: "Estimated energy for each full day")
        }
    }

    /// Every fixed string above for both periods (for the copy checks).
    static var allFixedText: [String] {
        let periods = MetricInsightPeriod.allCases
        let fixed: [String] = [
            usualNow("45–62 ms"), reading, noReading, gapNote, activityLane, stableAwakeReference,
            windowCount(1), windowCount(64), windowsNeedCloud, windowsLoading, windowsPending, usableSignal(0.8),
            method, readings, compareHeartRate, compareRestingHeartRate, heartRateMatching,
            restingHeartRateNights, rowMetric, rowSource, rowShaded, rowComparison, rowContext, rowMissing, rowTime,
            rowNight, rowDay, shadedUsual, comparisonUsual, comparisonRecent, windowsMissing, windowsContext,
            windowsComparisonStableAwake, windowsComparisonOther, sourceStrap, sourceServer, rowMeasurement,
            windowsAllNoRange, localTime, heartRateAxis, fiveMinute,
        ]
        let perPeriod = periods.flatMap { p in
            [median(count: 1, p), median(count: 26, p), recentRange("38–55 ms", p), usualLearning(p),
             recentLearning(p), measuredCount(5, of: 7, p), shadedRecent(p), missing(p)]
                + [KeyMetricPeriod.hours24, .range(.week), .range(.month), .range(.quarter), .range(.year)]
                    .map { KeyMetricPeriods.label($0, p) }
        }
        let windows = KeyMetricWindowFilter.allCases.flatMap {
            [windowMedian(count: 12, filter: $0), noWindows($0), windowsSummaryEmpty($0), $0.name]
        }
        let contexts = KeyMetricWindowContext.allCases.map(\.name)
        let placements = [KeyMetricPlacement.within, .above, .below, .learning].flatMap { p in
            [KeyMetricBand.Kind.usual, .recent].compactMap { placement(p, kind: $0) }
        }
        let descriptions = MetricInsightMetric.allCases.flatMap {
            [metricDescription($0, windows: false), metricDescription($0, windows: true)]
        }
        let names = MetricInsightMetric.allCases.flatMap { [chartName($0), memoryName($0)] }
        return fixed + perPeriod + windows + contexts + placements + descriptions + names
            + periods.map(grain) + [bandLegend(.usual), bandLegend(.recent)]
    }
}
