#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - SparsePointsChart

/// Every reading as a point plus a smoothed trend line, never an area: weight, body fat, lean mass, BMI.
///
/// The trend is display-only smoothing (`trendLine`), drawn faint behind the readings so the readings stay
/// the data and the line only shows the direction. It breaks across gaps longer than the cadence, and is
/// not drawn at all for fewer than three readings, where it would be a line through two points dressed up
/// as a trend.
///
/// ```swift
/// SparsePointsChart(points: weighIns, color: StrandPalette.metricPurple, window: window,
///                   xStyle: range.axisStyle, y: ChartValueAxis(unit: "kg", domain: .fitted(minSpan: 2), format: ChartValueAxis.decimals(1)),
///                   selection: $selected, accessibilityTitle: "Weight")
/// ```
public struct SparsePointsChart: View {

    /// The smoothing behind the readings.
    public enum Trend: Equatable, Sendable {
        case none
        /// The mean of the readings within `days / 2` days either side of each reading.
        case rollingMean(days: Int)
        /// The median of the same window: one odd weigh-in barely moves it.
        case rollingMedian(days: Int)
    }

    struct Reading: Identifiable {
        let day: Date
        let value: Double
        let isEstimate: Bool
        var id: Date { day }
    }

    struct TrendMark: Identifiable {
        let day: Date
        let value: Double
        let run: String
        var id: Date { day }
    }

    private let readings: [Reading]
    private let trend: [TrendMark]
    private let color: Color
    private let references: [ChartReference]
    private let referenceAnchors: [ChartAxisLabelAnchor]
    private let pointSize: CGFloat
    private let xLayout: ChartXAxisLayout
    private let yLayout: ChartYAxisLayout
    private let xs: [Date]
    private let state: ChartState
    private let height: CGFloat
    private let legend: [ChartLegendItem]
    private let accessibilityTitle: String
    private let summary: String
    private let descriptor: NaraChartDescriptor
    private let format: @Sendable (Double) -> String
    private let unit: String?
    private let calendar: Calendar
    @Binding private var selection: Date?
    @Environment(\.naraChartCompact) private var compact

    /// - Parameters:
    ///   - cadence: where the trend line breaks (`.sparse(maxGapDays: 21)`: a three-week gap in weigh-ins).
    ///   - references: faint labelled rules, such as the BMI 18.5 / 25 / 30 lines.
    public init(points: [DailyPoint], trend: Trend = .rollingMedian(days: 14),
                cadence: ChartCadence = .sparse(maxGapDays: 21), color: Color,
                references: [ChartReference] = [], legend: [ChartLegendItem]? = nil,
                state: ChartState = .ready, window: ClosedRange<Date>, xStyle: ChartAxisStyle,
                y: ChartValueAxis, selection: Binding<Date?>,
                height: CGFloat = NoopMetrics.chartHeightPrimary, accessibilityTitle: String,
                calendar: Calendar = .current) {
        let sorted = points.filter { $0.value.isFinite }.sorted { $0.day < $1.day }
        let windowed = sorted.inWindow(window)
        // Smoothed over the whole history so the first readings in the window keep their context.
        let smoothed = windowed.count >= 3
            ? Self.trendLine(sorted, trend, calendar: calendar).inWindow(window) : []
        let runs = ChartGaps.runs(smoothed.map(\.day), series: smoothed.map { _ in "trend" }, cadence: cadence,
                                  calendar: calendar)
        let yLayout = y.layout(for: windowed.map(\.value) + smoothed.map(\.value) + references.map(\.value))

        self.readings = windowed.map { Reading(day: $0.day, value: $0.value, isEstimate: $0.isEstimate) }
        self.trend = zip(smoothed, runs).map { TrendMark(day: $0.day, value: $0.value, run: $1) }
        self.color = color
        self.references = references
        self.referenceAnchors = NaraReferenceLabelPlacement.anchors(
            for: references,
            marks: (windowed + smoothed).map { .init(x: ChartDay.center(of: $0.day, calendar: calendar),
                                                      low: $0.value, high: $0.value) },
            window: window, domain: yLayout.domain)
        self.pointSize = windowed.count > NaraChartStyle.densePointThreshold
            ? NaraChartStyle.densePointSize : NaraChartStyle.pointSize
        self.xLayout = ChartAxis.layout(window, style: xStyle, calendar: calendar)
        self.yLayout = yLayout
        self.xs = windowed.map(\.day)
        self.state = state
        self.height = height
        self.accessibilityTitle = accessibilityTitle
        self.calendar = calendar
        self._selection = selection

        let unitLabel = y.unit
        let format = y.format
        self.format = format
        self.unit = unitLabel
        self.summary = NaraChartText.summary(
            title: accessibilityTitle, count: windowed.count, noun: .readings,
            low: windowed.map(\.value).min().map { NaraChartText.value($0, format: format, unit: unitLabel) },
            high: windowed.map(\.value).max().map { NaraChartText.value($0, format: format, unit: unitLabel) })
        self.descriptor = NaraChartDescriptor(
            title: accessibilityTitle, summary: summary,
            xTitle: String(localized: "Date", bundle: .module), yTitle: unitLabel ?? accessibilityTitle,
            yRange: yLayout.domain,
            dateText: { NaraChartText.date($0, unit: .day, calendar: calendar) },
            valueText: { NaraChartText.value($0, format: format, unit: unitLabel) },
            series: [.init(name: accessibilityTitle, isContinuous: false, points: windowed.map { ($0.day, $0.value) })])

        if let legend {
            self.legend = legend
        } else {
            var automatic: [ChartLegendItem] = []
            if !smoothed.isEmpty {
                automatic.append(ChartLegendItem(.point(color), String(localized: "Reading", bundle: .module)))
                automatic.append(ChartLegendItem(.line(color.opacity(0.45), dashed: false),
                                                 String(localized: "Trend", bundle: .module)))
            }
            if windowed.contains(where: \.isEstimate) {
                automatic.append(ChartLegendItem(.estimate(color), String(localized: "Estimate", bundle: .module)))
            }
            self.legend = automatic
        }
    }

    /// The display-only trend at each reading: the mean or median of the readings within `days / 2`
    /// calendar days either side (the reading's own included), ascending. `.none` gives no line. Pure; it
    /// never feeds a score.
    public static func trendLine(_ points: [DailyPoint], _ trend: Trend, calendar: Calendar = .current) -> [DailyPoint] {
        let days: Int
        let median: Bool
        switch trend {
        case .none: return []
        case .rollingMean(let span): days = span; median = false
        case .rollingMedian(let span): days = span; median = true
        }
        let sorted = points.filter { $0.value.isFinite }.sorted { $0.day < $1.day }
        let half = max(0, days / 2)
        var low = 0
        var high = 0
        return sorted.map { point in
            let earliest = calendar.date(byAdding: .day, value: -half, to: point.day) ?? point.day
            let latest = calendar.date(byAdding: .day, value: half, to: point.day) ?? point.day
            while low < sorted.count, sorted[low].day < calendar.startOfDay(for: earliest) { low += 1 }
            if high < low { high = low }
            while high < sorted.count, sorted[high].day <= latest { high += 1 }
            let values = sorted[low..<high].map(\.value)
            return DailyPoint(day: point.day, value: median ? Self.median(values) : Self.mean(values), series: "trend")
        }
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
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
            NaraReferenceMarks(references: references)
            SelectionRule(selected, unit: .day)
            ForEach(trend) { point in
                LineMark(x: .value("Day", point.day, unit: .day),
                         y: .value("Trend", point.value),
                         series: .value("Run", point.run))
                    .interpolationMethod(.monotone)
                    .lineStyle(NaraChartStyle.line)
                    .foregroundStyle(color.opacity(0.45))
            }
            ForEach(readings) { reading in
                PointMark(x: .value("Day", reading.day, unit: .day), y: .value("Value", reading.value))
                    .symbol(NaraPointSymbol.shape(estimate: reading.isEstimate))
                    .symbolSize(selected == reading.day ? NaraChartStyle.selectedPointSize : pointSize)
                    .foregroundStyle(color)
            }
            NaraReferenceLabels(references: references, anchors: referenceAnchors, showsLabels: !compact)
        }
        .naraChartAxes(x: xLayout, y: yLayout, calendar: calendar)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection)
        }
        .naraChartRangeAnimation(xLayout.window)
        .naraChartAccessibility(title: accessibilityTitle, summary: summary, descriptor: descriptor, xs: xs,
                                selection: $selection,
                                describe: { [readings, format, unit, calendar] date in
                                    let day = calendar.startOfDay(for: date)
                                    guard let reading = readings.first(where: { $0.day == day }) else { return nil }
                                    return NaraChartText.reading(day, unit: .day,
                                                                 parts: [NaraChartText.value(reading.value, format: format, unit: unit)],
                                                                 isEstimate: reading.isEstimate, calendar: calendar)
                                })
    }
}

#if DEBUG
private struct SparsePointsChartPreview: View {
    @State private var selected: Date?
    var body: some View {
        NaraChartPreviewGallery("SparsePointsChart") { sample in
            SparsePointsChart(points: sample.points(base: 72.4, swing: 1.6, every: 3),
                              color: StrandPalette.metricPurple, state: sample.state, window: sample.window,
                              xStyle: sample.range.axisStyle,
                              y: ChartValueAxis(unit: "kg", domain: .fitted(minSpan: 2), format: ChartValueAxis.decimals(1)),
                              selection: $selected, accessibilityTitle: "Weight")
        }
    }
}

#Preview("SparsePointsChart · light") { SparsePointsChartPreview().preferredColorScheme(.light) }
#Preview("SparsePointsChart · dark") { SparsePointsChartPreview().preferredColorScheme(.dark) }
#endif
#endif
