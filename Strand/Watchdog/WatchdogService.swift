import Foundation
import Combine
import GRDB
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Live Watchdog driver: one tick every `WatchdogConfig.tickSeconds` while the app runs, plus best-effort
/// background refreshes.
///
/// Reliability rules this type keeps (BW2):
/// - It reads the strap the rest of the app reads: `Repository.rawPhysiologyReadIds` (active strap first, then
///   other registered WHOOPs, then the canonical history), and persists its carry and sidecars under the
///   active strap's registry id, rebinding when that changes (`WatchdogDeviceBinding`).
/// - Ticks are single-flight: a request while one runs joins it, so an older tick can never overwrite a newer
///   carry, and one `now` is captured per tick.
/// - The window build and the evaluation run off the main actor on value copies; the main actor only gathers
///   inputs (including the main-confined raw IMU file read) and publishes results.
/// - A push's delivery is awaited and persisted inside the tick, so a background task completes only after it.
@MainActor
final class WatchdogService {
    weak var model: AppModel?
    private var loop: Task<Void, Never>?
    private var carry = WatchdogCarry.empty
    private var liveHRRing: [HRSample] = []
    private var liveRRRing: [RRInterval] = []
    /// Last `LiveState.rrSeq` taken into the ring: every R-R packet exactly once.
    private var rrCursor = 0
    private var liveWristEvents: [WatchdogQualityFeed.WristEvent] = []
    /// The key the carry and sidecars are persisted under (the active strap's registry id). Empty until bound.
    private(set) var stateKey: String = ""
    private var cancellables = Set<AnyCancellable>()
    private var tickInFlight: Task<Bool, Never>?
    /// Strap families proven by stored evidence (positive only).
    private var provenFamilies: [String: DeviceFamily] = [:]
    /// The family of the strap that owned the last window's heart rate (nil = unknown).
    private var lastWindowFamily: DeviceFamily?
    /// WRIST_OFF seconds already closed by sustained HR recovery.
    private var recoveredOffs: Set<Int> = []

    /// Live ring retention: the window plus a margin for a tick that runs late.
    private static let ringSeconds = WatchdogConfig.contextSeconds + 5 * 60

    func start(on model: AppModel) {
        self.model = model
        bindLive(model)
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.tick()
            while !Task.isCancelled {
                let ns = UInt64(WatchdogConfig.tickSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: ns)
                await self?.tick()
            }
        }
    }

    /// BGAppRefresh entry. On a cold background launch the launch sequence starts this service only after
    /// `repo.refresh()`, so wait for it within the task's budget rather than tick against a nil model (which
    /// used to return at once and report success). Returns true only when a tick ran to completion (its own,
    /// or one already in flight that it joined).
    func backgroundTick(budgetSeconds: Double) async -> Bool {
        guard await waitUntilStarted(timeoutSeconds: budgetSeconds) else { return false }
        return await tick(skipForecast: true)
    }

    /// True once `start(on:)` has bound a model; false when `timeoutSeconds` passes first or the caller is
    /// cancelled.
    func waitUntilStarted(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while model == nil {
            if Task.isCancelled || Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return true
    }

    /// Single-flight tick. A request while a tick runs waits for that tick instead of starting a second one
    /// that could interleave at an await and persist an older carry over a newer one.
    @discardableResult
    func tick(inject: Watchdog.WatchdogInject? = nil, skipForecast: Bool = false) async -> Bool {
        if let running = tickInFlight { return await running.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.runTick(inject: inject, skipForecast: skipForecast)
        }
        tickInFlight = task
        let completed = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if tickInFlight == task { tickInFlight = nil }
        return completed
    }

    private func runTick(inject: Watchdog.WatchdogInject?, skipForecast: Bool) async -> Bool {
        guard let model else { return false }
        if Task.isCancelled { return false }
        await rebindIfNeeded(model)
        let key = stateKey
        // One clock for the whole tick.
        let now = Int(Date().timeIntervalSince1970)
        captureLive(model, now: now)
        let liveAlerts = !model.live.backfilling
        let intervalMinutes = WatchdogConfig.clampInterval(model.baseline.liveIntervalMinutes)
        let days = model.repo.days
        // v2 context strata (posture / walking / sleep HR) come from the stored activity-context intervals;
        // refreshed at most every 30 min, off the main actor.
        await model.baseline.refreshContextStrata(repo: model.repo)
        if Task.isCancelled { return false }
        let promptEvals = model.baseline.watchdogPromptEvaluations(days: days)
        let prompt = UniTSPrompt.from(evaluations: promptEvals)
        let window: Result<WatchdogWindow, WatchdogUnavailable>
        if inject == nil {
            window = await loadWindow(model: model, now: now)
        } else {
            window = .failure(.empty)
        }
        if Task.isCancelled { return false }
        let sessions = await model.repo.watchdogSleepSessions(from: now - 20 * 3600, to: now + 3600, limit: 40)
        if Task.isCancelled { return false }
        var sleepIntervals = sessions.map {
            WatchdogSleepInterval(startUnix: $0.effectiveStartTs, endUnix: $0.endTs)
        }
        // The strap's own asleep code (sleepStateSample state 2) covers minutes a scored
        // sleep session has not closed yet. Those minutes must not train awake rest.
        sleepIntervals.append(contentsOf: await asleepBandIntervals(model: model, now: now))
        if Task.isCancelled { return false }
        // A strap switch during the awaits: this tick read the old strap. Drop it; the next tick rebinds.
        guard key == stateKey else { return false }
        let sleepOpen = sleepIntervals.contains { $0.contains(now) }
        let todayLog = model.baseline.calendarTodayLog
        let yesterdayLog = model.baseline.dayLogsByDay[BaselineStore.yesterdayKey()]
        let log = Watchdog.liveDayLog(today: todayLog, yesterday: yesterdayLog, sleepOpen: sleepOpen)
        await reconcileQueuedDelivery(model: model, now: now)
        let previous = carry
        // Pure evaluation (Core ML sessions are lock-guarded) on value copies, off the main actor.
        let evaluated = await Task.detached(priority: .utility) { () -> (WatchdogResult, Data?) in
            var result = Watchdog.evaluate(window: window,
                                           prompt: prompt,
                                           evaluations: promptEvals,
                                           dayLog: log,
                                           nowUnix: now,
                                           liveIntervalMinutes: intervalMinutes,
                                           previous: previous,
                                           inject: inject,
                                           sleepSessionOpen: sleepOpen,
                                           sleepIntervals: sleepIntervals,
                                           skipForecast: skipForecast,
                                           liveAlerts: liveAlerts)
            if result.shouldNotify { result.carry.notifyQueuedAtUnix = now }
            return (result, try? JSONEncoder().encode(result.carry))
        }.value
        if Task.isCancelled { return false }
        guard key == stateKey else { return false }
        let result = evaluated.0
        carry = result.carry
        if let data = evaluated.1 {
            UserDefaults.standard.set(data, forKey: Self.carryKey(deviceId: key))
        }
        if case .success(let built) = window,
           Watchdog.shouldTrainUsual(result: result, dayLog: log) {
            model.baseline.ingestImu(samples: built.imu, nowUnix: now)
            model.baseline.ingestWatchdogTape(window: built, nowUnix: now,
                                              lastWorkoutEndUnix: carry.lastWorkoutEndUnix,
                                              sleepIntervals: sleepIntervals)
        }
        model.baseline.activityContextNote = await activityContextNote(model: model, now: now)
        model.baseline.applyWatchdog(result)
        model.baseline.ingestLiveSidecars(result: result, deviceId: key,
                                          nowUnix: now, liveAlerts: liveAlerts,
                                          evaluations: promptEvals)
        if result.shouldNotify {
            // Awaited, so the outcome is persisted before this tick (and a background task) completes.
            let delivery = await WatchdogNotifier.deliver(result)
            applyDelivery(delivery, result: result, queuedAt: now, key: key, liveAlerts: liveAlerts, model: model)
        }
        return true
    }

    // MARK: - Notification delivery

    private func applyDelivery(_ delivery: String, result: WatchdogResult, queuedAt: Int, key: String,
                               liveAlerts: Bool, model: AppModel) {
        // A strap switch or a newer push owns the carry now; the stale-queue rule recovers this one.
        guard key == stateKey, carry.notifyQueuedAtUnix == queuedAt else { return }
        carry.notifyDelivery = delivery
        if delivery == "sent", let eid = result.episodeId {
            carry.notifiedSevereEpisodeId = eid
            let opened = eid.split(separator: "-").last.flatMap { Int($0) } ?? queuedAt
            model.baseline.noteAfterSent(episodeId: eid, deviceId: key, eventUnix: opened, liveAlerts: liveAlerts)
        }
        persistCarry(key: key)
        var shown = result
        shown.carry = carry
        model.baseline.applyWatchdog(shown)
    }

    /// A carry still "queued" at the start of a tick lost its delivery callback (the process died mid-post).
    /// Once it is overdue, ask Notification Center whether that push landed: delivered → "sent"; otherwise
    /// "failed", which the policy retries after the cooldown.
    private func reconcileQueuedDelivery(model: AppModel, now: Int) async {
        guard WatchdogNotifyPolicy.inFlight(carry.notifyDelivery) else { return }
        let queuedAt = carry.notifyQueuedAtUnix ?? carry.lastNotifiedAt
        guard !WatchdogNotifyPolicy.inFlight(WatchdogNotifyPolicy.effectiveDelivery(
            carry.notifyDelivery, queuedAtUnix: queuedAt, nowUnix: now)) else { return }
        let key = stateKey
        let delivered = await WatchdogNotifier.deliveredIdentifiers()
        guard key == stateKey, WatchdogNotifyPolicy.inFlight(carry.notifyDelivery) else { return }
        if let eid = carry.episodeId, delivered.contains(eid) {
            carry.notifyDelivery = "sent"
            carry.notifiedSevereEpisodeId = eid
            let opened = eid.split(separator: "-").last.flatMap { Int($0) } ?? (queuedAt ?? now)
            model.baseline.noteAfterSent(episodeId: eid, deviceId: key, eventUnix: opened, liveAlerts: true)
        } else {
            carry.notifyDelivery = "failed"
        }
        persistCarry(key: key)
    }

    // MARK: - Live ingest

    private func bindLive(_ model: AppModel) {
        cancellables.removeAll()
        rrCursor = model.live.rrSeq
        model.live.$heartRate
            .sink { [weak self, weak model] _ in
                guard let self, let model else { return }
                self.captureHR(model)
            }
            .store(in: &cancellables)
        // `rrSeq` moves after `rr` is written (`setRRIntervals`), so in this sink `live.rr` is the packet that
        // owns the delivered sequence number: every packet once, stamped at receipt.
        model.live.$rrSeq
            .sink { [weak self, weak model] seq in
                guard let self, let model else { return }
                self.ingestRRPacket(seq: seq, packet: model.live.rr, receivedUnix: Int(Date().timeIntervalSince1970))
                self.captureHR(model)
            }
            .store(in: &cancellables)
        // Live WRIST_ON / WRIST_OFF (FrameRouter flips `worn` only on a real, fresh event).
        model.live.$worn
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                let now = Int(Date().timeIntervalSince1970)
                self.liveWristEvents.append(.init(ts: now, on: on))
                self.liveWristEvents.removeAll { now - $0.ts > WatchdogQualityFeedBuilder.wearLookbackSeconds }
            }
            .store(in: &cancellables)
    }

    private func captureHR(_ model: AppModel) {
        if let sample = WatchdogLiveTape.hrSample(
            lastRingTs: liveHRRing.last?.ts,
            packetUnix: model.live.lastHeartRatePacketUnix,
            packetBpm: model.live.lastHeartRatePacketBpm
        ) {
            liveHRRing.append(sample)
        }
    }

    private func ingestRRPacket(seq: Int, packet: [Int], receivedUnix: Int) {
        guard seq != rrCursor else { return }
        rrCursor = seq
        liveRRRing.append(contentsOf: WatchdogLiveTape.rrBeats(packet: packet, receivedUnix: receivedUnix,
                                                               lastRingBeat: liveRRRing.last))
    }

    private func captureLive(_ model: AppModel, now: Int) {
        captureHR(model)
        let cut = now - Self.ringSeconds
        liveHRRing.removeAll { $0.ts < cut }
        liveRRRing.removeAll { $0.ts < cut }
        liveWristEvents.removeAll { now - $0.ts > WatchdogQualityFeedBuilder.wearLookbackSeconds }
    }

    private func liveSnapshot(_ model: AppModel) -> WatchdogLiveInputs {
        WatchdogLiveInputs(hrRing: liveHRRing, rrRing: liveRRRing,
                             lastHeartRatePacketUnix: model.live.lastHeartRatePacketUnix,
                             wristEvents: liveWristEvents,
                             charging: model.live.connected ? model.live.charging : nil)
    }

    // MARK: - Window

    /// Structure-only fallback (gap / freshness tolerances) when no evidence names the family. Never used to
    /// convert a unit: an unknown family leaves temperature missing.
    private static var structuralHint: DeviceFamily {
        UserDefaults.standard.string(forKey: WhoopModel.storageKey) == WhoopModel.whoop5mg.rawValue ? .whoop5 : .whoop4
    }

    private func loadWindow(model: AppModel, now: Int) async -> Result<WatchdogWindow, WatchdogUnavailable> {
        let snapshot = liveSnapshot(model)
        guard let store = await model.repo.storeHandle() else {
            let family = provenFamilies[stateKey] ?? lastWindowFamily
            return WatchdogWindowLoader.liveOnly(snapshot: snapshot, nowUnix: now, family: family,
                                                 structuralHint: Self.structuralHint).window
        }
        let ids = model.repo.rawPhysiologyReadIds(store: store)
        let devices = (try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? []
        var registry: [String: (model: String?, brand: String?)] = [:]
        for d in devices { registry[d.id] = (d.model, d.brand) }
        let placement = WatchdogQualityFeedBuilder.placement(at: now, rows: Self.placementRows(store: store),
                                                             deviceIds: ids)
        let from = now - WatchdogConfig.contextSeconds
        // The raw IMU file store is main-confined (the Collector appends on the main actor): read here, convert
        // off the main actor. A logged bicep / other site never reads it.
        let rawImu: [[ImuStoredRecord]] = (placement == "bicep" || placement == "other") ? [] : ids.map {
            ImuSessionFileStore.shared.readRecords(deviceId: $0, fromTs: Int64(from), toTs: Int64(now))
        }
        let context = await model.repo.storedActivityContext(from: from - 600, to: now).intervals.map(\.storeRow)
        let request = WatchdogWindowRequest(store: store, readIds: ids, nowUnix: now, live: snapshot,
                                            registry: registry, provenFamilies: provenFamilies,
                                            structuralHint: Self.structuralHint, placement: placement,
                                            rawImu: rawImu, contextIntervals: context,
                                            recoveredOffs: recoveredOffs)
        let load = await Task.detached(priority: .utility) {
            await WatchdogWindowLoader.load(request)
        }.value
        provenFamilies.merge(load.provenFamilies) { _, new in new }
        recoveredOffs = load.recoveredOffs
        lastWindowFamily = load.family
        return load.window
    }

    /// Every placement interval row (bare and `installation:…:<id>` scopes). A plain read: no table is created
    /// here, and a missing table is no placement (UNKNOWN).
    private static func placementRows(store: WhoopStore) -> [WatchdogQualityFeedBuilder.PlacementRow] {
        (try? store.registryWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT deviceId, placement, effectiveStart, effectiveEnd, recordedAt, revision
                FROM placementInterval WHERE deviceId IS NOT NULL
                """).map { row in
                WatchdogQualityFeedBuilder.PlacementRow(
                    scope: row["deviceId"] as String?,
                    placement: row["placement"] as String? ?? "unknown",
                    effectiveStart: row["effectiveStart"] as Int? ?? 0,
                    effectiveEnd: row["effectiveEnd"] as Int?,
                    recordedAt: row["recordedAt"] as Int? ?? 0,
                    revision: Int64(row["revision"] as Int? ?? 1))
            }
        }) ?? []
    }

    // MARK: - Device binding

    private static let carryKeyPrefix = "noop.watchdog.carry.v2."
    private static let legacyCarryKey = "noop.watchdog.carry.v1"
    private static let legacyMigratedKey = "noop.watchdog.carry.v1.migratedTo"
    /// Set once the pre-binding "my-whoop" state has been copied to the first non-legacy strap.
    private static let legacyIdMigratedKey = "noop.watchdog.carry.v2.myWhoopMigratedTo"

    private static func carryKey(deviceId: String) -> String {
        carryKeyPrefix + deviceId
    }

    /// Every persisted per-device Watchdog key: the carry and the three sidecars `BaselineStore` loads.
    private static func stateKeys(deviceId: String) -> [String] {
        [carryKey(deviceId: deviceId),
         WatchdogEventRecovery.persistKey(deviceId: deviceId),
         WatchdogEpisodeAnnotation.persistKey(deviceId: deviceId),
         WatchdogEpisodeLedger.persistKey(deviceId: deviceId)]
    }

    /// Bind to the active strap (`Repository.deviceId`, which follows the registry's active device). On a change:
    /// migrate persisted state if the rules say so, reload carry + sidecars, and reset what belonged to the old
    /// strap. A serial-identity adoption (same physical strap, rows moved) keeps the live rings.
    private func rebindIfNeeded(_ model: AppModel) async {
        let key = WatchdogDeviceBinding.stateKey(activeDeviceId: model.repo.deviceId)
        guard key != stateKey else { return }
        let previous = stateKey.isEmpty ? nil : stateKey
        let registered: Set<String>
        if let store = await model.repo.storeHandle() {
            registered = Set(((try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? []).map(\.id))
        } else {
            registered = []
        }
        // Re-check after the await: another tick cannot run (single-flight), but the active id can move.
        guard WatchdogDeviceBinding.stateKey(activeDeviceId: model.repo.deviceId) == key, key != stateKey else {
            return
        }
        let sameStrap = previous.map { !registered.isEmpty && !registered.contains($0) } ?? false
        migratePersistedState(to: key, previous: previous, registered: registered)
        if !sameStrap {
            liveHRRing = []
            liveRRRing = []
            liveWristEvents = []
            rrCursor = model.live.rrSeq
        }
        recoveredOffs = []
        lastWindowFamily = nil
        stateKey = key
        carry = loadCarry(deviceId: key)
        model.baseline.loadWatchdogSidecars(deviceId: key)
    }

    private func migratePersistedState(to key: String, previous: String?, registered: Set<String>) {
        let defaults = UserDefaults.standard
        func hasState(_ id: String) -> Bool { defaults.data(forKey: Self.carryKey(deviceId: id)) != nil }
        let legacy = WatchdogDeviceBinding.legacyCarryId
        guard let source = WatchdogDeviceBinding.migrationSource(
            target: key, previous: previous,
            targetHasState: hasState(key),
            previousHasState: previous.map(hasState) ?? false,
            previousStillRegistered: previous.map { registered.isEmpty || registered.contains($0) } ?? true,
            legacyHasState: hasState(legacy),
            legacyAlreadyMigrated: defaults.string(forKey: Self.legacyIdMigratedKey) != nil)
        else { return }
        for (from, to) in zip(Self.stateKeys(deviceId: source), Self.stateKeys(deviceId: key))
        where defaults.data(forKey: to) == nil {
            if let data = defaults.data(forKey: from) { defaults.set(data, forKey: to) }
        }
        if source == legacy { defaults.set(key, forKey: Self.legacyIdMigratedKey) }
    }

    private func loadCarry(deviceId: String) -> WatchdogCarry {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.carryKey(deviceId: deviceId)),
           let decoded = try? JSONDecoder().decode(WatchdogCarry.self, from: data) {
            return decoded
        }
        // v1 was one blob. Copy it once onto the first strap that needs a v2 key.
        // Do not stamp that episode / band onto every later deviceId.
        if defaults.string(forKey: Self.legacyMigratedKey) == nil,
           let legacy = defaults.data(forKey: Self.legacyCarryKey),
           let decoded = try? JSONDecoder().decode(WatchdogCarry.self, from: legacy) {
            defaults.set(deviceId, forKey: Self.legacyMigratedKey)
            defaults.set(legacy, forKey: Self.carryKey(deviceId: deviceId))
            return decoded
        }
        return .empty
    }

    private func persistCarry(key: String) {
        if let data = try? JSONEncoder().encode(carry) {
            UserDefaults.standard.set(data, forKey: Self.carryKey(deviceId: key))
        }
    }

    // MARK: - Sleep

    /// Strap asleep code 2, coalesced. A gap longer than 90 seconds starts a new interval.
    nonisolated static func asleepIntervals(from samples: [SleepStateSample]) -> [WatchdogSleepInterval] {
        let asleep = samples.filter { $0.state == 2 }.sorted { $0.ts < $1.ts }
        var out: [WatchdogSleepInterval] = []
        var start: Int?
        var end: Int?
        for sample in asleep {
            if let openEnd = end, sample.ts <= openEnd + 90 {
                end = sample.ts + 1
            } else {
                if let start, let end {
                    out.append(WatchdogSleepInterval(startUnix: start, endUnix: end))
                }
                start = sample.ts
                end = sample.ts + 1
            }
        }
        if let start, let end {
            out.append(WatchdogSleepInterval(startUnix: start, endUnix: end))
        }
        return out
    }

    /// The same raw-physiology ids the window reads.
    private func asleepBandIntervals(model: AppModel, now: Int) async -> [WatchdogSleepInterval] {
        guard let store = await model.repo.storeHandle() else { return [] }
        let from = now - WatchdogConfig.contextSeconds
        var samples: [SleepStateSample] = []
        for id in model.repo.rawPhysiologyReadIds(store: store) {
            samples += (try? await store.sleepStateSamples(deviceId: id, from: from, to: now + 60)) ?? []
        }
        return Self.asleepIntervals(from: samples)
    }

    /// The heart-rate page already decodes today's activity context onto disk. Read that
    /// cache only. A miss does not start a decode, and the label never enters scoring.
    private func activityContextNote(model: AppModel, now: Int) async -> String? {
        let dayStart = Int(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now)))
            .timeIntervalSince1970)
        let joined = model.repo.importedReadIds.joined(separator: "+")
        var keys = [joined]
        for id in model.repo.importedReadIds where !keys.contains(id) { keys.append(id) }
        for key in keys {
            guard let doc = ActivityContextFileStore.shared.load(source: key, dayStart: dayStart),
                  let run = doc.runs.last(where: { $0.start <= now && now < $0.end }),
                  let label = run.displayContext, !label.isEmpty, label != "Unclear"
            else { continue }
            return "Phone activity context: \(label). Not used in the Off check."
        }
        return nil
    }
}
