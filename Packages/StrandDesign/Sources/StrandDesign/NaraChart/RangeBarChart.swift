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
/// night is a light bar with solid ends, and the legend says "Estimate".
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

    struct Bar: Identifiable {
        let day: Date
        /// Negated clock offsets: `top` is the (earlier) start, `bottom` the end.
        let top: Double
        let bottom: Double
        let isEstimate: Bool
        var id: Date { day }
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
        let windowed = items.filter { $0.day >= window.lowerBound && $0.day < window.upperBound && $0.end > $0.start }
            .sorted { $0.day < $1.day }
        // (day or bin start, start offset, end offset, estimate), ascending.
        var offsets: [(day: Date, start: Double, end: Double, isEstimate: Bool)] = windowed.map { item in
            (item.day, Self.clockOffset(item.start, wakeDay: item.day, anchorHour: anchorHour, calendar: calendar),
             Self.clockOffset(item.end, wakeDay: item.day, anchorHour: anchorHour, calendar: calendar), item.isEstimate)
        }
        if bin != .day {
            var groups: [Date: (start: Double, end: Double, count: Int, estimates: Int)] = [:]
            for night in offsets {
                let key = calendar.dateInterval(of: bin, for: night.day)?.start ?? night.day
                var group = groups[key] ?? (0, 0, 0, 0)
                group.start += night.start
                group.end += night.end
                group.count += 1
                if night.isEstimate { group.estimates += 1 }
                groups[key] = group
            }
            offsets = groups.keys.sorted().compactMap { key in
                guard let group = groups[key], group.count > 0 else { return nil }
                let n = Double(group.count)
                return (key, group.start / n, group.end / n, group.estimates * 2 >= group.count)
            }
        }
        var bands: [ClosedRange<Double>] = []
        for typical in [typicalStart, typicalEnd].compactMap({ $0 }) {
            let low = Self.timeOfDayOffset(typical.lowerBound, anchorHour: anchorHour, calendar: calendar)
            let high = Self.timeOfDayOffset(typical.upperBound, anchorHour: anchorHour, calendar: calendar)
            bands.append(min(low, high)...max(low, high))
        }
        let earliest = (offsets.map(\.start) + bands.map(\.lowerBound)).min() ?? 4
        let latest = (offsets.map(\.end) + bands.map(\.upperBound)).max() ?? 14
        let layout = Self.clockAxis(earliest: earliest, latest: latest, anchorHour: anchorHour, calendar: calendar)

        self.bars = offsets.map { Bar(day: $0.day, top: -$0.start, bottom: -$0.end, isEstimate: $0.isEstimate) }
        self.bin = bin
        self.anchorHour = anchorHour
        self.capHeight = (layout.domain.upperBound - layout.domain.lowerBound) * NaraChartStyle.estimateCapShare
        self.bands = bands.map { -$0.upperBound ... -$0.lowerBound }
        self.color = color
        self.xLayout = ChartAxis.layout(window, style: xStyle, calendar: calendar)
        self.yLayout = layout
        self.xs = offsets.map(\.day)
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

    // MARK: Clock math (pure)

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

    /// The clock label for an offset ("11 PM", or "23" in a 24-hour locale).
    static func clockLabel(offset: Double, anchorHour: Int, calendar: Calendar) -> String {
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
    /// step, so the top and bottom of the plot are labelled lines rather than an unlabelled strip.
    static func clockAxis(earliest: Double, latest: Double, anchorHour: Int, calendar: Calendar) -> ChartYAxisLayout {
        let rawTop = max(0, (earliest - 0.5).rounded(.down))
        let rawBottom = min(36, max(rawTop + 2, (latest + 0.5).rounded(.up)))
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
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection)
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
