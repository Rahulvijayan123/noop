import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// MARK: - The primary chart

/// The detail page's primary chart: the kit chart `MetricPresentation` picks for this metric, fed the
/// frame's local-day points in display units. One frame height in every state (loading, empty, ready).
struct MetricPrimaryChart: View {
    let frame: MetricDetailFrame
    let title: String
    let state: ChartState
    let showsSDNN: Bool
    @Binding var selection: Date?

    private var height: CGFloat { NoopMetrics.chartHeightPrimary }

    var body: some View {
        let f = frame
        let p = f.presentation
        switch p.chart {
        case .scoreBars(let fill):
            scoreBars(fill)
        case .totals:
            totals
        case .line(let minSpan):
            line(minSpan: minSpan)
        case .fixedPoints(let domain, let reference, let joined):
            DailyLineChart.fixedDomainPoints(
                f.chartPoints, domain: domain,
                reference: reference.map { ChartReference($0, label: "\($0.formatted(.number.precision(.fractionLength(0)))) %") },
                color: p.tint.color, joined: joined, state: state, window: f.window,
                xStyle: f.chartRange.axisStyle, selection: $selection, height: height,
                accessibilityTitle: title, calendar: f.calendar)
        case .diverging:
            let edge = f.divergingReference
            DivergingBarChart(points: f.chartPoints, positive: StrandPalette.metricAmber,
                              negative: StrandPalette.metricCyan,
                              positiveLabel: String(localized: "Warmer"), negativeLabel: String(localized: "Cooler"),
                              references: [ChartReference(edge), ChartReference(-edge)], bin: f.bin,
                              state: state, window: f.window, xStyle: f.chartRange.axisStyle,
                              y: ChartValueAxis(unit: f.axisUnit, domain: .symmetric(minMagnitude: edge),
                                                format: ChartValueAxis.decimals(1)),
                              selection: $selection, height: height, accessibilityTitle: title,
                              calendar: f.calendar)
        case .stacked(let kind):
            if let stack = f.stack {
                StackedBarChart(days: stack.days, categories: stack.categories, highlighted: stack.highlighted,
                                bin: f.bin, state: state, window: f.window, xStyle: f.chartRange.axisStyle,
                                y: kind == .zones
                                    ? ChartValueAxis(unit: "min", domain: .fitted(minSpan: 30, includeZero: true))
                                    : ChartValueAxis.durationMinutes(),
                                selection: $selection, height: height, accessibilityTitle: title,
                                calendar: f.calendar)
            } else {
                totals
            }
        case .stepLine(let fixed, let minSpan):
            StepLineChart(points: f.chartPoints, color: p.tint.color,
                          reference: f.age.map { ChartReference(Double($0), label: String(localized: "Your age")) }
                              .flatMap { p.referencesAge ? $0 : nil },
                          state: state, window: f.window, xStyle: f.chartRange.axisStyle,
                          y: ChartValueAxis(unit: f.axisUnit,
                                            domain: fixed.map { .fixed($0) } ?? .fitted(minSpan: minSpan),
                                            format: p.axisFormat()),
                          selection: $selection, height: height, accessibilityTitle: title, calendar: f.calendar)
        case .sparsePoints(let minSpan, let references):
            SparsePointsChart(points: f.chartPoints, color: p.tint.color,
                              references: references.map { ChartReference($0, label: $0.formatted()) },
                              state: state, window: f.window, xStyle: f.chartRange.axisStyle,
                              y: ChartValueAxis(unit: f.axisUnit, domain: .fitted(minSpan: minSpan),
                                                format: ChartValueAxis.decimals(1)),
                              selection: $selection, height: height, accessibilityTitle: title, calendar: f.calendar)
        case .dotStrip:
            DotStripChart(points: f.chartPoints, levels: 1...5, levelLabels: MetricMood.labels,
                          color: { MetricMood.color($0) }, state: state, window: f.window,
                          xStyle: f.chartRange.axisStyle, selection: $selection, height: height,
                          accessibilityTitle: title, calendar: f.calendar)
        case .needBars:
            DailyBarChart(points: f.chartPoints,
                          fill: .bands(ScoreBands([
                              .init(upperBound: 100, color: StrandPalette.statusWarning, name: String(localized: "Below need")),
                              .init(upperBound: .infinity, color: StrandPalette.restColor, name: String(localized: "Met")),
                          ])),
                          bin: f.bin, aggregation: .mean, reference: ChartReference(100, label: "100 %"),
                          state: state, window: f.window, xStyle: f.chartRange.axisStyle,
                          y: ChartValueAxis(unit: "%", domain: .fitted(minSpan: 40, includeZero: true)),
                          selection: $selection, height: height, accessibilityTitle: title, calendar: f.calendar)
        }
    }

    @ViewBuilder
    private func scoreBars(_ fill: MetricPresentation.ScoreFill) -> some View {
        let f = frame
        switch fill {
        case .charge, .rest:
            DailyBarChart.scores(f.chartPoints, bands: MetricScoreBands.bands(for: fill) ?? MetricScoreBands.charge,
                                 bin: f.bin, unit: "%", state: state, window: f.window,
                                 xStyle: f.chartRange.axisStyle, selection: $selection, height: height,
                                 accessibilityTitle: title, calendar: f.calendar)
        case .dayStress:
            DailyBarChart.scores(f.chartPoints, bands: MetricScoreBands.dayStress, scale: 0...3, bin: f.bin,
                                 format: ChartValueAxis.decimals(1), state: state, window: f.window,
                                 xStyle: f.chartRange.axisStyle, selection: $selection, height: height,
                                 accessibilityTitle: title, calendar: f.calendar)
        case .effort:
            let max = f.scoreMax
            DailyBarChart.scores(f.chartPoints, ramp: { StrandPalette.effortTint(fraction: $0 / max) },
                                 scale: 0...max, bin: f.bin, state: state, window: f.window,
                                 xStyle: f.chartRange.axisStyle, selection: $selection, height: height,
                                 accessibilityTitle: title, calendar: f.calendar)
        case .single:
            DailyBarChart(points: f.chartPoints, fill: .single(f.presentation.tint.color), bin: f.bin,
                          aggregation: .mean, meanLine: f.bin == .day ? 7 : nil, state: state, window: f.window,
                          xStyle: f.chartRange.axisStyle, y: ChartValueAxis(unit: nil, domain: .fixed(0...100)),
                          selection: $selection, height: height, accessibilityTitle: title, calendar: f.calendar)
        }
    }

    private var totals: some View {
        let f = frame
        let p = f.presentation
        return DailyBarChart.totals(f.chartPoints, color: p.tint.color, goal: f.goal, bin: f.bin,
                                    aggregation: p.aggregation, state: state, window: f.window,
                                    xStyle: f.chartRange.axisStyle, y: totalsAxis,
                                    selection: $selection, height: height, accessibilityTitle: title,
                                    calendar: f.calendar)
    }

    private var totalsAxis: ChartValueAxis {
        let f = frame
        let p = f.presentation
        if p.valueStyle == .duration { return .durationMinutes() }
        switch p.key {
        case "steps", "steps_est":
            return ChartValueAxis(unit: f.axisUnit, domain: .fitted(minSpan: 2_000, includeZero: true))
        case "energy_kcal", "active_kcal", "calories_in":
            return ChartValueAxis(unit: f.axisUnit, domain: .fitted(minSpan: 500, includeZero: true))
        case "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min", "intensity_min":
            return ChartValueAxis(unit: f.axisUnit, domain: .fitted(minSpan: 30, includeZero: true))
        default:
            return ChartValueAxis(unit: f.axisUnit, domain: .fitted(minSpan: 10, includeZero: true),
                                  format: p.axisFormat())
        }
    }

    @ViewBuilder
    private func line(minSpan: Double) -> some View {
        let f = frame
        let p = f.presentation
        let isHRV = p.key == "hrv"
        let rmssd = DailyLineChart.Series(id: p.key, name: isHRV ? "RMSSD" : title, color: p.tint.color,
                                          points: f.chartPoints)
        let sdnn = DailyLineChart.Series(id: "sdnn", name: "SDNN", color: StrandPalette.metricCyan, points: f.sdnnPoints)
        let series = isHRV && showsSDNN && !f.sdnnPoints.isEmpty ? [rmssd, sdnn] : [rmssd]
        let y: ChartValueAxis = p.valueStyle == .duration
            ? .durationMinutes(minSpanMinutes: 120, includeZero: false)
            : ChartValueAxis(unit: f.axisUnit, domain: .fitted(minSpan: minSpan), format: p.axisFormat())
        DailyLineChart(series: series, cadence: .daily, typicalBand: f.typical,
                       baseline: f.baseline.map { ChartReference($0, label: String(localized: "Baseline \(p.text($0))")) },
                       reference: p.key == "vitality" ? ChartReference(100, label: "100") : nil,
                       // HRV draws its own legend below, with the SDNN toggle.
                       legend: isHRV ? [] : nil,
                       state: state, window: f.window, xStyle: f.chartRange.axisStyle, y: y,
                       selection: $selection,
                       height: isHRV ? height - NaraChartStyle.legendHeight - NaraChartStyle.legendSpacing : height,
                       accessibilityTitle: title, calendar: f.calendar)
    }
}

/// HRV's legend row: RMSSD (the headline), the typical band and baseline, and SDNN as a toggle, off by
/// default. The row is always there, so the card is one height whether or not SDNN exists.
struct MetricHRVLegend: View {
    let hasSDNN: Bool
    let hasBand: Bool
    let hasBaseline: Bool
    @Binding var showsSDNN: Bool

    var body: some View {
        var items = [ChartLegendItem(.line(StrandPalette.metricPurple, dashed: false), "RMSSD")]
        if hasSDNN { items.append(ChartLegendItem(.line(StrandPalette.metricCyan, dashed: false), "SDNN")) }
        if hasBand { items.append(ChartLegendItem(.band(StrandPalette.metricPurple), String(localized: "Typical range"))) }
        if hasBaseline { items.append(ChartLegendItem(.line(NaraChartStyle.referenceColor, dashed: true), String(localized: "Baseline"))) }
        return ChartLegend(items, hidden: showsSDNN ? [] : ["SDNN"],
                           onToggle: hasSDNN ? { id in if id == "SDNN" { showsSDNN.toggle() } } : nil)
            .padding(.top, -NoopMetrics.space1)
            .accessibilityHint(hasSDNN ? Text("Shows or hides SDNN") : Text(""))
    }
}

// MARK: - Stacked bars

/// The parts of a stacked bar for one metric: sleep stages (with this stage highlighted), deep + REM,
/// asleep + awake in bed, or the five heart-rate zones. Nil when the companion series are too thin to
/// stack, in which case the page draws plain bars of the metric's own value.
struct MetricStackData {
    let days: [StackedBarChart.Day]
    let categories: [StackedBarChart.Category]
    let highlighted: String?
    /// day key → the parts, in minutes, for the readout's context line.
    let partsByDay: [String: [String: Double]]
    let kind: MetricPresentation.Stack

    static func build(_ kind: MetricPresentation.Stack, ownKey: String, own: [(day: String, value: Double)],
                      companions: [String: [(day: String, value: Double)]], calendar: Calendar) -> MetricStackData? {
        func map(_ key: String) -> [String: Double] {
            if key == ownKey { return Dictionary(own.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a }) }
            return Dictionary((companions[key] ?? []).map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        var parts: [String: [String: Double]] = [:]
        let categories: [StackedBarChart.Category]
        var highlighted: String?
        switch kind {
        case .sleepStages(let highlight):
            let keys = ["sleep_deep_min", "sleep_rem_min", "sleep_light_min"]
            let maps = keys.map(map)
            for row in own {
                let values = zip(keys, maps).compactMap { key, m in m[row.day].map { (key, $0) } }
                if values.count == 3 { parts[row.day] = Dictionary(uniqueKeysWithValues: values) }
            }
            categories = [.init(id: "sleep_deep_min", name: String(localized: "Deep"), color: StrandPalette.sleepDeep),
                          .init(id: "sleep_rem_min", name: String(localized: "REM"), color: StrandPalette.sleepREM),
                          .init(id: "sleep_light_min", name: String(localized: "Light"), color: StrandPalette.sleepLight)]
            highlighted = highlight
        case .restorative:
            let deep = map("sleep_deep_min"), rem = map("sleep_rem_min")
            for row in own {
                if let d = deep[row.day], let r = rem[row.day] {
                    parts[row.day] = ["sleep_deep_min": d, "sleep_rem_min": r]
                }
            }
            categories = [.init(id: "sleep_deep_min", name: String(localized: "Deep"), color: StrandPalette.sleepDeep),
                          .init(id: "sleep_rem_min", name: String(localized: "REM"), color: StrandPalette.sleepREM)]
        case .inBed:
            let asleep = map("sleep_total_min")
            for row in own {
                guard let a = asleep[row.day] else { continue }
                parts[row.day] = ["asleep": min(a, row.value), "awake": max(0, row.value - a)]
            }
            categories = [.init(id: "asleep", name: String(localized: "Asleep"), color: StrandPalette.restColor),
                          .init(id: "awake", name: String(localized: "Awake in bed"), color: StrandPalette.sleepAwake)]
        case .zones:
            let keys = (1...5).map { "hr_zone\($0)_min" }
            let maps = keys.map(map)
            for row in own {
                let values = zip(keys, maps).map { key, m in (key, m[row.day] ?? 0) }
                if values.contains(where: { $0.1 > 0 }) { parts[row.day] = Dictionary(uniqueKeysWithValues: values) }
            }
            let colors = [StrandPalette.zone1, StrandPalette.zone2, StrandPalette.zone3, StrandPalette.zone4,
                          StrandPalette.zone5]
            categories = zip(keys, colors).enumerated().map { index, pair in
                .init(id: pair.0, name: "Z\(index + 1)", color: pair.1)
            }
        }
        // Too thin to stack (most nights lack the parts): plain bars of the metric's own value say more.
        guard !own.isEmpty, Double(parts.count) >= Double(own.count) * 0.5 else { return nil }
        let days = parts.keys.sorted().compactMap { key -> StackedBarChart.Day? in
            guard let day = ChartDay.date(forKey: key, calendar: calendar), let values = parts[key] else { return nil }
            return StackedBarChart.Day(day: day, values: values)
        }
        return MetricStackData(days: days, categories: categories, highlighted: highlighted, partsByDay: parts,
                               kind: kind)
    }

    /// The readout's context line for a selected day: how the parts split.
    func contextLine(for selection: Date?, bin: Calendar.Component, calendar: Calendar,
                     text: (Double) -> String) -> String? {
        guard bin == .day, let selection else { return nil }
        let key = ChartDay.key(for: selection, calendar: calendar)
        guard let values = partsByDay[key] else { return nil }
        switch kind {
        case .sleepStages(let highlight):
            let total = values.values.reduce(0, +)
            guard total > 0, let own = values[highlight] else { return nil }
            let share = Int((own / total * 100).rounded())
            return String(localized: "\(share) % of \(text(total)) asleep")
        case .restorative:
            return String(localized: "Deep \(text(values["sleep_deep_min"] ?? 0)) · REM \(text(values["sleep_rem_min"] ?? 0))")
        case .inBed:
            return String(localized: "\(text(values["asleep"] ?? 0)) asleep")
        case .zones:
            let high = (values["hr_zone4_min"] ?? 0) + (values["hr_zone5_min"] ?? 0)
            return String(localized: "Zones 4-5: \(high.formatted(.number.precision(.fractionLength(0)))) min")
        }
    }
}

// MARK: - Share bars (band mix, mood distribution)

/// One row of a share card: a name, its colour, how long its bar is (0…1) and the value printed beside it.
struct MetricShareRow: Identifiable, Equatable {
    let id: String
    let name: String
    let color: Color
    let fraction: Double
    let valueText: String
}

enum MetricShareRows {
    /// Days in each score band over the range, best band first; bars against the largest band.
    static func bands(_ bands: ScoreBands, values: [Double]) -> [MetricShareRow] {
        let counts = Dictionary(grouping: values.filter(\.isFinite)) { bands.band(for: $0).name }.mapValues(\.count)
        let largest = Double(max(1, counts.values.max() ?? 1))
        return bands.bands.reversed().map { band in
            let n = counts[band.name] ?? 0
            return MetricShareRow(id: band.name, name: band.name, color: band.color,
                                  fraction: Double(n) / largest, valueText: "\(n)")
        }
    }

    /// Check-ins per mood level, best first.
    static func levels(values: [Double]) -> [MetricShareRow] {
        let counts = Dictionary(grouping: values.filter(\.isFinite)) { min(5, max(1, Int($0.rounded()))) }.mapValues(\.count)
        let largest = Double(max(1, counts.values.max() ?? 1))
        return (1...5).reversed().map { level in
            let n = counts[level] ?? 0
            return MetricShareRow(id: "\(level)", name: MetricMood.label(level), color: MetricMood.color(level),
                                  fraction: Double(n) / largest, valueText: "\(n)")
        }
    }

    /// The average for each weekday over the range, in the locale's week order; bars on the score's scale.
    static func weekdays(_ rows: [(day: String, value: Double)], scaleMax: Double, color: (Double) -> Color,
                         text: (Double) -> String, calendar: Calendar = .current) -> [MetricShareRow] {
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for row in rows where row.value.isFinite {
            guard let date = ChartDay.date(forKey: row.day, calendar: calendar) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            let entry = sums[weekday] ?? (0, 0)
            sums[weekday] = (entry.sum + row.value, entry.n + 1)
        }
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            let mean = sums[weekday].map { $0.sum / Double(max(1, $0.n)) }
            return MetricShareRow(id: "\(weekday)", name: symbols[weekday - 1],
                                  color: mean.map(color) ?? StrandPalette.textTertiary,
                                  fraction: mean.map { min(1, max(0, $0 / max(scaleMax, 1))) } ?? 0,
                                  valueText: mean.map(text) ?? "—")
        }
    }
}

/// How the range's days split across bands, levels or weekdays: one flat bar per row, with its value.
/// Kit candidate (a categorical bar card is not in the kit yet).
struct MetricShareCard: View {
    let title: String
    let rows: [MetricShareRow]
    let isLoading: Bool

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    ForEach(rows) { row in
                        HStack(spacing: NoopMetrics.space3) {
                            Text(row.name)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(1)
                                .frame(width: 84, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(StrandPalette.surfaceInset)
                                    Capsule().fill(row.color)
                                        .frame(width: row.fraction <= 0 ? 0 : max(6, geo.size.width * CGFloat(row.fraction)))
                                }
                            }
                            .frame(height: 8)
                            Text(row.valueText)
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .frame(minHeight: 24)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(row.name), \(row.valueText)"))
                    }
                }
            }
        }
        .loadingPlaceholder(isLoading)
    }
}

// MARK: - Moves with (correlations)

/// The metrics whose daily values rise and fall with this one over the visible range. Placeholder rows at
/// their final height while the catalog scan runs; one quiet line when nothing correlates.
struct MetricCorrelationsSection: View {
    struct Row: Identifiable {
        let id: String
        let metric: MetricDescriptor
        let r: Double
        let n: Int
    }

    let rows: [Row]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Moves with")
            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if isLoading {
                        ForEach(0..<3, id: \.self) { index in
                            if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                            row(icon: "waveform.path.ecg", title: "Heart Rate Variability", r: 0.5, n: 30)
                        }
                        .loadingPlaceholder(true)
                    } else if rows.isEmpty {
                        Text("Nothing moves with it in this range.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, NoopMetrics.cardPadding)
                            .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                            row(icon: item.metric.icon, title: item.metric.title, r: item.r, n: item.n)
                        }
                    }
                }
            }
        }
    }

    private func row(icon: String, title: String, r: Double, n: Int) -> some View {
        let color = r >= 0 ? StrandPalette.statusPositive : StrandPalette.statusCritical
        return HStack(spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.icon(.row))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: NoopMetrics.space2)
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                Capsule().fill(color).frame(width: 56 * CGFloat(min(abs(r), 1)))
            }
            .frame(width: 56, height: 6)
            .accessibilityHidden(true)
            Text("\(r >= 0 ? "+" : "−")\(String(format: "%.2f", abs(r)))")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), correlation \(String(format: "%.2f", r)), \(n) days"))
    }
}
