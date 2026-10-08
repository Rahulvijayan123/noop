import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

/// One workout's heart-rate recovery, for the recovery page (#516).
struct WorkoutRecoveryTrendPoint: Identifiable, Equatable {
    let startTs: Int
    let result: HeartRateRecovery.Result
    var id: Int { startTs }
}

// MARK: - Workouts
//
// The workout log. The top of the page is a glance at the selected range: training time (the readout, which
// the bar chart's scrub drives), a range control, the bars, and four statistics. Depth sits one tap down:
// heart-rate zones, heart-rate recovery, active calories and each sport have their own pages. Below them the
// sessions, grouped by day; each opens its detail page, and its "•••" (or a long press) holds edit, re-label,
// dismiss, duplicate and delete.

struct WorkoutsView: View {
    @EnvironmentObject var repo: Repository
    /// PERF (chart-invalidation): `AppModel` publishes `bpm` at ~1 Hz (AppModel.swift:202) via
    /// `@Published`, and `@EnvironmentObject` subscribes to the WHOLE object's `objectWillChange` —
    /// regardless of which properties `body` actually reads. Holding `model: AppModel` here re-ran this
    /// screen's entire body (chart + grids + sorting) every tick. `hrMax` and `analyzeRecent()`
    /// are the only two things this screen needs, and both live on sub-objects (`ProfileStore`,
    /// `IntelligenceEngine`) injected separately at the app root (StrandApp.swift) — neither publishes at
    /// live-tick frequency. The one genuinely `AppModel`-dependent piece ("Start Workout" / active-session
    /// state, #459) is isolated into `WorkoutStartControl`, mirroring `HealthView`'s live-observing-leaf
    /// pattern (HealthView.swift:17-22, 44-46), so a tick re-renders only that small leaf.
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var intelligence: IntelligenceEngine

    // Exercise-distance preference (#1913). Unset follows the original combined preference.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    // Effort display scale (#268). Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// All loaded sessions, newest first. Seedable for previews. #797: this holds only the rows inside the
    /// currently-LOADED window (`loadedWindowDays`), not the entire history. A 1700+-workout import made
    /// the eager all-rows read + sort fire on every `refreshSeq` bump (first paint AND every backfill
    /// slice). First paint loads a bounded window; selecting a wider range than is loaded lazily pages in
    /// the rest (`expandWindow`).
    @State private var allRows: [WorkoutRow]
    @State private var loaded: Bool
    @State private var seededInitialRange = false

    @State private var range: ChartRange = .all
    /// The training bar under the finger (the readout reads it).
    @State private var selectedBar: Date?
    /// The list shows the most recent `currentScopeCount` sessions of the range until "Show all".
    @State private var showsAllSessions = false
    /// #797: how many trailing days of workouts are currently LOADED into `allRows`. First paint loads
    /// `Self.firstPaintWindowDays`; picking "All" (or a range wider than this) pages the full history in on
    /// demand. nil means the full history is loaded (the user expanded to "All"). Preview rows are treated
    /// as fully loaded (nil) so the preview path is unchanged.
    @State private var loadedWindowDays: Int?
    private let usesPreviewRows: Bool

    /// Daily active-calorie totals (day "yyyy-MM-dd" → kcal) for the 13-week calendar, loaded alongside the
    /// rows. Empty until loaded / when there's no daily-calorie data.
    @State private var dailyKcal: [String: Double] = [:]

    /// Local `yyyy-MM-dd` formatter for the calendar's day keys + "today" anchor (matches the stored keys).
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func todayDayString() -> String { dayFormatter.string(from: Date()) }

    /// #797: trailing-day window the FIRST workouts read is bounded to, so first paint never sorts a
    /// multi-thousand-workout history. Comfortably covers the default range (the tightest range with ≥2
    /// sessions, almost always ≤90 days); a wider pick pages the rest in via `expandWindow`. 400 days
    /// covers the 1Y range plus headroom.
    static let firstPaintWindowDays = 400

    /// The add/edit sheet target: `.some(nil)` = add a new workout, `.some(row)` = edit `row`,
    /// `nil` = sheet closed. Wrapped in Identifiable so `.sheet(item:)` can drive presentation.
    @State private var sheet: WorkoutSheetTarget?

    /// A transient one-line note shown after a manual save / relabel for a sport that already has a
    /// solid/building ActivityCost entry — "Sessions like this usually …" (#439). Auto-clears.
    @State private var postLogNote: String?

    /// #516: eligible workouts in the visible 7/30/90-day window, calculated from recorded HR. Wider
    /// workout ranges intentionally keep this trend capped at 90 days so opening a deep history never
    /// launches hundreds of raw-HR reads.
    @State private var recoveryTrend: [WorkoutRecoveryTrendPoint] = []
    /// False until the first recovery pass has finished, so the row shows no value rather than "—".
    @State private var recoveryLoaded = false

    // MARK: - Filters + selection (#64)

    /// Filter beyond the time range: a displayed-sport key (nil = all) and an origin class (nil = all).
    /// Pure `WorkoutFilter` applies them after the window cut.
    @State private var sportFilter: String?
    @State private var sourceFilter: WorkoutSource?

    /// Multi-select + merge mode. `selectionMode` toggles the leading checkmarks + the toolbar strip;
    /// `selected` holds the natural keys ("startTs|sport") of the chosen rows. Only MANUAL / DETECTED rows
    /// are selectable (imported history is read-only and can never be merged or bulk-deleted).
    @State private var selectionMode = false
    @State private var selected: Set<String> = []
    /// When every selected row is a bare detected bout, the merge has no sport to keep — this drives a
    /// small confirm sheet asking the user to name the merged session.
    @State private var mergeSportPrompt: MergeSportTarget?

    #if DEBUG
    /// `--demo-workout-open detail|sport|zones|recovery|calories`: push one sub-page after the first load,
    /// for simulator screenshots (nothing outside the app can tap).
    @State private var demoOpen: DemoPage?
    #endif

    /// The selection key for a row (its natural key). Stable across a reload so the checkmarks persist.
    private func selectionKey(_ row: WorkoutRow) -> String { "\(row.startTs)|\(row.sport)" }

    /// Wraps the pending merge inputs so a `.sheet(item:)` can present the "name the merged session" prompt
    /// (used only when every selected row is detected, so there's no sport to inherit).
    private struct MergeSportTarget: Identifiable {
        let rows: [WorkoutRow]
        let id = UUID()
    }

    /// Wraps the optional edited row so `.sheet(item:)` can present add (editing == nil) or edit.
    private struct WorkoutSheetTarget: Identifiable {
        let editing: WorkoutRow?
        /// True for "Duplicate as manual": the form pre-fills FROM a read-only row, but the save is a pure
        /// ADD. The pre-fill row is not a stored manual row, so it must never travel on as `replacing:` —
        /// it carries the ORIGINAL's natural key while claiming source "manual", and the repository would
        /// take that as an edit and retire the row it was copied from. `Repository.saveManualWorkout`
        /// documents that an imported row is never passed as `replacing`; this is what makes that true.
        var isCopy = false
        let id = UUID()
    }

    init(previewRows: [WorkoutRow]? = nil) {
        _allRows = State(initialValue: previewRows ?? [])
        _loaded = State(initialValue: previewRows != nil)
        // Preview-seeded rows are treated as the full history (nil window) so the preview path never pages.
        _loadedWindowDays = State(initialValue: previewRows != nil ? nil : Self.firstPaintWindowDays)
        usesPreviewRows = previewRows != nil
    }

    var body: some View {
        #if os(macOS)
        // The Mac sidebar hosts this pane without a navigation stack of its own, and the session rows and
        // the zone / recovery / sport pages push (MetricExplorerView makes the same choice).
        MorePaneNavigation { page }
        #else
        page
        #endif
    }

    private var page: some View {
        // Compute the windowed (unscoped) rows ONCE per body evaluation and thread them into the page AND
        // the HR-recovery trend `.task(id:)` further down this modifier chain.
        let unscopedRows = sessions(for: range)
        let trendRows = recoveryTrendRows(from: unscopedRows)
        return ScreenScaffold(title: "Workouts", titleDisplay: .navigationBar,
                              onRefresh: { await repo.refresh() },
                              // PERF: the column ends in the session log, a row per session. The LazyVStack
                              // path builds the off-screen day groups on demand.
                              lazy: true) {
            if loaded && allRows.isEmpty {
                workoutActionRow
                ComingSoon(what: "No workouts yet. They come from your WHOOP and Apple Health history. Import in Data Sources to bring them in, or add one you tracked elsewhere.")
            } else {
                content(rows: unscopedRows)
            }
        }
        .toolbar {
            if loaded && !allRows.isEmpty {
                ToolbarItem(placement: .primaryAction) { filterMenu }
            }
        }
        // The post-log note floats over the page instead of pushing it down for a few seconds.
        .overlay(alignment: .bottom) {
            if let postLogNote {
                InlineNotice(postLogNote, tone: .neutral)
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                    .padding(.bottom, NoopMetrics.tabBarClearance)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .task(id: repo.refreshSeq) {
            guard !usesPreviewRows else { return }
            // #797: read only the currently-loaded window (bounded on first paint), not the whole history.
            let r = await repo.workoutRows(days: loadedWindowDays ?? 4000)
            allRows = r
            let wasLoaded = loaded
            loaded = true
            if !wasLoaded {
                range = defaultRange(for: r)
                seededInitialRange = true
                #if DEBUG
                if DemoPage.requested != .recovery { demoOpen = DemoPage.requested }
                #endif
            }
            // 13-week active-calorie calendar: pull ~100 days of daily metrics and map day → active kcal.
            // Loaded AFTER `loaded`/range are set so this secondary read never delays the list's first paint.
            let toDay = Self.todayDayString()
            let fromDate = Calendar.current.date(byAdding: .day, value: -100, to: Date()) ?? Date()
            let metrics = await repo.dailyMetrics(fromDay: Self.dayFormatter.string(from: fromDate), toDay: toDay)
            dailyKcal = Dictionary(metrics.compactMap { m in m.activeKcalEst.map { (m.day, $0) } },
                                   uniquingKeysWith: max)
        }
        .onAppear {
            // Preview-seeded rows skip `.task`; still choose a range that has data.
            if loaded && !seededInitialRange {
                range = defaultRange(for: allRows)
                seededInitialRange = true
            }
        }
        // #797: when the user picks a range wider than the bounded first-paint window (typically "All"),
        // page the full history in. A pick that fits the loaded window is a no-op.
        .onChangeCompat(of: range) { newRange in
            selectedBar = nil
            showsAllSessions = false
            Task { await expandWindowIfNeeded(for: newRange) }
        }
        .task(id: recoveryTrendInputKey(rows: trendRows)) {
            await loadRecoveryTrend(rows: trendRows)
        }
        .sheet(item: $sheet) { target in
            ManualWorkoutSheet(editing: target.editing) { row, replacing in
                Task {
                    // A copy pre-fills the form but replaces nothing — see `WorkoutSheetTarget.isCopy`.
                    await repo.saveManualWorkout(row, replacing: target.isCopy ? nil : replacing)
                    // #598: rescore the just-added workout from the strap's HR for its window NOW, so its
                    // average / peak HR, strain and calories appear immediately (from your own strap data)
                    // instead of waiting up to 15 minutes for the next analyze tick. No-ops when the strap
                    // had no HR for that window, and never overrides a value you typed yourself.
                    await intelligence.analyzeRecent()
                    await reload()
                    // Post-log note (#439): if this sport now has a solid/building recovery-cost
                    // entry, surface its personal-pattern sentence as a transient caption.
                    await showPostLogNote(forSport: WorkoutSource.displaySport(row.sport))
                }
            }
        }
        // #459 / PERF: the "Start Workout" button, its active-session sheet and the sport-picker cover all
        // moved to `WorkoutStartControl`, which owns `AppModel` itself — see the comment on this screen's
        // `profile`/`intelligence` properties above for why `model` can't live here.
        // #64: name the merged session when every selected row is a bare detected bout (there's no sport
        // to inherit). Reuses the "Start a workout" named-sport picker.
        .workoutSelectionCover(item: $mergeSportPrompt) { target in
            StartWorkoutSheet(title: String(localized: "Name the merged session"),
                              subtitle: String(localized: "These sessions have no sport label yet. Pick one for the merged session."),
                              actionVerb: String(localized: "Merge")) { name in
                performMerge(target.rows, sport: name)
            }
        }
        #if DEBUG
        .navigationDestination(isPresented: Binding(get: { demoOpen != nil }, set: { if !$0 { demoOpen = nil } })) {
            demoDestination(rows: unscopedRows)
        }
        #endif
    }

    // MARK: - Page content

    @ViewBuilder
    private func content(rows windowRows: [WorkoutRow]) -> some View {
        let window = WorkoutTraining.window(range, rows: allRows)
        let bin = WorkoutTraining.bin(for: range, window: window)
        let points = WorkoutTraining.minutesPerDay(windowRows)
        workoutActionRow
        if filter.isActive { filterNotice }
        trainingReadout(rows: windowRows, points: points, bin: bin)
        RangeControl(selection: $range, options: WorkoutTraining.ranges,
                     isAvailable: { loaded && WorkoutTraining.isAvailable($0, oldestTs: oldestTs) },
                     reservesSpaceWhenHidden: true)
        NoopCard {
            DailyBarChart.totals(points, color: StrandPalette.effortColor, goal: nil, bin: bin,
                                 aggregation: .sum, legend: [],
                                 state: !loaded ? .loading
                                     : (windowRows.isEmpty ? .empty(String(localized: "No workouts in this range")) : .ready),
                                 window: window, xStyle: range.axisStyle,
                                 y: .durationMinutes(minSpanMinutes: 60),
                                 selection: $selectedBar, accessibilityTitle: String(localized: "Training time"))
        }
        StatGrid(summaryStats(windowRows), columns: statColumns, isLoading: !loaded)
        detailLinks(rows: windowRows)
        sportSection(rows: windowRows)
        sessionsSection(rows: windowRows)
    }

    /// Training time for the range, or for the bar under the finger.
    private func trainingReadout(rows: [WorkoutRow], points: [DailyPoint], bin: Calendar.Component) -> some View {
        let format: (Double) -> String = { WorkoutFormat.duration(minutes: $0) }
        let content: ReadoutContent
        if let selectedBar {
            let binned = DailyBarChart.bin(points, by: bin, aggregation: .sum)
            let n = WorkoutTraining.rows(rows, inBinOf: selectedBar, unit: bin).count
            content = .daily(selection: selectedBar, in: binned, bin: bin, unit: nil, format: format,
                             context: WorkoutTraining.sessionCount(n))
        } else {
            let minutes = rows.compactMap(\.durationS).reduce(0, +) / 60
            content = ReadoutContent(dateLine: rangeLine, value: format(minutes), unit: nil,
                                     context: WorkoutTraining.sessionCount(rows.count))
        }
        return ValueReadout(content, isScrubbing: selectedBar != nil, isLoading: !loaded)
    }

    /// "Last 30 days", or "Since 12 Mar 2025" for All.
    private var rangeLine: String {
        switch range {
        case .week: return WorkoutFormat.sentenceStart(String(localized: "last 7 days"))
        case .month: return WorkoutFormat.sentenceStart(String(localized: "last 30 days"))
        case .quarter: return WorkoutFormat.sentenceStart(String(localized: "last 90 days"))
        case .half, .year: return WorkoutFormat.sentenceStart(String(localized: "last year"))
        case .all:
            guard let first = oldestTs else { return WorkoutFormat.sentenceStart(String(localized: "all time")) }
            return String(localized: "Since \(WorkoutFormat.day(first))")
        }
    }

    private var statColumns: Int {
        #if os(macOS)
        return 4
        #else
        return 2
        #endif
    }

    /// Four statistics for the range: typical effort, the average session, calories and distance (or the
    /// days trained, when nothing in the range has a distance).
    private func summaryStats(_ rows: [WorkoutRow]) -> [StatItem] {
        let strains = rows.compactMap(\.strain)
        let avgStrain = strains.isEmpty ? nil : strains.reduce(0, +) / Double(strains.count)
        let effort = WorkoutFormat.effort(avgStrain, scale: effortScale)
        let durations = rows.compactMap(\.durationS).filter { $0 > 0 }
        let avgMin = durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count) / 60
        let kcal = rows.compactMap(\.energyKcal)
        // Only POSITIVE distances count as "has distance" (a strap-detected sport with no GPS/manual
        // distance is nil, and an explicit 0 is not a real distance) — matches the per-workout rows' `m > 0`
        // guard. When nothing in the window has distance, the cell shows active days instead of a
        // misleading "0.0 km" (#reddit: rugby read as data loss).
        let distancesM = rows.compactMap(\.distanceM).filter { $0 > 0 }
        var items = [
            StatItem(String(localized: "Typical effort"), value: effort?.value, detail: effort?.of),
            StatItem(String(localized: "Avg session"), value: avgMin.map { WorkoutFormat.duration(minutes: $0) }),
            StatItem(String(localized: "Calories"), value: kcal.isEmpty ? nil : WorkoutFormat.grouped(kcal.reduce(0, +)),
                     unit: "kcal"),
        ]
        if distancesM.isEmpty {
            let days = Set(rows.map { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.startTs))) })
            items.append(StatItem(String(localized: "Active days"), value: rows.isEmpty ? nil : "\(days.count)"))
        } else {
            let d = WorkoutFormat.distance(meters: distancesM.reduce(0, +), system: distanceUnitSystem)
            items.append(StatItem(String(localized: "Distance"), value: d.value, unit: d.unit))
        }
        return items
    }

    // MARK: - One tap down: zones, recovery, active calories

    @ViewBuilder
    private func detailLinks(rows: [WorkoutRow]) -> some View {
        let zones = WorkoutZones.summary(from: rows)
        let grid = ActivityHeatmap.build(values: dailyKcal, today: Self.todayDayString())
        NoopCard(padding: 0) {
            VStack(spacing: 0) {
                NavigationLink {
                    WorkoutZonesView(rows: filter.apply(allRows), initialRange: range)
                } label: {
                    NoopListRow(icon: "heart.text.square", iconColor: StrandPalette.metricRose,
                                title: "Heart rate zones", value: zonesValue(zones, sessions: rows.count))
                }
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                NavigationLink {
                    WorkoutRecoveryView(points: recoveryTrend, rows: allRows)
                } label: {
                    NoopListRow(icon: "arrow.down.heart", iconColor: StrandPalette.metricRose,
                                title: "Heart rate recovery", value: recoveryValue)
                }
                // The page shows the figures this page computed, so it opens once they are in.
                .disabled(!recoveryLoaded)
                if !grid.isEmpty {
                    NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                    NavigationLink {
                        WorkoutActiveCaloriesView(dailyKcal: dailyKcal)
                    } label: {
                        NoopListRow(icon: "flame", iconColor: StrandPalette.metricAmber,
                                    title: "Active calories",
                                    value: String(localized: "\(WorkoutFormat.grouped(grid.total)) kcal"))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .loadingPlaceholder(!loaded)
    }

    /// "Z2 · 42 %": the zone that held the most time, from the sessions imported with a split. Nothing when
    /// none were (the zones page then estimates them from the strap, which this page does not read).
    private func zonesValue(_ z: WorkoutZones.Summary?, sessions: Int) -> String? {
        guard let z, z.totalMinutes > 0,
              let top = z.minutes.indices.max(by: { z.minutes[$0] < z.minutes[$1] }) else { return nil }
        return "Z\(top + 1) · \(Int((z.minutes[top] / z.totalMinutes * 100).rounded())) %"
    }

    /// The newest workout's one-minute recovery, "28 bpm".
    private var recoveryValue: String? {
        guard recoveryLoaded else { return nil }
        guard let latest = recoveryTrend.max(by: { $0.startTs < $1.startTs }),
              let one = latest.result.after1Minute else { return "—" }
        return String(localized: "\(one) bpm")
    }

    // MARK: - By sport

    @ViewBuilder
    private func sportSection(rows: [WorkoutRow]) -> some View {
        let groups = WorkoutSports.groups(rows)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("By sport")
                NoopCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, g in
                            if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                            NavigationLink {
                                WorkoutSportView(sport: g.sport,
                                                 rows: filter.apply(allRows).filter { $0.sport == g.sport },
                                                 initialRange: range)
                            } label: {
                                NoopListRow(icon: sportSymbol(g.sport), iconColor: StrandPalette.effortColor,
                                            title: "\(WorkoutSource.displaySport(g.sport))",
                                            subtitle: WorkoutTraining.sessionCount(g.count),
                                            value: WorkoutFormat.duration(minutes: g.totalTimeS / 60))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Sessions

    @ViewBuilder
    private func sessionsSection(rows: [WorkoutRow]) -> some View {
        if !loaded {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Sessions")
                WorkoutRowsPlaceholder()
            }
        } else if !rows.isEmpty {
            let shown = showsAllSessions ? rows : Self.scopedRows(rows, scope: .current)
            let anySelectable = rows.contains(where: WorkoutMerge.isMergeable)
            SectionHeader("Sessions", trailing: WorkoutTraining.sessionCount(rows.count),
                          action: anySelectable
                            ? .button(label: selectionMode ? "Done" : "Select") {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    selectionMode.toggle()
                                    if !selectionMode { selected.removeAll() }
                                }
                              }
                            : nil)
            if selectionMode { selectionToolbar(rows: rows) }
            ForEach(WorkoutDay.group(shown)) { group in
                WorkoutDayGroup(title: WorkoutFormat.day(Int(group.day.timeIntervalSince1970)), rows: group.rows) { row in
                    sessionRow(row)
                }
            }
            if shown.count < rows.count {
                Button {
                    showsAllSessions = true
                } label: {
                    HStack {
                        Text("Show all")
                            .font(StrandFont.subhead.weight(.medium))
                            .foregroundStyle(StrandPalette.accent)
                        Spacer(minLength: NoopMetrics.space2)
                        Text("\(rows.count)")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget)
                    .background(NoopPanelSurface())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One session: a push to its detail page, or a selection toggle in selection mode. The "•••" sits over
    /// the row's reserved trailing column, outside the row's own tap target (#318).
    @ViewBuilder
    private func sessionRow(_ row: WorkoutRow) -> some View {
        let selectable = WorkoutMerge.isMergeable(row)
        let isSelected = selected.contains(selectionKey(row))
        Group {
            if selectionMode {
                Button {
                    guard selectable else { return }
                    withAnimation(.easeOut(duration: 0.12)) { toggleSelection(row) }
                } label: {
                    WorkoutSessionRow(row: row, effortScale: effortScale,
                                      selection: selectable ? (isSelected ? .selected : .unselected) : .locked,
                                      accessory: .none)
                }
            } else {
                NavigationLink {
                    WorkoutDetailView(row: row, presentation: .pushed)
                } label: {
                    WorkoutSessionRow(row: row, effortScale: effortScale)
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if !selectionMode {
                WorkoutRowMenuButton { rowMenu(row) }
                    .padding(.trailing, NoopMetrics.space1)
            }
        }
        .contextMenu { if !selectionMode { rowMenu(row) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(row, selectable: selectable, isSelected: isSelected))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(selectionMode
            ? (selectable ? String(localized: "Double-tap to select") : String(localized: "Imported history can't be merged"))
            : String(localized: "Opens workout detail"))
    }

    /// A full-sentence a11y label for a row.
    private func rowAccessibilityLabel(_ row: WorkoutRow, selectable: Bool, isSelected: Bool) -> String {
        let summary = WorkoutSessionRow(row: row, effortScale: effortScale).accessibilitySummary
        let duration = WorkoutFormat.duration(seconds: row.durationS) ?? ""
        let base = "\(WorkoutSource.displaySport(row.sport)), \(duration), \(summary)"
        guard selectionMode else { return base }
        if !selectable { return String(localized: "\(base). Imported, can't be merged.") }
        return isSelected ? String(localized: "\(base). Selected.") : String(localized: "\(base). Not selected.")
    }

    /// #64: Merge / Delete / Cancel shown above the list in selection mode. Merge needs 2+ eligible rows;
    /// Delete needs 1+.
    private func selectionToolbar(rows: [WorkoutRow]) -> some View {
        let chosen = rows.filter { selected.contains(selectionKey($0)) }
        let canMerge = WorkoutMerge.canMerge(chosen)
        return NoopCard {
            HStack(spacing: NoopMetrics.space4) {
                Button {
                    beginMerge(chosen)
                } label: {
                    Label(String(localized: "Merge (\(chosen.count))"), systemImage: "arrow.triangle.merge")
                        .font(StrandFont.subhead.weight(.medium))
                        .foregroundStyle(canMerge ? StrandPalette.accent : StrandPalette.textTertiary)
                }
                .disabled(!canMerge)

                Button(role: .destructive) {
                    let toDelete = chosen
                    selectionMode = false; selected.removeAll()
                    Task { await repo.bulkDeleteWorkouts(toDelete); await reload() }
                } label: {
                    Label(String(localized: "Delete (\(chosen.count))"), systemImage: "trash")
                        .font(StrandFont.subhead.weight(.medium))
                        .foregroundStyle(chosen.isEmpty ? StrandPalette.textTertiary : StrandPalette.statusCritical)
                }
                .disabled(chosen.isEmpty)

                Spacer(minLength: 0)
                Button(String(localized: "Cancel")) {
                    withAnimation(.easeOut(duration: 0.15)) { selectionMode = false; selected.removeAll() }
                }
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .frame(minHeight: NoopMetrics.minimumHitTarget)
        }
        .accessibilityElement(children: .contain)
    }

    /// Toggle one row's selection (mergeable rows only).
    private func toggleSelection(_ row: WorkoutRow) {
        let key = selectionKey(row)
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    /// Start a merge: if the chosen rows carry a real sport, merge straight away; if every one is a bare
    /// detected bout, prompt the user to name the merged session first.
    private func beginMerge(_ chosen: [WorkoutRow]) {
        guard WorkoutMerge.canMerge(chosen) else { return }
        if WorkoutMerge.resolvedSport(chosen) == nil {
            mergeSportPrompt = MergeSportTarget(rows: chosen)
        } else {
            performMerge(chosen, sport: nil)
        }
    }

    /// Commit a merge through the repository (manual-row path), then rescore + reload. Leaves selection
    /// mode. Imported rows can never reach here (canMerge gates on manual/detected).
    private func performMerge(_ chosen: [WorkoutRow], sport: String?) {
        guard let merged = WorkoutMerge.merge(chosen, sport: sport) else { return }
        selectionMode = false; selected.removeAll(); mergeSportPrompt = nil
        Task {
            await repo.mergeWorkouts(chosen, into: merged)
            await intelligence.analyzeRecent()
            await reload()
        }
    }

    // MARK: - Filters

    /// Sport and source filters in one toolbar menu; the page says when one is narrowing it.
    private var filterMenu: some View {
        Menu {
            Picker(String(localized: "Sport"), selection: $sportFilter) {
                Text(String(localized: "All sports")).tag(String?.none)
                ForEach(availableSports, id: \.self) { s in Text(s).tag(String?.some(s)) }
            }
            .pickerStyle(.menu)
            Picker(String(localized: "Source"), selection: $sourceFilter) {
                Text(String(localized: "All sources")).tag(WorkoutSource?.none)
                ForEach(Self.sourceFilterOptions, id: \.self) { opt in
                    Text(Self.sourceFilterLabel(opt)).tag(WorkoutSource?.some(opt))
                }
            }
            .pickerStyle(.menu)
            if filter.isActive {
                Button(String(localized: "Clear filters")) { clearFilters() }
            }
        } label: {
            Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill"
                                              : "line.3.horizontal.decrease.circle")
                .font(StrandFont.icon(.row))
                .foregroundStyle(StrandPalette.accent)
        }
        .accessibilityLabel(Text("Filter"))
        .accessibilityValue(filter.isActive ? filterSummary : String(localized: "All sports"))
    }

    private var filterNotice: some View {
        InlineNotice(filterSummary, tone: .neutral, action: InlineNotice.Action("Clear") { clearFilters() })
    }

    /// "Swimming · Apple", the active filters in words.
    private var filterSummary: String {
        [sportFilter, sourceFilter.map(Self.sourceFilterLabel)].compactMap { $0 }.joined(separator: " · ")
    }

    private func clearFilters() {
        withAnimation(.easeOut(duration: 0.15)) { sportFilter = nil; sourceFilter = nil }
    }

    /// The origin classes offered in the Source filter (imported + on-device), in a stable menu order.
    private static let sourceFilterOptions: [WorkoutSource] =
        [.whoop, .apple, .detected, .manual, .lifting, .activityFile]

    /// The Source-filter menu label for an origin class.
    private static func sourceFilterLabel(_ c: WorkoutSource) -> String {
        switch c {
        case .whoop:        return String(localized: "Whoop")
        case .apple:        return String(localized: "Apple")
        case .detected:     return String(localized: "Detected")
        case .manual:       return String(localized: "Manual")
        case .lifting:      return String(localized: "Lifting")
        case .activityFile: return String(localized: "File")
        }
    }

    /// The set of displayed-sport names present across ALL loaded rows, for the sport-filter menu.
    /// Ordered by frequency (desc) so the common sports sit at the top.
    private var availableSports: [String] {
        var counts: [String: Int] = [:]
        for r in allRows { counts[WorkoutSource.displaySport(r.sport), default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// The active filter (#64), composed once. Sport / source apply AFTER the window cut, so the readout,
    /// chart, statistics and list all read one filtered set.
    private var filter: WorkoutFilter {
        WorkoutFilter(sport: sportFilter, sourceClass: sourceFilter, search: "")
    }

    // MARK: - Actions

    /// Opens the add sheet (editing == nil). Present on the populated screen and the empty state so a
    /// user with no imports can still log a session.
    private var addWorkoutButton: some View {
        NoopButton("Add workout", systemImage: "plus", kind: .secondary, fullWidth: true) {
            sheet = WorkoutSheetTarget(editing: nil)
        }
        .accessibilityLabel("Add a workout")
    }

    /// Equal-width primary actions share the same content width as every card below them.
    /// #459 / PERF: the live-workout button is `WorkoutStartControl`, a leaf that owns `AppModel` itself
    /// so this screen doesn't have to — see the comment on `profile`/`intelligence` above.
    private var workoutActionRow: some View {
        HStack(spacing: NoopMetrics.gap) {
            WorkoutStartControl()
                .frame(maxWidth: .infinity)
            addWorkoutButton
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    /// Re-read every source after a mutation so the screen reflects the new state immediately.
    /// Keeps the user's current range — only the initial load picks a default.
    private func reload() async {
        allRows = await repo.workoutRows(days: loadedWindowDays ?? 4000)
    }

    private func editWorkout(_ row: WorkoutRow, isCopy: Bool = false) {
        sheet = WorkoutSheetTarget(editing: row, isCopy: isCopy)
    }

    private func relabel(_ row: WorkoutRow, to sport: String) {
        Task {
            await repo.relabelDetected(row, sport: sport)
            await reload()
            await showPostLogNote(forSport: WorkoutSource.displaySport(sport))
        }
    }

    private func dismiss(_ row: WorkoutRow) {
        Task { await repo.dismissDetected(row); await reload() }
    }

    private func delete(_ row: WorkoutRow) {
        // #524: also drop any on-device GPS route stored under this session's natural key, so deleting a
        // workout doesn't leave its route orphaned in the RouteStore side-store.
        RouteStore.remove(startTs: row.startTs, sport: row.sport)
        Task { await repo.deleteWorkout(row); await reload() }
    }

    /// Common sports offered when re-labelling a detected bout (keeps the menu short and honest —
    /// the user can fine-tune via Edit afterwards).
    private static let relabelSports = ["Running", "Walking", "Cycling", "Strength Training",
                                        "Swimming", "Rowing", "Yoga", "HIIT",
                                        "CrossFit", "Hiking", "Tennis"]

    /// Row actions. A grandfathered DETECTED bout can be re-labelled as a real manual session or
    /// dismissed with its legacy marker retained. A MANUAL session can be edited or deleted. Imported
    /// WHOOP / Apple rows are read-only (we never rewrite imported history).
    @ViewBuilder
    private func rowMenu(_ row: WorkoutRow) -> some View {
        switch WorkoutSource.classify(row.source) {
        case .detected:
            Menu("Re-label as") {
                ForEach(Self.relabelSports, id: \.self) { sport in
                    Button(sport) { relabel(row, to: sport) }
                }
            }
            Button("Edit details…") { editWorkout(row) }
            Divider()
            Button("Dismiss (not a workout)", role: .destructive) { dismiss(row) }
        case .manual:
            Button("Edit…") { editWorkout(row) }
            Divider()
            Button("Delete", role: .destructive) { delete(row) }
        case .whoop, .apple, .lifting, .activityFile:
            // Imported history is read-only; offer a copy-to-manual edit path that doesn't touch it.
            Button("Duplicate as manual…") { editWorkout(asManualCopy(row), isCopy: true) }
        }
    }

    /// A manual-source copy of an imported row, so "Duplicate as manual" opens the add sheet pre-filled
    /// without ever mutating the imported original (the sheet saves under the strap source).
    private func asManualCopy(_ row: WorkoutRow) -> WorkoutRow {
        WorkoutRow(startTs: row.startTs, endTs: row.endTs, sport: WorkoutSource.displaySport(row.sport),
                   source: "manual", durationS: row.durationS, energyKcal: row.energyKcal,
                   avgHr: row.avgHr, maxHr: row.maxHr, strain: row.strain, distanceM: row.distanceM,
                   zonesJSON: row.zonesJSON, notes: row.notes, steps: row.steps)
    }

    // MARK: - Post-log activity-cost note (#439)

    /// After a manual save / relabel, look up whether `sport` has a solid/building ActivityCost entry
    /// (n ≥ minSessions) and, if so, show its plain-English sentence as a transient caption that
    /// auto-clears. Copy is "usually"/"personal pattern" framed (the engine's own wording) — never a
    /// law. Computes off the freshly reloaded sessions + the merged daily Charge.
    private func showPostLogNote(forSport sport: String) async {
        let costs = InsightsView.computeActivityCosts(workouts: allRows, days: repo.days)
        guard let match = costs.first(where: { $0.sport == sport }) else {
            await MainActor.run { postLogNote = nil }
            return
        }
        let sentence = match.sentence()
        await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { postLogNote = sentence } }
        // Auto-dismiss after a few seconds (transient caption, not a permanent card).
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        await MainActor.run {
            if postLogNote == sentence { withAnimation(.easeOut(duration: 0.2)) { postLogNote = nil } }
        }
    }

    // MARK: - Heart-rate recovery trend (#516)

    /// Apply the screen's 90-day cap to the already-`sessions(for:)`-filtered `unscopedRows` `body`
    /// computes once. PERF: this used to re-derive `sessions(for:)` from scratch (the SAME unscoped
    /// filter `body` already ran), so a body pass filtered `allRows` twice. Reusing the caller's rows
    /// removes the second pass.
    private func recoveryTrendRows(from unscopedRows: [WorkoutRow]) -> [WorkoutRow] {
        guard let last = latestTs else { return [] }
        let cutoff = last - 90 * 86_400
        return unscopedRows.filter { $0.startTs >= cutoff }.sorted { $0.startTs < $1.startTs }
    }

    /// Stable task identity: changing the range/filter/rows or HRmax cancels and rebuilds the trend.
    private func recoveryTrendInputKey(rows: [WorkoutRow]) -> String {
        // `loaded` is part of the identity so the pass that runs on the real rows is the one that counts
        // (`recoveryLoaded`), not the first one over the still-empty list.
        "\(repo.refreshSeq)|\(profile.hrMax)|\(loaded)|" + rows.map { "\($0.startTs):\($0.endTs)" }.joined(separator: ",")
    }

    private func loadRecoveryTrend(rows: [WorkoutRow]) async {
        guard !usesPreviewRows else { recoveryTrend = []; recoveryLoaded = true; return }
        var built: [WorkoutRecoveryTrendPoint] = []
        for row in rows {
            if Task.isCancelled { return }
            if let result = await repo.workoutHeartRateRecovery(
                from: row.startTs, to: row.endTs, maxHR: Double(profile.hrMax),
                source: row.source) {
                built.append(WorkoutRecoveryTrendPoint(startTs: row.startTs, result: result))
            }
        }
        guard !Task.isCancelled else { return }
        recoveryTrend = built
        if loaded { recoveryLoaded = true }
        #if DEBUG
        if DemoPage.requested == .recovery, recoveryLoaded, demoOpen == nil { demoOpen = .recovery }
        #endif
    }

    /// #797: page the FULL workout history in when the user selects a range wider than the bounded
    /// first-paint window. Idempotent: once expanded (`loadedWindowDays == nil`) it never re-reads here.
    /// Only a pick of `.all` (or a future range exceeding the loaded window) triggers the one-time full
    /// read, so the common W/M/3M/Y interactions stay on the already-loaded bounded set.
    private func expandWindowIfNeeded(for picked: ChartRange) async {
        guard !usesPreviewRows, loadedWindowDays != nil else { return }
        // A bounded range that fits inside what's already loaded needs no wider read.
        if let pickedDays = picked.days, pickedDays <= (loadedWindowDays ?? 0) { return }
        loadedWindowDays = nil
        allRows = await repo.workoutRows(days: 4000)
    }

    // MARK: - Range model

    /// The latest session start.
    private var latestTs: Int? { allRows.map(\.startTs).max() }
    /// The oldest loaded session start (decides which ranges the history fills).
    private var oldestTs: Int? { allRows.map(\.startTs).min() }

    /// Sessions inside a range ending today, then passed through the active filter. `.all` = all loaded.
    ///
    /// Deliberately NOT scoped to the newest ten: this feeds the HR-recovery trend (a 90-day analysis), the
    /// chart and the statistics as well as the list, and cutting those to the ten most recent sessions
    /// would quietly change what they measure. The newest-ten cut is applied to the LIST rows only.
    private func sessions(for r: ChartRange) -> [WorkoutRow] {
        let windowed: [WorkoutRow]
        if r == .all {
            windowed = allRows
        } else {
            windowed = WorkoutTraining.rows(allRows, in: WorkoutTraining.window(r, rows: allRows))
        }
        return filter.apply(windowed)
    }

    /// Pick the tightest range that holds ≥2 sessions; otherwise show All.
    private func defaultRange(for source: [WorkoutRow]) -> ChartRange {
        for r in [ChartRange.week, .month, .quarter, .year] {
            if WorkoutTraining.rows(source, in: WorkoutTraining.window(r, rows: source)).count >= 2 { return r }
        }
        return .all
    }

    // MARK: - The newest-ten split

    /// The most recent sessions (the list's first view) or everything older. A VIEW split, never a delete:
    /// older rows stay in the database and are one tap away ("Show all"), which is how the request for
    /// "keep the last 10 and auto-delete the rest" is answered: NOOP has no server and no cloud copy, so
    /// pruning real training history would be irreversible, and hiding it costs nothing.
    enum Scope: String, CaseIterable, Identifiable {
        case current, archived
        var id: String { rawValue }
        /// `LocalizedStringKey` rather than `String`, because this is only ever handed to `Text`.
        var label: LocalizedStringKey { self == .current ? "Current" : "Archived" }
    }

    /// How many of the most recent sessions "Current" holds.
    static let currentScopeCount = 10

    /// Split rows into the most recent `currentCount` and everything older.
    ///
    /// Pure and order-preserving: membership is decided by ranking on `startTs`, but the rows come back in
    /// the order they arrived, so the caller's sort still decides what the screen shows. Ranking rather
    /// than comparing against a cutoff timestamp is what makes ties safe: two sessions that start in the
    /// same second cannot both sneak past a threshold and hand "Current" an eleventh row.
    ///
    /// Applied AFTER the range and sport filters, so it means "the 10 most recent of what you are
    /// currently looking at".
    nonisolated static func scopedRows(_ rows: [WorkoutRow], scope: Scope,
                                       currentCount: Int = currentScopeCount) -> [WorkoutRow] {
        guard rows.count > currentCount else { return scope == .current ? rows : [] }
        let key: (WorkoutRow) -> String = { "\($0.startTs)|\($0.sport)" }
        let newest = Set(rows.sorted { $0.startTs > $1.startTs }.prefix(currentCount).map(key))
        return rows.filter { scope == .current ? newest.contains(key($0)) : !newest.contains(key($0)) }
    }

    /// #796 - the per-session Effort label: the stored 0-100 strain mapped to the user's Effort scale
    /// (the SAME `UnitFormatter.effortDisplay` every other Effort read-out routes through, so the toggle and
    /// rounding stay consistent), or "–" when the session has no captured strain. Pure + unit-testable.
    static func effortCellLabel(strain: Double?, scale: EffortScale) -> String {
        guard let strain else { return "–" }
        return UnitFormatter.effortDisplay(strain, scale: scale)
    }

    // MARK: - DEBUG screenshot hooks

    #if DEBUG
    enum DemoPage: String {
        case detail, sport, zones, recovery, calories
        static var requested: DemoPage? {
            DemoLaunch.stringArg("--demo-workout-open").flatMap(DemoPage.init(rawValue:))
        }
    }

    @ViewBuilder
    private func demoDestination(rows: [WorkoutRow]) -> some View {
        switch demoOpen {
        case .detail:
            // The newest finished session the demo seeded heart rate for (it seeds the newest few).
            let now = Int(Date().timeIntervalSince1970)
            if let row = rows.first(where: { $0.avgHr != nil && $0.endTs + 360 < now }) ?? rows.first {
                WorkoutDetailView(row: row, presentation: .pushed)
            }
        case .sport:
            if let g = WorkoutSports.groups(rows).first {
                WorkoutSportView(sport: g.sport, rows: allRows.filter { $0.sport == g.sport }, initialRange: .quarter)
            }
        case .zones: WorkoutZonesView(rows: allRows, initialRange: .quarter)
        case .recovery: WorkoutRecoveryView(points: recoveryTrend, rows: allRows)
        case .calories: WorkoutActiveCaloriesView(dailyKcal: dailyKcal)
        case nil: EmptyView()
        }
    }
    #endif
}

#if DEBUG
@MainActor
private func previewWorkoutRows() -> [WorkoutRow] {
    let now = Int(Date().timeIntervalSince1970)
    let day = 86_400
    return [
        WorkoutRow(startTs: now - day * 0 - 3600, endTs: now - day * 0,
                   sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
                   avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
                   zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil, steps: nil),
        WorkoutRow(startTs: now - day * 1 - 2700, endTs: now - day * 1,
                   sport: "Strength Training", source: "whoop", durationS: 2700, energyKcal: 388,
                   avgHr: 118, maxHr: 156, strain: 9.4, distanceM: nil,
                   zonesJSON: nil, notes: nil, steps: nil),
        WorkoutRow(startTs: now - day * 2 - 1800, endTs: now - day * 2,
                   sport: "Cycling", source: "apple_health", durationS: 1800, energyKcal: 240,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: 12_800,
                   zonesJSON: nil, notes: nil, steps: nil),
        WorkoutRow(startTs: now - day * 4 - 3300, endTs: now - day * 4,
                   sport: "Cycling", source: "whoop", durationS: 3300, energyKcal: 540,
                   avgHr: 134, maxHr: 162, strain: 11.8, distanceM: 24_600,
                   // Android key shape on purpose — exercises the cross-platform parser.
                   zonesJSON: #"{"zone1":20.0,"zone2":35.0,"zone3":30.0,"zone4":10.0}"#, notes: nil, steps: nil),
    ]
}

#Preview("Workouts") {
    let repo = Repository(deviceId: "preview")
    return NavigationStack {
        WorkoutsView(previewRows: previewWorkoutRows())
    }
    .environmentObject(repo)
    .environmentObject(ProfileStore())
    .environmentObject(AppModel())
    .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
}
#endif
