import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Trends
//
// The longitudinal view: the week in review (stepped week by week, opening the full digest), then one
// range control for the long-range charts below it, each chosen for its data (docs/DESIGN_SYSTEM.md,
// Chart selection): Charge and Effort as score bars on their fixed scales, HRV and resting HR as lines
// with gaps and a personal typical band, training load as two lines. Each chart scrubs; its section
// header opens the metric's detail page.

struct TrendsView: View {
    /// When true, the charts render inside another screen without a second header.
    var embedded: Bool = false
    @EnvironmentObject var repo: Repository
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only, and
    // observing it forced a full re-render of this subtree on every ~1 Hz live-HR tick.

    /// The windowing ranges `HostedTrendData.resolve` widens through (shared with the Today host cards).
    /// The page itself draws with the kit's `ChartRange`; `init(_:)` bridges the two at the boundary.
    enum Range: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week:    return String(localized: "W")
            case .month:   return String(localized: "M")
            case .quarter: return String(localized: "3M")
            case .half:    return String(localized: "6M")
            case .year:    return String(localized: "1Y")
            case .all:     return String(localized: "ALL")
            }
        }
        /// Trailing-day window, or nil for "all history".
        var days: Int? { self == .all ? nil : rawValue }

        /// This range plus every LARGER range, ascending — the auto-expand search
        /// order when the selected window holds zero points.
        var widening: [Range] {
            let order: [Range] = [.week, .month, .quarter, .half, .year, .all]
            guard let i = order.firstIndex(of: self) else { return [.all] }
            return Array(order[i...])
        }

        init(_ range: ChartRange) {
            switch range {
            case .week: self = .week
            case .month: self = .month
            case .quarter: self = .quarter
            case .half: self = .half
            case .year: self = .year
            case .all: self = .all
            }
        }

        var chartRange: ChartRange {
            switch self {
            case .week: return .week
            case .month: return .month
            case .quarter: return .quarter
            case .half: return .half
            case .year: return .year
            case .all: return .all
            }
        }
    }

    @State private var range: ChartRange = .quarter
    /// Current appearance, passed into the off-screen recap render so the shared PNG matches the app.
    @Environment(\.colorScheme) private var colorScheme

    // #710 — browse previous weeks in the week in review. 0 = the week containing today; each step back
    // is one Mon–Sun week earlier. Clamped so it never runs past the earliest day we hold (see
    // `weekAnchorDay` / `stepWeek`). The range control is independent of this: it scopes the long-range
    // charts; this only moves the week summary.
    @State private var weekOffset = 0

    /// The history as chart points, rebuilt only when the days change (not on every scrub frame).
    @State private var series = TrendsSeries()

    // Effort display scale (#268) — routes the Effort chart's numbers + axis. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private var isLoading: Bool { !repo.loaded }

    var body: some View {
        if embedded {
            trendColumn
                .onAppear { rebuildSeries() }
                .onChangeCompat(of: repo.days) { _ in rebuildSeries() }
        } else {
            // The section headers push their metric's detail page. On iOS each host (the tab stacks and the
            // pillar sheet) supplies a NavigationStack with the routes registered. On macOS the .trends
            // detail pane has NO enclosing NavigationStack (RootView), so — exactly like MetricExplorerView
            // (#753) — wrap the scaffold in one here so the pushes get Back chrome instead of hanging.
            #if os(macOS)
            // Register the value routes at THIS stack's root; on iOS the host stack registers them
            // instead (once per stack — a double registration double-pushes, #38).
            MorePaneNavigation { scaffold }
            #else
            scaffold
            #endif
        }
    }

    private var scaffold: some View {
        ScreenScaffold(title: "Trends", titleDisplay: .navigationBar, isLoading: isLoading,
                       onRefresh: { await repo.refresh() }) {
            trendColumn
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { shareButton }
        }
        .onAppear { rebuildSeries() }
        .onChangeCompat(of: repo.days) { _ in rebuildSeries() }
    }

    @ViewBuilder
    private var trendColumn: some View {
        let span = InsightsRanges.span(firstDay: series.firstDay)
        let selected = InsightsRanges.effective(range, span: span)
        // A stale history (an old import) widens to the smallest range that holds any data, the same rule
        // the Today host cards use, rather than drawing an empty recent window.
        let shown = effectiveRange(selected)
        let window = ChartAxis.window(shown, firstDataDay: series.firstDay)
        weekSection
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            RangeControl(insightsSelection: $range, span: span)
            if shown != selected {
                Text(String(localized: "Showing \(shown.accessibilityName): not enough recent data for \(selected.accessibilityName)"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        chargeSection(range: shown, window: window)
        hrvSection(range: shown, window: window)
        rhrSection(range: shown, window: window)
        effortSection(range: shown, window: window)
        TrainingLoadCard(days: repo.days, range: shown, window: window, isLoading: isLoading)
        AboutDisclosure(paragraphs: [
            String(localized: "42-day fitness vs 7-day fatigue"),
            String(localized: "Form is fitness minus fatigue. Training load is descriptive and never changes a score."),
            String(localized: "The week in review covers Monday to Sunday. Its Rest is the nightly sleep composite, recomputed for each night."),
        ])
    }

    private func rebuildSeries() {
        series = TrendsSeries(days: repo.days)
    }

    /// The selected range, widened through larger ranges until one holds a reading of any long-range
    /// metric (`HostedTrendData.resolve`, the tab's and the host cards' shared rule).
    private func effectiveRange(_ selected: ChartRange) -> ChartRange {
        let resolved = HostedTrendData.resolve(days: repo.days, selected: Range(selected)) { d in
            d.recovery ?? d.avgHrv ?? d.restingHr.map(Double.init) ?? d.strain
        }
        return resolved.points.isEmpty ? selected : resolved.effective.chartRange
    }

    private func chartState(_ points: [DailyPoint]) -> ChartState {
        isLoading ? .loading : (points.isEmpty ? .empty(String(localized: "No history yet")) : .ready)
    }

    // MARK: Long-range charts

    private func chargeSection(range: ChartRange, window: ClosedRange<Date>) -> some View {
        TrendsChartSection(title: "Charge", metricKey: "recovery", points: series.charge, range: range,
                           window: window, unit: "%", format: { "\(Int($0.rounded()))" }) { selection in
            DailyBarChart.scores(series.charge, bands: InsightsScoreBands.charge, bin: range.totalsBin, unit: "%",
                                 state: chartState(series.charge), window: window, xStyle: range.axisStyle,
                                 selection: selection, accessibilityTitle: String(localized: "Charge"))
        }
    }

    private func hrvSection(range: ChartRange, window: ClosedRange<Date>) -> some View {
        let inWindow = series.hrv.filter { window.contains($0.day) }.map(\.value)
        return TrendsChartSection(title: "Heart rate variability", metricKey: "hrv", points: series.hrv,
                                  range: range, window: window, unit: "ms", format: { "\(Int($0.rounded()))" },
                                  bins: false) { selection in
            DailyLineChart(series: [.init(id: "hrv", name: String(localized: "HRV"),
                                          color: StrandPalette.metricPurple, points: series.hrv)],
                           typicalBand: insightsTypicalBand(inWindow),
                           state: chartState(series.hrv), window: window, xStyle: range.axisStyle,
                           y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                           selection: selection, height: NoopMetrics.chartHeightSecondary,
                           accessibilityTitle: String(localized: "Heart rate variability"))
        }
    }

    private func rhrSection(range: ChartRange, window: ClosedRange<Date>) -> some View {
        let inWindow = series.rhr.filter { window.contains($0.day) }.map(\.value)
        return TrendsChartSection(title: "Resting heart rate", metricKey: "rhr", points: series.rhr,
                                  range: range, window: window, unit: "bpm", format: { "\(Int($0.rounded()))" },
                                  bins: false) { selection in
            DailyLineChart(series: [.init(id: "rhr", name: String(localized: "Resting HR"),
                                          color: StrandPalette.metricRose, points: series.rhr)],
                           typicalBand: insightsTypicalBand(inWindow),
                           state: chartState(series.rhr), window: window, xStyle: range.axisStyle,
                           y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 10)),
                           selection: selection, height: NoopMetrics.chartHeightSecondary,
                           accessibilityTitle: String(localized: "Resting heart rate"))
        }
    }

    /// Effort is stored 0–100; the bars, the axis and the readout all read on the user's display scale
    /// (#268), so the axis never disagrees with the numbers.
    private func effortSection(range: ChartRange, window: ClosedRange<Date>) -> some View {
        let scale = effortScale
        let points = series.effort.map { DailyPoint(day: $0.day, value: UnitFormatter.effortValue($0.value, scale: scale)) }
        let top = UnitFormatter.effortValue(100, scale: scale)
        let oneDecimal = scale == .whoop
        return TrendsChartSection(title: "Effort", metricKey: "strain", points: points, range: range,
                                  window: window, unit: "/ \(UnitFormatter.effortScaleMax(scale))",
                                  format: { oneDecimal ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" }) { selection in
            DailyBarChart.scores(points, ramp: { StrandPalette.effortTint(fraction: $0 / top) }, scale: 0...top,
                                 bin: range.totalsBin, state: chartState(points), window: window,
                                 xStyle: range.axisStyle, selection: selection,
                                 height: NoopMetrics.chartHeightSecondary,
                                 accessibilityTitle: String(localized: "Effort"))
        }
    }

    // MARK: Week in review with prev/next week browsing (#710)

    /// The earliest "yyyy-MM-dd" we hold (history is oldest → newest), used to clamp how far back the
    /// week stepper can go.
    private var earliestDay: String? { repo.days.first?.day }

    /// The most negative `weekOffset` allowed: the number of whole weeks between the earliest day's week
    /// and this week. Beyond that there's no data to digest, so the back chevron disables. 0 when history
    /// is empty or unparseable (so we stay on this week).
    private var minWeekOffset: Int {
        guard
            let earliest = earliestDay,
            let earliestMon = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
            let thisMon = WeeklyDigestEngine.mondayOfWeek(containing: Repository.localDayKey(Date()))
        else { return 0 }
        // Walk weeks back from this Monday until we pass the earliest week. Bounded by history length.
        var off = 0
        var mon = thisMon
        while mon > earliestMon && off > -520 {           // hard cap ~10 years so a bad date can't spin
            mon = WeeklyDigestEngine.addDays(mon, -7)
            off -= 1
        }
        return off
    }

    /// The anchor day (any day in the target week) for the current `weekOffset`: today shifted back by
    /// `weekOffset` whole weeks. The engine snaps it to that week's Monday.
    private var weekAnchorDay: String {
        WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), weekOffset * 7)
    }

    /// Move the summary one week earlier (-1) or later (+1), clamped to [minWeekOffset, 0] — never into a
    /// future week, never past the earliest week we hold.
    private func stepWeek(_ delta: Int) {
        let next = weekOffset + delta
        weekOffset = max(minWeekOffset, min(0, next))
    }

    /// "This week", "Last week", else the count of weeks back ("3 weeks ago").
    private var weekTitle: String {
        switch weekOffset {
        case 0: return String(localized: "This week")
        case -1: return String(localized: "Last week")
        default: return String(localized: "\(-weekOffset) weeks ago")
        }
    }

    /// The week's Charge, Effort and Rest with their week-over-week change, stepped week by week. The
    /// summary opens the full week in review. Built from the shared `WeeklyDigestSource` so past weeks
    /// render in the identical format. A week with no readings keeps the stepper so the user can move on.
    private var weekSection: some View {
        let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: weekAnchorDay)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Week in review")
            PeriodStepper(title: weekTitle,
                          subtitle: "\(weeklyDigestRangeLabel(digest)) · \(String(localized: "\(digest.daysWithData)/7 days"))",
                          canGoBack: weekOffset > minWeekOffset, canGoForward: weekOffset < 0,
                          onBack: { stepWeek(-1) }, onForward: { stepWeek(1) })
            if digest.isEmpty {
                ComingSoon(what: "No readings this week")
            } else {
                NavigationLink {
                    WeeklyDigestView(anchorDay: weekAnchorDay)
                } label: {
                    WeeklyDigestContent(digest: digest, compact: true, showsHeader: false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Share this week's recap as an image: the summary card rendered off-screen to a PNG and handed to
    /// the share sheet / Save panel (TrendsReport's ImageRenderer path). Only offered when the week holds
    /// data.
    @ViewBuilder
    private var shareButton: some View {
        let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: weekAnchorDay)
        if !digest.isEmpty {
            Button {
                let page = WeeklyDigestContent(digest: digest, compact: true, showsHeader: true)
                    .frame(width: 380)
                    .padding(24)
                    .background(StrandPalette.surfaceBase)
                    .environment(\.colorScheme, colorScheme)
                TrendsReportRenderer.exportPNG(page: page, suggestedName: "nara-recap-\(weekAnchorDay).png")
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(StrandPalette.accent)
            }
            .accessibilityLabel("Share recap")
        }
    }
}

// MARK: - Series

/// The long-range metrics as chart points, keyed by the stored local day (never a UTC midnight).
struct TrendsSeries {
    var charge: [DailyPoint] = []
    var hrv: [DailyPoint] = []
    var rhr: [DailyPoint] = []
    /// Stored 0–100; the Effort chart converts to the display scale.
    var effort: [DailyPoint] = []

    var firstDay: Date? {
        [charge.first?.day, hrv.first?.day, rhr.first?.day, effort.first?.day].compactMap { $0 }.min()
    }

    init() {}

    init(days: [DailyMetric]) {
        for d in days {
            guard let day = ChartDay.date(forKey: d.day) else { continue }
            if let v = d.recovery { charge.append(DailyPoint(day: day, value: v)) }
            if let v = d.avgHrv { hrv.append(DailyPoint(day: day, value: v)) }
            if let v = d.restingHr { rhr.append(DailyPoint(day: day, value: Double(v))) }
            if let v = d.strain { effort.append(DailyPoint(day: day, value: v)) }
        }
    }
}

// MARK: - One chart section

/// One long-range chart: a section header that opens the metric's detail (the card itself is not a
/// link, so the chart scrubs), a one-line readout (the range's average, or the value under the finger),
/// and the chart. Owns its selection, so scrubbing one chart re-renders only that card.
private struct TrendsChartSection<Chart: View>: View {
    let title: LocalizedStringKey
    let metricKey: String
    /// The chart's daily points (outside the window too; only the window is read).
    let points: [DailyPoint]
    let range: ChartRange
    let window: ClosedRange<Date>
    let unit: String?
    let format: (Double) -> String
    /// Whether the chart draws bars binned to `range.totalsBin` (scores) or one point a day (lines).
    var bins: Bool = true
    @ViewBuilder let chart: (Binding<Date?>) -> Chart

    @State private var selected: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(title, action: .link(label: "Details", value: TabRoute.metric(metricKey)))
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    readout
                    chart($selected)
                }
            }
        }
        .onChangeCompat(of: range) { _ in selected = nil }
    }

    private var readout: some View {
        let bin: Calendar.Component = bins ? range.totalsBin : .day
        let inWindow = points.filter { window.contains($0.day) }
        if let selected {
            let shownPoints = bins ? DailyBarChart.bin(inWindow, by: bin, aggregation: .mean) : inWindow
            let point = ChartSelection.point(for: selected, in: shownPoints, unit: bin)
            let day = point?.day ?? selected
            return InsightsCardReadout(value: point.map { format($0.value) }, unit: unit,
                                       context: ReadoutContent.dateLine(day, period: ReadoutContent.Period(bin: bin)))
        }
        let mean = inWindow.isEmpty ? nil : inWindow.map(\.value).reduce(0, +) / Double(inWindow.count)
        return InsightsCardReadout(value: mean.map(format), unit: unit,
                                   context: String(localized: "Average · \(range.accessibilityName)"))
    }
}

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(21, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Trends") {
    TrendsView()
        .environmentObject(previewRepo())
        .environmentObject(LiveState())
        .frame(width: 960, height: 960)
}
#endif
