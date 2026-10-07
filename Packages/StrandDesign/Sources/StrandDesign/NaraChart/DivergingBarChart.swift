#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - DivergingBarChart

/// Bars above and below a zero line: skin-temperature deviation (warmer above, cooler below), a nightly
/// sleep balance. The value axis is always symmetric around zero, so a +0.3 and a -0.3 night are the same
/// height, and the legend always names both directions.
///
/// ```swift
/// DivergingBarChart(points: deviations, positive: StrandPalette.metricAmber, negative: StrandPalette.metricCyan,
///                   positiveLabel: "Warmer", negativeLabel: "Cooler",
///                   references: [ChartReference(0.5), ChartReference(-0.5)],
///                   window: window, xStyle: range.axisStyle,
///                   y: ChartValueAxis(unit: "Δ°C", domain: .symmetric(minMagnitude: 0.5), format: ChartValueAxis.decimals(1)),
///                   selection: $selected, accessibilityTitle: "Skin temperature")
/// ```
public struct DivergingBarChart: View {
    struct Bar: Identifiable {
        let day: Date
        let value: Double
        let isEstimate: Bool
        var id: Date { day }
    }

    private let bars: [Bar]
    private let positive: Color
    private let negative: Color
    private let references: [ChartReference]
    private let capHeight: Double
    private let xLayout: ChartXAxisLayout
    private let yLayout: ChartYAxisLayout
    private let xs: [Date]
    private let state: ChartState
    private let height: CGFloat
    private let legend: [ChartLegendItem]
    private let accessibilityTitle: String
    private let summary: String
    private let descriptor: NaraChartDescriptor
    private let directions: (positive: String, negative: String)
    private let format: @Sendable (Double) -> String
    private let unit: String?
    private let calendar: Calendar
    @Binding private var selection: Date?
    @Environment(\.naraChartCompact) private var compact

    /// - Parameters:
    ///   - references: extra rules, such as ±0.5 °C; zero is always drawn.
    ///   - y: any domain is made symmetric around zero; `.symmetric(minMagnitude:)` says how small the axis
    ///     may get.
    public init(points: [DailyPoint], positive: Color, negative: Color,
                positiveLabel: String, negativeLabel: String,
                references: [ChartReference] = [], legend: [ChartLegendItem]? = nil,
                state: ChartState = .ready, window: ClosedRange<Date>, xStyle: ChartAxisStyle,
                y: ChartValueAxis, selection: Binding<Date?>,
                height: CGFloat = NoopMetrics.chartHeightPrimary, accessibilityTitle: String,
                calendar: Calendar = .current) {
        let windowed = points.filter { $0.value.isFinite }.inWindow(window)
        var axis = y
        switch y.domain {
        case .symmetric: break
        case .fixed(let range):
            axis.domain = .symmetric(minMagnitude: max(abs(range.lowerBound), abs(range.upperBound)))
        case .fitted(let minSpan, _, _, _):
            axis.domain = .symmetric(minMagnitude: minSpan / 2)
        }
        let yLayout = axis.layout(for: windowed.map(\.value) + references.map(\.value))

        self.bars = windowed.map { Bar(day: $0.day, value: $0.value, isEstimate: $0.isEstimate) }
        self.positive = positive
        self.negative = negative
        self.references = references
        self.capHeight = (yLayout.domain.upperBound - yLayout.domain.lowerBound) * 0.012
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
        self.directions = (positiveLabel, negativeLabel)
        self.format = format
        self.unit = unitLabel
        self.summary = NaraChartText.summary(
            title: accessibilityTitle, count: windowed.count, noun: .days,
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
            var automatic = [ChartLegendItem(.swatch(positive), positiveLabel),
                             ChartLegendItem(.swatch(negative), negativeLabel)]
            if windowed.contains(where: \.isEstimate) {
                automatic.append(ChartLegendItem(.estimate(StrandPalette.textSecondary),
                                                 String(localized: "Estimate", bundle: .module)))
            }
            self.legend = automatic
        }
    }

    public var body: some View {
        NaraChartFrame(state: state, height: height, legend: legend, accessibilityTitle: accessibilityTitle) {
            chart
        }
    }

    private var chart: some View {
        let selected = selection.map { calendar.startOfDay(for: $0) }
        return Chart {
            NaraReferenceMarks(references: references, showsLabels: !compact)
            RuleMark(y: .value("Zero", 0.0))
                .lineStyle(NaraChartStyle.solidReference)
                .foregroundStyle(StrandPalette.textTertiary)
            SelectionRule(selected, unit: .day)
            ForEach(bars) { bar in
                let color = bar.value >= 0 ? positive : negative
                let opacity = selected == nil || selected == bar.day ? 1 : NaraChartStyle.dimmedOpacity
                BarMark(x: .value("Day", bar.day, unit: .day),
                        yStart: .value("Zero", 0.0),
                        yEnd: .value("Value", bar.value),
                        width: .ratio(NaraChartStyle.barWidthRatio))
                    .foregroundStyle(color.opacity(bar.isEstimate ? NaraChartStyle.estimateFillOpacity : 1))
                    .cornerRadius(NaraChartStyle.barCornerRadius)
                    .opacity(opacity)
                if bar.isEstimate {
                    BarMark(x: .value("Day", bar.day, unit: .day),
                            yStart: .value("Cap", bar.value >= 0 ? bar.value - capHeight : bar.value + capHeight),
                            yEnd: .value("Value", bar.value),
                            width: .ratio(NaraChartStyle.barWidthRatio))
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
                                describe: { [bars, directions, format, unit, calendar] date in
                                    let day = calendar.startOfDay(for: date)
                                    guard let bar = bars.first(where: { $0.day == day }) else { return nil }
                                    let direction = bar.value > 0 ? directions.positive : (bar.value < 0 ? directions.negative : nil)
                                    let parts = [NaraChartText.value(bar.value, format: format, unit: unit), direction].compactMap { $0 }
                                    return NaraChartText.reading(day, unit: .day, parts: parts, isEstimate: bar.isEstimate,
                                                                 calendar: calendar)
                                })
    }
}

#if DEBUG
private struct DivergingBarChartPreview: View {
    @State private var selected: Date?
    var body: some View {
        NaraChartPreviewGallery("DivergingBarChart") { sample in
            DivergingBarChart(points: sample.points(base: 0, swing: 0.6),
                              positive: StrandPalette.metricAmber, negative: StrandPalette.metricCyan,
                              positiveLabel: "Warmer", negativeLabel: "Cooler",
                              references: [ChartReference(0.5), ChartReference(-0.5)],
                              state: sample.state, window: sample.window, xStyle: sample.range.axisStyle,
                              y: ChartValueAxis(unit: "Δ°C", domain: .symmetric(minMagnitude: 0.5),
                                                format: ChartValueAxis.decimals(1)),
                              selection: $selected, accessibilityTitle: "Skin temperature")
        }
    }
}

#Preview("DivergingBarChart · light") { DivergingBarChartPreview().preferredColorScheme(.light) }
#Preview("DivergingBarChart · dark") { DivergingBarChartPreview().preferredColorScheme(.dark) }
#endif
#endif
