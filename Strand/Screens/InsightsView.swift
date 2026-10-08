import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Insights
//
// The headline "interrogate what affects what" screen. Two halves:
//
//  1. BEHAVIOUR EFFECTS, split your logged journal answers (Alcohol, Caffeine,
//     Late meal, Meditation…) into the days each behaviour WAS logged vs NOT, then
//     compare a chosen outcome metric (Recovery / HRV / Sleep performance / RHR)
//     between the two groups. Ranked by effect size (Cohen's d) with significant
//     effects first; each card carries the plain-English sentence, the with/without
//     means, group counts, a significance pill, and the effect-size magnitude.
//     Tint is sign-aware: a behaviour that moves the outcome the "good" way
//     (respecting higherIsBetter) is positive/green, the "bad" way is critical/red.
//
//  2. METRIC RELATIONSHIPS, a curated set of Pearson correlations between daily
//     series (sleep ↔ recovery, today's strain ↔ next-day recovery via a 1-day lag,
//     HRV ↔ recovery, RHR ↔ recovery), each rendered as a one-line insight with r
//     and a plain-English reading of strength + direction.
//
// All math comes from StrandAnalytics (BehaviorInsights / CorrelationEngine); this
// view only loads the series, shapes them, and presents. Empty state via ComingSoon
// when there is no journal data to interrogate.

/// `.task(id:)` key for the Insights journal load: the data-refresh sequence plus today's day-key, so the
/// load re-runs both on a data change and on a calendar-day rollover (#860 item 4).
private struct InsightsLoadKey: Equatable {
    let seq: Int
    let dayKey: String
}

/// #833 (Insights freeze): the snapshot InsightsView.load() builds, parked on the long-lived Repository so a
/// re-mount (macOS keys the NavigationSplitView detail with `.id`, so every sidebar switch cold-mounts the
/// screen) can RESTORE it in-memory instead of re-running the full history read on the @MainActor. The exact
/// twin of Today's `TodayHistoryWideCache` for #849; holds load()'s six computed outputs. Consumed only when
/// the seq AND the dayKey still match (see `Repository.insightsLoadedSeq` / `insightsLoadedDayKey`).
struct InsightsLoadCache {
    let behaviours: [String: Set<String>]
    /// Per behaviour, the days it was logged NO. Cached alongside `behaviours` because a restore that
    /// dropped it would leave the ranker with no controls and silently produce no insights at all.
    let controls: [String: Set<String>]
    let importedQuestions: [String]
    let dayAnswers: [String: Bool]
    /// The journal day offset the `dayAnswers` were read for (0 = today, 1 = yesterday, -1 = tomorrow). The
    /// restore guards on it so a re-mount, which resets `journalDayOffset` to 0, only reuses the cache when
    /// the cached answers match that reset day, otherwise it falls through to a fresh read (#833).
    let journalDayOffset: Int
    let outcomeByKey: [String: [String: Double]]
    let seriesByKey: [String: [(day: String, value: Double)]]
    let activityCosts: [ActivityCost]
    /// #322: per-question numeric journal series (question → [day: value]) for numeric journal items
    /// (e.g. "caffeine mg", "alcohol units"). A numeric series feeds the same effect ranker the metric
    /// outcomes do, so a numeric behaviour can rank in Insights. Empty for a yes/no-only journal.
    let numericJournalByKey: [String: [String: Double]]
}

struct InsightsView: View {
    @EnvironmentObject var repo: Repository
    /// Deep-link into the v5 "What moves you" hub (the n-of-1 ranked-effect + dose-response surface).
    @EnvironmentObject var router: NavRouter
    /// #860 item 4: foreground signal for the day-rollover re-load (see `currentDayKey`).
    @Environment(\.scenePhase) private var scenePhase

    // MARK: Selected outcome (segmented)

    /// One interrogable outcome metric: how to fetch it and how to read its direction.
    enum Outcome: String, CaseIterable, Identifiable {
        case recovery, hrv, sleep, rhr
        var id: String { rawValue }

        /// Short segment label.
        var label: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return "RHR"
            }
        }
        /// The metricSeries key (source is always "my-whoop" for these).
        var key: String {
            switch self {
            case .recovery: return "recovery"
            case .hrv:      return "hrv"
            case .sleep:    return "sleep_performance"
            case .rhr:      return "rhr"
            }
        }
        /// The human outcome name used by BehaviorInsights.sentence.
        var outcomeName: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return String(localized: "Resting HR")
            }
        }
        /// Whether a higher value is the "good" direction (drives tint).
        var higherIsBetter: Bool {
            switch self {
            case .recovery, .hrv, .sleep: return true
            case .rhr:                    return false
            }
        }
        /// The Bevel colour world each outcome belongs to, Charge→green, HRV→Rest
        /// (periwinkle, the HRV world), Rest→indigo, RHR→Stress (teal). Drives the
        /// section's domain accent + the segmented selection's wash.
        var domain: DomainTheme {
            switch self {
            case .recovery: return .charge
            case .hrv:      return .rest
            case .sleep:    return .rest
            case .rhr:      return .stress
            }
        }
    }

    /// One personal-experiment window length (and the matching baseline span).
    private enum ExperimentLength: Int, CaseIterable, Identifiable {
        case oneWeek = 7
        case twoWeeks = 14
        case fourWeeks = 28

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .oneWeek:  return String(localized: "7d")
            case .twoWeeks: return String(localized: "14d")
            case .fourWeeks: return String(localized: "28d")
            }
        }
    }

    @State private var outcome: Outcome = .recovery

    // MARK: Personal-experiment state (LOCAL ONLY, UserDefaults-backed, single user)
    //
    // A running n-of-1 plan: one behaviour, one outcome, a short window. All five
    // keys mirror the Android SharedPreferences keys (InsightsScreen.kt) for parity.
    @AppStorage("noop.experiment.behaviour")    private var experimentBehaviour = ""
    @AppStorage("noop.experiment.outcome")      private var experimentOutcomeRaw = Outcome.recovery.rawValue
    @AppStorage("noop.experiment.startedDay")   private var experimentStartedDay = ""
    @AppStorage("noop.experiment.durationDays") private var experimentDurationDays = ExperimentLength.twoWeeks.rawValue
    @AppStorage("noop.experiment.baselineDays") private var experimentBaselineDays = ExperimentLength.twoWeeks.rawValue

    /// The journal catalog, read for `hiddenQuestions` so a behaviour the user has
    /// hidden never resurfaces as an eligible experiment candidate (triage fix b).
    @StateObject private var catalog = JournalCatalogStore()

    // MARK: Loaded state

    /// behaviour question → set of days where it was answered yes.
    @State private var behaviours: [String: Set<String>] = [:]
    /// Per behaviour, the days it was logged NO — the only legitimate control group.
    @State private var controls: [String: Set<String>] = [:]
    /// outcome key → [day: value].
    @State private var outcomeByKey: [String: [String: Double]] = [:]
    /// outcome key → ordered (day, value) series for correlations.
    @State private var seriesByKey: [String: [(day: String, value: Double)]] = [:]
    /// #322: numeric journal item (question) → [day: value]. A numeric journal series is a daily
    /// series the effect ranker can consume exactly like a metric series (it already ranks metrics),
    /// so "caffeine mg" / "alcohol units" can rank as a numeric outcome in Insights. Empty for a
    /// yes/no-only journal.
    @State private var numericJournalByKey: [String: [String: Double]] = [:]
    @State private var loaded = false

    // MARK: Memoized derived state
    //
    // The ranking and correlations are expensive (BehaviorInsights.rank +
    // four Pearson correlations) and were previously recomputed inside `body`
    // on EVERY render, including hover/animation/1Hz HR ticks. Cache them in
    // @State and recompute only when their inputs change.

    /// Ranked behaviour effects for the current outcome, recomputed via
    /// recomputeRanked() only when behaviours / outcomeByKey / outcome change.
    @State private var ranked: [BehaviorEffect] = []
    /// Curated metric relationships, recomputed via recomputeRelationships()
    /// only when the loaded series change.
    @State private var relationships: [Relationship] = []

    private let outcomeKeys = ["recovery", "hrv", "sleep_performance", "rhr"]

    // MARK: Native-logging state for the journal card

    /// Ranked activity-recovery costs (#439). Computed at load via ActivityCostEngine over the tagged
    /// activity days and daily Charge; empty when nothing clears the engine's minSessions gate.
    @State private var activityCosts: [ActivityCost] = []

    /// Distinct imported question strings, so the card adopts the export's exact wording.
    @State private var importedQuestions: [String] = []
    /// The selected day's native answers (question → answeredYes), drives the chip state.
    @State private var dayAnswers: [String: Bool] = [:]
    /// The selected day's native numeric values (question → value), drives the numeric fields (#322).
    @State private var dayNumeric: [String: Double] = [:]
    /// -1 = tomorrow (log ahead), 0 = today, 1 = yesterday (late logging).
    @State private var journalDayOffset = 0
    /// #860 item 4: today's local calendar-day key, captured on appear and refreshed on foreground. The
    /// journal day chips ("Today"/"Yesterday"/"Tomorrow") are relative to the CURRENT date, but the
    /// answers (`dayAnswers`) and the resolved day key are derived from `Date()` only inside `load()`,
    /// which re-runs on `repo.refreshSeq`. A day can pass with the screen alive and no data refresh (the
    /// app simply backgrounded overnight), so without re-keying on this the previous day's answers stayed
    /// pinned under "Today" instead of the new day starting blank. Folding it into the `.task(id:)` key
    /// re-runs the load the moment the date rolls over, so "Today" always resolves to the live day and
    /// prior answers move to their real date. Local CALENDAR day (matches the journal's `localDayKey`).
    @State private var currentDayKey = Repository.localDayKey(Date())

    var body: some View {
        // The journal: logging first (always reachable, the account-free way in), then one list of what
        // the journal shows, each a page one tap down. The ranked behaviour effects live on What moves
        // you (the lag-aware ranking), so this page does not draw a second, same-day list of them.
        ScreenScaffold(title: "Insights", titleDisplay: .navigationBar, isLoading: !loaded) {
            JournalLogCard(importedQuestions: importedQuestions,
                           answers: dayAnswers,
                           numericAnswers: dayNumeric,
                           dayOffset: $journalDayOffset,
                           onChanged: { Task { await load() } })
            // Mind, daily mood check-in + mood↔body correlations. Self-contained (owns its own
            // load/state); sits with the journal card so the two daily-logging surfaces read as one
            // "log today" block above the derived insights.
            MindSection()
            // Caffeine window (#526), log an intake + a rough on-device "still active" hint.
            // Self-contained (owns its own UserDefaults-backed store). Opt-in: shows nothing until the
            // user logs an intake.
            CaffeineLogCard()
            journalInsightsSection
        }
        // #860 item 4: key on the data-refresh seq AND today's day-key, so the journal re-loads both on a
        // data change and the moment the calendar day rolls over (driven by the foreground/appear refresh
        // of `currentDayKey` below), so yesterday's answers leave "Today" and the new day starts fresh.
        .task(id: InsightsLoadKey(seq: repo.refreshSeq, dayKey: currentDayKey)) { await load(allowCache: true) }
        // Recompute the cached ranking only when the outcome selection changes.
        // (behaviours / outcomeByKey change only at load, which calls
        //  recomputeRanked() directly, so keying on `outcome` is sufficient.)
        .onChangeCompat(of: outcome) { _ in recomputeRanked() }
        // Refresh the day anchor on appear and whenever the app returns to the foreground; if the date has
        // advanced this bumps the `.task(id:)` key and the journal reloads for the new logical day (#860).
        .onAppear {
            refreshCurrentDayKey()
            // #656: honour a day the Today journal widget deep-linked to (tapping a bar opens the journal
            // at THAT day). Consumed once on arrival, then cleared. Reload explicitly — setting the offset
            // here doesn't run the pill's onChanged, and the `.task` keys on the day-key, not the offset.
            if let day = router.pendingJournalDayOffset {
                journalDayOffset = day
                router.pendingJournalDayOffset = nil
                Task { await load() }
            }
        }
        .onChangeCompat(of: scenePhase) { phase in
            if phase == .active { refreshCurrentDayKey() }
        }
    }

    /// Re-stamp `currentDayKey` to today's local calendar day. A no-op while the day is unchanged; when the
    /// date has rolled over it flips the value, which re-keys the journal load so the chips' "Today" and the
    /// answers behind them snap to the new day (#860 item 4).
    private func refreshCurrentDayKey() {
        let key = Repository.localDayKey(Date())
        if key != currentDayKey { currentDayKey = key }
    }

    // MARK: - What the journal shows (rows, each one tap down)

    private var journalInsightsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Patterns")
            NoopListSection {
                whatMovesYouRow
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                InsightsDetailLink { experimentPage } label: {
                    NoopListRow(icon: "flask", iconColor: StrandPalette.accent, title: "Personal experiment",
                                value: activeExperimentSnapshot?.phaseLabel ?? String(localized: "Setup"))
                }
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                InsightsDetailLink { activityCostPage } label: {
                    NoopListRow(icon: "figure.run", iconColor: StrandPalette.accent, title: "Activity cost",
                                value: activityCosts.isEmpty ? nil : "\(activityCosts.count)")
                }
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                InsightsDetailLink { relationshipsPage } label: {
                    NoopListRow(icon: "point.3.connected.trianglepath.dotted", iconColor: StrandPalette.accent,
                                title: "Metric relationships",
                                value: relationships.isEmpty ? nil : "\(relationships.count)")
                }
            }
        }
    }

    /// What moves you: the lag-aware ranked effects and the dose-response, pushed inside the journal's own
    /// stack on iOS (the journal is itself a sheet, so a router hop would try to stack a second sheet on
    /// the same root). The Mac selects its sidebar item.
    @ViewBuilder
    private var whatMovesYouRow: some View {
        #if os(macOS)
        Button { router.openInsightsHub() } label: {
            NoopListRow(icon: "wand.and.sparkles", iconColor: StrandPalette.accent, title: "What moves you")
        }
        .buttonStyle(.plain)
        #else
        NavigationLink { InsightsHubView() } label: {
            NoopListRow(icon: "wand.and.sparkles", iconColor: StrandPalette.accent, title: "What moves you")
        }
        .buttonStyle(.plain)
        #endif
    }

    // MARK: - Load

    /// Load the journal + outcome series + activity costs.
    ///
    /// #833 (Insights freeze): on macOS the NavigationSplitView detail is keyed with `.id` (RootView), so
    /// every sidebar switch DESTROYS and cold-mounts this view, tearing down its `@State`. Without a cache
    /// each visit re-ran the full history read on the @MainActor, which is the freeze. Mirroring Today's #849
    /// remount cache, when `allowCache` is set and the live data state is unchanged
    /// (`repo.insightsLoadedSeq == repo.refreshSeq` AND the same dayKey) we RESTORE the prior snapshot from
    /// the long-lived `repo` instead of re-querying. `allowCache` is true ONLY on the `.task(id:)`-driven
    /// path (a re-mount / data-refresh / day-rollover); the direct write-then-reload sites (journal toggle,
    /// experiment mark) leave it false so a change that doesn't bump `refreshSeq` always re-reads.
    private func load(allowCache: Bool = false) async {
        // #833: same-state re-mount → restore from the repo-level cache (no store queries). The dayKey guard
        // mirrors the `.task(id:)` key so a day-rollover still re-loads even at an unchanged seq.
        if allowCache,
           repo.insightsLoadedSeq == repo.refreshSeq,
           repo.insightsLoadedDayKey == currentDayKey,
           let cached = repo.insightsCache,
           cached.journalDayOffset == journalDayOffset {
            restoreFromCache(cached)
            return
        }

        // Journal → behaviours map (only "yes" answers count as the behaviour occurring).
        // journalEntries() is the imported ∪ native union (native wins per day+question). A numeric
        // log writes answeredYes=true too (#322), so a numeric item lands in the with/without split
        // here unchanged, on top of the numeric series read below.
        let entries = await repo.journalEntries()
        // Yes days and NO days, kept apart. A day with no journal row for the question lands in
        // neither, so an unanswered day is never counted as a No (BehaviorInsights.effect).
        var byBehaviour: [String: Set<String>] = [:]
        var controlsByBehaviour: [String: Set<String>] = [:]
        var numericByBehaviour: [String: [String: Double]] = [:]
        for e in entries {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controlsByBehaviour[e.question, default: []].insert(e.day) }
        }
        // #322: per-question numeric series (question → [day: value]) for numeric journal items. A
        // numeric series is the same [day: value] shape a metric outcome is, so the effect ranker can
        // consume it directly (dose-response lands in the v5 hub). Additive: yes/no-only journals
        // never populate this, so the boolean effect cards are untouched.
        for e in entries {
            if let v = e.numericValue { numericByBehaviour[e.question, default: [:]][e.day] = v }
        }

        // The logging card's inputs: the export's exact question strings (so logged days join
        // imported history) and the selected day's native chip state, a targeted read, since the
        // merged list carries no deviceId to filter on.
        let imported = await repo.importedJournalEntries()
        let importedQs = NSOrderedSet(array: imported.map(\.question)).array as? [String] ?? []
        let selectedDayKey = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -journalDayOffset, to: Date()) ?? Date())
        let nativeAnswers = await repo.nativeJournalAnswers(day: selectedDayKey)
        let nativeNumeric = await repo.nativeJournalNumeric(day: selectedDayKey)

        // Daily metrics for the strap-only outcome fallback (merged, imported-wins). The view is
        // MainActor-isolated, so reading the published cache here is on the right actor.
        let mergedDays = repo.days

        // Outcome series (Whoop) → both [day:value] dictionaries and ordered series. The imported
        // metricSeries only exists after a CSV import; fill the days it doesn't cover from the
        // merged daily metrics so an account-free user's logging still gets effects
        // (recovery/hrv/rhr have daily columns; sleep_performance stays import-only).
        var byKey: [String: [String: Double]] = [:]
        var seriesMap: [String: [(day: String, value: Double)]] = [:]
        for key in outcomeKeys {
            let s = await repo.series(key: key, source: "my-whoop")
            var dict: [String: Double] = [:]
            for row in s { dict[row.day] = row.value }
            for d in mergedDays where dict[d.day] == nil {
                if let v = Self.dailyOutcome(key: key, day: d) { dict[d.day] = v }
            }
            byKey[key] = dict
            seriesMap[key] = dict.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
        }

        // #322: fold each numeric journal item's series into the same day→value maps the effect ranker
        // consumes, under a namespaced "journal.numeric:<question>" key so it never collides with the
        // four fixed metric outcomes. This makes a numeric journal series (caffeine mg, alcohol units)
        // a first-class series the ranker/correlations can consume, exactly like a metric outcome; the
        // four boolean effect cards key on Outcome.key only, so they are untouched.
        for (question, series) in numericByBehaviour {
            let namespaced = Self.numericJournalKey(question)
            byKey[namespaced] = series
            seriesMap[namespaced] = series.sorted { $0.key < $1.key }.map { (day: $0.key, value: $0.value) }
        }

        // Activity Cost (#439): shape the engine's inputs in the VIEW, not the engine. From the loaded
        // sessions build [sport: Set<localDayKey>], collapsing detected/"Activity" into one bucket via
        // displaySport, keeping manual/imported labels, keyed by the LOCAL calendar day the session
        // STARTED (the same local-day calendar DailyMetric.day uses, so the engine's D+1 alignment is
        // honest). The recovery side is [localDayKey: Charge] off the merged DailyMetric.recovery.
        let costs = Self.computeActivityCosts(workouts: await repo.workoutRows(), days: mergedDays)

        await MainActor.run {
            self.behaviours = byBehaviour
            self.controls = controlsByBehaviour
            self.importedQuestions = importedQs
            self.dayAnswers = nativeAnswers
            self.dayNumeric = nativeNumeric
            self.outcomeByKey = byKey
            self.seriesByKey = seriesMap
            self.numericJournalByKey = numericByBehaviour
            self.activityCosts = costs
            self.loaded = true
            // Seed the memoized derived state from the freshly loaded inputs.
            self.recomputeRanked()
            self.recomputeRelationships()
            // #833: snapshot what we just read onto the long-lived `repo`, keyed by the seq + dayKey we
            // loaded for, so a later same-state re-mount restores it in-memory instead of re-querying. This
            // ALSO runs on the direct (non-cached) write-then-reload sites, so the cache always reflects the
            // freshest read, a subsequent re-mount never restores stale data behind a journal toggle.
            self.repo.insightsCache = InsightsLoadCache(
                behaviours: byBehaviour,
                controls: controlsByBehaviour,
                importedQuestions: importedQs,
                dayAnswers: nativeAnswers,
                journalDayOffset: self.journalDayOffset,
                outcomeByKey: byKey,
                seriesByKey: seriesMap,
                activityCosts: costs,
                numericJournalByKey: numericByBehaviour)
            self.repo.insightsLoadedSeq = self.repo.refreshSeq
            self.repo.insightsLoadedDayKey = self.currentDayKey
        }
    }

    /// #833: restore the loaded snapshot from a same-state `repo` cache on a re-mount, so the screen repaints
    /// from memory without re-running the heavy load. Sets the same `@State` and re-seeds the same memoized
    /// derived state as the first-load `MainActor.run` block above, byte-identical screen, no store queries.
    @MainActor
    private func restoreFromCache(_ c: InsightsLoadCache) {
        behaviours = c.behaviours
        controls = c.controls
        importedQuestions = c.importedQuestions
        dayAnswers = c.dayAnswers
        // Numeric journal rows are native-only (imported WHOOP rows never carry a numericValue), so the
        // selected day's numeric fields can be derived from the cached per-question series (#322).
        let selectedDayKey = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -c.journalDayOffset, to: Date()) ?? Date())
        dayNumeric = c.numericJournalByKey.compactMapValues { $0[selectedDayKey] }
        outcomeByKey = c.outcomeByKey
        seriesByKey = c.seriesByKey
        numericJournalByKey = c.numericJournalByKey
        activityCosts = c.activityCosts
        loaded = true
        recomputeRanked()
        recomputeRelationships()
    }

    /// The merged DailyMetric column backing an outcome key, for days the imported metricSeries
    /// doesn't cover (strap-only users). sleep_performance has no daily column, so it stays
    /// import-only, never seeded here.
    private static func dailyOutcome(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery": return d.recovery
        case "hrv":      return d.avgHrv
        case "rhr":      return d.restingHr.map(Double.init)
        default:         return nil
        }
    }

    // MARK: - Activity Cost input shaping (#439)
    //
    // The engine is pure + unit-tested; ALL the DB→input shaping lives here in the view. Sessions
    // become [sport: Set<localDayKey>] and the merged daily metrics become [localDayKey: Charge], then
    // ActivityCostEngine.evaluate ranks the per-sport recovery cost. Keying both sides on the LOCAL
    // calendar day (DailyMetric.day's calendar) keeps the engine's D+1 next-morning lookups aligned.

    // `internal` (not private) so the Workouts post-log note (#439) reuses the exact same input
    // shaping rather than duplicating it, one source of truth for [sport: days] / [day: Charge].
    static func computeActivityCosts(workouts: [WorkoutRow], days: [DailyMetric]) -> [ActivityCost] {
        // Local-day offset so the activity day key lands on the SAME calendar as DailyMetric.day
        // (which IntelligenceEngine/WhoopImporter both bucket by local midnight, #277).
        let tzOffset = TimeZone.current.secondsFromGMT()
        var activityDaysBySport: [String: Set<String>] = [:]
        for w in workouts {
            // displaySport collapses the detector's "detected" token into one "Activity" bucket and
            // de-camelCases WHOOP sport names; manual/imported labels pass through unchanged.
            let sport = WorkoutSource.displaySport(w.sport)
            guard !sport.isEmpty else { continue }
            let day = AnalyticsEngine.dayString(w.startTs, offsetSec: tzOffset)
            activityDaysBySport[sport, default: []].insert(day)
        }
        var recoveryByDay: [String: Double] = [:]
        for d in days {
            if let r = d.recovery { recoveryByDay[d.day] = r }
        }
        return ActivityCostEngine.evaluate(activityDaysBySport: activityDaysBySport,
                                           recoveryByDay: recoveryByDay)
    }

    // MARK: - Memoized recomputation

    /// Rebuild the cached behaviour ranking for the current inputs.
    /// Called at load and whenever `outcome` changes, NOT in `body`.
    private func recomputeRanked() {
        let outcomeDays = outcomeByKey[outcome.key] ?? [:]
        ranked = BehaviorInsights.rank(
            behaviors: behaviours,
            controls: controls,
            outcomeByDay: outcomeDays,
            outcome: outcome.outcomeName
        )
    }

    /// Rebuild the cached metric relationships from the loaded series.
    /// Called at load only, the series don't change after that.
    private func recomputeRelationships() {
        relationships = computeRelationships()
    }

    // MARK: - Personal experiment section
    //
    // A LOCAL-ONLY n-of-1 protocol: pick ONE behaviour you actually log, one outcome,
    // and a short window, then compare the outcome on days you logged the behaviour
    // (the intervention) against your behaviour-ABSENT days before the start (the
    // baseline). The absent-day baseline mirrors the with/without model used by the
    // Behaviour Effects section above, so "Baseline" vs "Intervention" is an honest
    // present-vs-absent contrast rather than a raw pre/post window. Nothing leaves the
    // device: state is @AppStorage and "Mark done" writes a normal journal answer.

    /// The personal experiment one tap below its row: the setup form, or the running experiment.
    private var experimentPage: some View {
        ScreenScaffold(title: "Personal experiment", titleDisplay: .navigationBar) {
            NoopCard {
                if let snapshot = activeExperimentSnapshot {
                    activeExperimentCard(snapshot)
                } else {
                    experimentSetupCard
                }
            }
            AboutDisclosure(paragraphs: [
                String(localized: "Pick one behaviour you log, one outcome, and a short window. Nara compares the days you log the behaviour against your behaviour-free days before the start."),
                String(localized: "Local only"),
            ])
        }
    }

    @ViewBuilder private var experimentSetupCard: some View {
        let candidates = experimentCandidates
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Run a clean personal test")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)

            if candidates.isEmpty {
                Text("Log at least one behaviour above before starting an experiment.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                experimentField("Behaviour") {
                    Picker("Behaviour", selection: experimentBehaviourBinding) {
                        ForEach(candidates, id: \.self) { q in
                            Text(verbatim: q).tag(q)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Experiment behaviour")
                }
                experimentField("Outcome") {
                    SegmentedPillControl(Outcome.allCases, selection: experimentOutcomeBinding) { $0.label }
                        .accessibilityLabel("Experiment outcome metric")
                }
                experimentField("Window") {
                    SegmentedPillControl(ExperimentLength.allCases,
                                         selection: experimentLengthBinding) { $0.label }
                        .accessibilityLabel("Experiment window length")
                }

                NoopButton("Start experiment", systemImage: "flask.fill",
                           kind: .primary, fullWidth: true) { startExperiment() }
                    .disabled(resolvedExperimentBehaviour == nil)
                    .help("Start a local experiment using today's date as day one.")
            }
        }
    }

    private func activeExperimentCard(_ snapshot: ExperimentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(verbatim: snapshot.behavior)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                    Text("Started \(snapshot.startDay) · testing \(snapshot.outcome.outcomeName.lowercased())")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: NoopMetrics.space3)
                StatePill(LocalizedStringKey(snapshot.phaseLabel), tone: snapshot.phaseTone)
            }

            Text(experimentReading(snapshot))
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: NoopMetrics.space2)],
                alignment: .leading,
                spacing: NoopMetrics.space2
            ) {
                experimentMeasure("Baseline",
                                  value: snapshot.baselineMean.map { formatOutcome($0, as: snapshot.outcome) } ?? "—",
                                  caption: String(localized: "\(snapshot.baselineCount) days without it"))
                experimentMeasure("Intervention",
                                  value: snapshot.interventionMean.map { formatOutcome($0, as: snapshot.outcome) } ?? "—",
                                  caption: String(localized: "\(snapshot.interventionCount) logged days"))
                experimentMeasure("Change",
                                  value: formatExperimentDelta(snapshot.delta, outcome: snapshot.outcome),
                                  caption: snapshot.deltaCaption)
                experimentMeasure("Compliance",
                                  value: "\(Int(snapshot.compliance.rounded())) %",
                                  caption: snapshot.loggedToday ? String(localized: "logged today") : String(localized: "not logged today"))
            }

            // The experiment has a real end, so its progress is a real bar toward it.
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                ProgressView(value: snapshot.progress)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Experiment progress")
                    .accessibilityValue("\(snapshot.daysElapsed) of \(snapshot.durationDays) days")
                HStack {
                    Text("\(snapshot.daysElapsed) of \(snapshot.durationDays) days")
                    Spacer()
                    StatePill(LocalizedStringKey(snapshot.confidence.label),
                              tone: snapshot.confidence.tone,
                              showsDot: false)
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            }

            HStack(spacing: NoopMetrics.space2) {
                Button { Task { await markExperimentToday(true) } } label: {
                    Label("Mark done today", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(snapshot.loggedToday)

                Button { Task { await markExperimentToday(false) } } label: {
                    Label("Skip today", systemImage: "xmark.circle")
                }
                .buttonStyle(NoopButtonStyle(.secondary))

                Spacer(minLength: NoopMetrics.space2)

                Button(role: .destructive) { endExperiment() } label: {
                    Label("End", systemImage: "stop.circle")
                }
                .buttonStyle(NoopButtonStyle(.destructive))
                .help("End the experiment plan. Journal and metric history stay untouched.")
            }
        }
    }

    private func experimentField<Content: View>(_ title: LocalizedStringKey,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title).strandLabel()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func experimentMeasure(_ label: LocalizedStringKey,
                                   value: String,
                                   caption: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(label).strandLabel()
                .lineLimit(1)
            Text(value)
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(caption)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(NoopInsetSurface())
    }

    /// Behaviours the user actually has data for: distinct logged journal questions
    /// (`behaviours.keys`) ∪ imported-export questions, minus the catalog's hidden set.
    /// Triage fix (a)/(b): we do NOT route this through `mergeCatalog`, which would inject
    /// the whole starter catalog (and re-surface hidden behaviours) as eligible, so the
    /// empty-state guard is real and only behaviours with history can be tested.
    private var experimentCandidates: [String] {
        let saved = experimentBehaviour.trimmingCharacters(in: .whitespacesAndNewlines)
        let hidden = Set(catalog.hiddenQuestions.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        // Logged behaviours first (most relevant), then imported wording, then the saved
        // selection so an in-flight pick never vanishes mid-edit.
        let raw = behaviours.keys.sorted() + importedQuestions + (saved.isEmpty ? [] : [saved])
        var seen = Set<String>()
        var out: [String] = []
        for q in raw {
            let t = q.trimmingCharacters(in: .whitespaces)
            let key = t.lowercased()
            if !t.isEmpty, !hidden.contains(key), seen.insert(key).inserted { out.append(t) }
        }
        return out
    }

    private var resolvedExperimentBehaviour: String? {
        let candidates = experimentCandidates
        let saved = experimentBehaviour.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty, candidates.contains(saved) { return saved }
        return candidates.first
    }

    private var experimentBehaviourBinding: Binding<String> {
        Binding(
            get: { resolvedExperimentBehaviour ?? "" },
            set: { experimentBehaviour = $0 }
        )
    }

    private var experimentOutcomeBinding: Binding<Outcome> {
        Binding(
            get: { Outcome(rawValue: experimentOutcomeRaw) ?? .recovery },
            set: { experimentOutcomeRaw = $0.rawValue }
        )
    }

    private var experimentLengthBinding: Binding<ExperimentLength> {
        Binding(
            get: { ExperimentLength(rawValue: experimentDurationDays) ?? .twoWeeks },
            set: { experimentDurationDays = $0.rawValue }
        )
    }

    private var activeExperimentSnapshot: ExperimentSnapshot? {
        guard !experimentStartedDay.isEmpty,
              let outcome = Outcome(rawValue: experimentOutcomeRaw),
              let behavior = resolvedExperimentBehaviour
        else { return nil }

        let today = Repository.localDayKey(Date())
        let duration = max(1, experimentDurationDays)
        let outcomeDays = outcomeByKey[outcome.key] ?? [:]
        let loggedDays = behaviours[behavior] ?? []

        // Baseline = behaviour-ABSENT days BEFORE the start (with/without model, matching
        // Behaviour Effects). Restricting to absent days is triage fix (c): "Baseline" vs
        // "Intervention" is now an honest present-vs-absent contrast, not a raw pre/post window.
        let baselineDays = outcomeDays.keys
            .filter { $0 < experimentStartedDay && !loggedDays.contains($0) }
            .sorted()
            .suffix(max(1, experimentBaselineDays))
        // Intervention = the first `duration` outcome days in the window where the behaviour
        // WAS logged.
        let interventionWindow = outcomeDays.keys
            .filter { $0 >= experimentStartedDay && $0 <= today }
            .sorted()
            .prefix(duration)
        let interventionDays = interventionWindow.filter { loggedDays.contains($0) }

        let baselineValues = baselineDays.compactMap { outcomeDays[$0] }
        let interventionValues = interventionDays.compactMap { outcomeDays[$0] }
        let daysElapsed = max(1, min(duration, dayDistance(from: experimentStartedDay, to: today) + 1))
        let complianceFraction = Double(interventionDays.count) / Double(max(daysElapsed, 1))
        let confidence = experimentConfidence(baselineCount: baselineValues.count,
                                              interventionCount: interventionValues.count,
                                              compliance: complianceFraction)

        return ExperimentSnapshot(
            behavior: behavior,
            outcome: outcome,
            startDay: experimentStartedDay,
            durationDays: duration,
            daysElapsed: daysElapsed,
            baselineMean: Self.mean(baselineValues),
            baselineCount: baselineValues.count,
            interventionMean: Self.mean(interventionValues),
            interventionCount: interventionValues.count,
            loggedToday: loggedDays.contains(today),
            compliance: complianceFraction * 100,
            confidence: confidence
        )
    }

    private func startExperiment() {
        guard let behavior = resolvedExperimentBehaviour else { return }
        experimentBehaviour = behavior
        if ExperimentLength(rawValue: experimentDurationDays) == nil {
            experimentDurationDays = ExperimentLength.twoWeeks.rawValue
        }
        if Outcome(rawValue: experimentOutcomeRaw) == nil {
            experimentOutcomeRaw = Outcome.recovery.rawValue
        }
        experimentBaselineDays = experimentDurationDays
        experimentStartedDay = Repository.localDayKey(Date())
    }

    private func endExperiment() {
        experimentStartedDay = ""
    }

    private func markExperimentToday(_ answeredYes: Bool) async {
        guard let behavior = activeExperimentSnapshot?.behavior else { return }
        await repo.saveJournalAnswer(day: Repository.localDayKey(Date()),
                                     question: behavior,
                                     answeredYes: answeredYes)
        await load()
    }

    private func experimentConfidence(baselineCount: Int,
                                      interventionCount: Int,
                                      compliance: Double) -> ExperimentConfidence {
        let pairedCount = min(baselineCount, interventionCount)
        if pairedCount >= 10, compliance >= 0.65 {
            return .init(label: String(localized: "Stronger signal"), tone: .positive)
        }
        if pairedCount >= 5 {
            return .init(label: String(localized: "Early signal"), tone: .accent)
        }
        return .init(label: String(localized: "Low signal"), tone: .warning)
    }

    private func experimentReading(_ snapshot: ExperimentSnapshot) -> String {
        guard let delta = snapshot.delta else {
            return String(localized: "Collect a few logged intervention days before reading the effect. Baseline and imported metrics stay in place.")
        }
        let absDelta = formatExperimentDelta(abs(delta), outcome: snapshot.outcome, includeSign: false)
        if abs(delta) < 0.05 {
            return String(localized: "\(snapshot.outcome.outcomeName) is flat against baseline on logged intervention days.")
        }
        // Whole-phrase variants per direction so translators never see a stitched better/worse fragment.
        let movedGood = snapshot.outcome.higherIsBetter ? delta > 0 : delta < 0
        return movedGood
            ? String(localized: "\(snapshot.outcome.outcomeName) is \(absDelta) better than baseline on days you logged this behaviour.")
            : String(localized: "\(snapshot.outcome.outcomeName) is \(absDelta) worse than baseline on days you logged this behaviour.")
    }

    private func experimentDeltaColor(_ snapshot: ExperimentSnapshot) -> Color {
        guard let delta = snapshot.delta, abs(delta) >= 0.05 else {
            return StrandPalette.textTertiary
        }
        let movedGood = snapshot.outcome.higherIsBetter ? delta > 0 : delta < 0
        return movedGood ? StrandPalette.statusPositive : StrandPalette.statusCritical
    }

    private func formatExperimentDelta(_ delta: Double?,
                                       outcome: Outcome,
                                       includeSign: Bool = true) -> String {
        guard let delta else { return "—" }
        let prefix: String
        if includeSign {
            prefix = delta > 0 ? "+" : (delta < 0 ? "−" : "")
        } else {
            prefix = ""
        }
        let absDelta = abs(delta)
        switch outcome {
        case .recovery, .sleep:
            return "\(prefix)\(Int(absDelta.rounded()))%"
        case .hrv:
            return "\(prefix)\(Int(absDelta.rounded())) ms"
        case .rhr:
            return "\(prefix)\(Int(absDelta.rounded())) bpm"
        }
    }

    private func dayDistance(from start: String, to end: String) -> Int {
        guard let startDate = Self.dateFromDayKey(start),
              let endDate = Self.dateFromDayKey(end)
        else { return 0 }
        return Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
    }

    private static func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.date
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The namespaced outcome key a numeric journal item's series is folded under (#322). Prefixed so
    /// it can never collide with a fixed metric outcome key. Pure + tested (mirrors Android).
    static func numericJournalKey(_ question: String) -> String { "journal.numeric:" + question }

    private struct ExperimentSnapshot {
        let behavior: String
        let outcome: Outcome
        let startDay: String
        let durationDays: Int
        let daysElapsed: Int
        let baselineMean: Double?
        let baselineCount: Int
        let interventionMean: Double?
        let interventionCount: Int
        let loggedToday: Bool
        let compliance: Double
        let confidence: ExperimentConfidence

        var progress: Double { min(1, Double(daysElapsed) / Double(max(durationDays, 1))) }
        var phaseLabel: String {
            daysElapsed >= durationDays ? String(localized: "Complete")
                                        : String(localized: "Day \(daysElapsed) of \(durationDays)")
        }
        var phaseTone: StrandTone { daysElapsed >= durationDays ? .positive : .accent }
        var delta: Double? {
            guard let interventionMean, let baselineMean else { return nil }
            return interventionMean - baselineMean
        }
        var deltaCaption: String {
            guard delta != nil else { return String(localized: "needs baseline + logged days") }
            return String(localized: "vs behaviour-free baseline")
        }
    }

    private struct ExperimentConfidence {
        let label: String
        let tone: StrandTone
    }

    // MARK: - Activity Cost page (#439)

    /// "What each activity costs your recovery", one tap below its row: one card per sport that cleared
    /// the engine's minSessions gate, each with the engine's sentence and the next-morning Charge against
    /// the rest baseline, days to bounce back and the session count.
    private var activityCostPage: some View {
        ScreenScaffold(title: "Activity cost", titleDisplay: .navigationBar) {
            if activityCosts.isEmpty {
                ComingSoon(what: "Tag a few sessions of the same activity and Nara will learn its personal recovery cost.")
            } else {
                ForEach(activityCosts, id: \.sport) { cost in
                    activityCostCard(cost)
                }
            }
        }
    }

    private func activityCostCard(_ cost: ActivityCost) -> some View {
        let pointsLabel = String(format: "%@%.0f", cost.delta >= 0 ? "−" : "+", abs(cost.delta))
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .center, spacing: NoopMetrics.space2) {
                    Image(systemName: sportSymbol(cost.sport))
                        .font(StrandFont.icon(.inline))
                        .foregroundStyle(StrandPalette.effortColor)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(cost.sport)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: NoopMetrics.space2)
                    StatePill(cost.confidence == .solid ? "Solid" : "Building",
                              tone: cost.confidence == .solid ? .positive : .neutral, showsDot: false)
                }
                Text(cost.sentence())
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                InsightsComparisonBars(bars: [
                    .init(id: "next", label: String(localized: "Next morning"), value: cost.meanNextMorning,
                          valueText: "\(Int(cost.meanNextMorning.rounded())) %",
                          detail: String(localized: "Charge · \(pointsLabel) pts"),
                          color: StrandPalette.chargeColor),
                    .init(id: "base", label: String(localized: "Rest baseline"), value: cost.baselineMean,
                          valueText: "\(Int(cost.baselineMean.rounded())) %",
                          detail: String(localized: "untouched days"),
                          color: StrandPalette.textTertiary),
                ], domain: 0...100)
                InsightsValueRow(label: String(localized: "Bounce back"),
                                 value: cost.daysToBaseline.map { "\($0)" } ?? "—",
                                 unit: cost.daysToBaseline != nil ? String(localized: "days") : nil)
                InsightsValueRow(label: String(localized: "Sessions"), value: "\(cost.n)")
            }
        }
    }

    // MARK: - Metric relationships page

    /// The curated metric pairs one tap below their row: for each, its strength in words and r, a bar for
    /// direction and size, and the scatter of the days the two share, which is what actually shows the
    /// relationship.
    private var relationshipsPage: some View {
        // `relationships` is memoized in @State (see recomputeRelationships()); the four Pearson
        // correlations no longer run per render.
        ScreenScaffold(title: "Metric relationships", titleDisplay: .navigationBar) {
            if relationships.isEmpty {
                ComingSoon(what: "Not enough overlapping history to correlate your metrics yet.")
            } else {
                ForEach(relationships) { rel in
                    relationshipCard(rel)
                }
            }
            AboutDisclosure(paragraphs: relationships.map(\.blurb))
        }
    }

    /// A curated metric relationship plus its computed correlation.
    private struct Relationship: Identifiable {
        let id: String
        let title: String        // "Sleep → Recovery"
        let blurb: String        // what the pairing probes
        let corr: Correlation
        /// The series keys behind the pair, for the scatter, and the lag in days.
        var xKey: String = ""
        var yKey: String = ""
        var lagDays: Int = 0
    }

    private func computeRelationships() -> [Relationship] {
        func series(_ key: String) -> [(day: String, value: Double)] { seriesByKey[key] ?? [] }
        var out: [Relationship] = []

        // Sleep performance ↔ recovery (same day).
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("sleep_performance"), series("recovery"))) {
            out.append(.init(id: "sleep-rec",
                             title: String(localized: "Rest ↔ Charge"),
                             blurb: String(localized: "How closely a good night tracks next-morning charge."),
                             corr: c, xKey: "sleep_performance", yKey: "recovery"))
        }
        // HRV ↔ recovery (same day).
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("hrv"), series("recovery"))) {
            out.append(.init(id: "hrv-rec",
                             title: String(localized: "HRV ↔ Charge"),
                             blurb: String(localized: "Heart-rate variability as the engine behind your charge score."),
                             corr: c, xKey: "hrv", yKey: "recovery"))
        }
        // Resting HR ↔ recovery (same day), expected to be negative.
        if let c = CorrelationEngine.pearson(
            CorrelationEngine.alignByDay(series("rhr"), series("recovery"))) {
            out.append(.init(id: "rhr-rec",
                             title: String(localized: "Resting HR ↔ Charge"),
                             blurb: String(localized: "A lower resting heart rate usually means a higher charge."),
                             corr: c, xKey: "rhr", yKey: "recovery"))
        }
        // Today's recovery ↔ NEXT-day recovery (1-day lag) as a strain/carry-over proxy.
        // (Strain series isn't in the outcome set; recovery→next-day recovery shows
        //  how much yesterday carries into today.)
        if let c = CorrelationEngine.lagged(x: series("recovery"), y: series("recovery"), lagDays: 1) {
            out.append(.init(id: "rec-lag",
                             title: String(localized: "Charge → Next-day charge"),
                             blurb: String(localized: "How much one day's charge carries into the next."),
                             corr: c, xKey: "recovery", yKey: "recovery", lagDays: 1))
        }

        return out
    }

    /// The day pairs a relationship was computed over, for its scatter (display only): the same-day join
    /// `CorrelationEngine.alignByDay` uses, or x's day against y's day `lagDays` later.
    private func scatterPairs(_ rel: Relationship) -> [(Double, Double)] {
        let x = seriesByKey[rel.xKey] ?? []
        let y = seriesByKey[rel.yKey] ?? []
        guard rel.lagDays != 0 else { return CorrelationEngine.alignByDay(x, y) }
        var mapY: [String: Double] = [:]
        for row in y { mapY[row.day] = row.value }
        return x.sorted { $0.day < $1.day }.compactMap { row in
            mapY[WeeklyDigestEngine.addDays(row.day, rel.lagDays)].map { (row.value, $0) }
        }
    }

    private func axisTitle(_ key: String, nextDay: Bool = false) -> String {
        let name: String
        switch key {
        case "sleep_performance": name = String(localized: "Rest") + " (%)"
        case "hrv": name = "HRV (ms)"
        case "rhr": name = String(localized: "Resting HR") + " (bpm)"
        default: name = String(localized: "Charge") + " (%)"
        }
        return nextDay ? String(localized: "Next day") + " · " + name : name
    }

    private func relationshipCard(_ rel: Relationship) -> some View {
        let r = rel.corr.r
        // Build the reading sentence ONCE and reuse it for the visible copy and
        // the accessibility label (was computed twice per row).
        let sentence = relationshipSentence(rel)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(LocalizedStringKey(rel.title),
                          trailing: rel.corr.pApprox < 0.05 ? "p < 0.05" : String(localized: "n.s."))
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "r = %+.2f", r))
                            .font(StrandFont.number(20))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: NoopMetrics.space2)
                        Text(sentence)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(sentence)
                    InsightsDivergingBar(value: r, magnitude: 1,
                                         positiveColor: StrandPalette.chargeColor,
                                         negativeColor: StrandPalette.metricRose)
                    InsightsScatterChart(pairs: scatterPairs(rel),
                                         xTitle: axisTitle(rel.xKey),
                                         yTitle: axisTitle(rel.yKey, nextDay: rel.lagDays != 0))
                }
            }
        }
    }

    // MARK: - Formatting / interpretation helpers

    /// Format an outcome value with sensible units for a specific metric (used by the
    /// experiment card, which formats against its own stored outcome rather than the
    /// segmented selection).
    private func formatOutcome(_ v: Double, as outcome: Outcome) -> String {
        switch outcome {
        case .recovery, .sleep: return "\(Int(v.rounded()))%"
        case .hrv:              return "\(Int(v.rounded())) ms"
        case .rhr:              return "\(Int(v.rounded())) bpm"
        }
    }

    /// |r| → strength word.
    private func strengthWord(_ r: Double) -> String {
        switch abs(r) {
        case ..<0.1:  return String(localized: "no")
        case ..<0.3:  return String(localized: "a weak")
        case ..<0.5:  return String(localized: "a moderate")
        case ..<0.7:  return String(localized: "a strong")
        default:      return String(localized: "a very strong")
        }
    }

    private func relationshipSentence(_ rel: Relationship) -> String {
        let r = rel.corr.r
        let dir = r > 0 ? String(localized: "positive") : (r < 0 ? String(localized: "negative") : String(localized: "flat"))
        let strength = strengthWord(r)
        return String(localized: "\(strength.capitalizedFirst) \(dir) relationship (r = \(String(format: "%.2f", r)), n = \(rel.corr.n)).")
    }
}

private extension String {
    /// Capitalise only the first letter (keeps "a weak" → "A weak").
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func insightsPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Insights") {
    InsightsView()
        .environmentObject(insightsPreviewRepo())
        .environmentObject(NavRouter())
        .frame(width: 920, height: 900)
        .preferredColorScheme(.dark)
}
#endif
