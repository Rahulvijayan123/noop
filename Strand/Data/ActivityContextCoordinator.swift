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

    private var isEvaluatingStand = false
    private var lastStandReason: StandReminderEngine.Reason?

    private var materializeTask: Task<Void, Never>?
    private var materializeAgain = false
    /// What this process last saw of each day (never persisted: a relaunch looks again).
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
         timeZone: @escaping () -> TimeZone = { .current }) {
        self.repo = repo
        self.horizonDays = horizonDays
        self.isWorn = isWorn
        self.remind = remind
        self.log = log
        self.timeZone = timeZone
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
        var candidates: [ActivityContextMaterialization.Candidate] = []
        for day in days {
            guard let owner = await repo.activityContextOwner(store: store, ids: ids, from: day.start, to: day.end) else { continue }
            owners[day.start] = owner
            // A07: the cheap store-level day-stream fingerprint (count/max-ts per stream) rides on the
            // candidate so `needsWork` re-examines a day whose streams changed under an unchanged ledger
            // — a late backfill to an old day with no new HR must not stay invisible until the horizon
            // rolls over it. (Equal-count *value* corrections are caught by the track's content
            // fingerprint once the day is re-examined; the last-seen route here is in-session — the
            // ledger column that would persist it across launches is the documented follow-up.)
            // Only a day this process has already looked at can compare against a fingerprint (no stored one is
            // passed in), so the query is skipped for the others — about 118 of 120 on a pass.
            if checks[day.start] != nil {
                let fingerprint = (try? await store.dayStreamFingerprint(deviceId: owner.deviceId, from: day.start, to: day.end)) ?? ""
                if !fingerprint.isEmpty { fingerprints[day.start] = fingerprint }
            }
            candidates.append(.init(day: day, ledger: ledgers[owner.deviceId]?[day.start],
                                    newestHeartRateTs: owner.newestHeartRateTs, lastCheck: checks[day.start],
                                    inputFingerprint: fingerprints[day.start]))
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
                              inputFingerprint: fingerprints[day.start], ids: ids, store: store)
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

    private func materialize(_ day: Day, owner: Repository.ActivityContextOwner, ledger: ActivityContextDayRow?,
                             inputFingerprint: String?, ids: [String], store: WhoopStore) async {
        // The planner fingerprints only days this process already looked at; a day derived for the first time
        // records its fingerprint here, so a later backfill into it is still noticed (rule 5).
        var fingerprint = inputFingerprint
        if fingerprint == nil {
            let read = (try? await store.dayStreamFingerprint(deviceId: owner.deviceId, from: day.start, to: day.end)) ?? ""
            fingerprint = read.isEmpty ? nil : read
        }
        checks[day.start] = .init(at: Int(Date().timeIntervalSince1970), newestHeartRateTs: owner.newestHeartRateTs,
                                  inputFingerprint: fingerprint)
        guard let loaded = await loadDay(day) else {
            failures[day.start] = Int(Date().timeIntervalSince1970)
            return
        }
        // Decoded to the same horizon by the same rules as what is already saved: nothing to write.
        if ActivityContextMaterialization.covers(ledger, document: loaded.document) { return }

        let streams = loaded.streams
        let beats = await repo.rrIntervals(from: streams.start, to: streams.end, limit: 250_000)
        let document = loaded.document, hr = streams.hr, steps = streams.stepCounter, gravity = streams.gravity
        let (built, hrvWindows) = await Task.detached(priority: .utility) {
            let intervals = ActivityContextIntervalBuilder.build(document: document, hr: hr, steps: steps, rr: beats)
            // Fed by exactly the same live beat-to-beat R-R and the strap's always-on 1 Hz motion stream the
            // interval build above uses (no fabricated/placeholder data): see `HRVWindow.swift`'s header for
            // why this is a SEPARATE, canonical-duration population from `intervals`'s own per-interval RMSSD.
            // `imuWindows` is left empty: the strap does not stream raw 100 Hz IMU continuously during normal
            // wear (only during an opt-in Raw Data collector session), so `motionRmsG` falls back to the 1 Hz
            // stream and `gyroRmsDps` stays honestly nil here rather than inventing a reading.
            let lookup = ActivityContextLookup(intervals: intervals)
            // The phone's day document carries runs, not per-epoch wear signal (that is server-only, in the
            // C10 epochs), so every window resolves wearSignal nil here. These windows only feed the
            // diagnostic line today; no score or baseline reads them yet.
            let windows = HRVWindowBuilder.build(kind: .canonical5m, dayStart: document.dayStart, dayEnd: document.dayEnd,
                                                 rr: beats, gravity: gravity, activity: lookup,
                                                 transitionEvents: document.events,
                                                 epochWearSignal: [])
            return (intervals, windows)
        }.value
        log(HRVWindowSummary.diagLine(hrvWindows, kind: .canonical5m, day: day.key))
        let intervals = ActivityContextPersistence.clipped(built, from: day.start, to: day.end)
        let row = ActivityContextPersistence.dayRow(day: day.key, document: document, intervalCount: intervals.count,
                                                    computedAt: document.generatedAt, dayEnd: day.end)
        do {
            try await store.replaceActivityContext(deviceId: owner.deviceId, day: row,
                                                   intervals: intervals.map(\.storeRow))
            // One owner per day: another id that held this day's context (the active strap changed) must not
            // keep describing the same seconds.
            for id in ids where id != owner.deviceId {
                try? await store.clearActivityContext(deviceId: id, from: day.start, to: day.end)
            }
            failures[day.start] = nil
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
        guard let streams = await repo.dayStreams(dayStart: Date(timeIntervalSince1970: TimeInterval(day.start))),
              let document = await repo.activityContext(from: streams, lane: .background) else { return nil }
        return LoadedDay(streams: streams, document: document)
    }
}
