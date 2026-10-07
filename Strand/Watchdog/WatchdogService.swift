import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

@MainActor
final class WatchdogService {
    weak var model: AppModel?
    private var loop: Task<Void, Never>?
    private var carry = WatchdogCarry.empty
    private var liveHRRing: [HRSample] = []
    private var liveRRRing: [RRInterval] = []
    private var lastRRSeq: Int = -1
    private var boundDeviceId: String = ""
    private var cancellables = Set<AnyCancellable>()

    func start(on model: AppModel) {
        self.model = model
        boundDeviceId = model.deviceId
        carry = loadCarry(deviceId: model.deviceId)
        model.baseline.loadWatchdogSidecars(deviceId: model.deviceId)
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

    func tick(inject: Watchdog.WatchdogInject? = nil, skipForecast: Bool = false) async {
        guard let model else { return }
        if Task.isCancelled { return }
        if model.deviceId != boundDeviceId {
            liveHRRing = []
            liveRRRing = []
            lastRRSeq = -1
            boundDeviceId = model.deviceId
            carry = loadCarry(deviceId: model.deviceId)
            model.baseline.loadWatchdogSidecars(deviceId: model.deviceId)
        }
        captureLive(model)
        let now = Int(Date().timeIntervalSince1970)
        let liveAlerts = !model.live.backfilling
        let days = model.repo.days
        // v2 context strata (posture / walking / sleep HR) come from the stored activity-context intervals;
        // refreshed at most every 30 min, off the main actor.
        await model.baseline.refreshContextStrata(repo: model.repo)
        if Task.isCancelled { return }
        let promptEvals = model.baseline.watchdogPromptEvaluations(days: days)
        let prompt = UniTSPrompt.from(evaluations: promptEvals)
        let window: Result<WatchdogWindow, WatchdogUnavailable>
        if inject == nil {
            window = await loadWindow(model: model, now: now)
        } else {
            window = .failure(.empty)
        }
        if Task.isCancelled { return }
        let sessions = await model.repo.watchdogSleepSessions(from: now - 20 * 3600, to: now + 3600, limit: 40)
        if Task.isCancelled { return }
        var sleepIntervals = sessions.map {
            WatchdogSleepInterval(startUnix: $0.effectiveStartTs, endUnix: $0.endTs)
        }
        // The strap's own asleep code (sleepStateSample state 2) covers minutes a scored
        // sleep session has not closed yet. Those minutes must not train awake rest.
        sleepIntervals.append(contentsOf: await asleepBandIntervals(model: model, now: now))
        let sleepOpen = sleepIntervals.contains { $0.contains(now) }
        let todayLog = model.baseline.calendarTodayLog
        let yesterdayLog = model.baseline.dayLogsByDay[BaselineStore.yesterdayKey()]
        let log = Watchdog.liveDayLog(today: todayLog, yesterday: yesterdayLog, sleepOpen: sleepOpen)
        let result = Watchdog.evaluate(window: window,
                                       prompt: prompt,
                                       evaluations: promptEvals,
                                       dayLog: log,
                                       nowUnix: now,
                                       liveIntervalMinutes: WatchdogConfig.defaultLiveIntervalMinutes,
                                       previous: carry,
                                       inject: inject,
                                       sleepSessionOpen: sleepOpen,
                                       sleepIntervals: sleepIntervals,
                                       skipForecast: skipForecast,
                                       liveAlerts: liveAlerts)
        if Task.isCancelled { return }
        carry = result.carry
        persistCarry(deviceId: model.deviceId)
        if case .success(let built) = window,
           Watchdog.shouldTrainUsual(result: result, dayLog: log) {
            model.baseline.ingestImu(samples: built.imu, nowUnix: now)
            model.baseline.ingestWatchdogTape(window: built, nowUnix: now,
                                              lastWorkoutEndUnix: carry.lastWorkoutEndUnix,
                                              sleepIntervals: sleepIntervals)
        }
        model.baseline.activityContextNote = await activityContextNote(model: model, now: now)
        model.baseline.applyWatchdog(result)
        model.baseline.ingestLiveSidecars(result: result, deviceId: model.deviceId,
                                          nowUnix: now, liveAlerts: liveAlerts,
                                          evaluations: promptEvals)
        if result.shouldNotify, !Task.isCancelled {
            WatchdogNotifier.post(result) { [weak self] delivery in
                Task { @MainActor in
                    guard let self, let model = self.model else { return }
                    self.carry.notifyDelivery = delivery
                    if delivery == "sent", let eid = self.carry.episodeId {
                        self.carry.notifiedSevereEpisodeId = eid
                        let opened = eid.split(separator: "-").last.flatMap { Int($0) } ?? now
                        model.baseline.noteAfterSent(episodeId: eid, deviceId: model.deviceId,
                                                     eventUnix: opened, liveAlerts: liveAlerts)
                    }
                    self.persistCarry(deviceId: model.deviceId)
                    var shown = result
                    shown.carry = self.carry
                    model.baseline.applyWatchdog(shown)
                }
            }
        }
    }

    private func bindLive(_ model: AppModel) {
        cancellables.removeAll()
        model.live.$heartRate
            .sink { [weak self] _ in self?.captureLive(model) }
            .store(in: &cancellables)
        model.live.$rr
            .sink { [weak self] _ in self?.captureLive(model) }
            .store(in: &cancellables)
    }

    private func captureLive(_ model: AppModel) {
        let now = Int(Date().timeIntervalSince1970)
        let cut = now - WatchdogConfig.contextSeconds
        if let sample = WatchdogLiveTape.hrSample(
            lastRingTs: liveHRRing.last?.ts,
            packetUnix: model.live.lastHeartRatePacketUnix,
            packetBpm: model.live.lastHeartRatePacketBpm
        ) {
            liveHRRing.append(sample)
        }
        if let beat = WatchdogLiveTape.rrSample(
            lastSeq: lastRRSeq,
            currentSeq: model.live.rrSeq,
            lastRingTs: liveRRRing.last?.ts,
            packetUnix: model.live.lastHeartRatePacketUnix,
            rrMs: model.live.rr.last
        ) {
            lastRRSeq = model.live.rrSeq
            liveRRRing.append(beat)
        }
        liveHRRing.removeAll { $0.ts < cut }
        liveRRRing.removeAll { $0.ts < cut }
    }

    private func loadWindow(model: AppModel, now: Int) async -> Result<WatchdogWindow, WatchdogUnavailable> {
        guard let store = await model.repo.storeHandle() else {
            return windowFromLiveOnly(model: model, now: now)
        }
        let from = now - WatchdogConfig.contextSeconds
        let id = model.deviceId
        let family: DeviceFamily = UserDefaults.standard.string(forKey: "selectedWhoopModel") == WhoopModel.whoop5mg.rawValue
            ? .whoop5 : .whoop4
        let limit = family == .whoop5 ? 8_000 : 4_000

        let hrStored = (try? await store.hrSamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        let rrStored = (try? await store.rrIntervals(deviceId: id, from: from, to: now, limit: 8_000)) ?? []
        let tempLists = (try? await store.skinTempSamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        let spo2Lists = (try? await store.spo2Samples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        let respRows = (try? await store.respSamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        var respPerMin = WatchdogWindowBuilder.respPerMin(
            rawRows: respRows.map { (ts: $0.ts, raw: $0.raw) },
            ringRate: OuraRespScale.isRingRateStream(deviceId: id),
            start: from, end: now)
        let eventLists = (try? await store.events(deviceId: id, from: from, to: now, limit: 400)) ?? []
        let stepLists = (try? await store.stepSamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        var hr = hrStored
        hr.append(contentsOf: liveHRRing.filter { sample in
            sample.ts >= from && sample.ts <= now && !hr.contains(where: { $0.ts == sample.ts })
        })
        var rr = rrStored
        rr.append(contentsOf: liveRRRing.filter { beat in
            beat.ts >= from && beat.ts <= now
        })
        if respPerMin.isEmpty {
            let window = Repository.hrvRollingWindowSec(spanSeconds: max(1, now - from))
            let step = Repository.respRollingStepSec(windowSec: window)
            respPerMin = SleepStager.rollingRespRate(rr, windowSec: window, stepSec: step)
                .filter { $0.ts >= from && $0.ts <= now }
                .map { WatchdogScalarSample(ts: $0.ts, value: $0.breathsPerMinute) }
        }
        let tempsRaw = tempLists.sorted { $0.ts < $1.ts }
        let temps = tempsRaw.map {
            WatchdogScalarSample(ts: $0.ts, value: skinTempCelsius(raw: $0.raw, family: family))
        }
        let gravity = (try? await store.gravitySamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        let imu = Self.imuSamples(gravity: gravity, family: family, store: store, deviceId: id, from: from, to: now)
        let motion = imu.map { sample -> WatchdogScalarSample in
            let mag = (sample.x * sample.x + sample.y * sample.y + sample.z * sample.z).squareRoot()
            let fromVector = min(1, max(0, abs(mag - 1.0) / 0.4))
            let occ: Double
            if let dyn = sample.dynAccel { occ = min(1, max(0, dyn / 0.4)) }
            else { occ = fromVector }
            return WatchdogScalarSample(ts: sample.ts, value: occ)
        }
        let events = eventLists.sorted { $0.ts < $1.ts }
        let liveBeating = WatchdogLiveTape.isFresh(
            packetUnix: model.live.lastHeartRatePacketUnix,
            now: now,
            freshnessSeconds: WatchdogQuality.freshnessLimit(family)
        )
        let wristOff = WatchdogLiveTape.wristOff(deviceOff: lastWristOff(events), freshLiveHR: liveBeating)
        var spo2Pct = spo2Lists.sorted { $0.ts < $1.ts }.compactMap { sample -> WatchdogScalarSample? in
            guard let pct = WatchdogWindowBuilder.percentFromOptical(red: sample.red, ir: sample.ir) else {
                return nil
            }
            return WatchdogScalarSample(ts: sample.ts, value: pct)
        }
        let aux = (try? await store.v18AuxSamples(deviceId: id, from: from, to: now, limit: limit)) ?? []
        let strapSpO2 = Spo2StrapEstimate.readings(from: aux)
        if spo2Pct.isEmpty {
            spo2Pct = strapSpO2.map { WatchdogScalarSample(ts: $0.ts, value: Double($0.percent)) }
        } else {
            let have = Set(spo2Pct.map(\.ts))
            spo2Pct.append(contentsOf: strapSpO2.compactMap { reading in
                guard !have.contains(reading.ts) else { return nil }
                return WatchdogScalarSample(ts: reading.ts, value: Double(reading.percent))
            })
        }
        let usedLive = liveHRRing.contains { $0.ts >= from }
        let hrSource: WatchdogHRSource = usedLive ? .live2A37 : (family == .whoop5 ? .ppgHr : .v18)
        let steps = stepLists.sorted { $0.ts < $1.ts }
        let feed = WatchdogFeed(family: family, hrSource: hrSource, nowUnix: now,
                                hr: hr, rr: rr, skinTempC: temps, respPerMin: respPerMin,
                                motion: motion,
                                spo2Pct: spo2Pct, wristOff: wristOff,
                                holdSeeds: .empty,
                                imu: imu, steps: steps)
        return WatchdogWindowBuilder.build(feed)
    }

    private func windowFromLiveOnly(model: AppModel, now: Int) -> Result<WatchdogWindow, WatchdogUnavailable> {
        captureLive(model)
        let from = now - WatchdogConfig.contextSeconds
        let hr = liveHRRing.filter { $0.ts >= from }
        let liveBeating = WatchdogLiveTape.isFresh(
            packetUnix: model.live.lastHeartRatePacketUnix,
            now: now,
            freshnessSeconds: WatchdogQuality.freshnessLimit(.whoop4)
        )
        if hr.isEmpty && !liveBeating { return .failure(.empty) }
        let feed = WatchdogFeed(family: .whoop4, hrSource: .live2A37, nowUnix: now,
                                hr: hr, rr: liveRRRing.filter { $0.ts >= from },
                                wristOff: false,
                                holdSeeds: .empty)
        return WatchdogWindowBuilder.build(feed)
    }

    private func lastWristOff(_ events: [WhoopEvent]) -> Bool {
        var off = false
        for e in events.sorted(by: { $0.ts < $1.ts }) {
            if e.kind.hasPrefix("WRIST_OFF") { off = true }
            if e.kind.hasPrefix("WRIST_ON") { off = false }
        }
        return off
    }

    private static let carryKeyPrefix = "noop.watchdog.carry.v2."
    private static let legacyCarryKey = "noop.watchdog.carry.v1"
    private static let legacyMigratedKey = "noop.watchdog.carry.v1.migratedTo"

    private static func carryKey(deviceId: String) -> String {
        carryKeyPrefix + deviceId
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

    private func persistCarry(deviceId: String) {
        if let data = try? JSONEncoder().encode(carry) {
            UserDefaults.standard.set(data, forKey: Self.carryKey(deviceId: deviceId))
        }
    }

    /// Lane B is SQLite `gravitySample`, plus any second the 100 Hz capture has that SQLite does not.
    /// A live walk updates heart rate before the next gravity row is stored. Those seconds still
    /// have dynamic acceleration in the raw file, and that is what moves the HR corridor.
    /// SQLite x/y/z win on a shared second. A nil `dynAccel` is filled from the same second in the file.
    /// A logged bicep or other site drops the wrist IMU model entirely.
    private static func imuSamples(gravity: [GravitySample], family: DeviceFamily, store: WhoopStore,
                                   deviceId: String, from: Int, to: Int) -> [WatchdogIMUSample] {
        if placementDropsWristImu(store: store, deviceId: deviceId, now: to) { return [] }
        _ = family
        let sqlite = gravity.map {
            WatchdogIMUSample(ts: $0.ts, x: $0.x, y: $0.y, z: $0.z, dynAccel: $0.dynAccel)
        }
        let raw = ImuSessionFileStore.shared.readRecords(deviceId: deviceId, fromTs: Int64(from), toTs: Int64(to))
        let fromFiles = WatchdogGravityFill.fromRawIMU(raw)
        if fromFiles.isEmpty { return sqlite }
        if sqlite.isEmpty { return fromFiles }
        var dynByTs: [Int: Double?] = [:]
        for sample in fromFiles { dynByTs[sample.ts] = sample.dynAccel }
        let covered = Set(sqlite.map(\.ts))
        let filled = sqlite.map { sample -> WatchdogIMUSample in
            guard sample.dynAccel == nil, let dyn = dynByTs[sample.ts] ?? nil else { return sample }
            return WatchdogIMUSample(ts: sample.ts, x: sample.x, y: sample.y, z: sample.z, dynAccel: dyn)
        }
        return filled + fromFiles.filter { !covered.contains($0.ts) }
    }

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

    private func asleepBandIntervals(model: AppModel, now: Int) async -> [WatchdogSleepInterval] {
        guard let store = await model.repo.storeHandle() else { return [] }
        let from = now - WatchdogConfig.contextSeconds
        var samples: [SleepStateSample] = []
        for id in await model.repo.watchdogSourceIds() {
            samples += (try? await store.sleepStateSamples(deviceId: id, from: from, to: now + 60)) ?? []
        }
        return Self.asleepIntervals(from: samples)
    }

    private static func placementDropsWristImu(store: WhoopStore, deviceId: String, now: Int) -> Bool {
        guard let placementStore = try? PlacementStore(dbQueue: store.registryWriter),
              let interval = try? placementStore.activePlacement(
                at: Date(timeIntervalSince1970: TimeInterval(now)), deviceId: deviceId)
        else { return false }
        switch interval.placement {
        case .bicep, .other: return true
        case .wrist, .unknown: return false
        }
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
