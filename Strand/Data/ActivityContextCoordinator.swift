import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// What the activity classifier does after the strap's data lands on the phone.
///
/// 1. **The stand reminder.** The rolling-window rule (`StandReminderEngine`) is run over the live day's
///    activity context. It is judged from the classifier and the step counter, never from elapsed time alone,
///    and its de-dup state is persisted so a relaunch cannot judge the same window twice.
/// 2. **The persisted context.** Each local day's context is written to the `activityContextInterval` and
///    `activityContextDay` tables, so a later question (a score, the coach, a query) can join physiology
///    against what the wearer was doing without decoding anything. Which days need writing is decided by
///    `ActivityContextMaterialization`, from a few indexed lookups, so an idle pass costs almost nothing.
///
/// Both read the same decoded day (`Repository.activityContext(from:)`), which the Heart rate page also reads
/// through the same on-disk cache: the classification a reminder acts on, the timeline a person sees and the
/// rows the coach reads are one result.
@MainActor
final class ActivityContextCoordinator {
    typealias Day = ActivityContextMaterialization.Day

    private let repo: Repository
    private let isWorn: () -> Bool
    private let remind: (_ loops: UInt8, _ windowMinutes: Int) -> Void
    private let log: (String) -> Void
    private let timeZone: () -> TimeZone
    private let horizonDays: Int
    private let smooth: Smoother
    private let smoothedEmpty: RetrospectiveEmptyMarks

    /// The retrospective smoother (D8-10): `ActivityContextPersistence.retrospectiveIntervals` in production;
    /// injectable so a test can drive a final day whose smoothing yields nothing.
    typealias Smoother = @Sendable (_ document: ActivityContextDayDocument, _ events: [ActivityTransitionEvent],
                                    _ hr: [HRSample], _ steps: [StepSample], _ rr: [RRInterval],
                                    _ from: Int, _ to: Int, _ finality: String) -> [ActivityContextInterval]
    nonisolated static let defaultSmoother: Smoother = { document, events, hr, steps, rr, from, to, finality in
        ActivityContextPersistence.retrospectiveIntervals(document: document, events: events, hr: hr, steps: steps,
                                                          rr: rr, from: from, to: to, finality: finality)
    }

    private var isEvaluatingStand = false
    private var lastStandReason: StandReminderEngine.Reason?

    private var materializeTask: Task<Void, Never>?
    private var materializeAgain = false
    /// What this process last saw of each day. Not persisted itself; the input fingerprint a day was derived
    /// from is, in its ledger row, so a relaunch still sees late input.
    private var checks: [Int: ActivityContextMaterialization.Check] = [:]
    /// When a day last failed to be written, so one that keeps failing is not retried on every pass.
    private var failures: [Int: Int] = [:]

    /// Days a first run is allowed to reach back. The heart-rate caches the decoder reads are kept for 45 days;
    /// an older day is decoded from its samples, a few per pass.
    nonisolated static let defaultHorizonDays = 120
    nonisolated static let retryAfterFailureS = 900
    /// How often a day still in progress, whose saved context is current, is re-derived for new heart rate
    /// alone. A worn strap adds heart rate every second, so the planner always finds today stale, and every
    /// completed sync (once a minute in cloud mode, foreground and background alike) re-derived the whole day
    /// so far: about 600 intervals over up to 250,000 beats, rewritten in full, for a table only the coach
    /// reads. A first derivation, a stale ledger, a day that has just closed and a failed write are not held.
    nonisolated static let openDayRederiveFloorS = 900
    /// Stops a backlog drain that never finishes from running for ever in one session.
    nonisolated static let maxChainedPasses = 80
    nonisolated static let pauseBetweenBacklogPassesNs: UInt64 = 20_000_000_000

    init(repo: Repository,
         horizonDays: Int = ActivityContextCoordinator.defaultHorizonDays,
         isWorn: @escaping () -> Bool,
         remind: @escaping (_ loops: UInt8, _ windowMinutes: Int) -> Void,
         log: @escaping (String) -> Void,
         timeZone: @escaping () -> TimeZone = { .current },
         smooth: @escaping Smoother = ActivityContextCoordinator.defaultSmoother,
         retrospectiveMarks: UserDefaults = .standard) {
        self.repo = repo
        self.horizonDays = horizonDays
        self.isWorn = isWorn
        self.remind = remind
        self.log = log
        self.timeZone = timeZone
        self.smooth = smooth
        self.smoothedEmpty = RetrospectiveEmptyMarks(defaults: retrospectiveMarks)
    }

    // MARK: - Stand reminder

    /// Judge the rolling window ending at the newest data and, when the rule says so, remind. Quietly does
    /// nothing unless the user turned the reminder on.
    func evaluateStandReminder() async {
        guard !isEvaluatingStand else { return }
        let config = InactivityPrefs.loadStandConfig()
        guard config.enabled, config.notificationsMasterOn else { return }
        isEvaluatingStand = true
        defer { isEvaluatingStand = false }

        let nowSec = Int(Date().timeIntervalSince1970)
        let days = ActivityContextMaterialization.localDays(endingAt: nowSec, count: 2, timeZone: timeZone())
        guard let today = days.first, let current = await loadDay(today) else { return }

        // The engine's window ends at the newest data, which can trail the clock by up to `staleAfterSeconds`
        // before the data is rejected as stale, so reach that much further back than "now - window".
        let reach = nowSec - config.staleAfterSeconds - config.windowSeconds
        var runs = current.document.runs
        var counter = current.streams.stepCounter
        if reach < today.start, days.count > 1, let earlier = await loadDay(days[1]) {
            runs = earlier.document.runs.filter { $0.end > reach } + runs
            counter = earlier.streams.stepCounter + counter
        }

        let decision = StandReminderEngine.evaluate(
            runs: runs,
            stepTicks: StandReminderEngine.stepTicks(from: counter, start: reach, end: nowSec),
            state: InactivityPrefs.loadStandState(), config: config, worn: isWorn(),
            nowSec: nowSec, tzOffsetSec: InactivityPrefs.tzOffsetSec(nowSec))
        InactivityPrefs.saveStandState(decision.nextState)

        // Data already judged says nothing new; it must not displace the outcome the log last reported.
        if decision.reason != .replayed {
            if decision.shouldRemind || decision.reason != lastStandReason {
                log(Self.standLogLine(decision, windowMinutes: config.windowMinutes))
            }
            lastStandReason = decision.reason
        }
        if decision.shouldRemind {
            remind(UInt8(clamping: decision.buzzLoops), config.windowMinutes)
        }
    }

    /// One line for the shareable log: what the rule saw, so a reminder (or a missing one) can be explained.
    static func standLogLine(_ decision: StandReminderEngine.Decision, windowMinutes: Int) -> String {
        guard let w = decision.window else { return "Stand reminder: \(decision.reason.rawValue)" }
        func percent(_ v: Double) -> Int { Int((v * 100).rounded()) }
        return "Stand reminder: \(decision.reason.rawValue) (\(windowMinutes)-min window: \(w.movementSeconds) s "
            + "standing or moving, \(percent(w.coverage))% observed, \(percent(w.sedentaryShare))% sedentary "
            + "(sitting or standing))"
    }

    // MARK: - Persisted context

    /// Ask for a pass over the days that need their context written. Passes never overlap: a request made
    /// while one is running makes it go round once more when it finishes. A first run over a long history
    /// is spread over several passes a little apart rather than decoded in one go.
    func requestMaterialization() {
        guard materializeTask == nil else { materializeAgain = true; return }
        materializeTask = Task { [weak self] in
            await self?.drainMaterialization()
            self?.materializeTask = nil
        }
    }

    /// Passes until nothing is left to do: another when a request came in during one, and more (a little apart)
    /// while the per-pass backlog limit is what ended the last. Exposed so a test can await the whole run.
    func drainMaterialization(pauseNs: UInt64 = ActivityContextCoordinator.pauseBetweenBacklogPassesNs) async {
        var passes = 0
        while !Task.isCancelled {
            materializeAgain = false
            let moreBacklog = await runMaterializationPass()
            passes += 1
            if materializeAgain { continue }
            guard moreBacklog, passes < Self.maxChainedPasses else { break }
            try? await Task.sleep(nanoseconds: pauseNs)
        }
    }

    /// One pass. Returns true when it stopped at the per-pass backlog limit, so more old days may be waiting.
    private func runMaterializationPass() async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let nowSec = Int(Date().timeIntervalSince1970)
        let days = ActivityContextMaterialization.localDays(endingAt: nowSec, count: horizonDays, timeZone: timeZone())
        let ids = repo.rawPhysiologyReadIds(store: store)
        guard !ids.isEmpty else { return false }
        let ledgers = await repo.activityContextLedgers(store: store, ids: ids, days: days)

        var owners: [Int: Repository.ActivityContextOwner] = [:]
        var fingerprints: [Int: String] = [:]
        var tails: [Int: [ActivityTransitionEvent]] = [:]
        var configTags: [Int: String] = [:]
        var candidates: [ActivityContextMaterialization.Candidate] = []
        var unanswered: Set<Int> = []
        for day in days {
            let probed: Repository.ActivityContextOwner?
            do {
                probed = try await repo.activityContextOwner(store: store, ids: ids, from: day.start, to: day.end)
            } catch {
                unanswered.insert(day.start)
                log("Activity context: could not read \(day.key)'s heart rate: \(error)")
                continue
            }
            guard let owner = probed else { continue }
            owners[day.start] = owner
            let configTag = repo.activityContextLedgerConfigTag(dayStart: day.start)
            configTags[day.start] = configTag
            // The witness of everything the decode reads (every raw id's streams, sleep, workouts, the server's
            // windows, the config): `needsWork` compares it with the one the day's ledger recorded when it was
            // derived — persisted, so a late backfill to an old day is seen after a relaunch too — and with what
            // this process last saw. Equal-count *value* corrections are caught by the track's content
            // fingerprint once the day is re-examined.
            // The previous day's last events are input too: the day's first rows settle on them. Witnessed by their
            // content ("" with none), so the day is derived again once the day before it is stored or its last
            // minutes change, and not otherwise.
            let tail = await previousDayTail(day, ids: ids, store: store)
            tails[day.start] = tail
            if let fingerprint = await repo.activityContextInputFingerprint(store: store, ids: ids, day: day,
                                                                             ownerId: owner.deviceId, configTag: configTag) {
                fingerprints[day.start] = fingerprint + ActivityContextPersistence.tailFingerprint(tail)
            }
            // Rule 7 is on: `materialize` writes retrospective rows for every final day it derives, so a final
            // day without this smoother's rows is derived once more (and, once it has them, never re-planned).
            // A final day whose smoothing at this version, from this input, already came out empty is done: the store
            // cannot record an empty result (`replaceActivityContext` sets the ledger's version to nil without
            // rows), so the phone remembers it instead and rule 7 is off for that day.
            let ledger = ledgers[owner.deviceId]?[day.start]
            let smoothedToNothing = ledger.map { smoothedEmpty.covers($0, deviceId: owner.deviceId) } ?? false
            candidates.append(.init(day: day, ledger: ledger,
                                    newestHeartRateTs: owner.newestHeartRateTs, lastCheck: checks[day.start],
                                    inputFingerprint: fingerprints[day.start], configTag: configTag,
                                    retrospectiveVersion: smoothedToNothing ? nil : ActivityContextRetrospective.version))
        }

        // A day that still has stored context but no heart rate under any id (samples moved out, a device's data
        // deleted) is forgotten under every id, so nothing describes seconds that have no data behind them. Only a
        // pass whose every probe was answered clears anything: a failed read is not "no heart rate".
        let ledgerDays = Set(ledgers.values.flatMap(\.keys))
        for day in ActivityContextMaterialization.orphanedDays(days, ledgerDays: ledgerDays, owned: Set(owners.keys),
                                                               unanswered: unanswered) {
            do {
                try await store.clearActivityContext(deviceIds: ids, from: day.start, to: day.end)
                checks[day.start] = nil
                log("Activity context: cleared \(day.key), which no longer has heart rate")
            } catch {
                log("Activity context: could not clear \(day.key): \(error)")
            }
        }

        let planned = ActivityContextMaterialization.plan(candidates, now: nowSec)
        let due = planned.filter { day in
            if let failedAt = failures[day.start], nowSec - failedAt < Self.retryAfterFailureS { return false }
            return !holdsOpenDay(day, ledger: owners[day.start].flatMap { ledgers[$0.deviceId]?[day.start] },
                                 now: nowSec)
        }
        for day in due {
            guard let owner = owners[day.start] else { continue }
            await materialize(day, owner: owner, ledger: ledgers[owner.deviceId]?[day.start],
                              inputFingerprint: fingerprints[day.start], previousEvents: tails[day.start] ?? [],
                              configTag: configTags[day.start] ?? repo.activityContextLedgerConfigTag(dayStart: day.start),
                              ids: ids, store: store)
        }
        let oldDays = planned.filter { !ActivityContextMaterialization.isRecent($0, now: nowSec) }.count
        return oldDays >= ActivityContextMaterialization.Config().maxBacklogPerPass
    }

    /// Whether `day` is still in progress, already has a current saved context, and was derived less than
    /// `openDayRederiveFloorS` ago (see there).
    private func holdsOpenDay(_ day: Day, ledger: ActivityContextDayRow?, now: Int) -> Bool {
        guard day.end > now, let ledger, ActivityContextPersistence.isCurrent(ledger),
              let last = checks[day.start]?.at else { return false }
        return now - last < Self.openDayRederiveFloorS
    }

    /// The previous day's events in the `hrvEventLookbackS` before `day`, as stored with that day under any of `ids`.
    /// Empty when that day is not stored yet (or the read failed): the day's first rows and windows then see no
    /// event before the day, as before.
    private func previousDayTail(_ day: Day, ids: [String], store: WhoopStore) async -> [ActivityTransitionEvent] {
        var rows: [ActivityContextTransitionRow] = []
        for id in ids {
            rows += (try? await store.activityContextTransitions(
                deviceId: id, from: day.start - ActivityContextPersistence.hrvEventLookbackS, to: day.start)) ?? []
        }
        return ActivityContextPersistence.events(rows)
    }

    private func materialize(_ day: Day, owner: Repository.ActivityContextOwner, ledger: ActivityContextDayRow?,
                             inputFingerprint: String?, previousEvents: [ActivityTransitionEvent],
                             configTag: String, ids: [String], store: WhoopStore) async {
        let startedAt = Int(Date().timeIntervalSince1970)
        checks[day.start] = .init(at: startedAt, newestHeartRateTs: owner.newestHeartRateTs,
                                  inputFingerprint: inputFingerprint)
        guard let loaded = await loadDay(day) else {
            failures[day.start] = Int(Date().timeIntervalSince1970)
            return
        }
        // Decoded to the same horizon by the same rules and config, from the same input, as what is already saved:
        // nothing to write but whether the day is now final. (`covers` compares the decode's timestamp to the
        // second; when the input witness moved, the rows are written again rather than trusting that.) A day that
        // is final but lacks this smoother's retrospective rows falls through to the full write, which adds them.
        if let ledger, ledger.inputFingerprint == inputFingerprint,
           ActivityContextMaterialization.covers(ledger, document: loaded.document, configTag: configTag) {
            let finality = ActivityContextPersistence.finality(
                sleepKnownOutsideSessions: loaded.document.sleepKnownOutsideSessions, dayEnd: day.end, at: startedAt)
            let settled = ledger.isFinal ? ActivityContextDayRow.final : finality
            let needsRetrospective = settled == ActivityContextDayRow.final
                && ledger.retrospectiveVersion != ActivityContextRetrospective.version
                && !smoothedEmpty.covers(ledger, deviceId: owner.deviceId)
            if !needsRetrospective {
                if ledger.finality != settled {
                    _ = try? await store.updateActivityContextDayStatus(deviceId: owner.deviceId, dayStart: ledger.dayStart,
                                                                        inputFingerprint: inputFingerprint, finality: settled)
                }
                return
            }
        }

        let streams = loaded.streams
        let beats = await repo.rrIntervals(from: streams.start, to: streams.end, limit: 250_000)
        let document = loaded.document, hr = streams.hr, steps = streams.stepCounter, gravity = streams.gravity
        // The previous day's last minutes, as stored with that day, so the day's first rows and HRV windows see a
        // change of position or the end of a walk or a workout just before midnight: its events (read when the
        // pass planned the day, and witnessed in its input fingerprint) as settling anchors and for the windows'
        // recovery lookback, and its intervals for the windows' time-since-locomotion / exercise gates. Empty when
        // that day is not stored yet.
        var previousRows: [[ActivityContextInterval]] = []
        for id in ids {
            let rows = (try? await store.activityContextIntervals(
                deviceId: id, from: day.start - ActivityContextPersistence.hrvIntervalLookbackS, to: day.start)) ?? []
            previousRows.append(rows.map(ActivityContextInterval.init(row:)))
        }
        let previousIntervals = ActivityContextPersistence.merged(previousRows)
        // The wearer's answers on these seconds ("not wearing", "it was a walk"), laid over the windows' lookup the
        // same way `storedActivityContext` lays them over what it reads, so a stretch the wearer corrected never
        // vouches for an HRV window. The saved intervals stay the decoder's own output.
        let feedback = StretchFeedbackStore.shared.verdicts(
            overlapping: day.start - ActivityContextPersistence.hrvIntervalLookbackS, to: day.end)
        // Retrospective smoothing (D8-10) reads later seconds of the day, so only a day already final when it is
        // written gets it; the same rule `dayRow` stamps the ledger's finality with.
        let finality = ActivityContextPersistence.finality(
            sleepKnownOutsideSessions: document.sleepKnownOutsideSessions, dayEnd: day.end, at: startedAt)
        let smooth = self.smooth
        let (built, hrvWindows, smoothed) = await Task.detached(priority: .utility) {
            let events = ActivityContextPersistence.hrvEvents(day: document.events, previous: previousEvents,
                                                              dayStart: document.dayStart)
            let intervals = ActivityContextIntervalBuilder.build(runs: document.runs, events: events,
                                                                 hr: hr, steps: steps, rr: beats)
            // Fed by exactly the same live beat-to-beat R-R and the strap's always-on 1 Hz motion stream the
            // interval build above uses (no fabricated/placeholder data): see `HRVWindow.swift`'s header for
            // why this is a SEPARATE, canonical-duration population from `intervals`'s own per-interval RMSSD.
            // `imuWindows` is left empty: the strap does not stream raw 100 Hz IMU continuously during normal
            // wear (only during an opt-in Raw Data collector session), so `motionRmsG` falls back to the 1 Hz
            // stream and `gyroRmsDps` stays honestly nil here rather than inventing a reading.
            let lookup = ActivityContextLookup(intervals: ActivityContextCorrections.applying(
                feedback, to: ActivityContextPersistence.hrvIntervals(
                    day: intervals, previous: previousIntervals, dayStart: document.dayStart)))
            // The phone's day document carries runs, not per-epoch wear signal (that is server-only, in the
            // C10 epochs), so every window resolves wearSignal nil here. These windows only feed the
            // diagnostic line today; no score or baseline reads them yet.
            let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: document.dayStart, dayEnd: document.dayEnd,
                                                 rr: beats, gravity: gravity, activity: lookup,
                                                 transitionEvents: events,
                                                 epochWearSignal: [])
            // Historical readers only (`reading: .historical`). Never the lookup above, never a causal consumer.
            let smoothed = smooth(document, events, hr, steps, beats, day.start, day.end, finality)
            return (intervals, windows, smoothed)
        }.value
        log(HRVWindowSummary.diagLine(hrvWindows, kind: .canonical5m, day: day.key))
        let intervals = ActivityContextPersistence.clipped(built, from: day.start, to: day.end)
        let retrospective = smoothed   // empty unless the day is final
        let row = ActivityContextPersistence.dayRow(day: day.key, document: document, intervalCount: intervals.count,
                                                    computedAt: document.generatedAt, dayEnd: day.end,
                                                    configTag: configTag, inputFingerprint: inputFingerprint,
                                                    writtenAt: startedAt,
                                                    retrospectiveVersion: retrospective.isEmpty
                                                        ? nil : ActivityContextRetrospective.version)
        // The decoder's typed events (a 10 s stand the interval builder folds into sitting still leaves one),
        // written with the intervals they belong to.
        let transitions = ActivityContextPersistence.transitionRows(document.events, from: day.start, to: day.end,
                                                                     decoderVersion: document.versions.decoder)
        let smoothedRows = row.isFinal ? retrospective.map(\.storeRow) : []
        do {
            // One owner per day, in one write: another id that held this day's context (the active strap
            // changed) stops describing the same seconds in the same transaction that the owner's rows land in,
            // or neither happens and the day is retried.
            do {
                try await store.replaceActivityContext(deviceId: owner.deviceId, day: row,
                                                       intervals: intervals.map(\.storeRow), transitions: transitions,
                                                       clearingOtherIds: ids, retrospective: smoothedRows)
            } catch let error where !smoothedRows.isEmpty {
                // The causal rows are what every live consumer needs; a smoother output the store refuses must not
                // cost the day those. Write them alone (the ledger then names no smoother) and say so.
                log("Activity context: retrospective rows for \(day.key) refused (\(error)); saving causal rows only")
                var causalOnly = row
                causalOnly.retrospectiveVersion = nil
                try await store.replaceActivityContext(deviceId: owner.deviceId, day: causalOnly,
                                                       intervals: intervals.map(\.storeRow), transitions: transitions,
                                                       clearingOtherIds: ids)
            }
            failures[day.start] = nil
            // A final day smoothed to nothing is a result too: remember it (the ledger cannot), so a relaunch does not
            // decode the day again only to smooth it to nothing again. A refused write is not remembered: that day is
            // tried again at most once per launch (rule 7 stops once this process has looked at it after it settled).
            if row.isFinal && smoothedRows.isEmpty {
                smoothedEmpty.mark(deviceId: owner.deviceId, dayStart: day.start, inputFingerprint: inputFingerprint)
            } else {
                smoothedEmpty.clear(deviceId: owner.deviceId, dayStart: day.start)
            }
            if !smoothedRows.isEmpty {
                log("Activity context: \(smoothedRows.count) retrospective intervals (\(ActivityContextRetrospective.version)) for \(day.key)")
            }
            log("Activity context: saved \(intervals.count) intervals for \(day.key)")
        } catch {
            failures[day.start] = Int(Date().timeIntervalSince1970)
            log("Activity context: could not save \(day.key): \(error)")
        }
    }

    // MARK: - Shared

    private struct LoadedDay {
        let streams: DayStreams
        let document: ActivityContextDayDocument
    }

    private func loadDay(_ day: Day) async -> LoadedDay? {
        guard let streams = await repo.dayStreams(dayStart: Date(timeIntervalSince1970: TimeInterval(day.start)),
                                                  dayEnd: Date(timeIntervalSince1970: TimeInterval(day.end))),
              let document = await repo.activityContext(from: streams, lane: .background) else { return nil }
        return LoadedDay(streams: streams, document: document)
    }
}

/// Final days whose retrospective smoothing came out empty, per device, day, input fingerprint and smoother version
/// (D8-10). The store's ledger can only name a smoother version when it holds that smoother's rows, so an empty
/// result is kept here; without it rule 7 would re-decode such a day on every launch. A different input or smoother
/// version no longer matches, and the day is smoothed again.
struct RetrospectiveEmptyMarks {
    let defaults: UserDefaults
    static let prefix = "activityContext.retrospectiveEmpty."

    private static func key(_ deviceId: String, _ dayStart: Int) -> String { "\(prefix)\(deviceId).\(dayStart)" }
    private static func value(_ inputFingerprint: String?) -> String {
        "\(ActivityContextRetrospective.version)|\(inputFingerprint ?? "")"
    }

    /// True when `ledger` is final, holds no smoother rows, and was smoothed to nothing from the same input by the
    /// current smoother.
    func covers(_ ledger: ActivityContextDayRow, deviceId: String) -> Bool {
        guard ledger.isFinal, ledger.retrospectiveVersion == nil,
              let stored = defaults.string(forKey: Self.key(deviceId, ledger.dayStart)) else { return false }
        return stored == Self.value(ledger.inputFingerprint)
    }

    func mark(deviceId: String, dayStart: Int, inputFingerprint: String?) {
        defaults.set(Self.value(inputFingerprint), forKey: Self.key(deviceId, dayStart))
    }

    func clear(deviceId: String, dayStart: Int) {
        defaults.removeObject(forKey: Self.key(deviceId, dayStart))
    }
}
