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
        guard let runtime = CloudPushRuntime.sharedIfRunning else { return .notRunning }
        guard let ref = clockRef else {
            runtime.noteSkippedPreClock(1)
            return .preClock
        }
        let streams = extractStreams([frame], deviceClockRef: ref.device, wallClockRef: ref.wall,
                                     family: family)
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
        guard let runtime = CloudPushRuntime.sharedIfRunning else { return .notRunning }
        let acceptedHR = (30...220).contains(hr)
        let acceptedRR = rr.filter { (250...3000).contains($0) }
        let source: RRSourceChannel? = family == .whoop5 ? .whoop5Standard
            : (family == .whoop4 ? .whoop4Standard : nil)
        var streams = StandardHRMapping.samples(fromHR: hr, rr: acceptedRR, contact: contact, at: ts)
        if !acceptedHR { streams.hr = [] }
        streams.rr = acceptedRR.map { RRInterval(ts: ts, rrMs: $0, srcChannel: source) }
        let records = rows(from: streams, provenance: .live, family: family,
                           wallClockRef: nil, deviceClockRef: nil,
                           receivedAtMs: receivedAtMs, characteristic: characteristic,
                           deviceId: deviceId)
        guard !records.isEmpty else { return .nothingToRecord }
        runtime.submit(records)
        return nil
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
        for step in streams.steps {
            let data: [String: PushJSONValue] = [
                "counter": .int(Int64(step.counter)),
                "activityClass": step.activityClass.map { .int(Int64($0)) } ?? .null,
            ]
            if let record = make(.stepSample, ["ts": .int(Int64(step.ts))], data, strapTs: step.ts) {
                out.append(record)
            }
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
        policy.activeTargetSeconds = 2
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
        lock.lock()
        _journal = journal
        _coordinator = coordinator
        _session = session
        _deviceId = deviceId.lowercased()
        lock.unlock()
        Task {
            do {
                try await journal.activate(configuration: configuration, policy: policy)
            } catch {
                // A protected-data failure (locked phone before the first unlock) is not fatal: staged
                // records stay staged and are committed on the next activation attempt.
                CloudJournal.disableStaging()
            }
            await coordinator.start()
        }
    }

    /// Scene phase, pushed by the app layer. Determines whether an eligible batch is sent on the
    /// prompt (foreground) lane or handed to the background session.
    public func setAppIsActive(_ active: Bool) {
        lock.lock(); appIsActive = active; lock.unlock()
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
        lock.unlock()
        await coordinator?.stop()
        await CloudJournal.shared.deactivate()
    }

    // MARK: - capture path (non-blocking)

    public func submit(_ records: [CloudJournalRecord]) {
        guard let journal = journalIfRunning else { return }
        journal.submit(records)
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
