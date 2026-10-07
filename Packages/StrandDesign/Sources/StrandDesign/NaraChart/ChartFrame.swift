#if !os(watchOS)
// Shared plumbing for the Swift Charts views in this folder; the watch draws no charts.
import SwiftUI
import Charts
import Accessibility

// MARK: - Frame

/// The frame every kit chart draws inside: the plot (or its loading or empty stand-in) and an optional
/// legend, at one fixed height in every state, so a page never moves when its data lands or runs out.
struct NaraChartFrame<Content: View>: View {
    let state: ChartState
    let height: CGFloat
    let legend: [ChartLegendItem]
    let accessibilityTitle: String
    @ViewBuilder let content: () -> Content
    @Environment(\.naraChartCompact) private var compact

    var body: some View {
        let showsLegend = !legend.isEmpty && !compact
        let plotHeight = max(0, height - (showsLegend ? NaraChartStyle.legendHeight + NaraChartStyle.legendSpacing : 0))
        VStack(alignment: .leading, spacing: NaraChartStyle.legendSpacing) {
            switch state {
            case .ready:
                content().frame(height: plotHeight)
            case .loading:
                ChartPlaceholder(height: plotHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(accessibilityTitle))
                    .accessibilityValue(Text("Loading", bundle: .module))
            case .empty(let message):
                EmptyChartMessage(message, height: plotHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(accessibilityTitle))
                    .accessibilityValue(Text(message))
            }
            if showsLegend { ChartLegend(legend) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
    }
}

// MARK: - Motion

extension View {
    /// Animates the marks for 0.25 s when `value` (the window) changes and never otherwise: not on
    /// selection, which updates in a non-animating transaction, and not when a value simply arrives. Off
    /// under Reduce Motion and the quiet-motion gate.
    func naraChartRangeAnimation<Value: Equatable>(_ value: Value) -> some View {
        modifier(NaraChartRangeAnimation(value: value))
    }

    /// One VoiceOver element for the chart: its title, a one-line summary (or the selected value while
    /// one is selected), the audio-graph descriptor, and an adjustable action that steps the selection
    /// through the chart's x values.
    func naraChartAccessibility(title: String, summary: String, descriptor: NaraChartDescriptor,
                                xs: [Date], selection: Binding<Date?>,
                                describe: @escaping (Date) -> String?) -> some View {
        modifier(NaraChartAccessibility(title: title, summary: summary, descriptor: descriptor, xs: xs,
                                        selection: selection, describe: describe))
    }
}

private struct NaraChartRangeAnimation<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    func body(content: Content) -> some View {
        content.animation(motion.poseStill(reduceMotion) ? nil : NaraChartStyle.rangeAnimation, value: value)
    }
}

private struct NaraChartAccessibility: ViewModifier {
    let title: String
    let summary: String
    let descriptor: NaraChartDescriptor
    let xs: [Date]
    @Binding var selection: Date?
    let describe: (Date) -> String?

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(selection.flatMap(describe) ?? summary))
            .accessibilityChartDescriptor(descriptor)
            .accessibilityAdjustableAction { direction in
                let next: Date?
                switch direction {
                case .increment: next = ChartSelection.step(from: selection, in: xs, forward: true)
                case .decrement: next = ChartSelection.step(from: selection, in: xs, forward: false)
                @unknown default: next = selection
                }
                guard next != selection else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { selection = next }
            }
    }
}

// MARK: - Audio graph

/// The audio-graph description of a kit chart: numeric x (seconds since 1970, read back as dates) and y,
/// one series per line or bar set.
struct NaraChartDescriptor: AXChartDescriptorRepresentable {
    struct Series {
        var name: String
        var isContinuous: Bool
        var points: [(x: Date, y: Double)]
    }

    var title: String
    var summary: String
    var xTitle: String
    var yTitle: String
    var yRange: ClosedRange<Double>
    var dateText: (Date) -> String
    var valueText: (Double) -> String
    var series: [Series]

    func makeChartDescriptor() -> AXChartDescriptor {
        let xs = series.flatMap { $0.points.map { $0.x.timeIntervalSince1970 } }
        let xRange = (xs.min() ?? 0)...(xs.max() ?? 1)
        let dateText = self.dateText
        let valueText = self.valueText
        let xAxis = AXNumericDataAxisDescriptor(title: xTitle, range: xRange, gridlinePositions: []) {
            dateText(Date(timeIntervalSince1970: $0))
        }
        let yAxis = AXNumericDataAxisDescriptor(title: yTitle, range: yRange, gridlinePositions: []) {
            valueText($0)
        }
        let described = series.map { item in
            AXDataSeriesDescriptor(name: item.name, isContinuous: item.isContinuous,
                                   dataPoints: item.points.map { AXDataPoint(x: $0.x.timeIntervalSince1970, y: $0.y) })
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: described)
    }
}

// MARK: - Text

/// The words a chart speaks: dates at the chart's resolution, values with their unit, and the one-line
/// summary. Shared so every chart reads its selection the same way.
enum NaraChartText {
    /// A day ("Tue, Oct 7"), a week ("Week of Sep 29"), a month ("October 2026"), or a time ("2:14 PM").
    static func date(_ date: Date, unit: Calendar.Component?, calendar: Calendar) -> String {
        switch unit {
        case .some(.weekOfYear), .some(.weekOfMonth):
            let start = ChartAxis.format(date, .dateTime.month(.abbreviated).day(), calendar)
            return String(localized: "Week of \(start)", bundle: .module)
        case .some(.month):
            return ChartAxis.format(date, .dateTime.month(.wide).year(), calendar)
        case .some(.year):
            return ChartAxis.format(date, .dateTime.year(), calendar)
        case .none:
            return ChartAxis.format(date, .dateTime.hour().minute(), calendar)
        default:
            return ChartAxis.format(date, .dateTime.weekday(.abbreviated).month(.abbreviated).day(), calendar)
        }
    }

    /// "Tue, Oct 7, 62 ms", plus ", estimate" for an estimated reading. Built when VoiceOver asks, not in a
    /// chart's `init`: the page re-creates its chart on every scrub step, and formatting a year of readings
    /// each time would cost more than drawing them.
    static func reading(_ date: Date, unit: Calendar.Component?, parts: [String], isEstimate: Bool,
                        calendar: Calendar) -> String {
        var words = [Self.date(date, unit: unit, calendar: calendar)] + parts
        if isEstimate { words.append(String(localized: "estimate", bundle: .module)) }
        return words.joined(separator: ", ")
    }

    /// "62 ms", or the bare number when the axis has no unit.
    static func value(_ value: Double, format: (Double) -> String, unit: String?) -> String {
        let number = format(value)
        guard let unit, !unit.isEmpty else { return number }
        return unit == "%" ? "\(number) %" : "\(number) \(unit)"
    }

    /// "Heart rate variability, 30 days, 56 to 104 ms".
    static func summary(title: String, count: Int, noun: Noun, low: String?, high: String?) -> String {
        guard count > 0 else { return String(localized: "\(title), no data", bundle: .module) }
        let counted: String
        switch noun {
        case .days: counted = String(localized: "\(count) days", bundle: .module)
        case .readings: counted = String(localized: "\(count) readings", bundle: .module)
        case .bars: counted = String(localized: "\(count) bars", bundle: .module)
        case .samples: counted = String(localized: "\(count) samples", bundle: .module)
        }
        guard let low, let high else { return "\(title), \(counted)" }
        if low == high { return "\(title), \(counted), \(low)" }
        return String(localized: "\(title), \(counted), \(low) to \(high)", bundle: .module)
    }

    enum Noun { case days, readings, bars, samples }
}

// MARK: - Shared marks

/// The labelled reference rules every chart draws the same way.
struct NaraReferenceMarks: ChartContent {
    let references: [ChartReference]
    let showsLabels: Bool

    var body: some ChartContent {
        ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
            RuleMark(y: .value("Reference", reference.value))
                .lineStyle(reference.style == .dashed ? NaraChartStyle.reference : NaraChartStyle.solidReference)
                .foregroundStyle(NaraChartStyle.referenceColor)
                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                    if showsLabels, let label = reference.label {
                        Text(label)
                            .font(NaraChartStyle.referenceLabelFont)
                            .foregroundStyle(NaraChartStyle.referenceColor)
                            .padding(.horizontal, 3)
                            .background(StrandPalette.surfaceRaised.opacity(0.85),
                                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }
        }
    }
}

extension ChartInterpolation {
    var method: InterpolationMethod {
        switch self {
        case .monotone: return .monotone
        case .linear: return .linear
        }
    }
}

// MARK: - Bridge from TrendPoint

public extension DailyPoint {
    /// A point for an existing `TrendPoint`, for call sites that have not moved to `DailyPoint` yet; the
    /// segment becomes the series.
    ///
    /// `dayIsUTC` is for points built from day keys parsed at UTC midnight (the detail page's parser): the
    /// day is re-read in UTC and moved to the same calendar day in `calendar`'s zone, which is what stops
    /// them plotting on the previous day west of UTC. Otherwise the point's own local day is used.
    init(_ point: TrendPoint, dayIsUTC: Bool = false, isEstimate: Bool = false, calendar: Calendar = .current) {
        let day = dayIsUTC
            ? ChartDay.day(fromUTCMidnight: point.date, calendar: calendar)
            : calendar.startOfDay(for: point.date)
        self.init(day: day, value: point.value, isEstimate: isEstimate, series: point.segment)
    }
}

extension Array where Element == DailyPoint {
    /// The points whose day lies inside `window` (start inclusive, end exclusive), ascending.
    func inWindow(_ window: ClosedRange<Date>) -> [DailyPoint] {
        filter { $0.day >= window.lowerBound && $0.day < window.upperBound }.sorted { $0.day < $1.day }
    }
}
#endif
