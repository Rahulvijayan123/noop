#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - IntradayChart

/// A line through the day on a clock axis: heart rate through the day, 5-minute skin temperature, stress
/// through the waking day, physiology around an event, the live trace.
///
/// - The line breaks wherever a bucket is skipped (the `hrGapSegments` rule): an hour the strap was off is
///   empty, not a straight line across it. A bucket alone between two gaps is drawn as a point.
/// - Spans of the day (sleep, a workout, an event, off-wrist time) are bands behind the line, with a label;
///   `hatched` bands are hatched, for time with no trustworthy signal.
/// - `valueBands` shade ranges of the value axis (stress Low/Medium/High, heart-rate zones); `markers` are
///   labelled vertical rules at a moment (wake, a dose, an alert).
/// - Long series are downsampled for drawing after the gaps are found on the full series.
/// - `compact` is the small-card form (no value labels, fewer time labels, no legend or band labels).
///   `live` puts the "now" cap on the latest sample and turns off the range animation, which would
///   otherwise replay on every new second as the window slides.
///
/// There is no zoom or pan here; the Deep Timeline keeps `OverviewHRChart` for that.
///
/// ```swift
/// IntradayChart(samples: buckets.map { .init(time: $0.start, value: $0.bpm) }, bucketSeconds: 300,
///               bands: [.init(id: "sleep", start: onset, end: wake, color: StrandPalette.restColor, label: "Asleep")],
///               window: midnight...now, y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)),
///               selection: $selected, accessibilityTitle: "Heart rate")
/// ```
public struct IntradayChart: View {

    public struct Sample: Identifiable, Sendable {
        public var time: Date
        public var value: Double
        /// The bucket's low and high, drawn as a faint envelope around the line when both are present.
        public var low: Double?
        public var high: Double?
        /// A stretch made only of estimated samples is drawn dashed.
        public var isEstimate: Bool
        public var id: Date { time }

        public init(time: Date, value: Double, low: Double? = nil, high: Double? = nil, isEstimate: Bool = false) {
            self.time = time
            self.value = value
            self.low = low
            self.high = high
            self.isEstimate = isEstimate
        }
    }

    /// A span of the day behind the line.
    public struct Band: Identifiable, Sendable {
        public var id: String
        public var start: Date
        public var end: Date
        public var color: Color
        public var label: String?
        /// Hatched instead of filled: time without a trustworthy signal (off wrist, moving).
        public var hatched: Bool

        public init(id: String, start: Date, end: Date, color: Color, label: String? = nil, hatched: Bool = false) {
            self.id = id
            self.start = start
            self.end = end
            self.color = color
            self.label = label
            self.hatched = hatched
        }
    }

    /// A shaded range of the value axis across the whole window.
    public struct ValueBand: Identifiable, Sendable {
        public var id: String
        public var range: ClosedRange<Double>
        public var color: Color
        public var label: String?

        public init(id: String, range: ClosedRange<Double>, color: Color, label: String? = nil) {
            self.id = id
            self.range = range
            self.color = color
            self.label = label
        }
    }

    /// A labelled vertical rule at a moment.
    public struct Marker: Identifiable, Sendable {
        public var id: String
        public var time: Date
        public var label: String
        public var color: Color

        public init(id: String, time: Date, label: String, color: Color) {
            self.id = id
            self.time = time
            self.label = label
            self.color = color
        }
    }

    struct LinePoint: Identifiable {
        let time: Date
        let value: Double
        let run: String
        var id: Date { time }
    }

    struct EnvelopePoint: Identifiable {
        let time: Date
        let low: Double
        let high: Double
        let run: String
        var id: Date { time }
    }

    private let line: [LinePoint]
    private let dashedRuns: Set<String>
    private let isolated: [LinePoint]
    private let envelope: [EnvelopePoint]
    private let times: [Date]
    private let values: [Double]
    private let color: Color
    private let interpolation: ChartInterpolation
    private let bands: [Band]
    private let valueBands: [ValueBand]
    private let markers: [Marker]
    private let references: [ChartReference]
    private let compact: Bool
    private let live: Bool
    private let xLayout: ChartXAxisLayout
    private let yLayout: ChartYAxisLayout
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
    @Environment(\.naraChartCompact) private var inheritedCompact

    /// - Parameters:
    ///   - bucketSeconds: the series' bucket size; a step longer than one bucket is a gap.
    ///   - height: nil for `chartHeightCompact` when `compact`, else `chartHeightPrimary`.
    public init(samples: [Sample], bucketSeconds: Int, color: Color = StrandPalette.metricRose,
                interpolation: ChartInterpolation = .monotone,
                bands: [Band] = [], valueBands: [ValueBand] = [], markers: [Marker] = [],
                references: [ChartReference] = [], compact: Bool = false, live: Bool = false,
                legend: [ChartLegendItem]? = nil, state: ChartState = .ready,
                window: ClosedRange<Date>, y: ChartValueAxis, selection: Binding<Date?>,
                height: CGFloat? = nil, accessibilityTitle: String, calendar: Calendar = .current) {
        let windowed = samples.filter { $0.value.isFinite && window.contains($0.time) }.sorted { $0.time < $1.time }
        let runs = ChartGaps.runs(windowed.map(\.time), series: windowed.map { _ in "line" },
                                  cadence: .buckets(seconds: max(1, bucketSeconds)), calendar: calendar)
        let all = zip(windowed, runs).map { LinePoint(time: $0.time, value: $0.value, run: $1) }
        var runCounts: [String: Int] = [:]
        var runEstimates: [String: Bool] = [:]
        for (sample, run) in zip(windowed, runs) {
            runCounts[run, default: 0] += 1
            runEstimates[run] = (runEstimates[run] ?? true) && sample.isEstimate
        }

        let envelope: [EnvelopePoint] = zip(windowed, runs).compactMap { sample, run in
            guard let low = sample.low, let high = sample.high, low.isFinite, high.isFinite else { return nil }
            return EnvelopePoint(time: sample.time, low: min(low, high), high: max(low, high), run: run)
        }
        let yLayout = y.layout(for: windowed.map(\.value) + envelope.flatMap { [$0.low, $0.high] } + references.map(\.value))
        let domain = yLayout.domain

        self.line = ChartDownsample.minMaxBucketed(all, threshold: ChartDownsample.markThreshold,
                                                   targetCount: ChartDownsample.targetVertices,
                                                   date: \.time, value: \.value)
        self.dashedRuns = Set(runEstimates.filter(\.value).keys)
        self.isolated = all.filter { runCounts[$0.run] == 1 }
        self.envelope = ChartDownsample.minMaxBucketed(envelope, threshold: ChartDownsample.markThreshold,
                                                       targetCount: ChartDownsample.targetVertices,
                                                       date: \.time, value: \.high)
        self.times = windowed.map(\.time)
        self.values = windowed.map(\.value)
        self.color = color
        self.interpolation = interpolation
        self.bands = bands.compactMap { band in
            let start = max(band.start, window.lowerBound)
            let end = min(band.end, window.upperBound)
            guard end > start else { return nil }
            var clipped = band
            clipped.start = start
            clipped.end = end
            return clipped
        }
        self.valueBands = valueBands.compactMap { band in
            let low = max(band.range.lowerBound, domain.lowerBound)
            let high = min(band.range.upperBound, domain.upperBound)
            guard high > low else { return nil }
            var clipped = band
            clipped.range = low...high
            return clipped
        }
        self.markers = markers.filter { window.contains($0.time) }
        self.references = references
        self.compact = compact
        self.live = live
        self.xLayout = ChartAxis.layout(window, style: .hours, target: compact ? 4 : nil, calendar: calendar)
        self.yLayout = yLayout
        self.state = state
        self.height = height ?? (compact ? NoopMetrics.chartHeightCompact : NoopMetrics.chartHeightPrimary)
        self.accessibilityTitle = accessibilityTitle
        self.format = y.format
        self.unit = y.unit
        self.calendar = calendar
        self._selection = selection

        let format = y.format
        let unitLabel = y.unit
        let valueText: (Double) -> String = { NaraChartText.value($0, format: format, unit: unitLabel) }
        if let first = windowed.first, let last = windowed.last,
           let low = windowed.map(\.value).min(), let high = windowed.map(\.value).max() {
            let span = String(localized: "\(NaraChartText.date(first.time, unit: nil, calendar: calendar)) to \(NaraChartText.date(last.time, unit: nil, calendar: calendar))", bundle: .module)
            self.summary = low == high
                ? "\(accessibilityTitle), \(span), \(valueText(low))"
                : String(localized: "\(accessibilityTitle), \(span), \(valueText(low)) to \(valueText(high))", bundle: .module)
        } else {
            self.summary = String(localized: "\(accessibilityTitle), no data", bundle: .module)
        }
        let spoken = ChartDownsample.minMaxBucketed(all, threshold: ChartDownsample.markThreshold,
                                                    targetCount: ChartDownsample.targetVertices,
                                                    date: \.time, value: \.value)
        self.descriptor = NaraChartDescriptor(
            title: accessibilityTitle, summary: summary,
            xTitle: String(localized: "Time", bundle: .module), yTitle: unitLabel ?? accessibilityTitle,
            yRange: domain,
            dateText: { NaraChartText.date($0, unit: nil, calendar: calendar) },
            valueText: valueText,
            series: [.init(name: accessibilityTitle, isContinuous: true, points: spoken.map { ($0.time, $0.value) })])

        if let legend {
            self.legend = legend
        } else {
            var automatic: [ChartLegendItem] = []
            var seen: Set<String> = []
            for band in bands {
                guard let label = band.label, !seen.contains(label) else { continue }
                seen.insert(label)
                automatic.append(ChartLegendItem(band.hatched ? .hatched(band.color) : .band(band.color), label))
            }
            self.legend = automatic.count > 1 ? automatic : []
        }
    }

    // MARK: Body

    public var body: some View {
        let isCompact = compact || inheritedCompact
        NaraChartFrame(state: state, height: height, legend: legend, accessibilityTitle: accessibilityTitle) {
            chart(compact: isCompact)
        }
        .environment(\.naraChartCompact, isCompact)
    }

    private func chart(compact: Bool) -> some View {
        let selectedIndex = selection.flatMap { ChartSelection.nearestIndex(to: $0, in: times) }
        let base = Chart {
            valueBandMarks(showsLabels: !compact)
            bandMarks(showsLabels: !compact)
            NaraReferenceMarks(references: references, showsLabels: !compact)
            markerMarks(showsLabels: !compact)
            SelectionRule(selectedIndex.map { times[$0] }, unit: nil)
            envelopeMarks
            lineMarks
            if let index = selectedIndex {
                PointMark(x: .value("Time", times[index]), y: .value("Value", values[index]))
                    .symbolSize(NaraChartStyle.selectedPointSize)
                    .foregroundStyle(color)
            }
        }
        .naraChartAxes(x: xLayout, y: yLayout, calendar: calendar)
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    hatches(proxy: proxy, plot: plot)
                    if live, let time = times.last, let value = values.last,
                       let x = proxy.position(forX: time), let y = proxy.position(forY: value) {
                        NowCapDot(color: color)
                            .position(x: plot.minX + x, y: plot.minY + y)
                    }
                    ChartScrubLayer(proxy: proxy, xs: times, selection: $selection)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .naraChartAccessibility(title: accessibilityTitle, summary: summary, descriptor: descriptor, xs: times,
                                selection: $selection,
                                describe: { [times, values, format, unit, calendar] time in
                                    guard let index = ChartSelection.nearestIndex(to: time, in: times) else { return nil }
                                    return "\(NaraChartText.date(times[index], unit: nil, calendar: calendar)), \(NaraChartText.value(values[index], format: format, unit: unit))"
                                })
        return Group {
            if live {
                base
            } else {
                base.naraChartRangeAnimation(xLayout.window)
            }
        }
    }

    @ChartContentBuilder
    private func valueBandMarks(showsLabels: Bool) -> some ChartContent {
        ForEach(valueBands) { band in
            RectangleMark(xStart: .value("Start", xLayout.window.lowerBound),
                          xEnd: .value("End", xLayout.window.upperBound),
                          yStart: .value("Low", band.range.lowerBound),
                          yEnd: .value("High", band.range.upperBound))
                .foregroundStyle(band.color.opacity(NaraChartStyle.bandOpacity * 0.7))
                .annotation(position: .overlay, alignment: .trailing) {
                    if showsLabels, let label = band.label {
                        Text(label)
                            .font(StrandFont.footnote)
                            .foregroundStyle(band.color)
                            .fixedSize()
                            .padding(.trailing, 4)
                    }
                }
        }
    }

    @ChartContentBuilder
    private func bandMarks(showsLabels: Bool) -> some ChartContent {
        ForEach(bands) { band in
            RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end))
                .foregroundStyle(band.color.opacity(band.hatched ? NaraChartStyle.bandOpacity * 0.5 : NaraChartStyle.bandOpacity))
                .annotation(position: .overlay, alignment: .topLeading) {
                    // An overlay annotation is offered the mark's own width; a narrow band would squeeze its label
                    // to nothing, so the label keeps its own size and may run past the band.
                    if showsLabels, let label = band.label {
                        Text(label)
                            .font(StrandFont.footnote)
                            .foregroundStyle(band.color)
                            .fixedSize()
                            .padding(.leading, 4)
                            .padding(.top, 2)
                    }
                }
        }
    }

    @ChartContentBuilder
    private func markerMarks(showsLabels: Bool) -> some ChartContent {
        ForEach(markers) { marker in
            RuleMark(x: .value("Time", marker.time))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .foregroundStyle(marker.color)
                .annotation(position: .overlay, alignment: .top) {
                    if showsLabels {
                        Text(marker.label)
                            .font(StrandFont.footnote)
                            .foregroundStyle(marker.color)
                            .fixedSize()
                            .padding(.horizontal, 4)
                            .background(StrandPalette.surfaceRaised.opacity(0.9),
                                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }
        }
    }

    @ChartContentBuilder
    private var envelopeMarks: some ChartContent {
        ForEach(envelope) { point in
            AreaMark(x: .value("Time", point.time),
                     yStart: .value("Low", point.low),
                     yEnd: .value("High", point.high),
                     series: .value("Run", point.run))
                .interpolationMethod(interpolation.method)
                .foregroundStyle(color.opacity(0.15))
        }
    }

    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        ForEach(line) { point in
            LineMark(x: .value("Time", point.time), y: .value("Value", point.value), series: .value("Run", point.run))
                .interpolationMethod(interpolation.method)
                .lineStyle(dashedRuns.contains(point.run) ? NaraChartStyle.estimateLine : NaraChartStyle.line)
                .foregroundStyle(color)
        }
        ForEach(isolated) { point in
            PointMark(x: .value("Time", point.time), y: .value("Value", point.value))
                .symbolSize(NaraChartStyle.pointSize)
                .foregroundStyle(color)
        }
    }

    /// Hatching for the `hatched` bands, drawn in the overlay because a chart mark cannot take a pattern.
    @ViewBuilder
    private func hatches(proxy: ChartProxy, plot: CGRect) -> some View {
        ForEach(bands.filter(\.hatched)) { band in
            if let x0 = proxy.position(forX: band.start), let x1 = proxy.position(forX: band.end), x1 > x0 {
                DiagonalHatch(spacing: 5)
                    .stroke(band.color.opacity(0.35), lineWidth: 1)
                    .frame(width: x1 - x0, height: plot.height)
                    .clipped()
                    .position(x: plot.minX + (x0 + x1) / 2, y: plot.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

#if DEBUG
private struct IntradayChartPreview: View {
    @State private var selected: Date?
    var body: some View {
        NaraChartPreviewGallery("IntradayChart", intraday: true) { sample in
            let day = sample.dayWindow
            IntradayChart(samples: sample.heartRate(), bucketSeconds: 300,
                          bands: [.init(id: "sleep", start: day.lowerBound, end: day.lowerBound.addingTimeInterval(7 * 3600),
                                        color: StrandPalette.restColor, label: "Asleep"),
                                  .init(id: "off", start: day.lowerBound.addingTimeInterval(13 * 3600),
                                        end: day.lowerBound.addingTimeInterval(14 * 3600),
                                        color: StrandPalette.textTertiary, label: "Off wrist", hatched: true)],
                          markers: [.init(id: "wake", time: day.lowerBound.addingTimeInterval(7 * 3600),
                                          label: "Woke", color: StrandPalette.textSecondary)],
                          references: [ChartReference(56, label: "Resting 56")],
                          state: sample.state, window: day,
                          y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)),
                          selection: $selected, accessibilityTitle: "Heart rate")
            IntradayChart(samples: sample.heartRate(), bucketSeconds: 300, compact: true, live: true,
                          state: sample.state, window: day,
                          y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)),
                          selection: $selected, accessibilityTitle: "Heart rate today")
        }
    }
}

#Preview("IntradayChart · light") { IntradayChartPreview().preferredColorScheme(.light) }
#Preview("IntradayChart · dark") { IntradayChartPreview().preferredColorScheme(.dark) }
#endif
#endif
