import SwiftUI
import Charts
import StrandDesign

/// One reading on a key-metric chart, in plotted units.
struct KeyMetricDot: Identifiable, Equatable {
    let id: String
    let x: Date
    let y: Double
}

/// The shaded range at one x, in plotted units.
struct KeyMetricBandPoint: Identifiable, Equatable {
    let x: Date
    let low: Double
    let high: Double
    var id: Date { x }
}

/// The key-metric screens' chart: one dot per reading and nothing between them, so a night, a day or a 5-minute
/// window without a reading is plainly a gap and nothing is ever drawn at zero. Behind the dots, the shaded range
/// (the usual or recent range) and, for the 24-hour stable awake view, a dashed reference line. The selected
/// reading is marked with a guide; a tap or a sideways drag reports the x it touched (`onSelect`) and the screen
/// decides what that selects, so the activity lane and the comparison chart can share the guide.
///
/// The value labels have a fixed width so every chart on the screen has the same plot inset, which the screen
/// reads back through `KeyMetricPlotInsetKey` to line the activity lane up with the plot.
struct KeyMetricDotChart: View {
    let dots: [KeyMetricDot]
    let domain: ClosedRange<Date>
    var band: [KeyMetricBandPoint] = []
    var referenceLine: Double? = nil
    /// "HRV (ms)", drawn above the plot.
    let yTitle: String
    /// "Night", "Local time", drawn under the axis.
    let xTitle: String
    let xTicks: [Date]
    let xLabel: (Date) -> String
    var color: Color = KeyMetricStyle.accent
    var dotSize: CGFloat = 36
    var minimumPad: Double = 3
    /// Values below zero are never readings, so the axis floor is zero unless a metric says otherwise.
    var floorsAtZero: Bool = true
    var height: CGFloat = 220
    /// The guide's x and, when it sits on a reading, that reading.
    var guideX: Date? = nil
    var selectedID: String? = nil
    /// Nil makes the chart read-only (the comparison chart follows the main one).
    var onSelect: ((Date) -> Void)? = nil

    static let valueLabelWidth: CGFloat = 34

    private var valueDomain: ClosedRange<Double>? {
        var values = dots.map(\.y)
        values += band.flatMap { [$0.low, $0.high] }
        if let referenceLine { values.append(referenceLine) }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let pad = max((hi - lo) * 0.16, minimumPad)
        let low = floorsAtZero ? max(0, lo - pad) : lo - pad
        return low...(hi + pad)
    }

    /// Flat bands (one span) are drawn edge to edge.
    private var bandMarks: [KeyMetricBandPoint] {
        guard band.count == 1, let only = band.first else { return band }
        return [KeyMetricBandPoint(x: domain.lowerBound, low: only.low, high: only.high),
                KeyMetricBandPoint(x: domain.upperBound, low: only.low, high: only.high)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(yTitle)
                .font(KeyMetricStyle.small)
                .foregroundStyle(KeyMetricStyle.secondary)
                .padding(.leading, 2)
            chart
            Text(xTitle)
                .font(KeyMetricStyle.small)
                .foregroundStyle(KeyMetricStyle.secondary)
                .frame(maxWidth: .infinity)
                .padding(.leading, Self.valueLabelWidth)
        }
        // VoiceOver reads the selected reading from the row under the chart, which has previous / next buttons.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(yTitle))
        .accessibilityValue(Text(dots.count == 1 ? String(localized: "1 reading")
                                 : String(localized: "\(dots.count) readings")))
    }

    private var chart: some View {
        let selected = dots.first { $0.id == selectedID }
        return Chart {
            ForEach(bandMarks) { b in
                AreaMark(x: .value("x", b.x), yStart: .value("low", b.low), yEnd: .value("high", b.high))
                    .foregroundStyle(KeyMetricStyle.band)
                    .interpolationMethod(.monotone)
            }
            if let referenceLine {
                RuleMark(y: .value("reference", referenceLine))
                    .foregroundStyle(KeyMetricStyle.teal)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            ForEach(dots) { d in
                PointMark(x: .value("x", d.x), y: .value("y", d.y))
                    .foregroundStyle(color)
                    .symbolSize(dotSize)
            }
            if let guideX {
                RuleMark(x: .value("x", guideX))
                    .foregroundStyle(KeyMetricStyle.secondary.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let selected {
                PointMark(x: .value("x", selected.x), y: .value("y", selected.y))
                    .foregroundStyle(KeyMetricStyle.panel)
                    .symbolSize(150)
                PointMark(x: .value("x", selected.x), y: .value("y", selected.y))
                    .foregroundStyle(KeyMetricStyle.text)
                    .symbolSize(70)
            }
        }
        .chartXScale(domain: domain)
        .modifier(KeyMetricValueScale(domain: valueDomain))
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisTick(length: 0)
                if let date = value.as(Date.self) {
                    AxisValueLabel(anchor: labelAnchor(date)) {
                        Text(xLabel(date))
                            .font(KeyMetricStyle.small)
                            .foregroundStyle(KeyMetricStyle.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(KeyMetricStyle.border)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Self.axisNumber(v))
                            .font(KeyMetricStyle.small)
                            .foregroundStyle(KeyMetricStyle.secondary)
                            .frame(width: Self.valueLabelWidth - 6, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                Color.clear
                    .preference(key: KeyMetricPlotInsetKey.self,
                                value: KeyMetricPlotInset(leading: plot.minX, trailing: geo.size.width - plot.maxX))
                if onSelect != nil {
                    touchSurface(proxy: proxy, plot: plot)
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func touchSurface(proxy: ChartProxy, plot: CGRect) -> some View {
        #if os(iOS)
        HorizontalScrubSurface(onScrub: { select($0, proxy: proxy, plot: plot) }, onEnd: {},
                               onTap: { select($0, proxy: proxy, plot: plot) })
        #else
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { select($0.location.x, proxy: proxy, plot: plot) })
        #endif
    }

    /// A label near the plot's edge is anchored inward so it is never cut off.
    private func labelAnchor(_ date: Date) -> UnitPoint {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return .top }
        let f = date.timeIntervalSince(domain.lowerBound) / span
        return f < 0.08 ? .topLeading : f > 0.92 ? .topTrailing : .top
    }

    /// `x` is in the touch surface's own space, which starts at the plot's leading edge.
    private func select(_ x: CGFloat, proxy: ChartProxy, plot: CGRect) {
        guard plot.width > 0, let onSelect else { return }
        let clamped = min(max(x, 0), plot.width)
        guard let date: Date = proxy.value(atX: clamped) else { return }
        onSelect(date)
    }

    /// Axis numbers: thousands abbreviated ("8k", "2.5k") so they fit the fixed label width, whole numbers
    /// otherwise, one decimal when the step needs it.
    static func axisNumber(_ v: Double) -> String {
        if abs(v) >= 1_000 {
            let k = v / 1_000
            let digits = abs(k - k.rounded()) < 0.05 ? 0 : 1
            return k.formatted(.number.precision(.fractionLength(digits))) + "k"
        }
        let rounded = v.rounded()
        if abs(v - rounded) < 0.001 || abs(v) >= 100 {
            return rounded.formatted(.number.precision(.fractionLength(0)))
        }
        return v.formatted(.number.precision(.fractionLength(1)))
    }
}

/// The plot's distance from the chart's leading and trailing edges.
struct KeyMetricPlotInset: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
}

struct KeyMetricPlotInsetKey: PreferenceKey {
    static var defaultValue = KeyMetricPlotInset(leading: KeyMetricDotChart.valueLabelWidth, trailing: 0)
    static func reduce(value: inout KeyMetricPlotInset, nextValue: () -> KeyMetricPlotInset) { value = nextValue() }
}

/// The y scale when the chart has values; Swift Charts' own otherwise.
private struct KeyMetricValueScale: ViewModifier {
    let domain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain { content.chartYScale(domain: domain) } else { content }
    }
}

// MARK: - Activity lane

/// The 24-hour view's context lane under the chart: one bar per stretch of windows with one context, on the
/// chart's own x scale (the plot inset is passed in so the bars sit under the readings they describe).
struct KeyMetricActivityLane: View {
    let spans: [KeyMetricContextSpan]
    let domain: ClosedRange<Date>
    let inset: KeyMetricPlotInset
    var guideX: Date? = nil

    static func color(_ context: KeyMetricWindowContext) -> Color {
        switch context {
        case .sleep: return KeyMetricStyle.accent
        case .stableAwake: return KeyMetricStyle.teal
        case .moving: return KeyMetricStyle.secondary
        case .awake: return KeyMetricStyle.secondary.opacity(0.45)
        case .mixed: return KeyMetricStyle.track
        // Unknown is drawn hollow: the strap could not tell.
        case .unknown: return .clear
        }
    }

    /// One bar (or legend swatch); unknown is an outline.
    @ViewBuilder
    static func swatch(_ context: KeyMetricWindowContext, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color(context))
            .overlay {
                if context == .unknown {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(KeyMetricStyle.secondary.opacity(0.5), lineWidth: 1)
                }
            }
            .frame(width: width, height: height)
    }

    /// The stretches that overlap the chart's x range.
    private var visible: [KeyMetricContextSpan] {
        let lo = Int(domain.lowerBound.timeIntervalSince1970), hi = Int(domain.upperBound.timeIntervalSince1970)
        return spans.filter { $0.end > lo && $0.start < hi }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(KeyMetricScreenCopy.activityLane)
                .font(KeyMetricStyle.small)
                .foregroundStyle(KeyMetricStyle.secondary)
            GeometryReader { geo in
                let lo = domain.lowerBound.timeIntervalSince1970, hi = domain.upperBound.timeIntervalSince1970
                let width = max(1, geo.size.width - inset.leading - inset.trailing)
                let x: (Double) -> CGFloat = { inset.leading + CGFloat(($0 - lo) / max(1, hi - lo)) * width }
                ZStack(alignment: .topLeading) {
                    ForEach(visible) { span in
                        let a = max(Double(span.start), lo), b = min(Double(span.end), hi)
                        Self.swatch(span.context, width: max(1, x(b) - x(a) - 1), height: 8)
                            .offset(x: x(a), y: 4)
                    }
                    if let guideX {
                        Rectangle()
                            .fill(KeyMetricStyle.secondary.opacity(0.8))
                            .frame(width: 1, height: 16)
                            .offset(x: x(guideX.timeIntervalSince1970))
                    }
                }
            }
            .frame(height: 16)
            .accessibilityHidden(true)
            legend
        }
    }

    private var legend: some View {
        let shown = visible
        let present = KeyMetricWindowContext.allCases.filter { c in shown.contains { $0.context == c } }
        return FlowLayout(spacing: 10) {
            ForEach(present, id: \.self) { c in
                HStack(spacing: 6) {
                    Self.swatch(c, width: 12, height: 6)
                    Text(c.name)
                }
                .font(KeyMetricStyle.small)
                .foregroundStyle(KeyMetricStyle.secondary)
            }
        }
    }
}
