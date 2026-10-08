import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SleepView
//
// The Sleep tab: a glance at one night, then the trends behind it.
//
//   1. Status: the night's freshness (syncing / calculating / not detected), only while it applies.
//   2. Night stepper: "‹ Last night · Mon 6 – Tue 7 Oct ›".
//   3. Night summary: the Rest ring, the state word, asleep against the need, the in-bed window and
//      efficiency. Opens the night page (`TabRoute.sleepNight`), where the times, naps, edits, caveats
//      and every per-night detail live.
//   4. Stages: the filled stepped hypnogram with one legend row (tap a stage to highlight it) and at most
//      one caveat badge.
//   5. Naps, when the day has any.
//   6. Trends: sleep debt, consistency, restorative share and respiratory rate, each opening its own
//      metric page.
//   7. Asleep: the last 14 nights against the sleep need, opening the asleep-time page.
//
// `SleepView` also stays the namespace for the pure sleep rules other screens and tests use
// (`mainNightGroup`, `stubDaySession`, `decodeSegments`, `isStagingLowConfidence`, ...): names and
// signatures unchanged.

struct SleepView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject private var router: NavRouter
    // NOTE: SleepView itself deliberately does NOT observe `LiveState` OR `AppModel`. A connected strap
    // publishes at ~1 Hz, and `AppModel` itself publishes `bpm` at that same ~1 Hz (AppModel.swift:202) —
    // `@EnvironmentObject` subscribes to the WHOLE object's `objectWillChange` regardless of which
    // properties are read, so holding either here would re-evaluate this body on every tick. The live
    // dependencies (the freshness note, the body-clock dial on the night page) each own their OWN
    // `@EnvironmentObject var live`/`appModel` in a small leaf (mirrors the Today leaf-scoping pattern and
    // HealthView.swift:17-22), so a tick refreshes only that leaf.
    @EnvironmentObject var intelligence: IntelligenceEngine

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals resolved once, the
    /// seven metric series, the trend points, the typical means). Rebuilt only when the underlying repo data
    /// actually changes — NOT on taps or 1 Hz ticks that merely re-evaluate `body`. `nil` until first build
    /// or when there's no night.
    @State private var model: SleepModel?
    /// The repo signature the cached `model` was built from. Cheap to compute every render; when it differs
    /// from the current inputs we rebuild the model.
    @State private var modelKey: SleepInputKey?
    @State private var loadedSleepRefresh: Int?
    @State private var resultTracker = SleepResultChangeTracker()
    @State private var resultNoticeVisible = false
    @State private var resultNoticeRevision = 0
    @State private var resultNoticeScope: String?

    /// The browsed night by its local WAKE DAY; nil = the newest night. A wake day survives a reload, where
    /// an index would silently point at a different night once a newer one lands (#160), so a sync no
    /// longer drops the reader back to last night.
    @State private var selectedWakeDay: String?
    /// Which night the page shows: 0 = the newest, N = N recorded days back. Re-resolved from
    /// `selectedWakeDay` whenever the data reloads.
    @State private var nightOffset = 0
    /// Memoized decode of the BROWSED night (nil when `nightOffset == 0`, which reads `model.night`).
    /// Rebuilt only when the browsed night or the data changes; `decodedNight` JSON-decodes, which must
    /// never run per body pass. (#160)
    @State private var navNight: Night?

    /// Every sleep BLOCK across both sources, UN-deduplicated (`repo.allSleepSessions`) — `repo.sleeps`
    /// keeps one winner per night for the dashboard, collapsing split-sleep days (a nap + a main sleep on
    /// the same day) into a single block. The page groups these by day (`navDays`) and merges each day into
    /// one Night, so a split day reads as one correctly-totalled night with the gaps preserved.
    /// Oldest→newest. Falls back to `repo.sleeps` until loaded. (#170)
    @State private var allSessions: [CachedSleepSession] = []
    /// `navDays` memoized, rebuilt where `model` is (a per-render regroup is a pass over every block ever
    /// recorded). Nil falls back to computing it, so a first render before either has run is correct.
    @State private var navDaysCache: [[CachedSleepSession]]?

    /// The user's LEARNED habitual midsleep (local time-of-day seconds), or nil under the cold-start
    /// threshold. Loaded from `repo.habitualMidsleepSec()` — the SAME value `AnalyticsEngine.analyzeDay`
    /// threads into the daily total — and fed into the main-night selector so the page, the naps split,
    /// and the edit target pick the SAME block the analytics rollup did. (#547) Refreshed with `allSessions`.
    @State private var habitualMidsleepSec: Int? = nil

    /// Persisted per-epoch MOTION series keyed by each session's detected `startTs` (#407), loaded in the
    /// same `.task` as `allSessions` from `repo.sessionMotions(sessions:)`. Refreshed with `allSessions`.
    @State private var motionByStart: [Int: [Double]] = [:]

    /// The stage highlighted from the legend (tap again to clear). Display-only. (ryanAtriumAi #988)
    @State private var highlightedStage: SleepStage? = nil

    var body: some View {
        // Resolve the memoized model for THIS render. `dataKey` is O(1)-ish (counts + last-row identity),
        // so comparing it every render is cheap. When it matches the cached key we reuse the cached model;
        // when it differs (or on first render) we build once, here, synchronously, so the very first frame
        // already shows content (no empty-state flash).
        let key = dataKey
        let resolved: SleepModel? = (key == modelKey) ? model : buildModel()
        ScreenScaffold(title: "Sleep",
                       // Redacted until the repository's first load lands: the sleep blocks can arrive before
                       // the day rows, and a score or efficiency read off half the data would change under the
                       // reader a moment later.
                       isLoading: !repo.loaded,
                       onRefresh: { await repo.refresh() },
                       trailing: { alarmButton }) {
            // The one status slot: the night's freshness, only while it applies. The transient notices
            // (the result-changed note; the undo after a delete, on the night page) are overlays instead,
            // so nothing pushes the page down when they come and go.
            SleepFreshnessNote(latestWakeTs: resolved?.night.session.endTs)
            if let resolved {
                content(resolved)
            } else if repo.loaded {
                emptyState
            } else {
                loadingLayout
            }
        }
        .overlay(alignment: .bottom) {
            if resultNoticeVisible {
                SleepToast(message: String(localized: "Sleep result updated"))
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                    .padding(.bottom, NoopMetrics.tabBarClearance)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: resultNoticeVisible)
        // Persist the freshly-built model so subsequent renders with the same inputs hit the cache. Writing
        // State during body is not allowed, so commit it after layout; `resolved` already drives THIS frame,
        // so there is no flash and no extra rebuild.
        .onChangeCompat(of: key) { newKey in
            modelKey = newKey
            navDaysCache = SleepModel.navDays(navSessions: navSessions)
            model = buildModel()
            reresolveBrowsedNight()
        }
        .onAppear {
            if modelKey != key {
                modelKey = key
                model = resolved
                reresolveBrowsedNight()
            }
        }
        .onChangeCompat(of: intelligence.computing) { _ in observeResultChange() }
        .onDisappear { resetResultNotice() }
        .task(id: resultNoticeRevision) {
            guard resultNoticeVisible else { return }
            do { try await Task.sleep(nanoseconds: 8_000_000_000) }
            catch { return }
            resultNoticeVisible = false
        }
        // Load EVERY sleep block across BOTH sources (un-deduplicated) so the stepper can browse split-sleep
        // days the dashboard collapses — including Bluetooth-only nights, whose blocks live under the
        // computed source. Re-runs whenever a sync/import bumps refreshSeq, then rebuilds the model. (#170)
        .task(id: repo.refreshSeq) {
            let refresh = repo.refreshSeq
            let sessions = await repo.allSleepSessions()
            // Load the learned habitual midsleep the engine used, so the main-night pick aligns to it
            // (a shift/late sleeper) instead of only the cold-start band. nil under threshold. (#547)
            let habitual = await repo.habitualMidsleepSec()
            // Per-epoch motion for every block (#407), keyed by detected start. mergeDay reads only the
            // already-resolved group's entries — this just pre-fetches them all so the model build is sync.
            let motions = await repo.sessionMotions(sessions: sessions)
            guard !Task.isCancelled, refresh == repo.refreshSeq else { return }
            allSessions = sessions
            habitualMidsleepSec = habitual
            motionByStart = motions
            // The night page opened from here reads this result instead of loading it all again.
            SleepSessionsCache.shared.record(SleepSessionsCache.Snapshot(
                refreshSeq: refresh, deviceId: repo.deviceId, sessions: sessions,
                habitualMidsleepSec: habitual, motionByStart: motions))
            modelKey = dataKey
            navDaysCache = SleepModel.navDays(navSessions: navSessions)
            model = buildModel()
            reresolveBrowsedNight()
            loadedSleepRefresh = refresh
            observeResultChange()
        }
        .onChangeCompat(of: nightOffset) { _ in
            highlightedStage = nil
            resetResultNotice()
            observeResultChange()
        }
    }

    /// The one alarm screen, from the header (it is an action, not content).
    private var alarmButton: some View {
        Button { router.openAlarms() } label: {
            Image(systemName: "alarm")
                .font(StrandFont.icon(.row))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Alarms")
    }

    // MARK: - Page

    @ViewBuilder
    private func content(_ model: SleepModel) -> some View {
        let shown = displayedNight(model)
        nightStepper(shown.night)
        nightSummaryCard(shown.night, isStub: shown.isStub)
        stagesCard(shown.night, isStub: shown.isStub)
        napRows(shown.night)
        trendsSection(model)
        asleepSection(model)
    }

    /// The night on screen: the browsed night while browsing (the newest only until it has decoded), else
    /// the newest. A browsed day whose blocks decode to no usable stages is the honest stage-less stub,
    /// never the newest night under a browsed label. (#160, #940)
    private func displayedNight(_ model: SleepModel) -> (night: Night, isStub: Bool) {
        if nightOffset == 0 { return (model.night, model.isStubNight) }
        if let navNight { return (navNight, false) }
        if let session = sessionRow(at: nightOffset) {
            let stub = Night(session: session, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                             sourceBlocks: dayBlocks(at: nightOffset),
                             habitualMidsleepSec: habitualMidsleepSec)
            return (stub, true)
        }
        return (model.night, model.isStubNight)
    }

    // MARK: Night stepper

    private func nightStepper(_ night: Night) -> some View {
        let lastIndex = max(navDays.count - 1, 0)
        return PeriodStepper(title: SleepFormat.relativeNight(nightsAgo(nightOffset)),
                             subtitle: SleepFormat.nightDateLine(night.session.endTs),
                             canGoBack: nightOffset < lastIndex,
                             canGoForward: nightOffset > 0,
                             onBack: { browse(to: nightOffset + 1) },
                             onForward: { browse(to: nightOffset - 1) })
            .accessibilityElement(children: .contain)
    }

    /// Step to the night `offset` days back (0 = newest), remembering it by its wake day.
    private func browse(to offset: Int) {
        let days = navDays
        guard offset >= 0, offset < max(days.count, 1) else { return }
        selectedWakeDay = offset == 0 ? nil : days[offset].first.map { SleepFormat.wakeDayKey($0.endTs) }
        nightOffset = offset
        navNight = offset == 0 ? nil : decodedNight(at: offset)
    }

    /// After a reload, find the browsed night again by its wake day; if that day is gone, go to the newest.
    private func reresolveBrowsedNight() {
        guard let day = selectedWakeDay,
              let index = SleepModel.navIndex(wakeDay: day, navDays: navDays), index > 0 else {
            selectedWakeDay = nil
            nightOffset = 0
            navNight = nil
            return
        }
        nightOffset = index
        navNight = decodedNight(at: index)
    }

    /// #1311: how many nights back the night at `offset` is, counted in CALENDAR nights from today rather
    /// than carousel index (a night with no data is a gap the index can't see). Delegates to
    /// `SleepNightLabel.nightsAgo`, which is where this logic is tested. Kotlin twin: `calendarNightsAgo`.
    private func nightsAgo(_ offset: Int, now: Date = Date()) -> Int {
        SleepNightLabel.nightsAgo(
            // Optional per entry, NOT `?? 0`: a day group with no session must fall back to the offset
            // the way the Kotlin twin does. Zero would be 1970 and would read as ~20,000 nights ago.
            wakeTimestamps: navDays.map { $0.first.map { s in Int(s.endTs) } },
            offset: offset,
            today: Repository.logicalDay(now)
        )
    }

    // MARK: Night summary

    /// The sleep-performance score (0–100) for a SPECIFIC night: the imported WHOOP figure for that
    /// night's LOCAL wake-day when the export carried one, else the resolved Rest composite for that
    /// day. Mirrors `performanceSeries`'s per-day transform exactly (the same single source of truth
    /// the Today Rest score reads), keyed by the wake-day (sleep is filed under the day you woke) so
    /// a browsed past night reads ITS OWN score, never last night's. nil when that day has no score.
    private func performanceScore(for night: Night) -> Double? {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        if let p = repo.importedSleep[wakeDay]?.performancePct { return p }
        guard let daily = repo.days.last(where: { $0.day == wakeDay }) else { return nil }
        return AnalyticsEngine.Rest.composite(daily: daily)
    }

    /// The Rest ring, its state word, and the night's three facts. One card at one height whatever it holds
    /// (a night with no score keeps the ring with "—"), opening the night page.
    private func nightSummaryCard(_ night: Night, isStub: Bool) -> some View {
        let score = isStub ? nil : performanceScore(for: night)
        let need = model?.sleepDebtLedger.needMin
        let efficiency = isStub ? nil : SleepNightFacts.efficiencyPct(night, days: repo.days)
        return SleepRouteLink(route: .sleepNight(wakeDay: SleepFormat.wakeDayKey(night.session.endTs))) {
            NightSummaryLayout(
                score: score,
                asleep: isStub ? nil : SleepFormat.duration(night.stages.asleep),
                need: need.map { String(localized: "of \(SleepFormat.duration($0)) need") },
                window: SleepFormat.window(night.session.effectiveStartTs, night.session.endTs),
                efficiency: efficiency.map { "\(Int($0.rounded()))" })
        }
        .buttonStyle(StrandPressableButtonStyle())
        .accessibilityHint(Text("Opens this night"))
    }

    // MARK: Stages

    @ViewBuilder
    private func stagesCard(_ night: Night, isStub: Bool) -> some View {
        let hasTimeline = (night.realSegments?.count ?? 0) >= 2
        let caveats = isStub ? [] : SleepCaveat.applicable(to: night, todayEfficiency: repo.today?.efficiency,
                                                           isOura: repo.activeDeviceIsOura)
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Stages")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Group {
                    if !repo.loaded {
                        // The chart is a Canvas, so the scaffold's redaction cannot grey it. Until the first
                        // load lands, show the placeholder rather than stage colours read off half the data.
                        ChartPlaceholder(height: Self.compactChartHeight)
                    } else if hasTimeline {
                        NightTimelineChart(
                            timeline: NightTimeline(onset: night.onsetDate,
                                                    end: Date(timeIntervalSince1970: TimeInterval(night.session.endTs)),
                                                    intervals: night.intervals),
                            highlighted: highlightedStage,
                            stageHeight: Self.compactStageHeight)
                    } else if !isStub {
                        // An imported night carries stage TOTALS only: no timeline is drawn for it.
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Spacer(minLength: 0)
                            StageCompositionBar(stages: night.stages, highlighted: highlightedStage, height: 20)
                            Text("Stage totals only")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Spacer(minLength: 0)
                        }
                    } else {
                        EmptyChartMessage("No stage data recorded for this night.", height: Self.compactChartHeight)
                    }
                }
                .frame(height: Self.compactChartHeight)
                if !isStub {
                    StageLegendRow(stages: night.stages, highlighted: $highlightedStage)
                }
                if let first = caveats.first {
                    SleepRouteLink(route: .sleepNight(wakeDay: SleepFormat.wakeDayKey(night.session.endTs))) {
                        HStack(spacing: NoopMetrics.space2) {
                            SleepCaveatBadge(caveat: first)
                            if caveats.count > 1 {
                                Text("+\(caveats.count - 1)")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.icon(.inline))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: NoopMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens this night"))
                }
            }
        }
    }

    static let compactStageHeight: CGFloat = 104
    /// The compact chart's whole frame (stage lane + its clock axis), kept for every kind of night.
    static let compactChartHeight: CGFloat = compactStageHeight + NightTimelineChart.axisHeight + NoopMetrics.space1

    // MARK: Naps

    /// One row per nap when the day has any (they change the day's total); each opens the night page,
    /// where naps are edited and added. Only blocks OUTSIDE the bridged main-night group are naps
    /// (#508, #518, #555, #561).
    @ViewBuilder
    private func napRows(_ night: Night) -> some View {
        let groupStarts = night.mainGroupStarts
        let naps = night.sourceBlocks
            .filter { !groupStarts.contains($0.startTs) }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        if !naps.isEmpty {
            NoopListSection("Naps") {
                ForEach(naps, id: \.startTs) { nap in
                    SleepRouteLink(route: .sleepNight(wakeDay: SleepFormat.wakeDayKey(night.session.endTs))) {
                        NoopListRow(icon: "powersleep", iconColor: StrandPalette.restColor,
                                    title: LocalizedStringKey(stringLiteral: SleepFormat.window(nap.effectiveStartTs, nap.endTs)),
                                    value: SleepFormat.duration(Double(nap.endTs - nap.effectiveStartTs) / 60.0))
                    }
                    .buttonStyle(.plain)
                    if nap.startTs != naps.last?.startTs {
                        NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                    }
                }
            }
        }
    }

    // MARK: Trends

    private func trendsSection(_ model: SleepModel) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Trends")
            SleepTrendTiles(model: model)
        }
    }

    // MARK: Asleep

    private func asleepSection(_ model: SleepModel) -> some View {
        SleepRouteLink(route: .metricSourced(key: "sleep_total_min", source: "my-whoop")) {
            AsleepNightsCard(days: repo.days, needMin: model.sleepDebtLedger.needMin, state: .ready)
        }
        .buttonStyle(StrandPressableButtonStyle())
        .accessibilityHint(Text("Opens asleep time"))
    }

    // MARK: Empty / loading

    /// No night recorded: the summary card's frame with one line and the one way to get nights in.
    private var emptyState: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("No nights yet")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                SleepRouteLink(route: .dataSources) {
                    HStack {
                        Text("Data sources")
                            .font(StrandFont.subhead.weight(.medium))
                            .foregroundStyle(StrandPalette.accent)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.icon(.inline))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: NoopMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Before the first load: the real layout, redacted by the scaffold, at its final size.
    @ViewBuilder
    private var loadingLayout: some View {
        PeriodStepper(title: SleepFormat.relativeNight(0), subtitle: " ", canGoBack: false, canGoForward: false,
                      onBack: {}, onForward: {})
        NightSummaryLayout(score: nil, asleep: nil, need: nil, window: nil, efficiency: nil, isLoading: true)
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Stages").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                ChartPlaceholder(height: Self.compactChartHeight)
                StageLegendRow(stages: Stages(awake: 0, light: 0, deep: 0, rem: 0), highlighted: .constant(nil))
            }
        }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Trends")
            SleepTrendTiles(model: nil)
        }
        AsleepNightsCard(days: [], needMin: nil, state: .loading)
    }

    // MARK: - Result-change notice

    /// Compare only after the screen has loaded the refreshed blocks and scoring has settled.
    /// The observer lives on the screen, so a hidden notice cannot stop change observation.
    private func observeResultChange() {
        guard loadedSleepRefresh == repo.refreshSeq, !intelligence.computing else { return }
        guard let model else { resetResultNotice(); return }
        let snapshot = resultSnapshot(displayedNight(model).night)
        if resultNoticeScope != snapshot.scope { resultNoticeVisible = false }
        resultNoticeScope = snapshot.scope
        if resultTracker.observe(snapshot, ready: true) {
            resultNoticeVisible = true
            resultNoticeRevision += 1
        }
    }

    private func resetResultNotice() {
        resultTracker = SleepResultChangeTracker()
        resultNoticeVisible = false
        resultNoticeScope = nil
    }

    private func resultSnapshot(_ night: Night) -> SleepResultSnapshot {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(night.session.endTs)))
        let sources = Set(night.sourceBlocks.compactMap(\.deviceId)).sorted().joined(separator: ",")
        return SleepResultSnapshot(
            scope: "\(repo.deviceId):\(sources):\(day.timeIntervalSince1970)",
            onset: night.session.effectiveStartTs, wake: night.session.endTs,
            asleepMinutes: night.stages.asleep,
            edited: night.session.userEdited || night.sourceBlocks.contains { $0.userEdited })
    }

    // MARK: - Memoization plumbing

    /// A cheap fingerprint of the repo inputs this screen derives from. Recomputed every render but only
    /// contains counts + the identity of the newest/oldest rows, so equality is fast. When it changes we
    /// know `repo.days`/`repo.sleeps` actually changed and the memoized `model` must be rebuilt.
    private var dataKey: SleepInputKey {
        SleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last,
            refreshSeq: repo.refreshSeq)
    }

    /// Build every expensive derivation exactly once. Called only when `dataKey` changes. A thin wrapper:
    /// it snapshots the view's current state into `SleepModelInputs` and hands off to the pure
    /// `SleepModel.build(_:)` (SleepModel.swift), which the Today host also calls. Returns nil when there is
    /// no usable latest night (renders the empty state).
    private func buildModel() -> SleepModel? {
        SleepModel.build(SleepModelInputs(
            days: repo.days,
            sleeps: repo.sleeps,
            allSessions: allSessions,
            importedSleep: repo.importedSleep,
            habitualMidsleepSec: habitualMidsleepSec,
            motionByStart: motionByStart))
    }

    /// The browsable block list: every sleep session un-deduplicated (incl. same-day naps / split sleep).
    /// Falls back to `repo.sleeps` (one-per-night) until the fuller list loads. (#170)
    private var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    /// The browsable DAY list — a thin wrapper over the shared `SleepModel.navDays`. (#170)
    private var navDays: [[CachedSleepSession]] {
        navDaysCache ?? SleepModel.navDays(navSessions: navSessions)
    }

    /// The real stored blocks composing the day at `offset` (for the stage-less stub Night, so its edit
    /// affordance still targets a real row). Empty when out of range.
    private func dayBlocks(at offset: Int) -> [CachedSleepSession] {
        let days = navDays
        return offset >= 0 && offset < days.count ? days[offset] : []
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night), via the
    /// shared `SleepModel.decodedNight`, which JSON-decodes, so it only runs from the builder and the
    /// browse/reload handlers, never per render. (#160, #170)
    private func decodedNight(at offset: Int) -> Night? {
        SleepModel.decodedNight(at: offset, navDays: navDays,
                                habitualMidsleepSec: habitualMidsleepSec, motionByStart: motionByStart)
    }

    /// A synthetic session for the DAY `offset` stops back, spanning the MAIN block's window, for the
    /// honest no-stage-data night when the day's blocks don't decode to usable stages. (#160, #170, #518)
    private func sessionRow(at offset: Int) -> CachedSleepSession? {
        SleepView.stubDaySession(dayBlocks(at: offset), habitualMidsleepSec: habitualMidsleepSec)
    }
    // MARK: - Shared sleep rules (pure statics other screens and tests read)

    /// A unix second as a fractional local clock hour — the dial's only input beyond the phase estimate.
    static func localClockHour(_ ts: Int) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute],
                                                from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60.0
    }

    /// Pure #345 gate (unit-testable without a live view) — whether the "May be incomplete" caveat applies.
    /// Mirror EXACTLY in Kotlin.
    ///
    /// `stagingSparse` alone is NOT the question the note asks. It is a STAGING-MECHANISM verdict:
    /// `SleepStager.isGravitySparse` returns true when the gravity span is short against the HR span OR when
    /// the LARGEST inter-sample gap exceeds `maxGapMin`, and its own doc calls that second branch "the
    /// typical WHOOP 4.0 backfill (#28)" whose only consequence is to ENABLE `buildRuns`' HR-vouched bridge.
    /// So a single long motion dropout sets it on a night of ANY length, including a complete twelve-hour
    /// one, and the flag is raised precisely where the engine has already applied its own mitigation.
    ///
    /// The note's copy, though, claims something narrower and checkable: that the night "may be
    /// under-detected and the sleep total can read short". So require the total to actually read short. A
    /// night at or above the wearer's need cannot honestly be captioned as possibly reading short, whatever
    /// the motion trace looked like.
    ///
    /// A night that staged to NOTHING keeps the caveat: zero asleep is the strongest form of the collapse
    /// this note exists to explain, not an exemption from it.
    ///
    /// `needHours` is a parameter rather than a constant so a personalised need
    /// (`AnalyticsEngine.Rest.personalizedNeedHours`) can be threaded in later without moving the rule. It
    /// is computed per pass today and not persisted on the row a screen can reach, so the shared default
    /// stands in.
    static func stageSparseNoteApplies(stagingSparse: Bool,
                                       asleepMin: Double,
                                       needHours: Double = AnalyticsEngine.Rest.defaultNeedHours) -> Bool {
        guard stagingSparse else { return false }
        return asleepMin < needHours * 60.0
    }

    /// Pure H9 gate (unit-testable without a live view) — true when a night's staging is low-confidence:
    /// a high-efficiency night whose deep+REM share is below the restorative floor. Built on the engine's
    /// own `ScoreConfidence.rest(...)` so the UI flag and the persisted Rest confidence agree. `asleepMin`,
    /// `deepMin`, `remMin` are minutes; `efficiency` is asleep/in-bed in [0,1]. Returns false for an unstaged
    /// or zero-asleep night (no staging to doubt). Mirror EXACTLY in Kotlin. (#H9)
    static func isStagingLowConfidence(asleepMin: Double, deepMin: Double, remMin: Double,
                                       efficiency: Double) -> Bool {
        guard asleepMin > 0 else { return false }
        let restorativeMin = max(0, deepMin) + max(0, remMin)
        // An UNSTAGED night (no deep+REM at all) has no staging split to doubt — its base Rest
        // confidence already reads honestly as `.building` (NOT a downgrade), so it must never be
        // flagged. Only a night that DID stage some sleep can be a suspicious "high efficiency yet
        // implausibly little restorative" staging miss.
        guard restorativeMin > 0 else { return false }
        let tier = ScoreConfidence.rest(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: asleepMin * 60.0,
            restorativeSeconds: restorativeMin * 60.0,
            efficiency: efficiency)
        // The H9 overload only DOWNGRADES solid → building on the suspicious case; a genuinely
        // low-restorative-AND-low-efficiency night keeps its honest base tier and isn't flagged here.
        return tier == .building
            && (restorativeMin / asleepMin) < ScoreConfidence.restorativeLowConfidenceShare
            && efficiency >= ScoreConfidence.highEfficiencyThreshold
    }

    /// The device's current UTC offset (seconds east), evaluated once per pick. Feeds the selector's
    /// `offsetSec` so the timing test reads the user's clock via the SAME `offsetSec` math the engine
    /// uses (`SleepStageTotals.localSecOfDay`), instead of `Calendar.current.component(.hour:)` which was
    /// the duplicated, DST-fragile gate the audit flagged. (#547)
    static var tzOffsetSec: Int { TimeZone.current.secondsFromGMT() }

    /// The day's single WINNING main block — the durable-edit anchor (`editTarget`) and the one block whose
    /// learned-timing score won. Scores by learned timing on each block's EFFECTIVE onset (what the user
    /// sees) and returns the owning session. This is the BARE single-block pick (no gap-bridge), because the
    /// edit affordance writes against ONE real row so it must resolve to one block. The HERO display and the
    /// nap split do NOT use this alone: they use `mainNightGroup`, which bridges the winner's adjacent
    /// fragments (a wake gap shorter than `gapBridgeMaxMin`) into ONE night the way `AnalyticsEngine`
    /// does (#561), so a biphasic / briefly-interrupted night is shown as one continuous sleep instead of
    /// phantom naps (#555). `habitualMidsleepSec` is the SAME learned value the engine threads into the
    /// persisted totals (loaded via `repo.habitualMidsleepSec()`), so a shift/late sleeper's pick matches
    /// the analytics rollup; nil keeps the cold-start overnight-band bonus. (#525 / #547 / #561)
    static func mainNightSession(_ sessions: [CachedSleepSession],
                                 habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        SleepStageTotals.mainNightIndex(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec).map { sessions[$0] }
    }

    /// The day's MAIN-night GROUP — the winning block PLUS any adjacent fragments bridged into it (a wake
    /// gap shorter than `gapBridgeMaxMin`), so a briefly-interrupted / biphasic night reads as ONE
    /// continuous sleep exactly the way `AnalyticsEngine.analyzeDay` rolls it up for the daily total (#561).
    /// The hero aggregates this whole group and ONLY blocks outside it are naps. Without it the tab used the
    /// un-bridged single-block pick and rendered the bridged siblings as phantom naps (#555). A night with
    /// no bridgeable gap collapses to the single block `mainNightSession` picks, so the common case is byte-
    /// identical. Returns ascending by effective onset. (#561 / #555)
    static func mainNightGroup(_ sessions: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        guard let idx = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return [] }
        return idx.map { sessions[$0] }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Actual asleep minutes in blocks outside a day's canonical main-night group. The Repository's
    /// all-session union has already removed cross-namespace duplicates; this helper only applies the
    /// same main-vs-nap classification the hero uses and decodes persisted stages. A stage-less nap
    /// contributes nothing rather than substituting its in-bed window. Mirrors Android
    /// `napSleepMinutesByDay`.
    static func napSleepMinutes(_ sessions: [CachedSleepSession],
                                habitualMidsleepSec: Int? = nil) -> Double {
        let mainStarts = Set(mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
            .map { $0.startTs })
        return sessions
            .filter { !mainStarts.contains($0.startTs) }
            .reduce(0) { total, nap in
                total + decodedAsleepMinutes(nap.stagesJSON, effectiveStartTs: nap.effectiveStartTs)
            }
    }

    /// The day's main-night bridged SPAN (onset → wake), the same window `mainNightGroup` bridges into
    /// one continuous night. The ONE canonical bed/wake read every glance screen (Coupled, Today's HR
    /// band) should show — never a screen-local "freshest" or "longest single block" heuristic, which
    /// can silently disagree with each other and with the Sleep tab hero on a night stored as more than
    /// one block (#294). nil only when `sessions` has nothing bridgeable.
    static func mainNightSpan(_ sessions: [CachedSleepSession],
                              habitualMidsleepSec: Int? = nil) -> (start: Int, end: Int)? {
        let group = mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        guard let first = group.first, let last = group.last else { return nil }
        return (first.effectiveStartTs, last.endTs)
    }

    /// Soft nap-duration hint retained for callers/tests; the nap CLASSIFICATION is now purely "not the
    /// chosen main block" (see `isNap`), never an independent duration/onset test. (#518/#547)
    static let napMaxHours: Double = 3.0
    /// Classify a block as a nap: it's a nap exactly when it is NOT the day's chosen main block. Derived
    /// from the pick (never an independent onset/duration gate), so the label can't contradict the
    /// selection — the contradiction the audit flagged. The main block is never a nap. (#518/#547)
    static func isNap(_ s: CachedSleepSession, main: CachedSleepSession?) -> Bool {
        guard let main else { return false }
        return s.startTs != main.startTs
    }

    // `mergeDay` / `nightOnsetTs` / the fragment-level `isPreOnsetAwakeStub(_:)` moved to
    // SleepModel.swift (pure statics reused by the builder and the ◀/▶ nav). The pure rule statics and
    // tuning constants below stay here — they are the shared source of truth reused by tests and by
    // those moved helpers.

    /// Longest a leading block can be and still be treated as a spurious pre-sleep awake stub (lying in bed
    /// before sleep). Generous (a few hours) because the reporter's stub ran 21:41 → 00:27 — ~2h45m of
    /// pre-sleep awake — so a tight cap missed it (#736). The real guard against swallowing a genuine first
    /// sleep fragment is `preOnsetStubAsleepMaxMin`: a stub must be essentially SLEEPLESS, which a real sleep
    /// block never is. The cap only stops a pathological all-day awake block from being silently dropped.
    static let preOnsetStubMaxMin: Double = 240
    /// Most asleep minutes a fragment can carry and still count as a (sleepless) pre-onset awake stub. A real
    /// first sleep fragment of a biphasic night carries far more, so it's never mistaken for a stub. (#736)
    static let preOnsetStubAsleepMaxMin: Double = 3
    /// A leading pre-onset fragment carrying SOME sleep is still spurious when it is minor RELATIVE to the
    /// night's main block: its asleep minutes are below this fraction of the largest fragment's. A genuine
    /// biphasic first sleep is comparable to the main block (well above this) and is kept; only a small stray
    /// lead is dropped. Extends the essentially-sleepless `preOnsetStubAsleepMaxMin` rule (#736), which missed
    /// a lead carrying a few minutes more than 3. Mirrors Android PRE_ONSET_STUB_MINOR_FRAC. (#259)
    static let preOnsetStubMinorFrac: Double = 0.15

    /// Absolute floor (ASLEEP minutes) under the #259 relative "minor lead" test: a leading fragment that
    /// carries at least this much real sleep is a genuine first sleep — a real sleep episode — and is NEVER
    /// a spurious pre-onset lead, however large the main block is. Without it a long main sleep inflates the
    /// 15% relative bar (a 6h night → ~54 min) so a genuine ~34-min first sleep was swallowed and the shown
    /// bedtime jumped hours late, hiding the real onset the bridged night (and the Health write-back, #364)
    /// already spans. 20 min ≈ the shortest standalone sleep episode; below it a handful of asleep minutes
    /// beside a long night is a stray lead. Mirrors Android PRE_ONSET_STUB_MINOR_ASLEEP_FLOOR_MIN.
    /// (bridged-night headline: a real 2026-07-14 12:16 first sleep hidden behind the 1:29 main block)
    static let preOnsetStubMinorAsleepFloorMin: Double = 20

    /// Pure stub test on a fragment's span + asleep minutes, so the rule is unit-testable without decoding
    /// JSON or building a view. Spurious when BRIEF and EITHER essentially sleepless OR minor relative to the
    /// main block (`refAsleepMin`, the group's largest asleep span): asleep below `preOnsetStubMinorFrac` of
    /// it AND below the absolute `preOnsetStubMinorAsleepFloorMin` real-sleep-episode floor. `refAsleepMin`
    /// defaults to 0 (relative test off) so existing callers/tests are byte-identical. (#736 / #259)
    static func isPreOnsetAwakeStub(spanMin: Double, asleepMin: Double, refAsleepMin: Double = 0) -> Bool {
        guard spanMin <= preOnsetStubMaxMin else { return false }
        if asleepMin <= preOnsetStubAsleepMaxMin { return true }
        // #259 relative "minor lead" test, floored: a real sleep episode (>= the floor) is never a stray
        // lead, so a long main block can't inflate the 15% bar past a genuine short first sleep.
        return refAsleepMin > 0
            && asleepMin < preOnsetStubMinorFrac * refAsleepMin
            && asleepMin < preOnsetStubMinorAsleepFloorMin
    }

    /// The index into an ascending-by-onset group whose fragment supplies the DISPLAYED bedtime: the first
    /// fragment that is NOT a spurious leading pre-onset awake stub, falling back to 0 when every fragment is
    /// stub-like. Pure mirror of `nightOnsetTs`'s walk, driven by per-fragment (spanMin, asleepMin) so a
    /// golden test can pin the #736 behaviour without view internals. (#736)
    static func nightOnsetIndex(spansMin: [Double], asleepsMin: [Double]) -> Int {
        let refAsleepMin = asleepsMin.max() ?? 0
        for i in spansMin.indices {
            let asleep = i < asleepsMin.count ? asleepsMin[i] : 0
            if !isPreOnsetAwakeStub(spanMin: spansMin[i], asleepMin: asleep, refAsleepMin: refAsleepMin) { return i }
        }
        return 0
    }

    /// The stage-less stub SESSION for a day whose blocks decode to no usable sleep: the MAIN
    /// block's effective window (the same pick `sessionRow` always made), falling back to the day's
    /// first block so a day with ANY stored block renders a header. Static and pure so the #940
    /// no-blank rule is unit-testable without view internals (SleepPhantomNightFallbackTests): as
    /// long as a day has a block, the tab has something honest to show and `buildModel` never
    /// collapses the whole screen to the first-run empty state. nil only for an empty day.
    static func stubDaySession(_ blocks: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        guard let main = mainNightSession(blocks, habitualMidsleepSec: habitualMidsleepSec) ?? blocks.first
        else { return nil }
        return CachedSleepSession(startTs: main.effectiveStartTs, endTs: main.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    // MARK: - Stage decoding

    /// Asleep minutes decoded from a stored `stagesJSON` in EITHER of the two formats that exist in the
    /// DB: on-device COMPUTED nights store a SEGMENT ARRAY `[{"start":epoch,"end":epoch,"stage":…}]`
    /// (`AnalyticsEngine.encodeStages`); imported nights store a dict of MINUTES
    /// `{"light","deep","rem","awake"}`. The displayed-onset stub test (`nightOnsetTs` /
    /// `isPreOnsetAwakeStub`) MUST read asleep minutes format-agnostically: it previously used the
    /// dict-only `decodeStages`, which returns nil for a computed night's segment array, so every
    /// fragment of an on-device night read as 0 asleep minutes — a real ~54-min first sleep tripped the
    /// "essentially sleepless stub" branch and the shown bedtime jumped from the true 12:16 onset to the
    /// 1:29 main block, bypassing the #259 real-sleep-episode floor entirely (the 2026-07-14 night).
    /// `effectiveStartTs` threads the fragment's effective onset into the segment decode's #259
    /// pre-onset trim. Internal (not private) so the golden test pins the DECODE PATH itself, not a
    /// pre-computed minute count. Android twin: SleepScreen's onset stub-test caller needs the same
    /// both-format decode.
    static func decodedAsleepMinutes(_ json: String?, effectiveStartTs: Int) -> Double {
        decodeStages(json)?.asleep
            ?? decodeSegments(json, sessionStart: effectiveStartTs)?.stages.asleep
            ?? 0
    }

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    /// Internal (not private) so `SleepModel.mergeDay` (SleepModel.swift) can call it.
    static func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let s = Stages(awake: val("awake"), light: val("light"),
                       deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|
    /// "light"|"deep"|"rem"}] into stage totals plus the real timeline (seconds relative to the
    /// session start, the Hypnogram's domain). The on-device SleepStager calls awake "wake". (#77)
    /// Internal (not private) so `SleepModel.mergeDay` (SleepModel.swift) can call it.
    static func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let rawStart = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue,
                  let name = seg["stage"] as? String else { continue }
            // #259: trim each segment to the effective onset (`sessionStart`) so a hand-edited bedtime the
            // raw was too sparse to re-stage (WHOOP 4.0) can't sum pre-onset stages past time-in-bed — nor
            // draw bars before the onset. No-op when segments already start at/after it (the common case).
            let start = max(rawStart, sessionStart)
            guard end > start else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(
                stage: stage,
                start: TimeInterval(start - sessionStart),
                end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
    }
}

// MARK: - Live-observing leaf subviews (scroll-stutter isolation)
//
// SleepView itself does NOT observe `LiveState` (a connected strap publishes at ~1 Hz, which would
// re-evaluate the heavy Sleep body on every tick). These two small leaves each hold their OWN
// `@EnvironmentObject var live`, so a live tick re-renders only the mark card / syncing note — never
// the hero hypnogram, the stage chart, the metric grid or the trends. They render byte-for-byte what
// the inline code did before the extraction (mirrors the Today leaf-scoping pattern).

/// The "going to sleep / I'm awake" sleep-mark card (#461, Phase 1). Tapping logs a timestamped mark —
/// persisted to the `sleep_mark` metric series AND appended to the shareable strap log — then confirms
/// with a haptic and a transient line. LOGGING ONLY: a mark never touches the sleep detector or the
/// night boundaries. Owns `live` (it appends to the strap log) + `repo` (the metric-series write) and
/// the `lastMark` confirmation state, so its strap-log write keeps working without SleepView observing.
/// The "Sleep marks" tap-to-log card. Lives in the Sleep tab but is also hostable in Today
/// (#today-hosted-cards), so it is `internal` (not `private`) and self-contained — it reads only the
/// shared `repo`/`live` environment objects, both present on Today too.
struct SleepMarkCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState

    /// The most recent sleep-mark the user tapped, shown as a transient confirmation line under the
    /// two buttons. Drives the SwiftUI haptic landing too. LOGGING-ONLY: a mark never feeds the sleep
    /// detector — it's persisted to the metric series + strap log. (#461)
    @State private var lastMark: SleepMark?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep marks")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text("Tap when you're heading to bed or when you wake. Each tap is logged with the time. It doesn't change tonight's detected sleep.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: NoopMetrics.gap) {
                        // Routed through the unified NoopButton system so the two marks sit identically
                        // (sentence-case label, leading icon at 8pt, controlHeight=48, no glow).
                        NoopButton("Going to sleep", systemImage: "moon.zzz.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.bedtime) }
                            .accessibilityLabel("Log going to sleep")

                        NoopButton("I'm awake", systemImage: "sun.max.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.wake) }
                            .accessibilityLabel("Log waking up")
                    }
                    if let lastMark {
                        Text(lastMark.confirmation)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .transition(.opacity)
                            .accessibilityLabel(lastMark.confirmation)
                    }
                }
            }
        }
        // A success haptic lands when a new mark is captured (value-driven, not per-tap), matching the
        // app's sparse tactile vocabulary. No-op on macOS.
        .strandHaptic(.success, trigger: lastMark?.tsMs ?? 0)
    }

    /// Persist + log a tapped mark. Optimistically shows the confirmation immediately, fires the
    /// haptic via `lastMark`, appends the human-readable strap-log line, then writes the metric-series
    /// row through the repo's live store handle (no new Repository API, no schema change). The write is
    /// idempotent by (deviceId, day, key). (#461)
    private func logMark(_ type: SleepMarkType) {
        let mark = SleepMark(type: type)
        withAnimation(.easeOut(duration: 0.2)) { lastMark = mark }
        // The shareable strap log is the human-readable surface that lands in a debug export.
        live.append(log: mark.logLine)
        Task {
            guard let store = await repo.storeHandle() else { return }
            try? await store.upsertMetricSeries([mark.metricPoint], deviceId: repo.deviceId)
        }
    }
}

/// The "Syncing strap history…" note, shown only while a historical offload is running (#77). Owns the
/// `LiveState` observation so the chunk count ticks without re-rendering the rest of the Sleep screen.
enum SleepFreshnessStatus: Equatable {
    case syncing, calculating, syncFailed, awaitingSync, notDetected
}

/// Pure priority ladder behind the Sleep status banner. "Missing" is deliberately held until morning so
/// opening Sleep during the night does not claim a still-in-progress night was missed.
func resolveSleepFreshness(hasCurrentNight: Bool, morningReady: Bool, syncing: Bool,
                           calculating: Bool, syncedSinceDayStart: Bool,
                           syncFailed: Bool) -> SleepFreshnessStatus? {
    if syncing { return .syncing }
    // #2108: a night already in hand outranks .calculating. It used to sit below, so `hasCurrentNight`
    // could only silence the missing-night states and a finished night was structurally unable to
    // silence this one: the banner said "detecting and staging the night now" directly above that same
    // night scored, timed and staged on screen. A note that contradicts the content beside it is worse
    // than no note, and one that is always on is read by nobody the day it matters. .syncing stays
    // above, because data still arriving can genuinely change what is shown.
    if hasCurrentNight { return nil }
    if calculating { return .calculating }
    if !morningReady { return nil }
    if syncFailed { return .syncFailed }
    return syncedSinceDayStart ? .notDetected : .awaitingSync
}

/// Explicit state for the expected current night. Older sleep can remain available underneath, but it is
/// never left to impersonate today's result while a sync, calculation, or failed detection is unresolved.
/// Owns the `LiveState` observation so a live tick re-renders only this note, never the Sleep page.
private struct SleepFreshnessNote: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var intelligence: IntelligenceEngine
    let latestWakeTs: Int?

    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.startOfDay(for: now)
        let current = latestWakeTs.map {
            calendar.isDate(Date(timeIntervalSince1970: TimeInterval($0)), inSameDayAs: now)
        } ?? false
        // AppModel intentionally waits two quiet seconds after HISTORY_COMPLETE before starting the
        // scoring pass. Treat that debounce as calculation too; otherwise the banner can flash the final
        // "wasn't detected" verdict between sync completion and `intelligence.computing` becoming true.
        let calculationQueued = live.lastSyncedAt.map {
            (0..<5).contains(now.timeIntervalSince1970 - $0)
        } ?? false
        let status = resolveSleepFreshness(
            hasCurrentNight: current,
            morningReady: calendar.component(.hour, from: now) >= 6,
            syncing: live.backfilling,
            calculating: intelligence.computing || calculationQueued,
            syncedSinceDayStart: (live.lastSyncedAt ?? 0) >= start.timeIntervalSince1970,
            syncFailed: live.lastSyncError != nil
        )
        switch status {
        case .syncing:
            InlineNotice(String(localized: "Syncing strap history…"))
        case .calculating:
            InlineNotice(String(localized: "Calculating last night's sleep…"))
        case .syncFailed:
            InlineNotice(String(localized: "The history sync stopped before it finished. Keep the strap nearby and try Sync again."),
                         title: String(localized: "Last night's sleep hasn't synced"), tone: .warning)
        case .awaitingSync:
            InlineNotice(String(localized: "Connect the strap and sync its history."),
                         title: String(localized: "Waiting for last night's sleep"))
        case .notDetected:
            InlineNotice(String(localized: "Keep the strap connected and try Sync again."),
                         title: String(localized: "Last night's sleep wasn't detected"), tone: .warning)
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Local value types

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
private struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    /// Newest day row (Equatable) — catches in-place edits to the latest day's values.
    let lastDayUpdated: DailyMetric?
    /// Newest sleep session (Equatable) — catches a re-import of the latest night.
    let lastSleep: CachedSleepSession?
    /// Bumped on every Repository.refresh — catches a re-import that changes only the
    /// imported metricSeries figures (importedSleep) without touching days/sleeps.
    let refreshSeq: Int
}

// MARK: - Preview

#if DEBUG
#Preview("Sleep") {
    let repo = Repository.previewSleep()
    return SleepView()
        .environmentObject(repo)
        .environmentObject(LiveState())
        .environmentObject(AppModel())
        .environmentObject(IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "preview"))
        .frame(width: 980, height: 1180)
        .preferredColorScheme(.dark)
}

@MainActor
private extension Repository {
    /// Sample repository populated with imported-style nights for previews.
    static func previewSleep() -> Repository {
        let repo = Repository(deviceId: "preview")
        let cal = Calendar.current
        let now = Date()

        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        for i in (0..<30).reversed() {
            let date = cal.date(byAdding: .day, value: -i, to: now)!
            let jitter = Double((i * 23) % 11) - 5
            let light = 210.0 + jitter
            let deep = 80.0 + jitter * 0.5
            let rem = 95.0 + jitter * 0.7
            let awake = 25.0 + Double((i * 7) % 9)
            let asleep = light + deep + rem
            let stagesJSON = "{\"light\":\(light),\"deep\":\(deep),\"rem\":\(rem),\"awake\":\(awake)}"

            days.append(DailyMetric(
                day: fmt.string(from: date),
                totalSleepMin: asleep,
                efficiency: 88 + jitter * 0.3,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Int(awake / 6), restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5), recovery: 60 + jitter,
                strain: 10 + Double(i % 6), exerciseCount: i % 2,
                spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6 + jitter * 0.1))

            var onset = cal.date(bySettingHour: 22, minute: 50 + Int(jitter), second: 0, of: date) ?? date
            onset = cal.date(byAdding: .day, value: -1, to: onset) ?? onset
            let end = onset.addingTimeInterval((asleep + awake) * 60)
            sleeps.append(CachedSleepSession(
                startTs: Int(onset.timeIntervalSince1970),
                endTs: Int(end.timeIntervalSince1970),
                efficiency: 88 + jitter * 0.3,
                restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5),
                stagesJSON: stagesJSON))
        }

        repo.days = days
        repo.sleeps = sleeps
        repo.loaded = true
        return repo
    }
}
#endif
