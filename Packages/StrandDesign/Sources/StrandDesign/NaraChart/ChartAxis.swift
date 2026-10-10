#if !os(watchOS)
// Swift Charts axes; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - X-axis layout (pure)

/// Where a label sits against its mark. The first and last labels of an axis are pulled inside the plot
/// when their mark is close to an edge, so a centred label never hangs off the card ("Oct 7" cut to "(").
public enum ChartAxisLabelAnchor: Equatable, Sendable {
    case leading, center, trailing
}

/// A resolved x-axis: the window it spans, the labelled marks, their text and anchors, and the grid lines.
/// Built once per chart in `init` by `ChartAxis.layout`, then drawn by `naraChartAxes`.
public struct ChartXAxisLayout: Equatable, Sendable {
    /// The x domain.
    public var window: ClosedRange<Date>
    /// The style the labels were finally drawn in, after adapting to the window.
    public var style: ChartAxisStyle
    /// Label positions: the middle of each labelled day, the start of each labelled month's visible part
    /// (or the window's end for a newest month too narrow for its name), or round clock times.
    public var marks: [Date]
    public var labels: [String]
    public var anchors: [ChartAxisLabelAnchor]
    /// Grid lines: the labelled days, month boundaries for month styles, the clock ticks for hours.
    public var grid: [Date]

    public init(window: ClosedRange<Date>, style: ChartAxisStyle, marks: [Date], labels: [String],
                anchors: [ChartAxisLabelAnchor], grid: [Date]) {
        self.window = window
        self.style = style
        self.marks = marks
        self.labels = labels
        self.anchors = anchors
        self.grid = grid
    }

    func entry(for mark: Date) -> (label: String, anchor: ChartAxisLabelAnchor)? {
        guard let index = marks.firstIndex(of: mark), index < labels.count, index < anchors.count else { return nil }
        return (labels[index], anchors[index])
    }
}

/// The x window, marks and labels for every kit chart. Pure: everything is a function of the window, the
/// style and the calendar (whose time zone and locale decide where days start and how they print).
public enum ChartAxis {

    /// The fixed window for a range ending today, so missing days at the start read as gaps rather than the
    /// axis shrinking to the data: W is the 7 local days ending with today, M 30, and so on, from the local
    /// start of the first day to the local end of today. `.all` runs from the first data day and is never
    /// shorter than a week, so one reading does not become one bar the width of the card.
    public static func window(_ range: ChartRange, now: Date = Date(), firstDataDay: Date?,
                              calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
        let days: Int
        if let fixed = range.days {
            days = fixed
        } else {
            let first = firstDataDay.map { calendar.startOfDay(for: min($0, now)) } ?? today.start
            days = max(7, ChartDay.daysBetween(first, today.start, calendar: calendar) + 1)
        }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today.start)
            .map { calendar.startOfDay(for: $0) } ?? today.start
        return start...today.end
    }

    /// `window` widened to whole `unit`s (week, month), for bars that aggregate to that unit: the oldest
    /// bin starts at its own start and the current one runs to its own end, so neither bar is cut in half.
    public static func snap(_ window: ClosedRange<Date>, to unit: Calendar.Component,
                            calendar: Calendar = .current) -> ClosedRange<Date> {
        let lower = calendar.dateInterval(of: unit, for: window.lowerBound)?.start ?? window.lowerBound
        let upper = calendar.dateInterval(of: unit, for: window.upperBound.addingTimeInterval(-1))?.end
            ?? window.upperBound
        return lower...max(upper, lower)
    }

    /// The style an axis actually draws for `window`. A requested style is kept while the window suits it;
    /// otherwise the span decides: up to 7 days by weekday, up to 62 by day of month, up to 400 by month,
    /// longer by month and year.
    public static func effectiveStyle(_ style: ChartAxisStyle, window: ClosedRange<Date>,
                                      calendar: Calendar = .current) -> ChartAxisStyle {
        if style == .hours { return .hours }
        let days = dayCount(window, calendar: calendar)
        let suits: Bool
        switch style {
        case .weekday: suits = days <= 7
        case .dayOfMonth: suits = days >= 2 && days <= 92
        case .month: suits = days >= 32 && days <= 400
        case .monthYear: suits = days >= 32
        case .hours: suits = true
        }
        if suits { return style }
        if days <= 7 { return .weekday }
        if days <= 62 { return .dayOfMonth }
        if days <= 400 { return .month }
        return .monthYear
    }

    /// How many labels a style aims for on a phone-width plot.
    public static func defaultTarget(for style: ChartAxisStyle) -> Int {
        switch style {
        case .weekday: return 7
        case .dayOfMonth: return 5
        case .month: return 7
        case .monthYear: return 4
        case .hours: return 6
        }
    }

    /// The labelled marks for `window` (see `layout`).
    public static func marks(_ window: ClosedRange<Date>, style: ChartAxisStyle, target: Int? = nil,
                             calendar: Calendar = .current) -> [Date] {
        layout(window, style: style, target: target, calendar: calendar).marks
    }

    /// The whole x-axis for `window`: marks that are distinct and day-, month- or clock-aligned, with the
    /// newest day (or month) always labelled, and labels that never repeat.
    ///
    /// Day styles reuse `ChartAxisDays.spanning`, which walks back from the newest day so it is always
    /// present, and put each mark in the MIDDLE of its day, where a bar or point plotted with `unit: .day`
    /// sits. Month styles start each label on its month's boundary, where the grid line is, and read across
    /// the month; a newest month too narrow for its name is labelled right-aligned at the window's end.
    /// Hours step like `chartTimeTicks` (6, 3, 2 or 1 hours, or 15 minutes, by span) but on wall-clock
    /// times (`wallClockTicks`), so the 23- and 25-hour days of a clock change still read 12 AM, 6 AM, 12 PM.
    ///
    /// Swift Charts keeps x labels inside the plot and truncates one that does not fit ("Oct 2025" became
    /// "O…"), so a label whose mark is near an edge is anchored on that edge instead of centred, and a
    /// label that would overlap its neighbour is dropped (never the newest).
    ///
    /// If a style would still print a label twice (two Octobers in a year-long window, two midnights in a
    /// 30-hour one), it moves to the next coarser style, or adds the year or weekday, until none repeat.
    public static func layout(_ window: ClosedRange<Date>, style: ChartAxisStyle, target: Int? = nil,
                              calendar: Calendar = .current) -> ChartXAxisLayout {
        var current = effectiveStyle(style, window: window, calendar: calendar)
        var built = build(window, style: current, target: target, calendar: calendar)
        var attempts = 0
        while Set(built.labels).count != built.labels.count, attempts < 4 {
            attempts += 1
            switch current {
            case .weekday: current = .dayOfMonth
            case .dayOfMonth: current = .month
            case .month: current = .monthYear
            case .monthYear, .hours: attempts = 4
            }
            if attempts < 4 { built = build(window, style: current, target: target, calendar: calendar) }
        }
        return ChartXAxisLayout(window: window, style: current, marks: built.marks, labels: built.labels,
                                anchors: built.anchors, grid: built.grid)
    }

    /// Labels for marks in a style, applying the first-of-month / first-of-year rules.
    public static func labels(for marks: [Date], style: ChartAxisStyle, calendar: Calendar = .current) -> [String] {
        switch style {
        case .weekday:
            return marks.map { format($0, .dateTime.weekday(.abbreviated), calendar) }
        case .dayOfMonth:
            return marks.indices.map { i in
                let newMonth = i == 0 || calendar.component(.month, from: marks[i]) != calendar.component(.month, from: marks[i - 1])
                return newMonth
                    ? format(marks[i], .dateTime.month(.abbreviated).day(), calendar)
                    : format(marks[i], .dateTime.day(), calendar)
            }
        case .month:
            return marks.map { format($0, .dateTime.month(.abbreviated), calendar) }
        case .monthYear:
            let firstOfYear = marks.indices.map { i in
                i == 0 || calendar.component(.year, from: marks[i]) != calendar.component(.year, from: marks[i - 1])
            }
            let mixed = marks.indices.map { i in
                firstOfYear[i]
                    ? format(marks[i], .dateTime.month(.abbreviated).year(), calendar)
                    : format(marks[i], .dateTime.month(.abbreviated), calendar)
            }
            if Set(mixed).count == mixed.count { return mixed }
            return marks.map { format($0, .dateTime.month(.abbreviated).year(), calendar) }
        case .hours:
            let showsMinutes = marks.contains { calendar.component(.minute, from: $0) != 0 }
            let plain = marks.map {
                showsMinutes ? format($0, .dateTime.hour().minute(), calendar) : format($0, .dateTime.hour(), calendar)
            }
            if Set(plain).count == plain.count { return plain }
            // Over more than a day: midnights carry the weekday instead of "12 AM", and any other time that
            // still occurs twice carries its weekday too ("Tue 6 PM", "Wed 6 PM").
            let counts = Dictionary(plain.map { ($0, 1) }, uniquingKeysWith: +)
            let dated = marks.indices.map { i -> String in
                let parts = calendar.dateComponents([.hour, .minute], from: marks[i])
                if parts.hour == 0 && parts.minute == 0 { return format(marks[i], .dateTime.weekday(.abbreviated), calendar) }
                if counts[plain[i], default: 0] > 1 {
                    return showsMinutes
                        ? format(marks[i], .dateTime.weekday(.abbreviated).hour().minute(), calendar)
                        : format(marks[i], .dateTime.weekday(.abbreviated).hour(), calendar)
                }
                return plain[i]
            }
            if Set(dated).count == dated.count { return dated }
            return marks.map { format($0, .dateTime.weekday(.abbreviated).day().hour().minute(), calendar) }
        }
    }

    // MARK: Internals

    /// Calendar days the window covers (a window from a day's start to the next day's start is one day).
    static func dayCount(_ window: ClosedRange<Date>, calendar: Calendar) -> Int {
        let last = window.upperBound > window.lowerBound ? window.upperBound.addingTimeInterval(-1) : window.lowerBound
        return ChartDay.daysBetween(window.lowerBound, last, calendar: calendar) + 1
    }

    /// The plot width the edge rules assume (a phone card). A wider plot only makes them cautious.
    static let assumedPlotWidth: Double = 300

    /// A label's approximate width in points: the footnote axis font averages about 6.5 pt a character.
    static func estimatedWidth(_ label: String) -> Double { Double(label.count) * 6.5 + 4 }

    /// How a label centred on `mark` would fit: anchored leading when its left half would cross the plot's
    /// leading edge, trailing when its right half would cross the trailing edge, centred otherwise.
    static func anchor(for mark: Date, label: String, in window: ClosedRange<Date>) -> ChartAxisLabelAnchor {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        guard span > 0 else { return .center }
        let fraction = mark.timeIntervalSince(window.lowerBound) / span
        let half = estimatedWidth(label) / 2 / assumedPlotWidth
        if fraction < half { return .leading }
        if fraction > 1 - half { return .trailing }
        return .center
    }

    /// The labels left once any that would overlap the next one are dropped, walking back from the newest
    /// (which always stays). Extents are fractions of the window, from the estimated widths.
    static func droppingOverlaps(_ marks: [Date], labels: [String], anchors: [ChartAxisLabelAnchor],
                                 in window: ClosedRange<Date>) -> [Int] {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        guard span > 0, marks.count > 1 else { return Array(marks.indices) }
        func extent(_ i: Int) -> ClosedRange<Double> {
            let at = marks[i].timeIntervalSince(window.lowerBound) / span
            let width = estimatedWidth(labels[i]) / assumedPlotWidth
            switch anchors[i] {
            case .leading: return at...(at + width)
            case .trailing: return (at - width)...at
            case .center: return (at - width / 2)...(at + width / 2)
            }
        }
        let gap = 6 / assumedPlotWidth
        var kept = [marks.count - 1]
        for i in stride(from: marks.count - 2, through: 0, by: -1) where extent(i).upperBound + gap <= extent(kept[0]).lowerBound {
            kept.insert(i, at: 0)
        }
        return kept
    }

    private static func build(_ window: ClosedRange<Date>, style: ChartAxisStyle, target: Int?,
                              calendar: Calendar)
        -> (marks: [Date], labels: [String], anchors: [ChartAxisLabelAnchor], grid: [Date]) {
        let goal = max(1, target ?? defaultTarget(for: style))
        switch style {
        case .weekday, .dayOfMonth:
            let first = calendar.startOfDay(for: window.lowerBound)
            let last = calendar.startOfDay(for: window.upperBound > window.lowerBound
                                            ? window.upperBound.addingTimeInterval(-1) : window.lowerBound)
            var marks = ChartAxisDays.spanning([first, last], targetLabels: goal, calendar: calendar)
                .map { ChartDay.center(of: $0, calendar: calendar) }
                .filter { window.contains($0) }
            var text = labels(for: marks, style: style, calendar: calendar)
            let kept = droppingOverlaps(marks, labels: text,
                                        anchors: zip(marks, text).map { anchor(for: $0, label: $1, in: window) }, in: window)
            if kept.count != marks.count {
                marks = kept.map { marks[$0] }
                text = labels(for: marks, style: style, calendar: calendar)
            }
            return (marks, text, zip(marks, text).map { anchor(for: $0, label: $1, in: window) }, marks)

        case .month, .monthYear:
            let years = style == .monthYear && dayCount(window, calendar: calendar) > 1096
            let unit: Calendar.Component = years ? .year : .month
            let portions = visiblePortions(of: unit, in: window, calendar: calendar)
            let step = max(1, Int((Double(portions.count) / Double(goal)).rounded(.up)))
            var picked: [(start: Date, end: Date)] = []
            var index = portions.count - 1
            while index >= 0 {
                picked.append(portions[index])
                index -= step
            }
            picked.reverse()
            func names(_ portions: [(start: Date, end: Date)]) -> [String] {
                years ? portions.map { format($0.start, .dateTime.year(), calendar) }
                      : labels(for: portions.map(\.start), style: style, calendar: calendar)
            }
            func place(_ portions: [(start: Date, end: Date)], _ text: [String]) -> ([Date], [ChartAxisLabelAnchor]) {
                var marks = portions.map(\.start)
                var anchors = Array(repeating: ChartAxisLabelAnchor.leading, count: portions.count)
                let span = window.upperBound.timeIntervalSince(window.lowerBound)
                if let last = portions.last, let name = text.last, span > 0,
                   last.end.timeIntervalSince(last.start) / span < estimatedWidth(name) / assumedPlotWidth {
                    marks[marks.count - 1] = window.upperBound.addingTimeInterval(-1)
                    anchors[anchors.count - 1] = .trailing
                }
                return (marks, anchors)
            }
            var text = names(picked)
            var (marks, anchors) = place(picked, text)
            let kept = droppingOverlaps(marks, labels: text, anchors: anchors, in: window)
            if kept.count != picked.count {
                picked = kept.map { picked[$0] }
                text = names(picked)
                (marks, anchors) = place(picked, text)
            }
            return (marks, text, anchors, boundaries(of: unit, in: window, calendar: calendar))

        case .hours:
            var ticks = wallClockTicks(start: window.lowerBound, end: window.upperBound, calendar: calendar)
            // A full day ends on the clock time it started at (midnight to midnight): that closing mark would
            // repeat the first label on the trailing edge, so it goes, before thinning counts it.
            if ticks.count > 1, let first = ticks.first, let last = ticks.last, last >= window.upperBound,
               format(last, .dateTime.hour().minute(), calendar) == format(first, .dateTime.hour().minute(), calendar) {
                ticks.removeLast()
            }
            if ticks.count > goal {
                let step = Int((Double(ticks.count) / Double(goal)).rounded(.up))
                ticks = ticks.enumerated().filter { $0.offset % step == 0 }.map(\.element)
            }
            // Every tick keeps its grid line; a label that would overlap its neighbour goes, as on the other
            // styles (a short window, like an event's 90 minutes, steps every 15 minutes).
            let grid = ticks
            var text = labels(for: ticks, style: .hours, calendar: calendar)
            let kept = droppingOverlaps(ticks, labels: text,
                                        anchors: zip(ticks, text).map { anchor(for: $0, label: $1, in: window) }, in: window)
            if kept.count != ticks.count {
                ticks = kept.map { ticks[$0] }
                text = labels(for: ticks, style: .hours, calendar: calendar)
            }
            return (ticks, text, zip(ticks, text).map { anchor(for: $0, label: $1, in: window) }, grid)
        }
    }

    /// Clock ticks from `start` to `end` (both included): the step `chartTimeTicks` picks for the span (6 h
    /// above 20 h, 3 h above 10 h, 2 h above 5 h, 1 h above 2 h, else 15 min), placed on the WALL-CLOCK
    /// multiples of that step on each local day, so a clock change does not shift every later tick off
    /// its round hour. A time the clock skips that day does not exist and gets no tick. Pure.
    static func wallClockTicks(start: Date, end: Date, calendar: Calendar) -> [Date] {
        guard end > start else { return [] }
        let span = end.timeIntervalSince(start) / 60
        let step: Int
        switch span {
        case (20 * 60)...: step = 360
        case (10 * 60)...: step = 180
        case (5 * 60)...: step = 120
        case (2 * 60)...: step = 60
        default: step = 15
        }
        var ticks: [Date] = []
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        var guardDays = 0
        while day <= lastDay, guardDays < 64 {
            guardDays += 1
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            for minute in stride(from: 0, to: 24 * 60, by: step) {
                var wanted = parts
                wanted.hour = minute / 60
                wanted.minute = minute % 60
                wanted.second = 0
                guard let tick = calendar.date(from: wanted) else { continue }
                if tick > end { break }
                guard tick >= start else { continue }
                let back = calendar.dateComponents([.day, .hour, .minute], from: tick)
                guard back.day == parts.day, back.hour == minute / 60, back.minute == minute % 60 else { continue }
                if let last = ticks.last, tick <= last { continue }
                ticks.append(tick)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return ticks
    }

    /// The part of each calendar `unit` inside the window, oldest first. The oldest part is dropped when it
    /// is a sliver (under a quarter of a unit) and is not the only one, so its label does not crowd the next.
    private static func visiblePortions(of unit: Calendar.Component, in window: ClosedRange<Date>,
                                        calendar: Calendar) -> [(start: Date, end: Date)] {
        var portions: [(start: Date, end: Date)] = []
        var cursor = calendar.dateInterval(of: unit, for: window.lowerBound)
        var guardSteps = 0
        while let interval = cursor, interval.start < window.upperBound, guardSteps < 600 {
            guardSteps += 1
            let lo = max(interval.start, window.lowerBound)
            let hi = min(interval.end, window.upperBound)
            if hi > lo { portions.append((lo, hi)) }
            cursor = calendar.dateInterval(of: unit, for: interval.end)
        }
        let typical: TimeInterval = unit == .year ? 365.25 * 86_400 : 30.44 * 86_400
        if portions.count > 1, portions[0].end.timeIntervalSince(portions[0].start) < typical / 4 { portions.removeFirst() }
        return portions
    }

    /// Starts of `unit` strictly inside the window.
    private static func boundaries(of unit: Calendar.Component, in window: ClosedRange<Date>,
                                   calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var cursor = calendar.dateInterval(of: unit, for: window.lowerBound)?.end
        var guardSteps = 0
        while let start = cursor, start < window.upperBound, guardSteps < 600 {
            guardSteps += 1
            out.append(start)
            cursor = calendar.dateInterval(of: unit, for: start)?.end
        }
        return out
    }

    static func format(_ date: Date, _ style: Date.FormatStyle, _ calendar: Calendar) -> String {
        var style = style
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style.locale(calendar.locale ?? .autoupdatingCurrent))
    }
}

// MARK: - The house axes

public extension View {
    /// The house axes for a Swift Charts chart: a leading value axis with its unit on top, footnote tabular
    /// tick labels in `textTertiary`, a faint hairline grid, and x labels from a `ChartXAxisLayout` with the
    /// edge labels pulled inside the plot. Also sets the chart's calendar, so `unit: .day` bins and the axis
    /// agree about where a day starts.
    func naraChartAxes(x: ChartXAxisLayout, y: ChartYAxisLayout, calendar: Calendar = .current) -> some View {
        modifier(NaraChartAxesModifier(x: x, y: y, calendar: calendar))
    }

    /// The house axes, resolved on the spot from a window and a value axis. Charts built in the kit resolve
    /// their layouts once in `init` and use the overload above.
    func naraChartAxes(x window: ClosedRange<Date>, style: ChartAxisStyle, y: ChartValueAxis,
                       yDomain: ClosedRange<Double>, calendar: Calendar = .current) -> some View {
        naraChartAxes(x: ChartAxis.layout(window, style: style, calendar: calendar),
                      y: y.layout(domain: yDomain), calendar: calendar)
    }
}

struct NaraChartAxesModifier: ViewModifier {
    let x: ChartXAxisLayout
    let y: ChartYAxisLayout
    let calendar: Calendar
    @Environment(\.naraChartCompact) private var compact

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: x.window)
            .chartYScale(domain: y.domain, range: .plotDimension(startPadding: 0, endPadding: NaraChartStyle.plotTopPadding))
            .chartXAxis {
                AxisMarks(values: x.grid) { _ in
                    AxisGridLine(stroke: NaraChartStyle.grid).foregroundStyle(NaraChartStyle.gridColor)
                }
                AxisMarks(values: x.marks) { value in
                    if let date = value.as(Date.self), let entry = x.entry(for: date) {
                        AxisValueLabel(anchor: entry.anchor.unitPoint) {
                            Text(entry.label)
                                .font(NaraChartStyle.axisFont)
                                .foregroundStyle(NaraChartStyle.axisColor)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: y.ticks) { value in
                    AxisGridLine(stroke: NaraChartStyle.grid).foregroundStyle(NaraChartStyle.gridColor)
                    if !compact, let tick = value.as(Double.self), let label = y.label(for: tick) {
                        AxisValueLabel {
                            Text(label)
                                .font(NaraChartStyle.axisFont)
                                .foregroundStyle(NaraChartStyle.axisColor)
                        }
                    }
                }
            }
            .modifier(NaraChartUnitLabel(unit: compact ? nil : y.unit))
            .environment(\.calendar, calendar)
    }
}

/// The value axis's unit above the axis, when there is one.
private struct NaraChartUnitLabel: ViewModifier {
    let unit: String?
    func body(content: Content) -> some View {
        if let unit, !unit.isEmpty {
            content.chartYAxisLabel(position: .top, alignment: .leading, spacing: 4) {
                Text(unit)
                    .font(NaraChartStyle.unitFont)
                    .foregroundStyle(NaraChartStyle.axisColor)
            }
        } else {
            content
        }
    }
}

extension ChartAxisLabelAnchor {
    var unitPoint: UnitPoint {
        switch self {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
}
#endif
