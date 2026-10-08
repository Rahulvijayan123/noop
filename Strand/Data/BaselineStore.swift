import Foundation
import Combine
import StrandAnalytics
import WhoopStore

/// UI-facing baseline state. Views never call `evaluate`. Scores from real `DailyMetric` rows
/// (Repository.days) plus persisted treatment events. No in-app sample-patient toggle.
@MainActor
final class BaselineStore: ObservableObject {
    enum Pane: String, CaseIterable {
        case monitor = "Monitor"
        case treatment = "Treatment"
    }

    enum ContextFilter: String, CaseIterable, Identifiable {
        case sleep = "Sleep"
        case allDay = "All day"
        case rest = "Rest"
        case active = "Active"
        var id: String { rawValue }
        var scoredValueLabel: String {
            switch self {
            case .sleep: return "SCORED NIGHT"
            case .allDay: return "SCORED DAY"
            case .rest: return "SCORED REST"
            case .active: return "SCORED ACTIVE"
            }
        }
        var scoredMoment: String {
            switch self {
            case .sleep: return "night"
            case .allDay: return "day"
            case .rest: return "rest window"
            case .active: return "active window"
            }
        }
        var lbContext: LBContext {
            switch self {
            case .sleep: return .sleep
            case .allDay: return .continuous
            case .rest: return .awakeRest
            case .active: return .awakeActive
            }
        }
    }

    @Published var pane: Pane = .monitor
    @Published var asOf: String
    @Published var longAsOf: String
    @Published var context: ContextFilter = .sleep
    @Published var series: LBSeries = .sleepRHR
    @Published var evaluation: LBEvaluation?
    @Published var longEvaluation: LBEvaluation?
    @Published var weekPoints: [BaselinePlotPoint] = []
    @Published var longPoints: [BaselinePlotPoint] = []
    @Published var calendarSlots: [BaselineCalendarSlot] = []
    @Published var events: [LBTreatmentEvent] = []
    @Published var confoundersByDay: [String: [LBConfounder]] = [:]
    @Published var dayLogsByDay: [String: LBDayLog] = [:]
    @Published var imuByDay: [String: LBDailyObservation] = [:]
    private var imuAccByDay: [String: LBImuDayAccumulator] = [:]
    private var imuLastPersistUnix: Int = 0
    private var dayTapeByDay: [String: LBDayTape] = [:]
    private var tapeLastPersistUnix: Int = 0
    @Published var showStartForm = false
    @Published var showDoseForm = false
    @Published var showEndForm = false
    @Published var showContextSheet = false
    @Published var loggingDay: String
    @Published var trendsExpanded = false
    @Published var watchdogResult: WatchdogResult?
    /// Phone activity-context label for the current minute. Display only; scoring ignores it.
    @Published var activityContextNote: String?
    @Published var eventRecovery: WatchdogEventRecovery?
    @Published var episodeAnnotations: [WatchdogEpisodeAnnotation] = []
    @Published var episodeLedger: [WatchdogEpisodeLedgerRow] = []
    @Published var showEpisodeNoteSheet = false
    @Published var liveIntervalMinutes: Int
    @Published var editingEventIndex: Int?
    @Published var trialExpanded = false
    @Published var watchCandidates: [BaselineWatchCandidate] = []
    /// Per-chip readiness in the current context. One thin series must not hide the others.
    @Published var seriesReadiness: [LBSeries: SeriesReadiness] = [:]
    /// Today ring and Monitor list. Nil until real nights exist.
    @Published var vitalsCheck: BaselineVitalsCheck?
    private var dismissedPromptDay: String?
    /// v2 context strata (posture / steady walking / sleep HR, and the full-day pooled awake-rest days) from the
    /// stored activity-context intervals. See `LongitudinalBaseline.ContextMaterializer`.
    @Published private(set) var contextObservations: [LBSeries: [LBDailyObservation]] = [:]
    private var contextRefreshedAt: Date?
    private var contextRefreshing = false
    private var contextVersion = 0
    /// Explicit "set a new reference" days (frozen-anchor epochs). Device-family epochs are added at evaluate time.
    @Published private(set) var reanchorDays: [String] = []
    private let reanchorKey = "noop.baseline.reanchor.v1"
    /// Memo for `watchdogPromptEvaluations`: the Watchdog tick asks every 20 s with identical inputs.
    private var promptMemo: (key: String, evals: [LBEvaluation])?

    struct SeriesReadiness: Equatable {
        var show7: Bool
        var showLong: Bool
        var n7: Int
        var nLong: Int
        var ready: Bool { show7 || showLong }
    }

    private let defaults: UserDefaults
    private let eventsKey = "noop.baseline.events.v1"
    private let freezeKeyPrefix = "noop.baseline.freeze.v1."
    private let confoundersKey = "noop.baseline.confounders.v1"
    private let dayLogsKey = "noop.baseline.daylog.v1"
    private let imuKey = "noop.baseline.imu.v1"
    private let tapeKey = "noop.baseline.daytape.v2"
    private let tapeKeyLegacy = "noop.baseline.daytape.v1"
    private let dismissedPromptKey = "noop.baseline.dismissedPrompt.v1"

    init(defaults: UserDefaults = .standard, asOf: String? = nil, resetCourse: Bool = false) {
        self.defaults = defaults
        let start = asOf ?? Self.yesterdayKey()
        self.asOf = start
        self.longAsOf = start
        self.loggingDay = start
        let storedInterval = defaults.integer(forKey: WatchdogConfig.intervalKey)
        self.liveIntervalMinutes = WatchdogConfig.clampInterval(storedInterval == 0 ? WatchdogConfig.defaultLiveIntervalMinutes : storedInterval)
        if resetCourse {
            defaults.removeObject(forKey: eventsKey)
            defaults.removeObject(forKey: confoundersKey)
            defaults.removeObject(forKey: dayLogsKey)
            defaults.removeObject(forKey: imuKey)
            defaults.removeObject(forKey: tapeKey)
            defaults.removeObject(forKey: tapeKeyLegacy)
            defaults.removeObject(forKey: dismissedPromptKey)
            for series in LBSeries.allCases {
                defaults.removeObject(forKey: freezeKeyPrefix + series.rawValue)
            }
            self.events = []
            self.confoundersByDay = [:]
            self.dayLogsByDay = [:]
            self.imuByDay = [:]
            self.imuAccByDay = [:]
            self.dayTapeByDay = [:]
        } else {
            self.events = Self.loadEvents(defaults: defaults)
            self.confoundersByDay = Self.loadConfounders(defaults: defaults)
            self.dayLogsByDay = Self.loadDayLogs(defaults: defaults)
            self.imuAccByDay = Self.loadImu(defaults: defaults)
            self.imuByDay = Dictionary(uniqueKeysWithValues: self.imuAccByDay.map { ($0.key, $0.value.observation) })
            self.dayTapeByDay = Self.loadDayTape(defaults: defaults)
            self.dismissedPromptDay = defaults.string(forKey: dismissedPromptKey)
            self.reanchorDays = defaults.stringArray(forKey: reanchorKey) ?? []
        }
    }

    /// Reloads the context strata from the stored activity-context intervals (≤ 400 days). Throttled; the
    /// materializer runs off the main actor.
    func refreshContextStrata(repo: Repository, force: Bool = false) async {
        if contextRefreshing { return }
        if !force, let at = contextRefreshedAt, Date().timeIntervalSince(at) < 30 * 60 { return }
        contextRefreshing = true
        defer { contextRefreshing = false }
        let now = Int(Date().timeIntervalSince1970)
        let (intervals, _) = await repo.storedActivityContext(from: now - 400 * 86_400, to: now)
        let rows = intervals.map(\.storeRow)
        let obs = await Task.detached(priority: .utility) {
            LongitudinalBaseline.ContextMaterializer.observations(rows: rows)
        }.value
        contextObservations = obs
        contextRefreshedAt = Date()
        contextVersion += 1
        promptMemo = nil
    }

    /// The wearer starts a new frozen reference from `day` (e.g. after a lasting change their clinician has
    /// reviewed). Earlier days stay in the 60/90/365-day copies; only the anchor moves. Never automatic.
    func setNewReference(on day: String) {
        guard !reanchorDays.contains(day) else { return }
        reanchorDays.append(day)
        reanchorDays.sort()
        defaults.set(reanchorDays, forKey: reanchorKey)
        promptMemo = nil
    }

    var referenceEpochs: [LBReferenceEpoch] {
        reanchorDays.map { LBReferenceEpoch(startDay: $0, reason: .userReanchor) }
    }

    static var allWiredSeries: [LBSeries] {
        LBSeries.allCases.filter(\.hasDailyMetricColumn)
    }

    /// Series shown for the selected period. Sleep uses DailyMetric columns; Rest / Active / All day
    /// use demonstration observations derived from those nights (no WHOOP rest/active windows yet).
    var displayedSeries: [LBSeries] {
        LBSeries.allCases.filter {
            if $0 == .wakingImuEnergy { return context == .active }
            return $0.context == context.lbContext && $0 != .wakingSteps && $0 != .sleepSpO2Nadir
        }
    }

    var wiredSeriesInContext: [LBSeries] { displayedSeries }

    func shortTitle(for series: LBSeries) -> String {
        switch series {
        case .sleepRHR: return "Resting HR"
        case .sleepHRVLn, .awakeRestHRVLn, .awakeActiveHRVLn, .continuousHRVLn: return "HRV"
        case .sleepTemp: return "Wrist temp"
        case .sleepResp: return "Resp"
        case .sleepSpO2Mean, .awakeRestSpO2Mean, .awakeActiveSpO2Mean, .continuousSpO2Mean: return "SpO₂"
        case .awakeRestHR, .awakeActiveHR, .continuousHR: return "Heart rate"
        case .wakingSteps: return "Steps"
        case .wakingImuEnergy: return "Movement"
        case .awakeSupineHR: return "Lying HR"
        case .awakeSeatedHR: return "Seated HR"
        case .awakeUprightHR: return "Standing HR"
        case .awakeSupineHRVLn: return "Lying HRV"
        case .awakeSeatedHRVLn: return "Seated HRV"
        case .awakeUprightHRVLn: return "Standing HRV"
        case .walkingHR: return "Walking HR"
        case .sleepHR: return "Sleep HR"
        default: return series.planRow.planName
        }
    }

    func setLiveInterval(_ minutes: Int) {
        liveIntervalMinutes = WatchdogConfig.clampInterval(minutes)
        defaults.set(liveIntervalMinutes, forKey: WatchdogConfig.intervalKey)
    }

    func applyWatchdog(_ result: WatchdogResult) {
        watchdogResult = result
    }

    func loadWatchdogSidecars(deviceId: String) {
        eventRecovery = Self.decode(defaults.data(forKey: WatchdogEventRecovery.persistKey(deviceId: deviceId)))
        episodeAnnotations = Self.decode(defaults.data(forKey: WatchdogEpisodeAnnotation.persistKey(deviceId: deviceId))) ?? []
        episodeLedger = Self.decode(defaults.data(forKey: WatchdogEpisodeLedger.persistKey(deviceId: deviceId))) ?? []
    }

    /// After evaluate. Does not change severity, notify, or Layer 1 snapshots.
    func ingestLiveSidecars(result: WatchdogResult, deviceId: String, nowUnix: Int,
                            liveAlerts: Bool, evaluations: [LBEvaluation]) {
        if liveAlerts {
            let day = Self.dayKey(Date(timeIntervalSince1970: TimeInterval(nowUnix)))
            if let opened = WatchdogEventRecovery.openIfNeeded(
                existing: eventRecovery, episodeId: result.episodeId, deviceId: deviceId,
                nowUnix: nowUnix, civilDay: day, evaluations: evaluations, liveAlerts: true) {
                let hr = result.signals.first(where: { $0.name == "HR" })?.observed
                let hrv = result.signals.first(where: { $0.name == "HRV" })?.observed
                eventRecovery = WatchdogEventRecovery.step(
                    opened, hrBpm: hr, hrvMs: hrv, nowUnix: nowUnix,
                    unavailable: result.unavailable != nil)
                persist(eventRecovery, key: WatchdogEventRecovery.persistKey(deviceId: deviceId))
            }
            episodeLedger = WatchdogEpisodeLedger.upsert(
                rows: episodeLedger, result: result, deviceId: deviceId,
                nowUnix: nowUnix, liveAlerts: true)
            persist(episodeLedger, key: WatchdogEpisodeLedger.persistKey(deviceId: deviceId))
        }
    }

    func noteAfterSent(episodeId: String, deviceId: String, eventUnix: Int, liveAlerts: Bool) {
        episodeAnnotations = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: episodeAnnotations, episodeId: episodeId, deviceId: deviceId,
            eventUnix: eventUnix, delivery: "sent", liveAlerts: liveAlerts)
        persist(episodeAnnotations, key: WatchdogEpisodeAnnotation.persistKey(deviceId: deviceId))
        showEpisodeNoteSheet = episodeAnnotations.contains {
            $0.episodeId == episodeId && $0.status == .pending
        }
    }

    func saveEpisodeNote(_ row: WatchdogEpisodeAnnotation, deviceId: String) {
        episodeAnnotations = WatchdogEpisodeAnnotation.replace(episodeAnnotations, with: row)
        persist(episodeAnnotations, key: WatchdogEpisodeAnnotation.persistKey(deviceId: deviceId))
        showEpisodeNoteSheet = false
    }

    var pendingEpisodeNote: WatchdogEpisodeAnnotation? {
        episodeAnnotations.first(where: { $0.status == .pending })
    }

    func clinicianExportText(deviceId: String, nowUnix: Int = Int(Date().timeIntervalSince1970)) -> String {
        let start = nowUnix - 8 * 24 * 3600
        let evals = [evaluation, longEvaluation].compactMap { $0 }
        return WatchdogClinicianExport.build(
            deviceId: deviceId, startUnix: start, endUnix: nowUnix,
            ledger: episodeLedger, evaluations: evals, dayLogs: dayLogsByDay,
            annotations: episodeAnnotations, recovery: eventRecovery).text
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Usuals for every Watchdog vital, not only the series the patient currently has selected. v2 adds the
    /// context strata the live comparison is matched against (posture, steady walking, sleep HR).
    static let watchdogSeries: [LBSeries] = [
        .sleepRHR, .awakeRestHR, .continuousHR,
        .sleepHRVLn, .awakeRestHRVLn,
        .sleepTemp, .sleepResp, .sleepSpO2Mean,
        .sleepHR, .awakeSupineHR, .awakeSeatedHR, .awakeUprightHR, .walkingHR,
        .awakeSupineHRVLn, .awakeSeatedHRVLn, .awakeUprightHRVLn,
    ]

    func watchdogPromptEvaluations(days: [DailyMetric]) -> [LBEvaluation] {
        let asOf = Self.livePromptAsOf(days: days)
        let key = "\(asOf)|\(days.count)|\(days.last?.day ?? "")|\(days.last?.restingHr ?? -1)|\(contextVersion)|"
            + "\(dayLogsByDay.count)|\(dayTapeByDay[Self.dayKey(Date())]?.restHR.n ?? 0)|\(reanchorDays.count)"
        if let memo = promptMemo, memo.key == key { return memo.evals }
        let request = LBTrialRequest(dayLogsByDay: dayLogsByDay, referenceEpochs: referenceEpochs)
        let evals = Self.watchdogSeries.map { series in
            LongitudinalBaseline.evaluate(asOf: asOf, series: series,
                                          observations: observations(from: days, series: series),
                                          trial: request)
        }
        promptMemo = (key, evals)
        return evals
    }

    func nightCount(days: [DailyMetric], series: LBSeries) -> Int {
        observations(from: days, series: series)
            .filter { $0.qualityStatus == .ok }.count
    }

    /// Scoring tape only. Stub series (no DailyMetric column) stay empty — never +6 / ×0.88 / −0.2.
    func observations(from days: [DailyMetric], series: LBSeries) -> [LBDailyObservation] {
        if series == .wakingImuEnergy {
            return imuAccByDay.values.map(\.observation).sorted { $0.day < $1.day }
        }
        if series.hasDailyMetricColumn {
            return LongitudinalBaseline.observations(from: days, series: series)
        }
        let tape = dayTapeByDay.values.compactMap { $0.observation(series: series) }
        guard let materialized = contextObservations[series] else {
            return tape.sorted { $0.day < $1.day }
        }
        // Whole-day materialized values win; the live tape fills days the interval table does not cover yet.
        var byDay = Dictionary(tape.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        for o in materialized { byDay[o.day] = o }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Unique-minute stub series from the same window Watchdog scored. Does not write Layer 1 snapshots.
    func ingestWatchdogTape(window: WatchdogWindow, nowUnix: Int, lastWorkoutEndUnix: Int,
                             sleepIntervals: [WatchdogSleepInterval] = []) {
        let day = Self.dayKey(Date(timeIntervalSince1970: TimeInterval(nowUnix)))
        var tape = dayTapeByDay[day] ?? LBDayTape(day: day)
        guard tape.ingest(window: window, nowUnix: nowUnix, lastWorkoutEndUnix: lastWorkoutEndUnix,
                          sleepIntervals: sleepIntervals) else { return }
        dayTapeByDay[day] = tape
        if nowUnix - tapeLastPersistUnix >= 60 {
            persistDayTape()
            tapeLastPersistUnix = nowUnix
        }
    }

    /// Incremental IMU usual. New samples only; does not write Charge or other Layer 1 series.
    func ingestImu(samples: [WatchdogIMUSample], nowUnix: Int) {
        guard !samples.isEmpty else { return }
        let day = Self.dayKey(Date(timeIntervalSince1970: TimeInterval(nowUnix)))
        var acc = imuAccByDay[day] ?? LBImuDayAccumulator(day: day)
        guard acc.add(samples) else { return }
        imuAccByDay[day] = acc
        imuByDay[day] = acc.observation
        if nowUnix - imuLastPersistUnix >= 60 {
            persistImu()
            imuLastPersistUnix = nowUnix
        }
    }

    var medicationLabelToday: LBMedicationDayLabel {
        LBMedicationDayLabel.make(asOf: calendarTodayKey, events: events, log: calendarTodayLog)
    }

    var card: LBCardCopy { evaluation?.trial.card ?? .monitoring(building: true) }

    var asOfLabel: String { BaselinePlotScale.mediumDate(asOf) }
    var longAsOfLabel: String { BaselinePlotScale.mediumDate(longAsOf) }

    var activeTreatment: Bool {
        switch evaluation?.trial.phase {
        case .settlingIn, .onTreatment, .washingOut: return true
        default: return false
        }
    }

    var subtitle: String {
        if activeTreatment, let name = evaluation?.trial.displayName {
            return "\(name) · \(cardPhaseWord)"
        }
        return "Demonstration series so each period can be read."
    }

    /// Caption under the series name: rails come from unconfounded nights of this window.
    var quietRangeCaption: String {
        let window = evaluation?.stableWindow.caption ?? "this series"
        let k = evaluation?.kBandUsed ?? LongitudinalBaseline.params(for: series).kBand
        return String(format: "Usual and k from nights without logged confounders · %@ · k %.2f",
                      window, k)
    }

    /// Score nights on this phone. Empty repository → labelled demonstration tape only.
    func displayDays(from repoDays: [DailyMetric]) -> [DailyMetric] {
        if repoDays.isEmpty { return Self.demoTape() }
        return repoDays
    }

    func canShift(_ delta: Int, days: [DailyMetric]) -> Bool {
        if days.isEmpty { return false }
        guard let e = LongitudinalBaseline.isoEpochDay(asOf) else { return false }
        let next = LongitudinalBaseline.isoFromEpochDay(e + delta)
        if let newest = lastScoredDay(in: days), next > newest { return false }
        if let oldest = days.map(\.day).min(), next < oldest { return false }
        return true
    }

    /// Calendar-yesterday is often empty (sync lag). Score the newest night we actually hold.
    func clampAsOf(days: [DailyMetric]) {
        guard let newest = lastScoredDay(in: days) else { return }
        if asOf > newest { asOf = newest }
        if let oldest = days.map(\.day).min(), asOf < oldest { asOf = newest }
        if longAsOf > newest { longAsOf = newest }
        if let oldest = days.map(\.day).min(), longAsOf < oldest { longAsOf = newest }
    }

    func lastScoredDay(in days: [DailyMetric]) -> String? {
        let cap = Self.yesterdayKey()
        return days.map(\.day).filter { $0 <= cap }.max()
    }

    private var cardPhaseWord: String {
        switch evaluation?.trial.phase {
        case .settlingIn: return "Settling in"
        case .onTreatment: return "On treatment"
        case .washingOut: return "Washing out"
        case .ended: return "Ended"
        default: return ""
        }
    }

    func rescore(days: [DailyMetric], preferReadySeries: Bool = true) {
        clampAsOf(days: days)
        if !displayedSeries.contains(series) {
            series = displayedSeries.first ?? .sleepRHR
        }
        refreshSeriesReadiness(days: days)
        if preferReadySeries,
           seriesReadiness[series]?.ready != true,
           let ready = displayedSeries.first(where: { seriesReadiness[$0]?.ready == true }) {
            series = ready
        }
        let obs = observations(from: days, series: series)
        let freeze = loadFreeze(series: series)
        let trial = LBTrialRequest(events: events, freeze: freeze,
                                   confoundersByDay: confoundersByDay,
                                   dayLogsByDay: dayLogsByDay)
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: series,
                                               observations: obs, trial: trial)
        evaluation = ev
        if freeze == nil, ev.trial.trialFreezeOk, let bundle = ev.trial.freeze {
            saveFreeze(bundle, series: series)
        }
        let longEv = LongitudinalBaseline.evaluate(asOf: longAsOf, series: series,
                                                   observations: obs, trial: LBTrialRequest.none)
        longEvaluation = longEv
        weekPoints = plotPoints(obs: obs, endDay: asOf, span: 7)
        longPoints = plotPoints(obs: obs, endDay: longAsOf, span: 60)
        calendarSlots = calendar(obs: obs, asOf: asOf, t0: ev.trial.freeze?.t0CivilDay)
        refreshWatchCandidates(days: days)
        showContextSheet = false
    }

    func shiftDay(_ delta: Int, days: [DailyMetric]) {
        guard canShift(delta, days: days),
              let e = LongitudinalBaseline.isoEpochDay(asOf) else { return }
        asOf = LongitudinalBaseline.isoFromEpochDay(e + delta)
        rescore(days: days)
    }

    func shiftLongWeek(_ delta: Int, days: [DailyMetric]) {
        guard canShiftLongWeek(delta, days: days),
              let e = LongitudinalBaseline.isoEpochDay(longAsOf) else { return }
        longAsOf = LongitudinalBaseline.isoFromEpochDay(e + delta * 7)
        rescore(days: days)
    }

    func canShiftLongWeek(_ delta: Int, days: [DailyMetric]) -> Bool {
        if days.isEmpty { return false }
        guard let e = LongitudinalBaseline.isoEpochDay(longAsOf) else { return false }
        let next = LongitudinalBaseline.isoFromEpochDay(e + delta * 7)
        if let newest = lastScoredDay(in: days), next > newest { return false }
        if let oldest = days.map(\.day).min(), next < oldest { return false }
        return true
    }

    /// After a qualified freeze, the right box is the no-treatment path, not the live on-drug usual.
    func longCopyForPlot() -> LBCopySnapshot? {
        if let ev = evaluation, ev.trial.trialFreezeOk,
           let freeze = ev.trial.freeze {
            let math = ev.trial.expectedT ?? freeze.centerLong
            return Self.snapshot(center: math, spread: freeze.spreadLong, n: freeze.nLong, series: series)
        }
        return longEvaluation?.copyLong ?? evaluation?.copyLong
    }

    var shortConfidence: Int? {
        evaluation?.show7 == true ? evaluation?.usualTrustPct7 : nil
    }

    var longConfidence: Int? {
        longEvaluation?.showLong == true ? longEvaluation?.usualTrustPctLong : nil
    }

    var shortHowOff: Int? {
        guard let ev = evaluation, ev.show7, ev.usualTrustPct7 >= LongitudinalBaseline.trustHideThreshold else { return nil }
        return ev.howUnusualPct7
    }

    /// Longer usual keeps TRUST / IN RANGE. HOW OFF vs a 60-day path is not shown on the card.
    var longHowOff: Int? { nil }

    func isExploratory(_ series: LBSeries) -> Bool {
        guard let start = activeStart, !start.primarySeries.isEmpty else { return false }
        return !start.primarySeries.contains(series)
    }

    var longBoxTitle: String {
        if evaluation?.trial.trialFreezeOk == true {
            return "EXPECTED WITHOUT TREATMENT"
        }
        return "LONGER USUAL"
    }

    var shortVerdict: String {
        verdict(show: evaluation?.show7 ?? false, trust: evaluation?.usualTrustPct7,
                z: evaluation?.z7, k: evaluation?.kBandUsed ?? LongitudinalBaseline.params(for: series).kBand)
    }

    var longVerdict: String {
        if let ev = evaluation, ev.trial.trialFreezeOk {
            return verdict(show: true, trust: ev.usualTrustPctLong,
                           z: ev.trial.zTrialTraj,
                           k: ev.kBandUsed)
        }
        let ev = longEvaluation ?? evaluation
        return verdict(show: ev?.showLong ?? false, trust: ev?.usualTrustPctLong,
                       z: ev?.zLong, k: ev?.kBandUsed ?? LongitudinalBaseline.params(for: series).kBand)
    }

    private func verdict(show: Bool, trust: Int?, z: Double?, k: Double) -> String {
        if !show { return "BUILDING" }
        if (trust ?? 0) < LongitudinalBaseline.trustHideThreshold { return "NOT ENOUGH NIGHTS" }
        if evaluation?.stale == true { return "WEAK SIGNAL" }
        if LongitudinalBaseline.isOffUsual(z: z, k: k) { return "OFF" }
        return "IN RANGE"
    }

    static func snapshot(center: Double, spread: Double, n: Int, series: LBSeries) -> LBCopySnapshot {
        let k = LongitudinalBaseline.params(for: series).kBand
        let lo = center - k * spread
        let hi = center + k * spread
        return LBCopySnapshot(
            center: center, spread: spread,
            centerDisplay: LongitudinalBaseline.toDisplay(center, series: series),
            bandLoDisplay: LongitudinalBaseline.toDisplay(lo, series: series),
            bandHiDisplay: LongitudinalBaseline.toDisplay(hi, series: series),
            deltaDisplay: nil, z: nil, n: n,
            coverage: 1, lastUpdate: nil, version: "freeze", held: true)
    }

    func refreshSeriesReadiness(days: [DailyMetric]) {
        var next: [LBSeries: SeriesReadiness] = [:]
        for s in displayedSeries {
            let ev = LongitudinalBaseline.evaluate(
                asOf: asOf, series: s, observations: observations(from: days, series: s),
                trial: LBTrialRequest.none)
            next[s] = SeriesReadiness(show7: ev.show7, showLong: ev.showLong, n7: ev.n7, nLong: ev.nLong)
        }
        seriesReadiness = next
    }

    func nightsNeeded(for s: LBSeries) -> Int {
        let r = seriesReadiness[s]
        let n7 = r?.n7 ?? 0
        return max(0, LongitudinalBaseline.Params.n7Show - n7)
    }

    func selectContext(_ next: ContextFilter, days: [DailyMetric]) {
        context = next
        if !displayedSeries.contains(series) {
            series = displayedSeries.first ?? .sleepRHR
        }
        jumpToNewestNight(days: days)
        rescore(days: days)
    }

    func selectSeries(_ next: LBSeries, days: [DailyMetric]) {
        series = next
        jumpToNewestNight(days: days)
        rescore(days: days, preferReadySeries: false)
    }

    /// Set when a Monitor vital row opens the plots, so the plots' first rescore keeps that vital
    /// even while it is still learning.
    private(set) var seriesPinned = false

    func openVital(_ next: LBSeries, days: [DailyMetric]) {
        context = .sleep
        seriesPinned = true
        selectSeries(next, days: days)
    }

    func consumeSeriesPin() -> Bool {
        defer { seriesPinned = false }
        return seriesPinned
    }

    /// Metric / context switches always land on the newest scored night so the plots are current.
    func jumpToNewestNight(days: [DailyMetric]) {
        guard let newest = lastScoredDay(in: days) else { return }
        asOf = newest
        longAsOf = newest
    }

    func openDayLog(on day: String) {
        loggingDay = day
        showContextSheet = true
    }

    func logStart(name: String, dose: String?, civilDay: String, clockTime: String,
                  enteredBy: LBEnteredBy, kind: LBTreatmentKind = .medication,
                  days: [DailyMetric], onsetDays: Int? = 7, washoutDays: Int? = 7,
                  primarySeries: [LBSeries] = [], notes: String? = nil,
                  schedule: LBMedSchedule = .daily) {
        var watching = Array(primarySeries.prefix(3))
        if watching.isEmpty {
            watching = suggestWatchSeries(days: days, asOf: civilDay)
        }
        let event = LBTreatmentEvent(
            trialId: UUID().uuidString, type: .start, civilDay: civilDay, clockTime: clockTime,
            displayName: name, kind: kind, doseText: dose, enteredBy: enteredBy,
            notes: notes, onsetDays: onsetDays, washoutDays: washoutDays,
            primarySeries: watching, schedule: schedule)
        events.append(event)
        persistEvents()
        invalidateFreezes()
        showStartForm = false
        rescore(days: days)
    }

    /// Rank series by how solid the usual is (established + TRUST), never by post-start movement.
    func suggestWatchSeries(days: [DailyMetric], asOf freezeDay: String) -> [LBSeries] {
        rankedWatchCandidates(days: days, asOf: freezeDay)
            .prefix(3)
            .map(\.series)
    }

    func rankedWatchCandidates(days: [DailyMetric], asOf freezeDay: String) -> [BaselineWatchCandidate] {
        let pinned = Set(activeStart?.primarySeries ?? [])
        var rows: [BaselineWatchCandidate] = []
        for series in Self.allWiredSeries {
            let obs = observations(from: days, series: series)
            let ev = LongitudinalBaseline.evaluate(asOf: freezeDay, series: series, observations: obs)
            guard ev.show7 || ev.showLong else { continue }
            rows.append(BaselineWatchCandidate(
                series: series,
                trust: ev.usualTrustPctLong,
                established: ev.establishedLong,
                nLong: ev.nLong,
                pinned: pinned.contains(series)))
        }
        return rows.sorted { a, b in
            if a.established != b.established { return a.established && !b.established }
            if a.trust != b.trust { return a.trust > b.trust }
            return a.nLong > b.nLong
        }
    }

    func refreshWatchCandidates(days: [DailyMetric]) {
        guard activeStart != nil else {
            watchCandidates = []
            return
        }
        watchCandidates = rankedWatchCandidates(days: days, asOf: asOf)
    }

    func setWatchList(_ series: [LBSeries], days: [DailyMetric]) {
        guard let index = events.firstIndex(where: { $0.trialId == activeStart?.trialId && $0.type == .start }) else { return }
        events[index].primarySeries = Array(series.prefix(3))
        persistEvents()
        let pins = events[index].primarySeries
        for s in LBSeries.allCases {
            guard var bundle = loadFreeze(series: s) else { continue }
            bundle.primarySeries = pins
            saveFreeze(bundle, series: s)
        }
        rescore(days: days)
    }

    func toggleWatch(_ series: LBSeries, days: [DailyMetric]) {
        var pins = activeStart?.primarySeries ?? []
        if let i = pins.firstIndex(of: series) {
            pins.remove(at: i)
        } else if pins.count < 3 {
            pins.append(series)
        }
        setWatchList(pins, days: days)
    }

    func logDose(civilDay: String, clockTime: String, dose: String?, days: [DailyMetric]) {
        guard let start = activeStart else { return }
        let event = LBTreatmentEvent(
            trialId: start.trialId, type: .dose, civilDay: civilDay, clockTime: clockTime,
            displayName: start.displayName, kind: start.kind, doseText: dose,
            enteredBy: start.enteredBy)
        events.append(event)
        persistEvents()
        showDoseForm = false
        rescore(days: days)
    }

    var activeStart: LBTreatmentEvent? {
        let dated = events.sorted { ($0.civilDay, $0.clockTime) < ($1.civilDay, $1.clockTime) }
        guard let start = dated.last(where: { $0.type == .start }) else { return nil }
        if dated.contains(where: { $0.trialId == start.trialId && $0.type == .stop }) { return nil }
        return start
    }

    var canLogDose: Bool { activeStart != nil }

    var canEndTreatment: Bool { activeStart != nil }

    var canAddTreatment: Bool { true }

    func events(on civilDay: String) -> [LBTreatmentEvent] {
        events.filter { $0.civilDay == civilDay }
            .sorted { $0.clockTime < $1.clockTime }
    }

    var eventDays: Set<String> { Set(events.map(\.civilDay)) }

    func logEnd(civilDay: String, clockTime: String, reason: LBStopReason, days: [DailyMetric],
                washoutDays: Int? = nil, lastDoseDay: String? = nil, lastDoseClock: String? = nil,
                patientSaysClear: Bool = false, patientStillFeeling: Bool = false) {
        showEndForm = false
        guard let start = activeStart else { return }
        let event = LBTreatmentEvent(
            trialId: start.trialId, type: .stop, civilDay: civilDay, clockTime: clockTime,
            displayName: start.displayName, kind: start.kind, doseText: start.doseText,
            enteredBy: start.enteredBy, stopReason: reason,
            washoutDays: washoutDays, lastDoseDay: lastDoseDay, lastDoseClock: lastDoseClock,
            patientSaysClear: patientSaysClear, patientStillFeeling: patientStillFeeling)
        events.append(event)
        persistEvents()
        rescore(days: days)
    }

    func setDayLog(_ log: LBDayLog, on day: String, days: [DailyMetric]) {
        dayLogsByDay[day] = log
        persistDayLogs()
        let acute = log.acuteConfounders
        if acute.isEmpty {
            confoundersByDay.removeValue(forKey: day)
        } else {
            confoundersByDay[day] = acute
        }
        persistConfounders()
        showContextSheet = false
        rescore(days: days)
    }

    func setConfounders(on day: String, chips: [LBConfounder], days: [DailyMetric]) {
        if chips.isEmpty {
            confoundersByDay.removeValue(forKey: day)
        } else {
            confoundersByDay[day] = chips
        }
        persistConfounders()
        dismissedPromptDay = day
        defaults.set(day, forKey: dismissedPromptKey)
        showContextSheet = false
        rescore(days: days)
    }

    func updateEvent(at index: Int, name: String, dose: String?, civilDay: String,
                     clockTime: String, enteredBy: LBEnteredBy, kind: LBTreatmentKind,
                     days: [DailyMetric]) {
        guard events.indices.contains(index) else { return }
        let previous = events[index]
        events[index].displayName = name
        events[index].doseText = dose
        events[index].civilDay = civilDay
        events[index].clockTime = clockTime
        events[index].enteredBy = enteredBy
        events[index].kind = kind
        if previous.type == .start {
            for i in events.indices where events[i].trialId == previous.trialId {
                events[i].displayName = name
                events[i].kind = kind
            }
            if previous.civilDay != civilDay || previous.clockTime != clockTime {
                invalidateFreezes()
            }
        }
        persistEvents()
        editingEventIndex = nil
        rescore(days: days)
    }

    func deleteEvent(at index: Int, days: [DailyMetric]) {
        guard events.indices.contains(index) else { return }
        let removed = events.remove(at: index)
        if removed.type == .start {
            events.removeAll { $0.trialId == removed.trialId }
            invalidateFreezes()
        }
        persistEvents()
        editingEventIndex = nil
        rescore(days: days)
    }

    func beginEdit(index: Int) {
        editingEventIndex = index
    }

    private func invalidateFreezes() {
        for series in LBSeries.allCases {
            defaults.removeObject(forKey: freezeKeyPrefix + series.rawValue)
        }
    }

    func clearTreatment(days: [DailyMetric]) {
        events = []
        persistEvents()
        for series in LBSeries.allCases {
            defaults.removeObject(forKey: freezeKeyPrefix + series.rawValue)
        }
        pane = .monitor
        trialExpanded = false
        rescore(days: days)
    }

    func addConfounder(_ flag: LBConfounder, days: [DailyMetric]) {
        var flags = confoundersByDay[asOf] ?? []
        if !flags.contains(flag) { flags.append(flag) }
        setConfounders(on: asOf, chips: flags, days: days)
    }

    func dismissContextPrompt() {
        dismissedPromptDay = asOf
        defaults.set(asOf, forKey: dismissedPromptKey)
        showContextSheet = false
    }

    var labeledEventsToday: [LBConfounder] {
        if let log = dayLogsByDay[asOf] { return log.acuteConfounders }
        return confoundersByDay[asOf] ?? []
    }

    var todayLog: LBDayLog? { dayLogsByDay[asOf] }

    var loggingLog: LBDayLog? { dayLogsByDay[loggingDay] }

    var calendarTodayKey: String { Self.dayKey(Date()) }

    var calendarTodayLog: LBDayLog? { dayLogsByDay[calendarTodayKey] }

    var shortUsualReady: Bool {
        (evaluation?.show7 == true)
            && (evaluation?.usualTrustPct7 ?? 0) >= LongitudinalBaseline.trustHideThreshold
    }

    var longUsualReady: Bool {
        let ev = longEvaluation ?? evaluation
        return (ev?.showLong == true)
            && (ev?.usualTrustPctLong ?? 0) >= LongitudinalBaseline.trustHideThreshold
    }

    var usualsReady: Bool { shortUsualReady || longUsualReady }

    var usualsReadyCaption: String {
        switch (shortUsualReady, longUsualReady) {
        case (true, true):
            return "Short-term and long-term baselines are fully calculated."
        case (false, true):
            return "Long-term baseline is fully calculated."
        case (true, false):
            return "Short-term baseline is fully calculated."
        default:
            return "Still learning your usuals."
        }
    }

    /// Night vitals with a DailyMetric column, in the order the Today ring and Monitor list them.
    static let vitalsCheckSeries: [LBSeries] = [.sleepRHR, .sleepHRVLn, .sleepTemp, .sleepResp, .sleepSpO2Mean]

    /// Last scored night of each night vital against its own usual. Real nights only: the demo tape
    /// never reaches this, so an empty repository reads as no data rather than a made-up count.
    func refreshVitalsCheck(days: [DailyMetric]) {
        guard let night = lastScoredDay(in: days) else {
            vitalsCheck = nil
            return
        }
        let vitals = Self.vitalsCheckSeries.map { series -> BaselineVitalsCheck.Vital in
            let trial = LBTrialRequest(events: events, freeze: loadFreeze(series: series),
                                       confoundersByDay: confoundersByDay,
                                       dayLogsByDay: dayLogsByDay)
            let ev = LongitudinalBaseline.evaluate(asOf: night, series: series,
                                                   observations: observations(from: days, series: series),
                                                   trial: trial)
            return BaselineVitalsCheck.Vital.make(series: series, name: shortTitle(for: series), ev: ev)
        }
        vitalsCheck = BaselineVitalsCheck(night: night, vitals: vitals)
    }

    /// Each listed day's verdict against its own usual for `series`: the call `refreshVitalsCheck` makes for the
    /// last scored night, with the same observations, treatment events, freeze and day logs. The key-metric
    /// screens draw the bands as the person's usual range. Each day is a Layer 1 replay, so the work runs off the
    /// main actor and stops early when the caller's task is cancelled.
    func usualVerdicts(series: LBSeries, days: [DailyMetric], on dayKeys: [String]) async -> [String: LBVitalVerdict] {
        guard !dayKeys.isEmpty else { return [:] }
        let observations = observations(from: days, series: series)
        let trial = LBTrialRequest(events: events, freeze: loadFreeze(series: series),
                                   confoundersByDay: confoundersByDay, dayLogsByDay: dayLogsByDay)
        let work = Task.detached(priority: .userInitiated) { () -> [String: LBVitalVerdict] in
            var out: [String: LBVitalVerdict] = [:]
            for day in dayKeys {
                if Task.isCancelled { break }
                let ev = LongitudinalBaseline.evaluate(asOf: day, series: series, observations: observations,
                                                       trial: trial)
                out[day] = LongitudinalBaseline.vitalVerdict(ev)
            }
            return out
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    static func yesterdayKey(now: Date = Date()) -> String {
        let cal = Calendar.current
        let y = cal.date(byAdding: .day, value: -1, to: now) ?? now
        return dayKey(y)
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// ~80 nights ending 2026-09-11: quiet longer usual, a late spike, and a raised last week.
    static func demoTape(asOf: String = "2026-09-11") -> [DailyMetric] {
        guard let t = LongitudinalBaseline.isoEpochDay(asOf) else { return [] }
        return (t - 80...t).map { e in
            let age = Double(e - (t - 80))
            let fever = e >= t - 7
            let longSpike = e >= t - 20 && e <= t - 16
            let rhr = 60.0 + 2.2 * sin(age / 5.0) + (fever ? 8 : 0) + (longSpike ? 16 : 0)
            let hrv = 48.0 - 1.4 * sin(age / 6.0) - (fever ? 6 : 0) - (longSpike ? 10 : 0)
            let temp = 33.05 + 0.12 * sin(age / 7.0) + (fever ? 0.35 : 0) + (longSpike ? 0.6 : 0)
            let resp = 14.0 + 0.4 * sin(age / 4.0) + (fever ? 1.2 : 0) + (longSpike ? 2.4 : 0)
            let spo2 = 97.2 - (fever ? 0.8 : 0) - (longSpike ? 1.6 : 0)
            let steps = 7800.0 + 900 * sin(age / 3.0) - (fever ? 1800 : 0)
            return daily(day: LongitudinalBaseline.isoFromEpochDay(e),
                         rhr: Int(rhr.rounded()),
                         hrv: hrv,
                         temp: temp,
                         resp: resp,
                         spo2: spo2,
                         steps: Int(steps.rounded()))
        }
    }

    static func daily(day: String, rhr: Int? = nil, hrv: Double? = nil, temp: Double? = nil,
                      resp: Double? = nil, spo2: Double? = nil, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                    recovery: nil, strain: nil, exerciseCount: nil, spo2Pct: spo2,
                    respRateBpm: resp, steps: steps, skinTempC: temp)
    }

    /// Inclusive nights through `endDay`. The scored night is drawn so a labeled outlier is visible;
    /// it is still not folded into the usual itself.
    private func plotPoints(obs: [LBDailyObservation], endDay: String, span: Int) -> [BaselinePlotPoint] {
        guard let t = LongitudinalBaseline.isoEpochDay(endDay) else { return [] }
        let lo = t - span
        let hi = t
        var byDay: [String: LBDailyObservation] = [:]
        for o in obs { byDay[o.day] = o }
        var out: [BaselinePlotPoint] = []
        var segment = 0
        for e in lo...hi {
            let day = LongitudinalBaseline.isoFromEpochDay(e)
            let o = byDay[day]
            let missing = o == nil || o?.qualityStatus != .ok
            let v = missing ? nil : o?.value
            let acute = dayLogsByDay[day]?.confoundsUsual == true
                || !(confoundersByDay[day] ?? []).filter(\.isAcute).isEmpty
            out.append(BaselinePlotPoint(day: day, epoch: e, value: v,
                                         missing: missing, segment: segment,
                                         inShortWindow: true, explained: acute,
                                         isScoredNight: e == t))
            if missing { segment += 1 }
        }
        return out
    }

    private func calendar(obs: [LBDailyObservation], asOf: String, t0: String?) -> [BaselineCalendarSlot] {
        guard let t = LongitudinalBaseline.isoEpochDay(asOf) else { return [] }
        var byDay: [String: LBDailyObservation] = [:]
        for o in obs { byDay[o.day] = o }
        return (t - 60...t).map { e in
            let day = LongitudinalBaseline.isoFromEpochDay(e)
            let o = byDay[day]
            let fill: BaselineCalendarSlot.Fill
            if e == t { fill = .today }
            else if o?.qualityStatus == .ok { fill = .ok }
            else if o?.qualityStatus == .lowQuality { fill = .lowQuality }
            else { fill = .missing }
            return BaselineCalendarSlot(day: day, fill: fill, isStart: day == t0,
                                        reason: o?.qualityReason?.rawValue)
        }
    }

    private func persistEvents() {
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: eventsKey)
        }
    }

    private func saveFreeze(_ bundle: LBFreezeBundle, series: LBSeries) {
        if let data = try? JSONEncoder().encode(bundle) {
            defaults.set(data, forKey: freezeKeyPrefix + series.rawValue)
        }
    }

    private func loadFreeze(series: LBSeries) -> LBFreezeBundle? {
        guard let data = defaults.data(forKey: freezeKeyPrefix + series.rawValue) else { return nil }
        return try? JSONDecoder().decode(LBFreezeBundle.self, from: data)
    }

    private func persistConfounders() {
        if let data = try? JSONEncoder().encode(confoundersByDay) {
            defaults.set(data, forKey: confoundersKey)
        }
    }

    private func persistDayLogs() {
        if let data = try? JSONEncoder().encode(dayLogsByDay) {
            defaults.set(data, forKey: dayLogsKey)
        }
    }

    private func persistImu() {
        if let data = try? JSONEncoder().encode(Array(imuAccByDay.values)) {
            defaults.set(data, forKey: imuKey)
        }
    }

    private func persistDayTape() {
        if let data = try? JSONEncoder().encode(Array(dayTapeByDay.values)) {
            defaults.set(data, forKey: tapeKey)
        }
    }

    private static func loadImu(defaults: UserDefaults) -> [String: LBImuDayAccumulator] {
        guard let data = defaults.data(forKey: "noop.baseline.imu.v1"),
              let rows = try? JSONDecoder().decode([LBImuDayAccumulator].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
    }

    /// Live UniTS prompt uses last completed civil day, not the Baseline calendar swipe.
    static func livePromptAsOf(days: [DailyMetric]) -> String {
        let today = dayKey(Date())
        let yesterday = yesterdayKey()
        if let newest = days.map(\.day).filter({ $0 < today }).max() {
            return newest
        }
        return yesterday
    }

    private static func loadDayTape(defaults: UserDefaults) -> [String: LBDayTape] {
        if let data = defaults.data(forKey: "noop.baseline.daytape.v2"),
           var rows = try? JSONDecoder().decode([LBDayTape].self, from: data) {
            for i in rows.indices { rows[i].migrateHrvFromLnIfNeeded() }
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
        }
        guard let data = defaults.data(forKey: "noop.baseline.daytape.v1"),
              var rows = try? JSONDecoder().decode([LBDayTape].self, from: data) else { return [:] }
        for i in rows.indices { rows[i].migrateHrvFromLnIfNeeded() }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
    }

    private static func loadEvents(defaults: UserDefaults) -> [LBTreatmentEvent] {
        guard let data = defaults.data(forKey: "noop.baseline.events.v1") else { return [] }
        return (try? JSONDecoder().decode([LBTreatmentEvent].self, from: data)) ?? []
    }

    private static func loadConfounders(defaults: UserDefaults) -> [String: [LBConfounder]] {
        guard let data = defaults.data(forKey: "noop.baseline.confounders.v1") else { return [:] }
        return (try? JSONDecoder().decode([String: [LBConfounder]].self, from: data)) ?? [:]
    }

    private static func loadDayLogs(defaults: UserDefaults) -> [String: LBDayLog] {
        guard let data = defaults.data(forKey: "noop.baseline.daylog.v1") else { return [:] }
        return (try? JSONDecoder().decode([String: LBDayLog].self, from: data)) ?? [:]
    }
}

/// Display-only: how far a point sits past the usual band. Does not change k, z, or verdicts.
enum BaselineOffPaint {
    /// `nil` when the value is inside `[lo, hi]`. `0` at the edge, `1` at one extra half-band beyond.
    static func strength(value: Double, lo: Double, hi: Double) -> Double? {
        if value >= lo && value <= hi { return nil }
        let half = max((hi - lo) / 2, 1e-9)
        let over = max(value - hi, lo - value)
        return min(1, over / half)
    }
}

enum BaselinePlotScale {
    static func date(fromISO day: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day) ?? Date(timeIntervalSince1970: 0)
    }

    static func mediumDate(_ day: String) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f.string(from: date(fromISO: day))
    }

    static func shortDate(_ day: String) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date(fromISO: day))
    }

    /// Fitted to the hatch and plotted nights, not a 30–120 physiological span.
    static func yDomain(values: [Double], bandLo: Double?, bandHi: Double?) -> ClosedRange<Double> {
        var ys = values
        if let bandLo { ys.append(bandLo) }
        if let bandHi { ys.append(bandHi) }
        guard let lo = ys.min(), let hi = ys.max() else { return 0...1 }
        let span = max(hi - lo, 0)
        let pad = max(baselinePad(span: span), span * 0.18)
        return (lo - pad)...(hi + pad)
    }

    static func baselinePad(span: Double) -> Double {
        if span < 2 { return 0.8 }
        if span < 8 { return 1.2 }
        if span < 40 { return 1.5 }
        return max(40, span * 0.08)
    }

    static func formatTick(_ value: Double, domain: ClosedRange<Double>) -> String {
        let span = domain.upperBound - domain.lowerBound
        if span < 8 { return String(format: "%.1f", value) }
        if span < 400 { return String(format: "%.0f", value) }
        return String(format: "%.0f", value)
    }

    static func ticks(in domain: ClosedRange<Double>, count: Int = 4) -> [Double] {
        let n = max(2, count)
        let step = (domain.upperBound - domain.lowerBound) / Double(n - 1)
        return (0..<n).map { domain.lowerBound + Double($0) * step }
    }
}

struct BaselinePlotPoint: Identifiable, Equatable {
    var day: String
    var epoch: Int
    var value: Double?
    var missing: Bool
    var segment: Int = 0
    var inShortWindow: Bool = false
    var explained: Bool = false
    var isScoredNight: Bool = false
    var id: String { day }
    var date: Date { BaselinePlotScale.date(fromISO: day) }
}

struct BaselineWatchCandidate: Identifiable, Equatable {
    var series: LBSeries
    var trust: Int
    var established: Bool
    var nLong: Int
    var pinned: Bool
    var id: String { series.rawValue }
}

struct BaselineCalendarSlot: Identifiable, Equatable {
    enum Fill: Equatable { case ok, lowQuality, missing, today }
    var day: String
    var fill: Fill
    var isStart: Bool
    var reason: String?
    var id: String { day }
}
