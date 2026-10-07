import SwiftUI

// MARK: - NaraChart shared data types
//
// The values every kit chart draws. Screens build these from numbers they have already computed: nothing
// in this folder reads, derives or scores health data, it only lays out what it is handed.
//
// These types are plain values with no Swift Charts dependency, so they compile on every platform the
// package builds for (watchOS included) even though the charts that draw them do not.

// MARK: Days

/// The bridge between stored day keys (`yyyy-MM-dd`) and the dates a daily chart plots.
///
/// A day key names a calendar day, not an instant. Parsing it at UTC midnight (what the detail page did)
/// puts every reading at 17:00 the previous evening for a viewer in California, so the axis, which marks
/// local days, labelled each point one day early and the newest day had no label at all. Every daily chart
/// takes the LOCAL start of the day instead, built here, so a reading, its bar and its axis label agree in
/// whatever zone the viewer is in.
///
/// Keys are always read as Gregorian dates, whatever calendar the viewer uses: a Buddhist or Japanese
/// `Calendar.current` would otherwise turn "2026-10-07" into a date five centuries away. Only the calendar's
/// time zone decides where the day starts.
public enum ChartDay {

    /// The local start of the day `key` names, in `calendar`'s time zone. Nil for anything that is not a
    /// real `yyyy-MM-dd` date (a malformed key, or one like "2026-02-30" that a lenient calendar would roll
    /// into March).
    public static func date(forKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let gregorian = gregorianCalendar(like: calendar)
        // Noon, not midnight: in a zone that changes its clocks at midnight the 00:00 of that day does not
        // exist, and `startOfDay` below finds the day's real first instant either way.
        guard let noon = gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
            return nil
        }
        let back = gregorian.dateComponents([.year, .month, .day], from: noon)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return gregorian.startOfDay(for: noon)
    }

    /// The `yyyy-MM-dd` key of the local day `date` falls in.
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = gregorianCalendar(like: calendar).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The local start of the calendar day a UTC-midnight date stands for.
    ///
    /// For call sites that already hold dates parsed from day keys at UTC midnight: the day is re-read in
    /// UTC and rebuilt as the same calendar day in `calendar`'s zone, which is the fix for a one-day-early
    /// axis without touching how the keys are stored or loaded.
    public static func day(fromUTCMidnight date: Date, calendar: Calendar = .current) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return Self.date(forKey: key(for: date, calendar: utc), calendar: calendar) ?? calendar.startOfDay(for: date)
    }

    /// The middle of the calendar `unit` (day, week, month) containing `date`. On a 23- or 25-hour day this
    /// is half way between the day's real start and end, which is where Swift Charts centres a mark plotted
    /// with `unit: .day`.
    public static func center(of date: Date, unit: Calendar.Component = .day, calendar: Calendar = .current) -> Date {
        guard let interval = calendar.dateInterval(of: unit, for: date) else { return date }
        return interval.start.addingTimeInterval(interval.duration / 2)
    }

    /// Whole calendar days from the day of `from` to the day of `to`, counted on local day boundaries so a
    /// 23- or 25-hour day still counts as one.
    public static func daysBetween(_ from: Date, _ to: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from),
                                to: calendar.startOfDay(for: to)).day ?? 0
    }

    private static func gregorianCalendar(like calendar: Calendar) -> Calendar {
        if calendar.identifier == .gregorian { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }
}

// MARK: Points

/// One value on a day or night cadence.
///
/// `day` is the LOCAL start of the day the value belongs to; a night belongs to the day you woke up. Charts
/// plot it with `unit: .day` (or the bin they aggregate to), so a bar or point sits in the middle of its day
/// rather than on the boundary before it.
public struct DailyPoint: Identifiable, Hashable, Sendable {
    public var day: Date
    public var value: Double
    /// Drawn hollow (points) or as a light fill with a solid cap (bars); the legend says "Estimate".
    public var isEstimate: Bool
    /// Method or source run. A change starts a new line, so two incompatible methods are never joined
    /// (the same idea as `TrendPoint.segment`).
    public var series: String
    public var id: Date { day }

    public init(day: Date, value: Double, isEstimate: Bool = false, series: String = "default") {
        self.day = day
        self.value = value
        self.isEstimate = isEstimate
        self.series = series
    }

    /// A point for a stored `yyyy-MM-dd` key, at the local start of that day. Nil for a malformed key.
    public init?(key: String, value: Double, isEstimate: Bool = false, series: String = "default",
                 calendar: Calendar = .current) {
        guard let day = ChartDay.date(forKey: key, calendar: calendar) else { return nil }
        self.init(day: day, value: value, isEstimate: isEstimate, series: series)
    }
}

/// How often a metric is sampled. Decides where a line breaks: a gap longer than the cadence is drawn as
/// a gap, never joined across.
public enum ChartCadence: Equatable, Sendable {
    /// One value a day or night: break when consecutive days are more than one day apart.
    case daily
    /// About one value a week: break when readings are more than ten days apart.
    case weekly
    /// Irregular readings (weight, VO2 max): break only across gaps longer than `maxGapDays`.
    case sparse(maxGapDays: Int)
    /// Intraday buckets: break wherever a bucket is skipped (the `hrGapSegments` rule).
    case buckets(seconds: Int)
    /// The median-step rule `TrendChart` uses (`TrendChart.gapSegments`), for series of unknown cadence.
    case adaptive
}

/// How several days are combined into one bar on long ranges.
public enum ChartAggregation: Equatable, Sendable {
    /// The average of the days that have a value (steps "per observed day", a weekly mean score).
    case mean
    /// The total of the days in the bin (weekly zone minutes, weekly intensity minutes).
    case sum
}

/// Line interpolation. Both pass through every reading and never swing past one; Catmull-Rom is not
/// offered because it overshoots sharp turns and invents peaks the data never had.
public enum ChartInterpolation: Equatable, Sendable {
    case monotone
    case linear
}

// MARK: Value axis

/// The value axis's extent: fixed where the metric has a natural scale, fitted to the data otherwise.
public enum ChartDomain: Equatable, Sendable {
    /// A natural scale: 0...100 scores, 85...100 % oxygen, 0...3 stress. A reading outside it widens the
    /// domain just enough to show it, so a fixed axis never hides a value.
    case fixed(ClosedRange<Double>)
    /// Fitted to the values, at least `minSpan` tall, `headroom` (a fraction of the span) above and below,
    /// rounded out to whole tick steps. `includeZero` anchors bars at zero; `clampTo` keeps the axis inside
    /// a natural limit. A series that never goes below zero never gets an axis that does.
    case fitted(minSpan: Double, includeZero: Bool = false, clampTo: ClosedRange<Double>? = nil, headroom: Double = 0.08)
    /// Diverging values around zero: `-m...m`, `m` at least `minMagnitude`.
    case symmetric(minMagnitude: Double)

    /// The domain for `values` (non-finite values are ignored). Pure.
    public func resolve(_ values: [Double]) -> ClosedRange<Double> {
        resolved(values, tickCount: 4, steps: nil).domain
    }

    /// The domain and the tick step that produced it. A fitted domain is rounded out to whole steps, so its
    /// ticks are that same step; recomputing a step from the rounded span can pick a different one that no
    /// longer lands on the ends.
    func resolved(_ values: [Double], tickCount: Int, steps: [Double]?) -> (domain: ClosedRange<Double>, step: Double?) {
        let finite = values.filter(\.isFinite)
        let count = max(1, tickCount)
        switch self {
        case .fixed(let range):
            guard let lo = finite.min(), let hi = finite.max(),
                  lo < range.lowerBound || hi > range.upperBound else { return (range, nil) }
            let step = ChartTicks.step(span: range.upperBound - range.lowerBound, count: count, candidates: steps)
            let lower = min(range.lowerBound, (lo / step).rounded(.down) * step)
            let upper = max(range.upperBound, (hi / step).rounded(.up) * step)
            return (lower...upper, step)

        case .fitted(let minSpan, let includeZero, let clamp, let headroom):
            let span0 = max(minSpan, .ulpOfOne)
            guard var lo = finite.min(), var hi = finite.max() else {
                // No data: an honest empty grid of the minimum span, from zero or the clamp's floor.
                let base = clamp?.lowerBound ?? 0
                let step = ChartTicks.step(span: span0, count: count, candidates: steps)
                return (base...(base + (span0 / step).rounded(.up) * step), step)
            }
            let nonNegative = lo >= 0
            if includeZero { lo = min(lo, 0); hi = max(hi, 0) }
            let anchoredLow = includeZero && lo == 0
            let anchoredHigh = includeZero && hi == 0 && !anchoredLow
            if hi - lo < span0 {
                if anchoredLow { hi = lo + span0 }
                else if anchoredHigh { lo = hi - span0 }
                else {
                    let pad = (span0 - (hi - lo)) / 2
                    lo -= pad; hi += pad
                }
            }
            let room = (hi - lo) * max(0, headroom)
            if !anchoredLow { lo -= room }
            if !anchoredHigh { hi += room }
            if nonNegative && lo < 0 { lo = 0 }
            let step = ChartTicks.step(span: hi - lo, count: count, candidates: steps)
            lo = (lo / step).rounded(.down) * step
            hi = (hi / step).rounded(.up) * step
            if let clamp {
                lo = max(lo, clamp.lowerBound)
                hi = min(hi, clamp.upperBound)
            }
            if hi <= lo { hi = lo + step }
            return (lo...hi, step)

        case .symmetric(let minMagnitude):
            let largest = finite.map(abs).max() ?? 0
            let magnitude = max(abs(minMagnitude), largest * 1.08, .ulpOfOne)
            let step = ChartTicks.step(span: magnitude * 2, count: count, candidates: steps)
            let edge = (magnitude / step).rounded(.up) * step
            return (-edge...edge, step)
        }
    }
}

/// Round tick values for a value axis. Pure.
public enum ChartTicks {

    /// The smallest "nice" step (1, 2, 2.5 or 5 times a power of ten, or one of `candidates`) that splits
    /// `span` into at most `count` intervals. Below 1 the 2.5 multiple is skipped: 0.25 needs one more
    /// decimal than the axis format usually prints, and 0.3 under a tick at 0.25 would be a wrong label.
    public static func step(span: Double, count: Int, candidates: [Double]? = nil) -> Double {
        let raw = abs(span) / Double(max(1, count))
        guard raw.isFinite, raw > 0 else { return 1 }
        if let candidates, let pick = candidates.sorted().first(where: { $0 >= raw }) { return pick }
        if let candidates, let largest = candidates.max(), largest > 0 {
            return largest * (raw / largest).rounded(.up)
        }
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        let multiples: [Double] = magnitude >= 1 ? [1, 2, 2.5, 5, 10] : [1, 2, 5, 10]
        for multiple in multiples where multiple * magnitude >= raw * (1 - 1e-9) {
            return multiple * magnitude
        }
        return 10 * magnitude
    }

    /// Multiples of `step` inside `domain`, rounded to the step so 0.1 + 0.2 never prints as 0.30000004,
    /// and with no negative zero (which prints as "-0").
    public static func values(in domain: ClosedRange<Double>, step: Double) -> [Double] {
        guard step > 0, step.isFinite else { return [domain.lowerBound, domain.upperBound] }
        let first = (domain.lowerBound / step - 1e-9).rounded(.up)
        let last = (domain.upperBound / step + 1e-9).rounded(.down)
        guard first <= last, last - first < 1000 else { return [domain.lowerBound, domain.upperBound] }
        return stride(from: first, through: last, by: 1).map { index in
            let value = (index * step * 1e9).rounded() / 1e9
            return value == 0 ? 0 : value
        }
    }

    /// Ticks for an arbitrary (fixed) domain: the first nice step at or above `span / count` that lands on
    /// both ends, so 50...100 reads 50/75/100 rather than 60/80/100 with an unlabelled floor.
    public static func nice(in domain: ClosedRange<Double>, count: Int = 4, candidates: [Double]? = nil) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [domain.lowerBound] }
        let first = step(span: span, count: count, candidates: candidates)
        var trial = first
        for _ in 0..<4 {
            if isMultiple(domain.lowerBound, of: trial) && isMultiple(domain.upperBound, of: trial) {
                return values(in: domain, step: trial)
            }
            trial = step(span: trial * Double(max(1, count)) * 1.0001, count: count, candidates: candidates)
            if trial <= 0 { break }
        }
        return values(in: domain, step: first)
    }

    private static func isMultiple(_ value: Double, of step: Double) -> Bool {
        let ratio = value / step
        return abs(ratio - ratio.rounded()) < 1e-6
    }
}

/// The value axis of a chart: unit, domain, ticks and how a tick prints.
public struct ChartValueAxis: Sendable {
    /// Drawn above the axis ("ms", "bpm", "%", "°C", "h"), in the displayed unit system. Nil draws none.
    public var unit: String?
    public var domain: ChartDomain
    /// Roughly how many intervals the axis is split into when `ticks` is nil.
    public var tickCount: Int
    /// Explicit tick values; nil picks round ones.
    public var ticks: [Double]?
    /// Allowed tick steps, for axes whose round numbers are not base ten (minutes shown as hours).
    public var stepCandidates: [Double]?
    /// Tick label text, without the unit. Tabular digits come from the axis font.
    public var format: @Sendable (Double) -> String

    public init(unit: String?, domain: ChartDomain, tickCount: Int = 4, ticks: [Double]? = nil,
                stepCandidates: [Double]? = nil,
                format: @escaping @Sendable (Double) -> String = ChartValueAxis.integer) {
        self.unit = unit
        self.domain = domain
        self.tickCount = tickCount
        self.ticks = ticks
        self.stepCandidates = stepCandidates
        self.format = format
    }

    /// Whole numbers, grouped ("10,000").
    public static let integer: @Sendable (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0))) }

    /// A fixed number of decimals.
    public static func decimals(_ places: Int) -> @Sendable (Double) -> String {
        { $0.formatted(.number.precision(.fractionLength(max(0, places)))) }
    }

    /// Minutes printed as hours ("7" for 420), for duration axes whose unit is "h".
    public static let hoursFromMinutes: @Sendable (Double) -> String = { minutes in
        let hours = minutes / 60
        return hours == hours.rounded()
            ? hours.formatted(.number.precision(.fractionLength(0)))
            : hours.formatted(.number.precision(.fractionLength(1)))
    }

    /// A duration axis for values in MINUTES (asleep time, time in bed, stage minutes): ticks on whole
    /// hours, labelled in hours under an "h" unit. Bars always include zero.
    public static func durationMinutes(unit: String = "h", minSpanMinutes: Double = 120,
                                       includeZero: Bool = true) -> ChartValueAxis {
        ChartValueAxis(unit: unit,
                       domain: .fitted(minSpan: minSpanMinutes, includeZero: includeZero, headroom: 0.05),
                       stepCandidates: [30, 60, 120, 180, 240, 360, 480, 720],
                       format: hoursFromMinutes)
    }

    /// The resolved axis for `values`: domain, tick values and their labels. Labels never repeat: when the
    /// format would print two ticks the same (0.25 steps under a whole-number format), the labels get the
    /// decimals the step needs.
    public func layout(for values: [Double]) -> ChartYAxisLayout {
        let resolved = domain.resolved(values, tickCount: tickCount, steps: stepCandidates)
        let tickValues: [Double]
        if let ticks {
            tickValues = ticks.filter { $0 >= resolved.domain.lowerBound - 1e-9 && $0 <= resolved.domain.upperBound + 1e-9 }
        } else if let step = resolved.step {
            tickValues = ChartTicks.values(in: resolved.domain, step: step)
        } else {
            tickValues = ChartTicks.nice(in: resolved.domain, count: tickCount, candidates: stepCandidates)
        }
        return ChartYAxisLayout(domain: resolved.domain, ticks: tickValues,
                                labels: Self.distinctLabels(tickValues, format: format), unit: unit)
    }

    /// The resolved axis for a domain the caller has already settled.
    public func layout(domain fixedDomain: ClosedRange<Double>) -> ChartYAxisLayout {
        ChartValueAxis(unit: unit, domain: .fixed(fixedDomain), tickCount: tickCount, ticks: ticks,
                       stepCandidates: stepCandidates, format: format).layout(for: [])
    }

    static func distinctLabels(_ ticks: [Double], format: (Double) -> String) -> [String] {
        let labels = ticks.map(format)
        guard Set(labels).count != labels.count, ticks.count > 1 else { return labels }
        let step = zip(ticks.dropFirst(), ticks).map { abs($0 - $1) }.filter { $0 > 0 }.min() ?? 1
        // The decimals that print the step exactly (2 for 0.25), so a label never rounds to a neighbour's.
        let places = (1...6).first { places in
            let scaled = step * pow(10, Double(places))
            return abs(scaled - scaled.rounded()) < 1e-6
        } ?? 6
        return ticks.map { $0.formatted(.number.precision(.fractionLength(places))) }
    }
}

/// A value axis resolved for one chart: what the axis draws and where.
public struct ChartYAxisLayout: Equatable, Sendable {
    public var domain: ClosedRange<Double>
    public var ticks: [Double]
    public var labels: [String]
    public var unit: String?

    public init(domain: ClosedRange<Double>, ticks: [Double], labels: [String], unit: String?) {
        self.domain = domain
        self.ticks = ticks
        self.labels = labels
        self.unit = unit
    }

    /// The label printed at `tick`, or nil for a value the axis does not mark.
    public func label(for tick: Double) -> String? {
        guard let index = ticks.firstIndex(where: { abs($0 - tick) <= 1e-9 * max(1, abs(tick)) }),
              index < labels.count else { return nil }
        return labels[index]
    }
}

// MARK: References, bands, legend, state

/// A labelled horizontal reference: baseline, 95 % oxygen, 85 % efficiency, a goal, sleep need.
public struct ChartReference: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case dashed, solid }
    public var value: Double
    /// Drawn at the trailing edge ("Baseline 61", "95 %", "Goal 10,000"). Nil draws the rule alone.
    public var label: String?
    public var style: Style

    public init(_ value: Double, label: String? = nil, style: Style = .dashed) {
        self.value = value
        self.label = label
        self.style = style
    }
}

/// Score bands for colouring bars, built by the APP from the scorer's own thresholds (for example
/// `RecoveryScorer.bandRedMax` / `bandYellowMax`, or `StressBand`). The kit never defines a band set of its
/// own, so a chart cannot drift from the score it draws.
public struct ScoreBands: Sendable {
    public struct Band: Sendable {
        /// Exclusive upper bound: a value belongs to the first band whose bound is greater than it, the
        /// same `score < bound` comparison `RecoveryScorer.band` and `StressBand` use.
        public var upperBound: Double
        public var color: Color
        public var name: String
        public init(upperBound: Double, color: Color, name: String) {
            self.upperBound = upperBound
            self.color = color
            self.name = name
        }
    }

    /// Ascending by `upperBound`.
    public var bands: [Band]

    public init(_ bands: [Band]) {
        self.bands = bands.sorted { $0.upperBound < $1.upperBound }
    }

    /// The band `value` falls in. A value at or above every bound belongs to the last band; with no bands
    /// at all the result is a neutral placeholder rather than a crash.
    public func band(for value: Double) -> Band {
        if let match = bands.first(where: { value < $0.upperBound }) { return match }
        return bands.last ?? Band(upperBound: .infinity, color: StrandPalette.textSecondary, name: "")
    }
}

/// One row in a chart legend.
public struct ChartLegendItem: Identifiable, Sendable {
    public enum Mark: Sendable {
        case swatch(Color)
        case line(Color, dashed: Bool)
        case point(Color)
        case band(Color)
        case estimate(Color)
        case hatched(Color)
    }
    public var id: String { label }
    public var mark: Mark
    public var label: String

    public init(_ mark: Mark, _ label: String) {
        self.mark = mark
        self.label = label
    }
}

/// Loading, empty or ready, for every chart frame. A frame never changes height between states, so a page
/// does not move when its data arrives.
public enum ChartState: Equatable, Sendable {
    case loading
    /// Loading finished and there is nothing to draw; the text is one short line ("No readings yet").
    case empty(String)
    case ready
}

/// How the x-axis labels a window. `ChartRange.axisStyle` picks one per range; the axis falls back to a
/// finer or coarser style when the window is too short or too long for it (see `ChartAxis.layout`).
public enum ChartAxisStyle: Equatable, Sendable {
    /// "Mon", for a week.
    case weekday
    /// "12", with the month on the first mark of each month ("Sep 12").
    case dayOfMonth
    /// "Sep".
    case month
    /// "Sep 2025" on the first mark of each year, "Dec" otherwise; whole years ("2024") on very long spans.
    case monthYear
    /// Clock time ("6 AM"), from `chartTimeTicks`.
    case hours
}
