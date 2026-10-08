import SwiftUI
import StrandDesign

// MARK: - Per-source series detail
//
// The detail page for a series one imported source writes that the metric catalog has no entry for under
// that source (Apple Health's resting heart rate, HRV, blood oxygen, respiratory rate and asleep time; the Mi
// Band's distance). Catalogued series open the shared `MetricDetailView` instead; this page follows the same
// anatomy (docs/DESIGN_SYSTEM.md, Detail pages): readout, range, the chart chosen for the data, statistics,
// the newest readings and an About card. It only draws the rows it is handed, already loaded by the source
// page; it reads and computes nothing.

struct SourceSeriesPresentation {
    enum Chart {
        /// A daily or nightly vital: points joined across consecutive days, gaps break the line.
        case vital(minSpan: Double, decimals: Int)
        /// A percentage on a fixed scale (blood oxygen): points only, with a reference rule.
        case percent(domain: ClosedRange<Double>, reference: Double?)
        /// A daily total (steps, distance, energy): bars that bin to weeks and months on long ranges.
        case totals(minSpan: Double, decimals: Int)
        /// A nightly duration in minutes: bars on an hours axis.
        case duration
    }

    let title: String
    let unit: String?
    let color: Color
    let chart: Chart
    /// The value without its unit ("62", "7 h 32 m").
    let format: (Double) -> String
    /// What the series is, how the source measures it, caveats.
    let about: [String]
    var nightly = false
}

struct SourceSeriesDetailView: View {
    let presentation: SourceSeriesPresentation
    let rows: [(day: String, value: Double)]
    let sourceName: String

    @State private var range: ChartRange = .month
    @State private var selected: Date?
    @State private var showAllReadings = false
    @State private var pickedInitialRange = false

    private var points: [DailyPoint] {
        rows.compactMap { DailyPoint(key: $0.day, value: $0.value) }.sorted { $0.day < $1.day }
    }

    /// How far back the history reaches, in days before today.
    private func spanDays(_ points: [DailyPoint]) -> Int {
        guard let first = points.first?.day else { return 0 }
        return Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
    }

    /// A range is offered when the history reaches past the range below it, so every segment shows
    /// something the previous one did not.
    private func isAvailable(_ r: ChartRange, span: Int) -> Bool {
        switch r {
        case .week, .all: return true
        case .month: return span > 7
        case .quarter: return span > 30
        case .half: return span > 90
        case .year: return span > 180
        }
    }

    private func effectiveRange(span: Int) -> ChartRange {
        let visible = RangeControl.visibleOptions(ChartRange.allCases, isAvailable: { isAvailable($0, span: span) })
        return RangeControl.displayedSelection(range, visible: visible) ?? range
    }

    private var bin: Calendar.Component {
        switch presentation.chart {
        case .totals, .duration: return effectiveRange(span: spanDays(points)).totalsBin
        case .vital, .percent: return .day
        }
    }

    var body: some View {
        let points = points
        let span = spanDays(points)
        let shownRange = effectiveRange(span: span)
        let window = ChartAxis.window(shownRange, firstDataDay: points.first?.day)
        let inWindow = points.filter { window.contains($0.day) }
        let readoutPoints = bin == .day ? points : DailyBarChart.bin(points, by: bin, aggregation: .mean)

        ScreenScaffold(title: LocalizedStringKey(presentation.title), titleDisplay: .navigationBar) {
            ValueReadout(.daily(selection: selected, in: readoutPoints, bin: bin, nightly: presentation.nightly,
                                unit: presentation.unit, format: presentation.format,
                                context: selected == nil ? context(points) : nil),
                         isScrubbing: selected != nil)
            RangeControl(selection: $range, isAvailable: { isAvailable($0, span: span) })
            NoopCard {
                chart(points, window: window, range: shownRange,
                      state: inWindow.isEmpty ? .empty(String(localized: "No readings in this range")) : .ready)
            }
            if !inWindow.isEmpty {
                StatGrid(stats(inWindow))
            }
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("Readings")
                    ReadingsList(rows: readingRows(points), onShowAll: { showAllReadings = true })
                }
            }
            AboutDisclosure("About \(presentation.title)", paragraphs: presentation.about)
        }
        .onChangeCompat(of: range) { _ in selected = nil }
        .onAppear { pickInitialRange(points) }
        .sheet(isPresented: $showAllReadings) {
            SourceReadingsSheet(title: presentation.title, rows: readingRows(points)) { showAllReadings = false }
        }
    }

    /// Opens on a month, or on the shortest range that still shows the newest reading when the source has
    /// not written anything recently (an Apple Health export from last spring), so the page never opens on
    /// an empty chart while there is history to show.
    private func pickInitialRange(_ points: [DailyPoint]) {
        guard !pickedInitialRange else { return }
        pickedInitialRange = true
        guard let latest = points.last?.day else { return }
        let age = Calendar.current.dateComponents([.day], from: latest, to: Date()).day ?? 0
        let order: [ChartRange] = [.month, .quarter, .half, .year]
        range = order.first { ($0.days ?? .max) > age } ?? .all
    }

    @ViewBuilder
    private func chart(_ points: [DailyPoint], window: ClosedRange<Date>, range: ChartRange,
                       state: ChartState) -> some View {
        let p = presentation
        switch p.chart {
        case .vital(let minSpan, let decimals):
            DailyLineChart(series: [.init(id: "value", name: p.title, color: p.color, points: points)],
                           state: state, window: window, xStyle: range.axisStyle,
                           y: ChartValueAxis(unit: p.unit, domain: .fitted(minSpan: minSpan),
                                             format: decimals > 0 ? ChartValueAxis.decimals(decimals) : ChartValueAxis.integer),
                           selection: $selected, accessibilityTitle: p.title)
        case .percent(let domain, let reference):
            DailyLineChart.fixedDomainPoints(points, domain: domain,
                                             reference: reference.map { ChartReference($0, label: "\(Int($0)) %") },
                                             color: p.color, joined: false, unit: p.unit,
                                             state: state, window: window, xStyle: range.axisStyle,
                                             selection: $selected, accessibilityTitle: p.title)
        case .totals(let minSpan, let decimals):
            DailyBarChart.totals(points, color: p.color, goal: nil, bin: range.totalsBin, aggregation: .mean,
                                 state: state, window: window, xStyle: range.axisStyle,
                                 y: ChartValueAxis(unit: p.unit, domain: .fitted(minSpan: minSpan, includeZero: true),
                                                   format: decimals > 0 ? ChartValueAxis.decimals(decimals) : ChartValueAxis.integer),
                                 selection: $selected, accessibilityTitle: p.title)
        case .duration:
            DailyBarChart.totals(points, color: p.color, goal: nil, bin: range.totalsBin, aggregation: .mean,
                                 state: state, window: window, xStyle: range.axisStyle,
                                 y: .durationMinutes(), selection: $selected, accessibilityTitle: p.title)
        }
    }

    /// The readout's resting line: the 7-day average when there is a week of readings, else how many.
    private func context(_ points: [DailyPoint]) -> String? {
        guard !points.isEmpty else { return nil }
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let recent = points.filter { $0.day >= weekAgo }.map(\.value)
        if recent.count >= 3 {
            let avg = recent.reduce(0, +) / Double(recent.count)
            return String(localized: "7-day avg \(withUnit(avg))")
        }
        return points.count == 1 ? String(localized: "1 reading") : String(localized: "\(points.count) readings")
    }

    private func withUnit(_ value: Double) -> String {
        let text = presentation.format(value)
        guard let unit = presentation.unit, !unit.isEmpty, !isDuration else { return text }
        return "\(text) \(unit)"
    }

    private var isDuration: Bool {
        if case .duration = presentation.chart { return true }
        return false
    }

    private func stats(_ inWindow: [DailyPoint]) -> [StatItem] {
        let values = inWindow.map(\.value)
        let unit = isDuration ? nil : presentation.unit
        let avg = values.reduce(0, +) / Double(max(values.count, 1))
        let low = inWindow.min { $0.value < $1.value }
        let high = inWindow.max { $0.value < $1.value }
        let short: (Date) -> String = { $0.formatted(.dateTime.day().month(.abbreviated)) }
        return [
            StatItem(String(localized: "Average"), value: presentation.format(avg), unit: unit),
            StatItem(String(localized: "Readings"), value: "\(values.count)"),
            StatItem(String(localized: "Low"), value: low.map { presentation.format($0.value) }, unit: unit,
                     detail: low.map { short($0.day) }),
            StatItem(String(localized: "High"), value: high.map { presentation.format($0.value) }, unit: unit,
                     detail: high.map { short($0.day) }),
        ]
    }

    private func readingRows(_ points: [DailyPoint]) -> [ReadingsList.Row] {
        points.reversed().map { point in
            ReadingsList.Row(id: ChartDay.key(for: point.day),
                             date: ReadoutContent.dateLine(point.day, period: presentation.nightly ? .night : .day),
                             value: withUnit(point.value),
                             source: sourceName)
        }
    }
}

/// Every reading of a series, newest first, in a sheet.
private struct SourceReadingsSheet: View {
    let title: String
    let rows: [ReadingsList.Row]
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { NoopListDivider() }
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.date)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: NoopMetrics.space2)
                        Text(row.value)
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .padding(.vertical, NoopMetrics.space3)
                    .accessibilityElement(children: .combine)
                }
            }
            .background(NoopPanelSurface())
            .padding(NoopMetrics.screenHPadding)
        }
        .moreSheetChrome(LocalizedStringKey(title), onDone: onDone)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }
}
