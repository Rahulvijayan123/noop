#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - DotStripChart

/// One dot per day on a scale of named levels, never joined: mood 1-5. A line between two check-ins would
/// invent the days in between, so there is none; each level is its own labelled row.
///
/// ```swift
/// DotStripChart(points: moods, levels: 1...5, levelLabels: [1: "Low", 3: "Okay", 5: "Great"],
///               color: { moodColor($0) }, window: window, xStyle: range.axisStyle,
///               selection: $selected, accessibilityTitle: "Mood")
/// ```
public struct DotStripChart: View {
    struct Dot: Identifiable {
        let day: Date
        let level: Int
        let isEstimate: Bool
        let color: Color
        var id: Date { day }
    }

    private let dots: [Dot]
    private let xLayout: ChartXAxisLayout
    private let yLayout: ChartYAxisLayout
    private let xs: [Date]
    private let state: ChartState
    private let height: CGFloat
    private let legend: [ChartLegendItem]
    private let accessibilityTitle: String
    private let summary: String
    private let descriptor: NaraChartDescriptor
    private let levelLabels: [Int: String]
    private let dotSize: CGFloat
    private let calendar: Calendar
    @Binding private var selection: Date?

    /// - Parameters:
    ///   - levels: the scale; a value is rounded to the nearest level and clamped into it.
    ///   - levelLabels: the row labels; a level without one prints its number.
    ///   - color: each level's colour.
    ///   - unit: drawn above the axis ("/5"); usually nil, since the rows are labelled.
    public init(points: [DailyPoint], levels: ClosedRange<Int>, levelLabels: [Int: String] = [:],
                color: (Int) -> Color, unit: String? = nil, legend: [ChartLegendItem]? = nil,
                state: ChartState = .ready, window: ClosedRange<Date>, xStyle: ChartAxisStyle,
                selection: Binding<Date?>, height: CGFloat = NoopMetrics.chartHeightPrimary,
                accessibilityTitle: String, calendar: Calendar = .current) {
        // One check-in per local day: two on one day draw as their mean, on the nearest level.
        let windowed = points.normalisedDays(calendar).inWindow(window)
        let palette = Dictionary(uniqueKeysWithValues: levels.map { ($0, color($0)) })
        let dots = windowed.map { point -> Dot in
            let level = Self.level(for: point.value, in: levels)
            return Dot(day: point.day, level: level, isEstimate: point.isEstimate,
                       color: palette[level] ?? StrandPalette.textSecondary)
        }
        let ticks = levels.map(Double.init)
        let labels = levels.map { levelLabels[$0] ?? "\($0)" }

        self.dots = dots
        self.xLayout = ChartAxis.layout(window, style: xStyle, calendar: calendar)
        self.yLayout = ChartYAxisLayout(domain: (Double(levels.lowerBound) - 0.5)...(Double(levels.upperBound) + 0.5),
                                        ticks: ticks, labels: labels, unit: unit)
        self.xs = dots.map(\.day)
        self.state = state
        self.height = height
        self.legend = legend ?? (dots.contains(where: \.isEstimate)
            ? [ChartLegendItem(.estimate(StrandPalette.textSecondary), String(localized: "Estimate", bundle: .module))]
            : [])
        // A year of check-ins at the full dot size merges into a bar along each row.
        self.dotSize = dots.count > NaraChartStyle.densePointThreshold ? NaraChartStyle.pointSize : NaraChartStyle.pointSize * 2
        self.accessibilityTitle = accessibilityTitle
        self.calendar = calendar
        self._selection = selection

        self.levelLabels = levelLabels
        self.summary = NaraChartText.summary(title: accessibilityTitle, count: dots.count, noun: .days,
                                             low: dots.map(\.level).min().map(String.init),
                                             high: dots.map(\.level).max().map(String.init))
        self.descriptor = NaraChartDescriptor(
            title: accessibilityTitle, summary: summary,
            xTitle: String(localized: "Date", bundle: .module), yTitle: accessibilityTitle,
            yRange: Double(levels.lowerBound)...Double(levels.upperBound),
            dateText: { NaraChartText.date($0, unit: .day, calendar: calendar) },
            valueText: { value in
                let level = Int(value.rounded())
                return levelLabels[level].map { "\(level), \($0)" } ?? "\(level)"
            },
            series: [.init(name: accessibilityTitle, isContinuous: false, points: dots.map { ($0.day, Double($0.level)) })])
    }

    /// The level a value is drawn on: the nearest whole level, clamped into the scale. Pure.
    public static func level(for value: Double, in levels: ClosedRange<Int>) -> Int {
        guard value.isFinite else { return levels.lowerBound }
        return min(max(Int(value.rounded()), levels.lowerBound), levels.upperBound)
    }

    public var body: some View {
        NaraChartFrame(state: state, height: height, legend: legend, accessibilityTitle: accessibilityTitle) {
            chart
        }
    }

    private var chart: some View {
        let selected = selection.map { calendar.startOfDay(for: $0) }
        return Chart {
            SelectionRule(selected, unit: .day)
            ForEach(dots) { dot in
                PointMark(x: .value("Day", dot.day, unit: .day), y: .value("Level", Double(dot.level)))
                    .symbol(NaraPointSymbol.shape(estimate: dot.isEstimate))
                    .symbolSize(selected == dot.day ? NaraChartStyle.selectedPointSize : dotSize)
                    .foregroundStyle(dot.color)
                    .opacity(selected == nil || selected == dot.day ? 1 : NaraChartStyle.dimmedOpacity)
            }
        }
        .naraChartAxes(x: xLayout, y: yLayout, calendar: calendar)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection, unit: .day, calendar: calendar)
        }
        .naraChartRangeAnimation(xLayout.window)
        .naraChartAccessibility(title: accessibilityTitle, summary: summary, descriptor: descriptor, xs: xs,
                                selection: $selection,
                                describe: { [dots, levelLabels, calendar] date in
                                    let day = calendar.startOfDay(for: date)
                                    guard let dot = dots.first(where: { $0.day == day }) else { return nil }
                                    let parts = ["\(dot.level)", levelLabels[dot.level]].compactMap { $0 }
                                    return NaraChartText.reading(day, unit: .day, parts: parts, isEstimate: dot.isEstimate,
                                                                 calendar: calendar)
                                })
    }
}

#if DEBUG
private struct DotStripChartPreview: View {
    @State private var selected: Date?
    var body: some View {
        NaraChartPreviewGallery("DotStripChart") { sample in
            DotStripChart(points: sample.points(base: 3, swing: 2), levels: 1...5,
                          levelLabels: [1: "Low", 3: "Okay", 5: "Great"],
                          color: { level in level >= 4 ? StrandPalette.statusPositive : (level <= 2 ? StrandPalette.metricRose : StrandPalette.metricPurple) },
                          state: sample.state, window: sample.window, xStyle: sample.range.axisStyle,
                          selection: $selected, height: NoopMetrics.chartHeightSecondary,
                          accessibilityTitle: "Mood")
        }
    }
}

#Preview("DotStripChart · light") { DotStripChartPreview().preferredColorScheme(.light) }
#Preview("DotStripChart · dark") { DotStripChartPreview().preferredColorScheme(.dark) }
#endif
#endif
