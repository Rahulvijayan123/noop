#if !os(watchOS)
// Swift Charts view; the watch draws no charts.
import SwiftUI
import Charts

// MARK: - DailyBarChart

/// Bars per day, week or month: one score per day coloured by its band (Charge, Rest, Effort, day stress),
/// or a daily total against a goal (steps, calories, asleep time, minutes).
///
/// Long ranges aggregate to weeks or months (`bin`), by mean or sum (`aggregation`), so a year of steps is
/// twelve readable bars rather than 365 hairlines. Bars always grow from zero. An estimated day is a light
/// bar with a solid cap and the legend says "Estimate"; a week or month is drawn that way when at least
/// half of its days are estimates (one estimated day does not make a month of measurements an estimate).
///
/// ```swift
/// DailyBarChart.scores(charge, bands: bands, window: window, xStyle: range.axisStyle,
///                      selection: $selected, accessibilityTitle: "Charge")
/// DailyBarChart.totals(steps, color: StrandPalette.metricCyan, goal: ChartReference(10_000, label: "Goal"),
///                      bin: range.totalsBin, window: window, xStyle: range.axisStyle,
///                      y: ChartValueAxis(unit: "steps", domain: .fitted(minSpan: 2_000, includeZero: true)),
///                      selection: $selected, accessibilityTitle: "Steps")
/// ```
public struct DailyBarChart: View {
    /// How bars are coloured.
    public enum Fill {
        /// One colour for every bar (totals).
        case single(Color)
        /// The colour of the score band each bar falls in (`ScoreBands` from the scorer's thresholds).
        case bands(ScoreBands)
        /// A continuous ramp over the value (Effort's `StrandPalette.effortTint(fraction:)`).
        case ramp((Double) -> Color)

        func color(for value: Double) -> Color {
            switch self {
            case .single(let color): return color
            case .bands(let bands): return bands.band(for: value).color
            case .ramp(let ramp): return ramp(value)
            }
        }
    }

    struct Bar: Identifiable {
        let day: Date
        let value: Double
        let isEstimate: Bool
        let color: Color
        var id: Date { day }
    }

    struct MeanPoint: Identifiable {
        let day: Date
        let value: Double
        let run: String
        var id: Date { day }
    }

    private let bars: [Bar]
    private let mean: [MeanPoint]
    private let references: [ChartReference]
    private let referenceAnchors: [ChartAxisLabelAnchor]
    private let bin: Calendar.Component
    private let capHeight: Double
    private let xLayout: ChartXAxisLayout
    private let yLayout: ChartYAxisLayout
    private let xs: [Date]
    private let state: ChartState
    private let height: CGFloat
    private let legend: [ChartLegendItem]
    private let accessibilityTitle: String
    private let summary: String
    private let descriptor: NaraChartDescriptor
    private let format: @Sendable (Double) -> String
    private let unit: String?
    private let calendar: Calendar
    @Binding private var selection: Date?
    @Environment(\.naraChartCompact) private var compact

    /// - Parameters:
    ///   - points: one value per day; points outside `window` are ignored (pass the whole history if that
    ///     is simpler: the trailing mean then has context before the window starts).
    ///   - bin: `.day`, `.weekOfYear` or `.month`; `ChartRange.totalsBin` picks the house rule.
    ///   - aggregation: how a week or month of days becomes one bar.
    ///   - meanLine: draw the trailing mean of this many bins as a dashed line (7 for scores); not drawn
    ///     with fewer than three bars in the window.
    ///   - reference: a goal or need rule with its label at the trailing edge.
    ///   - legend: nil for the automatic legend (mean line, estimates), `[]` for none.
    public init(points: [DailyPoint], fill: Fill, bin: Calendar.Component = .day,
                aggregation: ChartAggregation = .mean, meanLine: Int? = nil,
                reference: ChartReference? = nil, legend: [ChartLegendItem]? = nil,
                state: ChartState = .ready, window: ClosedRange<Date>, xStyle: ChartAxisStyle,
                y: ChartValueAxis, selection: Binding<Date?>,
                height: CGFloat = NoopMetrics.chartHeightPrimary, accessibilityTitle: String,
                calendar: Calendar = .current) {
        let window = bin == .day ? window : ChartAxis.snap(window, to: bin, calendar: calendar)
        let sorted = points.filter { $0.value.isFinite }.sorted { $0.day < $1.day }
        let binnedAll = Self.bin(sorted, by: bin, aggregation: aggregation, calendar: calendar)
        let binned = binnedAll.inWindow(window)

        // Fewer than three bars draw no mean line: a line through one or two values is not a trend.
        var meanPoints: [MeanPoint] = []
        if let count = meanLine, count > 1, binned.count >= 3 {
            let means = Self.trailingMean(binnedAll, count: count, unit: bin, calendar: calendar).inWindow(window)
            let runs = ChartGaps.runs(means.map(\.day), series: means.map { _ in "mean" },
                                      cadence: .sparse(maxGapDays: count * Self.daysPerUnit(bin)), calendar: calendar)
            meanPoints = zip(means, runs).map { MeanPoint(day: $0.day, value: $0.value, run: $1) }
        }

        var values = binned.map(\.value) + meanPoints.map(\.value)
        if let reference { values.append(reference.value) }
        var axis = y
        if case let .fitted(minSpan, _, clamp, headroom) = y.domain {
            axis.domain = .fitted(minSpan: minSpan, includeZero: true, clampTo: clamp, headroom: headroom)
        }
        var yLayout = axis.layout(for: values)
        if yLayout.domain.lowerBound > 0 {
            yLayout = axis.layout(domain: 0...yLayout.domain.upperBound)
        }

        self.bars = binned.map { Bar(day: $0.day, value: $0.value, isEstimate: $0.isEstimate, color: fill.color(for: $0.value)) }
        self.mean = meanPoints
        let references = reference.map { [$0] } ?? []
        self.references = references
        self.referenceAnchors = NaraReferenceLabelPlacement.anchors(
            for: references,
            marks: binned.map { .init(x: ChartDay.center(of: $0.day, unit: bin, calendar: calendar),
                                      low: min(0, $0.value), high: max(0, $0.value)) }
                + meanPoints.map { .init(x: ChartDay.center(of: $0.day, unit: bin, calendar: calendar),
                                         low: $0.value, high: $0.value) },
            window: window, domain: yLayout.domain)
        self.bin = bin
        self.capHeight = (yLayout.domain.upperBound - yLayout.domain.lowerBound) * NaraChartStyle.estimateCapShare
        self.xLayout = ChartAxis.layout(window, style: xStyle, calendar: calendar)
        self.yLayout = yLayout
        self.xs = binned.map(\.day)
        self.state = state
        self.height = height
        self.accessibilityTitle = accessibilityTitle
        self.calendar = calendar
        self._selection = selection

        let unitLabel = y.unit
        let format = y.format
        self.format = format
        self.unit = unitLabel
        let low = binned.map(\.value).min().map { NaraChartText.value($0, format: format, unit: unitLabel) }
        let high = binned.map(\.value).max().map { NaraChartText.value($0, format: format, unit: unitLabel) }
        self.summary = NaraChartText.summary(title: accessibilityTitle, count: binned.count,
                                             noun: bin == .day ? .days : .bars, low: low, high: high)
        self.descriptor = NaraChartDescriptor(
            title: accessibilityTitle, summary: summary,
            xTitle: String(localized: "Date", bundle: .module), yTitle: unitLabel ?? accessibilityTitle,
            yRange: yLayout.domain,
            dateText: { NaraChartText.date($0, unit: bin, calendar: calendar) },
            valueText: { NaraChartText.value($0, format: format, unit: unitLabel) },
            series: [.init(name: accessibilityTitle, isContinuous: false, points: binned.map { ($0.day, $0.value) })])

        if let legend {
            self.legend = legend
        } else {
            var automatic: [ChartLegendItem] = []
            if let count = meanLine, count > 1, meanPoints.count >= 2 {
                automatic.append(ChartLegendItem(.line(NaraChartStyle.meanLineColor, dashed: true),
                                                 Self.meanLabel(count: count, unit: bin)))
            }
            if binned.contains(where: \.isEstimate) {
                // Band and ramp colours vary bar to bar, so their estimate glyph is neutral.
                let color: Color
                if case .single(let single) = fill { color = single } else { color = StrandPalette.textSecondary }
                automatic.append(ChartLegendItem(.estimateBar(color), String(localized: "Estimate", bundle: .module)))
            }
            self.legend = automatic
        }
    }

    /// Charge, Rest, Effort, day stress: one score a day on its fixed scale, each bar in its band's colour,
    /// with the trailing 7-day mean.
    ///
    /// Pass `bin: range.totalsBin` so 3M reads as weekly and 6M and longer as monthly mean bars (each in the
    /// band of its mean); the mean line is drawn on daily bars only, since a weekly bar already is a mean.
    public static func scores(_ points: [DailyPoint], bands: ScoreBands, scale: ClosedRange<Double> = 0...100,
                              bin: Calendar.Component = .day, meanLine: Int? = 7, unit: String? = nil,
                              format: @escaping @Sendable (Double) -> String = ChartValueAxis.integer,
                              legend: [ChartLegendItem]? = nil, state: ChartState = .ready,
                              window: ClosedRange<Date>, xStyle: ChartAxisStyle, selection: Binding<Date?>,
                              height: CGFloat = NoopMetrics.chartHeightPrimary, accessibilityTitle: String,
                              calendar: Calendar = .current) -> DailyBarChart {
        DailyBarChart(points: points, fill: .bands(bands), bin: bin, aggregation: .mean,
                      meanLine: bin == .day ? meanLine : nil, legend: legend, state: state,
                      window: window, xStyle: xStyle,
                      y: ChartValueAxis(unit: unit, domain: .fixed(scale), format: format),
                      selection: selection, height: height, accessibilityTitle: accessibilityTitle,
                      calendar: calendar)
    }

    /// A score on a fixed scale coloured by a continuous ramp instead of bands (Effort's strain tint).
    public static func scores(_ points: [DailyPoint], ramp: @escaping (Double) -> Color,
                              scale: ClosedRange<Double> = 0...100, bin: Calendar.Component = .day,
                              meanLine: Int? = 7, unit: String? = nil,
                              format: @escaping @Sendable (Double) -> String = ChartValueAxis.integer,
                              legend: [ChartLegendItem]? = nil, state: ChartState = .ready,
                              window: ClosedRange<Date>, xStyle: ChartAxisStyle, selection: Binding<Date?>,
                              height: CGFloat = NoopMetrics.chartHeightPrimary, accessibilityTitle: String,
                              calendar: Calendar = .current) -> DailyBarChart {
        DailyBarChart(points: points, fill: .ramp(ramp), bin: bin, aggregation: .mean,
                      meanLine: bin == .day ? meanLine : nil, legend: legend, state: state,
                      window: window, xStyle: xStyle,
                      y: ChartValueAxis(unit: unit, domain: .fixed(scale), format: format),
                      selection: selection, height: height, accessibilityTitle: accessibilityTitle,
                      calendar: calendar)
    }

    /// Steps, calories, asleep time, minutes: one colour, an optional goal or need rule, and the range's
    /// bin (`ChartRange.totalsBin`) with an explicit aggregation.
    public static func totals(_ points: [DailyPoint], color: Color, goal: ChartReference?,
                              bin: Calendar.Component, aggregation: ChartAggregation = .mean,
                              legend: [ChartLegendItem]? = nil, state: ChartState = .ready,
                              window: ClosedRange<Date>, xStyle: ChartAxisStyle, y: ChartValueAxis,
                              selection: Binding<Date?>, height: CGFloat = NoopMetrics.chartHeightPrimary,
                              accessibilityTitle: String, calendar: Calendar = .current) -> DailyBarChart {
        DailyBarChart(points: points, fill: .single(color), bin: bin, aggregation: aggregation, reference: goal,
                      legend: legend, state: state, window: window, xStyle: xStyle, y: y, selection: selection,
                      height: height, accessibilityTitle: accessibilityTitle, calendar: calendar)
    }

    // MARK: Aggregation (pure)

    /// `points` combined into one point per calendar `unit` (day, week, month), dated at the unit's start,
    /// ascending. `.mean` averages the days that have a value; `.sum` totals them. A bin is an estimate when
    /// at least half of its values are. Non-finite values are ignored.
    public static func bin(_ points: [DailyPoint], by unit: Calendar.Component, aggregation: ChartAggregation,
                           calendar: Calendar = .current) -> [DailyPoint] {
        var groups: [Date: (sum: Double, count: Int, estimates: Int, series: String)] = [:]
        for point in points where point.value.isFinite {
            let start = calendar.dateInterval(of: unit, for: point.day)?.start ?? calendar.startOfDay(for: point.day)
            var group = groups[start] ?? (0, 0, 0, point.series)
            group.sum += point.value
            group.count += 1
            if point.isEstimate { group.estimates += 1 }
            groups[start] = group
        }
        return groups.keys.sorted().compactMap { start in
            guard let group = groups[start], group.count > 0 else { return nil }
            let value = aggregation == .sum ? group.sum : group.sum / Double(group.count)
            return DailyPoint(day: start, value: value, isEstimate: group.estimates * 2 >= group.count,
                              series: group.series)
        }
    }

    /// The trailing mean at each point: the average of the points within the last `count` units (the
    /// point's own unit included), over the units that have a value. Display only.
    public static func trailingMean(_ points: [DailyPoint], count: Int, unit: Calendar.Component = .day,
                                    calendar: Calendar = .current) -> [DailyPoint] {
        let sorted = points.filter { $0.value.isFinite }.sorted { $0.day < $1.day }
        guard count > 0 else { return [] }
        var out: [DailyPoint] = []
        out.reserveCapacity(sorted.count)
        var low = 0
        var sum = 0.0
        for (index, point) in sorted.enumerated() {
            sum += point.value
            let earliest = calendar.date(byAdding: unit, value: -(count - 1), to: point.day) ?? point.day
            let start = calendar.dateInterval(of: unit, for: earliest)?.start ?? earliest
            while low < index, sorted[low].day < start {
                sum -= sorted[low].value
                low += 1
            }
            out.append(DailyPoint(day: point.day, value: sum / Double(index - low + 1), series: "mean"))
        }
        return out
    }

    static func daysPerUnit(_ unit: Calendar.Component) -> Int {
        switch unit {
        case .weekOfYear, .weekOfMonth: return 7
        case .month: return 31
        case .year: return 366
        default: return 1
        }
    }

    static func meanLabel(count: Int, unit: Calendar.Component) -> String {
        switch unit {
        case .weekOfYear, .weekOfMonth: return String(localized: "\(count)-week average", bundle: .module)
        case .month: return String(localized: "\(count)-month average", bundle: .module)
        default: return String(localized: "\(count)-day average", bundle: .module)
        }
    }

    // MARK: Body

    private var selectedBin: Date? {
        selection.flatMap { calendar.dateInterval(of: bin, for: $0)?.start }
    }

    public var body: some View {
        NaraChartFrame(state: state, height: height, legend: legend, accessibilityTitle: accessibilityTitle) {
            chart
        }
    }

    private var chart: some View {
        let selected = selectedBin
        return Chart {
            SelectionRule(selected, unit: bin)
            barMarks(selected: selected)
            meanMarks
            NaraReferenceMarks(references: references)
            NaraReferenceLabels(references: references, anchors: referenceAnchors, showsLabels: !compact)
        }
        .naraChartAxes(x: xLayout, y: yLayout, calendar: calendar)
        .chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: $selection)
        }
        .naraChartRangeAnimation(xLayout.window)
        .naraChartAccessibility(title: accessibilityTitle, summary: summary, descriptor: descriptor, xs: xs,
                                selection: $selection,
                                describe: { [bars, calendar, bin, format, unit] date in
                                    guard let start = calendar.dateInterval(of: bin, for: date)?.start,
                                          let bar = bars.first(where: { $0.day == start }) else { return nil }
                                    return NaraChartText.reading(bar.day, unit: bin,
                                                                 parts: [NaraChartText.value(bar.value, format: format, unit: unit)],
                                                                 isEstimate: bar.isEstimate, calendar: calendar)
                                })
    }

    @ChartContentBuilder
    private func barMarks(selected: Date?) -> some ChartContent {
        ForEach(bars) { bar in
            let opacity = selected == nil || selected == bar.day ? 1 : NaraChartStyle.dimmedOpacity
            BarMark(x: .value("Day", bar.day, unit: bin),
                    yStart: .value("Base", 0.0),
                    yEnd: .value("Value", bar.value),
                    width: .ratio(NaraChartStyle.barWidthRatio))
                .foregroundStyle(bar.color.opacity(bar.isEstimate ? NaraChartStyle.estimateFillOpacity : 1))
                .cornerRadius(NaraChartStyle.barCornerRadius)
                .opacity(opacity)
            if bar.isEstimate {
                BarMark(x: .value("Day", bar.day, unit: bin),
                        yStart: .value("Cap", bar.value >= 0 ? bar.value - capHeight : bar.value + capHeight),
                        yEnd: .value("Value", bar.value),
                        width: .ratio(NaraChartStyle.barWidthRatio))
                    .foregroundStyle(bar.color)
                    .opacity(opacity)
            }
        }
    }

    @ChartContentBuilder
    private var meanMarks: some ChartContent {
        ForEach(mean) { point in
            LineMark(x: .value("Day", point.day, unit: bin),
                     y: .value("Average", point.value),
                     series: .value("Run", point.run))
                .interpolationMethod(.monotone)
                .lineStyle(NaraChartStyle.meanLine)
                .foregroundStyle(NaraChartStyle.meanLineColor)
        }
    }
}

#if DEBUG
private struct DailyBarChartPreview: View {
    @State private var selected: Date?
    var body: some View {
        NaraChartPreviewGallery("DailyBarChart") { sample in
            DailyBarChart.scores(sample.points(base: 58, swing: 30), bands: NaraChartPreviewData.chargeBands,
                                 unit: "%", state: sample.state, window: sample.window, xStyle: sample.range.axisStyle,
                                 selection: $selected, accessibilityTitle: "Charge")
            DailyBarChart.totals(sample.points(base: 8_400, swing: 3_000, estimateEvery: 9),
                                 color: StrandPalette.metricCyan, goal: ChartReference(10_000, label: "Goal 10,000"),
                                 bin: sample.range.totalsBin, state: sample.state, window: sample.window,
                                 xStyle: sample.range.axisStyle,
                                 y: ChartValueAxis(unit: "steps", domain: .fitted(minSpan: 2_000, includeZero: true)),
                                 selection: $selected, height: NoopMetrics.chartHeightSecondary,
                                 accessibilityTitle: "Steps")
        }
    }
}

#Preview("DailyBarChart · light") { DailyBarChartPreview().preferredColorScheme(.light) }
#Preview("DailyBarChart · dark") { DailyBarChartPreview().preferredColorScheme(.dark) }
#endif
#endif
