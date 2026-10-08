#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - RangeBarChart

/// A floating bar per night from start to end on a clock axis: bedtime to wake (sleep consistency, time in
/// bed). Evening is at the top and morning at the bottom, the way a night is read.
///
/// The clock is anchored at `anchorHour` (18:00) of the evening before each wake day, so a night that
/// crosses midnight is one continuous bar instead of two pieces at the top and bottom of a 0-24 axis.
/// Positions are WALL-CLOCK hours after the anchor, not elapsed time: on the night the clocks change, 23:00
/// still sits on the 11 PM line and 07:00 on the 7 AM line, so bedtimes line up night after night, which is
/// what the chart is for.
///
/// Long ranges bin to the mean bedtime and wake of each week or month (`bin: range.totalsBin`). An estimated
/// night is a light bar with solid ends, and the legend says "Estimate". `RangeBarChart.bin` returns the bars
/// as drawn (clock offsets), so the readout above the chart (`ReadoutContent.range(selection:in:bin:)`) shows
/// the same means. Pass one item per sleep (the main sleep for a schedule); two on one wake day are two bars
/// in the same column on daily bars, and both count towards a binned mean.
///
/// The clock axis widens to every bar and usual window, also one before the 18:00 anchor (an early evening
/// bedtime), so nothing is drawn outside the plot.
///
/// ```swift
/// RangeBarChart(items: nights.map { .init(day: $0.wakeDay, start: $0.bedtime, end: $0.wake) },
///               color: StrandPalette.restColor, window: window, xStyle: range.axisStyle,
///               selection: $selected, accessibilityTitle: "Sleep schedule")
/// ```
public struct RangeBarChart: View {

    /// One night (or span). `day` is the local start of the wake day it belongs to.
    public struct Item: Identifiable, Sendable {
        public var day: Date
        public var start: Date
        public var end: Date
        public var isEstimate: Bool
        public var id: Date { day }

        public init(day: Date, start: Date, end: Date, isEstimate: Bool = false) {
            self.day = day
            self.start = start
            self.end = end
            self.isEstimate = isEstimate
        }
    }

    /// One bar as the chart draws it: a night, or a week's or month's mean night, as wall-clock hours after
    /// the anchor (`clockOffset`: with the 18:00 anchor, 5 is 11 PM and 13 is 7 AM on the wake day).
    public struct Span: Identifiable, Equatable, Sendable {
        /// The local start of the wake day, or of the week or month for a binned bar.
        public var day: Date
        public var start: Double
        public var end: Double
        public var isEstimate: Bool
        public var id: String { "\(day.timeIntervalSince1970)|\(start)" }

        public init(day: Date, start: Double, end: Double, isEstimate: Bool = false) {
            self.day = day
            self.start = start
            self.end = end
            self.isEstimate = isEstimate
        }
    }

    struct Bar: Identifiable {
        let id: Int
        let day: Date
        /// Negated clock offsets: `top` is the (earlier) start, `bottom` the end.
        let top: Double
        let bottom: Double
        let isEstimate: Bool
    }

    private let bars: [Bar]
    private let bin: Calendar.Component
    private let anchorHour: Int
    private let capHeight: Double
    private let bands: [ClosedRange<Double>]
    private let color: Color
    private let xLayout: ChartXAxisLayout
    private let yLayout: ChartYAxisLayout
    private let xs: [Date]
    private let state: ChartState
    private let height: CGFloat
    private let legend: [ChartLegendItem]
    private let accessibilityTitle: String
    private let summary: String
    private let descriptor: NaraChartDescriptor
    private let calendar: Calendar
    @Binding private var selection: Date?

    /// - Parameters:
    ///   - anchorHour: the top of the clock, in hours (18 = 6 PM the evening before the wake day).
    ///   - typicalStart / typicalEnd: the usual bedtime and wake windows, drawn as bands across the chart.
    ///     Only their time of day is used.
    ///   - bin: `.day`, `.weekOfYear` or `.month`: each bar runs from the bin's mean start to its mean end.
    public init(items: [Item], anchorHour: Int = 18,
                typicalStart: ClosedRange<Date>? = nil, typicalEnd: ClosedRange<Date>? = nil,
                color: Color, bin: Calendar.Component = .day, legend: [ChartLegendItem]? = nil,
                state: ChartState = .ready,
                window: ClosedRange<Date>, xStyle: ChartAxisStyle, selection: Binding<Date?>,
                height: CGFloat = NoopMetrics.chartHeightPrimary, accessibilityTitle: String,
                calendar: Calendar = .current) {
        let window = bin == .day ? window : ChartAxis.snap(window, to: bin, calendar: calendar)
        let offsets = Self.bin(items, by: bin, anchorHour: anchorHour, calendar: calendar)
            .filter { $0.day >= window.lowerBound && $0.day < window.upperBound }
        var bands: [ClosedRange<Double>] = []
        // Each usual window sits next to the bars it describes (bedtimes, wakes), even when it crosses the
        // anchor, so a 17:30-18:30 bedtime window is drawn at the top rather than near the wake band.
        let count = Double(offsets.count)
        let meanStart: Double? = offsets.isEmpty ? nil : offsets.reduce(0.0) { $0 + $1.start } / count
        let meanEnd: Double? = offsets.isEmpty ? nil : offsets.reduce(0.0) { $0 + $1.end } / count
        if let typicalStart {
            bands.append(Self.typicalBand(typicalStart, near: meanStart, anchorHour: anchorHour, calendar: calendar))
        }
        if let typicalEnd {
            bands.append(Self.typicalBand(typicalEnd, near: meanEnd, anchorHour: anchorHour, calendar: calendar))
        }
        let earliest = (offsets.map(\.start) + bands.map(\.lowerBound)).min() ?? 4
        let latest = (offsets.map(\.end) + bands.map(\.upperBound)).max() ?? 14
        let layout = Self.clockAxis(earliest: earliest, latest: latest, anchorHour: anchorHour, calendar: calendar)

        self.bars = offsets.enumerated().map { index, span in
            Bar(id: index, day: span.day, top: -span.start, bottom: -span.end, isEstimate: span.isEstimate)
        }
        self.bin = bin
        self.anchorHour = anchorHour
        self.capHeight = (layout.domain.upperBound - layout.domain.lowerBound) * NaraChartStyle.estimateCapShare
        self.bands = bands.map { -$0.upperBound ... -$0.lowerBound }
        self.color = color
        self.xLayout = ChartAxis.layout(window, style: xStyle, calendar: calendar)
        self.yLayout = layout
        self.xs = Array(Set(offsets.map(\.day))).sorted()
        self.state = state
        self.height = height
        self.accessibilityTitle = accessibilityTitle
        self.calendar = calendar
        self._selection = selection

        self.summary = NaraChartText.summary(title: accessibilityTitle, count: offsets.count,
                                             noun: bin == .day ? .days : .bars, low: nil, high: nil)
        let clockText: (Double) -> String = { value in
            Self.clockLabel(offset: -value, anchorHour: anchorHour, calendar: calendar)
        }
        self.descriptor = NaraChartDescriptor(
            title: accessibilityTitle, summary: summary,
            xTitle: String(localized: "Date", bundle: .module), yTitle: String(localized: "Time", bundle: .module),
            yRange: layout.domain,
            dateText: { NaraChartText.date($0, unit: bin, calendar: calendar) },
            valueText: clockText,
            series: [.init(name: String(localized: "Start", bundle: .module), isContinuous: false,
                           points: offsets.map { ($0.day, -$0.start) }),
                     .init(name: String(localized: "End", bundle: .module), isContinuous: false,
                           points: offsets.map { ($0.day, -$0.end) })])

        if let legend {
            self.legend = legend
        } else {
            var automatic: [ChartLegendItem] = []
            if !bands.isEmpty { automatic.append(ChartLegendItem(.band(color), String(localized: "Usual", bundle: .module))) }
            if offsets.contains(where: \.isEstimate) {
                automatic.append(ChartLegendItem(.estimateBar(color), String(localized: "Estimate", bundle: .module)))
            }
            self.legend = automatic
        }
    }

    // MARK: Binning and clock math (pure)

    /// The bars for `items` as the chart draws them, ascending: on `.day` one span per item (each on the
    /// local start of its wake day); on `.weekOfYear` or `.month` one per bin, from the mean start offset to
    /// the mean end offset of its nights (wall-clock hours from the anchor, so a mean never wraps around
    /// midnight), an estimate when at least half its nights are. Items that do not end after they start
    /// are left out. Use it for a readout that matches the selected bar.
    public static func bin(_ items: [Item], by unit: Calendar.Component = .day, anchorHour: Int = 18,
                           calendar: Calendar = .current) -> [Span] {
        let nights = items.filter { $0.end > $0.start }.map { item -> Span in
            let day = calendar.startOfDay(for: item.day)
            return Span(day: day,
                        start: clockOffset(item.start, wakeDay: day, anchorHour: anchorHour, calendar: calendar),
                        end: clockOffset(item.end, wakeDay: day, anchorHour: anchorHour, calendar: calendar),
                        isEstimate: item.isEstimate)
        }.sorted { (a: Span, b: Span) -> Bool in a.day != b.day ? a.day < b.day : a.start < b.start }
        guard unit != .day else { return nights }
        var groups: [Date: (start: Double, end: Double, count: Int, estimates: Int)] = [:]
        for night in nights {
            let key = calendar.dateInterval(of: unit, for: night.day)?.start ?? night.day
            var group = groups[key] ?? (0, 0, 0, 0)
            group.start += night.start
            group.end += night.end
            group.count += 1
            if night.isEstimate { group.estimates += 1 }
            groups[key] = group
        }
        return groups.keys.sorted().compactMap { key in
            guard let group = groups[key], group.count > 0 else { return nil }
            let n = Double(group.count)
            return Span(day: key, start: group.start / n, end: group.end / n, isEstimate: group.estimates * 2 >= group.count)
        }
    }

    /// A usual window (only its times of day are used) as anchor offsets, placed on the side of the anchor
    /// nearest `near` (the mean offset of the bars it describes); with no bars, inside 0..<24.
    static func typicalBand(_ typical: ClosedRange<Date>, near: Double?, anchorHour: Int,
                            calendar: Calendar) -> ClosedRange<Double> {
        var low = timeOfDayOffset(typical.lowerBound, anchorHour: anchorHour, calendar: calendar)
        let high = timeOfDayOffset(typical.upperBound, anchorHour: anchorHour, calendar: calendar)
        var width = high - low
        if width < 0 { width += 24 }
        if let near {
            let middle: Double = low + width / 2
            let shifts: [Double] = [-24, 0, 24]
            var best: Double = 0
            for shift in shifts where abs(middle + shift - near) < abs(middle + best - near) { best = shift }
            low += best
        }
        return low...(low + width)
    }

    /// Wall-clock hours from `anchorHour` on the evening before `wakeDay` to `date`: 23:00 is 5, 07:00 on
    /// the wake day is 13. Counted in local clock time (whole days between the dates plus the clock reading),
    /// so a clock change during the night does not move a bedtime off its hour line.
    public static func clockOffset(_ date: Date, wakeDay: Date, anchorHour: Int = 18,
                                   calendar: Calendar = .current) -> Double {
        let eveningDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: wakeDay)) ?? wakeDay
        let days = ChartDay.daysBetween(eveningDay, date, calendar: calendar)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let clock = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
        return Double(days) * 24 + clock - Double(anchorHour)
    }

    /// The offset of a time of day from the anchor, wrapping into 0..<24 (so 22:30 is 4.5 and 06:30 is 12.5).
    public static func timeOfDayOffset(_ date: Date, anchorHour: Int = 18, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let clock = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        let offset = clock - Double(anchorHour)
        return offset < 0 ? offset + 24 : offset
    }

    /// The clock label for an offset ("11 PM", or "23" in a 24-hour locale; "11:20 PM" off the hour).
    public static func clockLabel(offset: Double, anchorHour: Int = 18, calendar: Calendar = .current) -> String {
        let minutes = Int(((Double(anchorHour) + offset) * 60).rounded())
        let wrapped = ((minutes % 1440) + 1440) % 1440
        var parts = DateComponents()
        parts.year = 2001; parts.month = 1; parts.day = 1
        parts.hour = wrapped / 60
        parts.minute = wrapped % 60
        guard let date = calendar.date(from: parts) else { return "" }
        return wrapped % 60 == 0
            ? ChartAxis.format(date, .dateTime.hour(), calendar)
            : ChartAxis.format(date, .dateTime.hour().minute(), calendar)
    }

    /// The negated clock axis: whole hours from just before the earliest start to just after the latest
    /// end, at a step of 1, 2, 3, 4 or 6 hours that gives at most six intervals. Both ends are widened to the
    /// step, so the top and bottom of the plot are labelled lines rather than an unlabelled strip. The top
    /// goes above the anchor (a negative offset) for a bedtime before it, so no bar runs off the plot; the
    /// axis spans at most two days.
    static func clockAxis(earliest: Double, latest: Double, anchorHour: Int, calendar: Calendar) -> ChartYAxisLayout {
        // Half an hour of air above the earliest start, but never above the anchor unless a bar is.
        let padded = (earliest - 0.5).rounded(.down)
        let rawTop = earliest >= 0 ? max(0, padded) : max(-12, padded)
        let rawBottom = min(rawTop + 48, max(rawTop + 2, (latest + 0.5).rounded(.up)))
        var top = rawTop, bottom = rawBottom, step = 6.0
        for candidate in [1.0, 2, 3, 4, 6] {
            let t = (rawTop / candidate).rounded(.down) * candidate
            let b = (rawBottom / candidate).rounded(.up) * candidate
            if (b - t) / candidate <= 6 || candidate == 6 {
                top = t; bottom = b; step = candidate
                break
            }
        }
        let ticks = stride(from: top, through: bottom + 1e-9, by: step).map { -$0 }
        return ChartYAxisLayout(domain: -bottom ... -top, ticks: ticks,
                                labels: ticks.map { clockLabel(offset: -$0, anchorHour: anchorHour, calendar: calendar) },
                                unit: nil)
    }

    // MARK: Body

    public var body: some View {
        NaraChartFrame(state: state, height: height, legend: legend, accessibilityTitle: accessibilityTitle) {
            chart
        }
    }

    private var chart: some View {
        let selected = selection.flatMap { calendar.dateInterval(of: bin, for: $0)?.start }
        return Chart {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                RectangleMark(xStart: .value("Start", xLayout.window.lowerBound),
                              xEnd: .value("End", xLayout.window.upperBound),
                              yStart: .value("Early", band.lowerBound),
                              yEnd: .value("Late", band.upperBound))
                    .foregroundStyle(color.opacity(NaraChartStyle.bandOpacity))
            }
            SelectionRule(selected, unit: bin)
            ForEach(bars) { bar in
                let opacity = selected == nil || selected == bar.day ? 1 : NaraChartStyle.dimmedOpacity
                BarMark(x: .value("Day", bar.day, unit: bin),
                        yStart: .value("Start", bar.top),
                        yEnd: .value("End", bar.bottom),
                        width: .ratio(NaraChartStyle.rangeBarWidthRatio))
                    .foregroundStyle(color.opacity(bar.isEstimate ? NaraChartStyle.estimateFillOpacity : 1))
                    .cornerRadius(NaraChartStyle.barCornerRadius)
                    .opacity(opacity)
                if bar.isEstimate {
                    // Solid ends on a light bar: an estimate, not a dimmed night.
                    BarMark(x: .value("Day", bar.day, unit: bin),
                            yStart: .value("Start", bar.top), yEnd: .value("Cap", bar.top - capHeight),
                            width: .ratio(NaraChartStyle.rangeBarWidthRatio))
                        .foregroundStyle(color)
                        .opacity(opacity)
                    BarMark(x: .value("Day", bar.day, unit: bin),
                            yStart: .value("Cap", bar.bottom + capHeight), yEnd: .value("End", bar.bottom),
                            width: .ratio(NaraChartStyle.rangeBarWidthRatio))
                        .foregroundStyle(color)
                        .opacity(opacity)
                }
            }
        }
        .naraChartAxes(x: xLayout, y: yLayout, calendar: calendar)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection, unit: bin, calendar: calendar)
        }
        .naraChartRangeAnimation(xLayout.window)
        .naraChartAccessibility(title: accessibilityTitle, summary: summary, descriptor: descriptor, xs: xs,
                                selection: $selection,
                                describe: { [bars, calendar, bin, anchorHour] date in
                                    guard let day = calendar.dateInterval(of: bin, for: date)?.start,
                                          let bar = bars.first(where: { $0.day == day }) else { return nil }
                                    let start = Self.clockLabel(offset: -bar.top, anchorHour: anchorHour, calendar: calendar)
                                    let end = Self.clockLabel(offset: -bar.bottom, anchorHour: anchorHour, calendar: calendar)
                                    return NaraChartText.reading(day, unit: bin,
                                                                 parts: [String(localized: "\(start) to \(end)", bundle: .module)],
                                                                 isEstimate: bar.isEstimate, calendar: calendar)
                                })
    }
}

#if DEBUG
private struct RangeBarChartPreview: View {
    @State private var selected: Date?
    var body: some View {
        NaraChartPreviewGallery("RangeBarChart") { sample in
            RangeBarChart(items: sample.nights(), typicalStart: sample.clock(22, 45)...sample.clock(23, 30),
                          typicalEnd: sample.clock(6, 30)...sample.clock(7, 15),
                          color: StrandPalette.restColor, state: sample.state, window: sample.window,
                          xStyle: sample.range.axisStyle, selection: $selected,
                          accessibilityTitle: "Sleep schedule")
        }
    }
}

#Preview("RangeBarChart · light") { RangeBarChartPreview().preferredColorScheme(.light) }
#Preview("RangeBarChart · dark") { RangeBarChartPreview().preferredColorScheme(.dark) }
#endif
#endif
