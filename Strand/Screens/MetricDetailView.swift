import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Metric detail
//
// The drill-down for every `MetricCatalog` entry, on the detail-page anatomy (docs/DESIGN_SYSTEM.md, Detail
// pages): the readout (the latest value, or the one under the finger), the range control, the primary chart
// chosen for this metric (`MetricPresentation`), the secondary visuals that say something the chart cannot,
// the statistics for the visible range, the context rows, the newest readings, what moves with it, and the
// About card with the method and caveats.
//
// The data path is unchanged: `load()` reads and shapes the series exactly as before (the steps full-history
// guard, VO₂ max provenance, the SpO₂ candidate fill, the skin-temperature kind rule, the SDNN read, the
// phase-2 correlation scan and its cache key). Everything after it is presentation.

/// yyyy-MM-dd → Date at UTC midnight. The range arithmetic (`slice`, `historySpanDays`) works on these, as
/// before; every chart takes local days through `ChartDay` instead.
private let detailDayParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func parseDay(_ day: String) -> Date? { detailDayParser.date(from: day) }

struct MetricDetailView: View {
    let metric: MetricDescriptor
    @EnvironmentObject var repo: Repository
    // Profile basics for the Fitness Age not-ready countdown (age/sex gate its readiness lead) and the "Your
    // age" rule. Injected app-wide at the root; previews supply their own.
    @EnvironmentObject var profile: ProfileStore
    // Drives the fitness_age not-ready "refresh" button (force an immediate recompute). App-wide injected.
    @EnvironmentObject var intelligence: IntelligenceEngine
    /// True while a manual Fitness Age refresh runs (spinner on the not-ready empty state).
    @State private var refreshing = false

    // Imperial/Metric display preference (D#103). Display-only.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    // Effort display scale (#268) — the plotted series stays 0–100 in storage.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    /// #1846/#1848: which skin-temp number the explorer leads with — absent/`""` = a temperature
    /// (the default), or `SkinTempDisplay.Kind.deviation.rawValue` to lead with the ±baseline move.
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var skinTempPreferred: SkinTempDisplay.Kind {
        SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute
    }

    @State private var range: ExploreRange
    /// Full ascending series for this metric — ALL history.
    @State private var series: [(day: String, value: Double)] = []
    /// Nightly SDNN index, charted next to the headline RMSSD on the HRV screen only.
    @State private var sdnnSeries: [(day: String, value: Double)] = []
    /// day → the RAW source id that supplied that day's value (task #8), for the readings' source line and
    /// the on-device estimate marks. The plotted values ride `series`, never this.
    @State private var sourceByDay: [String: String] = [:]
    /// Every OTHER catalog series, loaded once for the correlation scan (phase 2 of `load()`).
    @State private var others: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
    /// True once THIS metric's own series is in. Deliberately not "everything is in": see `load()`.
    @State private var loaded = false
    /// True once a load ran against a repository that had finished its first refresh, so a load against the
    /// still-empty cache at launch never shows the final empty state.
    @State private var loadedWithRepository = false
    /// True once the cross-catalog scan behind the correlation card has finished.
    @State private var correlationsLoaded = false

    // MARK: Activity context (optional, feature-off default)
    private static let activityMetrics: Set<String> = ["hrv", "resp_rate", "spo2"]
    @State private var activityContext: ActivityContextDocument?
    @State private var activityInterval: [Int]?
    @State private var activityDayWindow: [Int]?
    /// "day|resultRevision" the cached context was loaded from.
    @State private var activityLoadedKey: String?

    /// #1848: the skin-temp explorer's explanatory note (nil when none is needed). Set in `load()` alongside
    /// the series. On the page it becomes the readout's context line and an About paragraph.
    @State private var skinTempNote: String? = nil

    /// Cached correlation scan, keyed by its inputs (selected range + the metric id + the catalog count).
    @State private var correlationCache: [CorrRow] = []
    @State private var correlationKey: String? = nil

    // MARK: Presentation state
    /// The day (or bin) under the finger; nil shows the latest value.
    @State private var selected: Date?
    /// HRV's SDNN line, off by default: RMSSD is the headline.
    @State private var showsSDNN = false
    /// Companion series read for display only (sleep need, the other stages, zone minutes).
    @State private var companions: [String: [(day: String, value: Double)]] = [:]
    @State private var companionsLoadedFor: String?
    @State private var showAllReadings = false
    @State private var showScoringGuide = false
    /// Derived per-range values, rebuilt only when their inputs change (never per scrub tick).
    @State private var memo = MetricDetailMemo()

    init(metric: MetricDescriptor) {
        self.metric = metric
        _range = State(initialValue: ExploreRange(MetricPresentation.of(metric).defaultRange))
    }

    private var loadTaskID: String {
        MetricDetailSteps.loadIdentity(metricID: metric.id, refreshSequence: repo.refreshSeq,
                                       skinTemperatureStyle: skinTempDisplayRaw, range: range)
    }

    private var companionTaskID: String { "\(metric.id)|\(repo.refreshSeq)" }

    // MARK: Derived (range rules, unchanged)

    /// The trailing-N-days slice for a given range, taken RELATIVE TO THE LATEST data point (not "now") —
    /// `.all` returns everything. Feeds the correlation scan and the steps readings, as before.
    private func slice(for r: ExploreRange) -> [(day: String, value: Double)] {
        guard let days = r.days else { return series }
        guard let lastDay = series.last?.day, let last = parseDay(lastDay) else { return [] }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        return series.filter { row in
            guard let d = parseDay(row.day) else { return false }
            return d >= cutoff
        }
    }

    private var isStepsDetail: Bool { MetricDetailSteps.isMetric(metric.key) }

    /// The one series every visible steps summary consumes. Non-step metrics retain their raw daily window.
    private func presentedSeries(for r: ExploreRange) -> [(day: String, value: Double)] {
        guard isStepsDetail else { return slice(for: r) }
        return MetricDetailSteps.presentation(readings: series, range: r).series
    }

    /// The range the control and chart ACTUALLY describe, resolved NON-DESTRUCTIVELY from the stored `range`
    /// (#943). The chips are the six `ChartRange`s, so the coercion only lands on a range that has a chip
    /// (2W and 3W stay internal to the steps bucketing).
    private var coercedSelection: ExploreRange {
        ExploreRangeGating.coerced(selection: range, isUnlocked: { isUnlocked($0) && $0.chartRange != nil })
    }

    /// The SELECTED range whenever its window holds ≥1 point, otherwise the smallest LARGER range that does.
    private var effectiveRange: ExploreRange {
        guard !series.isEmpty else { return coercedSelection }
        let candidates = isStepsDetail
            ? MetricDetailSteps.widening(from: coercedSelection)
            : coercedSelection.widening
        for r in candidates where !presentedSeries(for: r).isEmpty { return r }
        return .all
    }

    /// Whole days between the first and last reading (0 for a single point).
    private var historySpanDays: Int {
        guard let firstDay = series.first?.day, let lastDay = series.last?.day,
              let first = parseDay(firstDay), let last = parseDay(lastDay) else { return 0 }
        return Int(last.timeIntervalSince(first) / 86_400)
    }

    /// Whether a range is selectable (#943): a longer range unlocks once the history span EXCEEDS the
    /// previous window. W and ALL are never gated; nothing is gated before the series loads.
    private func isUnlocked(_ r: ExploreRange) -> Bool {
        guard loaded, !series.isEmpty else { return true }
        switch r {
        case .week, .all: return true
        case .twoWeeks:   return historySpanDays > ExploreRange.week.rawValue
        case .threeWeeks: return historySpanDays > ExploreRange.twoWeeks.rawValue
        case .month:      return historySpanDays > ExploreRange.threeWeeks.rawValue
        case .quarter:    return historySpanDays > ExploreRange.month.rawValue
        case .half:       return historySpanDays > ExploreRange.quarter.rawValue
        case .year:       return historySpanDays > ExploreRange.half.rawValue
        }
    }

    /// The window immediately preceding the active one (equal length). Steps compare calendar periods;
    /// every other metric steps back the same number of readings, as before.
    private func previousWindow(effectiveRange: ExploreRange,
                                windowed: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        guard effectiveRange != .all else { return [] }
        if isStepsDetail, let anchorDay = MetricDetailSteps.latestValidDay(readings: series) {
            return MetricDetailSteps.previousPresentation(
                readings: series, range: effectiveRange, currentAnchorDay: anchorDay).series
        }
        let size = windowed.count
        guard size > 0 else { return [] }
        guard let firstDay = windowed.first?.day,
              let lo = series.firstIndex(where: { $0.day == firstDay }) else { return [] }
        let prevLo = max(0, lo - size)
        guard prevLo < lo else { return [] }
        return Array(series[prevLo..<lo])
    }

    /// The personal baseline fold (HRV, resting HR, respiratory rate, absolute skin temperature) over the
    /// FULL history, or nil until it is TRUSTED (at least fourteen valid nights, not stale). Same fold
    /// `VitalBands` bands against, so the band here and the Health tiles agree.
    private func baselineState(_ band: MetricPresentation.Band?) -> BaselineState? {
        let cfg: MetricCfg?
        switch band {
        case .hrv: cfg = Baselines.hrvCfg
        case .restingHR: cfg = Baselines.restingHRCfg
        case .resp: cfg = Baselines.respCfg
        case .skinAbsolute: cfg = Baselines.metricCfg["skin_temp"]
        case nil: cfg = nil
        }
        guard let cfg else { return nil }
        let state = Baselines.foldHistory(series.map { $0.value }, cfg: cfg)
        return state.trusted ? state : nil
    }

    // MARK: Presentation inputs

    private var units: MetricUnitContext {
        MetricUnitContext(system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }

    private var presentation: MetricPresentation {
        let base = MetricPresentation.of(metric)
        guard metric.key == "skin_temp" else { return base }
        let absolute = series.last.map { VitalBands.isAbsoluteSkinTemp($0.value) } ?? false
        return base.forSkinTemp(absolute: absolute)
    }

    private var companionsReady: Bool {
        presentation.companions.isEmpty || companionsLoadedFor == companionTaskID
    }

    /// Loaded, against a repository that has its data, with any companion series in.
    private var isLoaded: Bool { loaded && loadedWithRepository && companionsReady }

    /// The Monday-first calendar the steps buckets use, so a weekly bar lines up with its bucket.
    private var chartCalendar: Calendar {
        guard isStepsDetail else { return .current }
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    private var memoSignature: String {
        let today = ChartDay.key(for: Date())
        return [metric.id, "\(range.rawValue)", "\(series.count)", series.first?.day ?? "", series.last?.day ?? "",
                "\(series.last?.value ?? 0)", "\(sdnnSeries.count)", "\(sourceByDay.count)", unitSystemRaw,
                temperatureRaw, effortScaleRaw, skinTempDisplayRaw, "\(repo.refreshSeq)", today,
                "\(companions.count)", companionsLoadedFor ?? "", skinTempNote ?? "", "\(loaded)",
                "\(profile.age)"].joined(separator: "|")
    }

    private func frame() -> MetricDetailFrame {
        memo.frame(signature: memoSignature) { buildFrame() }
    }

    private func buildFrame() -> MetricDetailFrame {
        let p = presentation
        let units = self.units
        let effRange = effectiveRange
        let chartRange = effRange.chartRange ?? .month
        let calendar = chartCalendar
        let unitLabel = p.unit(catalogUnit: metric.unit, units: units)
        func shown(_ v: Double) -> Double { p.display(v, units: units, unitLabel: metric.unit) }

        // The window ends today; a series whose newest reading is older than the window ends at that reading
        // instead (the explorer's "relative to the latest point" rule), so a stale series still shows.
        let now = Date()
        var anchor = now
        if let lastKey = series.last?.day, let lastDay = ChartDay.date(forKey: lastKey, calendar: calendar) {
            if let days = chartRange.days,
               let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)),
               lastDay < windowStart {
                anchor = lastDay.addingTimeInterval(12 * 3_600)
            } else if lastDay > now {
                anchor = lastDay.addingTimeInterval(12 * 3_600)
            }
        }
        let firstDay = series.first.flatMap { ChartDay.date(forKey: $0.day, calendar: calendar) }
        let window = ChartAxis.window(chartRange, now: anchor, firstDataDay: firstDay, calendar: calendar)

        // Bars bin by the range (steps keep their own calendar buckets).
        let resolution = MetricDetailSteps.resolution(for: effRange)
        let bin: Calendar.Component
        if isStepsDetail {
            bin = resolution == .daily ? .day : (resolution == .weekly ? .weekOfYear : .month)
        } else if p.isBarChart {
            bin = p.key == "intensity_min" ? (chartRange == .week ? .day : .weekOfYear) : chartRange.totalsBin
        } else {
            bin = .day
        }
        let statWindow = bin == .day ? window : ChartAxis.snap(window, to: bin, calendar: calendar)
        let startKey = ChartDay.key(for: statWindow.lowerBound, calendar: calendar)
        let endKey = ChartDay.key(for: statWindow.upperBound.addingTimeInterval(-1), calendar: calendar)

        func isEstimate(_ day: String) -> Bool {
            if p.isEstimateSeries { return true }
            if metric.key == "spo2", sourceByDay[day] == spo2CandidateAttributionSource { return true }
            if p.marksOnDeviceDaysAsEstimates, let source = sourceByDay[day], source.hasSuffix("-noop") { return true }
            return false
        }
        let segmentIds = metric.key == "vo2max_est"
            ? vo2MaxTrendSegmentIds(days: series.map(\.day), sourceByDay: sourceByDay)
            : Array(repeating: "default", count: series.count)

        // Every reading as a local day, in display units.
        let dailyPoints: [DailyPoint] = series.enumerated().compactMap { index, row in
            DailyPoint(key: row.day, value: shown(row.value), isEstimate: isEstimate(row.day),
                       series: segmentIds[index], calendar: calendar)
        }

        // What the chart draws, and what the readout reads.
        let chartPoints: [DailyPoint]
        let readoutPoints: [DailyPoint]
        let rawWindow: [(day: String, value: Double)]
        if isStepsDetail {
            let buckets = MetricDetailSteps.presentation(readings: series, range: effRange).buckets
            rawWindow = slice(for: effRange)
            let rawDays = Set(rawWindow.map(\.day))
            let estimateDays = Set(rawWindow.map(\.day).filter(isEstimate))
            chartPoints = buckets.compactMap { bucket in
                // A bucket is an estimate when at least half its observed days are.
                let days = rawDays.filter { MetricDetailSteps.bucketKey(for: $0, resolution: resolution) == bucket.key }
                let estimates = days.filter { estimateDays.contains($0) }.count
                return DailyPoint(key: bucket.displayDay, value: Double(bucket.mean),
                                  isEstimate: !days.isEmpty && estimates * 2 >= days.count, calendar: calendar)
            }
            readoutPoints = chartPoints
        } else {
            rawWindow = series.filter { $0.day >= startKey && $0.day <= endKey }
            chartPoints = dailyPoints
            if p.isBarChart && bin != .day {
                readoutPoints = DailyBarChart.bin(dailyPoints, by: bin, aggregation: p.aggregation, calendar: calendar)
            } else {
                readoutPoints = dailyPoints
            }
        }
        let windowRows = rawWindow.map { (day: $0.day, value: shown($0.value)) }

        // References.
        let state = baselineState(p.band)
        let typical: ClosedRange<Double>? = state.map { s in
            let sigma = Baselines.sigma(s) * VitalBands.sigmaK
            let low = shown(max(0, s.baseline - sigma)), high = shown(s.baseline + sigma)
            return min(low, high)...max(low, high)
        }
        let baseline: Double? = (p.band == .hrv || p.band == .restingHR) ? state.map { shown($0.baseline) } : nil

        // Companions, as display values by day.
        func companion(_ key: String) -> [String: Double] {
            Dictionary((companions[key] ?? []).map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        var asleepByDay: [String: Double] = [:]
        var needByDay: [String: Double] = [:]
        var zonesByDay: [String: [Double]] = [:]
        var stack: MetricStackData?
        switch p.chart {
        case .stacked(let kind):
            stack = MetricStackData.build(kind, ownKey: metric.key, own: series, companions: companions,
                                          calendar: calendar)
            if case .sleepStages = kind {
                let stages = ["sleep_deep_min", "sleep_rem_min", "sleep_light_min"]
                let maps = stages.map { $0 == metric.key ? Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a }) : companion($0) }
                for row in series {
                    let parts = maps.compactMap { $0[row.day] }
                    if parts.count == 3 { asleepByDay[row.day] = parts.reduce(0, +) }
                }
            }
            if case .zones = kind {
                let maps = (1...5).map { companion("hr_zone\($0)_min") }
                for row in series {
                    let parts = maps.map { $0[row.day] ?? 0 }
                    if parts.contains(where: { $0 > 0 }) { zonesByDay[row.day] = parts }
                }
            }
        default:
            break
        }
        if metric.key == "sleep_total_min" { needByDay = companion("sleep_need_min") }
        if metric.key == "sleep_need_min" { asleepByDay = companion("sleep_total_min") }

        // Statistics for the visible range.
        let previousRaw = previousWindow(effectiveRange: effRange,
                                         windowed: isStepsDetail ? presentedSeries(for: effRange) : rawWindow)
        let previous = isStepsDetail ? previousRaw.map(\.value) : previousRaw.map { shown($0.value) }
        var statsWindow = windowRows
        if p.cadence == .workoutDays {
            // Zone and strength minutes only exist on workout days; an absent day is zero, never a gap.
            statsWindow = windowRows.filter { $0.value > 0 }
        }
        let statsInput = MetricStatsInput(window: statsWindow, previous: previous, typical: typical,
                                          asleepByDay: asleepByDay, needByDay: needByDay, zonesByDay: zonesByDay,
                                          age: profile.age > 0 ? profile.age : nil, unit: unitLabel)
        var stats = MetricStats.items(p, input: statsInput)
        if isStepsDetail, let vsIndex = p.stats.firstIndex(of: .vsPrevious) {
            // Steps compare the bucket series with the previous equal calendar period, as before.
            let current = presentedSeries(for: effRange).map(\.value)
            let cmp = ComparisonEngine.compare(current: current, previous: previous)
            let delta = p.deltaParts(cmp.delta, unit: unitLabel)
            let hasDelta = cmp.current.n > 0 && cmp.previous.n > 0
            stats[vsIndex] = StatItem(String(localized: "vs previous"), value: hasDelta ? delta.value : nil,
                                      unit: hasDelta ? delta.unit : nil)
        }

        // The readout's idle context line.
        // Skin temperature that fell back to deviations although Settings asks for temperatures says so in
        // one line; the full explanation is in About.
        let note: String? = metric.key == "skin_temp" && skinTempNote != nil && p.chart == .diverging
            && skinTempPreferred == .absolute ? String(localized: "Showing difference from baseline") : nil
        let windowCount = isStepsDetail ? chartPoints.filter { window.contains($0.day) }.count : windowRows.count
        let idle = MetricReadoutContext.idle(p, rows: isStepsDetail ? windowRows : series.map { (day: $0.day, value: shown($0.value)) },
                                             windowRows: windowRows, windowCount: windowCount, typical: typical, unit: unitLabel,
                                             age: profile.age > 0 ? profile.age : nil,
                                             bin: isStepsDetail ? bin : (p.isBarChart ? bin : .day), note: note)

        // Readings, newest first, dated as local days.
        let readings = vitalReadingRows(
            readings: rawWindow.map { VitalReading(day: $0.day, value: $0.value, source: sourceByDay[$0.day] ?? metric.source) },
            unit: "", strapDeviceId: repo.deviceId,
            format: { p.textWithUnit(shown($0), unit: unitLabel) })
        let readingRows: [ReadingsList.Row] = zip(rawWindow.reversed(), readings).map { raw, row in
            let date = ChartDay.date(forKey: raw.day).map { ReadoutContent.dateLine($0, period: .day) } ?? row.time
            return ReadingsList.Row(id: raw.day, date: date, value: row.value, source: row.source)
        }

        // A goal or need rule on daily totals: the range's average sleep need, the 150-minute week.
        var goal: ChartReference?
        if metric.key == "sleep_total_min" {
            let needs = windowRows.compactMap { needByDay[$0.day] }
            if !needs.isEmpty {
                let need = needs.reduce(0, +) / Double(needs.count)
                goal = ChartReference(need, label: String(localized: "Need \(p.text(need))"))
            }
        } else if metric.key == "intensity_min", bin != .day {
            goal = ChartReference(150, label: "150 min")
        }
        let scoreMax = metric.key == "strain" && units.effortScale == .whoop ? 21.0 : 100.0
        let divergingReference = units.temperature == .fahrenheit ? 0.9 : 0.5

        return MetricDetailFrame(
            presentation: p, effectiveRange: effRange, chartRange: chartRange, window: window, bin: bin,
            calendar: calendar, unit: unitLabel, axisUnit: p.axisUnit(catalogUnit: metric.unit, units: units),
            chartPoints: chartPoints, readoutPoints: readoutPoints, windowRows: windowRows,
            hasData: !chartPoints.isEmpty, typical: typical, baseline: baseline,
            sdnnPoints: metric.key == "hrv" ? sdnnSeries.compactMap { DailyPoint(key: $0.day, value: $0.value) } : [],
            stack: stack, stats: stats, idleContext: idle, readings: readingRows,
            widened: effRange != coercedSelection, age: profile.age > 0 ? profile.age : nil,
            goal: goal, scoreMax: scoreMax, divergingReference: divergingReference)
    }

    // MARK: Body

    var body: some View {
        let f = frame()
        let p = f.presentation
        let loadingNow = !isLoaded
        return ScreenScaffold(title: "\(metric.title)", titleDisplay: .navigationBar, isLoading: loadingNow) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                ValueReadout(readout(f), isScrubbing: selected != nil, isLoading: loadingNow)
                rangeControl(f, loading: loadingNow)
            }
            primaryCard(f, loading: loadingNow)
            secondarySections(f, loading: loadingNow)
            StatGrid(f.stats, columns: statColumns, isLoading: loadingNow)
            contextSection(f)
            readingsSection(f, loading: loadingNow)
            MetricCorrelationsSection(rows: correlationCache.map { .init(id: $0.id, metric: $0.metric, r: $0.r, n: $0.n) },
                                      isLoading: !correlationsLoaded)
            aboutCard(p)
        }
        .task(id: loadTaskID) {
            let repositoryReady = repo.loaded
            await load()
            if repositoryReady, !Task.isCancelled { loadedWithRepository = true }
        }
        .task(id: companionTaskID) { await loadCompanions() }
        // Range changes the window, hence the correlation inputs — recompute the cached scan rather than
        // letting the correlation card run it inside body.
        .onChangeCompat(of: range) { _ in
            selected = nil
            recomputeCorrelations()
        }
        .navigationDestination(isPresented: $showAllReadings) {
            MetricReadingsListView(title: metric.title, rows: f.readings)
        }
        .sheet(isPresented: $showScoringGuide) {
            ScoringGuideView(initialSection: p.scoringSection, onClose: { showScoringGuide = false })
        }
    }

    private var statColumns: Int {
        #if os(macOS)
        return 4
        #else
        return 2
        #endif
    }

    // MARK: Readout

    private func readout(_ f: MetricDetailFrame) -> ReadoutContent {
        let p = f.presentation
        let valueColor: ((Double) -> Color)? = {
            switch p.chart {
            case .scoreBars(let fill):
                if let bands = MetricScoreBands.bands(for: fill) { return { bands.band(for: $0).color } }
                if fill == .effort {
                    let max = effortScale == .whoop ? 21.0 : 100.0
                    return { StrandPalette.effortTint(fraction: $0 / max) }
                }
                return nil
            default:
                return nil
            }
        }()
        let selectedPoint = ChartSelection.point(for: selected, in: f.readoutPoints, unit: f.bin, calendar: f.calendar)
        var context: String?
        if selected == nil {
            context = f.idleContext
        } else {
            context = MetricReadoutContext.selected(p, value: selectedPoint?.value, typical: f.typical, unit: f.unit,
                                                    bin: f.bin, aggregation: p.isBarChart ? p.aggregation : nil)
            if showsSDNN, let selected,
               let sdnn = f.sdnnPoints.first(where: { f.calendar.isDate($0.day, inSameDayAs: selected) }) {
                context = String(localized: "SDNN \(p.text(sdnn.value)) ms")
            }
        }
        if case .stacked = p.chart, selected != nil, context == nil {
            context = f.stack?.contextLine(for: selected, bin: f.bin, calendar: f.calendar, text: p.text)
        }
        return ReadoutContent.daily(selection: selected, in: f.readoutPoints, bin: f.bin,
                                    nightly: p.isNightly && f.bin == .day, unit: f.unit, format: { p.text($0) },
                                    context: context, valueColor: valueColor, calendar: f.calendar)
    }

    // MARK: Range control

    @ViewBuilder
    private func rangeControl(_ f: MetricDetailFrame, loading: Bool) -> some View {
        let binding = Binding<ChartRange>(get: { range.chartRange ?? .month },
                                          set: { range = ExploreRange($0) })
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if loading {
                // The options are decided once the history span is known; until then the track holds the
                // control's place.
                RoundedRectangle(cornerRadius: NoopMetrics.insetRadius, style: .continuous)
                    .fill(StrandPalette.surfaceInset)
                    .frame(height: RangeControl.height)
                    .accessibilityHidden(true)
            } else {
                RangeControl(selection: binding, isAvailable: { isUnlocked(ExploreRange($0)) },
                             reservesSpaceWhenHidden: true)
            }
            if f.widened, !loading {
                Text("Showing \(f.chartRange.accessibilityName), the nearest range with readings")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    // MARK: Primary chart

    private func chartState(_ f: MetricDetailFrame, loading: Bool) -> ChartState {
        if loading { return .loading }
        guard f.hasData else {
            if metric.key == "fitness_age" {
                return .empty(fitnessReadyLeadCopy(rhrDays: repo.days.suffix(7).compactMap { $0.restingHr }.count,
                                                   hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty))
            }
            return .empty(f.presentation.emptyMessage)
        }
        return .ready
    }

    private func primaryCard(_ f: MetricDetailFrame, loading: Bool) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                MetricPrimaryChart(frame: f, title: metric.title, state: chartState(f, loading: loading),
                                   showsSDNN: showsSDNN, selection: $selected)
                if metric.key == "hrv" {
                    MetricHRVLegend(hasSDNN: !f.sdnnPoints.isEmpty, hasBand: f.typical != nil,
                                    hasBaseline: f.baseline != nil, showsSDNN: $showsSDNN)
                }
                if metric.key == "fitness_age", !f.hasData, !loading {
                    // Fitness Age is COMPUTED on-device; force the weekly recompute NOW from stored data
                    // (works offline), then re-read.
                    if refreshing {
                        ProgressView().controlSize(.small).tint(StrandPalette.accent)
                    } else {
                        NoopButton("Refresh Fitness Age", systemImage: "arrow.clockwise", kind: .tertiary) {
                            guard !refreshing else { return }
                            refreshing = true
                            Task {
                                _ = await intelligence.recomputeFitnessAgeOnly()
                                await load()
                                refreshing = false
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Secondary visuals

    @ViewBuilder
    private func secondarySections(_ f: MetricDetailFrame, loading: Bool) -> some View {
        let p = f.presentation
        if p.secondary.contains(.intraday), let intraday = intradayMetric {
            IntradaySeriesSection(metric: intraday, accent: p.tint.color)
        }
        if p.secondary.contains(.banked), metric.source == "my-whoop",
           metric.key == "skin_temp" || metric.key == "spo2" {
            BankedReadingsSection(signal: metric.key == "skin_temp" ? .skinTemp : .bloodOxygen,
                                  accent: p.tint.color)
        }
        if p.secondary.contains(.bandMix), case .scoreBars(let fill) = p.chart,
           let bands = MetricScoreBands.bands(for: fill), f.hasData || loading {
            MetricShareCard(title: p.isNightly ? String(localized: "Nights by band") : String(localized: "Days by band"),
                            rows: MetricShareRows.bands(bands, values: f.windowRows.map(\.value)),
                            isLoading: loading)
        }
        if p.secondary.contains(.distribution), f.hasData || loading {
            MetricShareCard(title: String(localized: "Check-ins"),
                            rows: MetricShareRows.levels(values: f.windowRows.map(\.value)),
                            isLoading: loading)
        }
    }

    /// The server's 5-minute series for this metric, when the hosted worker computes one and cloud scoring
    /// is on. Everything else, and every local-scoring install, shows nothing here.
    private var intradayMetric: IntradayMetric? {
        guard CloudPushSettings.isEnabled, CloudPushSettings.isConfigured else { return nil }
        return IntradayMetric(catalogKey: metric.key, source: metric.source)
    }

    // MARK: Context rows

    @ViewBuilder
    private func contextSection(_ f: MetricDetailFrame) -> some View {
        let contextMetric = MeasurementContextPage.metric(forCatalogKey: metric.key, source: metric.source)
        let showsMeasurement = contextMetric != nil && CloudPushSettings.isEnabled && CloudPushSettings.isConfigured
            && series.last != nil
        let showsActivity = activityContext != nil && activityInterval != nil && activityDayWindow != nil
        let showsWalking = isStepsDetail && CloudPushIdentityStore.current() != nil && series.last != nil
        if showsMeasurement || showsActivity || showsWalking {
            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if let contextMetric, showsMeasurement, let day = series.last?.day {
                        MeasurementContextRow(metric: contextMetric, day: day)
                    }
                    if showsActivity, let context = activityContext, let interval = activityInterval,
                       let dayWindow = activityDayWindow {
                        if showsMeasurement { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        ActivityContextLine(document: context, interval: interval,
                                            dayStart: dayWindow[0], dayEnd: dayWindow[1])
                    }
                    if showsWalking, let day = slice(for: effectiveRange).last?.day ?? series.last?.day {
                        if showsMeasurement || showsActivity {
                            NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                        }
                        NavigationLink {
                            WalkingDetailView(day: day)
                        } label: {
                            NoopListRow(icon: "figure.walk", iconColor: ActivityFamily.walking.color,
                                        title: "How you walked")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Readings

    @ViewBuilder
    private func readingsSection(_ f: MetricDetailFrame, loading: Bool) -> some View {
        if loading {
            // Placeholder rows while the series loads, so the sections below do not jump when it lands.
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Readings")
                ReadingsList(rows: (0..<3).map { ReadingsList.Row(id: "\($0)", date: "Wed, Oct 7", value: "00 ms",
                                                                 source: "WHOOP") },
                             visibleCount: 3, onShowAll: nil)
            }
        } else if !f.readings.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Readings")
                ReadingsList(rows: f.readings, visibleCount: 7, onShowAll: { showAllReadings = true })
            }
        }
    }

    // MARK: About

    private func aboutCard(_ p: MetricPresentation) -> some View {
        var paragraphs = p.about(title: metric.title, catalogDescription: metric.description)
        if let skinTempNote { paragraphs.insert(skinTempNote, at: min(1, paragraphs.count)) }
        if let intraday = intradayMetric {
            paragraphs.insert(IntradaySeriesSection.note(for: intraday), at: max(0, paragraphs.count - 1))
        }
        let shown = paragraphs
        return AboutDisclosure("About") {
            AboutParagraphs(shown)
            if p.scoringSection != nil {
                NoopButton("How it is scored", kind: .tertiary) { showScoringGuide = true }
            }
        }
    }

    // MARK: Load

    /// Display-only companion series (sleep need behind asleep time, the other sleep stages, zone minutes),
    /// read after the page's own series and never feeding anything but the chart and its statistics.
    private func loadCompanions() async {
        let keys = MetricPresentation.of(metric).companions
        guard !keys.isEmpty else { return }
        var loadedCompanions: [String: [(day: String, value: Double)]] = [:]
        for key in keys {
            guard !Task.isCancelled else { return }
            loadedCompanions[key] = await repo.exploreSeries(key: key, source: metric.source)
        }
        guard !Task.isCancelled else { return }
        companions = loadedCompanions
        if repo.loaded { companionsLoadedFor = companionTaskID }
    }

    /// Two phases, because the screen used to wait for data it does not draw.
    ///
    /// Phase 1 is this metric's own series + provenance — everything the visible screen needs. `loaded`
    /// flips there. Phase 2 is the catalog scan, awaited afterwards, and only the correlation card waits
    /// on it. Same reads, same results, same order.
    private func load() async {
        // Phase 1 — what the screen actually draws.
        let requestedRange = range
        let resolution: MetricSeriesResolution
        let loadedSeries: [(day: String, value: Double)]
        if isStepsDetail {
            // Steps have one authoritative daily input for values and provenance. ALL deliberately reads
            // the store-backed full-history resolver instead of the bounded in-memory Explore cache.
            let fullHistory = MetricDetailSteps.requiresFullHistory(
                metricKey: metric.key, range: requestedRange)
            if metric.source == MetricCatalog.combinedStepsSource {
                resolution = await repo.resolvedSteps(from: "0000-01-01", to: "9999-12-31")
            } else {
                resolution = await repo.resolvedSeries(
                    key: metric.key, source: metric.source, fullHistory: fullHistory)
            }
            loadedSeries = resolution.values
        } else {
            // Preserve the generic explorer's established value path and load order.
            loadedSeries = await repo.exploreSeries(key: metric.key, source: metric.source)
            resolution = await repo.resolvedSeries(key: metric.key, source: metric.source)
        }
        // A range tap changes the task identity. Do not let a cancelled bounded read overwrite a newer
        // full-history ALL read (or vice versa) if the underlying store await completes late.
        guard !Task.isCancelled, !isStepsDetail || requestedRange == range else { return }
        series = loadedSeries
        // Per-day provenance for the readings table (task #8). resolvedSeries names the source that
        // actually supplied each day (imported strap / on-device / Apple Health / Health Connect).
        if metric.key == "vo2max_est" {
            var attributed: [String: String] = [:]
            for point in resolution.points {
                let tag = await repo.scoreProvenanceTag(
                    resolvedSource: point.source, day: point.day, metricKey: metric.key)
                attributed[point.day] = vo2MaxAttributionSource(tag.flatMap { Vo2MaxEstimator(rawValue: $0) })
            }
            sourceByDay = attributed
        } else {
            sourceByDay = Dictionary(resolution.points.map { ($0.day, $0.source) },
                                     uniquingKeysWith: { first, _ in first })
        }
        // #103/queue-11a follow-up: fill in the spo2 candidate fallback for any day this Explorer's
        // calibrated `spo2` series has no reading for — the SAME fallback Today's Key Metrics tile,
        // `VitalSignsSummary`, and `LiquidTodayView` already show. Calibrated days always win — this only
        // ADDS days the calibrated series is missing, never overwrites one. Gated on the same toggle every
        // other candidate site checks, and on the source: only the WHOOP/Oura partition has a candidate
        // series behind it.
        if metric.key == "spo2", metric.source == "my-whoop", PuffinExperiment.spo2CandidateDisplayEnabled {
            let candidateSeries = await repo.exploreSeries(key: "spo2_candidate", source: metric.source)
            if !candidateSeries.isEmpty {
                // `uniquingKeysWith`, matching the `sourceByDay` build above — NOT `uniqueKeysWithValues`,
                // which TRAPS on a duplicate day.
                var byDay = Dictionary(series.map { ($0.day, $0.value) },
                                       uniquingKeysWith: { first, _ in first })
                for point in candidateSeries where byDay[point.day] == nil {
                    byDay[point.day] = point.value
                    sourceByDay[point.day] = spo2CandidateAttributionSource
                }
                series = byDay.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
            }
        }
        // #1848: skin-temp explorer — a skin-temp-specific branch mirroring the Android `buildVitalDetail`
        // "skin" case, rather than the shared `dailyColumn` → `skinTempDevC` path.
        //
        // The preference applies across the WINDOW (#1850), not just the newest row: the chosen kind wins
        // whenever any night carries it, the other is still the fallback, so a choice can never empty the
        // screen. An absolute may live in EITHER column (#622: a WHOOP CSV import writes absolute °C into
        // `skinTempDevC`), so both count here and in the series below.
        skinTempNote = nil
        if metric.key == "skin_temp" {
            let days = repo.days
            let anyAbsolute = days.contains { row in
                row.skinTempC != nil
                    || row.skinTempDevC.map(VitalBands.isAbsoluteSkinTemp) == true
            }
            let anyDeviation = days.contains { row in
                row.skinTempDevC.map { !VitalBands.isAbsoluteSkinTemp($0) } == true
            }
            if anyAbsolute || anyDeviation {
                let leadsAbsolute: Bool
                switch skinTempPreferred {
                case .absolute:   leadsAbsolute = anyAbsolute
                case .deviation:  leadsAbsolute = !anyDeviation && anyAbsolute
                }
                if leadsAbsolute {
                    // An absolute-led series takes EVERY absolute reading, whichever column holds it.
                    series = days.compactMap { row in
                        let v = row.skinTempC
                            ?? row.skinTempDevC.flatMap { VitalBands.isAbsoluteSkinTemp($0) ? $0 : nil }
                        return v.map { (day: row.day, value: $0) }
                    }.sorted { $0.day < $1.day }
                } else {
                    // Genuine deviations only — an imported absolute sitting in `skinTempDevC` belongs to
                    // the other scale and is excluded, exactly as before.
                    series = days.compactMap { row in
                        row.skinTempDevC.flatMap { !VitalBands.isAbsoluteSkinTemp($0) ? $0 : nil }
                            .map { (day: row.day, value: $0) }
                    }.sorted { $0.day < $1.day }
                }
                // Rebuild sourceByDay for the new series: every reading attributes to the metric's own source.
                sourceByDay = Dictionary(series.map { ($0.day, metric.source) },
                                         uniquingKeysWith: { first, _ in first })
                // The two #1847 notes (now an About paragraph and the readout's context line).
                let shownReadings = series.count
                let rowsWithEither = days.count { $0.skinTempC != nil || $0.skinTempDevC != nil }
                if shouldExplainSkinTempFallback(prefer: skinTempPreferred, leadsAbsolute: leadsAbsolute,
                                                 anyAbsoluteInWindow: anyAbsolute) {
                    skinTempNote = String(localized: "No measured temperature for these nights — showing the difference from your baseline instead. A re-score refills temperatures for nights that have one.")
                } else if shouldExplainShortenedSkinTempSeries(leadsAbsolute: leadsAbsolute,
                                                                shownReadings: shownReadings,
                                                                rowsWithEitherNumber: rowsWithEither) {
                    skinTempNote = String(localized: "Only nights with a measured temperature are shown — the others only have a baseline difference.")
                }
            }
        }
        // #943 selection seam: a locked default renders through `coercedSelection` instead of being
        // overwritten (non-destructive, recomputed every body eval).
        if metric.key == "hrv" {
            sdnnSeries = repo.days.compactMap { row in
                row.avgSdnn.map { (day: row.day, value: $0) }
            }.sorted { $0.day < $1.day }
        }
        loaded = true

        // Optional activity context for the latest day (HRV / resp / SpO2 only). Runs AFTER the visible
        // screen is up; a nil result leaves the screen as a feature-off build.
        await loadActivityContext()

        // Phase 2 — the cross-catalog scan behind the correlation card, now that the screen is up. The scan
        // is memoized on the Repository (`exploreAllSeries`); cancellation is checked per metric.
        guard let allSeries = await repo.exploreAllSeries() else { return }
        var loadedOthers: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
        for other in MetricCatalog.all where other.id != metric.id {
            guard !Task.isCancelled else { return }
            if let s = allSeries[other.id], !s.isEmpty { loadedOthers.append((other, s)) }
        }
        guard !Task.isCancelled else { return }
        others = loadedOthers
        correlationsLoaded = true
        // First correlation build, now that `series`/`others` exist.
        recomputeCorrelations()
    }

    // MARK: Activity context

    /// Load the hosted `daily.activity_context` for the LATEST day of this metric's series, then pick the
    /// support interval the read-out joins on (see `ActivityContextSelection`). Every failure mode leaves
    /// the three @State fields nil and the screen renders exactly as a feature-off build.
    private func loadActivityContext() async {
        guard Self.activityMetrics.contains(metric.key) else { return }
        guard let latestDay = series.last?.day else { return }
        guard CloudPushIdentityStore.current() != nil,
              let repository = CloudPushRuntime.shared.scoreRepository(),
              let dayWindow = ActivityContextSelection.dayWindow(day: latestDay) else { return }
        let deviceIds = await IntradaySeriesStore.shared.readCandidates
        guard let cached = await repository.cachedDay(day: latestDay, deviceIds: deviceIds) else { return }
        let loadKey = "\(latestDay)|\(cached.resultRevision ?? "")"
        guard loadKey != activityLoadedKey else { return }
        guard let hosted = cached.hostedResult, let document = hosted.activityContext else { return }
        let sessions = hosted.sleep.map { (start: $0.startTs, end: $0.endTs) }
        activityContext = document
        activityInterval = ActivityContextSelection.interval(metricKey: metric.key,
                                                             document: document,
                                                             dayWindow: dayWindow,
                                                             sleepSessions: sessions)
        activityDayWindow = dayWindow
        activityLoadedKey = loadKey
    }

    // MARK: Correlations

    private struct CorrRow: Identifiable {
        let id: String
        let metric: MetricDescriptor
        let r: Double
        let n: Int
    }

    /// Top |r| catalog metrics over a given window (|r| ≥ 0.30, n ≥ 10). Pure.
    private func computeCorrelationRows(windowed: [(day: String, value: Double)]) -> [CorrRow] {
        let myDays = Set(windowed.map(\.day))
        guard !myDays.isEmpty else { return [] }
        var rows: [CorrRow] = []
        for entry in others {
            let otherWindowed = entry.series.filter { myDays.contains($0.day) }
            let pairs = CorrelationEngine.alignByDay(windowed, otherWindowed)
            guard pairs.count >= 10, let c = CorrelationEngine.pearson(pairs) else { continue }
            if abs(c.r) >= 0.3 {
                rows.append(CorrRow(id: entry.metric.id, metric: entry.metric, r: c.r, n: c.n))
            }
        }
        rows.sort { abs($0.r) > abs($1.r) }
        return Array(rows.prefix(6))
    }

    /// Rebuild the cached correlation scan for the CURRENT effective window, but only when its key (metric
    /// id + selected range + catalog count) actually changed.
    private func recomputeCorrelations() {
        // `others.count` belongs in the key: the catalog scan lands AFTER the screen, so a range change
        // during the scan would otherwise cache an empty result under this key and never recompute.
        let key = "\(metric.id)|\(range.rawValue)|\(others.count)"
        guard correlationKey != key else { return }
        correlationKey = key
        correlationCache = computeCorrelationRows(windowed: slice(for: effectiveRange))
    }
}

// MARK: - Frame (derived values for one range)

/// Everything the page draws for the visible range, derived once per input change.
struct MetricDetailFrame {
    let presentation: MetricPresentation
    let effectiveRange: ExploreRange
    let chartRange: ChartRange
    let window: ClosedRange<Date>
    let bin: Calendar.Component
    let calendar: Calendar
    let unit: String?
    let axisUnit: String?
    /// What the primary chart is handed (all history; the chart keeps its window). Steps: the buckets.
    let chartPoints: [DailyPoint]
    /// What the bars show (binned), so the readout reads a bar rather than one day inside it.
    let readoutPoints: [DailyPoint]
    /// The visible range's readings in display units (daily values for steps).
    let windowRows: [(day: String, value: Double)]
    let hasData: Bool
    let typical: ClosedRange<Double>?
    let baseline: Double?
    let sdnnPoints: [DailyPoint]
    let stack: MetricStackData?
    let stats: [StatItem]
    let idleContext: String?
    let readings: [ReadingsList.Row]
    let widened: Bool
    let age: Int?
    /// A goal or need rule on daily totals.
    let goal: ChartReference?
    /// The top of a score's scale (Effort: 100, or 21 on the WHOOP scale).
    let scoreMax: Double
    /// ±0.5 °C (0.9 °F) around zero on the skin-temperature deviation chart.
    let divergingReference: Double
}

/// Holds the last derived frame. A reference held in `@State`, so reading or replacing it never invalidates
/// the view: a scrub re-renders the readout without re-deriving the series.
final class MetricDetailMemo {
    private var signature: String?
    private var cached: MetricDetailFrame?

    func frame(signature: String, build: () -> MetricDetailFrame) -> MetricDetailFrame {
        if signature == self.signature, let cached { return cached }
        let built = build()
        self.signature = signature
        self.cached = built
        return built
    }
}

extension MetricPresentation {
    /// How a week or month of this metric bins into one bar.
    var aggregation: ChartAggregation {
        if case .totals(let aggregation) = chart { return aggregation }
        return .mean
    }
}

extension MetricDetailSteps {
    /// The bucket a daily key falls in for `resolution`: the day itself, its Monday, or its month — the same
    /// identity `StepsDetailDensity` groups by.
    static func bucketKey(for day: String, resolution: Resolution) -> String {
        switch resolution {
        case .daily: return day
        case .weekly: return MetricStats.mondayKey(day) ?? day
        case .monthly: return String(day.prefix(7))
        }
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func detailPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Metric Detail") {
    let repo = detailPreviewRepo()
    return NavigationStack {
        MetricDetailView(metric: MetricCatalog.all.first { $0.key == "recovery" }!)
    }
    .environmentObject(repo)
    .environmentObject(ProfileStore())
    .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
    .frame(width: 900, height: 820)
}
#endif
