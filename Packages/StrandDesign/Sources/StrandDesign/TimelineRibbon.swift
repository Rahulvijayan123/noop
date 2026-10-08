#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - TimelineRibbon

/// Thin lanes of categorical spans that sit under an `IntradayChart` on the same time axis: what the wearer
/// was doing, each walk, how well the strap could read them.
///
/// The lanes line up with the chart above to the pixel because they are laid out the same way: a leading
/// value-axis gutter as wide as the chart's widest tick label (`gutterText`, drawn invisibly), the same x
/// domain, and no trailing inset. The gutter carries each lane's glyph instead of numbers.
///
/// - A segment narrower than `minimumFraction` of the window is widened about its centre so a short change
///   still shows as a tick; zooming in shows its real width.
/// - `hatched` segments (low confidence, off wrist, no reading) are drawn as a hatch over the lane's colour
///   rather than in a fainter tint, so "unsure" never reads as a lighter family colour.
/// - `ticks` are instants (position changes) drawn as short marks under the lane.
/// - `selection` draws the same 1 pt rule the chart above draws, so a scrub reads straight down.
/// - A tap reports the lane and the time under the finger.
///
/// ```swift
/// TimelineRibbon(lanes: [.init(id: "activity", symbol: "figure.walk", title: "Activity", segments: segs)],
///                window: dayStart...dayEnd, gutterText: "160", selection: selected,
///                onTap: { lane, time in open(lane, time) })
/// ```
public struct TimelineRibbon: View {

    public struct Segment: Identifiable, Sendable {
        public var id: String
        public var start: Date
        public var end: Date
        public var color: Color
        public var hatched: Bool

        public init(id: String, start: Date, end: Date, color: Color, hatched: Bool = false) {
            self.id = id
            self.start = start
            self.end = end
            self.color = color
            self.hatched = hatched
        }
    }

    public struct Lane: Identifiable, Sendable {
        public var id: String
        /// SF Symbol drawn in the gutter beside the lane.
        public var symbol: String?
        /// What the lane shows, for VoiceOver.
        public var title: String
        public var segments: [Segment]
        /// Instants marked under the lane (position changes).
        public var ticks: [Date]
        public var tickColor: Color
        public var height: CGFloat
        /// `.loading` draws the empty track; `.empty(message)` the track with one short line inside.
        public var state: ChartState

        public init(id: String, symbol: String? = nil, title: String, segments: [Segment],
                    ticks: [Date] = [], tickColor: Color = StrandPalette.metricAmber,
                    height: CGFloat = TimelineRibbon.laneHeight, state: ChartState = .ready) {
            self.id = id
            self.symbol = symbol
            self.title = title
            self.segments = segments
            self.ticks = ticks
            self.tickColor = tickColor
            self.height = height
            self.state = state
        }
    }

    /// The main lane's height.
    public static let laneHeight: CGFloat = 18
    /// A secondary lane's height (walks, strap signal).
    public static let thinLaneHeight: CGFloat = 10
    /// Room under a lane for its ticks.
    public static let tickHeight: CGFloat = 5
    public static let laneSpacing: CGFloat = 6

    private let lanes: [Lane]
    private let window: ClosedRange<Date>
    private let gutterText: String
    private let selection: Date?
    private let minimumFraction: Double
    private let onTap: ((String, Date) -> Void)?
    private let accessibilityLabelText: String
    private let accessibilityValueText: String?

    public init(lanes: [Lane], window: ClosedRange<Date>, gutterText: String, selection: Date? = nil,
                minimumFraction: Double = 0.004, accessibilityLabel: String,
                accessibilityValue: String? = nil, onTap: ((String, Date) -> Void)? = nil) {
        self.lanes = lanes
        self.window = window
        self.gutterText = gutterText
        self.selection = selection
        self.minimumFraction = minimumFraction
        self.onTap = onTap
        self.accessibilityLabelText = accessibilityLabel
        self.accessibilityValueText = accessibilityValue
    }

    /// The widest tick label of `axis` laid out for `values` (pass exactly what the chart above lays out:
    /// its windowed samples, envelope lows and highs, and reference values), so the ribbon's gutter matches.
    public static func gutterText(for axis: ChartValueAxis, values: [Double]) -> String {
        axis.layout(for: values).labels.max { $0.count < $1.count } ?? ""
    }

    /// The ribbon's total height for `lanes`.
    public static func height(for lanes: [Lane]) -> CGFloat {
        guard !lanes.isEmpty else { return 0 }
        let body = lanes.reduce(CGFloat(0)) { $0 + $1.height + ($1.ticks.isEmpty ? 0 : tickHeight) }
        return body + laneSpacing * CGFloat(lanes.count - 1)
    }

    // MARK: Layout (pure)

    /// Each lane's vertical extent in points from the top, and the extent of its tick strip.
    private struct LaneFrame {
        let lane: Lane
        let top: CGFloat
        let bottom: CGFloat
        let tickBottom: CGFloat
        var center: CGFloat { (top + bottom) / 2 }
    }

    private var frames: [LaneFrame] {
        var y: CGFloat = 0
        return lanes.map { lane in
            let top = y
            let bottom = top + lane.height
            let tickBottom = bottom + (lane.ticks.isEmpty ? 0 : Self.tickHeight)
            y = tickBottom + Self.laneSpacing
            return LaneFrame(lane: lane, top: top, bottom: bottom, tickBottom: tickBottom)
        }
    }

    private var totalHeight: CGFloat { Self.height(for: lanes) }

    /// A segment clipped to the window and widened to the minimum visible width.
    private func visibleRange(_ segment: Segment) -> ClosedRange<Date>? {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        guard span > 0 else { return nil }
        var start = max(segment.start, window.lowerBound)
        var end = min(segment.end, window.upperBound)
        guard end > start else { return nil }
        let minWidth = span * minimumFraction
        let width = end.timeIntervalSince(start)
        if width < minWidth {
            let mid = start.addingTimeInterval(width / 2)
            start = max(window.lowerBound, mid.addingTimeInterval(-minWidth / 2))
            end = min(window.upperBound, mid.addingTimeInterval(minWidth / 2))
        }
        return start...end
    }

    // MARK: Body

    public var body: some View {
        let frames = self.frames
        // Chart y runs bottom-up; lanes are laid out top-down in points, so flip.
        let total = max(1, totalHeight)
        let flip: (CGFloat) -> Double = { Double(total - $0) }
        Chart {
            ForEach(frames, id: \.lane.id) { frame in
                // The lane's track.
                RectangleMark(xStart: .value("Start", window.lowerBound), xEnd: .value("End", window.upperBound),
                              yStart: .value("Bottom", flip(frame.bottom)), yEnd: .value("Top", flip(frame.top)))
                    .foregroundStyle(StrandPalette.surfaceInset)
                    .cornerRadius(3)
                if frame.lane.state == .ready {
                    ForEach(frame.lane.segments) { segment in
                        if let range = visibleRange(segment) {
                            RectangleMark(xStart: .value("Start", range.lowerBound),
                                          xEnd: .value("End", range.upperBound),
                                          yStart: .value("Bottom", flip(frame.bottom)),
                                          yEnd: .value("Top", flip(frame.top)))
                                .foregroundStyle(segment.hatched ? segment.color.opacity(0.18) : segment.color)
                        }
                    }
                    ForEach(Array(frame.lane.ticks.enumerated()), id: \.offset) { _, tick in
                        if window.contains(tick) {
                            let half = window.upperBound.timeIntervalSince(window.lowerBound) * 0.0015
                            RectangleMark(xStart: .value("Start", tick.addingTimeInterval(-half)),
                                          xEnd: .value("End", tick.addingTimeInterval(half)),
                                          yStart: .value("Bottom", flip(frame.tickBottom)),
                                          yEnd: .value("Top", flip(frame.bottom + 1)))
                                .foregroundStyle(frame.lane.tickColor)
                        }
                    }
                }
            }
            if let selection, window.contains(selection) {
                RuleMark(x: .value("Selected", selection))
                    .lineStyle(NaraChartStyle.selectionRule)
                    .foregroundStyle(NaraChartStyle.selectionColor)
            }
        }
        .chartXScale(domain: window)
        .chartYScale(domain: 0...Double(total), range: .plotDimension(startPadding: 0, endPadding: 0))
        .chartXAxis(.hidden)
        .chartYAxis {
            // The same leading gutter as the chart above: an invisible copy of its widest tick label, with
            // the lane's glyph at the trailing edge where the chart's numbers end.
            AxisMarks(position: .leading, values: frames.map { flip($0.center) }) { value in
                AxisValueLabel {
                    ZStack(alignment: .trailing) {
                        Text(gutterText)
                            .font(NaraChartStyle.axisFont)
                            .hidden()
                        if let raw = value.as(Double.self),
                           let frame = frames.min(by: { abs(flip($0.center) - raw) < abs(flip($1.center) - raw) }),
                           let symbol = frame.lane.symbol {
                            Image(systemName: symbol)
                                .font(StrandFont.icon(.inline))
                                .foregroundStyle(NaraChartStyle.axisColor)
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    hatches(frames: frames, proxy: proxy, plot: plot)
                    messages(frames: frames, plot: plot)
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: plot.width, height: plot.height)
                        .position(x: plot.midX, y: plot.midY)
                        .onTapGesture { location in tap(at: location, frames: frames, proxy: proxy, plot: plot) }
                        .allowsHitTesting(onTap != nil)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .frame(height: totalHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityValue(Text(accessibilityValueText ?? ""))
    }

    /// Hatching over the hatched segments, drawn in the overlay because a mark cannot take a pattern.
    @ViewBuilder
    private func hatches(frames: [LaneFrame], proxy: ChartProxy, plot: CGRect) -> some View {
        ForEach(frames, id: \.lane.id) { frame in
            if frame.lane.state == .ready {
                ForEach(frame.lane.segments.filter(\.hatched)) { segment in
                    if let range = visibleRange(segment),
                       let x0 = proxy.position(forX: range.lowerBound),
                       let x1 = proxy.position(forX: range.upperBound), x1 - x0 >= 1 {
                        DiagonalHatch(spacing: 4)
                            .stroke(segment.color.opacity(0.7), lineWidth: 1)
                            .frame(width: x1 - x0, height: frame.lane.height)
                            .clipped()
                            .position(x: plot.minX + (x0 + x1) / 2, y: plot.minY + frame.center)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// The one-line message inside an empty lane.
    @ViewBuilder
    private func messages(frames: [LaneFrame], plot: CGRect) -> some View {
        ForEach(frames, id: \.lane.id) { frame in
            if case .empty(let message) = frame.lane.state, frame.lane.height >= 14 {
                Text(message)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: plot.width, height: frame.lane.height)
                    .position(x: plot.midX, y: plot.minY + frame.center)
                    .allowsHitTesting(false)
            }
        }
    }

    private func tap(at location: CGPoint, frames: [LaneFrame], proxy: ChartProxy, plot: CGRect) {
        guard let onTap, plot.width > 0 else { return }
        let x = min(max(location.x, plot.minX), plot.maxX) - plot.minX
        guard let date: Date = proxy.value(atX: x) else { return }
        let y = location.y - plot.minY
        // The lane under the finger, or the nearest one when the tap lands between lanes.
        let lane = frames.min { abs($0.center - y) < abs($1.center - y) }?.lane
        guard let lane else { return }
        onTap(lane.id, date)
    }
}

#if DEBUG
private struct TimelineRibbonPreview: View {
    var body: some View {
        let day = Calendar.current.startOfDay(for: Date())
        let window = day...day.addingTimeInterval(86_400)
        func seg(_ id: String, _ h0: Double, _ h1: Double, _ c: Color, hatched: Bool = false) -> TimelineRibbon.Segment {
            .init(id: id, start: day.addingTimeInterval(h0 * 3600), end: day.addingTimeInterval(h1 * 3600),
                  color: c, hatched: hatched)
        }
        return VStack(spacing: 12) {
            TimelineRibbon(lanes: [
                .init(id: "activity", symbol: "figure.walk", title: "Activity",
                      segments: [seg("a", 0, 6.8, StrandPalette.sleepDeep), seg("b", 7.2, 7.7, StrandPalette.accent),
                                 seg("c", 8.5, 12, StrandPalette.metricCyan), seg("d", 12, 12.5, StrandPalette.accent, hatched: true),
                                 seg("e", 15.3, 15.6, StrandPalette.metricRose)],
                      ticks: [day.addingTimeInterval(9 * 3600), day.addingTimeInterval(14 * 3600)]),
                .init(id: "walks", symbol: "shoeprints.fill", title: "Walks",
                      segments: [seg("w", 7.25, 7.75, StrandPalette.accent)], height: TimelineRibbon.thinLaneHeight),
                .init(id: "empty", title: "Strap", segments: [], state: .empty("No reading")),
            ], window: window, gutterText: "160", accessibilityLabel: "Activity")
        }
        .padding(20)
        .background(StrandPalette.surfaceRaised)
    }
}

#Preview("TimelineRibbon") { TimelineRibbonPreview() }
#endif
#endif
