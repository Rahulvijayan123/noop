import SwiftUI
import Charts
import StrandDesign

/// The key-metric screen's one history chart.
///
/// Each run of consecutive measured nights or days is its own line (`KeyMetricHistory.runs`), so a period with no
/// reading is a gap rather than a line drawn across it, and nothing is ever plotted at zero that was not measured
/// as zero. A reading with no measured neighbour is drawn as a dot. Dragging sideways (hovering on the Mac) selects
/// a period and the readout above the plot shows its value and date; at rest the readout says how many periods in
/// the range were measured.
struct KeyMetricHistoryChart: View {
    /// The window's readings, ascending.
    let readings: [KeyMetricHistory.Reading]
    /// The calendar days the range spans (`KeyMetricHistory.domain`).
    let domain: ClosedRange<Date>
    let tint: Color
    /// The value as text, with the reader's unit preferences (`KeyMetricFormatter.text`).
    let format: (Double) -> String
    /// Where a value sits on the value axis (`KeyMetricFormatter.plotted`): the axis labels are plain numbers, so a
    /// value shown in another unit than it is stored in is plotted in the shown one.
    var plotValue: (Double) -> Double = { $0 }
    /// The least air above and below the readings, in plotted units (`MetricInsightMetric.minimumPad`).
    var minimumPad: Double = 3
    /// Nights or days, for the captions and VoiceOver.
    var period: MetricInsightPeriod = .night
    /// The metric's name, for VoiceOver.
    let metricTitle: String
    var height: CGFloat = NoopMetrics.chartHeight

    @State private var selectedDay: String?

    private struct Mark: Identifiable {
        let reading: KeyMetricHistory.Reading
        let run: String
        /// No measured neighbour on either side, so the run is a single point.
        let isolated: Bool
        var id: String { reading.day }
    }

    private var marks: [Mark] {
        KeyMetricHistory.runs(readings).enumerated().flatMap { index, run in
            run.map { Mark(reading: $0, run: "run-\(index)", isolated: run.count == 1) }
        }
    }

    /// Dots on every reading while they can be told apart; past that only lone readings get one.
    private var showsAllDots: Bool { readings.count <= 45 }

    private var selected: KeyMetricHistory.Reading? {
        guard let selectedDay else { return nil }
        return readings.first { $0.day == selectedDay }
    }

    private static let utc: Calendar = PhysiologyContextDates.calendar

    /// Half a day of air either side so the first and last dots are not clipped by the plot edge.
    private var plotDomain: ClosedRange<Date> {
        domain.lowerBound.addingTimeInterval(-43_200)...domain.upperBound.addingTimeInterval(43_200)
    }

    private var axisDays: [Date] {
        ChartAxisDays.spanning([domain.lowerBound, domain.upperBound], targetLabels: 4, calendar: Self.utc)
    }

    private var spansYears: Bool {
        Self.utc.component(.year, from: domain.lowerBound) != Self.utc.component(.year, from: domain.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            readout
            chart
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(metricTitle) history"))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text(KeyMetricCopy.adjustHint(period)))
        .accessibilityAdjustableAction { direction in
            moveSelection(direction == .increment ? 1 : -1)
        }
        .onChangeCompat(of: readings.map(\.day)) { _ in selectedDay = nil }
    }

    // MARK: Readout

    private var measuredCaption: String {
        KeyMetricCopy.measured(readings.count, of: KeyMetricHistory.dayCount(domain), period)
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            if let selected {
                Text(format(selected.value))
                    .font(StrandFont.number(17))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(KeyMetricDates.short(selected.date, includeYear: spansYears))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text(measuredCaption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .frame(minHeight: 24, alignment: .leading)
    }

    // MARK: Plot

    private var chart: some View {
        let marks = self.marks
        let showsAllDots = self.showsAllDots
        let axis = KeyMetricCopy.axis(period)
        return Chart {
            ForEach(marks) { m in
                LineMark(x: .value(axis, m.reading.date), y: .value("Value", plotValue(m.reading.value)),
                         series: .value("Run", m.run))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                if showsAllDots || m.isolated {
                    PointMark(x: .value(axis, m.reading.date), y: .value("Value", plotValue(m.reading.value)))
                        .foregroundStyle(tint)
                        .symbolSize(showsAllDots ? 22 : 30)
                }
            }
            if let selected {
                RuleMark(x: .value(axis, selected.date))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value(axis, selected.date), y: .value("Value", plotValue(selected.value)))
                    .foregroundStyle(tint)
                    .symbolSize(90)
            }
        }
        .chartXScale(domain: plotDomain)
        .modifier(ValueScale(domain: KeyMetricHistory.valueDomain(readings.map { plotValue($0.value) },
                                                                  minimumPad: minimumPad)))
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: axisDays) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.5))
                if let date = value.as(Date.self) {
                    // A label on the range's first or last day is anchored inward so it is never cut off at the
                    // plot edge (the newest day is always marked).
                    AxisValueLabel(anchor: date == domain.upperBound ? .topTrailing
                                   : date == domain.lowerBound ? .topLeading : nil) {
                        Text(KeyMetricDates.format(date, template: ChartAxisDays.needsYear(axisDays, calendar: Self.utc)
                                                       ? "MMMdyy" : "MMMd"))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.5))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                scrubSurface(proxy: proxy, plot: plot)
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location): select(x: location.x, proxy: proxy, plot: plot)
                        case .ended: selectedDay = nil
                        }
                    }
            }
        }
        .frame(height: height)
    }

    /// The touch surface over the plot. On iOS the chart sits inside a vertical scroll view, so only a sideways drag
    /// may scrub and anything else reaches the page (`HorizontalScrubSurface`). The Mac scrubs on hover, or on a
    /// press-and-drag.
    @ViewBuilder
    private func scrubSurface(proxy: ChartProxy, plot: CGRect) -> some View {
        #if os(iOS)
        HorizontalScrubSurface(
            onScrub: { select(x: $0, proxy: proxy, plot: plot) },
            onEnd: { selectedDay = nil }
        )
        #else
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.15)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { state in
                        if case .second(true, let drag?) = state {
                            select(x: drag.location.x, proxy: proxy, plot: plot)
                        }
                    }
                    .onEnded { _ in selectedDay = nil }
            )
        #endif
    }

    private func select(x: CGFloat, proxy: ChartProxy, plot: CGRect) {
        guard plot.width > 0 else { return }
        let clamped = min(max(x, plot.minX), plot.maxX)
        guard let date: Date = proxy.value(atX: clamped - plot.minX) else { return }
        let nearest = readings.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        if nearest?.day != selectedDay { selectedDay = nearest?.day }
    }

    // MARK: Accessibility

    private var accessibilityValue: String {
        if let selected {
            return "\(format(selected.value)), \(KeyMetricDates.short(selected.date, includeYear: spansYears))"
        }
        guard let last = readings.last else { return measuredCaption }
        return "\(measuredCaption). \(format(last.value)), \(KeyMetricDates.short(last.date, includeYear: spansYears))"
    }

    /// VoiceOver's adjustable action steps through the readings (starting from the latest).
    private func moveSelection(_ step: Int) {
        guard !readings.isEmpty else { return }
        let current = selectedDay.flatMap { day in readings.firstIndex { $0.day == day } } ?? readings.count
        let next = min(max(current + step, 0), readings.count - 1)
        selectedDay = readings[next].day
    }
}

/// The y scale when the window has values; Swift Charts' own otherwise.
private struct ValueScale: ViewModifier {
    let domain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content
        }
    }
}
