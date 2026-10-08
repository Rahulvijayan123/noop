#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - StepLineChart

/// A value held until the next reading: VO2 max, fitness age, vitality, body age. A step says "this was the
/// estimate until the next one", where a sloped line would claim a gradual change nobody measured. A point
/// marks each reading; estimated readings are hollow.
///
/// The latest value is held on to the end of the window (today) when the reading is recent enough for the
/// cadence; an older reading's step ends at the reading, so a stale estimate is not drawn as current.
///
/// ```swift
/// StepLineChart(points: weekly, color: StrandPalette.chargeColor,
///               reference: ChartReference(Double(age), label: "Your age"),
///               window: window, xStyle: range.axisStyle,
///               y: ChartValueAxis(unit: "yrs", domain: .fitted(minSpan: 6)),
///               selection: $selected, accessibilityTitle: "Fitness age")
/// ```
public struct StepLineChart: View {
    struct Step: Identifiable {
        let id: String
        let day: Date
        let value: Double
        let run: String
    }

    struct Reading: Identifiable {
        let day: Date
        let value: Double
        let isEstimate: Bool
        var id: Date { day }
    }

    private let steps: [Step]
    private let readings: [Reading]
    private let dashedRuns: Set<String>
    private let color: Color
    private let references: [ChartReference]
    private let referenceAnchors: [ChartAxisLabelAnchor]
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
    ///   - cadence: where the step breaks (`.sparse(maxGapDays: 42)`: six weeks without a reading).
    ///   - reference: a labelled rule, such as chronological age.
    ///   - holdsLatest: carry the latest step to today while it is within the cadence.
    public init(points: [DailyPoint], cadence: ChartCadence = .sparse(maxGapDays: 42), color: Color,
                reference: ChartReference? = nil, holdsLatest: Bool = true,
                legend: [ChartLegendItem]? = nil, state: ChartState = .ready,
                window: ClosedRange<Date>, xStyle: ChartAxisStyle, y: ChartValueAxis,
                selection: Binding<Date?>, height: CGFloat = NoopMetrics.chartHeightPrimary,
                accessibilityTitle: String, calendar: Calendar = .current) {
        let windowed = points.filter { $0.value.isFinite }.inWindow(window)
        let runs = ChartGaps.runs(windowed.map(\.day), series: windowed.map(\.series), cadence: cadence, calendar: calendar)
        var steps = zip(windowed, runs).map { point, run in
            Step(id: "\(point.day.timeIntervalSince1970)", day: point.day, value: point.value, run: run)
        }
        var estimateRuns: [String: Bool] = [:]
        for (point, run) in zip(windowed, runs) {
            estimateRuns[run] = (estimateRuns[run] ?? true) && point.isEstimate
        }
        if holdsLatest, let last = steps.last {
            let today = calendar.startOfDay(for: window.upperBound.addingTimeInterval(-1))
            let age = ChartDay.daysBetween(last.day, today, calendar: calendar)
            if age > 0, age <= ChartGaps.maxGapDays(cadence) {
                steps.append(Step(id: "held", day: today, value: last.value, run: last.run))
            }
        }
        let references = reference.map { [$0] } ?? []
        let yLayout = y.layout(for: windowed.map(\.value) + references.map(\.value))

        self.steps = steps
        self.readings = windowed.map { Reading(day: $0.day, value: $0.value, isEstimate: $0.isEstimate) }
        self.dashedRuns = Set(estimateRuns.filter(\.value).keys)
        self.color = color
        self.references = references
        self.referenceAnchors = NaraReferenceLabelPlacement.anchors(
            for: references,
            marks: steps.map { .init(x: ChartDay.center(of: $0.day, calendar: calendar), low: $0.value, high: $0.value) },
            window: window, domain: yLayout.domain)
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
            series: [.init(name: accessibilityTitle, isContinuous: true, points: windowed.map { ($0.day, $0.value) })])

        if let legend {
            self.legend = legend
        } else if windowed.contains(where: \.isEstimate) {
            self.legend = [ChartLegendItem(.estimate(color), String(localized: "Estimate", bundle: .module))]
        } else {
            self.legend = []
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
            NaraReferenceMarks(references: references)
            SelectionRule(selected, unit: .day)
            ForEach(steps) { step in
                LineMark(x: .value("Day", step.day, unit: .day),
                         y: .value("Value", step.value),
                         series: .value("Run", step.run))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(dashedRuns.contains(step.run) ? NaraChartStyle.estimateLine : NaraChartStyle.line)
                    .foregroundStyle(color)
            }
            ForEach(readings) { reading in
                PointMark(x: .value("Day", reading.day, unit: .day), y: .value("Value", reading.value))
                    .symbol(NaraPointSymbol.shape(estimate: reading.isEstimate))
                    .symbolSize(selected == reading.day ? NaraChartStyle.selectedPointSize : NaraChartStyle.pointSize * 1.5)
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
private struct StepLineChartPreview: View {
    @State private var selected: Date?
    var body: some View {
        NaraChartPreviewGallery("StepLineChart") { sample in
            StepLineChart(points: sample.points(base: 44, swing: 3, every: 7, estimateEvery: 2),
                          color: StrandPalette.chargeColor, reference: ChartReference(46, label: "Your age"),
                          state: sample.state, window: sample.window, xStyle: sample.range.axisStyle,
                          y: ChartValueAxis(unit: "yrs", domain: .fitted(minSpan: 6)),
                          selection: $selected, accessibilityTitle: "Fitness age")
        }
    }
}

#Preview("StepLineChart · light") { StepLineChartPreview().preferredColorScheme(.light) }
#Preview("StepLineChart · dark") { StepLineChartPreview().preferredColorScheme(.dark) }
#endif
#endif
