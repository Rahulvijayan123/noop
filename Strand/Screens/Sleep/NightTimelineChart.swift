import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Night timeline (one night's stages, heart rate and movement on one clock axis)
//
// The one renderer for a night's stage timeline: the Sleep tab's compact card, the per-night page and the
// Stages card Today hosts all draw through it, so the three can never disagree about the shape of a night.
// It replaces the four per-stage hatched rows, the separate HR canvas and the index-based movement strip
// (whose x drifted from the stages whenever a night had more than one fragment).
//
// Every lane shares one x mapping: onset (the night's displayed bedtime) at the leading edge of the plot,
// wake (the session end) at the trailing edge, so the last label is the wake time the Times card prints.
// The stage lane is the filled stepped hypnogram (stages smoothed for display exactly as `Hypnogram`
// smooths them; totals come from the raw segments elsewhere). Heart rate breaks across gaps of more than
// five minutes; weak-signal stretches are drawn dashed. Movement is per-epoch, placed at each epoch's own
// time, so a gap between fragments is a gap here too.
//
// Display only: every input is something the screen already loaded.

/// One fragment's persisted per-epoch movement, placed on the clock (see `Night.motionFragments`).
struct NightMotionColumn {
    let time: Date
    let value: Double
}

/// The precomputed geometry of one night, built once per night (never per scrub frame).
struct NightTimeline {
    let onset: Date
    let end: Date
    /// Display-smoothed stage segments, seconds from `onset`, clipped to the window.
    let segments: [SleepInterval]
    /// Per-epoch movement on the clock, oldest first.
    let motion: [NightMotionColumn]
    let motionPeak: Double

    var span: TimeInterval { max(1, end.timeIntervalSince(onset)) }
    var window: ClosedRange<Date> { onset...max(end, onset.addingTimeInterval(60)) }

    /// - Parameters:
    ///   - intervals: the night's REAL stage segments, seconds from `onset` (`Night.realSegments`).
    ///   - motionFragments: per-fragment persisted movement; empty draws no movement.
    init(onset: Date, end: Date, intervals: [SleepInterval], motionFragments: [Night.MotionFragment] = []) {
        self.onset = onset
        self.end = max(end, onset.addingTimeInterval(60))
        let span = max(1, self.end.timeIntervalSince(onset))
        let sorted = intervals.sorted { $0.start < $1.start }
        let smoothed = Hypnogram.displaySmoothed(sorted, minDuration: 300)
        segments = smoothed.compactMap { iv in
            let s = max(0, iv.start), e = min(span, iv.end)
            return e > s ? SleepInterval(stage: iv.stage, start: s, end: e) : nil
        }
        var columns: [NightMotionColumn] = []
        for frag in motionFragments.sorted(by: { $0.startTs < $1.startTs }) {
            for (i, v) in frag.values.enumerated() where v.isFinite {
                let t = Date(timeIntervalSince1970: TimeInterval(frag.startTs) + Double(i) * Night.MotionFragment.epochSeconds)
                if t >= onset && t <= self.end { columns.append(NightMotionColumn(time: t, value: max(0, v))) }
            }
        }
        motion = columns
        motionPeak = columns.map(\.value).max() ?? 0
    }

    /// The (smoothed) stage segment under a clock time, or nil outside the timeline.
    func segment(at date: Date) -> SleepInterval? {
        let t = date.timeIntervalSince(onset)
        return segments.first { t >= $0.start && t < $0.end }
            ?? segments.last.flatMap { t >= $0.start && t <= $0.end ? $0 : nil }
    }

    /// Minutes per stage across the drawn segments (for VoiceOver).
    func minutes(_ stage: SleepStage) -> Double {
        segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration } / 60
    }
}

/// The night's stage lane, with optional heart-rate and movement lanes beneath it on the same clock axis.
struct NightTimelineChart: View {
    /// What the heart-rate lane shows.
    enum HeartRate {
        /// No lane at all (the compact card).
        case hidden
        /// The night's buckets are still loading: the lane's frame, empty.
        case loading
        /// Loaded; empty draws the lane's one-line message in the same frame.
        case ready([HRBucket])
    }

    let timeline: NightTimeline
    var heartRate: HeartRate = .hidden
    var showsMovement: Bool = false
    var highlighted: SleepStage? = nil
    /// The scrubbed time. nil binding: the chart does not scrub (a card inside a link, or a glance).
    var selection: Binding<Date?>? = nil
    var stageHeight: CGFloat = 132

    static let gutter: CGFloat = 44
    static let gutterSpacing: CGFloat = 8
    static let hrHeight: CGFloat = 76
    static let motionHeight: CGFloat = 28
    static let laneGap: CGFloat = 14
    static let axisHeight: CGFloat = 18
    /// Space above the top and below the bottom tick of a value lane, so an edge tick label is never cut.
    static let valueInset: CGFloat = 8

    private var stagesTopToBottom: [SleepStage] { [.awake, .rem, .light, .deep] }

    var body: some View {
        let axis = ChartAxis.layout(timeline.window, style: .hours)
        let selected = selection?.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            lanes(axis: axis, selected: selected)
            xAxis(axis)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep stages"))
        .accessibilityValue(Text(axValue(selected)))
        .modifier(DemoSelection(selection: selection, timeline: timeline))
    }

    // MARK: Lanes

    private func lanes(axis: ChartXAxisLayout, selected: Date?) -> some View {
        VStack(alignment: .leading, spacing: Self.laneGap) {
            HStack(alignment: .top, spacing: Self.gutterSpacing) {
                stageGutter
                stageLane(grid: axis.grid, selected: selected)
                    .frame(height: stageHeight)
            }
            heartRateLane(grid: axis.grid, selected: selected)
            if showsMovement {
                movementLane(grid: axis.grid, selected: selected)
            }
        }
        .overlay(alignment: .topLeading) {
            if let selection {
                scrubSurface(selection)
                    .padding(.leading, Self.gutter + Self.gutterSpacing)
            }
        }
    }

    private var stageGutter: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(stagesTopToBottom, id: \.self) { stage in
                Text(stage.label)
                    .font(NaraChartStyle.axisFont)
                    .foregroundStyle(highlighted == stage ? StrandPalette.textPrimary : NaraChartStyle.axisColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: Self.gutter, height: stageHeight, alignment: .leading)
    }

    private func stageLane(grid: [Date], selected: Date?) -> some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let rowStep = h / 4
            func rowY(_ rank: Int) -> CGFloat { rowStep * (CGFloat(rank) + 0.5) }
            func x(_ seconds: TimeInterval) -> CGFloat { CGFloat(seconds / timeline.span) * w }

            // Faint lanes so height reads as stage even across a gap.
            for (rank, stage) in stagesTopToBottom.enumerated() {
                let laneH = rowStep * 0.74
                let rect = CGRect(x: 0, y: rowY(rank) - laneH / 2, width: w, height: laneH)
                let opacity = highlighted == stage ? 0.16 : 0.07
                ctx.fill(Path(roundedRect: rect, cornerRadius: 6),
                         with: .color(StrandPalette.sleepStageColor(stage).opacity(opacity)))
            }
            drawGrid(ctx, grid: grid, size: size)

            // Filled stepped bands: each segment from its lane's centre down to the baseline.
            for seg in timeline.segments {
                let x0 = x(seg.start), x1 = x(seg.end)
                let y = rowY(seg.stage.bandRank)
                let rect = CGRect(x: x0, y: y, width: max(1, x1 - x0), height: max(0, h - y))
                let dimmed = highlighted != nil && seg.stage != highlighted
                ctx.fill(Path(rect), with: .color(StrandPalette.sleepStageColor(seg.stage)
                    .opacity(dimmed ? 0.22 : 1)))
            }
            drawSelection(ctx, selected: selected, size: size)
        }
    }

    @ViewBuilder
    private func heartRateLane(grid: [Date], selected: Date?) -> some View {
        switch heartRate {
        case .hidden:
            EmptyView()
        case .loading:
            laneFrame(title: "Heart rate", unit: "bpm", height: Self.hrHeight) { _ in
                ChartPlaceholder(height: Self.hrHeight)
            }
        case .ready(let raw):
            let buckets = raw.filter {
                let t = Date(timeIntervalSince1970: TimeInterval($0.ts))
                return t >= timeline.onset.addingTimeInterval(-60) && t <= timeline.end.addingTimeInterval(60)
            }
            if buckets.count >= 2 {
                let axis = ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 20), tickCount: 2)
                    .layout(for: buckets.map(\.bpm))
                laneFrame(title: "Heart rate", unit: "bpm", height: Self.hrHeight, axis: axis) { _ in
                    hrCanvas(buckets, axis: axis, grid: grid, selected: selected)
                }
            } else {
                laneFrame(title: "Heart rate", unit: "bpm", height: Self.hrHeight) { _ in
                    LaneMessage("No heart rate for this night")
                }
            }
        }
    }

    private func hrCanvas(_ buckets: [HRBucket], axis: ChartYAxisLayout, grid: [Date],
                          selected: Date?) -> some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let lo = axis.domain.lowerBound, hi = max(axis.domain.upperBound, lo + 1)
            let inset = Self.valueInset
            func y(_ bpm: Double) -> CGFloat { inset + (h - 2 * inset) * (1 - CGFloat((bpm - lo) / (hi - lo))) }
            func x(_ ts: Int) -> CGFloat {
                CGFloat(Date(timeIntervalSince1970: TimeInterval(ts)).timeIntervalSince(timeline.onset) / timeline.span) * w
            }
            for tick in axis.ticks {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(tick))); line.addLine(to: CGPoint(x: w, y: y(tick)))
                ctx.stroke(line, with: .color(NaraChartStyle.gridColor), style: NaraChartStyle.grid)
            }
            drawGrid(ctx, grid: grid, size: size)

            // Highlighted stage: wash its columns, then trace it in the stage colour on top.
            let ranges: [(TimeInterval, TimeInterval)] = highlighted.map { stage in
                timeline.segments.filter { $0.stage == stage }.map { ($0.start, $0.end) }
            } ?? []
            if let stage = highlighted {
                for r in ranges {
                    let rect = CGRect(x: CGFloat(r.0 / timeline.span) * w, y: 0,
                                      width: max(1, CGFloat((r.1 - r.0) / timeline.span) * w), height: h)
                    ctx.fill(Path(rect), with: .color(StrandPalette.sleepStageColor(stage).opacity(0.12)))
                }
            }
            // The line breaks across gaps of more than five minutes; weak-signal stretches dash.
            var strong = Path(), weak = Path()
            var prev: (ts: Int, pt: CGPoint, strong: Bool)?
            for b in buckets {
                let p = CGPoint(x: x(b.ts), y: y(b.bpm))
                let isStrong = b.conf >= 0.3
                if let pr = prev, b.ts - pr.ts <= 300 {
                    if isStrong {
                        if pr.strong { strong.addLine(to: p) } else { strong.move(to: pr.pt); strong.addLine(to: p) }
                    } else {
                        if !pr.strong { weak.addLine(to: p) } else { weak.move(to: pr.pt); weak.addLine(to: p) }
                    }
                } else {
                    if isStrong { strong.move(to: p) } else { weak.move(to: p) }
                }
                prev = (b.ts, p, isStrong)
            }
            let base = highlighted == nil ? StrandPalette.restColor : StrandPalette.textTertiary.opacity(0.5)
            ctx.stroke(strong, with: .color(base), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            ctx.stroke(weak, with: .color(base.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: [2, 3]))
            if let stage = highlighted {
                var overlay = Path()
                var lastIn: Int?
                for b in buckets {
                    let rel = Date(timeIntervalSince1970: TimeInterval(b.ts)).timeIntervalSince(timeline.onset)
                    if ranges.contains(where: { rel >= $0.0 && rel <= $0.1 }) {
                        let p = CGPoint(x: x(b.ts), y: y(b.bpm))
                        if let last = lastIn, b.ts - last <= 300 { overlay.addLine(to: p) } else { overlay.move(to: p) }
                        lastIn = b.ts
                    } else {
                        lastIn = nil
                    }
                }
                ctx.stroke(overlay, with: .color(StrandPalette.sleepStageColor(stage)),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            drawSelection(ctx, selected: selected, size: size)
            if let selected, let b = Self.bucket(at: selected, in: buckets) {
                let p = CGPoint(x: x(b.ts), y: y(b.bpm))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                         with: .color(StrandPalette.surfaceRaised))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                           with: .color(StrandPalette.restColor), lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private func movementLane(grid: [Date], selected: Date?) -> some View {
        if timeline.motion.count >= 2, timeline.motionPeak > 0 {
            laneFrame(title: "Movement", unit: nil, height: Self.motionHeight) { _ in
                Canvas { ctx, size in
                    let w = size.width, h = size.height
                    drawGrid(ctx, grid: grid, size: size)
                    var base = Path()
                    base.move(to: CGPoint(x: 0, y: h - 0.5)); base.addLine(to: CGPoint(x: w, y: h - 0.5))
                    ctx.stroke(base, with: .color(StrandPalette.hairline), lineWidth: 1)
                    // One bar per pixel column: the largest epoch that lands in it, against the night's peak.
                    var columns: [Int: Double] = [:]
                    for m in timeline.motion {
                        let col = Int((CGFloat(m.time.timeIntervalSince(timeline.onset) / timeline.span) * w).rounded(.down))
                        columns[col] = max(columns[col] ?? 0, m.value)
                    }
                    var bars = Path()
                    for (col, v) in columns {
                        let frac = CGFloat(min(1, v / timeline.motionPeak))
                        guard frac > 0.02 else { continue }
                        bars.addRect(CGRect(x: CGFloat(col), y: h - frac * (h - 1), width: 1, height: frac * (h - 1)))
                    }
                    ctx.fill(bars, with: .color(StrandPalette.textSecondary.opacity(0.7)))
                    drawSelection(ctx, selected: selected, size: size)
                }
            }
        } else {
            laneFrame(title: "Movement", unit: nil, height: Self.motionHeight) { _ in
                LaneMessage("No movement recorded")
            }
        }
    }

    /// A secondary lane: its title above the plot, the value axis in the gutter (unit on top).
    private func laneFrame<Plot: View>(title: LocalizedStringKey, unit: String?, height: CGFloat,
                                       axis: ChartYAxisLayout? = nil,
                                       @ViewBuilder plot: @escaping (CGSize) -> Plot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack(alignment: .lastTextBaseline, spacing: Self.gutterSpacing) {
                Text(unit ?? "")
                    .font(NaraChartStyle.unitFont)
                    .foregroundStyle(NaraChartStyle.axisColor)
                    .frame(width: Self.gutter, alignment: .leading)
                Text(title)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: Self.gutterSpacing) {
                ZStack(alignment: .topLeading) {
                    if let axis {
                        GeometryReader { geo in
                            let lo = axis.domain.lowerBound, hi = max(axis.domain.upperBound, lo + 1)
                            ForEach(axis.ticks.indices, id: \.self) { i in
                                let tick = axis.ticks[i]
                                Text(i < axis.labels.count ? axis.labels[i] : "")
                                    .font(NaraChartStyle.axisFont)
                                    .foregroundStyle(NaraChartStyle.axisColor)
                                    .position(x: Self.gutter / 2,
                                              y: Self.valueInset + (geo.size.height - 2 * Self.valueInset)
                                                * (1 - CGFloat((tick - lo) / (hi - lo))))
                            }
                        }
                    }
                }
                .frame(width: Self.gutter, height: height)
                GeometryReader { geo in plot(geo.size) }
                    .frame(height: height)
            }
        }
    }

    // MARK: X axis

    private func xAxis(_ axis: ChartXAxisLayout) -> some View {
        HStack(spacing: Self.gutterSpacing) {
            Color.clear.frame(width: Self.gutter, height: 1)
            GeometryReader { geo in
                ForEach(Array(axis.marks.enumerated()), id: \.offset) { i, mark in
                    if i < axis.labels.count {
                        let x = CGFloat(mark.timeIntervalSince(timeline.onset) / timeline.span) * geo.size.width
                        let anchor = i < axis.anchors.count ? axis.anchors[i] : .center
                        Text(axis.labels[i])
                            .font(NaraChartStyle.axisFont)
                            .foregroundStyle(NaraChartStyle.axisColor)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                switch anchor {
                                case .leading: return -x
                                case .trailing: return d.width - x
                                case .center: return d.width / 2 - x
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(height: Self.axisHeight)
        .padding(.top, NoopMetrics.space1)
        .accessibilityHidden(true)
    }

    // MARK: Drawing helpers

    private func drawGrid(_ ctx: GraphicsContext, grid: [Date], size: CGSize) {
        for g in grid {
            let x = CGFloat(g.timeIntervalSince(timeline.onset) / timeline.span) * size.width
            guard x > 0.5, x < size.width - 0.5 else { continue }
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(NaraChartStyle.gridColor), style: NaraChartStyle.grid)
        }
    }

    private func drawSelection(_ ctx: GraphicsContext, selected: Date?, size: CGSize) {
        guard let selected else { return }
        let x = CGFloat(selected.timeIntervalSince(timeline.onset) / timeline.span) * size.width
        var p = Path()
        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(p, with: .color(NaraChartStyle.selectionColor), style: NaraChartStyle.selectionRule)
    }

    /// The bucket nearest a time, within three minutes; nil in a gap.
    static func bucket(at date: Date, in buckets: [HRBucket]) -> HRBucket? {
        let ts = Int(date.timeIntervalSince1970)
        guard let nearest = buckets.min(by: { abs($0.ts - ts) < abs($1.ts - ts) }),
              abs(nearest.ts - ts) <= 180 else { return nil }
        return nearest
    }

    // MARK: Scrub

    @ViewBuilder
    private func scrubSurface(_ selection: Binding<Date?>) -> some View {
        GeometryReader { geo in
            #if canImport(UIKit) && os(iOS)
            HorizontalScrubSurface(
                onScrub: { select(x: $0, width: geo.size.width, selection) },
                onEnd: { set(nil, selection) },
                onTap: { x in
                    let tapped = time(x: x, width: geo.size.width)
                    set(ChartSelection.afterTap(current: selection.wrappedValue, tapped: tapped), selection)
                })
            #else
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p): select(x: p.x, width: geo.size.width, selection)
                    case .ended: set(nil, selection)
                    }
                }
            #endif
        }
    }

    /// The x position snapped to the five-minute grid, as a clock time inside the window.
    private func time(x: CGFloat, width: CGFloat) -> Date? {
        guard width > 0 else { return nil }
        let frac = min(1, max(0, Double(x / width)))
        let raw = timeline.onset.addingTimeInterval(frac * timeline.span)
        let snapped = (raw.timeIntervalSince1970 / 300).rounded() * 300
        return min(timeline.end, max(timeline.onset, Date(timeIntervalSince1970: snapped)))
    }

    private func select(x: CGFloat, width: CGFloat, _ selection: Binding<Date?>) {
        set(time(x: x, width: width), selection)
    }

    private func set(_ next: Date?, _ selection: Binding<Date?>) {
        guard next != selection.wrappedValue else { return }
        // One selection tick when the finger crosses into a different stage, not on every five minutes.
        if let next, timeline.segment(at: next)?.id != selection.wrappedValue.flatMap({ timeline.segment(at: $0)?.id }) {
            StrandHaptic.selection.play()
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { selection.wrappedValue = next }
    }

    // MARK: Accessibility

    private func axValue(_ selected: Date?) -> String {
        if let selected, let seg = timeline.segment(at: selected) {
            return "\(Night.clockString(Int(selected.timeIntervalSince1970))), \(seg.stage.label)"
        }
        let parts = [SleepStage.deep, .rem, .light, .awake].compactMap { stage -> String? in
            let m = timeline.minutes(stage)
            return m > 0 ? "\(stage.label) \(SleepFormat.duration(m))" : nil
        }
        return parts.joined(separator: ", ")
    }
}

/// The one-line empty state inside a secondary lane, centred in the lane's own frame (the lane keeps its
/// height loaded or empty, so the card never changes size).
private struct LaneMessage: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StrandPalette.surfaceInset.opacity(0.5)))
    }
}

/// DEBUG-only `--demo-chart-select <fraction>`: pre-selects a point on a scrubbable night timeline so a
/// screenshot shows the scrubbed readout (the kit charts' own hook is internal to the package).
private struct DemoSelection: ViewModifier {
    let selection: Binding<Date?>?
    let timeline: NightTimeline

    func body(content: Content) -> some View {
        #if DEBUG
        content.onAppear {
            guard let selection, selection.wrappedValue == nil,
                  let i = CommandLine.arguments.firstIndex(of: "--demo-chart-select"),
                  i + 1 < CommandLine.arguments.count,
                  let f = Double(CommandLine.arguments[i + 1]), f.isFinite else { return }
            let t = timeline.onset.addingTimeInterval(min(1, max(0, f)) * timeline.span)
            selection.wrappedValue = Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 300).rounded() * 300)
        }
        #else
        content
        #endif
    }
}

// MARK: - Stage legend (one row; tap a stage to highlight it on the chart)

/// The four stages as one row of equal columns: swatch and name, then the night's time in that stage.
/// Each column is a button that highlights its stage on the chart above (tap again to clear).
struct StageLegendRow: View {
    let stages: Stages
    @Binding var highlighted: SleepStage?
    /// Adds the share of the night under the duration (the night page's composition card).
    var showsShare: Bool = false

    private let order: [SleepStage] = [.awake, .rem, .light, .deep]

    var body: some View {
        HStack(spacing: NoopMetrics.space1) {
            ForEach(order, id: \.self) { stage in
                chip(stage)
            }
        }
    }

    private func chip(_ stage: SleepStage) -> some View {
        let minutes = Self.minutes(stage, in: stages)
        let isOn = highlighted == stage
        let dimmed = highlighted != nil && !isOn
        return Button {
            highlighted = isOn ? nil : stage
        } label: {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(StrandPalette.sleepStageColor(stage))
                        .frame(width: 8, height: 8)
                    Text(stage.label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(SleepFormat.duration(minutes))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if showsShare {
                    Text("\(Self.share(stage, in: stages)) %")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1 + 2)
            .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget, alignment: .leading)
            .background {
                if isOn { NoopInsetSurface() }
            }
            .opacity(dimmed ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(stage.label), \(SleepFormat.duration(minutes)), \(Self.share(stage, in: stages)) percent"))
        .accessibilityHint(Text("Highlights this stage on the sleep chart"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    static func minutes(_ stage: SleepStage, in s: Stages) -> Double {
        switch stage {
        case .awake: return s.awake
        case .light: return s.light
        case .deep:  return s.deep
        case .rem:   return s.rem
        }
    }

    /// Whole percentages that sum to 100 (largest remainder), the one apportionment every stage share
    /// on the Sleep surfaces prints.
    static func share(_ stage: SleepStage, in s: Stages) -> Int {
        guard let p = StagePercentages.wholePercentages([s.awake, s.light, s.deep, s.rem]) else { return 0 }
        switch stage {
        case .awake: return p[0]
        case .light: return p[1]
        case .deep:  return p[2]
        case .rem:   return p[3]
        }
    }
}

// MARK: - Stage composition (one 100 % bar)

/// The night's stage totals as one stacked bar (deep, light, REM, awake), for a night with totals but
/// no timeline (an imported night) and as the composition beside the timeline on the night page.
struct StageCompositionBar: View {
    let stages: Stages
    var highlighted: SleepStage? = nil
    var height: CGFloat = 14

    private let order: [SleepStage] = [.deep, .light, .rem, .awake]

    var body: some View {
        GeometryReader { geo in
            let total = max(1, stages.total)
            let gaps = CGFloat(order.filter { StageLegendRow.minutes($0, in: stages) > 0 }.count - 1) * 2
            let usable = max(0, geo.size.width - max(0, gaps))
            HStack(spacing: 2) {
                ForEach(order, id: \.self) { stage in
                    let m = StageLegendRow.minutes(stage, in: stages)
                    if m > 0 {
                        Rectangle()
                            .fill(StrandPalette.sleepStageColor(stage))
                            .opacity(highlighted != nil && highlighted != stage ? 0.25 : 1)
                            .frame(width: usable * CGFloat(m / total))
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep stage breakdown: deep \(StageLegendRow.share(.deep, in: stages)) percent, light \(StageLegendRow.share(.light, in: stages)) percent, REM \(StageLegendRow.share(.rem, in: stages)) percent, awake \(StageLegendRow.share(.awake, in: stages)) percent"))
    }
}
