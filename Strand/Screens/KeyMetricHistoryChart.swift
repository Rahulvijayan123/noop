import SwiftUI
import Charts
import StrandDesign

/// The key-metric screen's one history chart.
///
/// Each run of consecutive measured nights is its own line (`KeyMetricHistory.runs`), so a night with no reading is
/// a gap rather than a line drawn across it, and nothing is ever plotted at zero. A night with no measured
/// neighbour is drawn as a dot. Dragging sideways (hovering on the Mac) selects a night and the readout above the
/// plot shows its value and date; at rest the readout says how many nights in the range were measured.
struct KeyMetricHistoryChart: View {
    /// The window's measured nights, ascending.
    let nights: [KeyMetricHistory.Night]
    /// The calendar days the range spans (`KeyMetricHistory.domain`).
    let domain: ClosedRange<Date>
    let tint: Color
    /// `metric.format` with the reader's unit preferences.
    let format: (Double) -> String
    /// The metric's name, for VoiceOver.
    let metricTitle: String
    var height: CGFloat = NoopMetrics.chartHeight

    @State private var selectedDay: String?

    private struct Mark: Identifiable {
        let night: KeyMetricHistory.Night
        let run: String
        /// No measured neighbour on either side, so the run is a single point.
        let isolated: Bool
        var id: String { night.day }
    }

    private var marks: [Mark] {
        KeyMetricHistory.runs(nights).enumerated().flatMap { index, run in
            run.map { Mark(night: $0, run: "run-\(index)", isolated: run.count == 1) }
        }
    }

    /// Dots on every night while they can be told apart; past that only lone nights get one.
    private var showsAllDots: Bool { nights.count <= 45 }

    private var selected: KeyMetricHistory.Night? {
        guard let selectedDay else { return nil }
        return nights.first { $0.day == selectedDay }
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
        .accessibilityHint(Text("Swipe up or down to move through the nights."))
        .accessibilityAdjustableAction { direction in
            moveSelection(direction == .increment ? 1 : -1)
        }
        .onChangeCompat(of: nights.map(\.day)) { _ in selectedDay = nil }
    }

    // MARK: Readout

    private var measuredCaption: String {
        let total = KeyMetricHistory.dayCount(domain)
        return nights.count == 1
            ? String(localized: "1 of \(total) nights measured")
            : String(localized: "\(nights.count) of \(total) nights measured")
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            if let selected {
                Text(format(selected.value))
                    .font(StrandFont.number(17))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(KeyMetricDates.shortNight(selected.date, includeYear: spansYears))
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
        return Chart {
            ForEach(marks) { m in
                LineMark(x: .value("Night", m.night.date), y: .value("Value", m.night.value),
                         series: .value("Run", m.run))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                if showsAllDots || m.isolated {
                    PointMark(x: .value("Night", m.night.date), y: .value("Value", m.night.value))
                        .foregroundStyle(tint)
                        .symbolSize(showsAllDots ? 22 : 30)
                }
            }
            if let selected {
                RuleMark(x: .value("Night", selected.date))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Night", selected.date), y: .value("Value", selected.value))
                    .foregroundStyle(tint)
                    .symbolSize(90)
            }
        }
        .chartXScale(domain: plotDomain)
        .modifier(ValueScale(domain: KeyMetricHistory.valueDomain(nights.map(\.value))))
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
        let nearest = nights.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        if nearest?.day != selectedDay { selectedDay = nearest?.day }
    }

    // MARK: Accessibility

    private var accessibilityValue: String {
        if let selected {
            return "\(format(selected.value)), \(KeyMetricDates.shortNight(selected.date, includeYear: spansYears))"
        }
        guard let last = nights.last else { return measuredCaption }
        return "\(measuredCaption). \(format(last.value)), \(KeyMetricDates.shortNight(last.date, includeYear: spansYears))"
    }

    /// VoiceOver's adjustable action steps through the nights (starting from the latest).
    private func moveSelection(_ step: Int) {
        guard !nights.isEmpty else { return }
        let current = selectedDay.flatMap { day in nights.firstIndex { $0.day == day } } ?? nights.count
        let next = min(max(current + step, 0), nights.count - 1)
        selectedDay = nights[next].day
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
