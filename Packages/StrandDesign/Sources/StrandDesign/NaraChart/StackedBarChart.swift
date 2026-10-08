#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - StackedBarChart

/// Stacked bars per day: sleep stages, heart-rate zone minutes, macro mix. One category can be highlighted
/// (the stage a detail page is about): it sits at the BOTTOM of every stack so its height reads straight off
/// the axis, and the others step back to 30 %. `normalised` shows each day as shares of its total. Long
/// ranges bin to weekly or monthly stacks (`bin: range.totalsBin`): the mean day by default (sleep stages),
/// or the per-category totals with `aggregation: .sum` (heart-rate zone minutes, so the stack agrees with a
/// summed single-zone chart and a "Total" stat). Two entries on one day are added together. Estimated days
/// are drawn light and the legend says "Estimate".
///
/// ```swift
/// StackedBarChart(days: nights, categories: [deep, rem, light], highlighted: "deep",
///                 window: window, xStyle: range.axisStyle, y: .durationMinutes(),
///                 selection: $selected, accessibilityTitle: "Deep sleep")
/// ```
public struct StackedBarChart: View {

    public struct Category: Identifiable, Sendable {
        public var id: String
        public var name: String
        public var color: Color
        public init(id: String, name: String, color: Color) {
            self.id = id
            self.name = name
            self.color = color
        }
    }

    /// One day's values by category id. `day` is the local start of the day (the wake day for a night).
    public struct Day: Identifiable, Sendable {
        public var day: Date
        public var values: [String: Double]
        public var isEstimate: Bool
        public var id: Date { day }
        public init(day: Date, values: [String: Double], isEstimate: Bool = false) {
            self.day = day
            self.values = values
            self.isEstimate = isEstimate
        }
    }

    /// One piece of a stack, from `start` to `end` on the value axis.
    public struct Segment: Equatable, Sendable {
        public var category: String
        public var start: Double
        public var end: Double
    }

    struct Piece: Identifiable {
        let id: String
        let day: Date
        let category: String
        let start: Double
        let end: Double
        let color: Color
        let emphasised: Bool
        let isEstimate: Bool
    }

    private let pieces: [Piece]
    private let bin: Calendar.Component
    private let xLayout: ChartXAxisLayout
    private let yLayout: ChartYAxisLayout
    private let xs: [Date]
    private let state: ChartState
    private let height: CGFloat
    private let legend: [ChartLegendItem]
    private let accessibilityTitle: String
    private let summary: String
    private let descriptor: NaraChartDescriptor
    private let names: [String: String]
    private let format: @Sendable (Double) -> String
    private let unit: String?
    private let calendar: Calendar
    @Binding private var selection: Date?

    /// - Parameters:
    ///   - categories: the stack order, bottom first (the highlighted one is moved to the bottom).
    ///   - highlighted: the category drawn at full strength; nil draws them all at full strength.
    ///   - normalised: each day as percentages of its own total, on a fixed 0-100 % axis.
    ///   - bin: `.day`, `.weekOfYear` or `.month`: each stack is its bin's mean day, or its total with
    ///     `aggregation: .sum` (`Self.bin`).
    public init(days: [Day], categories: [Category], highlighted: String? = nil, normalised: Bool = false,
                bin: Calendar.Component = .day, aggregation: ChartAggregation = .mean,
                legend: [ChartLegendItem]? = nil, state: ChartState = .ready,
                window: ClosedRange<Date>, xStyle: ChartAxisStyle, y: ChartValueAxis,
                selection: Binding<Date?>, height: CGFloat = NoopMetrics.chartHeightPrimary,
                accessibilityTitle: String, calendar: Calendar = .current) {
        let window = bin == .day ? window : ChartAxis.snap(window, to: bin, calendar: calendar)
        let windowed = Self.bin(days, by: bin, aggregation: aggregation, calendar: calendar)
            .filter { $0.day >= window.lowerBound && $0.day < window.upperBound }
            .sorted { $0.day < $1.day }
        let colors = Dictionary(categories.map { ($0.id, $0.color) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var pieces: [Piece] = []
        var totals: [Double] = []
        let format = normalised ? ChartValueAxis.integer : y.format
        let unitLabel = normalised ? "%" : y.unit
        for day in windowed {
            let segments = Self.segments(day.values, order: categories.map(\.id), highlighted: highlighted,
                                         normalised: normalised)
            guard let top = segments.last?.end, top > 0 else { continue }
            totals.append(top)
            for segment in segments {
                pieces.append(Piece(id: "\(day.day.timeIntervalSince1970)|\(segment.category)", day: day.day,
                                    category: segment.category, start: segment.start, end: segment.end,
                                    color: colors[segment.category] ?? StrandPalette.textSecondary,
                                    emphasised: highlighted == nil || highlighted == segment.category,
                                    isEstimate: day.isEstimate))
            }
        }

        var axis = y
        if normalised {
            axis = ChartValueAxis(unit: "%", domain: .fixed(0...100), ticks: [0, 25, 50, 75, 100])
        } else if case let .fitted(minSpan, _, clamp, headroom) = y.domain {
            axis.domain = .fitted(minSpan: minSpan, includeZero: true, clampTo: clamp, headroom: headroom)
        }
        let yLayout = axis.layout(for: totals + [0])

        self.pieces = pieces
        self.bin = bin
        self.xLayout = ChartAxis.layout(window, style: xStyle, calendar: calendar)
        self.yLayout = yLayout
        self.xs = Array(Set(pieces.map(\.day))).sorted()
        self.state = state
        self.height = height
        self.accessibilityTitle = accessibilityTitle
        self.calendar = calendar
        self._selection = selection
        self.names = names
        self.format = format
        self.unit = unitLabel
        self.summary = NaraChartText.summary(
            title: accessibilityTitle, count: totals.count, noun: bin == .day ? .days : .bars,
            low: totals.min().map { NaraChartText.value($0, format: format, unit: unitLabel) },
            high: totals.max().map { NaraChartText.value($0, format: format, unit: unitLabel) })
        let byCategory = Dictionary(grouping: pieces, by: \.category)
        self.descriptor = NaraChartDescriptor(
            title: accessibilityTitle, summary: summary,
            xTitle: String(localized: "Date", bundle: .module), yTitle: unitLabel ?? accessibilityTitle,
            yRange: yLayout.domain,
            dateText: { NaraChartText.date($0, unit: bin, calendar: calendar) },
            valueText: { NaraChartText.value($0, format: format, unit: unitLabel) },
            series: categories.compactMap { category in
                guard let items = byCategory[category.id] else { return nil }
                return .init(name: category.name, isContinuous: false, points: items.map { ($0.day, $0.end - $0.start) })
            })
        var automatic = categories.map { ChartLegendItem(.swatch($0.color), $0.name) }
        if pieces.contains(where: \.isEstimate) {
            automatic.append(ChartLegendItem(.estimateBar(StrandPalette.textSecondary),
                                             String(localized: "Estimate", bundle: .module)))
        }
        self.legend = legend ?? automatic
    }

    /// `days` combined into one day per calendar `unit` (day, week, month), dated at the unit's start,
    /// ascending. Entries on the same local day are first added together (two sessions, two workouts). Then
    /// each category of a week or month is the average over the days in the bin (`.mean`, a missing
    /// category counting as zero for that day) or their total (`.sum`). A bin is an estimate when at least
    /// half of its days are. Non-finite values are ignored. Pure.
    public static func bin(_ days: [Day], by unit: Calendar.Component, aggregation: ChartAggregation = .mean,
                           calendar: Calendar = .current) -> [Day] {
        // One entry per local day.
        var byDay: [Date: (values: [String: Double], entries: Int, estimates: Int)] = [:]
        for day in days {
            let start = calendar.startOfDay(for: day.day)
            var entry = byDay[start] ?? ([:], 0, 0)
            for (key, value) in day.values where value.isFinite { entry.values[key, default: 0] += value }
            entry.entries += 1
            if day.isEstimate { entry.estimates += 1 }
            byDay[start] = entry
        }
        var groups: [Date: (sums: [String: Double], count: Int, estimates: Int)] = [:]
        for (start, entry) in byDay {
            let key = unit == .day ? start : (calendar.dateInterval(of: unit, for: start)?.start ?? start)
            var group = groups[key] ?? ([:], 0, 0)
            for (category, value) in entry.values { group.sums[category, default: 0] += value }
            group.count += 1
            if entry.estimates * 2 >= entry.entries { group.estimates += 1 }
            groups[key] = group
        }
        return groups.keys.sorted().compactMap { start in
            guard let group = groups[start], group.count > 0 else { return nil }
            let values = aggregation == .sum ? group.sums : group.sums.mapValues { $0 / Double(group.count) }
            return Day(day: start, values: values, isEstimate: group.estimates * 2 >= group.count)
        }
    }

    /// The pieces of one stack, bottom first: the highlighted category, then the rest in `order`, then any
    /// categories `order` does not name (sorted, so the result is stable). Missing, zero, negative and
    /// non-finite values are left out; `normalised` turns the pieces into percentages of the day's total.
    /// Pure.
    public static func segments(_ values: [String: Double], order: [String], highlighted: String? = nil,
                                normalised: Bool = false) -> [Segment] {
        var keys = order.filter { values[$0] != nil }
        keys += values.keys.filter { !order.contains($0) }.sorted()
        if let highlighted, let index = keys.firstIndex(of: highlighted) {
            keys.remove(at: index)
            keys.insert(highlighted, at: 0)
        }
        let positive = keys.compactMap { key -> (String, Double)? in
            guard let value = values[key], value.isFinite, value > 0 else { return nil }
            return (key, value)
        }
        let total = positive.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        var cursor = 0.0
        return positive.map { key, value in
            let size = normalised ? value / total * 100 : value
            defer { cursor += size }
            return Segment(category: key, start: cursor, end: cursor + size)
        }
    }

    // MARK: Body

    public var body: some View {
        NaraChartFrame(state: state, height: height, legend: legend, accessibilityTitle: accessibilityTitle) {
            chart
        }
    }

    private var chart: some View {
        let selected = selection.flatMap { calendar.dateInterval(of: bin, for: $0)?.start }
        return Chart {
            SelectionRule(selected, unit: bin)
            ForEach(pieces) { piece in
                let emphasis = piece.emphasised ? 1 : NaraChartStyle.deemphasisedOpacity
                let estimate = piece.isEstimate ? NaraChartStyle.estimateFillOpacity : 1
                let dim = selected == nil || selected == piece.day ? 1 : NaraChartStyle.dimmedOpacity
                // Square pieces: a radius on every piece would notch the stack where they meet.
                BarMark(x: .value("Day", piece.day, unit: bin),
                        yStart: .value("Start", piece.start),
                        yEnd: .value("End", piece.end),
                        width: .ratio(NaraChartStyle.barWidthRatio))
                    .foregroundStyle(piece.color.opacity(emphasis * estimate))
                    .opacity(dim)
            }
        }
        .naraChartAxes(x: xLayout, y: yLayout, calendar: calendar)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection, unit: bin, calendar: calendar)
        }
        .naraChartRangeAnimation(xLayout.window)
        .naraChartAccessibility(title: accessibilityTitle, summary: summary, descriptor: descriptor, xs: xs,
                                selection: $selection,
                                describe: { [pieces, names, format, unit, calendar, bin] date in
                                    guard let day = calendar.dateInterval(of: bin, for: date)?.start else { return nil }
                                    let stack = pieces.filter { $0.day == day }
                                    guard !stack.isEmpty else { return nil }
                                    let parts = stack.map { piece in
                                        "\(names[piece.category] ?? piece.category) \(NaraChartText.value(piece.end - piece.start, format: format, unit: unit))"
                                    }
                                    return NaraChartText.reading(day, unit: bin, parts: parts,
                                                                 isEstimate: stack.contains(where: \.isEstimate), calendar: calendar)
                                })
    }
}

#if DEBUG
private struct StackedBarChartPreview: View {
    @State private var selected: Date?
    var body: some View {
        NaraChartPreviewGallery("StackedBarChart") { sample in
            StackedBarChart(days: sample.stages(), categories: NaraChartPreviewData.stageCategories,
                            highlighted: "deep", state: sample.state, window: sample.window,
                            xStyle: sample.range.axisStyle, y: .durationMinutes(),
                            selection: $selected, accessibilityTitle: "Deep sleep")
            StackedBarChart(days: sample.stages(), categories: NaraChartPreviewData.stageCategories,
                            normalised: true, state: sample.state, window: sample.window,
                            xStyle: sample.range.axisStyle, y: .durationMinutes(), selection: $selected,
                            height: NoopMetrics.chartHeightSecondary, accessibilityTitle: "Stage share")
        }
    }
}

#Preview("StackedBarChart · light") { StackedBarChartPreview().preferredColorScheme(.light) }
#Preview("StackedBarChart · dark") { StackedBarChartPreview().preferredColorScheme(.dark) }
#endif
#endif
