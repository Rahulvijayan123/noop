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
            + "standing or moving, \(percent(w.coverage))% observed, \(percent(w.sedentaryShare))% seated)"
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
        var candidates: [ActivityContextMaterialization.Candidate] = []
        for day in days {
            guard let owner = await repo.activityContextOwner(store: store, ids: ids, from: day.start, to: day.end) else { continue }
            owners[day.start] = owner
            candidates.append(.init(day: day, ledger: ledgers[owner.deviceId]?[day.start],
                                    newestHeartRateTs: owner.newestHeartRateTs, lastCheck: checks[day.start]))
        }

        let planned = ActivityContextMaterialization.plan(candidates, now: nowSec)
        let due = planned.filter { day in failures[day.start].map { nowSec - $0 >= Self.retryAfterFailureS } ?? true }
        for day in due {
            guard let owner = owners[day.start] else { continue }
            await materialize(day, owner: owner, ledger: ledgers[owner.deviceId]?[day.start], ids: ids, store: store)
        }
        let oldDays = planned.filter { !ActivityContextMaterialization.isRecent($0, now: nowSec) }.count
        return oldDays >= ActivityContextMaterialization.Config().maxBacklogPerPass
    }

    private func materialize(_ day: Day, owner: Repository.ActivityContextOwner, ledger: ActivityContextDayRow?,
                             ids: [String], store: WhoopStore) async {
        checks[day.start] = .init(at: Int(Date().timeIntervalSince1970), newestHeartRateTs: owner.newestHeartRateTs)
        guard let loaded = await loadDay(day) else {
            failures[day.start] = Int(Date().timeIntervalSince1970)
            return
        }
        // Decoded to the same horizon by the same rules as what is already saved: nothing to write.
        if ActivityContextMaterialization.covers(ledger, document: loaded.document) { return }

        let streams = loaded.streams
        let beats = await repo.rrIntervals(from: streams.start, to: streams.end, limit: 250_000)
        let document = loaded.document, hr = streams.hr, steps = streams.stepCounter
        let built = await Task.detached(priority: .utility) {
            ActivityContextIntervalBuilder.build(document: document, hr: hr, steps: steps, rr: beats)
        }.value
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
