import Foundation
import NoopPush
import WhoopProtocol
import WhoopStore

/// The capture boundary.
///
/// Every call here is additive and cheap: it builds the wire rows for one notification and hands them
/// to the journal's non-blocking staging path. Nothing in this file can throw into the BLE pipeline,
/// block it, or change what the local store records — a cloud failure must never stop collection.
///
/// Rows are encoded as the receiver's canonical `{"key":…,"data":{…}}` object using the SAME decode
/// functions the local store uses (`extractStreams` for proprietary frames, `StandardHRMapping` for
/// 0x2A37), so the cloud sees the rows the phone actually banked rather than a second, differently
/// interpreted copy.
public enum CloudCapture {

    /// Why a frame was not journaled. Reported rather than hidden: these are real capture gaps.
    public enum Skip: Equatable {
        case notRunning
        /// No clock correlation yet, so the frame has no trustworthy timestamp. The local pipeline
        /// buffers these and persists them once the clock lands; the cloud journal does not guess.
        case preClock
        case nothingToRecord
    }

    // MARK: - proprietary frames (WHOOP realtime / custom envelopes)

    /// Journal one reassembled frame's decoded rows.
    ///
    /// Called from `Collector.ingest(frame:parsed:)` — the notification boundary, before the 64-frame
    /// / 30-second store buffer. The journal's own coalescing is bounded to well under a second, so
    /// cloud durability is not controlled by that buffer.
    @discardableResult
    public static func record(frame: ParsedFrame,
                              deviceId: String,
                              clockRef: ClockRef?,
                              family: DeviceFamily,
                              receivedAtMs: Int,
                              characteristic: String? = nil) -> Skip? {
        // The master switch is checked HERE, before the heart-rate ledger claims anything: a second
        // claimed but never staged would otherwise be skipped as "already sent" after re-enable.
        // `sharedIfRunning` is nil once the runtime is stopped, so this only matters in the tiny
        // window between the user flipping the switch and `stop()` running (D1).
        guard CloudPushSettings.isEnabled, let runtime = CloudPushRuntime.sharedIfRunning else { return .notRunning }
        guard let ref = clockRef else {
            runtime.noteSkippedPreClock(1)
            return .preClock
        }
        var streams = extractStreams([frame], deviceClockRef: ref.device, wallClockRef: ref.wall,
                                     family: family)
        if let ledger = journalLedger { streams = freshHeartRates(streams, deviceId: deviceId, ledger: ledger) }
        let records = rows(from: streams, provenance: .live, family: family,
                           wallClockRef: ref.wall, deviceClockRef: ref.device,
                           receivedAtMs: receivedAtMs, characteristic: characteristic,
                           deviceId: deviceId)
        guard !records.isEmpty else { return .nothingToRecord }
        runtime.submit(records)
        return nil
    }

    // MARK: - standard 0x2A37 HR / RR / contact

    /// Journal one standard Heart Rate Measurement notification.
    ///
    /// This path is included deliberately: it is the always-on stream and it does NOT pass through the
    /// proprietary raw outbox, so a journal that only watched custom frames would miss the most
    /// reliable input the app has. Its rows go through `StandardHRMapping`, the same mapping the local
    /// store uses, so contact transitions are recorded identically on both sides.
    @discardableResult
    public static func recordStandardHR(hr: Int,
                                        rr: [Int],
                                        contact: StandardHRContact?,
                                        family: DeviceFamily?,
                                        at ts: Int,
                                        deviceId: String,
                                        receivedAtMs: Int,
                                        characteristic: String = "2A37") -> Skip? {
        // Same master-switch gate as `record(frame:)` — see the comment there (D1).
        guard CloudPushSettings.isEnabled, let runtime = CloudPushRuntime.sharedIfRunning else { return .notRunning }
        let records = standardHRRecords(hr: hr, rr: rr, contact: contact, family: family, at: ts,
                                        deviceId: deviceId, receivedAtMs: receivedAtMs,
                                        characteristic: characteristic, ledger: journalLedger)
        guard !records.isEmpty else { return .nothingToRecord }
        runtime.submit(records)
        return nil
    }

    /// The journal rows for one standard Heart Rate Measurement. With a ledger, the heart-rate row is
    /// left out when the journal already holds that second (see `CloudHeartRateLedger`); the R-R rows
    /// are not affected, the receiver already keeps those apart by beat.
    static func standardHRRecords(hr: Int,
                                  rr: [Int],
                                  contact: StandardHRContact?,
                                  family: DeviceFamily?,
                                  at ts: Int,
                                  deviceId: String,
                                  receivedAtMs: Int,
                                  characteristic: String,
                                  ledger: CloudHeartRateLedger?) -> [CloudJournalRecord] {
        let acceptedHR = (30...220).contains(hr)
        let acceptedRR = rr.filter { (250...3000).contains($0) }
        let source: RRSourceChannel? = family == .whoop5 ? .whoop5Standard
            : (family == .whoop4 ? .whoop4Standard : nil)
        var streams = StandardHRMapping.samples(fromHR: hr, rr: acceptedRR, contact: contact, at: ts)
        if !acceptedHR { streams.hr = [] }
        streams.rr = acceptedRR.map { RRInterval(ts: ts, rrMs: $0, srcChannel: source) }
        if let ledger { streams = freshHeartRates(streams, deviceId: deviceId, ledger: ledger) }
        return rows(from: streams, provenance: .live, family: family,
                    wallClockRef: nil, deviceClockRef: nil,
                    receivedAtMs: receivedAtMs, characteristic: characteristic,
                    deviceId: deviceId)
    }

    // MARK: - strap history offload

    /// Journal rows the strap's history offload banked.
    ///
    /// The offload is the only source of the overnight record (per-second HR with motion, skin
    /// temperature, steps and band sleep state); live notifications never carry it. Callers pass rows
    /// that are ALREADY durable in the local store, so the store stays the source of truth and a chunk
    /// the strap re-sends after a failed insert is never journaled before it is banked.
    ///
    /// One chunk can hold more rows than the staging buffer, so rows are encoded off the main actor and
    /// committed in bounded slices.
    ///
    /// The offload returns every second the live notifications already carried, so its heart-rate rows
    /// are filtered through `CloudHeartRateLedger`: only seconds the journal does not hold yet are sent.
    ///
    /// Returns the number of records the journal committed plus the heart-rate rows that were already in
    /// the journal. 0 therefore still means "the journal took nothing", which callers retry, and never
    /// means "everything in this chunk was already sent".
    @discardableResult
    public static func recordHistory(_ streams: Streams,
                                     deviceId: String,
                                     family: DeviceFamily?,
                                     clockRef: ClockRef?) async -> Int {
        // Same master-switch gate as `record(frame:)` (D1). Returns 0 so the caller retries the
        // window on the next pass instead of treating it as fully sent.
        guard CloudPushSettings.isEnabled, let runtime = CloudPushRuntime.sharedIfRunning else { return 0 }
        let fresh = journalLedger.map { freshHeartRates(streams, deviceId: deviceId, ledger: $0) } ?? streams
        let alreadyHeld = streams.hr.count - fresh.hr.count
        let receivedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        let records = await Task.detached(priority: .utility) {
            rows(from: fresh, provenance: .history, family: family,
                 wallClockRef: clockRef?.wall, deviceClockRef: clockRef?.device,
                 receivedAtMs: receivedAtMs, characteristic: nil, deviceId: deviceId)
        }.value
        guard !records.isEmpty else { return alreadyHeld }
        let committed = await runtime.submitDurably(records)
        return committed > 0 ? committed + alreadyHeld : 0
    }

    // MARK: - heart-rate seconds

    /// The ledger capture consults, or nil while the journal is not taking records (nothing is then
    /// being sent, so nothing may be counted as sent).
    private static var journalLedger: CloudHeartRateLedger? {
        CloudJournal.isStaging ? CloudHeartRateLedger.shared : nil
    }

    /// `streams` with only the heart-rate samples whose second the journal does not hold. The seconds
    /// kept are taken, so a second reaches the journal once, from whichever lane delivers it first.
    static func freshHeartRates(_ streams: Streams, deviceId: String?,
                                ledger: CloudHeartRateLedger) -> Streams {
        guard !streams.hr.isEmpty else { return streams }
        var out = streams
        out.hr = ledger.claim(streams.hr, deviceId: deviceId)
        return out
    }

    // MARK: - row encoding

    /// Encode decoded streams as journal records.
    ///
    /// The receiver's registry requires every declared data column on a record, so absent optional
    /// values are sent as explicit JSON nulls rather than omitted — an omitted column is a rejection,
    /// and "unknown" is not the same as "zero".
    static func rows(from streams: Streams,
                     provenance: CloudProvenance,
                     family: DeviceFamily?,
                     wallClockRef: Int?,
                     deviceClockRef: Int?,
                     receivedAtMs: Int,
                     characteristic: String?,
                     deviceId: String?) -> [CloudJournalRecord] {
        var out: [CloudJournalRecord] = []
        let familyName = family.map { String(describing: $0) }

        func make(_ stream: CloudStreamKind, _ key: [String: PushJSONValue],
                  _ data: [String: PushJSONValue], strapTs: Int?) -> CloudJournalRecord? {
            guard let payload = try? PushProtocol.canonicalJson(.map(["key": .map(key), "data": .map(data)])),
                  let encoded = payload.data(using: .utf8) else { return nil }
            return CloudJournalRecord(stream: stream, encoding: .jsonRow, provenance: provenance,
                                      characteristic: characteristic, family: familyName,
                                      firmware: nil, receivedAtMs: receivedAtMs, strapTs: strapTs,
                                      wallClockRef: wallClockRef, deviceClockRef: deviceClockRef,
                                      deviceId: deviceId, payload: encoded)
        }

        for hr in streams.hr {
            if let record = make(.hrSample, ["ts": .int(Int64(hr.ts))], ["bpm": .int(Int64(hr.bpm))],
                                 strapTs: hr.ts) { out.append(record) }
        }
        for rr in streams.rr {
            // `seq` is part of the receiver's RR identity and the local store's key is
            // (deviceId, ts, rrMs), so equal beats in one second are already collapsed before capture;
            // the decoded row's own seq is carried through unchanged.
            let key: [String: PushJSONValue] = ["ts": .int(Int64(rr.ts)),
                                                "rrMs": .int(Int64(rr.rrMs)),
                                                "seq": .int(Int64(rr.seq))]
            let data: [String: PushJSONValue] = [
                "ord": rr.ord.map { .int(Int64($0)) } ?? .null,
                "srcChannel": rr.srcChannel.map { .int(Int64($0.rawValue)) } ?? .null,
                // The local decoder does not flag suspect beats on this path; null means "not
                // assessed", which is the honest value rather than a fabricated `false`.
                "tsSuspect": .null,
            ]
            if let record = make(.rrInterval, key, data, strapTs: rr.ts) { out.append(record) }
        }
        for event in streams.events {
            let payload = Self.jsonString(event.payload)
            let key: [String: PushJSONValue] = ["ts": .int(Int64(event.ts)), "kind": .string(event.kind)]
            if let record = make(.event, key, ["payloadJSON": .string(payload)], strapTs: event.ts) {
                out.append(record)
            }
        }
        for battery in streams.battery {
            let data: [String: PushJSONValue] = [
                "soc": battery.soc.map { .double($0) } ?? .null,
                "mv": battery.mv.map { .int(Int64($0)) } ?? .null,
                "charging": battery.charging.map { .bool($0) } ?? .null,
            ]
            if let record = make(.battery, ["ts": .int(Int64(battery.ts))], data, strapTs: battery.ts) {
                out.append(record)
            }
        }
        for spo2 in streams.spo2 {
            let data: [String: PushJSONValue] = ["red": .int(Int64(spo2.red)), "ir": .int(Int64(spo2.ir))]
            if let record = make(.spo2Sample, ["ts": .int(Int64(spo2.ts))], data, strapTs: spo2.ts) {
                out.append(record)
            }
        }
        for temp in streams.skinTemp {
            let data: [String: PushJSONValue] = [
                "raw": .int(Int64(temp.raw)),
                "aux1Raw": temp.aux1Raw.map { .int(Int64($0)) } ?? .null,
                "aux2Raw": temp.aux2Raw.map { .int(Int64($0)) } ?? .null,
            ]
            if let record = make(.skinTempSample, ["ts": .int(Int64(temp.ts))], data, strapTs: temp.ts) {
                out.append(record)
            }
        }
        for resp in streams.resp {
            if let record = make(.respSample, ["ts": .int(Int64(resp.ts))], ["raw": .int(Int64(resp.raw))],
                                 strapTs: resp.ts) { out.append(record) }
        }
        for gravity in streams.gravity {
            let data: [String: PushJSONValue] = [
                "x": .double(gravity.x), "y": .double(gravity.y), "z": .double(gravity.z),
                "dynAccel": gravity.dynAccel.map { .double($0) } ?? .null,
            ]
            if let record = make(.gravitySample, ["ts": .int(Int64(gravity.ts))], data, strapTs: gravity.ts) {
                out.append(record)
            }
        }
        // Scalar-extension rows are range-checked by the wire package when a batch is sealed, and one
        // out-of-range row fails the whole batch. A row the decoder produced outside the contract is left
        // out here instead of wedging every later row of its stream.
        for step in streams.steps where (0...65535).contains(step.counter)
            && step.activityClass.map({ (0...2).contains($0) }) ?? true {
            let data: [String: PushJSONValue] = [
                "counter": .int(Int64(step.counter)),
                "activityClass": step.activityClass.map { .int(Int64($0)) } ?? .null,
            ]
            if let record = make(.stepSample, ["ts": .int(Int64(step.ts))], data, strapTs: step.ts) {
                out.append(record)
            }
        }
        for sample in streams.sleepState where (0...3).contains(sample.state)
            && sample.rawByte.map({ (0...255).contains($0) && ($0 >> 4) & 3 == sample.state }) ?? true {
            let data: [String: PushJSONValue] = [
                "state": .int(Int64(sample.state)),
                "rawByte": sample.rawByte.map { .int(Int64($0)) } ?? .null,
            ]
            if let record = make(.sleepStateSample, ["ts": .int(Int64(sample.ts))], data, strapTs: sample.ts) {
                out.append(record)
            }
        }
        // The strap's own SpO₂ estimate (5/MG `@82`) rides as one event row per in-band second. The receiver
        // has no stream for the aux byte, and an event row is keyed by (ts, kind), so a second sent twice
        // is a no-op there. The server reduces the readings with the same nightly gate the app applies.
        for reading in Spo2StrapEstimate.readings(from: streams.v18Aux) {
            let key: [String: PushJSONValue] = ["ts": .int(Int64(reading.ts)),
                                                "kind": .string(Spo2StrapEstimate.eventKind)]
            let data: [String: PushJSONValue] = [
                "payloadJSON": .string(Spo2StrapEstimate.payloadJSON(percent: reading.percent)),
            ]
            if let record = make(.event, key, data, strapTs: reading.ts) { out.append(record) }
        }
        return out
    }

    static func jsonString(_ payload: [String: ParsedValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// The heart-rate seconds the cloud journal already holds, per device.
///
/// The receiver keeps one bpm per (device, second). A second that comes in again with a different bpm
/// is a conflict: it deletes the row it holds and refuses that second from then on. The phone does
/// offer a second more than once:
///  - the strap's 1 Hz notification lands twice inside one second now and then, because the arrival
///    jitter that doubles one second empties the one before it;
///  - the history offload hands back, a minute or two later and stamped by the strap's own clock, every
///    second the live notifications already carried, with a bpm that matches the live one in about a
///    quarter of the seconds.
/// Left alone, that erased up to half of a connected day's heart rate on the server while the phone's own
/// store, which keeps the first value it sees, held all of it.
///
/// The ledger gives the journal the store's rule: a second is sent once, with whichever sample reached
/// the journal first, and later samples for it are dropped. Seconds the offload carries that no live
/// notification covered (the phone was out of range, or the app was not running) are still sent.
///
/// Held in memory. A relaunch seeds it from the journal's tail (`CloudPushRuntime.start`), and `stop`
/// clears it, so what it holds never outlives what the journal was given.
final class CloudHeartRateLedger: @unchecked Sendable {
    static let shared = CloudHeartRateLedger()

    /// How many of the journal's newest heart-rate records a relaunch reads back. A history offload
    /// follows the live notifications by minutes, so this is hours of cover.
    static let seedRecords = 100_000

    private let lock = NSLock()
    private var held: [String: Set<Int>] = [:]
    private let retainSeconds: Int
    private let capacity: Int

    /// `retainSeconds` is how far behind now a second may be before trimming forgets it; `capacity`
    /// bounds one device's set, so a chunk with years of timestamps cannot grow it without limit.
    init(retainSeconds: Int = 24 * 3600, capacity: Int = 200_000) {
        self.retainSeconds = retainSeconds
        self.capacity = capacity
    }

    /// The samples whose second is new, in order, with those seconds now held. A second already held,
    /// or repeated inside `samples`, keeps its first sample and loses the rest.
    func claim(_ samples: [HRSample], deviceId: String?,
               now: Int = Int(Date().timeIntervalSince1970)) -> [HRSample] {
        guard !samples.isEmpty else { return [] }
        let key = Self.key(deviceId)
        lock.lock(); defer { lock.unlock() }
        var fresh: [HRSample] = []
        fresh.reserveCapacity(samples.count)
        for sample in samples {
            if held[key, default: []].insert(sample.ts).inserted { fresh.append(sample) }
        }
        if let count = held[key]?.count, count > capacity {
            let earliest = now - retainSeconds
            let latest = now + 3600
            held[key] = held[key]?.filter { $0 >= earliest && $0 <= latest }
        }
        return fresh
    }

    /// Marks seconds the journal already holds, for one device each. Used after a relaunch.
    func seed(_ seconds: [String: [Int]]) {
        lock.lock(); defer { lock.unlock() }
        for (device, list) in seconds where !list.isEmpty {
            held[Self.key(device), default: []].formUnion(list)
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        held.removeAll()
    }

    func holds(_ second: Int, deviceId: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held[Self.key(deviceId)]?.contains(second) ?? false
    }

    func count(deviceId: String?) -> Int {
        lock.lock(); defer { lock.unlock() }
        return held[Self.key(deviceId)]?.count ?? 0
    }

    private static func key(_ deviceId: String?) -> String { (deviceId ?? "").lowercased() }
}

/// Process-wide owner of the cloud runtime.
///
/// One place decides whether the cloud path is on, and one place owns the objects that must be shared
/// (the journal, the upload session and the coordinator). Everything is created only when cloud mode
/// is enabled AND an enrollment identity exists, so an unconfigured or disabled build allocates
/// nothing and behaves exactly like offline NOOP.
public final class CloudPushRuntime: @unchecked Sendable {
    public static let shared = CloudPushRuntime()

    private let lock = NSLock()
    private var _journal: CloudJournal?
    private var _coordinator: CloudTransportCoordinator?
    private var _session: CloudUploadSession?
    private var _scoreRepository: ServerScoreRepository?
    private var _deviceId: String?
    private var skippedPreClock = 0
    private var appIsActive = true
    /// Object-lane pieces for the rawImuSession binary table (CONTRACTS C1). Source, HTTP transport
    /// and durable progress live for the whole enrollment; the coordinator is built per lane pass
    /// once capabilities are known, and the lane loop runs on its own task at a bounded cadence.
    private var _objectTransport: ImuObjectTransport?
    private var _objectProgress: ImuPushProgressStore?
    private var _objectSource: ImuObjectSource?
    private var _objectLoopTask: Task<Void, Never>?
    private var _objectCapabilities: PushCapabilities?
    private var _objectCapabilitiesAt: Int = 0
    /// The D2 retry: re-attempts `journal.activate` when protected data becomes available after a
    /// locked launch. Cancelled on `stop()` so a disabled/signed-out runtime never re-activates.
    private var _reactivationTask: Task<Void, Never>?

    private init() {}

    /// The running runtime, or nil when cloud mode is off. Read from the BLE path, so it is a plain
    /// lock-guarded read with no allocation.
    public static var sharedIfRunning: CloudPushRuntime? {
        shared.isRunning ? shared : nil
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _coordinator != nil
    }

    public var journalIfRunning: CloudJournal? {
        lock.lock(); defer { lock.unlock() }
        return _journal
    }

    public var coordinatorIfRunning: CloudTransportCoordinator? {
        lock.lock(); defer { lock.unlock() }
        return _coordinator
    }

    /// Start the cloud path for an enrolled identity and the active device.
    public func start(identity: CloudPushIdentity, deviceId: String) throws {
        lock.lock()
        let alreadyRunning = _coordinator != nil
        lock.unlock()
        if alreadyRunning { return }

        guard let endpoint = CloudPushSettings.receiverURL, CloudPushSettings.isConfigured else {
            throw CloudTransportCoordinator.CoordinatorError.notConfigured
        }
        let directory = try CloudJournalPaths.defaultDirectory()
        let payloadDirectory = directory.appendingPathComponent("payload", isDirectory: true)
        let journal = CloudJournal.shared
        let configuration = CloudJournal.Configuration(ownerId: identity.ownerId,
                                                       sourceId: identity.sourceId,
                                                       deviceId: deviceId)
        var policy = CloudJournal.SealPolicy()
        policy.activeTargetSeconds = Self.sealTargetSeconds(sceneActive: appIsActiveValue)
        // Accept records IMMEDIATELY, before the store opens: this method is reached from the app
        // delegate on a Bluetooth relaunch, and the earliest restored notifications can arrive while
        // the SQLite file is still opening. They stage in order and commit as soon as it is open.
        CloudJournal.enableStaging()

        let session = CloudUploadSession(endpoint: endpoint, fleetToken: CloudPushSettings.fleetToken,
                                         bundleIdentifier: Bundle.main.bundleIdentifier,
                                         identity: { CloudPushIdentityStore.current() })
        let coordinator = CloudTransportCoordinator(journal: journal, session: session,
                                                   payloadDirectory: payloadDirectory,
                                                   projectURL: CloudPushSettings.canonicalProjectURL,
                                                   identity: { CloudPushIdentityStore.current() })
        // The prompt lane is chosen from the scene phase, which only the app layer knows. Push it in.
        CloudTransportCoordinator.appIsActiveProvider = { [weak self] in
            self?.appIsActiveValue ?? true
        }
        CloudHeartRateLedger.shared.reset()
        // Object lane (CONTRACTS C1): the rawImuSession binary table is uploaded through the
        // NoopPush object lane, never the NDJSON journal. A failure to open the durable progress
        // store disables only the object lane for this enrollment (rows stay local) — it must not
        // block the typed capture path.
        let objectProgress = try? ImuPushProgressStore(directory: directory)
        let objectTransport = ImuObjectTransport(endpoint: endpoint,
                                                 fleetToken: CloudPushSettings.fleetToken,
                                                 identity: { CloudPushIdentityStore.current() })
        let objectSource = ImuObjectSource(store: ImuSessionFileStoreReader(),
                                           deviceId: { [weak self] in self?._deviceId },
                                           uploadAllowed: { CloudPushSettings.isEnabled })
        lock.lock()
        _journal = journal
        _coordinator = coordinator
        _session = session
        _deviceId = deviceId.lowercased()
        _objectTransport = objectTransport
        _objectProgress = objectProgress
        _objectSource = objectProgress != nil ? objectSource : nil
        lock.unlock()
        Task {
            await journal.setCommitObserver { [weak coordinator] _ in coordinator?.kick() }
            do {
                try await journal.activate(configuration: configuration, policy: policy)
                await Self.activateLedgerFromJournalTail(journal)
            } catch {
                // A protected-data failure (locked phone before the first unlock) is not fatal: the
                // journal cannot open yet, so staging stays off. Unlike the previous build, this is
                // not a dead end: schedule the re-activation retry that fires the moment the
                // journal's files become readable again (D2), so live seconds captured after a
                // locked launch still reach the cloud.
                CloudJournal.disableStaging()
                scheduleJournalReactivation(journal: journal, configuration: configuration,
                                            policy: policy, directory: directory)
            }
            await coordinator.start()
        }
        if objectProgress != nil {
            let loop = Task { await self.runObjectLaneLoop() }
            lock.lock(); _objectLoopTask = loop; lock.unlock()
        }
    }

    /// How long records may wait in the journal before they are sealed into a file. Two seconds while
    /// the scene is on screen; ten while it is not, which still lands every record on the server within
    /// about a quarter of a minute but wakes the radio a fifth as often.
    static func sealTargetSeconds(sceneActive: Bool) -> Double { sceneActive ? 2 : 10 }

    /// Scene phase, pushed by the app layer. It sets how often the journal seals; uploads use the
    /// in-process lane in either state (see `CloudTransportCoordinator.lane`).
    public func setAppIsActive(_ active: Bool) {
        lock.lock()
        appIsActive = active
        let journal = _journal
        lock.unlock()
        guard let journal else { return }
        let target = Self.sealTargetSeconds(sceneActive: active)
        Task { await journal.setActiveTargetSeconds(target) }
    }

    var appIsActiveValue: Bool {
        lock.lock(); defer { lock.unlock() }
        return appIsActive
    }

    /// Start the cloud path from a launch that has no AppModel yet.
    ///
    /// A Bluetooth state-restoration relaunch (and a background URLSession relaunch) can reach the app
    /// delegate without ever creating a scene, so this is the path that keeps capture durable in the
    /// case the whole feature exists for. It is idempotent, and a no-op unless cloud mode is enabled
    /// AND an enrollment identity exists — an offline install allocates nothing here.
    ///
    /// `fallbackDeviceId` is only the default for records that do not carry their own device id; the
    /// capture seams stamp the real one per record, so a WHOOP-to-WHOOP switch stays correct.
    @discardableResult
    public func startIfEnabled(fallbackDeviceId: String = "my-whoop") -> Bool {
        guard CloudPushSettings.isEnabled, CloudPushSettings.isConfigured else { return false }
        guard let identity = CloudPushIdentityStore.current() else { return false }
        do {
            try start(identity: identity, deviceId: fallbackDeviceId)
            return true
        } catch {
            return false
        }
    }

    /// Forward the app delegate's background-URLSession completion handler to the stable session.
    ///
    /// iOS requires the handler to be called once the session's events are delivered; the session calls
    /// it as soon as it has no outstanding tasks (immediately when it never had any).
    public func takeBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        let session = _session
        lock.unlock()
        guard let session else {
            handler()
            return
        }
        session.takeBackgroundCompletionHandler(handler)
    }

    /// Flush staged records and start a pass. Called on lifecycle transitions, when execution is
    /// available and the ≤1 s coalescing window should be closed out.
    public func flushAndKick() async {
        await flush()
    }

    /// The server-score cache for the running owner, created on first use.
    ///
    /// Exposed so the presentation layer can read cached results synchronously and refresh
    /// asynchronously, which is the shape the spec asks for (show cached immediately, fetch behind it).
    public func scoreRepository() -> ServerScoreRepository? {
        guard isRunning else { return nil }
        lock.lock()
        let existing = _scoreRepository
        lock.unlock()
        if let existing { return existing }
        let created = ServerScoreRepository()
        lock.lock()
        _scoreRepository = created
        lock.unlock()
        return created
    }

    /// Pull the server's changed-days page and refresh those days into the cache.
    ///
    /// This is the cloud-mode replacement for a local re-score pass: the phone asks the server what
    /// changed since its cursor instead of recomputing anything. Failures are swallowed into the
    /// journal's error surface — a readback failure must never block capture or transport.
    @discardableResult
    public func refreshServerScores(deviceId: String, maxDays: Int = 8) async -> Int {
        guard let repository = scoreRepository() else { return 0 }
        do {
            let changes = try await repository.pollChangedDays(deviceId: deviceId)
            var refreshed = 0
            for change in changes.prefix(maxDays) {
                _ = try? await repository.refresh(day: change.day, deviceId: deviceId)
                refreshed += 1
            }
            return refreshed
        } catch {
            return 0
        }
    }

    public func stop() async {
        lock.lock()
        let coordinator = _coordinator
        _coordinator = nil
        _journal = nil
        _deviceId = nil
        let objectLoop = _objectLoopTask
        _objectLoopTask = nil
        let reactivation = _reactivationTask
        _reactivationTask = nil
        _objectTransport = nil
        _objectProgress = nil
        _objectSource = nil
        _objectCapabilities = nil
        _objectCapabilitiesAt = 0
        lock.unlock()
        CloudHeartRateLedger.shared.reset()
        objectLoop?.cancel()
        reactivation?.cancel()
        await coordinator?.stop()
        await CloudJournal.shared.deactivate()
    }

    // MARK: - journal (re-)activation

    /// Seed the heart-rate ledger from what the last run already journaled, so an offload that
    /// overlaps it does not offer those seconds a second time with a different bpm.
    private static func activateLedgerFromJournalTail(_ journal: CloudJournal) async {
        let held = await journal.recentStrapSeconds(stream: .hrSample,
                                                    lastRecords: CloudHeartRateLedger.seedRecords)
        CloudHeartRateLedger.shared.seed(held)
    }

    /// Retry `journal.activate` until the protected journal becomes readable (D2).
    ///
    /// A Bluetooth relaunch on a phone that has not been unlocked since boot reaches `start()` while
    /// the journal file is still unreadable (`CloudJournalPaths.isDataAvailable` is false), and the
    /// first activation throws `protectedDataUnavailable`. Previously that left staging disabled for
    /// the whole process lifetime, so every live second captured after the locked launch was lost
    /// from the cloud path. This retry polls the same data-availability signal `activate` itself
    /// uses — cheap filesystem checks, no network — and re-attempts activation as soon as the first
    /// unlock makes the file readable, so live seconds after that point reach the cloud. Staged
    /// records from before the failure (the earliest restored notifications) are committed in the
    /// same activation. The task is cancelled by `stop()`, so a disabled or signed-out runtime never
    /// re-activates behind the user's back.
    private func scheduleJournalReactivation(journal: CloudJournal, configuration: CloudJournal.Configuration,
                                             policy: CloudJournal.SealPolicy, directory: URL) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: Self.journalReactivationPollNanoseconds) }
                catch { return }
                guard CloudJournalPaths.isDataAvailable(at: directory) else { continue }
                do {
                    try await journal.activate(configuration: configuration, policy: policy)
                    await Self.activateLedgerFromJournalTail(journal)
                    // Activation restarted the journal's drain loop; wake the transport so any
                    // records that were staged before the failure are sealed and sent now.
                    self?.coordinatorIfRunning?.kick()
                    return
                } catch {
                    // Still unavailable or a transient failure; retry on the next poll.
                    continue
                }
            }
        }
        lock.lock()
        _reactivationTask = task
        lock.unlock()
    }

    /// Poll cadence for the D2 re-activation retry. Two seconds: a first unlock is a hard OS
    /// transition, so this converges almost immediately after it, and the check is just a file
    /// stat. `@TaskLocal`-free and fixed so tests and production share one behaviour.
    static let journalReactivationPollNanoseconds: UInt64 = 2_000_000_000

    // MARK: - object lane (rawImuSession)

    /// Lane cadence for the rawImuSession object lane. Deliberately NOT per frame: the loop wakes
    /// every ~45 s, and a pass only does network work when a new object window exists.
    enum ObjectLaneCadence {
        static let sleepNanoseconds: UInt64 = 45_000_000_000
        /// Bounded drain per pass so a backlog (e.g. after an offline day) catches up in bounded
        /// steps instead of one unbounded run.
        static let maxObjectsPerPass = 8
        /// Capabilities are cheap but still a network call; renegotiate at most every 5 minutes.
        static let capabilitiesRefreshSeconds = 300
    }

    /// Drive the object lane: negotiate once per refresh window, then deliver bounded object
    /// windows for the active device. Offline/failure simply keeps rows local — the durable
    /// cursor only advances on a verified receipt, and the source never deletes store data.
    private func runObjectLaneLoop() async {
        while !Task.isCancelled {
            await runObjectLanePass()
            do { try await Task.sleep(nanoseconds: ObjectLaneCadence.sleepNanoseconds) }
            catch { return }
        }
    }

    private func runObjectLanePass() async {
        // `disableCloud()` only flips the setting; nothing stops the runtime, so ask on every pass.
        guard isRunning, CloudPushSettings.isEnabled else { return }
        lock.lock()
        let transport = _objectTransport
        let progress = _objectProgress
        let source = _objectSource
        let deviceId = _deviceId
        lock.unlock()
        guard let transport, let progress, let source, let deviceId,
              let identity = CloudPushIdentityStore.current() else { return }

        let caps = await negotiatedObjectCapabilities(transport: transport)
        guard let caps, PushProtocol.isObjectVersion(caps.protocolVersion),
              let lane = caps.objectLane, lane.streams.contains(.rawImuSession),
              let receiptOwner = try? AccountScope(projectURL: CloudPushSettings.canonicalProjectURL,
                                                   userID: identity.ownerId) else { return }

        // The coordinator is the state machine; the transport is the HTTP layer. A fresh wake
        // budget bounds one pass. `associateReceipt` is intentionally empty: the receipt is
        // validated by the coordinator, and durability is the cursor + in-flight records in the
        // progress store (advanced only after that validation).
        let coordinator = PushCoordinator(
            source: source,
            transport: transport,
            progress: progress,
            sourceId: identity.sourceId,
            destinationStillCurrent: { [weak self] in self?.isRunning ?? false },
            receiptOwner: receiptOwner,
            objectProtocolVersion: caps.protocolVersion,
            associateReceipt: { _, _, _ in },
            wakeBudget: PushWakeBudget(duration: 20)
        )
        var result = await coordinator.pushObjects(.rawImuSession, deviceId: deviceId, lane: lane)
        var drained = 0
        while case .accepted(_, _, let hasMore, _) = result, hasMore,
              drained < ObjectLaneCadence.maxObjectsPerPass {
            result = await coordinator.pushObjects(.rawImuSession, deviceId: deviceId, lane: lane)
            drained += 1
        }
    }

    /// Cached capability negotiation for the object lane: refreshed at most every
    /// `capabilitiesRefreshSeconds`; a failed refresh keeps the last known advertisement so a
    /// transient outage does not stop already-advertised uploads.
    private func negotiatedObjectCapabilities(transport: ImuObjectTransport) async -> PushCapabilities? {
        let now = Int(Date().timeIntervalSince1970)
        lock.lock()
        let cached = _objectCapabilities
        let cachedAt = _objectCapabilitiesAt
        lock.unlock()
        if let cached, now - cachedAt < ObjectLaneCadence.capabilitiesRefreshSeconds { return cached }
        do {
            guard case .available(let caps) = try await transport.capabilities() else { return cached }
            lock.lock()
            _objectCapabilities = caps
            _objectCapabilitiesAt = now
            lock.unlock()
            return caps
        } catch {
            return cached
        }
    }

    // MARK: - capture path (non-blocking)

    public func submit(_ records: [CloudJournalRecord]) {
        // Master-switch gate (D1): between the user flipping the switch and `stop()` running, a
        // capture can still reach this method; it must not stage a single record while cloud is off.
        guard CloudPushSettings.isEnabled, let journal = journalIfRunning else { return }
        journal.submit(records)
    }

    /// Stage and commit a bulk set of records one bounded slice at a time, so a large history chunk can
    /// never overrun the staging buffer. Returns how many records the journal committed.
    @discardableResult
    public func submitDurably(_ records: [CloudJournalRecord], sliceSize: Int = 2_000) async -> Int {
        // Master-switch gate (D1), same as `submit` — the history/SpO2 seeders and the backfill
        // offload all land here and must stop with the switch.
        guard CloudPushSettings.isEnabled, let journal = journalIfRunning, sliceSize > 0 else { return 0 }
        var committed = 0
        var start = records.startIndex
        while start < records.endIndex {
            let end = records.index(start, offsetBy: sliceSize, limitedBy: records.endIndex) ?? records.endIndex
            journal.submit(Array(records[start..<end]))
            committed += await journal.flush()
            start = end
        }
        coordinatorIfRunning?.kick()
        return committed
    }

    public func noteSkippedPreClock(_ count: Int) {
        lock.lock()
        skippedPreClock += count
        lock.unlock()
    }

    public var skippedPreClockCount: Int {
        lock.lock(); defer { lock.unlock() }
        return skippedPreClock
    }

    public func kick() { coordinatorIfRunning?.kick() }

    public func flush() async {
        guard let journal = journalIfRunning else { return }
        _ = await journal.flush()
        coordinatorIfRunning?.kick()
    }

    public func stats() async -> CloudJournalStats {
        guard let journal = journalIfRunning else { return .empty }
        return await journal.stats()
    }
}

/// One-time cloud upload of strap history that was banked locally before the offload was journaled.
///
/// Earlier builds kept the overnight offload only in the local store, so the server never received a
/// night to score. This replays a bounded recent span of those rows through the same history encoding
/// the Backfiller now uses, oldest hour first, and persists its cursor per owner and device so an
/// interrupted pass resumes where it stopped. Re-sending a row is harmless: the receiver keys rows by
/// identity, so a row the Backfiller already journaled is a no-op the second time. Heart rate is the
/// exception the ledger covers: a second the journal already holds is skipped here too, because a copy
/// with a different bpm is a conflict on the receiver, not a no-op.
public enum CloudHistorySeeder {
    static let lookbackSeconds = 48 * 3600
    static let windowSeconds = 3600

    struct Progress: Codable, Equatable {
        var cursor: Int
        var until: Int
    }

    static func defaultsKey(ownerId: String, deviceId: String) -> String {
        "noop.cloud.historySeed.v1.\(ownerId.lowercased()).\(deviceId.lowercased())"
    }

    /// Replay what is left of the seed span. Returns the number of records the journal committed on
    /// this pass; 0 once the span is done. A window whose rows the journal did not take is retried on
    /// the next call rather than skipped.
    ///
    /// `cloudDeviceId` replays the rows stored under `deviceId` as another device's uploads. The server
    /// scores each uploaded device on its own, so once a strap adopts its serial id, the hours banked
    /// under the earlier id must be sent under the new one or that day's totals only cover the hours since.
    @discardableResult
    public static func runIfNeeded(store: WhoopStore,
                                   deviceId: String,
                                   cloudDeviceId: String? = nil,
                                   family: DeviceFamily?,
                                   defaults: UserDefaults = .standard,
                                   now: Int = Int(Date().timeIntervalSince1970)) async -> Int {
        guard CloudPushRuntime.sharedIfRunning != nil,
              let ownerId = CloudPushIdentityStore.current()?.ownerId else { return 0 }
        let uploadId = cloudDeviceId ?? deviceId
        let key = defaultsKey(ownerId: ownerId, deviceId: uploadId)
        var progress = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Progress.self, from: $0) }
            ?? Progress(cursor: now - lookbackSeconds, until: now)
        var committed = 0
        while progress.cursor < progress.until, !Task.isCancelled {
            let from = progress.cursor
            let to = min(from + windowSeconds, progress.until)
            guard let streams = await readWindow(store: store, deviceId: deviceId, from: from, to: to - 1) else {
                break
            }
            if rowCount(streams) > 0 {
                let taken = await CloudCapture.recordHistory(streams, deviceId: uploadId, family: family,
                                                            clockRef: nil)
                guard taken > 0 else { break }
                committed += taken
            }
            progress.cursor = to
            if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: key) }
        }
        return committed
    }

    /// Every stream the offload banks, for one inclusive window. Nil when the heart-rate read itself
    /// fails, so an unreadable window is retried instead of being recorded as empty.
    static func readWindow(store: WhoopStore, deviceId: String, from: Int, to: Int) async -> Streams? {
        let limit = 200_000
        guard let hr = try? await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit) else {
            return nil
        }
        var streams = Streams()
        streams.hr = hr
        streams.rr = (try? await store.rrIntervals(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        streams.events = (try? await store.events(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        streams.battery = (try? await store.batterySamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        streams.spo2 = (try? await store.spo2Samples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        streams.skinTemp = (try? await store.skinTempSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        streams.resp = (try? await store.respSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        streams.gravity = (try? await store.gravitySamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        streams.steps = (try? await store.stepSamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
        streams.sleepState = (try? await store.sleepStateSamples(deviceId: deviceId, from: from, to: to,
                                                                 limit: limit)) ?? []
        return streams
    }

    static func rowCount(_ s: Streams) -> Int {
        s.hr.count + s.rr.count + s.events.count + s.battery.count + s.spo2.count + s.skinTemp.count
            + s.resp.count + s.gravity.count + s.steps.count + s.sleepState.count
    }
}

/// One-time cloud upload of the SpO₂ strap estimates this install banked before they were journaled.
///
/// Earlier builds kept the strap's `@82` byte only in the local store, so the server never saw a reading.
/// This replays the recent nights' in-band readings (a few hundred per night) through the same encoding the
/// offload now uses, and keeps its cursor per owner and device so an interrupted pass resumes. Re-sending a
/// reading is harmless: the receiver keys event rows by `(ts, kind)`.
public enum CloudSpo2Seeder {
    static let lookbackSeconds = 14 * 86_400
    static let windowSeconds = 6 * 3600

    /// Keyed by where the rows are read from AND the device they are sent as: the provisional namespace and
    /// the strap's own both replay into the strap's cloud device, and each needs its own cursor.
    static func defaultsKey(ownerId: String, sourceDeviceId: String, uploadDeviceId: String) -> String {
        "noop.cloud.spo2Seed.v1.\(ownerId.lowercased()).\(sourceDeviceId.lowercased()).\(uploadDeviceId.lowercased())"
    }

    /// Returns the number of records the journal committed on this pass; 0 once the span is done. A window
    /// whose rows the journal did not take is retried on the next call rather than skipped.
    ///
    /// `deviceId` is the local namespace the readings are stored under. `cloudDeviceId` replays them as
    /// another device's uploads, as `CloudHistorySeeder` does for the rows banked before a strap adopted its
    /// serial id.
    @discardableResult
    public static func runIfNeeded(store: WhoopStore,
                                   deviceId: String,
                                   cloudDeviceId: String? = nil,
                                   family: DeviceFamily?,
                                   defaults: UserDefaults = .standard,
                                   now: Int = Int(Date().timeIntervalSince1970)) async -> Int {
        guard CloudPushRuntime.sharedIfRunning != nil,
              let ownerId = CloudPushIdentityStore.current()?.ownerId else { return 0 }
        let uploadId = cloudDeviceId ?? deviceId
        let key = defaultsKey(ownerId: ownerId, sourceDeviceId: deviceId, uploadDeviceId: uploadId)
        var progress = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(CloudHistorySeeder.Progress.self, from: $0) }
            ?? CloudHistorySeeder.Progress(cursor: now - lookbackSeconds, until: now)
        var committed = 0
        while progress.cursor < progress.until, !Task.isCancelled {
            let from = progress.cursor
            let to = min(from + windowSeconds, progress.until)
            guard let aux = try? await store.v18AuxSamples(deviceId: deviceId, from: from, to: to - 1,
                                                          limit: 200_000) else { break }
            var streams = Streams()
            streams.v18Aux = aux.filter { sample in
                sample.auxByte82.map { Spo2StrapEstimate.band.contains($0) } ?? false
            }
            if !streams.v18Aux.isEmpty {
                let taken = await CloudCapture.recordHistory(streams, deviceId: uploadId, family: family,
                                                            clockRef: nil)
                guard taken > 0 else { break }
                committed += taken
            }
            progress.cursor = to
            if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: key) }
        }
        return committed
    }
}
