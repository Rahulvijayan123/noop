#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - DailyLineChart

/// Points joined by a line that breaks across missing days: HRV, resting heart rate, respiratory rate,
/// average heart rate, absolute skin temperature, and (through `fixedDomainPoints`) blood oxygen and sleep
/// efficiency on their fixed scales.
///
/// Rules it keeps for every caller:
/// - the line breaks wherever the series skips more than its `cadence`, and wherever a point's `series`
///   (method) changes;
/// - fewer than three points in the window draws points only, because two points joined by a line imply a
///   trend nobody measured;
/// - nothing is ever filled under a line (an area reads as a quantity); the typical band is a range, drawn
///   as a band;
/// - estimated readings are hollow, and a run of nothing but estimates is dashed;
/// - long series are downsampled for drawing (`ChartDownsample`) after the gaps are found on the full
///   series, so a missing day still breaks the line.
///
/// ```swift
/// DailyLineChart(series: [.init(id: "hrv", name: "HRV", color: StrandPalette.metricCyan, points: nights)],
///                typicalBand: typical, baseline: ChartReference(base, label: "Baseline \(fmt(base))"),
///                window: window, xStyle: range.axisStyle,
///                y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
///                selection: $selected, accessibilityTitle: "Heart rate variability")
/// ```
public struct DailyLineChart: View {

    /// One line. Each `DailyPoint.series` within it is a method run that never joins the next.
    public struct Series: Identifiable {
        public var id: String
        public var name: String
        public var color: Color
        public var points: [DailyPoint]

        public init(id: String, name: String, color: Color, points: [DailyPoint]) {
            self.id = id
            self.name = name
            self.color = color
            self.points = points
        }
    }

    /// Which marks draw. `.lineOnly` still draws a reading that sits alone between two gaps, which a
    /// line cannot show.
    public enum Marks: Equatable, Sendable {
        case pointsAndLine, pointsOnly, lineOnly
    }

    struct Mark: Identifiable {
        let id: String
        let seriesID: String
        let run: String
        let day: Date
        let value: Double
        let isEstimate: Bool
        let color: Color
    }

    struct BandPoint: Identifiable {
        let day: Date
        let low: Double
        let high: Double
        let run: String
        var id: Date { day }
    }

    private let lineMarks: [Mark]
    private let pointMarks: [Mark]
    private let dashedRuns: Set<String>
    private let byDay: [Date: [Mark]]
    private let drawsLines: Bool
    private let interpolation: ChartInterpolation
    private let typicalBand: ClosedRange<Double>?
    private let rollingBand: [BandPoint]
    private let bandColor: Color
    private let references: [ChartReference]
    private let xLayout: ChartXAxisLayout
    private let yLayout: ChartYAxisLayout
    private let xs: [Date]
    private let state: ChartState
    private let height: CGFloat
    private let legend: [ChartLegendItem]
    private let accessibilityTitle: String
    private let summary: String
    private let descriptor: NaraChartDescriptor
    /// Series names by id, only when there are several (a single line's readout needs no name).
    private let seriesNames: [String: String]
    private let format: @Sendable (Double) -> String
    private let unit: String?
    private let calendar: Calendar
    @Binding private var selection: Date?
    @Environment(\.naraChartCompact) private var compact

    /// - Parameters:
    ///   - cadence: where lines break (`.daily` for nightly metrics, `.weekly`, `.sparse`).
    ///   - typicalBand: a personal band that does not move over the window, drawn across it at 12 %.
    ///   - rollingBand: a band that moves with time, one range per day; breaks where days are missing.
    ///   - bandColor: the band's colour; the first series' colour by default.
    ///   - baseline: a dashed baseline rule with its label at the trailing edge.
    ///   - reference: a second labelled rule (95 %, 85 %, a target).
    ///   - legend: nil for the automatic legend (series when there are several, the band, estimates).
    public init(series: [Series], cadence: ChartCadence = .daily, marks: Marks = .pointsAndLine,
                interpolation: ChartInterpolation = .monotone,
                typicalBand: ClosedRange<Double>? = nil,
                rollingBand: [(day: Date, range: ClosedRange<Double>)]? = nil,
                bandColor: Color? = nil,
                baseline: ChartReference? = nil, reference: ChartReference? = nil,
                legend: [ChartLegendItem]? = nil,
                state: ChartState = .ready, window: ClosedRange<Date>, xStyle: ChartAxisStyle,
                y: ChartValueAxis, selection: Binding<Date?>,
                height: CGFloat = NoopMetrics.chartHeightPrimary, accessibilityTitle: String,
                calendar: Calendar = .current) {
        let windowed = series.map { line in (line, line.points.filter { $0.value.isFinite }.inWindow(window)) }
        let total = windowed.reduce(0) { $0 + $1.1.count }
        let pointsOnly = marks == .pointsOnly || total < 3

        var lineMarks: [Mark] = []
        var pointMarks: [Mark] = []
        var dashedRuns: Set<String> = []
        var byDay: [Date: [Mark]] = [:]
        for (line, points) in windowed {
            let runs = ChartGaps.runs(points.map(\.day), series: points.map(\.series), cadence: cadence, calendar: calendar)
            let all = zip(points, runs).map { point, run in
                Mark(id: "\(line.id)|\(point.day.timeIntervalSince1970)", seriesID: line.id, run: "\(line.id)|\(run)",
                     day: point.day, value: point.value, isEstimate: point.isEstimate, color: line.color)
            }
            for mark in all { byDay[mark.day, default: []].append(mark) }
            var runCounts: [String: Int] = [:]
            var runEstimates: [String: Bool] = [:]
            for mark in all {
                runCounts[mark.run, default: 0] += 1
                runEstimates[mark.run] = (runEstimates[mark.run] ?? true) && mark.isEstimate
            }
            dashedRuns.formUnion(runEstimates.filter(\.value).keys)
            if !pointsOnly {
                lineMarks += ChartDownsample.minMaxBucketed(all, threshold: ChartDownsample.markThreshold,
                                                            targetCount: ChartDownsample.targetVertices,
                                                            date: \.day, value: \.value)
            }
            let isolated = all.filter { runCounts[$0.run] == 1 }
            switch marks {
            case _ where pointsOnly:
                pointMarks += all
            case .lineOnly:
                pointMarks += isolated
            default:
                pointMarks += all.count <= NaraChartStyle.denseSeriesPointLimit ? all : isolated
            }
        }

        var bandPoints: [BandPoint] = []
        if let rollingBand {
            let days = rollingBand.filter { $0.day >= window.lowerBound && $0.day < window.upperBound }
                .sorted { $0.day < $1.day }
            let runs = ChartGaps.runs(days.map(\.day), series: days.map { _ in "band" }, cadence: cadence, calendar: calendar)
            bandPoints = zip(days, runs).map { BandPoint(day: $0.day, low: $0.range.lowerBound, high: $0.range.upperBound, run: $1) }
        }

        let references = [baseline, reference].compactMap { $0 }
        var values = windowed.flatMap { $0.1.map(\.value) } + references.map(\.value)
        if let typicalBand { values += [typicalBand.lowerBound, typicalBand.upperBound] }
        values += bandPoints.flatMap { [$0.low, $0.high] }
        let yLayout = y.layout(for: values)

        self.lineMarks = lineMarks
        self.pointMarks = pointMarks
        self.dashedRuns = dashedRuns
        self.byDay = byDay
        self.drawsLines = !pointsOnly
        self.interpolation = interpolation
        self.typicalBand = typicalBand
        self.rollingBand = bandPoints
        let bandColor = bandColor ?? series.first?.color ?? StrandPalette.textTertiary
        self.bandColor = bandColor
        self.references = references
        self.xLayout = ChartAxis.layout(window, style: xStyle, calendar: calendar)
        self.yLayout = yLayout
        self.xs = byDay.keys.sorted()
        self.state = state
        self.height = height
        self.accessibilityTitle = accessibilityTitle
        self.calendar = calendar
        self._selection = selection

        let unitLabel = y.unit
        let format = y.format
        let multi = series.count > 1
        self.seriesNames = multi ? Dictionary(series.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }) : [:]
        self.format = format
        self.unit = unitLabel
        let allValues = windowed.flatMap { $0.1.map(\.value) }
        self.summary = NaraChartText.summary(
            title: accessibilityTitle, count: byDay.count, noun: .days,
            low: allValues.min().map { NaraChartText.value($0, format: format, unit: unitLabel) },
            high: allValues.max().map { NaraChartText.value($0, format: format, unit: unitLabel) })
        self.descriptor = NaraChartDescriptor(
            title: accessibilityTitle, summary: summary,
            xTitle: String(localized: "Date", bundle: .module), yTitle: unitLabel ?? accessibilityTitle,
            yRange: yLayout.domain,
            dateText: { NaraChartText.date($0, unit: .day, calendar: calendar) },
            valueText: { NaraChartText.value($0, format: format, unit: unitLabel) },
            series: windowed.map { line, points in
                .init(name: line.name, isContinuous: !pointsOnly, points: points.map { ($0.day, $0.value) })
            })

        if let legend {
            self.legend = legend
        } else {
            var automatic: [ChartLegendItem] = []
            if multi {
                automatic += series.map { ChartLegendItem(.line($0.color, dashed: false), $0.name) }
            }
            if typicalBand != nil || !bandPoints.isEmpty {
                automatic.append(ChartLegendItem(.band(bandColor), String(localized: "Typical range", bundle: .module)))
            }
            if let estimate = windowed.flatMap({ line, points in points.filter(\.isEstimate).map { _ in line.color } }).first {
                automatic.append(ChartLegendItem(.estimate(estimate), String(localized: "Estimate", bundle: .module)))
            }
            self.legend = automatic
        }
    }

    /// Blood oxygen (85...100 with a 95 % rule) and sleep efficiency (50...100 with an 85 % rule): a fixed
    /// scale, points, and a line only when `joined`.
    public static func fixedDomainPoints(_ points: [DailyPoint], domain: ClosedRange<Double>,
                                         reference: ChartReference?, color: Color, joined: Bool,
                                         cadence: ChartCadence = .daily, unit: String? = "%",
                                         ticks: [Double]? = nil,
                                         format: @escaping @Sendable (Double) -> String = ChartValueAxis.integer,
                                         legend: [ChartLegendItem]? = nil, state: ChartState = .ready,
                                         window: ClosedRange<Date>, xStyle: ChartAxisStyle,
                                         selection: Binding<Date?>,
                                         height: CGFloat = NoopMetrics.chartHeightPrimary,
                                         accessibilityTitle: String, calendar: Calendar = .current) -> DailyLineChart {
        DailyLineChart(series: [Series(id: "value", name: accessibilityTitle, color: color, points: points)],
                       cadence: cadence, marks: joined ? .pointsAndLine : .pointsOnly,
                       reference: reference, legend: legend, state: state, window: window, xStyle: xStyle,
                       y: ChartValueAxis(unit: unit, domain: .fixed(domain), ticks: ticks, format: format),
                       selection: selection, height: height, accessibilityTitle: accessibilityTitle,
                       calendar: calendar)
    }

    // MARK: Body

    private var selectedDay: Date? {
        selection.map { calendar.startOfDay(for: $0) }
    }

    public var body: some View {
        NaraChartFrame(state: state, height: height, legend: legend, accessibilityTitle: accessibilityTitle) {
            chart
        }
    }

    private var chart: some View {
        let selected = selectedDay
        return Chart {
            bandMarks
            NaraReferenceMarks(references: references, showsLabels: !compact)
            SelectionRule(selected, unit: .day)
            lineContent
            pointContent
            selectionPoints(selected)
        }
        .naraChartAxes(x: xLayout, y: yLayout, calendar: calendar)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection)
        }
        .naraChartRangeAnimation(xLayout.window)
        .naraChartAccessibility(title: accessibilityTitle, summary: summary, descriptor: descriptor, xs: xs,
                                selection: $selection,
                                describe: { [byDay, seriesNames, format, unit, calendar] date in
                                    let day = calendar.startOfDay(for: date)
                                    guard let marks = byDay[day] else { return nil }
                                    let parts = marks.map { mark -> String in
                                        let value = NaraChartText.value(mark.value, format: format, unit: unit)
                                        return seriesNames[mark.seriesID].map { "\($0) \(value)" } ?? value
                                    }
                                    return NaraChartText.reading(day, unit: .day, parts: parts,
                                                                 isEstimate: marks.contains(where: \.isEstimate),
                                                                 calendar: calendar)
                                })
    }

    @ChartContentBuilder
    private var bandMarks: some ChartContent {
        if let typicalBand {
            RectangleMark(xStart: .value("Start", xLayout.window.lowerBound),
                          xEnd: .value("End", xLayout.window.upperBound),
                          yStart: .value("Low", typicalBand.lowerBound),
                          yEnd: .value("High", typicalBand.upperBound))
                .foregroundStyle(bandColor.opacity(NaraChartStyle.bandOpacity))
        }
        ForEach(rollingBand) { point in
            AreaMark(x: .value("Day", point.day, unit: .day),
                     yStart: .value("Low", point.low),
                     yEnd: .value("High", point.high),
                     series: .value("Band", point.run))
                .interpolationMethod(interpolation.method)
                .foregroundStyle(bandColor.opacity(NaraChartStyle.bandOpacity))
        }
    }

    @ChartContentBuilder
    private var lineContent: some ChartContent {
        if drawsLines {
            ForEach(lineMarks) { mark in
                LineMark(x: .value("Day", mark.day, unit: .day),
                         y: .value("Value", mark.value),
                         series: .value("Run", mark.run))
                    .interpolationMethod(interpolation.method)
                    .lineStyle(dashedRuns.contains(mark.run) ? NaraChartStyle.estimateLine : NaraChartStyle.line)
                    .foregroundStyle(mark.color)
            }
        }
    }

    @ChartContentBuilder
    private var pointContent: some ChartContent {
        ForEach(pointMarks) { mark in
            PointMark(x: .value("Day", mark.day, unit: .day), y: .value("Value", mark.value))
                .symbol(NaraPointSymbol.shape(estimate: mark.isEstimate))
                .symbolSize(NaraChartStyle.pointSize)
                .foregroundStyle(mark.color)
        }
    }

    @ChartContentBuilder
    private func selectionPoints(_ selected: Date?) -> some ChartContent {
        if let selected, let marks = byDay[selected] {
            ForEach(marks) { mark in
                PointMark(x: .value("Day", mark.day, unit: .day), y: .value("Value", mark.value))
                    .symbol(NaraPointSymbol.shape(estimate: mark.isEstimate))
                    .symbolSize(NaraChartStyle.selectedPointSize)
                    .foregroundStyle(mark.color)
            }
        }
    }
}

/// The point symbol every chart uses: a filled circle, or a ring for an estimate.
enum NaraPointSymbol {
    static func shape(estimate: Bool) -> AnyChartSymbolShape {
        estimate
            ? AnyChartSymbolShape(BasicChartSymbolShape.circle.strokeBorder(lineWidth: NaraChartStyle.estimateStroke))
            : AnyChartSymbolShape(BasicChartSymbolShape.circle)
    }
}

#if DEBUG
private struct DailyLineChartPreview: View {
    @State private var selected: Date?
    var body: some View {
        NaraChartPreviewGallery("DailyLineChart") { sample in
            DailyLineChart(series: [.init(id: "hrv", name: "HRV", color: StrandPalette.metricCyan,
                                          points: sample.points(base: 64, swing: 18, estimateEvery: 11))],
                           typicalBand: 52...78, baseline: ChartReference(64, label: "Baseline 64"),
                           state: sample.state, window: sample.window, xStyle: sample.range.axisStyle,
                           y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                           selection: $selected, accessibilityTitle: "Heart rate variability")
            DailyLineChart.fixedDomainPoints(sample.points(base: 96, swing: 2), domain: 85...100,
                                             reference: ChartReference(95, label: "95 %"),
                                             color: StrandPalette.metricPurple, joined: false,
                                             state: sample.state, window: sample.window,
                                             xStyle: sample.range.axisStyle, selection: $selected,
                                             height: NoopMetrics.chartHeightSecondary,
                                             accessibilityTitle: "Blood oxygen")
        }
    }
}

#Preview("DailyLineChart · light") { DailyLineChartPreview().preferredColorScheme(.light) }
#Preview("DailyLineChart · dark") { DailyLineChartPreview().preferredColorScheme(.dark) }
#endif
#endif
