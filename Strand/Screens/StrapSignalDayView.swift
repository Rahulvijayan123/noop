import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Strap signal for one day
//
// Opened from the Heart rate day page. How well the strap could read the wearer, every 30 seconds, from the
// raw motion sessions the server has processed: the states on the day's clock axis (scrub to read one), and
// how the assessed time splits between them. The reading is the one the Heart rate page already loaded; the
// page loads it itself (`DayCloudReadings.strapSignal`) only when opened before that load finished.

struct StrapSignalDayView: View {
    let dayStart: Date

    @State private var reading: StrapSignalDay?
    @State private var loaded: Bool
    @State private var selected: Date?

    init(dayStart: Date, reading: StrapSignalDay?, loaded: Bool) {
        self.dayStart = dayStart
        _reading = State(initialValue: reading)
        _loaded = State(initialValue: loaded)
    }

    private var window: ClosedRange<Date> {
        dayStart...(Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400))
    }

    private var spans: [StrapSignalDay.Span] { reading?.spans ?? [] }

    private var chartState: ChartState {
        if !loaded { return .loading }
        return spans.isEmpty ? .empty(String(localized: "No strap-signal reading for this day yet")) : .ready
    }

    private var states: [WearSignalState] {
        guard let reading else { return [] }
        return WearSignalState.displayOrder.filter { (reading.seconds[$0] ?? 0) > 0 }
    }

    var body: some View {
        ScreenScaffold(title: "Strap signal", titleDisplay: .navigationBar, isLoading: !loaded) {
            ValueReadout(readout, isScrubbing: selected != nil, isLoading: !loaded)
            NoopCard {
                StrapSignalTimeline(spans: spans, window: window, state: chartState, selection: $selected)
            }
            if let reading, !states.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("Through the day")
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                            ShareBar(parts: states.map { ($0.color, Double(reading.seconds[$0] ?? 0), $0.isGap) })
                                .frame(height: 12)
                                .accessibilityHidden(true)
                            VStack(spacing: 0) {
                                ForEach(Array(states.enumerated()), id: \.element) { index, state in
                                    if index > 0 { NoopListDivider(leadingInset: 0) }
                                    shareRow(state, reading: reading)
                                }
                            }
                        }
                    }
                }
            }
            AboutDisclosure("About strap signal", paragraphs: [
                String(localized: "How well the strap could read you, every 30 seconds, from the motion sessions the server has processed. Loose fit and motion noise make heart rate and activity less certain."),
                String(localized: "Off wrist and sensor gaps are also hatched on the heart rate graph, where they explain a break in the line."),
                String(localized: "A day appears here once the server has processed a raw motion session from your strap."),
            ])
        }
        .task(id: dayStart) {
            guard !loaded else { return }
            await load()
        }
    }

    private func load() async {
        defer { loaded = true }
        await DayCloudReadings.strapSignal(dayStart: dayStart) { reading = $0 }
    }

    private func shareRow(_ state: WearSignalState, reading: StrapSignalDay) -> some View {
        let s = reading.seconds[state] ?? 0
        let total = max(1, reading.seconds.values.reduce(0, +))
        return HStack(spacing: NoopMetrics.space2) {
            RoundedRectangle(cornerRadius: 2).fill(state.color).frame(width: 10, height: 10)
            Text(state.displayName)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            Text(StretchFormat.duration(s))
                .font(StrandFont.subhead.monospacedDigit())
                .foregroundStyle(StrandPalette.textTertiary)
            Text(Self.shareText(s, of: total))
                .font(StrandFont.subhead.monospacedDigit())
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    /// "96 %", or "<1 %" for a real but tiny share (a 3-minute sensor gap is not "0 %").
    static func shareText(_ seconds: Int, of total: Int) -> String {
        let pct = Double(seconds) / Double(max(1, total)) * 100
        return seconds > 0 && pct < 0.5 ? "<1 %" : "\(Int(pct.rounded())) %"
    }

    // MARK: Readout

    private var selectedSpan: StrapSignalDay.Span? {
        guard let selected else { return nil }
        let ts = Int(selected.timeIntervalSince1970)
        return spans.first { $0.start <= ts && ts < $0.end }
            ?? spans.min { abs(StrapSignalTimeline.mid($0).timeIntervalSince(selected)) < abs(StrapSignalTimeline.mid($1).timeIntervalSince(selected)) }
    }

    private var readout: ReadoutContent {
        if let span = selectedSpan {
            let from = Date(timeIntervalSince1970: TimeInterval(span.start))
            let to = Date(timeIntervalSince1970: TimeInterval(span.end))
            return ReadoutContent(dateLine: ReadoutContent.dateLine(from, period: .time),
                                  value: span.state.displayName, unit: nil,
                                  context: "\(StretchFormat.clock(from)) – \(StretchFormat.clock(to)) · \(StretchFormat.duration(span.end - span.start))")
        }
        return ReadoutContent(dateLine: ReadoutContent.dateLine(dayStart, period: .day),
                              value: reading?.goodShare.map { "\(Int(($0 * 100).rounded()))" }, unit: "%",
                              context: reading?.goodShare == nil ? nil : String(localized: "Good contact"))
    }
}

/// The strap-signal states on the day's clock axis, one lane tall, scrubbable.
struct StrapSignalTimeline: View {
    let spans: [StrapSignalDay.Span]
    let window: ClosedRange<Date>
    let state: ChartState
    @Binding var selection: Date?

    static func mid(_ span: StrapSignalDay.Span) -> Date {
        Date(timeIntervalSince1970: TimeInterval(span.start + span.end) / 2)
    }

    var body: some View {
        let height: CGFloat = 96
        switch state {
        case .loading: ChartPlaceholder(height: height)
        case .empty(let message): EmptyChartMessage(message, height: height)
        case .ready: chart.frame(height: height)
        }
    }

    private var chart: some View {
        // Scrub positions: each span's start and end, so a long span can be read at either edge.
        let xs = Array(Set(spans.flatMap { [Date(timeIntervalSince1970: TimeInterval($0.start)),
                                            Date(timeIntervalSince1970: TimeInterval($0.end - 1))] })).sorted()
        let selected = selection.flatMap { ChartSelection.nearest(to: $0, in: xs) }
        let yLayout = ChartYAxisLayout(domain: 0...1, ticks: [], labels: [], unit: nil)
        return Chart {
            ForEach(spans) { span in
                RectangleMark(xStart: .value("Start", Date(timeIntervalSince1970: TimeInterval(span.start))),
                              xEnd: .value("End", Date(timeIntervalSince1970: TimeInterval(span.end))),
                              yStart: .value("Bottom", 0.0), yEnd: .value("Top", 1.0))
                    .foregroundStyle(span.state.isGap ? span.state.color.opacity(0.35) : span.state.color)
            }
            SelectionRule(selected, unit: nil)
        }
        .naraChartAxes(x: ChartAxis.layout(window, style: .hours), y: yLayout)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Strap signal across the day"))
    }
}

/// One horizontal bar split into shares, hatching the parts with no trustworthy signal.
private struct ShareBar: View {
    let parts: [(color: Color, value: Double, hatched: Bool)]

    var body: some View {
        GeometryReader { geo in
            let total = max(parts.reduce(0) { $0 + $1.value }, 1)
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    let width = max(1, geo.size.width * part.value / total - 1)
                    Rectangle()
                        .fill(part.hatched ? part.color.opacity(0.35) : part.color)
                        .overlay {
                            if part.hatched {
                                DiagonalHatch(spacing: 4).stroke(part.color, lineWidth: 1).clipped()
                            }
                        }
                        .frame(width: width)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }
}
