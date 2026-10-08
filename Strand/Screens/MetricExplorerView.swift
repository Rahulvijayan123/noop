import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Explore (Metric Explorer) and the shared detail helpers
//
// The catalog-driven "Explore" list (one section per MetricCatalog category, a row per metric with data,
// each pushing a MetricDetailView) and the pure helpers the detail page, Today and the tests share: the
// range enum and its #943 gating, the steps bucketing adapter, the readings projection and the
// skin-temperature note rules. The detail page itself lives in MetricDetailView.swift; how each metric is
// drawn lives in MetricPresentation.swift.
//
// Sparse-metric rule (owner saw "no data" on metrics that HAVE data): a series may be sampled weekly
// (weight / body fat). The range rules take windows RELATIVE TO THE LATEST data point, so a stale but
// present series still resolves; only an empty window widens to the smallest larger range that has data.

// yyyy-MM-dd → Date, fixed UTC / en_US_POSIX (per task spec).
private let strandDayParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func parseDay(_ day: String) -> Date? { strandDayParser.date(from: day) }

/// Localized long date for the hero "as of" line, with a fixed calendar-day time zone.
private func longDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = AppLanguage.activeLocale
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "d MMM yyyy"
    return f.string(from: d)
}

// MARK: - Range

/// The W/2W/3W/M/3M/6M/1Y/ALL window, driving the single SegmentedPillControl.
enum ExploreRange: Int, CaseIterable, Identifiable, Hashable {
    case week = 7, twoWeeks = 14, threeWeeks = 21, month = 30, quarter = 90, half = 180, year = 365, all = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .twoWeeks: return String(localized: "2W"); case .threeWeeks: return String(localized: "3W")
        case .week: return String(localized: "W"); case .month: return String(localized: "M"); case .quarter: return String(localized: "3M")
        case .half: return String(localized: "6M"); case .year: return String(localized: "1Y"); case .all: return String(localized: "ALL")
        }
    }
    var name: String {
        switch self {
        case .twoWeeks: return String(localized: "2 weeks"); case .threeWeeks: return String(localized: "3 weeks")
        case .week: return String(localized: "week"); case .month: return String(localized: "month"); case .quarter: return String(localized: "quarter")
        case .half: return String(localized: "6 months"); case .year: return String(localized: "year"); case .all: return String(localized: "all time")
        }
    }
    /// Trailing days the window spans (nil = everything).
    var days: Int? { self == .all ? nil : rawValue }

    /// This range plus every LARGER range, ascending — the auto-expand search order
    /// when the selected window holds zero points. ALW always terminates the chain.
    var widening: [ExploreRange] {
        let order: [ExploreRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }
}

/// The bridge between the detail page's `ExploreRange` and the kit's six-chip `ChartRange` (W M 3M 6M Y All).
/// `ExploreRange` keeps its eight cases and the #943 gating; 2W and 3W stay internal to the steps bucketing
/// and have no chip.
extension ExploreRange {
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

    /// The chip this range shows as; nil for 2W and 3W.
    var chartRange: ChartRange? {
        switch self {
        case .week: return .week
        case .twoWeeks, .threeWeeks: return nil
        case .month: return .month
        case .quarter: return .quarter
        case .half: return .half
        case .year: return .year
        case .all: return .all
        }
    }
}

/// The steps-specific adapter between the shared calendar projection and this screen. Keeping the
/// policy pure makes the renderer consume one authoritative bucket series for its chart, headline,
/// statistics and accessibility text while the readings table can continue to show daily inputs.
enum MetricDetailSteps {
    enum Resolution: Equatable {
        case daily
        case weekly
        case monthly
    }

    struct Presentation {
        let buckets: [StepsDetailBucket]
        let resolution: Resolution

        var series: [(day: String, value: Double)] {
            buckets.map { (day: $0.displayDay, value: Double($0.mean)) }
        }

        var accessibilitySummary: String {
            guard let latest = buckets.last else { return String(localized: "Steps chart, no data") }
            let noun = buckets.count == 1 ? String(localized: "bar") : String(localized: "bars")
            let period = MetricDetailSteps.periodLabel(day: latest.displayDay, resolution: resolution)
            switch resolution {
            case .daily:
                return String(localized: "Steps chart, \(buckets.count) daily \(noun), latest \(latest.mean) steps, \(period)")
            case .weekly:
                return String(localized: "Steps chart, \(buckets.count) weekly \(noun), latest \(latest.mean) average steps per observed day, \(period)")
            case .monthly:
                return String(localized: "Steps chart, \(buckets.count) monthly \(noun), latest \(latest.mean) average steps per observed day, \(period)")
            }
        }
    }

    static func isMetric(_ metricKey: String) -> Bool {
        metricKey == "steps" || metricKey == "steps_est"
    }

    static func range(_ range: ExploreRange) -> StepsDetailRange {
        switch range {
        case .week: return .week
        case .twoWeeks: return .twoWeeks
        case .threeWeeks: return .threeWeeks
        case .month: return .month
        case .quarter: return .threeMonths
        case .half: return .sixMonths
        case .year: return .year
        case .all: return .all
        }
    }

    static func resolution(for range: ExploreRange) -> Resolution {
        switch range {
        case .week, .twoWeeks, .threeWeeks, .month: return .daily
        case .quarter: return .weekly
        case .half, .year, .all: return .monthly
        }
    }

    static func widening(from range: ExploreRange) -> [ExploreRange] {
        let order = ExploreRange.allCases
        guard let index = order.firstIndex(of: range) else { return [.all] }
        return Array(order[index...])
    }

    static func presentation(readings: [(day: String, value: Double)], range: ExploreRange,
                             anchorDay: String? = nil) -> Presentation {
        let buckets = StepsDetailDensity.project(
            readings: readings.map { StepsDetailReading(day: $0.day, value: $0.value) },
            range: self.range(range), anchorDay: anchorDay)
        return Presentation(buckets: buckets, resolution: resolution(for: range))
    }

    static func latestValidDay(readings: [(day: String, value: Double)]) -> String? {
        StepsDetailDensity.project(
            readings: readings.map { StepsDetailReading(day: $0.day, value: $0.value) },
            range: .week).last?.displayDay
    }

    /// The finite comparison window ends one day before the current window and has the same number
    /// of local calendar days. The shared projector then applies the same daily/weekly/monthly fold.
    static func previousPresentation(readings: [(day: String, value: Double)], range: ExploreRange,
                                     currentAnchorDay: String) -> Presentation {
        let parts = currentAnchorDay.split(separator: "-")
        guard let dayCount = range.days, parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return Presentation(buckets: [], resolution: resolution(for: range))
        }
        let previousAnchor = LocalCalendarDate(year: year, month: month, day: day)
            .adding(days: -dayCount).key
        return presentation(readings: readings, range: range,
                            anchorDay: previousAnchor)
    }

    static func requiresFullHistory(metricKey: String, range: ExploreRange) -> Bool {
        isMetric(metricKey) && range == .all
    }

    static func loadIdentity(metricID: String, refreshSequence: Int,
                             skinTemperatureStyle: String, range: ExploreRange) -> String {
        let metricKey = metricID.split(separator: ":").last.map(String.init) ?? metricID
        let rangeIdentity = isMetric(metricKey)
            ? "|\(range.rawValue)" : ""
        return "\(metricID)|\(refreshSequence)|\(skinTemperatureStyle)\(rangeIdentity)"
    }

    static func periodLabel(day: String, resolution: Resolution) -> String {
        guard let date = parseDay(day) else { return day }
        switch resolution {
        case .daily:
            return String(localized: "as of \(longDate(date))")
        case .weekly:
            return String(localized: "week of \(longDate(date))")
        case .monthly:
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.activeLocale
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: date)
        }
    }

    static func countCaption(count: Int, resolution: Resolution, rangeName: String) -> String {
        let noun = count == 1 ? String(localized: "bar") : String(localized: "bars")
        switch resolution {
        case .daily:
            return String(localized: "\(count) daily \(noun) · \(rangeName)")
        case .weekly:
            return String(localized: "\(count) weekly \(noun) · average per observed day · \(rangeName)")
        case .monthly:
            return String(localized: "\(count) monthly \(noun) · average per observed day · \(rangeName)")
        }
    }

    static func valueLabel(_ value: Double, resolution: Resolution) -> String {
        let formatted = value.formatted(.number.locale(AppLanguage.activeLocale).precision(.fractionLength(0)))
        switch resolution {
        case .daily:
            return String(localized: "\(formatted) steps")
        case .weekly, .monthly:
            return String(localized: "\(formatted) average steps per observed day")
        }
    }
}

/// Pure #943 chip-coercion rule, extracted so it can be pinned by a test (the Swift twin of Android's
/// `coercedVitalRange` in HealthScreen.kt). Resolves a stored selection NON-DESTRUCTIVELY: an unlocked
/// selection is kept verbatim; a LOCKED one renders as the largest unlocked range with a real finite
/// window (`days != nil`, so never ALL) whose rawValue is <= the selection, else `.week`. Coercing a
/// locked default to ALL would jump a calibrating user to the everything view, so it is excluded.
enum ExploreRangeGating {
    static func coerced(selection: ExploreRange, isUnlocked: (ExploreRange) -> Bool) -> ExploreRange {
        if isUnlocked(selection) { return selection }
        return [ExploreRange.year, .half, .quarter, .month, .threeWeeks, .twoWeeks, .week]
            .first { $0.days != nil && $0.rawValue <= selection.rawValue && isUnlocked($0) } ?? .week
    }
}

// MARK: - Readings table projection (task #8)

/// One windowed reading behind a vital's detail chart: its day ("YYYY-MM-DD"), the value, and the RAW
/// source id it came from (a strap id, the "-noop" computed sibling, "apple-health", or "health-connect").
/// The readings TABLE and the "N readings" caption both derive from this ONE windowed list, so they can
/// never disagree; the raw source maps to a human label via `TodayView.provenanceDisplayLabel` — the SAME
/// resolver Today uses, so no source vocabulary is invented. Swift twin of Android's `VitalReading`.
struct VitalReading: Equatable {
    let day: String
    let value: Double
    let source: String
}

let vo2MaxAttributionPrefix = "vo2max-estimator:"

/// #103/queue-11a follow-up: a display-source token for a `spo2` reading that came from the
/// `spo2_candidate` fallback (WHOOP `spo2_candidate_82` or Oura ceiling@100 `0x6F`, device-conditional)
/// rather than a calibrated `spo2Pct` import. Every OTHER surface that shows this fallback (Today's Key
/// Metrics tile, `VitalSignsSummary`, `LiquidTodayView`) already labels it "strap estimate (unverified)"
/// — this Explorer/"Your Cards" drill-down had no candidate fallback at all until now (found 2026-08-24:
/// an Oura-only or WHOOP-4.0-only install with the toggle ON saw nothing here past the last calibrated
/// import, even though the Key Metrics tile right next to it showed a real number). Same
/// prefix-token idiom as `vo2MaxAttributionSource` just below, so the existing readings-table plumbing
/// needs no new machinery — only `TodayView.provenanceDisplayLabel` gains one more case.
let spo2CandidateAttributionSource = "spo2-candidate-estimate"

/// A display-source token that keeps the existing readings-table plumbing while naming the estimator.
/// `nil` is deliberately preserved as `unknown`; a legacy point must never inherit today's profile method.
func vo2MaxAttributionSource(_ estimator: Vo2MaxEstimator?) -> String {
    vo2MaxAttributionPrefix + (estimator?.rawValue ?? "unknown")
}

/// Will the chart show a visible break in this VO₂max trend?
///
/// Derived from `vo2MaxTrendSegmentIds` rather than recomputed, so the caption and the segmentation can
/// never disagree. A GAP IN DAYS under one estimator is still a single segment and draws no break, so it
/// correctly gets no caption: a break means the readings were not produced alike, not that the data
/// paused. Named for the BREAK: an untagged legacy reading resolves to "...estimator:unknown", so an
/// unknown -> Nes transition splits the line while the method itself may never have changed.
/// Kotlin twin `vo2MaxTrendHasBreak`.
func vo2MaxTrendHasBreak(days: [String], sourceByDay: [String: String]) -> Bool {
    Set(vo2MaxTrendSegmentIds(days: days, sourceByDay: sourceByDay)).count > 1
}

/// Sequential segment ids for the VO₂max trend. The counter matters when a user changes Nes → Uth → Nes:
/// using the method name alone would reconnect the two non-adjacent Nes runs across the Uth interval.
func vo2MaxTrendSegmentIds(days: [String], sourceByDay: [String: String]) -> [String] {
    var previous: String?
    var group = -1
    return days.map { day in
        let source = sourceByDay[day] ?? vo2MaxAttributionSource(nil)
        if source != previous { group += 1; previous = source }
        return "\(group):\(source)"
    }
}

func vo2MaxEstimatorDisplayName(_ estimator: Vo2MaxEstimator?) -> String {
    switch estimator {
    case .nes: return "Nes 2011"
    case .uth: return "Uth 2004"
    case nil:  return String(localized: "Unknown")
    }
}

/// One row of a vital detail's readings table: the reading's day (localized), its formatted value with
/// unit, and a human source label. Plain strings so the view is a thin renderer and the projection stays
/// unit-testable. Swift twin of Android's `VitalReadingRow`.
struct VitalReadingRow: Equatable {
    let time: String
    let value: String
    let source: String
}

/// Project a vital's windowed `readings` into table rows, NEWEST FIRST — the same list (so the same count)
/// the "N readings" caption shows, guaranteeing the two never drift. Each row pairs the reading's DAY
/// (these vital series carry one aggregated reading per night, so a row's "time" is its localized calendar
/// date; the date always shows since a charted window spans 2+ days) with the model's own `format`ted
/// value + `unit` and the source label from `TodayView.provenanceDisplayLabel` (a strap id → "Whoop", its
/// "-noop" sibling → "On-device", "apple-health" → "Apple Health", "health-connect" → "Health Connect").
/// `strapDeviceId` is the active strap id the resolver needs. Byte-identical projection to Android's
/// `vitalReadingRows`.
func vitalReadingRows(readings: [VitalReading], unit: String, strapDeviceId: String,
                      now: Date = Date(), format: (Double) -> String) -> [VitalReadingRow] {
    readings.reversed().map { reading in
        let value = format(reading.value)
        return VitalReadingRow(
            time: vitalReadingDateLabel(reading.day, now: now),
            value: unit.isEmpty ? value : "\(value) \(unit)",
            source: TodayView.provenanceDisplayLabel(rawSource: reading.source, deviceId: strapDeviceId)
        )
    }
}

/// "9 Jun" for a "YYYY-MM-DD" reading day (today / yesterday read as words to match the hero "as of"
/// line); the verbatim string if it doesn't parse. UTC-fixed and localized, matching this file's other date
/// labels. Swift twin of Android's `vitalReadingDateLabel`.
func vitalReadingDateLabel(_ day: String, now: Date = Date()) -> String {
    guard let date = parseDay(day) else { return day }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    if cal.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
    if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
       cal.isDate(date, inSameDayAs: yesterday) { return String(localized: "Yesterday") }
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.activeLocale
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "d MMM"
    return formatter.string(from: date)
}

// MARK: - Skin-temp explorer notes (#1847 / #1848)

/// Whether the skin-temp explorer must explain that it fell back to deviations despite the
/// user's Settings choice asking for temperatures. Twin of Android's `shouldExplainSkinTempFallback`.
///
/// True only when the user asked for absolute, the screen is NOT leading with absolutes, and NO
/// night in the window carries one — so the fallback is total, not partial. A window with one
/// stored temperature and twenty deltas still leads with temperatures (the #1850 window-wide rule),
/// so this note stays silent there; it fires only when the setting genuinely cannot be honoured.
func shouldExplainSkinTempFallback(prefer: SkinTempDisplay.Kind, leadsAbsolute: Bool,
                                   anyAbsoluteInWindow: Bool) -> Bool {
    prefer == .absolute && !leadsAbsolute && !anyAbsoluteInWindow
}

/// Whether the skin-temp explorer must explain that deviation-only nights were dropped from the
/// series when leading with absolutes. Twin of Android's `shouldExplainShortenedSkinTempSeries`.
///
/// True ONLY when leading with the absolute — the deviation-led branch also drops rows (calibrating
/// nights that have only an absolute, and the #622 bimodal partition), but those are the OPPOSITE
/// kind, so this note's sentence would be precisely backwards there. True only when rows were
/// actually dropped, so a complete series stays silent.
func shouldExplainShortenedSkinTempSeries(leadsAbsolute: Bool, shownReadings: Int,
                                          rowsWithEitherNumber: Int) -> Bool {
    leadsAbsolute && shownReadings < rowsWithEitherNumber
}

// MARK: - Root: categorized list

/// The "Explore" list: Deep Timeline first, then one section per category with a row per metric that has
/// data (its latest value on the right), and the metrics with nothing yet collapsed at the bottom.
struct MetricExplorerView: View {
    @EnvironmentObject var repo: Repository
    /// metric.id → whether its series is empty, from one cheap probe (`Repository.nonEmptyMetricIDs`).
    @State private var emptyByID: [String: Bool] = [:]
    @State private var probedRefreshSeq: Int?
    /// True until the first probe lands. The list is drawn redacted until then, so rows that turn out to
    /// have no data never appear and then move.
    @State private var probing = true
    /// metric.id → its newest reading, from the memoized catalog scan; fills in after the probe.
    @State private var latestByID: [String: MetricLatest] = [:]
    @State private var showsEmpty = false

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    var body: some View {
        #if os(macOS)
        // macOS: Explore is a standalone detail pane, so it owns its NavigationStack, unless Browse pushed it.
        MorePaneNavigation { exploreScaffold }
            .task(id: repo.refreshSeq) { await probe(refreshSeq: repo.refreshSeq) }
        #else
        // iOS: Explore is pushed inside a tab's NavigationStack. A nested NavigationStack made tapping a
        // metric bounce straight back (#199), so use the ambient stack; the rows push their detail with a
        // direct closure-based NavigationLink (#38).
        exploreScaffold
            .task(id: repo.refreshSeq) { await probe(refreshSeq: repo.refreshSeq) }
        #endif
    }

    private var units: MetricUnitContext {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return MetricUnitContext(system: system,
                                 temperature: UnitPrefs.resolveTemperature(system: system, override: temperatureRaw),
                                 effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw))
    }

    private func hasData(_ metric: MetricDescriptor) -> Bool { !(emptyByID[metric.id] ?? false) }

    private var emptyMetrics: [MetricDescriptor] {
        probing ? [] : MetricCatalog.all.filter { !hasData($0) }
    }

    private var exploreScaffold: some View {
        // Pushed on iPhone (inline navigation-bar title); a sidebar pane on the Mac, which keeps its header.
        ScreenScaffold(title: "Explore", titleDisplay: .navigationBar, isLoading: probing,
                       onRefresh: { await repo.refresh() }, lazy: true) {
            NoopListSection {
                // The full-day, full-resolution, zoomable timeline (#575): every second of one day rather than
                // one number per day. Closure-based NavigationLink, matching the metric rows (#38/#199).
                NavigationLink {
                    FullDayChartView()
                } label: {
                    NoopListRow(icon: "waveform.path.ecg", iconColor: StrandPalette.metricRose, title: "Deep Timeline")
                }
                .buttonStyle(LiquidPressStyle())
                #if os(iOS)
                .simultaneousGesture(TapGesture().onEnded { StrandHaptic.selection.play() })
                #endif
            }

            ForEach(MetricCatalog.categories, id: \.self) { category in
                let metrics = MetricCatalog.inCategory(category).filter { probing || hasData($0) }
                if !metrics.isEmpty {
                    // Localized at the render site only; `category` itself stays the raw English identifier.
                    NoopListSection("\(MetricCatalog.categoryDisplayName(category))") {
                        rows(metrics)
                    }
                }
            }

            if !emptyMetrics.isEmpty {
                emptySection(emptyMetrics)
            }
        }
    }

    @ViewBuilder
    private func rows(_ metrics: [MetricDescriptor]) -> some View {
        ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
            if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
            // Push the detail directly (closure-based). The old value + .navigationDestination(for:) pairing
            // resolved against TWO registered destinations and double-pushed (#38).
            NavigationLink {
                MetricDetailView(metric: metric)
            } label: {
                NoopListRow(icon: metric.icon, iconColor: MetricPresentation.of(metric).tint.color,
                            title: "\(metric.title)",
                            subtitle: needsSourceLabel(metric, among: metrics) ? metric.sourceLabel : nil,
                            value: latestText(metric))
            }
            .buttonStyle(LiquidPressStyle())
            #if os(iOS)
            // A light selection tick on tap; the simultaneousGesture leaves the NavigationLink push intact.
            .simultaneousGesture(TapGesture().onEnded { StrandHaptic.selection.play() })
            #endif
        }
    }

    /// The source names a row only when another row in the same list has the same title ("Steps" from
    /// Apple Health, the strap and a Mi Band).
    private func needsSourceLabel(_ metric: MetricDescriptor, among metrics: [MetricDescriptor]) -> Bool {
        metrics.contains { $0.id != metric.id && $0.title == metric.title }
    }

    /// The newest reading with its unit ("57 bpm", "6 h 42 m"), or nil until the scan lands.
    private func latestText(_ metric: MetricDescriptor) -> String? {
        guard let latest = latestByID[metric.id] else { return nil }
        let p = MetricPresentation.of(metric).forSkinTemp(absolute: VitalBands.isAbsoluteSkinTemp(latest.value))
        let value = p.display(latest.value, units: units, unitLabel: metric.unit)
        let unit = p.unit(catalogUnit: metric.unit, units: units)
        // A long unit ("ml/kg/min") would push the title into an ellipsis; the detail page carries it.
        return p.textWithUnit(value, unit: (unit?.count ?? 0) > 5 ? nil : unit)
    }

    /// The metrics with nothing yet, collapsed into one row at the bottom; still tappable, so a reader can
    /// see the empty page and where the data comes from.
    private func emptySection(_ metrics: [MetricDescriptor]) -> some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    showsEmpty.toggle()
                } label: {
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: "tray")
                            .font(StrandFont.icon(.row))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text("No data yet")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: NoopMetrics.space2)
                        Text("\(metrics.count)")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Image(systemName: "chevron.down")
                            .font(StrandFont.icon(.inline))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(showsEmpty ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsEmpty ? Text("Expanded") : Text("Collapsed"))
                if showsEmpty {
                    NoopListDivider(leadingInset: 0)
                    rows(metrics)
                }
            }
        }
    }

    /// One cheap pass to learn which metrics have no series (one DISTINCT-key query per source), then the
    /// newest reading per metric from the Repository's memoized catalog scan (the same scan the detail
    /// pages' correlation card reads). Failures default to "has data".
    private func probe(refreshSeq: Int) async {
        guard probedRefreshSeq != refreshSeq || emptyByID.isEmpty else { probing = false; return }
        probedRefreshSeq = refreshSeq
        let nonEmpty = await repo.nonEmptyMetricIDs(MetricCatalog.all)
        guard !Task.isCancelled else { return }
        emptyByID = Dictionary(uniqueKeysWithValues: MetricCatalog.all.map { ($0.id, !nonEmpty.contains($0.id)) })
        probing = false
        guard let all = await repo.exploreAllSeries(), !Task.isCancelled else { return }
        var latest: [String: MetricLatest] = [:]
        for metric in MetricCatalog.all {
            if let last = all[metric.id]?.last { latest[metric.id] = MetricLatest(day: last.day, value: last.value) }
        }
        latestByID = latest
    }
}

/// A metric's newest reading, for the Explore list.
struct MetricLatest: Equatable {
    let day: String
    let value: Double
}

// MARK: - Preview

#if DEBUG
@MainActor
private func explorerPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Explore") {
    MetricExplorerView()
        .environmentObject(explorerPreviewRepo())
        .frame(width: 900, height: 820)
}
#endif
