import Charts
import StrandDesign
import SwiftUI

// MARK: - Design tokens

enum CoachVizFont {
    static let title2 = StrandFont.title2
    static let bodySmall = Font.system(size: 14, design: .rounded)
    static let bodySmallMedium = Font.system(size: 14, weight: .medium, design: .rounded)
    static let caption = StrandFont.caption
    static let caption2 = Font.system(size: 11, design: .rounded)
    static let micro = Font.system(size: 10, design: .rounded)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
}

enum CoachVizMetric {
    static let radiusSM: CGFloat = 10
    static let radiusMD: CGFloat = 14
    static let spaceXS: CGFloat = 4
    static let spaceSM: CGFloat = 8
    static let spaceMD: CGFloat = 12
    static let spaceLG: CGFloat = 16
}

// MARK: - Palette

// MARK: - Build-up

/// How much of a visual has been drawn, 0 to 1. The image-generation reveal raises it while the pixels dissolve,
/// so the chart is seen being constructed; everywhere else it stays 1 and nothing is held back.
private struct CoachVizBuildKey: EnvironmentKey { static let defaultValue: Double = 1 }

extension EnvironmentValues {
    var coachVizBuild: Double {
        get { self[CoachVizBuildKey.self] }
        set { self[CoachVizBuildKey.self] = newValue }
    }
}

enum CoachVizBuild {
    /// `progress` remapped so it rises from 0 to 1 over the slice that starts at `delay` and lasts `span`.
    static func slice(_ progress: Double, delay: Double = 0, span: Double = 1) -> Double {
        min(1, max(0, (progress - delay) / span))
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
}

/// Uncovers its content along an axis with a soft leading edge, so lines draw in and cards fill in.
private struct CoachVizWipe: ViewModifier {
    @Environment(\.coachVizBuild) private var build
    let axis: Axis
    var delay: Double = 0
    var span: Double = 1

    func body(content: Content) -> some View {
        let soft = 0.14
        let front = CoachVizBuild.easeOut(CoachVizBuild.slice(build, delay: delay, span: span)) * (1 + soft)
        content.mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: min(1, max(0, front - soft))),
                    .init(color: .clear, location: min(1, max(0, front)))
                ],
                startPoint: axis == .horizontal ? .leading : .top,
                endPoint: axis == .horizontal ? .trailing : .bottom
            )
        )
    }
}

/// A clockwise sweep from 12 o'clock, used to draw a pie in.
private struct CoachVizSweep: Shape {
    var progress: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = Angle.degrees(-90)
        path.move(to: center)
        path.addArc(center: center, radius: max(rect.width, rect.height), startAngle: start,
                    endAngle: start + .degrees(360 * min(1, max(0, progress))), clockwise: false)
        path.closeSubpath()
        return path
    }
}

enum CoachVizPalette {
    static let series: [Color] = [
        StrandPalette.accent,
        StrandPalette.metricCyan,
        StrandPalette.metricAmber,
        StrandPalette.sleepREM,
        StrandPalette.statusPositive,
        StrandPalette.metricRose,
        StrandPalette.zone1
    ]

    static func color(_ index: Int) -> Color {
        series[index % series.count]
    }

    static func colors(count: Int) -> [Color] {
        (0..<max(count, 1)).map(color)
    }

    static func tone(_ tone: String?) -> Color {
        switch tone {
        case "positive": return StrandPalette.statusPositive
        case "negative": return StrandPalette.statusCritical
        case "warning": return StrandPalette.statusWarning
        case "info": return StrandPalette.metricCyan
        default: return StrandPalette.accent
        }
    }

    static func toneIcon(_ tone: String?) -> String {
        switch tone {
        case "positive": return "checkmark.circle.fill"
        case "negative": return "xmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "info": return "info.circle.fill"
        default: return "circle.fill"
        }
    }
}

enum CoachVizFormat {
    /// Evenly spaced indices (always including the first and last) so long axes show only a handful of labels.
    static func tickIndices(count: Int, maxLabels: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > maxLabels, maxLabels > 1 else { return Array(0..<count) }
        var indices: [Int] = []
        let last = count - 1
        for i in 0..<maxLabels {
            let idx = Int((Double(i) * Double(last) / Double(maxLabels - 1)).rounded())
            if indices.last != idx { indices.append(idx) }
        }
        return indices
    }

    static func number(_ value: Double) -> String {
        if abs(value) >= 10_000 { return String(format: "%.0f", value) }
        return value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    static func reading(_ value: Double, unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return number(value) }
        return "\(number(value)) \(unit)"
    }

    /// "HRV (ms)" -> "ms". A bare short unit ("lb") is kept; a long title with no parenthesised unit yields nil.
    static func unit(from axisTitle: String?) -> String? {
        guard let title = axisTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        if let open = title.lastIndex(of: "("), title.hasSuffix(")"), open < title.index(before: title.endIndex) {
            let inner = title[title.index(after: open)..<title.index(before: title.endIndex)]
            let unit = inner.trimmingCharacters(in: .whitespaces)
            return unit.isEmpty ? nil : unit
        }
        return title.count <= 6 && !title.contains(" ") ? title : nil
    }

    /// Filled areas encode magnitude, so their baseline is always zero (or the lowest value below it).
    static func zeroBasedDomain(_ values: [Double], fraction: Double = 0.12) -> ClosedRange<Double> {
        let lo = min(values.min() ?? 0, 0)
        let hi = max(values.max() ?? 1, lo + 1e-6)
        return lo...(hi + (hi - lo) * fraction)
    }

    static func paddedDomain(_ values: [Double], fraction: Double = 0.14) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let span = max(hi - lo, abs(hi) * 0.02, 1e-6)
        let pad = span * fraction
        return (lo - pad)...(hi + pad)
    }

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        return isoDay.date(from: iso)
    }
}

// MARK: - Card container

private struct CoachVizCard<Content: View>: View {
    let viz: CoachViz
    let content: Content

    @Environment(\.coachVizBuild) private var build

    init(viz: CoachViz, @ViewBuilder content: () -> Content) {
        self.viz = viz
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CoachVizMetric.spaceSM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viz.title)
                    .font(CoachVizFont.bodySmallMedium)
                    .foregroundColor(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = viz.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(CoachVizFont.caption2)
                        .foregroundColor(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(CoachVizBuild.slice(build, span: 0.2))

            content

            if let source = viz.source, !source.isEmpty {
                Text(source)
                    .font(CoachVizFont.micro)
                    .foregroundColor(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .opacity(CoachVizBuild.slice(build, delay: 0.8, span: 0.2))
            }
        }
        .padding(CoachVizMetric.spaceLG)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: CoachVizMetric.radiusMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CoachVizMetric.radiusMD, style: .continuous)
                .stroke(StrandPalette.hairline.opacity(0.5), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(viz.title)
    }
}

// MARK: - Entry point

/// Renders a validated `CoachViz` beneath an assistant answer.
struct CoachVizView: View, Equatable {
    let viz: CoachViz

    var body: some View {
        CoachVizCard(viz: viz) {
            switch viz.layout {
            case .chart: CoachVizChartBody(viz: viz)
            case .progress: CoachVizProgressBody(viz: viz).modifier(CoachVizWipe(axis: .vertical, delay: 0.1, span: 0.9))
            case .timeline: CoachVizTimelineBody(viz: viz).modifier(CoachVizWipe(axis: .vertical, delay: 0.1, span: 0.9))
            case .facts: CoachVizFactsBody(facts: viz.facts ?? []).modifier(CoachVizWipe(axis: .vertical, delay: 0.1, span: 0.9))
            case .table: CoachVizTableBody(columns: viz.columns ?? [], rows: viz.rows ?? []).modifier(CoachVizWipe(axis: .vertical, delay: 0.1, span: 0.9))
            case .comparison: CoachVizComparisonBody(options: viz.options ?? []).modifier(CoachVizWipe(axis: .vertical, delay: 0.1, span: 0.9))
            case .list: CoachVizListBody(items: viz.items ?? []).modifier(CoachVizWipe(axis: .vertical, delay: 0.1, span: 0.9))
            case .alerts: CoachVizAlertsBody(alerts: viz.alerts ?? []).modifier(CoachVizWipe(axis: .vertical, delay: 0.1, span: 0.9))
            case .unsupported: EmptyView()
            }
        }
    }
}

// MARK: - Generating placeholder

/// Placeholder the size of the visual it stands in for: the img-fx pixel mosaic (slowed under Reduce Motion).
/// Falls back to a dot field with a slow accent sweep only when Metal is unavailable.
struct CoachVizGeneratingView: View {
    var label: String = "Generating"
    var height: CGFloat = 220

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spacing: CGFloat = 18
    private let sweepPeriod: Double = 2.6

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if ImageFXMosaicView.isSupported {
                ImageFXMosaicView()
            } else if reduceMotion {
                dotField(phase: 0.5, animated: false)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (t.truncatingRemainder(dividingBy: sweepPeriod)) / sweepPeriod
                    dotField(phase: phase, animated: true)
                }
            }

            CoachShimmerLabel(text: label)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(StrandPalette.surfaceOverlay))
                .overlay(Capsule().stroke(StrandPalette.hairline.opacity(0.6), lineWidth: 0.5))
                .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(StrandPalette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: CoachVizMetric.radiusMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CoachVizMetric.radiusMD, style: .continuous)
                .stroke(StrandPalette.hairline.opacity(0.5), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drawing a visual")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func dotField(phase: Double, animated: Bool) -> some View {
        Canvas { context, size in
            let columns = Int(size.width / spacing) + 1
            let rows = Int(size.height / spacing) + 1
            let xOffset = (size.width - CGFloat(columns - 1) * spacing) / 2
            let yOffset = (size.height - CGFloat(rows - 1) * spacing) / 2
            // The sweep is a diagonal band travelling left to right past the card edges.
            let skew: CGFloat = 0.55
            let travel = size.width + size.height
            let center = (phase * 1.5 - 0.25) * travel
            let band = travel * 0.2

            if animated {
                // Soft accent wash that rides the same band, so the whole card shimmers, not just the dots.
                var wash = Path()
                wash.move(to: CGPoint(x: center - band, y: size.height))
                wash.addLine(to: CGPoint(x: center + band, y: size.height))
                wash.addLine(to: CGPoint(x: center + band - skew * size.height, y: 0))
                wash.addLine(to: CGPoint(x: center - band - skew * size.height, y: 0))
                wash.closeSubpath()
                let mid = CGPoint(x: center - skew * size.height / 2, y: size.height / 2)
                let t = band / (1 + skew * skew)
                context.fill(
                    wash,
                    with: .linearGradient(
                        Gradient(colors: [
                            StrandPalette.accent.opacity(0),
                            StrandPalette.accent.opacity(0.16),
                            StrandPalette.accent.opacity(0)
                        ]),
                        startPoint: CGPoint(x: mid.x - t, y: mid.y + skew * t),
                        endPoint: CGPoint(x: mid.x + t, y: mid.y - skew * t)
                    )
                )
            }

            for column in 0..<columns {
                for row in 0..<rows {
                    let x = xOffset + CGFloat(column) * spacing
                    let y = yOffset + CGFloat(row) * spacing
                    let along = x + (size.height - y) * skew
                    let lift = animated ? max(0, 1 - abs(along - center) / band) : 0
                    let eased = lift * lift * (3 - 2 * lift)
                    let radius = 1.5 + eased * 1.6
                    let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    let tint = StrandPalette.accent.opacity(0.24 + eased * 0.76)
                    context.fill(Path(ellipseIn: dot), with: .color(tint))
                }
            }
        }
        .drawingGroup(opaque: false)
    }
}

private struct CoachShimmerLabel: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            label(highlight: 0.5)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                label(highlight: (t.truncatingRemainder(dividingBy: 2.8)) / 2.8)
            }
        }
    }

    private func label(highlight: Double) -> some View {
        Text(text)
            .font(CoachVizFont.caption2)
            .foregroundColor(.clear)
            .overlay(
                GeometryReader { proxy in
                    let width = proxy.size.width
                    LinearGradient(
                        stops: [
                            .init(color: StrandPalette.textTertiary, location: 0.0),
                            .init(color: StrandPalette.textTertiary, location: 0.38),
                            .init(color: StrandPalette.accent, location: 0.5),
                            .init(color: StrandPalette.textTertiary, location: 0.62),
                            .init(color: StrandPalette.textTertiary, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 2.2)
                    .offset(x: -width * 1.3 + width * 1.4 * highlight)
                }
                .mask(Text(text).font(CoachVizFont.caption2))
            )
    }
}

// MARK: - Charts

private struct CoachVizChartBody: View {
    let viz: CoachViz
    private let points: [CoachViz.Point]
    private let indexed: [IndexedPoint]
    private let labels: [String]
    private let seriesNames: [String]
    private let waterfall: [WaterfallStep]
    private let yDomain: ClosedRange<Double>?

    @State private var selected: String?
    @Environment(\.coachVizBuild) private var build

    struct IndexedPoint: Identifiable {
        let id: Int
        let point: CoachViz.Point
    }

    struct WaterfallStep: Identifiable {
        enum Kind { case total, up, down }
        let id: Int
        let label: String
        let start: Double
        let end: Double
        let kind: Kind
    }

    init(viz: CoachViz) {
        self.viz = viz
        let pts = viz.points ?? []
        points = pts
        indexed = pts.enumerated().map { IndexedPoint(id: $0.offset, point: $0.element) }
        var seenLabels = Set<String>()
        labels = pts.compactMap(\.x).filter { seenLabels.insert($0).inserted }
        var seenSeries = Set<String>()
        seriesNames = pts.compactMap(\.series).filter { !$0.isEmpty && seenSeries.insert($0).inserted }

        var steps: [WaterfallStep] = []
        if viz.type == "waterfall" {
            var running = 0.0
            for (index, point) in pts.enumerated() {
                let label = point.x ?? ""
                if point.total == true {
                    steps.append(WaterfallStep(id: index, label: label, start: 0, end: point.y, kind: .total))
                    running = point.y
                } else {
                    let end = running + point.y
                    steps.append(WaterfallStep(id: index, label: label, start: running, end: end, kind: point.y >= 0 ? .up : .down))
                    running = end
                }
            }
        }
        waterfall = steps

        switch viz.type {
        case "line":
            yDomain = CoachVizFormat.paddedDomain(pts.map(\.y) + (viz.reference.map { [$0] } ?? []))
        case "area":
            yDomain = CoachVizFormat.zeroBasedDomain(pts.map(\.y) + (viz.reference.map { [$0] } ?? []))
        case "range":
            yDomain = CoachVizFormat.paddedDomain(pts.flatMap { [$0.low ?? $0.y, $0.high ?? $0.y] })
        case "scatter", "bubble":
            yDomain = CoachVizFormat.paddedDomain(pts.map(\.y), fraction: CoachVizLabelLayout.domainPadding(bubble: viz.type == "bubble"))
        default:
            yDomain = nil
        }
    }

    private var unit: String? { CoachVizFormat.unit(from: viz.yLabel) }
    private var yTitle: String { viz.yLabel ?? "Value" }
    private var hasSeries: Bool { seriesNames.count > 1 || (seriesNames.count == 1 && viz.type == "stacked_bar") }
    private var seriesColors: [Color] { CoachVizPalette.colors(count: seriesNames.count) }
    private var hasAxes: Bool { viz.type != "pie" }
    private var horizontalAxisTitle: String? { CoachVizAxisTitle.clean(viz.xLabel) }
    private var valueAxisTitle: String? { CoachVizAxisTitle.clean(viz.yLabel) }
    private var titleAllowance: CGFloat {
        guard hasAxes else { return 0 }
        return (viz.type == "heatmap" ? 0 : (valueAxisTitle == nil ? 0 : 22)) + (horizontalAxisTitle == nil ? 0 : 20)
    }
    private var chartHeight: CGFloat {
        switch viz.type {
        case "pie": return 168
        case "heatmap": return CGFloat(max(Set(points.compactMap(\.row)).count, 3)) * 32 + 34 + titleAllowance
        default:
            if isHorizontalBars { return CGFloat(max(labels.count, 3)) * 34 + 24 + titleAllowance }
            return 190 + titleAllowance
        }
    }
    private var isHorizontalBars: Bool { viz.horizontal == true && (viz.type == "bar" || viz.type == "stacked_bar") }
    private var isTimeAxis: Bool { viz.type == "line" || viz.type == "area" }
    private var showsZeroBaseline: Bool { ["bar", "stacked_bar", "waterfall"].contains(viz.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: CoachVizMetric.spaceSM) {
            if let readout = readout {
                HStack(alignment: .firstTextBaseline, spacing: CoachVizMetric.spaceSM) {
                    Text(readout.title)
                        .font(CoachVizFont.caption)
                        .foregroundColor(StrandPalette.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: CoachVizMetric.spaceXS)
                    Text(readout.value)
                        .font(CoachVizFont.monoSmall)
                        .foregroundColor(StrandPalette.accent)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }

            chart
                .modifier(CoachVizAxisTitles(
                    bottom: isHorizontalBars ? valueAxisTitle : horizontalAxisTitle,
                    topLeading: viz.type == "heatmap" ? nil : (isHorizontalBars ? horizontalAxisTitle : valueAxisTitle),
                    enabled: hasAxes
                ))
                .frame(height: chartHeight)

            if viz.type == "pie" {
                CoachVizPieLegend(points: points, labels: labels, unit: unit)
            } else if hasSeries {
                CoachVizSeriesLegend(names: seriesNames)
            }
            if let reference = viz.reference, isTimeAxis {
                referenceLegend(reference)
            }
            if viz.type == "heatmap" {
                heatmapLegend
            }
        }
    }

    private func referenceLegend(_ value: Double) -> some View {
        HStack(spacing: 6) {
            CoachVizDashLine()
                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .frame(width: 18, height: 2)
            Text("Reference \(CoachVizFormat.reading(value, unit: unit))")
                .font(CoachVizFont.caption2)
                .foregroundColor(StrandPalette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var heatmapLegend: some View {
        let values = points.map(\.y)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        return HStack(spacing: 6) {
            Text(valueAxisTitle.map { "Colour: \($0)" } ?? "Colour")
                .font(CoachVizFont.caption2)
                .foregroundColor(StrandPalette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(CoachVizFormat.number(low))
                .font(CoachVizFont.caption2)
                .foregroundColor(StrandPalette.textTertiary)
                .monospacedDigit()
            Capsule()
                .fill(LinearGradient(colors: [StrandPalette.accent.opacity(0.10), StrandPalette.accent], startPoint: .leading, endPoint: .trailing))
                .frame(width: 56, height: 6)
            Text(CoachVizFormat.number(high))
                .font(CoachVizFont.caption2)
                .foregroundColor(StrandPalette.textTertiary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Readout

    private var isSelectable: Bool {
        ["line", "area", "bar", "range"].contains(viz.type) && !isHorizontalBars
    }

    private var readout: (title: String, value: String)? {
        guard isSelectable else { return nil }
        let target = selected ?? labels.last
        guard let target else { return nil }
        let matches = points.filter { $0.x == target }
        guard !matches.isEmpty else { return nil }
        if matches.count == 1, let point = matches.first {
            if viz.type == "range", let low = point.low, let high = point.high {
                return (target, "\(CoachVizFormat.number(low))–\(CoachVizFormat.number(high))\(unit.map { " \($0)" } ?? "")")
            }
            return (target, CoachVizFormat.reading(point.y, unit: unit))
        }
        let value = matches.prefix(3).map { point in
            "\(point.series ?? "") \(CoachVizFormat.number(point.y))".trimmingCharacters(in: .whitespaces)
        }.joined(separator: " · ")
        return (target, value)
    }

    // MARK: Chart bodies

    @ViewBuilder
    private var chart: some View {
        switch viz.type {
        case "bar", "stacked_bar": barChart
        case "line": lineChart(filled: false).modifier(CoachVizWipe(axis: .horizontal, delay: 0.05, span: 0.95))
        case "area": lineChart(filled: true).modifier(CoachVizWipe(axis: .horizontal, delay: 0.05, span: 0.95))
        case "pie": pieChart.mask(CoachVizSweep(progress: CoachVizBuild.easeOut(CoachVizBuild.slice(build, delay: 0.05, span: 0.95))))
        case "scatter", "bubble": scatterChart.modifier(CoachVizWipe(axis: .horizontal, delay: 0.05, span: 0.95))
        case "heatmap": heatmapChart.modifier(CoachVizWipe(axis: .horizontal, delay: 0.05, span: 0.95))
        case "waterfall": waterfallChart.modifier(CoachVizWipe(axis: .horizontal, delay: 0.05, span: 0.95))
        case "range": rangeChart.modifier(CoachVizWipe(axis: .horizontal, delay: 0.05, span: 0.95))
        default: EmptyView()
        }
    }

    private var goldFill: LinearGradient {
        LinearGradient(
            colors: [StrandPalette.accent.opacity(0.95), StrandPalette.accent.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var barChart: some View {
        let stacked = viz.type == "stacked_bar"
        let horizontal = isHorizontalBars
        let extent = barExtent(stacked: stacked)
        return Chart {
            ForEach(indexed) { item in
                barMark(grown(item.point), horizontal: horizontal, stacked: stacked)
            }
            // While the bars grow, invisible marks at the final extremes keep the axis where it will end up.
            if build < 1 {
                if horizontal {
                    RuleMark(x: .value(yTitle, extent.upperBound)).opacity(0)
                    RuleMark(x: .value(yTitle, extent.lowerBound)).opacity(0)
                } else {
                    RuleMark(y: .value(yTitle, extent.upperBound)).opacity(0)
                    RuleMark(y: .value(yTitle, extent.lowerBound)).opacity(0)
                }
            }
        }
        .chartForegroundStyleScale(domain: hasSeries ? seriesNames : [], range: seriesColors)
        .chartLegend(.hidden)
        .modifier(CoachVizZeroBaseline(horizontal: horizontal))
        .chartXAxis {
            if horizontal { valueAxis(.bottom) } else { categoryAxis() }
        }
        .chartYAxis {
            if horizontal { categoryAxisLeading() } else { valueAxis(.leading) }
        }
        .modifier(CoachVizSelection(enabled: isSelectable, selection: $selected))
    }

    /// The lowest and highest edge any bar reaches, zero included.
    private func barExtent(stacked: Bool) -> ClosedRange<Double> {
        var high = 0.0, low = 0.0
        if stacked {
            var positive: [String: Double] = [:], negative: [String: Double] = [:]
            for p in points {
                let key = p.x ?? ""
                if p.y >= 0 { positive[key, default: 0] += p.y } else { negative[key, default: 0] += p.y }
            }
            high = positive.values.max() ?? 0
            low = negative.values.min() ?? 0
        } else {
            high = max(0, points.map(\.y).max() ?? 0)
            low = min(0, points.map(\.y).min() ?? 0)
        }
        return low...max(high, low)
    }

    /// A bar part-way through growing: bars rise from the baseline one after another.
    private func grown(_ p: CoachViz.Point) -> CoachViz.Point {
        guard build < 1 else { return p }
        let index = Double(labels.firstIndex(of: p.x ?? "") ?? 0)
        let delay = 0.5 * index / Double(max(labels.count - 1, 1))
        var q = p
        q.y = p.y * CoachVizBuild.easeOut(CoachVizBuild.slice(build, delay: delay, span: 0.5))
        return q
    }

    @ChartContentBuilder
    private func barMark(_ p: CoachViz.Point, horizontal: Bool, stacked: Bool) -> some ChartContent {
        if horizontal {
            if hasSeries {
                BarMark(x: .value(yTitle, p.y), y: .value("Category", p.x ?? ""))
                    .foregroundStyle(by: .value("Series", p.series ?? ""))
                    .cornerRadius(3)
            } else {
                BarMark(x: .value(yTitle, p.y), y: .value("Category", p.x ?? ""))
                    .foregroundStyle(goldFill)
                    .cornerRadius(3)
            }
        } else if hasSeries {
            if stacked {
                BarMark(x: .value("Category", p.x ?? ""), y: .value(yTitle, p.y))
                    .foregroundStyle(by: .value("Series", p.series ?? ""))
                    .cornerRadius(2)
            } else {
                BarMark(x: .value("Category", p.x ?? ""), y: .value(yTitle, p.y))
                    .foregroundStyle(by: .value("Series", p.series ?? ""))
                    .position(by: .value("Series", p.series ?? ""))
                    .cornerRadius(2)
            }
        } else {
            BarMark(x: .value("Category", p.x ?? ""), y: .value(yTitle, p.y), width: .ratio(0.62))
                .foregroundStyle(goldFill)
                .cornerRadius(3)
        }
    }

    private func lineChart(filled: Bool) -> some View {
        Chart {
            ForEach(indexed) { item in
                lineMarks(item.point, filled: filled)
            }
            if let reference = viz.reference {
                RuleMark(y: .value("Reference", reference))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            if let selected {
                RuleMark(x: .value("Selected", selected))
                    .foregroundStyle(StrandPalette.accent.opacity(0.35))
            }
        }
        .chartForegroundStyleScale(domain: hasSeries ? seriesNames : [], range: seriesColors)
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain ?? 0...1)
        .chartXAxis { categoryAxis() }
        .chartYAxis { valueAxis(.leading) }
        .modifier(CoachVizSelection(enabled: true, selection: $selected))
    }

    @ChartContentBuilder
    private func lineMarks(_ p: CoachViz.Point, filled: Bool) -> some ChartContent {
        let seriesKey = p.series ?? ""
        if hasSeries {
            LineMark(x: .value("Category", p.x ?? ""), y: .value(yTitle, p.y), series: .value("Series", seriesKey))
                .foregroundStyle(by: .value("Series", seriesKey))
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            if filled {
                AreaMark(x: .value("Category", p.x ?? ""), y: .value(yTitle, p.y), series: .value("Series", seriesKey), stacking: .unstacked)
                    .foregroundStyle(by: .value("Series", seriesKey))
                    .opacity(0.16)
                    .interpolationMethod(.monotone)
            }
        } else {
            LineMark(x: .value("Category", p.x ?? ""), y: .value(yTitle, p.y))
                .foregroundStyle(StrandPalette.accent)
                .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            if filled {
                AreaMark(x: .value("Category", p.x ?? ""), yStart: .value("Floor", 0), yEnd: .value(yTitle, p.y))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [StrandPalette.accent.opacity(0.30), StrandPalette.accent.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
            }
            if points.count <= 14 || p.x == selected {
                PointMark(x: .value("Category", p.x ?? ""), y: .value(yTitle, p.y))
                    .foregroundStyle(StrandPalette.accent)
                    .symbolSize(p.x == selected ? 70 : 28)
            }
        }
    }

    private var pieChart: some View {
        Chart(indexed) { item in
            SectorMark(
                angle: .value(yTitle, max(item.point.y, 0)),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(4)
            .foregroundStyle(by: .value("Slice", item.point.x ?? ""))
        }
        .chartForegroundStyleScale(domain: labels, range: CoachVizPalette.colors(count: labels.count))
        .chartLegend(.hidden)
    }

    private var scatterChart: some View {
        let bubble = viz.type == "bubble"
        let xs = points.compactMap(\.xValue)
        let xDomain = CoachVizFormat.paddedDomain(xs, fraction: CoachVizLabelLayout.domainPadding(bubble: bubble))
        let shown = scatterLabelIDs(xDomain: xDomain)
        return Chart(indexed) { item in
            let p = item.point
            if bubble {
                PointMark(x: .value(viz.xLabel ?? "X", p.xValue ?? 0), y: .value(yTitle, p.y))
                    .symbolSize(by: .value("Size", p.size ?? 1))
                    .foregroundStyle(StrandPalette.accent.opacity(0.62))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        if let label = p.label, shown.contains(item.id) {
                            Text(label)
                                .font(CoachVizFont.micro)
                                .foregroundColor(StrandPalette.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
            } else {
                PointMark(x: .value(viz.xLabel ?? "X", p.xValue ?? 0), y: .value(yTitle, p.y))
                    .symbolSize(58)
                    .foregroundStyle(StrandPalette.accent)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        if let label = p.label, shown.contains(item.id) {
                            Text(label)
                                .font(CoachVizFont.micro)
                                .foregroundColor(StrandPalette.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
            }
        }
        .chartSymbolSizeScale(range: 90...900)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain ?? 0...1)
        .chartXAxis { valueAxis(.bottom) }
        .chartYAxis { valueAxis(.leading) }
        .chartLegend(.hidden)
    }

    /// Points whose labels can be drawn without landing on another label or mark. Unlabelled overlap is hidden, never drawn over.
    private func scatterLabelIDs(xDomain: ClosedRange<Double>) -> Set<Int> {
        guard points.count <= 8 else { return [] }
        let sizes = points.compactMap(\.size)
        let smin = sizes.min() ?? 0
        let smax = sizes.max() ?? 1
        let bubble = viz.type == "bubble"
        let marks = indexed.compactMap { item -> CoachVizLabelLayout.Mark? in
            guard let x = item.point.xValue else { return nil }
            var radius = 4.0
            if bubble {
                let t = smax > smin ? ((item.point.size ?? smin) - smin) / (smax - smin) : 0
                radius = (90 + t * 810).squareRoot() / 2
            }
            return CoachVizLabelLayout.Mark(id: item.id, x: x, y: item.point.y, radius: radius, label: item.point.label)
        }
        return CoachVizLabelLayout.visibleLabels(marks: marks, xDomain: xDomain, yDomain: yDomain ?? 0...1)
    }

    private var heatmapChart: some View {
        let showValues = points.count <= 42
        let low = points.map(\.y).min() ?? 0
        let high = points.map(\.y).max() ?? 1
        return Chart(indexed) { item in
            let p = item.point
            RectangleMark(
                x: .value("Column", p.x ?? ""),
                y: .value("Row", p.row ?? ""),
                width: .ratio(0.94),
                height: .ratio(0.94)
            )
            .foregroundStyle(by: .value("Value", p.y))
            .cornerRadius(3)
            .annotation(position: .overlay) {
                if showValues {
                    Text(CoachVizFormat.number(p.y))
                        .font(CoachVizFont.micro)
                        .foregroundColor(high > low && (p.y - low) / (high - low) > 0.55 ? .black.opacity(0.8) : StrandPalette.textSecondary)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
        }
        .chartForegroundStyleScale(range: Gradient(colors: [StrandPalette.accent.opacity(0.10), StrandPalette.accent]))
        .chartLegend(.hidden)
        .chartXAxis { categoryAxis() }
        .chartYAxis { categoryAxisLeading() }
    }

    private var waterfallChart: some View {
        Chart(waterfall) { step in
            BarMark(
                x: .value("Step", step.label),
                yStart: .value("From", step.start),
                yEnd: .value("To", step.end),
                width: .ratio(0.62)
            )
            .foregroundStyle(color(for: step.kind))
            .cornerRadius(3)
        }
        .chartLegend(.hidden)
        .modifier(CoachVizZeroBaseline(horizontal: false))
        .chartXAxis { categoryAxis() }
        .chartYAxis { valueAxis(.leading) }
    }

    private func color(for kind: WaterfallStep.Kind) -> Color {
        switch kind {
        case .total: return StrandPalette.accent
        case .up: return StrandPalette.statusPositive
        case .down: return StrandPalette.statusCritical
        }
    }

    private var rangeChart: some View {
        Chart(indexed) { item in
            let p = item.point
            RuleMark(
                x: .value("Category", p.x ?? ""),
                yStart: .value("Low", p.low ?? p.y),
                yEnd: .value("High", p.high ?? p.y)
            )
            .lineStyle(StrokeStyle(lineWidth: 9, lineCap: .round))
            .foregroundStyle(StrandPalette.accent.opacity(0.42))
            if p.midpoint != true {
                PointMark(x: .value("Category", p.x ?? ""), y: .value(yTitle, p.y))
                    .symbolSize(52)
                    .foregroundStyle(StrandPalette.accent)
            }
            if p.x == selected {
                RuleMark(x: .value("Selected", p.x ?? ""))
                    .foregroundStyle(StrandPalette.accent.opacity(0.3))
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain ?? 0...1)
        .chartXAxis { categoryAxis() }
        .chartYAxis { valueAxis(.leading) }
        .modifier(CoachVizSelection(enabled: true, selection: $selected))
    }

    // MARK: Axes

    /// Time axes thin to five ticks; categorical axes name every bar, column, or step (up to eight).
    private var tickLabels: [String] {
        CoachVizFormat.tickIndices(count: labels.count, maxLabels: isTimeAxis ? 5 : 8).map { labels[$0] }
    }

    private var categorySlotWidth: CGFloat {
        max(28, 250 / CGFloat(max(tickLabels.count, 1)))
    }

    @AxisContentBuilder
    private func categoryAxis() -> some AxisContent {
        AxisMarks(values: tickLabels) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                .foregroundStyle(Color.white.opacity(0.06))
            AxisTick().foregroundStyle(Color.white.opacity(0.22))
            AxisValueLabel(anchor: .top) {
                if let label = value.as(String.self) {
                    Text(label)
                        .font(tickLabels.count > 5 && !isTimeAxis ? CoachVizFont.micro : CoachVizFont.caption2)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(isTimeAxis ? 1 : 2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: isTimeAxis ? nil : categorySlotWidth)
                        .padding(.top, 4)
                }
            }
        }
    }

    @AxisContentBuilder
    private func categoryAxisLeading() -> some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisValueLabel {
                if let label = value.as(String.self) {
                    Text(label)
                        .font(CoachVizFont.caption2)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    @AxisContentBuilder
    private func valueAxis(_ position: AxisMarkPosition) -> some AxisContent {
        AxisMarks(position: position, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                .foregroundStyle(Color.white.opacity(0.08))
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(CoachVizFormat.number(number))
                        .font(CoachVizFont.caption2)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .monospacedDigit()
                }
            }
        }
    }
}

private enum CoachVizAxisTitle {
    static func clean(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Draws the two axis titles: the measure above the value axis, the dimension under the other.
private struct CoachVizAxisTitles: ViewModifier {
    let bottom: String?
    let topLeading: String?
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .chartXAxisLabel(position: .bottom, alignment: .center, spacing: 6) { title(bottom) }
                .chartYAxisLabel(position: .top, alignment: .leading, spacing: 8) { title(topLeading) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func title(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(CoachVizFont.caption2.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Bars and waterfalls are read by length, so their value axis always starts at zero.
private struct CoachVizZeroBaseline: ViewModifier {
    let horizontal: Bool

    func body(content: Content) -> some View {
        if horizontal {
            content.chartXScale(domain: .automatic(includesZero: true))
        } else {
            content.chartYScale(domain: .automatic(includesZero: true))
        }
    }
}

private struct CoachVizDashLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// Decides which point labels can be drawn without covering another label or mark.
/// Mirrors the worker's `labelCollisions` estimate (250 x 140 pt plot, 5.4 pt per character).
enum CoachVizLabelLayout {
    struct Mark: Equatable {
        let id: Int
        let x: Double
        let y: Double
        let radius: Double
        let label: String?
    }

    static let plot = CGSize(width: 250, height: 140)
    static let characterWidth = 5.4
    static let labelHeight = 12.0
    static let gap = 2.0
    static let clearance = 1.5

    /// Head-room that keeps a label above the top-most point inside the plot.
    static func domainPadding(bubble: Bool) -> Double { bubble ? 0.32 : 0.2 }

    static func visibleLabels(
        marks: [Mark],
        xDomain: ClosedRange<Double>,
        yDomain: ClosedRange<Double>,
        plot: CGSize = CoachVizLabelLayout.plot
    ) -> Set<Int> {
        let xSpan = max(xDomain.upperBound - xDomain.lowerBound, 1e-9)
        let ySpan = max(yDomain.upperBound - yDomain.lowerBound, 1e-9)
        struct Box { var x, y, w, h: Double }
        func hit(_ a: Box, _ b: Box) -> Bool {
            a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
        }
        let placed: [(mark: Mark, center: CGPoint, marker: Box)] = marks.map { mark in
            let px = (mark.x - xDomain.lowerBound) / xSpan * plot.width
            let py = plot.height - (mark.y - yDomain.lowerBound) / ySpan * plot.height
            let reach = mark.radius + clearance
            return (mark, CGPoint(x: px, y: py), Box(x: px - reach, y: py - reach, w: reach * 2, h: reach * 2))
        }
        func textBox(_ item: (mark: Mark, center: CGPoint, marker: Box)) -> Box? {
            guard let label = item.mark.label, !label.isEmpty else { return nil }
            let width = Double(label.count) * characterWidth
            let left = min(max(item.center.x - width / 2, 0), max(plot.width - width, 0))
            let top = item.center.y - item.mark.radius - gap - labelHeight
            guard top >= -2 else { return nil }
            return Box(x: left, y: top, w: width, h: labelHeight)
        }
        var accepted: [(id: Int, box: Box)] = []
        let order = placed.sorted { ($0.mark.radius, -Double($0.mark.id)) > ($1.mark.radius, -Double($1.mark.id)) }
        for item in order {
            guard let box = textBox(item) else { continue }
            let onMark = placed.contains { $0.mark.id != item.mark.id && hit(box, $0.marker) }
            let onLabel = accepted.contains { hit(box, $0.box) }
            if !onMark && !onLabel { accepted.append((item.mark.id, box)) }
        }
        return Set(accepted.map(\.id))
    }
}

private struct CoachVizSelection: ViewModifier {
    let enabled: Bool
    @Binding var selection: String?

    func body(content: Content) -> some View {
        if enabled {
            content.chartXSelection(value: $selection)
        } else {
            content
        }
    }
}

private struct CoachVizSeriesLegend: View {
    let names: [String]

    var body: some View {
        HStack(spacing: CoachVizMetric.spaceMD) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 5) {
                    Circle().fill(CoachVizPalette.color(index)).frame(width: 7, height: 7)
                    Text(name)
                        .font(CoachVizFont.caption2)
                        .foregroundColor(StrandPalette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CoachVizPieLegend: View {
    let points: [CoachViz.Point]
    let labels: [String]
    let unit: String?

    var body: some View {
        let total = points.reduce(0) { $0 + max($1.y, 0) }
        VStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let value = points.first(where: { $0.x == label })?.y ?? 0
                HStack(spacing: 8) {
                    Circle().fill(CoachVizPalette.color(index)).frame(width: 8, height: 8)
                    Text(label)
                        .font(CoachVizFont.caption2)
                        .foregroundColor(StrandPalette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(CoachVizFormat.reading(value, unit: unit))
                        .font(CoachVizFont.caption2)
                        .foregroundColor(StrandPalette.textPrimary)
                        .monospacedDigit()
                    if total > 0 {
                        Text("\(Int((value / total * 100).rounded()))%")
                            .font(CoachVizFont.caption2)
                            .foregroundColor(StrandPalette.textTertiary)
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Goal progress

private struct CoachVizProgressBody: View {
    let viz: CoachViz

    var body: some View {
        VStack(spacing: CoachVizMetric.spaceMD) {
            ForEach(Array((viz.points ?? []).enumerated()), id: \.offset) { _, point in
                let target = point.target ?? 0
                let ratio = target > 0 ? point.y / target : 0
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(point.x ?? "")
                            .font(CoachVizFont.caption)
                            .foregroundColor(StrandPalette.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(CoachVizFormat.number(point.y)) / \(CoachVizFormat.reading(target, unit: CoachVizFormat.unit(from: viz.yLabel)))")
                            .font(CoachVizFont.monoSmall)
                            .foregroundColor(ratio >= 1 ? StrandPalette.statusPositive : StrandPalette.accent)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(ratio >= 1 ? StrandPalette.statusPositive : StrandPalette.accent)
                                .frame(width: max(6, proxy.size.width * min(max(ratio, 0), 1)))
                        }
                    }
                    .frame(height: 8)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Timeline

private struct CoachVizTimelineBody: View {
    let viz: CoachViz

    private struct Bar: Identifiable {
        let id: String
        let name: String
        let group: String
        let start: Date
        let end: Date
    }

    private var bars: [Bar] {
        (viz.tasks ?? []).compactMap { task in
            guard let start = CoachVizFormat.date(task.start), let end = CoachVizFormat.date(task.end) else { return nil }
            return Bar(id: task.id, name: task.name, group: task.group ?? "", start: start, end: max(end, start))
        }
    }

    var body: some View {
        if viz.type == "gantt", !bars.isEmpty {
            gantt
        } else {
            milestones
        }
    }

    private var gantt: some View {
        let groups = Array(Set(bars.map(\.group))).sorted()
        return Chart(bars) { bar in
            BarMark(
                xStart: .value("Start", bar.start),
                xEnd: .value("End", bar.end),
                y: .value("Task", bar.name),
                height: .ratio(0.62)
            )
            .foregroundStyle(by: .value("Group", bar.group))
            .cornerRadius(4)
        }
        .chartForegroundStyleScale(domain: groups, range: CoachVizPalette.colors(count: groups.count))
        .chartLegend(groups.count > 1 && !(groups.first?.isEmpty ?? true) ? .visible : .hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3)).foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), anchor: .top)
                    .font(CoachVizFont.caption2)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(CoachVizFont.caption2)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: 96, alignment: .trailing)
                    }
                }
            }
        }
        .frame(height: CGFloat(max(bars.count, 3)) * 34 + 30)
    }

    private var milestones: some View {
        let ordered = (viz.tasks ?? []).sorted { $0.start < $1.start }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { index, task in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle().fill(StrandPalette.accent).frame(width: 9, height: 9)
                        if index < ordered.count - 1 {
                            Rectangle().fill(StrandPalette.hairline).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayDate(task.start))
                            .font(CoachVizFont.caption2)
                            .foregroundColor(StrandPalette.accent)
                        Text(task.name)
                            .font(CoachVizFont.bodySmall)
                            .foregroundColor(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func displayDate(_ iso: String) -> String {
        guard let date = CoachVizFormat.date(iso) else { return iso }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Cards

private struct CoachVizFactsBody: View {
    let facts: [CoachViz.Fact]
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 3) {
                    Text(fact.value)
                        .font(CoachVizFont.title2)
                        .foregroundColor(CoachVizPalette.tone(fact.tone))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(fact.label)
                        .font(CoachVizFont.caption2)
                        .foregroundColor(StrandPalette.textSecondary)
                        .lineLimit(2)
                    if let detail = fact.detail, !detail.isEmpty {
                        Text(detail)
                            .font(CoachVizFont.micro)
                            .foregroundColor(StrandPalette.textTertiary)
                            .lineLimit(2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset)
                .clipShape(RoundedRectangle(cornerRadius: CoachVizMetric.radiusSM, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct CoachVizTableBody: View {
    let columns: [String]
    let rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            row(columns, isHeader: true, shaded: false)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                row(cells, isHeader: false, shaded: index % 2 == 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CoachVizMetric.radiusSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CoachVizMetric.radiusSM, style: .continuous)
                .stroke(StrandPalette.hairline.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func row(_ cells: [String], isHeader: Bool, shaded: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell)
                    .font(isHeader ? CoachVizFont.caption : CoachVizFont.caption2)
                    .foregroundColor(isHeader ? StrandPalette.accent : (index == 0 ? StrandPalette.textPrimary : StrandPalette.textSecondary))
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : .trailing)
                    .multilineTextAlignment(index == 0 ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isHeader ? StrandPalette.accent.opacity(0.10) : (shaded ? StrandPalette.surfaceInset : Color.clear))
    }
}

private struct CoachVizComparisonBody: View {
    let options: [CoachViz.Option]
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(options) { option in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(option.name)
                            .font(CoachVizFont.caption)
                            .foregroundColor(StrandPalette.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 2)
                        if let badge = option.badge, !badge.isEmpty {
                            Text(badge)
                                .font(CoachVizFont.micro)
                                .foregroundColor(StrandPalette.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(StrandPalette.accent.opacity(0.14)))
                        }
                    }
                    ForEach(option.facts) { fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.value)
                                .font(CoachVizFont.bodySmallMedium)
                                .foregroundColor(StrandPalette.accent)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text(fact.label)
                                .font(CoachVizFont.micro)
                                .foregroundColor(StrandPalette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset)
                .clipShape(RoundedRectangle(cornerRadius: CoachVizMetric.radiusSM, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct CoachVizListBody: View {
    let items: [CoachViz.Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(CoachVizFont.micro)
                        .foregroundColor(StrandPalette.accent)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(StrandPalette.accent.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(CoachVizFont.bodySmall)
                            .foregroundColor(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(CoachVizFont.caption2)
                                .foregroundColor(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if let tag = item.tag, !tag.isEmpty {
                        Text(tag)
                            .font(CoachVizFont.micro)
                            .foregroundColor(StrandPalette.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(StrandPalette.surfaceInset))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct CoachVizAlertsBody: View {
    let alerts: [CoachViz.Alert]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(alerts) { alert in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: CoachVizPalette.toneIcon(alert.tone))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(CoachVizPalette.tone(alert.tone))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title)
                            .font(CoachVizFont.bodySmallMedium)
                            .foregroundColor(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = alert.detail, !detail.isEmpty {
                            Text(detail)
                                .font(CoachVizFont.caption2)
                                .foregroundColor(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(CoachVizPalette.tone(alert.tone).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: CoachVizMetric.radiusSM, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
