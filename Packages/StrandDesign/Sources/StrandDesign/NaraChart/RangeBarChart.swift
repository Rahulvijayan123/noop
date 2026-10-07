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
        let top: Double
        let bottom: Double
        let isEstimate: Bool
        var id: Date { day }
    }

    private let bars: [Bar]
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
    private let spans: [Item]
    private let calendar: Calendar
    @Binding private var selection: Date?

    /// - Parameters:
    ///   - anchorHour: the top of the clock, in hours (18 = 6 PM the evening before the wake day).
    ///   - typicalStart / typicalEnd: the usual bedtime and wake windows, drawn as bands across the chart.
    ///     Only their time of day is used.
    public init(items: [Item], anchorHour: Int = 18,
                typicalStart: ClosedRange<Date>? = nil, typicalEnd: ClosedRange<Date>? = nil,
                color: Color, legend: [ChartLegendItem]? = nil, state: ChartState = .ready,
                window: ClosedRange<Date>, xStyle: ChartAxisStyle, selection: Binding<Date?>,
                height: CGFloat = NoopMetrics.chartHeightPrimary, accessibilityTitle: String,
                calendar: Calendar = .current) {
        let windowed = items.filter { $0.day >= window.lowerBound && $0.day < window.upperBound && $0.end > $0.start }
            .sorted { $0.day < $1.day }
        let offsets = windowed.map { item in
            (item, Self.clockOffset(item.start, wakeDay: item.day, anchorHour: anchorHour, calendar: calendar),
             Self.clockOffset(item.end, wakeDay: item.day, anchorHour: anchorHour, calendar: calendar))
        }
        var bands: [ClosedRange<Double>] = []
        for typical in [typicalStart, typicalEnd].compactMap({ $0 }) {
            let low = Self.timeOfDayOffset(typical.lowerBound, anchorHour: anchorHour, calendar: calendar)
            let high = Self.timeOfDayOffset(typical.upperBound, anchorHour: anchorHour, calendar: calendar)
            bands.append(min(low, high)...max(low, high))
        }
        let earliest = (offsets.map(\.1) + bands.map(\.lowerBound)).min() ?? 4
        let latest = (offsets.map(\.2) + bands.map(\.upperBound)).max() ?? 14
        let layout = Self.clockAxis(earliest: earliest, latest: latest, anchorHour: anchorHour, calendar: calendar)

        self.bars = offsets.map { Bar(day: $0.0.day, top: -$0.1, bottom: -$0.2, isEstimate: $0.0.isEstimate) }
        self.bands = bands.map { -$0.upperBound ... -$0.lowerBound }
        self.color = color
        self.xLayout = ChartAxis.layout(window, style: xStyle, calendar: calendar)
        self.yLayout = layout
        self.xs = windowed.map(\.day)
        self.state = state
        self.height = height
        self.accessibilityTitle = accessibilityTitle
        self.calendar = calendar
        self._selection = selection

        self.spans = windowed
        self.summary = NaraChartText.summary(title: accessibilityTitle, count: windowed.count, noun: .days,
                                             low: nil, high: nil)
        let clockText: (Double) -> String = { value in
            Self.clockLabel(offset: -value, anchorHour: anchorHour, calendar: calendar)
        }
        self.descriptor = NaraChartDescriptor(
            title: accessibilityTitle, summary: summary,
            xTitle: String(localized: "Date", bundle: .module), yTitle: String(localized: "Time", bundle: .module),
            yRange: layout.domain,
            dateText: { NaraChartText.date($0, unit: .day, calendar: calendar) },
            valueText: clockText,
            series: [.init(name: String(localized: "Start", bundle: .module), isContinuous: false,
                           points: offsets.map { ($0.0.day, -$0.1) }),
                     .init(name: String(localized: "End", bundle: .module), isContinuous: false,
                           points: offsets.map { ($0.0.day, -$0.2) })])

        if let legend {
            self.legend = legend
        } else {
            var automatic: [ChartLegendItem] = []
            if !bands.isEmpty { automatic.append(ChartLegendItem(.band(color), String(localized: "Usual", bundle: .module))) }
            if windowed.contains(where: \.isEstimate) {
                automatic.append(ChartLegendItem(.estimate(color), String(localized: "Estimate", bundle: .module)))
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
    /// end, at a step of 1, 2, 3, 4 or 6 hours that gives at most six lines.
    static func clockAxis(earliest: Double, latest: Double, anchorHour: Int, calendar: Calendar) -> ChartYAxisLayout {
        let top = max(0, (earliest - 0.5).rounded(.down))
        let bottom = min(36, max(top + 2, (latest + 0.5).rounded(.up)))
        let span = bottom - top
        let step = [1.0, 2, 3, 4, 6].first { span / $0 <= 6 } ?? 6
        let first = (top / step).rounded(.up) * step
        let ticks = stride(from: first, through: bottom, by: step).map { -$0 }
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
        let selected = selection.map { calendar.startOfDay(for: $0) }
        return Chart {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                RectangleMark(xStart: .value("Start", xLayout.window.lowerBound),
                              xEnd: .value("End", xLayout.window.upperBound),
                              yStart: .value("Early", band.lowerBound),
                              yEnd: .value("Late", band.upperBound))
                    .foregroundStyle(color.opacity(NaraChartStyle.bandOpacity))
            }
            SelectionRule(selected, unit: .day)
            ForEach(bars) { bar in
                BarMark(x: .value("Day", bar.day, unit: .day),
                        yStart: .value("Start", bar.top),
                        yEnd: .value("End", bar.bottom),
                        width: .ratio(NaraChartStyle.rangeBarWidthRatio))
                    .foregroundStyle(color.opacity(bar.isEstimate ? NaraChartStyle.estimateFillOpacity : 1))
                    .cornerRadius(NaraChartStyle.barCornerRadius)
                    .opacity(selected == nil || selected == bar.day ? 1 : NaraChartStyle.dimmedOpacity)
            }
        }
        .naraChartAxes(x: xLayout, y: yLayout, calendar: calendar)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection)
        }
        .naraChartRangeAnimation(xLayout.window)
        .naraChartAccessibility(title: accessibilityTitle, summary: summary, descriptor: descriptor, xs: xs,
                                selection: $selection,
                                describe: { [spans, calendar] date in
                                    let day = calendar.startOfDay(for: date)
                                    guard let item = spans.first(where: { $0.day == day }) else { return nil }
                                    let start = ChartAxis.format(item.start, .dateTime.hour().minute(), calendar)
                                    let end = ChartAxis.format(item.end, .dateTime.hour().minute(), calendar)
                                    return NaraChartText.reading(day, unit: .day,
                                                                 parts: [String(localized: "\(start) to \(end)", bundle: .module)],
                                                                 isEstimate: item.isEstimate, calendar: calendar)
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
