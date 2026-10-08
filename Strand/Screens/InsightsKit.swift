import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Shared pieces for the Health, Stress, Trends and Insights screens
//
// Small presentation helpers these screens share and the kit does not have yet (listed for promotion in
// the area's kit notes). Nothing here reads, computes or stores health data: every value is passed in.

/// Opens one metric's detail page from a row or tile.
///
/// On iOS it pushes the `TabRoute` value, which every iOS host of these screens registers (the tab
/// stacks and the pillar sheets call `tabRouteDestinations()`), so a tab re-tap still pops back. The Mac
/// hosts these screens in sidebar panes with no `NavigationStack`, where a pushed value would dead-end, so
/// there the detail opens in a sheet with its own stack instead.
struct MetricDetailLink<Label: View>: View {
    let key: String
    var source: String? = nil
    @ViewBuilder let label: () -> Label

    #if os(macOS)
    @State private var presented = false
    #endif

    init(key: String, source: String? = nil, @ViewBuilder label: @escaping () -> Label) {
        self.key = key
        self.source = source
        self.label = label
    }

    private var route: TabRoute {
        if let source { return .metricSourced(key: key, source: source) }
        return .metric(key)
    }

    var body: some View {
        #if os(macOS)
        Button { presented = true } label: { label() }
            .buttonStyle(.plain)
            .sheet(isPresented: $presented) {
                NavigationStack {
                    Group {
                        if let metric = (source.flatMap { MetricCatalog.metric(key: key, source: $0) })
                            ?? MetricCatalog.all.first(where: { $0.key == key }) {
                            MetricDetailView(metric: metric)
                        }
                    }
                    .tabRouteDestinations()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { presented = false }
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
                }
                .frame(width: 900, height: 820)
            }
        #else
        NavigationLink(value: route) { label() }
            .buttonStyle(.plain)
        #endif
    }
}

/// The range rule for the area's history charts: a range is offered once the history reaches past the
/// next shorter range, so W, M, 3M… appear as the history grows, and All only once it is longer than a
/// year (before that it would draw the same window as the longest finite range).
enum InsightsRanges {
    /// Days from `firstDay` to today, both included; 0 with no history.
    static func span(firstDay: Date?, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let firstDay else { return 0 }
        return ChartDay.daysBetween(calendar.startOfDay(for: firstDay), calendar.startOfDay(for: now),
                                    calendar: calendar) + 1
    }

    static func options(span: Int) -> [ChartRange] {
        span > 365 ? ChartRange.allCases : ChartRange.allCases.filter { $0 != .all }
    }

    static func isAvailable(_ range: ChartRange, span: Int) -> Bool {
        let order = ChartRange.allCases
        guard let index = order.firstIndex(of: range), index > 0, let shorter = order[index - 1].days else {
            return true
        }
        return span > shorter
    }

    /// The range the charts draw: the selection when it is offered, else what `RangeControl` shows.
    static func effective(_ selection: ChartRange, span: Int) -> ChartRange {
        let visible = RangeControl.visibleOptions(options(span: span)) { isAvailable($0, span: span) }
        return RangeControl.displayedSelection(selection, visible: visible) ?? selection
    }
}

extension RangeControl {
    /// The area's range control for a history that starts at `firstDay`. Its 38 pt are kept when it hides,
    /// so a short history does not move the page.
    init(insightsSelection selection: Binding<ChartRange>, span: Int) {
        self.init(selection: selection, options: InsightsRanges.options(span: span),
                  isAvailable: { InsightsRanges.isAvailable($0, span: span) },
                  reservesSpaceWhenHidden: true)
    }
}

/// One proportional bar for the parts of a whole (the day's stress split, a drink mix): segments in
/// order, each as wide as its share, with a one-line legend of names and amounts underneath. An empty
/// whole draws the bare track, so the card keeps its height.
struct InsightsShareBar: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let value: Double
        let color: Color
        /// The amount as the legend prints it ("5 h", "1.2 L"); "—" for nothing.
        let valueText: String
    }

    let segments: [Segment]

    private var total: Double { segments.reduce(0) { $0 + max(0, $1.value) } }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            GeometryReader { geo in
                let shown = segments.filter { $0.value > 0 }
                let gaps = CGFloat(max(0, shown.count - 1)) * 2
                HStack(spacing: 2) {
                    if total > 0 {
                        ForEach(shown) { segment in
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: max(0, (geo.size.width - gaps) * CGFloat(segment.value / total)))
                        }
                    } else {
                        Rectangle().fill(StrandPalette.surfaceInset)
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())

            HStack(spacing: NoopMetrics.space4) {
                ForEach(segments) { segment in
                    HStack(spacing: NoopMetrics.space1) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.label)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(segment.valueText)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: segments.map { "\($0.label) \($0.valueText)" }.joined(separator: ", ")))
    }
}

/// A label and value line inside a card or disclosure, for a few statistics that do not warrant a
/// `StatGrid` card of their own (a card never sits inside a card).
struct InsightsValueRow: View {
    let label: String
    let value: String
    var unit: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Text(label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: NoopMetrics.space2)
            Text(value)
                .font(StrandFont.number(17))
                .foregroundStyle(StrandPalette.textPrimary)
            if let unit, value != "—" {
                Text(unit)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Opens a page one tap down: a push inside the current stack on iOS (never a sheet over a sheet), a
/// sheet with its own stack on the Mac, whose sidebar panes have no `NavigationStack` to push into.
struct InsightsDetailLink<Label: View, Destination: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label

    #if os(macOS)
    @State private var presented = false
    #endif

    init(@ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    var body: some View {
        #if os(macOS)
        Button { presented = true } label: { label() }
            .buttonStyle(.plain)
            .sheet(isPresented: $presented) {
                NavigationStack {
                    destination()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { presented = false }
                                    .foregroundStyle(StrandPalette.accent)
                            }
                        }
                }
                .frame(width: 760, height: 760)
            }
        #else
        NavigationLink { destination() } label: { label() }
            .buttonStyle(.plain)
        #endif
    }
}

/// A bar that grows left or right of a centre line by a signed value (a correlation, an effect, a
/// factor's pull), on a symmetric scale of ±`magnitude`. The number it stands for is printed beside it;
/// the bar carries the direction and relative size only.
struct InsightsDivergingBar: View {
    let value: Double
    let magnitude: Double
    var positiveColor: Color = StrandPalette.statusPositive
    var negativeColor: Color = StrandPalette.statusWarning

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let share = magnitude > 0 ? min(1, abs(value) / magnitude) : 0
            let length = max(value == 0 ? 0 : 2, half * CGFloat(share))
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                Rectangle()
                    .fill(value >= 0 ? positiveColor : negativeColor)
                    .frame(width: length)
                    .offset(x: value >= 0 ? half : half - length)
                Rectangle()
                    .fill(StrandPalette.textTertiary)
                    .frame(width: 1)
                    .offset(x: half - 0.5)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// Score bands built from the scorers' own thresholds (docs/DESIGN_SYSTEM.md, Colour): the kit defines
/// none, and a screen never invents a set.
enum InsightsScoreBands {
    /// Charge (recovery) and Rest: red below `RecoveryScorer.bandRedMax`, yellow below `bandYellowMax`.
    static var charge: ScoreBands {
        ScoreBands([.init(upperBound: RecoveryScorer.bandRedMax, color: StrandPalette.statusCritical,
                          name: String(localized: "Low")),
                    .init(upperBound: RecoveryScorer.bandYellowMax, color: StrandPalette.statusWarning,
                          name: String(localized: "Moderate")),
                    .init(upperBound: .infinity, color: StrandPalette.chargeColor, name: String(localized: "High"))])
    }
}

/// The p25–p75 spread of `values`: the personal typical band a vital's line chart shades, drawn only once
/// there are enough readings to trust it (14, the baseline seed). Display only.
func insightsTypicalBand(_ values: [Double], minimumCount: Int = 14) -> ClosedRange<Double>? {
    let sorted = values.filter(\.isFinite).sorted()
    guard sorted.count >= minimumCount else { return nil }
    func quantile(_ q: Double) -> Double {
        let position = q * Double(sorted.count - 1)
        let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
    let p25 = quantile(0.25), p75 = quantile(0.75)
    return p75 > p25 ? p25...p75 : nil
}

/// A compact readout line inside a card holding one of several charts on a page: the value under the
/// finger (else the summary value) with its unit, and its date or a short context on the right. One
/// line at a fixed height, so scrubbing never moves the chart below it.
struct InsightsCardReadout: View {
    let value: String?
    let unit: String?
    let context: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
            Text(value ?? "—")
                .font(StrandFont.number(24))
                .foregroundStyle(StrandPalette.textPrimary)
            if let unit, value != nil {
                Text(unit)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: NoopMetrics.space2)
            Text(context)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
    }
}

/// The engine's confidence tier as the one state pill, always with its word.
struct InsightsConfidencePill: View {
    let confidence: ScoreConfidence

    var body: some View {
        switch confidence {
        case .solid:       StatePill("Solid", tone: .positive, showsDot: false)
        case .building:    StatePill("Building", tone: .neutral, showsDot: false)
        case .calibrating: StatePill("Calibrating", tone: .neutral, showsDot: false)
        }
    }
}

/// Two values side by side on one axis (an outcome with and without a behaviour, a reading before and
/// after): each a labelled bar from zero with its value and sample count, so the gap between them reads
/// at a glance. `domain` is the axis (0...100 for scores, else 0 to a little above the larger value).
struct InsightsComparisonBars: View {
    struct Bar: Identifiable {
        let id: String
        let label: String
        let value: Double
        let valueText: String
        let detail: String
        let color: Color
    }

    let bars: [Bar]
    let domain: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(bars) { bar in
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(bar.label).strandLabel()
                        Spacer(minLength: NoopMetrics.space2)
                        Text(bar.valueText)
                            .font(StrandFont.number(17))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(bar.detail)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    GeometryReader { geo in
                        let span = max(domain.upperBound - domain.lowerBound, 0.0001)
                        let share = min(1, max(0, (bar.value - domain.lowerBound) / span))
                        ZStack(alignment: .leading) {
                            Capsule().fill(StrandPalette.surfaceInset)
                            Capsule().fill(bar.color).frame(width: max(4, geo.size.width * CGFloat(share)))
                        }
                    }
                    .frame(height: 10)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Paired daily values as a scatter (one point per day the two series share), with both axes labelled
/// in their units, the house axis style, and the r value told beside it by the caller. Not in the kit
/// yet; built on Swift Charts here.
struct InsightsScatterChart: View {
    struct Pair: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    let pairs: [Pair]
    let xTitle: String
    let yTitle: String
    var color: Color = StrandPalette.chargeColor
    var height: CGFloat = NoopMetrics.chartHeightSecondary

    init(pairs: [(Double, Double)], xTitle: String, yTitle: String,
         color: Color = StrandPalette.chargeColor, height: CGFloat = NoopMetrics.chartHeightSecondary) {
        self.pairs = pairs.enumerated().map { Pair(id: $0.offset, x: $0.element.0, y: $0.element.1) }
        self.xTitle = xTitle
        self.yTitle = yTitle
        self.color = color
        self.height = height
    }

    private func domain(_ values: [Double]) -> ClosedRange<Double> {
        ChartDomain.fitted(minSpan: 2).resolve(values)
    }

    var body: some View {
        let xDomain = domain(pairs.map(\.x))
        let yDomain = domain(pairs.map(\.y))
        Chart(pairs) { pair in
            PointMark(x: .value(xTitle, pair.x), y: .value(yTitle, pair.y))
                .symbolSize(pairs.count > NaraChartStyle.densePointThreshold ? NaraChartStyle.densePointSize
                                                                              : NaraChartStyle.pointSize)
                .foregroundStyle(color.opacity(0.75))
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            // The edge labels anchor inside the plot, so the last one is never cut to "…".
            AxisMarks(values: ChartTicks.nice(in: xDomain)) { value in
                AxisGridLine(stroke: NaraChartStyle.grid).foregroundStyle(NaraChartStyle.gridColor)
                AxisValueLabel(anchor: value.index == 0 ? .topLeading
                               : (value.index == value.count - 1 ? .topTrailing : .top)) {
                    if let v = value.as(Double.self) {
                        Text(v.formatted(.number.precision(.fractionLength(0...1))))
                            .font(NaraChartStyle.axisFont).foregroundStyle(NaraChartStyle.axisColor)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: ChartTicks.nice(in: yDomain)) { _ in
                AxisGridLine(stroke: NaraChartStyle.grid).foregroundStyle(NaraChartStyle.gridColor)
                AxisValueLabel().font(NaraChartStyle.axisFont).foregroundStyle(NaraChartStyle.axisColor)
            }
        }
        .chartXAxisLabel(position: .bottom, alignment: .center) {
            Text(xTitle).font(NaraChartStyle.unitFont).foregroundStyle(StrandPalette.textSecondary)
        }
        .chartYAxisLabel(position: .top, alignment: .leading) {
            Text(yTitle).font(NaraChartStyle.unitFont).foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(xTitle), \(yTitle): \(pairs.count)"))
    }
}
