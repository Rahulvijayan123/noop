//  LiquidTodayView.swift
//  Nara · the Today tab.
//
//  The day at a glance, top to bottom: the day header (the day's name and date, step back and forward,
//  tap for a date picker, Settings), the three hero rings (Baseline, Watchdog, Rest), the key-metric
//  tiles the user chose, the day's workouts, the day's heart rate on a real clock axis, the opt-in cards,
//  one strap row, and the Browse / Customize footer. Depth lives one tap down: every ring, tile and card
//  opens its detail page. Every value binds to the SAME data the classic TodayView reads (the reads are
//  in `load()`, unchanged), and every tap routes to the same destination as before.

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics
import OuraProtocol

struct LiquidTodayView: View {
    @AppStorage(DayCycleMode.storageKey) private var dayCycleModeRaw = DayCycleMode.sleepOnset.rawValue
    private var dayCycleMode: DayCycleMode { DayCycleMode.persisted(dayCycleModeRaw) }
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    // For pull-to-sync (#334): a pull kicks a manual strap history offload via ble.syncNow(). Observe
    // BLEManager, NOT AppModel — AppModel @Publishes `bpm` on the ~1 Hz HR tick, so observing it would
    // re-render all of Today every second (the exact churn the LiveState leaves isolate). BLEManager only
    // publishes connect/discovery state, never HR. Injected at the app roots beside .environmentObject(model).
    @EnvironmentObject var ble: BLEManager

    /// #today-hosted-cards: the ordered Trends/Sleep cards the user has hosted in Today. Empty by default
    /// (opt-in); rendered by the `.addedCards` section. Shared @AppStorage key with Android.
    @AppStorage(HostedCardPrefs.selectionKey) private var hostedCardsRaw = ""

    // async-loaded via the confirmed Repository accessors
    @State private var restScore: Double?          // sleep_performance, day-keyed
    // Queue 11a: day-keyed "spo2_candidate" metricSeries (WHOOP `spo2_candidate_82` or Oura
    // ceiling@100 `0x6F`, device-conditional — see `IntelligenceEngine`). Empty when the
    // experimental toggle is OFF (the engine writes nothing) or the owner has no in-band reading.
    @State private var spo2CandidateByDay: [String: Double] = [:]
    /// The strap's current skin temperature (today only), straight from the banked samples, for the Skin Temp
    /// tile. nil when the strap is off the wrist or nothing has offloaded; the tile then shows the nightly
    /// value. See `KeyMetricReadings`.
    @State private var currentSkinTemp: KeyMetricReadings.SkinTemp?
    /// How many SpO₂ readings the strap banked for the selected day's night (read by `load()`).
    @State private var spo2NightReadings: KeyMetricReadings.Spo2Readings?
    @State private var stepsEst: Double?           // steps_est, day-keyed to the selected day (fallback)
    @State private var importedStepsDay: Int?      // Apple Health steps for the selected day (middle tier)
    @State private var importedActiveKcalDay: Double?  // #616: Apple Health active energy for the day (calorie fallback)
    @State private var weightKg: Double?           // #204: Apple Health weight ?: profile fallback
    @State private var hrValues: [Double] = []     // hrBuckets for the day's window → 5-min means
    /// Line identity for [hrValues] (#2082). The kit chart finds the same gaps from `hrTimes` itself; kept
    /// because `load()` writes it.
    @State private var hrSegments: [String] = []
    /// Unix seconds of each [hrValues] bucket: the heart-rate card's clock axis.
    @State private var hrTimes: [Double] = []
    @State private var workouts: [WorkoutRow] = [] // newest-first
    /// #today-hosted-cards: the shared SleepModel that backs every SleepModel-derived hosted sleep card.
    /// Built ONCE in `load()` from the SAME inputs the Sleep tab uses (`SleepModel.build`), and only when a
    /// sleep-origin card is actually hosted. nil until (and unless) it's built.
    @State private var hostedSleepModel: SleepModel? = nil

    // #2040: today's scored stress for the hosted curve card. Loaded only when that card is hosted.
    @State private var hostedStressHours: [DaytimeStress.HourPoint] = []
    @State private var hostedStressActivityMaskedHours = 0

    // sheets
    @State private var guideSection: ScoreSection?
    @State private var customizationDestination: TodayCustomizationDestination?
    // #today-layout (parity with Android): the user-chosen section order, persisted under the byte-identical
    // "today.sectionOrder" key the Android TodayLayoutPrefs uses.
    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @AppStorage(TodayLayoutPrefs.hiddenKey) private var hiddenSectionsRaw = ""
    private var sectionOrder: [TodaySection] {
        TodayLayoutPrefs.visibleOrder(orderRaw: sectionOrderRaw, hiddenRaw: hiddenSectionsRaw)
    }
    // #430 parity: the Key-Metrics grid honours the SAME editor selection/order + Detailed-tiles switch as
    // Android (byte-identical @AppStorage keys). `kSparks` holds the trailing-30-day series the detailed
    // tiles graph (keyed by metric-catalog key), filled by the loader alongside everything else.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    /// The detailed graphs' trailing window — 1 week / 2 weeks / 1 month (shared key with Android). The
    /// loader banks a day-keyed 30-day superset; render filters down, so a window change applies instantly.
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14
    @State private var kSparks: [String: [(String, Double)]] = [:]
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    /// #1001: TODAY's in-progress Effort, scored live in `load()` over the same window this view already
    /// resolves for its other reads. nil for a navigated past day, and nil when the scorer has too few
    /// readings — every Effort read-out then falls back to the stored row rather than a fabricated value.
    @State private var liveTodayStrain: Double?

    // day navigation (0 = today, 1 = yesterday, …). G1 (findings/g1-day-ui.md Q4 / T03): persisted via
    // the SAME key classic TodayView uses, so a browsed past day survives a process restart and a
    // SwiftUI re-mount, and the two Today surfaces agree on the selection.
    @AppStorage(TodayView.selectedDayOffsetKey) private var selectedDayOffset = 0
    @State private var showDayPicker = false
    /// Where the heart-rate CHART sits, so a sideways drag on it scrubs instead of changing the day.
    @State private var heartRateCardFrame: CGRect = .null
    private static let daySwipeSpace = "liquidTodayDaySwipeSpace"

    // PERF: the body was rescanning repo.days (599 days) ~23× per pass for displayDay and ~3× for
    // readiness on EVERY re-render. Resolve both ONCE per data/day change in load() and read the cache in
    // body (O(1)).
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    /// The recovery-INDEPENDENT prior-day vitals carry (HRV / RHR / respiratory), resolved ONCE in load()
    /// alongside cachedDisplayDay. Fixes the v8 rollover blank: after 04:00, before tonight's sleep scores,
    /// today's row has no vitals yet, so these fall back to the last night that recorded them.
    @State private var cachedVitalsDay: DailyMetric?
    @State private var cachedRespDay: DailyMetric?
    @State private var cachedHrvDay: DailyMetric?
    @State private var cachedRestingHrDay: DailyMetric?
    @State private var cachedSkinTempReadingDay: DailyMetric?
    /// The Charge hero's resolved state (#543 carry + the honest label), resolved ONCE in load().
    @State private var cachedChargeDisplay: ChargeDisplay = .noData
    @State private var cachedBaselineNights: (hrv: [Double?], dayKeys: [String]) = ([], [])
    /// Flips true once the first load() completes.
    @State private var dataLoaded = false
    /// The day offset whose data the caches hold: set when a `load()` for that day finishes. While it differs
    /// from `selectedDayOffset` (first launch, or a day swipe still loading) the page shows its real layout
    /// redacted, so the previous day's numbers never sit under the new day's title and nothing moves when
    /// the values land.
    @State private var loadedDayOffset: Int?
    /// Whether the load that set `loadedDayOffset` ran after the repository's first refresh. A load at
    /// launch, before the store has been read, finishes with nothing in hand; that is not "no data".
    @State private var loadedFromRepository = false

    /// True while the page has no data for the day it shows.
    private var isLoading: Bool { loadedDayOffset != selectedDayOffset || !loadedFromRepository }

    // MARK: - Day navigation (swipe, chevrons and calendar; day-keyed reads)

    /// The logical day the selector resolves to (offset 0 = today's logical day, rolls at 04:00).
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs key on. At offset 0 follows repo.today?.day.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }
    /// The DailyMetric shown for the selected day — read from the cache resolved in load().
    private var displayDay: DailyMetric? { cachedDisplayDay }
    /// The prior-day vitals carry (see `cachedVitalsDay`), read O(1) from the cache. Non-nil only at
    /// offset 0 (today); a navigated past day carries nothing (its own row is the whole story).
    private var vitalsDay: DailyMetric? { cachedVitalsDay }
    /// The prior-day RESPIRATORY carry (#1331): staleness-bounded. Non-nil only at offset 0.
    private var respDay: DailyMetric? { cachedRespDay }

    /// PER-FIELD HRV / resting-HR carries (#1842), read O(1) from the cache like `vitalsDay`. Twins of
    /// `DailyMetric.lastHrvDay` / `lastRestingHrDay`; mirror the Android per-field rows.
    private var hrvDay: DailyMetric? { cachedHrvDay }

    private var restingHrDay: DailyMetric? { cachedRestingHrDay }

    /// The skin-temp reading the tile LEADS with (#1844): today's row if it holds either number, else the
    /// vitals carry, else the freshest prior row with either. Both numbers come off the SAME row, so an
    /// absolute is never paired with another night's deviation. Twin of `TodayView.skinTempLeadReading`.
    private var skinTempLeadReading: SkinTempDisplay.Reading? {
        let row = [displayDay, vitalsDay, cachedSkinTempReadingDay]
            .compactMap { $0 }
            .first { $0.skinTempC != nil || $0.skinTempDevC != nil }
        return SkinTempDisplay.leadReading(absC: row?.skinTempC, devC: row?.skinTempDevC,
                                           prefer: SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute)
    }
    /// The Charge hero's resolved state (see `cachedChargeDisplay`), read O(1) from the cache.
    private var chargeDisplay: ChargeDisplay { cachedChargeDisplay }

    /// The actual O(days) resolution. Offset 0 prefers live repo.today; past offsets look up. Run ONCE
    /// per data/day change from load(), never from body.
    private func resolveDisplayDay() -> DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }
    /// How far back navigation can go (whole days from the earliest banked day to today).
    private var earliestDayOffset: Int {
        Self.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                          todayKey: Repository.logicalDayKey(Date()))
    }
    /// The page title: Today / Yesterday / the weekday for older days.
    private var dayTitle: String {
        switch selectedDayOffset {
        // #1013: these must localize — "Today"/"Yesterday" go through String(localized:) (matching the
        // classic TodayView.dayNavLabel), and the weekday name is formatted in the user's locale, not the
        // en_US_POSIX one used only for machine day-keys.
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            return selectedLogicalDay.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
        }
    }
    /// The data line under the title: "Tue 7 Oct" for today and yesterday, "5 Oct" under a weekday title
    /// (the weekday is already the title); the year is added outside the current year.
    private var dateLine: String {
        let day = selectedLogicalDay
        if selectedDayOffset <= 1 {
            return ReadoutContent.dateLine(day, period: .day, locale: AppLanguage.activeLocale)
        }
        let sameYear = Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year)
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(AppLanguage.activeLocale)
        return day.formatted(sameYear ? style : style.year())
    }
    /// Two-way binding for the graphical calendar: reads the shown day, writes back an offset.
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { selectedLogicalDay },
            set: { newValue in
                selectedDayOffset = Self.pickedDayOffset(pickedDate: newValue,
                                                         anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }
    /// Horizontal swipe between days (right = older, left = newer — `TodayView.daySwipeDelta`, #2378),
    /// clamped to [today, earliest]. A drag that starts on the heart-rate chart scrubs the chart instead.
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .named(Self.daySwipeSpace))
            .onEnded { value in
                guard !heartRateCardFrame.contains(value.startLocation) else { return }
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                step(by: TodayView.daySwipeDelta(dx: dx))
            }
    }

    /// Moves the selected day by `delta` (+1 older, −1 newer), clamped to the navigable range. The values
    /// swap in place; nothing animates (motion marks navigation, and this is the same page).
    private func step(by delta: Int) {
        let next = Self.clampedDayOffset(current: selectedDayOffset, delta: delta, maxOffset: earliestDayOffset)
        guard next != selectedDayOffset else { return }
        selectedDayOffset = next
    }

    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        min(max(0, maxOffset), max(0, current + delta))
    }
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        // ScreenScaffold owns the flat canvas, the page margins, the tab-bar clearance, the system
        // pull-to-refresh and the scroll-to-top on an at-root re-tap of the Today tab (#198 follow-up).
        ScreenScaffold(title: nil, onRefresh: { await pullToRefresh() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                header
                // The strain/illness early-warning banner, pinned ABOVE the reorderable block — the same
                // position classic TodayView and Android use — so a warning cannot be reordered below the
                // fold. Renders nothing when model.healthAlert is nil.
                HealthAlertBanner()
                // #105: the live "workout in progress" card, pinned above the reorderable block so an
                // active manual workout is immediately visible. Renders nothing when no workout is active.
                ActiveWorkoutIndicatorSection()
                // #today-layout (parity with Android): every Today section renders in the user's saved
                // order (the Arrange sheet reorders and hides them).
                ForEach(sectionOrder) { section in
                    switch section {
                    case .hero: heroCard
                    case .synthesis: EmptyView()
                    case .keyMetrics: keyMetricsSection
                    case .workouts: workoutsSection
                    case .heartRate: heartRateSection
                    case .menstrualCycle:
                        if selectedDayOffset == 0 { MenstrualCycleHomeCard() }
                    // #656: the persistent journal widget. Today only; the card self-hides when the
                    // reminder toggle is off.
                    case .journal: if selectedDayOffset == 0 { JournalReminderCard() }
                    // #today-hosted-cards: cards the user pulled in from the Trends/Sleep tabs. Today-only,
                    // matching Android's addedCards section gate + the classic TodayView.
                    case .addedCards: if selectedDayOffset == 0 { hostedCardsSection }
                    }
                }
                // Opt-in "looks like a workout?" suggestion. Self-gates on the toggle AND on the detector
                // finding an unsaved, un-dismissed window, so it renders nothing by default.
                AutoWorkoutCard()
                // One strap row, only when there is something to say (battery, a history sync, a re-pair).
                TodayStrapRow()
                footerActions
            }
            #if os(macOS)
            // Keep the phone-shaped column readable and centred on the wide Mac detail pane.
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            #endif
            // The Baseline ring's vitals refresh lives on an always-mounted view, so it keeps running on a
            // past day (where the hero hides Watchdog) and when the user hides the hero section.
            .background { BaselineVitalsRefresher() }
        }
        .coordinateSpace(name: Self.daySwipeSpace)
        .onPreferenceChange(LiquidHeartRateCardFrameKey.self) { heartRateCardFrame = $0 }
        // Swipe left/right to change DAYS (WHOOP-style). Tab-swipe is disabled on Today in RootTabView so
        // this owns the horizontal gesture here.
        .simultaneousGesture(daySwipeGesture)
        // One light tick per day change (swipe, chevron or calendar pick).
        .strandHaptic(.selection, trigger: selectedDayOffset)
        // G1 (findings/g1-day-ui.md T01; audit-g1-day F1b): the day-rollover + zone-context sequences
        // join the reload key so the liquid Today re-keys to the new local-midnight day within ~1s even
        // at an unchanged refreshSeq (no data refresh, sensor reading, network, or DB revision), and
        // re-keys day-scoped bounds on a same-day timezone change.
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)-\(repo.dayRolloverSeq)-\(repo.zoneContextSeq)-\(dayCycleModeRaw)") {
            await load()
        }
        // G1 (T03): clamp a persisted past-day selection into the current navigable range on appear so a
        // stored offset can never strand the user past the earliest banked day.
        .onAppear {
            let clamped = TodayView.restoredDayOffset(saved: selectedDayOffset, maxOffset: earliestDayOffset)
            if clamped != selectedDayOffset { selectedDayOffset = clamped }
        }
        #if DEBUG
        .task { await applyDemoDayOffset() }
        #endif
        // How the scores work, reached from the Rest ring's context menu (and from Browse).
        .sheet(item: $guideSection) { section in
            NavigationStack { ScoringGuideView(initialSection: section, onClose: { guideSection = nil }) }
        }
        .sheet(item: $customizationDestination) { destination in
            TodayCustomizationSheet(
                initialDestination: destination,
                sectionOrderRaw: $sectionOrderRaw,
                hiddenSectionsRaw: $hiddenSectionsRaw,
                keyMetricsRaw: $keyMetricsRaw,
                keyMetricsDetailed: $keyMetricsDetailed,
                keyMetricsWindowDays: $keyMetricsWindowDays,
                hostedCardsRaw: $hostedCardsRaw
            )
        }
    }

    /// The system pull-to-refresh. #334 (iOS twin of Android #426): a pull requests a fresh strap history
    /// offload, not just a UI reload. #1748: only when the client's own precondition holds — `syncNow()`'s
    /// gate checks connected + bonded, and `bonded` is set by the live-HR path for a 5/MG that never
    /// completed a handshake, so an ungated pull was accepted and then declined in silence.
    private func pullToRefresh() async {
        if ble.state.historyReady { ble.syncNow() }
        await repo.refresh()
        await load()
    }

    #if DEBUG
    /// DEBUG-only `--demo-day-offset N`: open Today on a past day for simulator screenshots (a swipe cannot
    /// be scripted). Waits for the history span so the clamp has something to clamp to. With
    /// `--demo-today-customize` (`today` / `keyMetrics` / `addedCards`) it also opens the Customize sheet.
    private func applyDemoDayOffset() async {
        if let page = DemoLaunch.stringArg("--demo-today-customize") {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            customizationDestination = TodayCustomizationDestination(rawValue: page) ?? .today
        }
        guard let wanted = DemoLaunch.intArg("--demo-day-offset") else { return }
        for _ in 0..<100 where repo.freshness.earliestDay == nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        selectedDayOffset = Self.clampedDayOffset(current: 0, delta: wanted, maxOffset: earliestDayOffset)
    }
    #endif

    // MARK: - Header

    /// The page header: the day's name (title1) over its date, both one button that opens the date
    /// picker; a return-to-today action while browsing the past; the day stepper; Settings. A title
    /// appears once, and the date is the only line under it.
    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space1) {
            Button { showDayPicker = true } label: {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(dayTitle)
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(verbatim: dateLine)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(Text("Choose a day. Swipe sideways to change day."))
            .popover(isPresented: $showDayPicker) {
                DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                           displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(12)
                    .frame(minWidth: 320, minHeight: 360)
                    .liquidPopoverAdaptation()
            }
            // G1 (spec §3 / findings T03): an explicit one-tap return to Today while browsing a past day.
            if selectedDayOffset > 0 {
                Button {
                    selectedDayOffset = 0
                    showDayPicker = false
                } label: {
                    Text("Today")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .padding(.horizontal, NoopMetrics.space1)
                        .frame(minHeight: NoopMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return to today")
            }
            dayChevron("chevron.left", enabled: selectedDayOffset < earliestDayOffset) { step(by: 1) }
                .accessibilityLabel(Text("Previous day"))
            dayChevron("chevron.right", enabled: selectedDayOffset > 0) { step(by: -1) }
                .accessibilityLabel(Text("Next day"))
            HeaderSettingsButton()
                .padding(.leading, NoopMetrics.space1)
        }
    }

    /// One day-stepper chevron, drawn like `PeriodStepper`'s: 44 pt target, accent when it can move,
    /// `textTertiary` and disabled at the end of the range.
    private func dayChevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(StrandFont.icon(.row).weight(.semibold))
                .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary.opacity(0.5))
                .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Hero

    /// Baseline, Watchdog and Rest as three flat rings in one card. Each whole cell (ring, name, state)
    /// is one link. Watchdog is a live signal, so a past day shows only Baseline and that day's Rest.
    private var heroCard: some View {
        NoopCard {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                BaselineHeroCell(isLoading: isLoading)
                if selectedDayOffset == 0 {
                    WatchdogHeroCell(isLoading: isLoading)
                }
                HeroRingCell(label: String(localized: "Rest"),
                             fraction: restScore.map { $0 / 100 },
                             value: restScore.map { String(Int($0.rounded())) } ?? Self.noValueDash,
                             color: StrandPalette.restColor,
                             state: HeroRings.recoveryStatus(score: restScore),
                             route: .metric(HeroRingMetric.rest),
                             isLoading: isLoading)
                    // The scoring guide stays one long-press away until the Rest detail page links it.
                    .contextMenu {
                        Button { guideSection = .rest } label: {
                            Label("How your scores work", systemImage: "info.circle")
                        }
                    }
                    .accessibilityAction(named: Text("How your scores work")) { guideSection = .rest }
            }
        }
    }

    // MARK: - Key metrics grid

    /// The chosen detailed-graph window's oldest day key (1 week / 2 weeks / 1 month ending on the
    /// selected day). The loader banks a 30-day superset; render filters down so a window change in the
    /// editor applies instantly, no reload.
    private var sparkWindowCutoffKey: String {
        let days = (keyMetricsWindowDays == 7 || keyMetricsWindowDays == 30) ? keyMetricsWindowDays : 14
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: selectedLogicalDay)
        return Repository.localDayKey(cal.date(byAdding: .day, value: -(days - 1), to: anchor) ?? anchor)
    }

    /// A metric's spark values inside the chosen window, oldest → newest.
    private func windowedSpark(_ key: String) -> [Double] {
        let cutoff = sparkWindowCutoffKey
        return (kSparks[key] ?? []).filter { $0.0 >= cutoff }.map { $0.1 }
    }

    /// The user's key-metric tiles, two across, every tile one height. No section header: the tiles name
    /// themselves, and the editor is reached from "Customize Today" and from a long-press on any tile.
    private var keyMetricsSection: some View {
        // HRV / Rest HR (+ Blood Oxygen / Respiratory) tiles share the recovery vitals' per-field
        // today-first carry so they don't blank at the rollover while Charge/Effort/Rest stay strictly
        // today's own (they are scored surfaces).
        let hrv = displayDay?.avgHrv ?? hrvDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? restingHrDay?.restingHr).map(Double.init)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: NoopMetrics.gap), count: 2),
            spacing: NoopMetrics.gap
        ) {
            ForEach(enabledKeyMetrics) { metric in
                keyMetricTile(tileModel(metric, hrv: hrv, rhr: rhr))
            }
        }
    }

    /// What one tile shows and where it goes.
    private struct TileModel {
        let metric: KeyMetric
        var value: String?
        var unit: String?
        var state: String? = nil
        var isEstimate = false
        /// The catalog entry the tile opens (and whose key names its spark series).
        var detail: MetricDescriptor?
        /// The `kSparks` key of the tile's trend; nil draws no trend.
        var sparkKey: String?
    }

    /// One editor-selected tile: the metric's value exactly as the old tiles read it (Android's descriptor
    /// map is the twin), plus the catalog entry it taps through to.
    private func tileModel(_ metric: KeyMetric, hrv: Double?, rhr: Double?) -> TileModel {
        func catalog(_ key: String) -> MetricDescriptor? { MetricCatalog.all.first(where: { $0.key == key }) }
        switch metric {
        case .charge:
            // Reads the SAME resolved Charge as before, not `displayDay?.recovery` raw (#543: one prior row
            // feeds every recovery-derived read-out). A carried value says whose night it is.
            let state: String?
            switch chargeDisplay {
            case .carried(_, let caption): state = caption
            case .calibrating: state = chargeDisplay.ringStatus
            case .scored, .noData: state = nil
            }
            return TileModel(metric: metric, value: Self.intValue(chargeDisplay.pct), unit: "%", state: state,
                             detail: catalog(HeroRingMetric.charge), sparkKey: HeroRingMetric.charge)
        case .effort:
            // #492: Effort is a load index (0–100 Nara / 0–21 WHOOP), NOT a percentage. `effortText`'s
            // shared formatter keeps the tile, the workout rows and the detail page on one scale.
            return TileModel(metric: metric, value: effortStrain(displayDay).map { effortText($0) }, unit: nil,
                             detail: catalog(HeroRingMetric.effort), sparkKey: HeroRingMetric.effort)
        case .rest:
            return TileModel(metric: metric, value: Self.intValue(restScore), unit: "%",
                             detail: catalog(HeroRingMetric.rest), sparkKey: HeroRingMetric.rest)
        case .hrv:
            return TileModel(metric: metric, value: Self.intValue(hrv), unit: "ms",
                             detail: catalog("hrv"), sparkKey: "hrv")
        case .restingHr:
            return TileModel(metric: metric, value: Self.intValue(rhr), unit: "bpm",
                             detail: catalog("rhr"), sparkKey: "rhr")
        case .bloodOxygen:
            // Queue 11a: falls back to the device-conditional "spo2_candidate" mean only when `spo2Pct` is
            // nil AND the experimental toggle is ON — same gating as the classic tile, never as the
            // default. The candidate is an unverified estimate, so the tile says "Estimate".
            let spo2Real = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            let spo2CandidateOn = PuffinExperiment.spo2CandidateDisplayEnabled
            let spo2CandidateValue = spo2Real == nil && spo2CandidateOn
                ? spo2CandidateByDay[cachedDisplayDay?.day ?? selectedDayKey]
                : nil
            let spo2 = spo2Real ?? spo2CandidateValue
            // The detail is the catalog's "spo2" entry even while the candidate shows: there is no
            // "spo2_candidate" catalog entry, and the detail view merges the candidate series itself.
            return TileModel(metric: metric, value: Self.intValue(spo2), unit: "%",
                             isEstimate: spo2CandidateValue != nil, detail: catalog("spo2"),
                             sparkKey: spo2CandidateValue != nil ? "spo2_candidate" : "spo2")
        case .respiratory:
            let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm ?? respDay?.respRateBpm
            return TileModel(metric: metric,
                             value: resp.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) },
                             unit: "rpm", detail: catalog("resp_rate"), sparkKey: "resp_rate")
        case .steps:
            // Measured strap count ?: imported Apple Health count ?: motion estimate, and the tap opens the
            // matching source (#377).
            return TileModel(metric: metric, value: stepCount.map { Int($0).formatted(.number) },
                             unit: String(localized: "steps"),
                             detail: stepsDetailMetric ?? catalog(stepsDetailKey), sparkKey: stepsDetailKey)
        case .weight:
            // Apple Health weight, else the profile weight, always through the shared formatter so the
            // Imperial/Metric toggle reaches the tile. The profile fallback says so.
            let kg = weightKg ?? profile.weightKg
            let unit = UnitFormatter.massUnit(unitSystem)
            let formatted = UnitFormatter.massFromKilograms(kg, system: unitSystem)
            let value = formatted.hasSuffix(" " + unit) ? String(formatted.dropLast(unit.count + 1)) : formatted
            return TileModel(metric: metric, value: value, unit: unit,
                             state: weightKg == nil ? String(localized: "From profile") : nil,
                             detail: catalog("weight"), sparkKey: "weight")
        case .calories:
            // #616: imported-first value (imported ?: activeKcalEst), and the tap opens the matching source.
            return TileModel(metric: metric, value: Self.intValue(caloriesCount), unit: "kcal",
                             detail: caloriesDetailMetric ?? catalog("energy_kcal"), sparkKey: "energy_kcal")
        case .skinTemp:
            // #1844: lead with the absolute (or the deviation, per Settings), from one row. When the strap is
            // on the wrist the absolute is its newest banked sample; a deviation needs the nightly baseline,
            // so a user who chose "deviation" keeps the nightly value.
            let fahrenheit = temperatureUnit == .fahrenheit
            let preferAbsolute = (SkinTempDisplay.Kind(rawValue: skinTempDisplayRaw) ?? .absolute) == .absolute
            let live = preferAbsolute ? currentSkinTemp : nil
            let reading = live.map { SkinTempDisplay.Reading(value: $0.celsius, kind: .absolute) }
                ?? skinTempLeadReading
            // The tile's trend is the nightly DEVIATION series, so it is drawn only under a deviation.
            return TileModel(metric: metric,
                             value: reading.map { SkinTempDisplay.numberString($0.value, kind: $0.kind,
                                                                              fahrenheit: fahrenheit) },
                             unit: reading.map { SkinTempDisplay.unitSymbol(kind: $0.kind, fahrenheit: fahrenheit) },
                             detail: catalog("skin_temp"),
                             sparkKey: reading?.kind == .deviation ? "skin_temp" : nil)
        }
    }

    @ViewBuilder
    private func keyMetricTile(_ m: TileModel) -> some View {
        let trend = keyMetricsDetailed ? m.sparkKey.map { windowedSpark($0) } : nil
        let tile = MetricTile(icon: m.metric.customizationIcon, iconColor: m.metric.customizationTint,
                              label: LocalizedStringKey(m.metric.title), value: m.value, unit: m.unit,
                              state: m.state, trend: trend, reservesTrendSlot: keyMetricsDetailed,
                              isEstimate: m.isEstimate, isLoading: isLoading)
        if let detail = m.detail {
            // A VALUE link (not a closure), so a re-tap of the Today tab pops back to the root (#135/#198).
            NavigationLink(value: TabRoute.metricSourced(key: detail.key, source: detail.source)) { tile }
                .buttonStyle(LiquidPressStyle())
                .contextMenu {
                    Button { customizationDestination = .keyMetrics } label: {
                        Label("Edit Key Metrics", systemImage: "slider.horizontal.3")
                    }
                }
        } else {
            tile
        }
    }

    // MARK: - Workouts

    /// The selected day's workouts, newest first: up to two rows and a "Show all" row. Nothing at all on a
    /// day without one (the Workouts list stays reachable from Browse and Events).
    @ViewBuilder
    private var workoutsSection: some View {
        if !workouts.isEmpty {
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(workouts.prefix(2).enumerated()), id: \.offset) { index, w in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        NavigationLink(value: TabRoute.workouts) {
                            NoopListRow(icon: WorkoutTypeIconography.systemSymbolName(for: w.sport),
                                        iconColor: StrandPalette.effortColor,
                                        title: LocalizedStringKey(WorkoutSource.displaySport(w.sport)),
                                        subtitle: workoutSub(w),
                                        value: w.strain.map { String(localized: "Effort \(effortText($0))") })
                        }
                        .buttonStyle(.plain)
                    }
                    if workouts.count > 2 {
                        NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                        NavigationLink(value: TabRoute.workouts) {
                            NoopListRow(icon: "list.bullet", title: "Show all", value: "\(workouts.count)")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .loadingRedaction(isLoading)
        }
    }

    // MARK: - Heart rate

    /// The day's heart rate on a real clock axis (5-minute means, gaps where nothing was recorded), the
    /// live value in the header while the strap streams today, and the day's resting / high / low.
    private var heartRateSection: some View {
        TodayHeartRateCard(times: hrTimes, values: hrValues,
                           resting: displayDay?.restingHr ?? restingHrDay?.restingHr,
                           isToday: selectedDayOffset == 0,
                           window: heartRateWindow,
                           isLoading: isLoading,
                           frameSpace: Self.daySwipeSpace)
    }

    /// The chart's x window: the selected logical day, midnight to midnight, widened to the loaded samples
    /// when the day-cycle setting starts the day at sleep onset (the evening before) or the logical day
    /// runs past midnight. Stable within a day, so a refresh does not replay the range animation.
    private var heartRateWindow: ClosedRange<Date> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: selectedLogicalDay)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        guard !isLoading, let first = hrTimes.first, let last = hrTimes.last else { return start...end }
        return min(start, Date(timeIntervalSince1970: first))...max(end, Date(timeIntervalSince1970: last))
    }

    // MARK: - Added cards (#today-hosted-cards)

    /// The Trends/Sleep cards the user hosted in Today, in their arranged order. Data-driven off the SAME
    /// @AppStorage the Customise editor writes, so add / remove / reorder reflects live. Each hosted card
    /// is the SAME view its home tab renders (a mirror, not a copy) and carries its own header.
    @ViewBuilder
    private var hostedCardsSection: some View {
        let cards = HostedCardPrefs.decodeEnabled(hostedCardsRaw)
        if !cards.isEmpty {
            VStack(spacing: NoopMetrics.sectionGap) {
                ForEach(cards) { card in
                    if let route = card.route {
                        NavigationLink(value: route) { hostedCard(for: card) }
                            .buttonStyle(.plain)
                    } else {
                        hostedCard(for: card)
                    }
                }
            }
        }
    }

    /// Dispatch a hosted card id to its native view. Each case renders the exact view the originating tab
    /// uses, so the Today copy and the home-tab copy never diverge.
    @ViewBuilder
    private func hostedCard(for card: HostedCard) -> some View {
        switch card {
        case .sleepMarks: SleepMarkCard()
        case .trendHRV, .trendRestingHR, .trendEffort:
            // The Trends charts from the SAME resolved points. `HostedTrendData` walks the `days` already
            // in hand, so there is no read behind these and nothing to gate.
            HostedTrendCard(card: card, days: repo.days, effortScale: effortScale)
        case .stressToday:
            // READ-ONLY: the Stress tab keeps the interactive timeline; this is the day's waking hours on
            // the stress scale. Only waking hours score and an hour needs enough heart rate, so early
            // morning is empty by construction.
            hostedStressCard(card)
        case .asleepDuration: AsleepDurationCard(data: AsleepDurationData.build(days: repo.days))
        // The SleepModel-backed cards render from the shared model built in load() (same inputs as the
        // Sleep tab). Until it lands they hold their slot with a placeholder; with no usable night they
        // say so once loading has finished.
        case .stagesVsTypical:
            if let m = hostedSleepModel { StagesVsTypicalCard(model: m) } else { hostedSleepPlaceholder(card) }
        case .nightDetail:
            if let m = hostedSleepModel { NightDetailCard(model: m) } else { hostedSleepPlaceholder(card) }
        case .sleepDebt:
            if let m = hostedSleepModel { SleepDebtLedgerCard(model: m) } else { hostedSleepPlaceholder(card) }
        case .stages:
            if let m = hostedSleepModel { StagesCard(model: m) } else { hostedSleepPlaceholder(card) }
        case .hoursVsNeeded:
            if let m = hostedSleepModel { HoursVsNeededCard(model: m) } else { hostedSleepPlaceholder(card) }
        case .consistency:
            if let m = hostedSleepModel { ConsistencyCard(model: m) } else { hostedSleepPlaceholder(card) }
        }
    }

    /// A SleepModel-backed hosted card before its model exists: the card's title over a compact chart
    /// frame, redacted while loading, "Not enough nights yet." once loading finished with no usable night.
    private func hostedSleepPlaceholder(_ card: HostedCard) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text(card.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if isLoading {
                    ChartPlaceholder(height: NoopMetrics.chartHeightCompact)
                } else {
                    EmptyChartMessage("Not enough nights yet.", height: NoopMetrics.chartHeightCompact)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The hosted "Stress through the day" card: the scored waking hours on the fixed 0–3 stress scale.
    private func hostedStressCard(_ card: HostedCard) -> some View {
        let samples = hostedStressHours.compactMap { hour -> IntradayChart.Sample? in
            guard let level = hour.level else { return nil }
            return IntradayChart.Sample(time: Date(timeIntervalSince1970: TimeInterval(hour.startTs)), value: level)
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let state: ChartState = isLoading ? .loading
            : (samples.isEmpty ? .empty(String(localized: "No waking hours scored yet")) : .ready)
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                TodayCardTitleRow(title: card.title, showsChevron: card.route != nil)
                IntradayChart(samples: samples, bucketSeconds: 3600, color: StrandPalette.stressColor,
                              compact: true, state: state, window: start...end,
                              y: ChartValueAxis(unit: nil, domain: .fixed(0...3), ticks: [0, 1, 2, 3]),
                              selection: .constant(nil), accessibilityTitle: card.title)
            }
        }
        // The card is a link, so the chart passes taps through to it.
        .naraChartScrubDisabled()
    }

    // MARK: - Footer

    /// The two quiet actions at the foot of the page: every screen without a tab (Browse), and the Arrange
    /// sheet for the order and visibility of the sections here.
    private var footerActions: some View {
        HStack(spacing: NoopMetrics.space2) {
            NavigationLink(value: TabRoute.browse) {
                Label("Browse", systemImage: "square.grid.2x2")
            }
            .accessibilityHint(Text("All metrics and tools"))
            Button { customizationDestination = .today } label: {
                Label("Customize Today", systemImage: "slider.horizontal.3")
            }
            .accessibilityHint("Reorder or hide the sections on Today")
        }
        .buttonStyle(TodayQuietActionStyle())
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private func load() async {
        // The loaded-day gate: the day this load is for, marked loaded at the very end (see `loadedDayOffset`).
        let loadingDayOffset = selectedDayOffset
        let repositoryWasLoaded = repo.loaded
        // Resolve the O(days) lookups ONCE here (not on every body re-render): the selected day and the
        // readiness verdict. Both scan repo.days (up to 599 rows); doing it per-render was the stutter.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        cachedReadiness = ReadinessEngine.evaluate(days: repo.days, today: day?.day)
        // Prior-day vitals carry, resolved ONCE here (never in body). Bound to today's own key so it can't
        // echo today's still-forming row; only on today (a past day's own row is the whole story).
        let tkey = cachedDisplayDay?.day ?? selectedDayKey
        cachedVitalsDay = (selectedDayOffset == 0) ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        cachedRespDay = (selectedDayOffset == 0) ? Repository.lastRespDay(days: repo.days, todayKey: tkey) : nil
        cachedHrvDay = (selectedDayOffset == 0) ? Repository.lastHrvDay(days: repo.days, todayKey: tkey) : nil
        cachedRestingHrDay = (selectedDayOffset == 0) ? Repository.lastRestingHrDay(days: repo.days, todayKey: tkey) : nil
        cachedSkinTempReadingDay = (selectedDayOffset == 0) ? Repository.lastSkinTempReadingDay(days: repo.days, todayKey: tkey) : nil
        // Charge carry (#543) + the honest label, resolved here for the same reason as the two above: the
        // selector below scans repo.days. Calibration nights come from the SAME `RecoveryScorer` helper the
        // classic Today reads, so the two screens agree on when a wearer is genuinely mid-calibration
        // rather than simply lacking a scored night.
        let baselineNights = Self.baselineNightlyHrv(days: repo.days, sleeps: repo.sleeps)
        cachedBaselineNights = baselineNights
        let calNights = (selectedDayOffset == 0)
            ? RecoveryScorer.calibrationNights(nightlyHrv: baselineNights.hrv,
                                               dayKeys: baselineNights.dayKeys,
                                               hasRecovery: day?.recovery != nil)
            : nil
        let priorScored = TodayView.lastScoredRecoveryDay(
            days: repo.days, selectedDayKey: tkey,
            isToday: selectedDayOffset == 0,
            todayScored: day?.recovery != nil,
            isCalibrating: calNights != nil
        )
        cachedChargeDisplay = ChargeDisplay.resolve(
            todayRecovery: day?.recovery,
            priorScored: priorScored,
            calibrationNights: calNights,
            todayKey: tkey)

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let calendarFrom = Int(dayStart.timeIntervalSince1970)
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space).
        let calendarTo: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)
        let nextDayKey = Repository.localDayKey(cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
        let cycleMarkers = dayCycleMode == .sleepOnset
            ? await repo.exploreSeries(key: DayCycleIntelligenceIntegration.onsetKey, source: "my-whoop") : []
        let from = cycleMarkers.last(where: { $0.day == selectedDayKey }).map { Int($0.value) } ?? calendarFrom
        let toExclusive = cycleMarkers.last(where: { $0.day == nextDayKey }).map { Int($0.value) } ?? calendarTo
        let to = max(from, toExclusive - 1)
        // #1001: in-progress Effort for TODAY, over the SAME window resolved just above (the day-cycle
        // onset when that mode is on, else calendar midnight → now) with the identical params the daily
        // pass uses, so the live number matches what the engine will eventually persist. Below
        // `StrainScorer.minReadings` the scorer returns nil and the read-outs fall back to the stored row
        // — never a fabricated value. A navigated past day clears it.
        let liveStrainLocal: Double?
        if selectedDayOffset == 0 {
            // An EXPLICIT limit, not the 8000 default: that default is chart-sized, and this read is
            // whole-window. `hrSamples` is `ORDER BY ts ASC LIMIT`, so truncation drops the NEWEST rows —
            // at the ~18k HR rows a real day banks, the default covered roughly the first ten hours and the
            // live score silently stopped climbing after that. It failed safe (`effectiveEffort` takes the
            // max, so the stored row simply won) which is why it went unnoticed. 200_000 is what every
            // other whole-window HR consumer already passes.
            let todayHr = await repo.hrSamples(from: from, to: to, limit: 200_000)
            // #2460: the manual HR-max override, then Tanaka, exactly as AnalyticsEngine resolves it
            // for the STORED day. These two numbers meet in `effectiveEffort`, which takes the larger,
            // so a live value on the formula's yardstick outvoted an override set because the real
            // maximum is above it. See `ProfileStore.effortHRmax`.
            let maxHR = profile.effortHRmax
            let restHR = day?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            liveStrainLocal = StrainScorer.strain(todayHr, maxHR: maxHR, restingHR: restHR,
                                                  method: PuffinExperiment.effortMethod, sex: profile.sex)
        } else {
            liveStrainLocal = nil
        }
        liveTodayStrain = liveStrainLocal

        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        // Queue 11a: SpO₂ candidate fallback (see `spo2CandidateByDay`'s declaration).
        async let spo2CandA = repo.exploreSeries(key: "spo2_candidate", source: "my-whoop")
        async let weightA = repo.series(key: "weight", source: "apple-health", days: 91)
        async let appleA = repo.appleDailyRows()
        async let hrA = repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        async let wkA = repo.workoutRows()
        let restSeries = await restA
        let stepsSeries = await stepsA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Selected day's Rest; tail fallback only at offset 0 (a past day with no row shows nothing) AND
        // only when the tail night is still fresh. #977: a live 5.0 whose sleep never scores (no overnight
        // gravity ⇒ no sleep_performance point ever written) used to pin Rest to the weeks-old series tail
        // forever while Charge advanced; freshness-gate the tail-fallback so a stale tail falls through to
        // the Rest hero's No-Data/calibrating state (same empty treatment Effort uses) instead of freezing.
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)
        let daysSnapshot = repo.days

        // #430 parity: the day-keyed series the DETAILED Key-Metrics tiles graph — a trailing CALENDAR
        // window ending on the selected day (not the last-N stored rows, which on an old import showed
        // months-old data as a fresh trend, issue #23). The loader banks the 30-day SUPERSET; the chosen
        // 1-week/2-week/1-month window filters at render (windowedSpark), so a picker change applies without
        // a reload. Keys mirror the metric catalog so a tile's graph, its tap-through detail and Android's
        // Window all read the same signal. Rest reuses the already-loaded sleep_performance series.
        let sparkCutoff = Repository.localDayKey(cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart)
        let sparkRows = daysSnapshot.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
        // #616: imported-first calorie spark (the day's imported Apple active energy ?: NOOP's on-device
        // estimate) over the window, so a Health-Connect / Apple-only calorie user gets a trend too —
        // matching the imported-first VALUE. Union of imported days + strap-row days. Mirrors Android's
        // caloriesSpark (windowed caloriesByDay).
        let appleRowsForSpark = await appleA
        // Queue 11a: SpO₂ candidate fallback — day-keyed for the tile's value lookup, windowed for its
        // detailed-mode sparkline below (same shape as `restByDay`/`kSparks["spo2"]` above).
        let spo2CandSeries = await spo2CandA
        spo2CandidateByDay = Dictionary(spo2CandSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        var winImportedKcal: [String: Double] = [:]
        for r in appleRowsForSpark where r.day >= sparkCutoff && r.day <= selectedDayKey {
            if let k = r.activeKcal { winImportedKcal[r.day] = max(winImportedKcal[r.day] ?? 0, k) }
        }
        var winOnDeviceKcal: [String: Double] = [:]
        for r in sparkRows { if let k = r.activeKcalEst { winOnDeviceKcal[r.day] = k } }
        let energyKcalSpark: [(String, Double)] = Set(winImportedKcal.keys).union(winOnDeviceKcal.keys).sorted()
            .compactMap { day in (winImportedKcal[day] ?? winOnDeviceKcal[day]).map { (day, $0) } }
        kSparks = [
            "recovery": sparkRows.compactMap { r in r.recovery.map { (r.day, $0) } },
            "strain": sparkRows.compactMap { r in r.strain.map { (r.day, $0) } },
            "hrv": sparkRows.compactMap { r in r.avgHrv.map { (r.day, $0) } },
            "rhr": sparkRows.compactMap { r in r.restingHr.map { (r.day, Double($0)) } },
            "spo2": sparkRows.compactMap { r in r.spo2Pct.map { (r.day, $0) } },
            "spo2_candidate": spo2CandSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey },
            // Added 2026-08-24 (queue 11c follow-up) for the new Skin Temp Key Metrics tile — already
            // loaded on `sparkRows` (`daysSnapshot`), same as every other DailyMetric-column tile above.
            "skin_temp": sparkRows.compactMap { r in r.skinTempDevC.map { (r.day, $0) } },
            "resp_rate": sparkRows.compactMap { r in r.respRateBpm.map { (r.day, $0) } },
            "steps": sparkRows.compactMap { r in r.steps.map { (r.day, Double($0)) } },
            // #616: the Calories tile drew no trend line — this dict had no matching entry, so windowedSpark
            // returned []. Bank the imported-first calorie series (built above) so the sparkline matches the
            // tile's imported-first number and a Health-Connect / Apple-only user gets a trend.
            "energy_kcal": energyKcalSpark,
            "steps_est": stepsSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
            "sleep_performance": restSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
            "weight": (await weightA).filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey },
        ]
        // Steps is a DAILY metric, so key it to the SELECTED day (like restScore above), not the history-wide
        // latest. Without this, swiping to a past day with no strap step count showed today's estimate (the
        // `.last` value) instead of that day's. Mirrors the classic Today's stepsEstByDay[selectedDayKey].
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsEst = stepsByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? stepsSeries.last?.value : nil)
        // Imported Apple Health steps for the SELECTED day (max across rows), the middle tier between the
        // measured strap count and the motion estimate. Health Connect is Android-only, so apple-health is
        // the sole import source on iOS. Mirrors Android `stepsForDay` (#377).
        importedStepsDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.steps }.max()
        // #616: same-day imported active energy — the calorie fallback when the strap banked no on-device
        // HR estimate for the day, so the tile/card/detail agree (imported-first, mirrors steps).
        importedActiveKcalDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.activeKcal }.max()

        // Weight for the SELECTED day: prefers a real Apple-Health reading (today's daily, else the
        // "weight" series' newest point so a sparse-but-recent value still renders). Falls back to the
        // user's profile weight in the renderer (weightTile).
        let appleRows = await appleA
        let weightSeries = await weightA
        weightKg = appleRows.filter { $0.day == selectedDayKey }.compactMap { $0.weightKg }.max()
            ?? weightSeries.last(where: { $0.day <= selectedDayKey })?.value

        // Awaited ONCE: the timestamps and the means have to come from the same read, or the segments
        // would describe a different series than the one drawn.
        let hrBuckets = await hrA
        hrValues = hrBuckets.map { $0.bpm }
        hrSegments = hrGapSegments(bucketTs: hrBuckets.map { $0.ts }, bucketSeconds: 300)
        hrTimes = hrBuckets.map { Double($0.ts) }
        workouts = (await wkA).filter { $0.startTs >= from && $0.startTs < to }

        // #today-hosted-cards: build the shared SleepModel that backs the hosted sleep cards, but ONLY when
        // at least one sleep-origin card is actually hosted — otherwise Today pays no extra Repository cost.
        // The inputs (allSleepSessions / habitualMidsleepSec / sessionMotions) are loaded exactly as the
        // Sleep tab loads them, then handed to the SAME pure `SleepModel.build`, so a hosted card renders
        // numbers byte-identical to the Sleep tab. Reused by every SleepModel-backed hosted card (built once).
        let sleepOrigin = String(localized: "Sleep")
        if HostedCardPrefs.decodeEnabled(hostedCardsRaw).contains(where: { $0.origin == sleepOrigin }) {
            let hostedSessions = await repo.allSleepSessions()
            let hostedHabitual = await repo.habitualMidsleepSec()
            let hostedMotion = await repo.sessionMotions(sessions: hostedSessions)
            hostedSleepModel = SleepModel.build(SleepModelInputs(
                days: repo.days,
                sleeps: repo.sleeps,
                allSessions: hostedSessions,
                importedSleep: repo.importedSleep,
                habitualMidsleepSec: hostedHabitual,
                motionByStart: hostedMotion))
        } else {
            hostedSleepModel = nil
        }

        // #2040: and today's stress, on the same "only when hosted" rule.
        if HostedCardPrefs.decodeEnabled(hostedCardsRaw).contains(.stressToday) {
            let result = await StressDayCurve.today(
                repo: repo,
                personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled
            )?.result
            hostedStressHours = result?.timeline ?? []
            hostedStressActivityMaskedHours = result?.activityMaskedHours ?? 0
        } else {
            hostedStressHours = []
            hostedStressActivityMaskedHours = 0
        }

        // First load done — bring the hero gauges + sky to life now the launch churn has settled.
        if !dataLoaded { withAnimation(.easeIn(duration: 0.4)) { dataLoaded = true } }

        // The strap's own newest skin temperature (today only: a past day has no "now") and this night's SpO₂
        // reading count, straight from the banked samples, so the two tiles do not wait for a nightly score.
        // After the first-paint flip above, and only for a tile that is actually on the grid: the SpO₂ read
        // scans up to a day of per-second rows.
        currentSkinTemp = (selectedDayOffset == 0 && enabledKeyMetrics.contains(.skinTemp))
            ? await repo.currentSkinTemp() : nil
        if enabledKeyMetrics.contains(.bloodOxygen) {
            let night = KeyMetricReadings.spo2NightWindow(dayStart: dayStart, now: Date())
            spo2NightReadings = await repo.spo2Readings(from: night.from, to: night.to)
        } else {
            spo2NightReadings = nil
        }
        // A load superseded by a newer one (a day swipe cancels the old `.task`) leaves the gate to it.
        if !Task.isCancelled {
            loadedDayOffset = loadingDayOffset
            if repositoryWasLoaded { loadedFromRepository = true }
        }
    }

    // MARK: - Derived (sync, off repo.today / repo.days)

    /// Pure aggregation seam for the Liquid hero. The provider mapper names the sensors/imports that
    /// supplied the score inputs; identical names collapse and the compact badge is capped at two.
    static func heroSourceLabel(providers: [ScoreInputProvider]) -> String? {
        var seen = Set<String>()
        var labels: [String] = []
        for provider in providers {
            let label = TodayView.todayScoreProviderLabel(
                sourceId: provider.sourceId,
                brand: provider.brand
            )
            if seen.insert(label).inserted { labels.append(label) }
            if labels.count == 2 { break }
        }
        return labels.isEmpty ? nil : labels.joined(separator: " + ")
    }

    // Measured strap count ?: imported Apple Health count ?: motion estimate — the same precedence the
    // detail routing follows below, so the tapped-through source always matches the number shown (#377).
    private var stepCount: Double? {
        displayDay?.steps.map(Double.init) ?? importedStepsDay.map(Double.init) ?? stepsEst
    }

    private var stepsDetailMetric: MetricDescriptor? {
        MetricCatalog.todayStepsMetric(hasMeasuredSteps: displayDay?.steps != nil,
                                       hasImportedSteps: importedStepsDay != nil)
    }

    private var stepsDetailKey: String { stepsDetailMetric?.key ?? "steps_est" }

    // #616: calories resolved IMPORTED-FIRST (the day's imported Apple active energy, else Nara's on-device
    // HR estimate `activeKcalEst`) — one number across the tile and the detail it taps to.
    private var caloriesCount: Double? {
        importedActiveKcalDay ?? displayDay?.activeKcalEst
    }

    private var caloriesDetailMetric: MetricDescriptor? {
        MetricCatalog.todayCaloriesMetric(hasImportedKcal: importedActiveKcalDay != nil,
                                          hasOnDeviceKcal: displayDay?.activeKcalEst != nil)
    }

    // MARK: - Formatting

    /// What a read-out shows when the metric has no value: the em dash, with no unit (DESIGN_SYSTEM, Copy).
    static let noValueDash = "—"

    /// Join a formatted tile value with its unit, dropping the unit when there is no value.
    ///
    /// #492 and the `–%` it left behind: a missing metric rendered its placeholder AND its unit, so an
    /// empty Strain tile read `–%`, which parses as "minus percent" rather than "no data". Android has
    /// had the guard all along; this is the iOS twin of it. `%` binds tight, every other unit takes a
    /// space. (`MetricTile` applies the same rule to its own value and unit.)
    static func tileDisplayValue(_ value: String, unit: String) -> String {
        guard !unit.isEmpty, value != noValueDash else { return value }
        return unit == "%" ? value + unit : value + " " + unit
    }

    /// A whole-number read-out, or nil for "no value" (the tile and ring draw the dash themselves).
    static func intValue(_ v: Double?) -> String? { v.map { String(Int($0.rounded())) } }

    // °C / °F for the Skin Temp tile, resolved exactly the way the other screens that show a temperature
    // resolve it: the explicit override when set, else derived from the unit system (#1627).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: unitSystem, override: distanceSystemRaw)
    }
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.skinTempDisplayKey) private var skinTempDisplayRaw = ""   // #1846
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }

    // The user's Effort display scale (#268), 0–100 by default or the WHOOP 0–21 axis if chosen — the SAME
    // preference the Workouts screen + Trends read, so a workout's Effort number is identical everywhere.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// The Effort this view should show: the live in-progress score when it beats the stored row, else the
    /// row (#1001). `StrainScorer.effectiveEffort` holds the never-drop floor and the live/stored
    /// preference and is shared with the Kotlin twin, so the two platforms cannot resolve Effort
    /// differently. `d` for today is always today's row or nil, never a prior day.
    private func effortStrain(_ d: DailyMetric?) -> Double? {
        StrainScorer.effectiveEffort(live: selectedDayOffset == 0 ? liveTodayStrain : nil, stored: d?.strain)
    }

    private func effortText(_ s: Double?) -> String {
        guard let s else { return Self.noValueDash }
        // The shared formatter, never a hardcoded *21: one Effort number per workout everywhere.
        return UnitFormatter.effortDisplay(s, scale: effortScale)
    }

    /// "14:05 · 45 min · 5.2 km" for a workout row: the start, the duration, and the distance (or, for a
    /// session with none, the energy). One line; the full breakdown is on the workout's own page.
    private func workoutSub(_ w: WorkoutRow) -> String {
        var parts: [String] = []
        parts.append(AppClock.hourMinuteFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(w.startTs))))
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        parts.append("\(Int(secs / 60)) min")
        if let dm = w.distanceM, dm > 0 {
            parts.append(UnitFormatter.distanceFromMeters(dm, system: distanceUnitSystem))
        } else if let k = w.energyKcal {
            parts.append("\(Int(k.rounded())) kcal")
        }
        return parts.joined(separator: " · ")
    }
}

/// Measures the heart-rate chart in the same coordinate space as the day-swipe gesture.
private struct LiquidHeartRateCardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: - Hero cells

/// One hero cell: a flat ring, the score's name, one state word. The whole cell is one link.
private struct HeroRingCell: View {
    static let ringDiameter: CGFloat = 88

    let label: String
    /// 0…1, nil for no score (the ring draws its track and "—").
    let fraction: Double?
    let value: String
    let color: Color
    let state: String?
    let route: TabRoute
    let isLoading: Bool

    var body: some View {
        NavigationLink(value: route) {
            VStack(spacing: NoopMetrics.space2) {
                ScoreRing(fraction: fraction, value: value, color: color,
                          diameter: Self.ringDiameter, isLoading: isLoading)
                VStack(spacing: NoopMetrics.spaceHalf) {
                    Text(label)
                        .font(StrandFont.subhead.weight(.medium))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    // Reserved when empty, and a representative width while loading, so the card never
                    // changes height.
                    Text(isLoading ? "On track" : (state ?? " "))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .redacted(reason: isLoading ? .placeholder : [])
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .allowsHitTesting(!isLoading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(isLoading ? String(localized: "Loading")
                                 : [ScoreRing.displayValue(fraction: fraction, value: value), state]
                                    .compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text("Opens the trend and readings"))
        .accessibilityAddTraits(.isButton)
    }
}

/// Layer 1 Baseline: how many night vitals sat inside their own usual on the last scored night.
/// Isolated so Today only re-renders this cell when the usuals move.
private struct BaselineHeroCell: View {
    let isLoading: Bool
    @EnvironmentObject private var store: BaselineStore

    var body: some View {
        let check = store.vitalsCheck
        let counted = check?.counted.count ?? 0
        let tint: Color = {
            guard let check, counted > 0 else { return StrandPalette.textTertiary }
            return check.offCount == 0 ? StrandPalette.statusPositive : StrandPalette.statusWarning
        }()
        HeroRingCell(label: String(localized: "Baseline"),
                     fraction: counted > 0 ? check.map { Double($0.inRangeCount) / Double(counted) } : nil,
                     value: check.map { "\($0.inRangeCount)/\(counted)" } ?? LiquidTodayView.noValueDash,
                     color: tint,
                     state: Self.stateWord(check),
                     route: .baselineCharts,
                     isLoading: isLoading)
    }

    /// One short word for the night: in range, how many vitals sit off their usual, or why there is no
    /// count yet. The count itself is inside the ring.
    static func stateWord(_ check: BaselineVitalsCheck?) -> String {
        guard let check else { return String(localized: "No data") }
        guard !check.counted.isEmpty else {
            return check.vitals.contains { $0.state == .learning }
                ? String(localized: "Learning") : String(localized: "No reading")
        }
        return check.offCount == 0
            ? String(localized: "In range")
            : String(localized: "\(check.offCount) off usual")
    }
}

/// Live Watchdog: the ring fills with how far the last half-hour is from the usual, full at the severe cut.
private struct WatchdogHeroCell: View {
    let isLoading: Bool
    @EnvironmentObject private var store: BaselineStore

    var body: some View {
        let state = HeroRings.watchdogState(store.watchdogResult)
        let distance = HeroRings.watchdogDistance(store.watchdogResult)
        HeroRingCell(label: String(localized: "Watchdog"),
                     fraction: distance.map { $0 / 100 },
                     value: LiquidTodayView.intValue(distance) ?? LiquidTodayView.noValueDash,
                     color: WatchdogTone.color(state),
                     state: HeroRings.watchdogLabel(state),
                     route: .watchdog,
                     isLoading: isLoading)
    }
}

/// Keeps `BaselineStore.vitalsCheck` fresh on every data refresh. It used to ride on the Baseline cell,
/// which made it the only refresh outside the Monitor tab; on its own always-mounted view it keeps
/// running when the hero is hidden. Draws nothing.
private struct BaselineVitalsRefresher: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var store: BaselineStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: repo.refreshSeq) { store.refreshVitalsCheck(days: repo.days) }
    }
}

// MARK: - Heart-rate card

/// The day's heart rate: title row (live value or the scrubbed reading, chevron), the 5-minute means on a
/// clock axis with a bpm value axis and the resting rate as a labelled dashed rule, and Resting / High /
/// Low. The secondary chart height, not the compact form: the compact form drops the value axis, and a
/// heart-rate line without its bpm scale is decoration. The chart scrubs (a
/// sideways drag on iPhone, the pointer on the Mac); the title row and the figures open the full day.
private struct TodayHeartRateCard: View {
    let times: [Double]
    let values: [Double]
    let resting: Int?
    let isToday: Bool
    let window: ClosedRange<Date>
    let isLoading: Bool
    let frameSpace: String

    @State private var selection: Date?

    private var samples: [IntradayChart.Sample] {
        zip(times, values).map { IntradayChart.Sample(time: Date(timeIntervalSince1970: $0), value: $1) }
    }

    private var chartState: ChartState {
        if isLoading { return .loading }
        if values.isEmpty {
            return .empty(isToday ? String(localized: "No heart rate yet today")
                                  : String(localized: "No heart rate this day"))
        }
        return .ready
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                NavigationLink(value: TabRoute.heartRateDay) {
                    TodayCardTitleRow(title: String(localized: "Heart rate")) { readout }
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the full-day heart rate graph with an activity timeline"))

                IntradayChart(samples: samples, bucketSeconds: 300, color: StrandPalette.metricRose,
                              references: resting.map { [ChartReference(Double($0), label: String(localized: "Resting"))] } ?? [],
                              state: chartState, window: window,
                              y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)),
                              selection: $selection, height: NoopMetrics.chartHeightSecondary,
                              accessibilityTitle: isToday ? String(localized: "Heart rate today")
                                                          : String(localized: "Heart rate"))
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: LiquidHeartRateCardFrameKey.self,
                                                   value: geometry.frame(in: .named(frameSpace)))
                        }
                    }

                NavigationLink(value: TabRoute.heartRateDay) { stats }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the full-day heart rate graph with an activity timeline"))
            }
        }
        // A new day (or the first load) starts unselected.
        .onChangeCompat(of: window) { _ in selection = nil }
    }

    /// The header's value: the reading under the finger while scrubbing, else the live heart rate while the
    /// strap streams today, else nothing (the figures below carry the day).
    @ViewBuilder
    private var readout: some View {
        if let selection, let index = ChartSelection.nearestIndex(to: selection, in: samples.map(\.time)) {
            let sample = samples[index]
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(AppClock.hourMinuteFormatter().string(from: sample.time))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                (Text("\(Int(sample.value.rounded()))").font(StrandFont.headline).monospacedDigit()
                    + Text(" bpm").font(StrandFont.subhead).foregroundColor(StrandPalette.textSecondary))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .transaction { $0.animation = nil }
        } else if isToday {
            LiveHeartRateValue()
        }
    }

    private var stats: some View {
        HStack(spacing: NoopMetrics.space2) {
            statCell(String(localized: "Resting"), resting.map(Double.init))
            statCell(String(localized: "High"), values.max())
            statCell(String(localized: "Low"), values.min())
        }
        .loadingRedaction(isLoading)
        .accessibilityElement(children: .combine)
    }

    private func statCell(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Group {
                if let value {
                    Text("\(Int(value.rounded()))").font(StrandFont.number(20)).monospacedDigit()
                        + Text(" bpm").font(StrandFont.subhead).foregroundColor(StrandPalette.textSecondary)
                } else {
                    Text(verbatim: LiquidTodayView.noValueDash).font(StrandFont.number(20))
                }
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopInsetSurface())
    }
}

/// The live heart rate beside the card title, while the strap streams. Owns LiveState so the ~1 Hz HR
/// notifies re-render only this label, never the card or Today. The dot is static: the number moving is
/// the live signal.
private struct LiveHeartRateValue: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        if live.connected, let hr = live.heartRate, hr > 0 {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Circle()
                    .fill(StrandPalette.metricRose)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                (Text("\(hr)").font(StrandFont.headline).monospacedDigit()
                    + Text(" bpm").font(StrandFont.subhead).foregroundColor(StrandPalette.textSecondary))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(hr) bpm"))
        }
    }
}

/// A card's title row: the title (headline), an optional trailing value, and a chevron when the row
/// navigates. One look for every tappable card on Today.
private struct TodayCardTitleRow<Trailing: View>: View {
    let title: String
    var showsChevron: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Text(title)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: NoopMetrics.space2)
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
    }
}

private extension TodayCardTitleRow where Trailing == EmptyView {
    init(title: String, showsChevron: Bool = true) {
        self.init(title: title, showsChevron: showsChevron, trailing: { EmptyView() })
    }
}


// MARK: - Strap row

/// The one strap line on Today, and only when there is something to say: the charge of the active device
/// (`StrapBatteryDisplay.resolve`, the tested truth table), a history sync in progress (B1: a multi-hour
/// recovery must be visible on the default Today), a refused bond, or when history last synced. Owns
/// LiveState; display-only. Taps open Devices.
private struct TodayStrapRow: View {
    @EnvironmentObject private var live: LiveState
    @EnvironmentObject private var router: NavRouter

    private struct Line {
        let icon: String
        let iconColor: Color
        let title: LocalizedStringKey
        let subtitle: String?
        let value: String?
        let tone: StrandTone
    }

    private var line: Line? {
        let battery = LiquidTodayView.StrapBatteryDisplay.resolve(
            activeIsWhoop: live.activeIsWhoop, connected: live.connected,
            batteryPct: live.batteryPct, charging: live.charging,
            ringPct: live.ouraBatteryPct, ringCharging: live.ouraWearState == .charging)
        let synced = live.lastSyncedAt.map { String(localized: "Synced \(relativeAgo($0))") }
        if live.backfilling {
            return Line(icon: "arrow.triangle.2.circlepath", iconColor: StrandPalette.accent, title: "Strap",
                        subtitle: nil, value: String(localized: "Syncing history…"), tone: .accent)
        }
        if live.connected, live.pairingHint != nil {
            // The bond was refused: history can't sync until the strap is re-paired (how-to on Devices).
            return Line(icon: "exclamationmark.triangle", iconColor: StrandPalette.statusWarning, title: "Strap",
                        subtitle: nil, value: String(localized: "Re-pair to sync"), tone: .warning)
        }
        switch battery {
        case .charge(let pct, let charging, let isRing):
            return Line(icon: Self.batterySymbol(pct: pct, charging: charging), iconColor: StrandPalette.textSecondary,
                        title: isRing ? "Ring" : "Strap", subtitle: isRing ? nil : synced,
                        value: chargeText(pct: pct, charging: charging, isRing: isRing), tone: .neutral)
        case .offline, .pending, .notActiveDevice:
            guard live.activeIsWhoop, let synced else { return nil }
            return Line(icon: "arrow.triangle.2.circlepath", iconColor: StrandPalette.textSecondary, title: "Strap",
                        subtitle: nil, value: synced, tone: .neutral)
        }
    }

    var body: some View {
        if let line {
            NoopCard(padding: 0) {
                Button { router.openDevices() } label: {
                    NoopListRow(icon: line.icon, iconColor: line.iconColor, title: line.title,
                                subtitle: line.subtitle, value: line.value, valueTone: line.tone)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "87 %" plus "· Charging" (#972) or the "~9 days left" runtime (#992), matching the Settings / Mac /
    /// Android pill and the classic Today badge.
    private func chargeText(pct: Double, charging: Bool, isRing: Bool) -> String {
        let base = "\(Int(pct.rounded())) %"
        if charging { return "\(base) · \(String(localized: "Charging"))" }
        if !isRing, let est = estimateText { return "\(base) · \(est)" }
        return base
    }

    /// #992, verbatim from `TodayView.estimateText`: under 48 h show hours, at two days or more round to
    /// days; nil (no banked discharge yet, or charging) hides it, so the row only shows an estimate we trust.
    private var estimateText: String? {
        guard live.charging != true, let est = live.batteryEstimate else { return nil }
        let hours = est.hoursRemaining
        guard hours.isFinite, hours > 0 else { return nil }
        if hours < 48 {
            return String(localized: "~\(Int(hours.rounded()))h left")
        }
        let days = Int((hours / 24).rounded())
        return days == 1
            ? String(localized: "~1 day left")
            : String(localized: "~\(days) days left")
    }

    private static func batterySymbol(pct: Double, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// The footer's quiet actions: accent text in the label role with its symbol, a 44 pt target, no fill.
private struct TodayQuietActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.subhead.weight(.medium))
            .foregroundStyle(StrandPalette.accent)
            .padding(.horizontal, NoopMetrics.space3)
            .frame(minHeight: NoopMetrics.minimumHitTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? NoopButtonMetrics.pressedOpacity : 1)
    }
}

// MARK: - Cross-platform chrome helpers

private extension View {
    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func liquidPopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }
}

extension LiquidTodayView {
    /// What the strap-battery ring can honestly say, resolved from the three live signals it has.
    /// Pure + static so the truth table is testable with no strap (`LiquidBatteryDisplayTests`).
    ///
    /// The three signals are INDEPENDENT and land separately, which is the whole reason this exists:
    ///  • `connected` — the CoreBluetooth link.
    ///  • `batteryPct` — standard 0x2A19 (5/MG) or the GET_BATTERY_LEVEL response (4.0).
    ///  • `charging` — a different source entirely: the strap's BATTERY_LEVEL event (~every 8 min),
    ///    which keeps arriving live even mid-offload (`FrameRouter`, "flag only — battery % keeps its
    ///    family-specific source", #77).
    ///
    /// So "charging, but no % yet" is REACHABLE, not hypothetical. The old code nested the bolt inside
    /// `if let pct`, so that state rendered as `bolt.slash` — a crossed-out bolt at a wearer whose strap
    /// was on the charger, which reads as "battery dead". And it drew the ring on `batteryPct` alone with
    /// no `connected` gate: `LiveState.batteryPct` is never cleared (`clearBiometrics` deliberately leaves
    /// it), so a dead strap kept showing its last % as if live — a 21 h old reading rendered identically
    /// to a fresh one. Gating on `connected` here also makes this ring agree with `LiquidStrapBatteryRow`
    /// directly below it, which already required `live.connected`.
    /// The Effort hero's "no cardio load yet" honest note (#530 follow-up — Liquid parity with classic
    /// `TodayView.effortZeroNote`). Pure + static so the gate is testable with no view: the note shows
    /// ONLY for today when a strain value exists and is ~0 — a genuinely calm day reads near zero, while a
    /// no-data day shows its own ring overlay and a past day is never annotated. The caller passes
    /// `effortStrain(displayDay)` — the SAME resolved value the Effort hero draws (#1001) — so the note
    /// and the hero can never disagree about whether today is at zero.
    enum EffortDisplay {
        static func showsZeroNote(strain: Double?, isToday: Bool) -> Bool {
            guard isToday, let s = strain else { return false }
            return s < 1.0
        }
    }

    /// (A3/B2, docs/bugs/2026-07-15-strap-battery-backfill-observability.md)
    enum StrapBatteryDisplay: Equatable {
        /// No link — say nothing about charge. A stale % is worse than no %.
        case offline
        /// Linked, but no charge reading has landed yet. `charging` is still knowable on its own.
        case pending(charging: Bool)
        /// A reading from the current link. `isRing` says whose: the ring's own charge under an active
        /// ring, the strap's under an active strap — the label names the device the number belongs to.
        case charge(pct: Double, charging: Bool, isRing: Bool)
        /// The active device is neither the strap nor a ring that has reported its charge this link, so
        /// this control has nothing to say and is not drawn.
        ///
        /// Distinct from [offline], which asserts a strap that IS active is not connected. Collapsing the
        /// two put a crossed-out bolt and "strap not connected" on the header of a wearer whose ring was
        /// streaming, which is a different false claim from the one #2208 is about rather than a fix for
        /// it, and the only one a ring-only wearer would see every day. (@pipiche38 on #2216)
        case notActiveDevice

        /// #2208: `activeIsWhoop` is required, not defaulted. `connected` alone was never enough: it is
        /// true the moment ANY source streams, `batteryPct` is the strap's and is never cleared, so under
        /// an active ring both halves of the old gate passed and this drew the strap's charge. Charging
        /// is strap-only for the same reason, so a non-WHOOP active device reports neither of the strap's.
        ///
        /// A ring reports its OWN charge into `ringPct` (`LiveState.ouraBatteryPct`), cleared with the
        /// link, so under a non-WHOOP active device a non-nil `ringPct` is a reading from the ring that is
        /// live right now and is drawn as such; nil (no ring, or none has reported yet) keeps the control
        /// off the header. `ringCharging` is the ring's charger state (`OuraWearState.charging`), the only
        /// charging evidence a ring gives. Same resolution `LiveConsoleReadout.batteryPercent` applies.
        ///
        /// No default values on purpose. A defaulted flag is one a future call site can forget, and
        /// forgetting it reinstates exactly this bug in a form that still compiles.
        static func resolve(activeIsWhoop: Bool, connected: Bool,
                            batteryPct: Double?, charging: Bool?,
                            ringPct: Int?, ringCharging: Bool) -> StrapBatteryDisplay {
            guard activeIsWhoop else {
                guard let ringPct else { return .notActiveDevice }
                return .charge(pct: Double(ringPct), charging: ringCharging, isRing: true)
            }
            guard connected else { return .offline }
            guard let pct = batteryPct else { return .pending(charging: charging == true) }
            return .charge(pct: pct, charging: charging == true, isRing: false)
        }
    }

    /// Per-night HRV for the "N of 4 nights" baseline count. The scored daily rows alone under-count: a night
    /// whose sleep session was banked (with its HRV) but whose daily row is still an unscored stub reads as
    /// "no HRV", so the card said "Learning, 3 of 4" while the scorer had four usable nights. Banked sessions
    /// fill only the days whose row carries no HRV, so a scored row always wins.
    static func baselineNightlyHrv(days: [DailyMetric],
                                   sleeps: [CachedSleepSession]) -> (hrv: [Double?], dayKeys: [String]) {
        var byDay: [String: Double] = [:]
        var keys = Set(days.map(\.day))
        for d in days { if let h = d.avgHrv, h > 0 { byDay[d.day] = h } }
        var longest: [String: (len: Int, hrv: Double)] = [:]
        for s in sleeps {
            guard let h = s.avgHrv, h > 0 else { continue }
            let key = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            keys.insert(key)
            let len = s.endTs - s.startTs
            if len > (longest[key]?.len ?? 0) { longest[key] = (len, h) }
        }
        for (key, entry) in longest where byDay[key] == nil { byDay[key] = entry.hrv }
        let ordered = keys.sorted()
        return (ordered.map { byDay[$0] }, ordered)
    }

    /// What the Charge hero can honestly say for the selected day. Pure + static so the truth table is
    /// testable with no clock and no view (`LiquidChargeCarryTests`).
    ///
    /// See `LiquidChargeCarryTests` for the regression this closes: Liquid read `displayDay?.recovery`
    /// raw, so after the 04:00 rollover — or on any day with no scored night — Charge blanked while the
    /// Rest hero (`freshRestScore`) and the vitals (`Repository.lastVitalsDay`) carried right beside it,
    /// and the widget/watch/Live Activity (`Repository.widgetAnchor`, #911) all showed a number.
    ///
    /// The SELECTION is not re-implemented here: callers pass the row `TodayView.lastScoredRecoveryDay`
    /// picked (its #547 future-day guard included) and the caption comes from `TodayView.carriedCaption`,
    /// so the two Today screens cannot drift apart.
    enum ChargeDisplay: Equatable {
        /// The selected day scored its own Charge.
        case scored(pct: Double)
        /// No score for the selected day; showing a REAL prior night's, stamped with whose it is.
        case carried(pct: Double, caption: String)
        /// Pre-seed-gate: the baseline is still learning and owns its own "N of 4 nights" copy.
        case calibrating(nights: Int)
        /// Nothing honest to show — no score, no prior night, and not calibrating.
        case noData

        /// The number the hero vessel draws, or nil for the honest empty state. A carry draws the REAL
        /// prior value; the empty states draw nothing rather than a fabricated zero.
        var pct: Double? {
            switch self {
            case .scored(let p): return p
            case .carried(let p, _): return p
            case .calibrating, .noData: return nil
            }
        }

        /// The short Charge-state pill beside the greeting. It shares a row with the greeting under a
        /// `fixedSize`, so it stays SHORT — the carried day's full "Last night · <date>" stamp lives in
        /// `caption`, not here. Only `.calibrating` may say "Calibrating": the pill used to key off
        /// `recovery != nil` and so claimed a calibrating baseline on every unscored day, including a
        /// trusted wearer who simply hadn't worn the strap that night.
        var stateLabel: String {
            switch self {
            case .scored: return String(localized: "Solid")
            case .carried: return String(localized: "Last night")
            case .calibrating: return String(localized: "Calibrating")
            case .noData: return String(localized: "No data")
            }
        }

        /// The synthesis-card detail line while the baseline is still forming — the same "N of
        /// `Baselines.minNightsSeed` nights" progress classic `TodayView.calibrationDetail` surfaces, so a
        /// wearer in their first few nights reads identical calibration copy on both Today screens (before
        /// this, Liquid dropped the count and showed a bare "Calibrating"). Non-nil ONLY for `.calibrating`:
        /// the compact greeting pill stays short ("Calibrating") because it shares a `fixedSize` row with
        /// the greeting, so the count lives here in the card, exactly as classic keeps it out of its
        /// `ScoreStatePill`. Reuses classic's String Catalog key verbatim — one entry serves both screens.
        var calibrationDetail: String? {
            guard case .calibrating(let nights) = self else { return nil }
            return String(localized: "Learning your baseline, \(nights) of \(Baselines.minNightsSeed) nights.")
        }

        /// The reason half, when nights are arriving but most carry no HRV (see `TodayView`'s twin). Nil
        /// when every observed night counted, so a healthy calibration says nothing extra.
        func calibrationReason(dayKeys: [String], nightlyHrv: [Double?], today: String) -> String? {
            guard case .calibrating = self else { return nil }
            let cov = Baselines.recentHrvCoverage(dayKeys: dayKeys, nightlyHrv: nightlyHrv, today: today)
            guard cov.missing > 0, cov.observed > 0 else { return nil }
            return String(localized: "\(cov.missing) of the last \(cov.observed) nights recorded no HRV. Check the strap is worn overnight and syncing.")
        }

        static func resolve(todayRecovery: Double?, priorScored: DailyMetric?,
                            calibrationNights: Int?, todayKey: String) -> ChargeDisplay {
            if let pct = todayRecovery { return .scored(pct: pct) }
            // Calibration owns its own copy and beats the carry — mid-calibration there is no trustworthy
            // prior score to stand in. Mirrors `lastScoredRecoveryDay`, which returns nil when calibrating.
            if let n = calibrationNights { return .calibrating(nights: n) }
            // `lastScoredRecoveryDay` only ever selects a row whose recovery is non-nil, so the second bind
            // is belt-and-suspenders: a nil falls through to noData rather than fabricating a carry.
            guard let prior = priorScored, let pct = prior.recovery else { return .noData }
            return .carried(pct: pct,
                            caption: TodayView.carriedCaption(priorDayKey: prior.day, todayKey: todayKey))
        }
    }
}
