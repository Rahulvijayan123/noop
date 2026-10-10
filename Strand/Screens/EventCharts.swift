import SwiftUI
import Charts
import StrandDesign

// MARK: - Event charts
//
// Two views of physiology around an event:
// - `EventWindowChart`: the kit's `IntradayChart` in an event-window form. The window is the event's own
//   (before, during, after), the "during" span is a neutral band, the event time a dashed rule, the
//   "before" mean a labelled reference, and every reading is drawn where it was taken: the line passes
//   through each point (monotone segments, no midpoint smoothing) and breaks wherever a reading is
//   missing. The value axis is fitted, never zero-based, with its unit on top.
// - `EventRecoveryCurves`: this event's after-window against other events of the same kind, each as a
//   percentage of its own "before" mean, aligned at the moment the event ended. App-side Swift Charts on
//   the house axes, because the kit has no aligned-curves chart yet (listed for the kit owner).

/// Physiology around one event, on the kit's intraday chart.
struct EventWindowChart: View {
    let physiology: EventPhysiology
    let metric: PhysiologyMetric
    /// The event's own time (the dashed rule), which can sit inside the band.
    let eventDate: Date
    var compact: Bool = false
    var state: ChartState = .ready
    @Binding var selection: Date?

    /// The readings in time order, as the chart draws them.
    static func samples(_ metric: PhysiologyMetric) -> [IntradayChart.Sample] {
        metric.points.filter { $0.value.isFinite }.sorted { $0.time < $1.time }
            .map { IntradayChart.Sample(time: $0.time, value: $0.value) }
    }

    /// The series' cadence: the median step between readings (15 min in the sample, 5 min for strap
    /// buckets, irregular for motion-gated HRV windows), so a stretch with no reading breaks the line.
    static func cadenceSeconds(_ points: [PhysiologyPoint]) -> Int {
        let times = points.map(\.time).sorted()
        let steps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }.filter { $0 > 0 }.sorted()
        guard !steps.isEmpty else { return 300 }
        return max(1, Int(steps[steps.count / 2].rounded()))
    }

    private var hasBand: Bool { physiology.eventEnd > physiology.eventStart }

    /// The event time gets its own rule when it is not simply the start of the band (a point event, or a
    /// logged time inside the span).
    private var showsMarker: Bool {
        !hasBand || abs(eventDate.timeIntervalSince(physiology.eventStart)) > Double(Self.cadenceSeconds(metric.points))
    }

    var body: some View {
        let stats = EventPhaseStats(physiology: physiology, metric: metric)
        let before = stats.mean(.before)
        let neutral = StrandPalette.textTertiary
        let band: [IntradayChart.Band] = hasBand
            ? [IntradayChart.Band(id: "during", start: physiology.eventStart, end: physiology.eventEnd, color: neutral)]
            : []
        let markers: [IntradayChart.Marker] = showsMarker
            ? [IntradayChart.Marker(id: "event", time: eventDate, label: EventFormat.time(eventDate),
                                    color: StrandPalette.textSecondary)]
            : []
        let references = before.map {
            [ChartReference($0, label: String(localized: "Before \(EventFormat.value($0)) \(metric.unit)"))]
        } ?? []
        IntradayChart(samples: Self.samples(metric), bucketSeconds: metric.points.compactMap(\.supportSeconds).min().map(Int.init) ?? Self.cadenceSeconds(metric.points),
                      color: EventFormat.color(for: metric), interpolation: .monotone,
                      bands: band, markers: markers, references: references, compact: compact,
                      legend: hasBand && !compact ? [ChartLegendItem(.band(neutral), String(localized: "During"))] : [],
                      state: state, window: physiology.windowStart...physiology.windowEnd,
                      y: ChartValueAxis(unit: metric.unit, domain: .fitted(minSpan: EventFormat.minSpan)),
                      selection: $selection, accessibilityTitle: metric.name)
    }
}

/// This event's recovery against other events of the same kind: every curve is the metric as a percentage
/// of that event's own "before" mean, from the moment the event ended to the end of its window.
struct EventRecoveryCurves: View {
    struct Curve {
        struct Point {
            let offset: TimeInterval
            let percent: Double
            let run: Int
        }
        let id: String
        let points: [Point]
    }

    let title: String
    let current: Curve
    let others: [Curve]
    let color: Color
    @State private var selected: Date?

    /// x positions are seconds after the event ended, carried as dates from a fixed origin so the house
    /// axes and the kit's scrub can be reused; the labels are written here ("0 h", "1 h", ...).
    private static let origin = Date(timeIntervalSinceReferenceDate: 0)

    /// The aligned curve of `metricName` for one event, or nil without a usable "before" mean or with fewer
    /// than two readings after the event.
    static func curve(for event: HealthEvent, metricName: String) -> Curve? {
        guard let physiology = event.physiology,
              let metric = physiology.metrics.first(where: { $0.name == metricName }) else { return nil }
        let stats = EventPhaseStats(physiology: physiology, metric: metric)
        guard let base = stats.mean(.before), base > 0 else { return nil }
        let after = metric.points
            .filter { $0.value.isFinite && $0.time >= physiology.eventEnd && $0.time <= physiology.windowEnd }
            .sorted { $0.time < $1.time }
        guard after.count >= 2 else { return nil }
        let limit = Double(EventWindowChart.cadenceSeconds(metric.points)) * 1.5
        var run = 0
        var points: [Curve.Point] = []
        for (index, point) in after.enumerated() {
            if index > 0, point.time.timeIntervalSince(after[index - 1].time) > limit { run += 1 }
            points.append(Curve.Point(offset: point.time.timeIntervalSince(physiology.eventEnd),
                                      percent: point.value / base * 100, run: run))
        }
        return Curve(id: event.id, points: points)
    }

    private struct Mark: Identifiable {
        let id: String
        let x: Date
        let y: Double
        let series: String
    }

    private var horizon: TimeInterval {
        max(3600, current.points.map(\.offset).max() ?? 3600)
    }

    private var xLayout: ChartXAxisLayout {
        let window = Self.origin...Self.origin.addingTimeInterval(horizon)
        let hours = Int((horizon / 3600).rounded(.down))
        let marks = (0...hours).map { Self.origin.addingTimeInterval(Double($0) * 3600) }
        let labels = (0...hours).map { String(localized: "\($0) h") }
        let anchors: [ChartAxisLabelAnchor] = marks.indices.map { index in
            if index == 0 { return .leading }
            if index == marks.count - 1, marks[index] >= window.upperBound.addingTimeInterval(-600) { return .trailing }
            return .center
        }
        return ChartXAxisLayout(window: window, style: .hours, marks: marks, labels: labels, anchors: anchors, grid: marks)
    }

    private var yLayout: ChartYAxisLayout {
        let curves: [Curve] = [current] + others
        let values: [Double] = curves.flatMap { curve in curve.points.map(\.percent) } + [100]
        return ChartValueAxis(unit: "%", domain: .fitted(minSpan: 40)).layout(for: values)
    }

    private var currentMarks: [Mark] {
        current.points.map { Mark(id: "c\($0.offset)", x: Self.origin.addingTimeInterval($0.offset), y: $0.percent,
                                  series: "this#\($0.run)") }
    }

    private var otherMarks: [Mark] {
        others.flatMap { curve in
            curve.points.map { Mark(id: "\(curve.id)-\($0.offset)", x: Self.origin.addingTimeInterval($0.offset),
                                    y: $0.percent, series: "\(curve.id)#\($0.run)") }
        }
    }

    /// The other events' median at the offset nearest `offset` (each event's nearest reading within half an
    /// hour), or nil when none has one there.
    private func othersMedian(at offset: TimeInterval) -> Double? {
        let values = others.compactMap { curve -> Double? in
            guard let near = curve.points.min(by: { abs($0.offset - offset) < abs($1.offset - offset) }),
                  abs(near.offset - offset) <= 1800 else { return nil }
            return near.percent
        }.sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count % 2 == 0 ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }

    private var line: String {
        if let selected, let index = ChartSelection.nearestIndex(to: selected, in: currentMarks.map(\.x)) {
            let point = current.points[index]
            let after = EventFormat.duration(point.offset)
            var parts = [String(localized: "\(after) after"),
                         String(localized: "this one \(EventFormat.value(point.percent)) %")]
            if let median = othersMedian(at: point.offset) {
                parts.append(String(localized: "others \(EventFormat.value(median)) %"))
            }
            return parts.joined(separator: " · ")
        }
        let count = others.count == 1 ? String(localized: "1 other") : String(localized: "\(others.count) others")
        return "\(title) · \(count)"
    }

    var body: some View {
        let current = currentMarks
        let selectedIndex = selected.flatMap { ChartSelection.nearestIndex(to: $0, in: current.map(\.x)) }
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text("Compared with other times")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(verbatim: line)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .transaction { $0.animation = nil }
                }
                Chart {
                    RuleMark(y: .value("Before", 100))
                        .lineStyle(NaraChartStyle.reference)
                        .foregroundStyle(NaraChartStyle.referenceColor)
                    SelectionRule(selectedIndex.map { current[$0].x }, unit: nil)
                    ForEach(otherMarks) { mark in
                        LineMark(x: .value("After", mark.x), y: .value("Percent", mark.y),
                                 series: .value("Event", mark.series))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(StrandPalette.textTertiary.opacity(0.7))
                    }
                    ForEach(current) { mark in
                        LineMark(x: .value("After", mark.x), y: .value("Percent", mark.y),
                                 series: .value("Event", mark.series))
                            .interpolationMethod(.monotone)
                            .lineStyle(NaraChartStyle.line)
                            .foregroundStyle(color)
                    }
                    if let index = selectedIndex {
                        PointMark(x: .value("After", current[index].x), y: .value("Percent", current[index].y))
                            .symbolSize(NaraChartStyle.selectedPointSize)
                            .foregroundStyle(color)
                    }
                }
                .naraChartAxes(x: xLayout, y: yLayout)
                .chartScrub(xs: current.map(\.x), selection: $selected)
                .frame(height: NoopMetrics.chartHeightSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Compared with other times"))
                .accessibilityValue(Text(verbatim: summary))
                ChartLegend([ChartLegendItem(.line(color, dashed: false), String(localized: "This one")),
                             ChartLegendItem(.line(StrandPalette.textTertiary, dashed: false), String(localized: "Others")),
                             ChartLegendItem(.line(NaraChartStyle.referenceColor, dashed: true), String(localized: "Before"))])
            }
        }
    }

    private var summary: String {
        guard let last = current.points.last else { return "" }
        var text = String(localized: "This one \(EventFormat.value(last.percent)) % of before \(EventFormat.duration(last.offset)) after")
        if let median = othersMedian(at: last.offset) {
            text += ", " + String(localized: "others \(EventFormat.value(median)) %")
        }
        return text
    }
}
