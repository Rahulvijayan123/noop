import Foundation
import NoopPush

/// One account-scoped coordinator for sealing, uploading and receipt reconciliation.
///
/// It is created for exactly one `(owner, source)` scope and never serves another: it only reads the
/// journal through that scope, only sends with a credential that belongs to that scope, and refuses to
/// run at all if the credential it is given belongs to someone else. Signing in as a different account
/// creates a new coordinator; it does not re-aim this one.
///
/// The loop is deliberately small and durable:
///
///   seal a bounded batch of journaled records into an immutable file
///     → register the file as a durable job (membership + job in one transaction)
///     → upload it on the prompt lane while the app runs, or on the background lane when it does not
///     → apply the receiver's checksum-matching receipt
///     → delete the file ONLY then, and only when no task still references it
///
/// Everything the loop needs to resume lives in the journal, so a crash between any two steps costs
/// work, never data. A batch that was sealed but never acknowledged keeps its records and its file,
/// and is re-sent on the next pass (the receiver is idempotent for an identical batch id).
public actor CloudTransportCoordinator {

    /// Where an eligible batch is sent.
    public enum UploadLane: Sendable, Equatable {
        /// An ordinary request issued by this process and awaited here. It starts at once and does not
        /// depend on the scene being on screen: BLE keeps the process running, so this is the lane that
        /// keeps the server current while the phone is locked or the app is in the background.
        case process
        /// A file task owned by the OS background session. The system decides when it runs, and for a
        /// transfer created while the app is backgrounded that has meant hours of silence.
        case background
    }

    public struct Policy: Sendable {
        /// At most this many in-process uploads in flight. Two is the spec's measured starting point.
        public var maxInFlight: Int = 2
        /// At most this many OS-session uploads in flight. Counted apart from `maxInFlight`: a task the
        /// OS defers must not use up the slots that live data needs.
        public var maxBackgroundInFlight: Int = 2
        /// Hand batches to the OS background session while the scene is not active. Off by default: the
        /// background session defers a transfer created while backgrounded, which is how a phone that
        /// stayed connected to the strap all night uploaded nothing from 01:00 until it was unlocked.
        public var useBackgroundLaneWhenInactive: Bool = false
        /// At most this many of the in-flight uploads may be backlog; the rest stay free for fresh
        /// data. A strap-history backlog sent at full concurrency overloaded the receiver's database.
        public var maxBacklogInFlight: Int = 1
        /// A batch older than this is "backlog" rather than "fresh"; one of each is admitted per pass
        /// so a long backlog can never starve newly captured data (and vice versa).
        public var freshWindowSeconds: Int = 30
        public var retryBaseSeconds: Double = 5
        public var retryCapSeconds: Double = 3600
        public var maxAttempts: Int = 12
        /// Bounded per pass, so one pass cannot turn into an unbounded drain.
        public var maxSealsPerPass: Int = 4
        /// Stop sealing new files while this many are already waiting to be sent. Sealing every couple
        /// of seconds makes tiny files; when the receiver is slower than that, the records are better
        /// left in the journal, where they merge into fewer, larger files and nothing is lost.
        public var sealBackpressureBatches: Int = 8
        public var sealMaxRecords: Int = 2_000
        public var sealMaxBytes: Int = 1 << 20
        public var acceptedRetentionSeconds: Int = 7 * 24 * 3600
        public init() {}
    }

    public enum CoordinatorError: Error, CustomStringConvertible {
        case notConfigured
        case sealFailed(String)
        case unsupportedStream(CloudStreamKind)
        /// The receiver, the credential or a batch named a different account than this coordinator serves.
        case ownershipMismatch(String)

        public var description: String {
            switch self {
            case .notConfigured: return "cloud: coordinator not configured"
            case .sealFailed(let why): return "cloud: seal failed: \(why)"
            case .unsupportedStream(let s): return "cloud: \(s.rawValue) is not an append stream"
            case .ownershipMismatch(let why): return "cloud: ownership mismatch: \(why)"
            }
        }
    }

    private let journal: CloudJournal
    private let session: any CloudUploading
    private let scope: CloudDataScope
    private let payloadDirectory: URL
    private let identity: @Sendable () -> CloudPushIdentity?
    private let projectURL: String
    private let policy: Policy
    private let now: @Sendable () -> Int
    /// Whether the master cloud switch is on. Injected so tests can drive it deterministically;
    /// production defaults to `CloudPushSettings.isEnabled` (the D1 gate that stops the upload
    /// cycle the moment the user disables cloud, before the runtime teardown lands).
    private let cloudEnabled: @Sendable () -> Bool
    private let random: @Sendable () -> Double

    /// In-process uploads in flight. The OS-session lane has its own counter (`backgroundInFlight`).
    private var inFlight = 0
    private var backgroundInFlight = 0
    /// In-process uploads in flight, keyed by batch id; the value says whether the batch is backlog.
    /// This lane does not reserve its batch in the journal, so this is what stops a later pass
    /// from sending the same batch again while the first upload is still waiting on the receiver.
    private var promptLaneBatches: [String: Bool] = [:]
    private var cycleScheduled = false
    private var active = false
    private var negotiatedProtocolVersion: String?
    private var lastError: String? {
        didSet {
            guard let lastError, lastError != oldValue else { return }
            let stamp = "\(now() * 1000) \(lastError)"
            Task { await journal.recordTransportDiagnostic("lastError", stamp) }
        }
    }
    private var lastOutcomeAtMs: Int?
    private var lastHeartbeatAtSeconds = 0
    private var credentialRejectedAtSeconds = 0

    /// Called when the receiver refuses this installation's credential (HTTP 401/403). The batch is kept
    /// and retried; the owner of the callback decides whether to rotate the credential or end the session.
    /// Throttled to one call per 30 s so a burst of rejected uploads asks once.
    public var onCredentialRejected: (@Sendable (_ status: Int) -> Void)?

    public func setOnCredentialRejected(_ handler: (@Sendable (_ status: Int) -> Void)?) {
        onCredentialRejected = handler
    }

    public init(journal: CloudJournal, session: any CloudUploading, scope: CloudDataScope,
                payloadDirectory: URL,
                projectURL: String, identity: @escaping @Sendable () -> CloudPushIdentity?,
                policy: Policy = Policy(),
                now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                cloudEnabled: @escaping @Sendable () -> Bool = { CloudPushSettings.isEnabled }) {
        self.journal = journal
        self.session = session
        self.scope = scope
        self.payloadDirectory = payloadDirectory
        self.projectURL = projectURL
        self.identity = identity
        self.policy = policy
        self.now = now
        self.random = random
        self.cloudEnabled = cloudEnabled
    }

    // MARK: - lifecycle

    public func start() async {
        active = true
        try? FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        await protectPayloadDirectory()
        session.onOutcome = { [weak self] outcome in
            guard let self else { return }
            Task { await self.handleBackgroundOutcome(outcome) }
        }
        try? await reconcileTasksAtLaunch()
        try? await cleanUpAcknowledgedFiles()
        try? await resealBlockedBatches()
        // A launch is a fresh attempt: a batch that failed while the receiver was down must not sit
        // out a backoff that grew toward the hour cap, holding the seal backpressure closed meanwhile.
        try? await journal.rescheduleFailed(dueAtMs: now() * 1000)
        kick()
    }

    /// One-shot at start: return blocked batches' records to the pending pool
    /// so the builder re-seals them with current rules. A blocked batch was a
    /// non-retryable rejection; when the defect was builder-side (e.g. the
    /// duplicate conflict-key bug), the records are still unacknowledged and
    /// must not stay stranded. Bounded to one pass at startup so a recurring
    /// rejection does not churn: a batch that blocks again stays blocked.
    private func resealBlockedBatches() async {
        do {
            let blocked = try await journal.sealedBatches(states: [.blocked], dueBeforeMs: nil, limit: 64)
            for batch in blocked {
                try await journal.resealBlocked(batchId: batch.batchId)
            }
        } catch {
            lastError = "reseal blocked: \(error)"
        }
    }

    public func stop() async {
        active = false
        session.onOutcome = nil
    }

    /// Kick a pass. Coalesced: many capture-driven kicks collapse into one pass.
    public nonisolated func kick() {
        Task { await self.scheduleCycle() }
    }

    private func scheduleCycle() async {
        guard active, !cycleScheduled else { return }
        cycleScheduled = true
        defer { cycleScheduled = false }
        await cycle()
    }

    // MARK: - the pass

    /// One bounded pass: reconcile, seal what is ready, then fill the in-flight budget.
    public func cycle() async {
        guard active else { return }
        // D1: the master switch stops the upload cycle. This is checked on every pass, so there is
        // no window between the user disabling cloud and the runtime teardown landing — a pass that
        // starts after the flip sends nothing, seals nothing and reserves nothing. The journal and
        // its pending/sealed work are untouched and resume on re-enable.
        guard cloudEnabled() else { return }
        guard let identity = identity() else {
            lastError = "no installation identity"
            return
        }
        guard identity.scope == scope else {
            // Fail closed: nothing is sealed or sent with a credential that is not this account's.
            lastError = "installation credential belongs to a different account"
            return
        }
        var stage = "negotiate"
        do {
            try await adoptNegotiatedVersionIfNeeded(identity: identity)
            stage = "reconcile"
            try await reconcileTasksAtLaunch()
            stage = "seal"
            try await sealReady(identity: identity)
            stage = "send"
            try await sendEligible(identity: identity)
            stage = "done"
        } catch {
            lastError = "cycle failed at \(stage): \(error)"
        }
        recordHeartbeat(stage: stage)
    }

    /// At most one diagnostic write per 30 s: proves the loop is alive and where its last pass ended.
    private func recordHeartbeat(stage: String) {
        let seconds = now()
        guard seconds - lastHeartbeatAtSeconds >= 30 else { return }
        lastHeartbeatAtSeconds = seconds
        let summary = "\(seconds * 1000) stage=\(stage) inFlight=\(inFlight) bgInFlight=\(backgroundInFlight)"
            + " sceneActive=\(CloudTransportCoordinator.applicationIsActive())"
            + " protocol=\(negotiatedProtocolVersion ?? "nil")"
        Task { await journal.recordTransportDiagnostic("lastCycle", summary) }
    }

    // MARK: - sealing

    /// Seal each ready group into an immutable file and register it as a durable job.
    ///
    /// A group becomes ready on AGE (the ~2 s active-use target) or on size. The file is written to a
    /// temporary name in the same directory and then renamed, so a reader can never observe a partial
    /// payload, and a re-seal after a crash lands on the same name because the batch id is derived
    /// from the batch's identity and lines.
    private func sealReady(identity: CloudPushIdentity) async throws {
        let unsent = try await journal.batches(states: [.sealed, .failed], dueBeforeMs: nil,
                                               limit: policy.sealBackpressureBatches)
        guard unsent.count < policy.sealBackpressureBatches else { return }
        let candidates = try await journal.sealCandidates(limit: policy.maxSealsPerPass)
        for candidate in candidates {
            guard CloudBatchBuilder.appendTable(for: candidate.stream) != nil else {
                // Replace-window / archive streams are not authored by the phone in cloud mode.
                continue
            }
            let entries = try await journal.entries(for: candidate, limit: policy.sealMaxRecords)
            guard !entries.isEmpty else { continue }
            let protocolVersion = try negotiatedVersion(for: candidate.stream)
            let startCursorJSON = await journal.appendCursorJSON(deviceId: candidate.deviceId,
                                                                stream: candidate.stream)
            let plan: CloudBatchBuilder.Plan
            do {
                plan = try CloudBatchBuilder.plan(entries: entries, stream: candidate.stream,
                                                  sourceId: candidate.sourceId, deviceId: candidate.deviceId,
                                                  protocolVersion: protocolVersion,
                                                  startCursorJSON: startCursorJSON)
            } catch {
                lastError = String(describing: error)
                continue
            }
            let covered = plan.entries
            guard !covered.isEmpty else { continue }
            let wire: Data
            do {
                // The receiver accepts an optional gzip body and the decoded limit is 4 MiB; gzip
                // keeps the wire small. The sealed file IS the wire body, so what we hash, send and
                // later delete are the same bytes.
                wire = try PushBinaryCompression.gzip(plan.batch.body)
            } catch {
                lastError = "gzip: \(error)"
                continue
            }
            // The receipt binds the DECODED digest, so that is what the journal stores as the content
            // hash; the file length is the wire length.
            let contentSha256 = PushDurabilityReceipt.sha256(plan.batch.body)
            let fileURL = payloadDirectory.appendingPathComponent("\(plan.batch.batchId).ndjson.gz")
            do {
                try writeImmutable(wire, to: fileURL)
            } catch {
                lastError = "seal write: \(error)"
                continue
            }
            let narrowed = CloudSealCandidate(ownerId: candidate.ownerId, sourceId: candidate.sourceId,
                                              deviceId: candidate.deviceId, stream: candidate.stream,
                                              firstSeq: covered.first!.seq, lastSeq: covered.last!.seq,
                                              recordCount: covered.count,
                                              oldestReceivedAtMs: candidate.oldestReceivedAtMs,
                                              byteSize: wire.count,
                                              windowIdentity: candidate.windowIdentity)
            try await journal.registerSeal(narrowed, batchId: plan.batch.batchId, filePath: fileURL.path,
                                           contentSha256: contentSha256, contentLength: wire.count,
                                           protocolVersion: plan.protocolVersion,
                                           endCursorJSON: plan.endCursorJSON)
        }
    }

    private func writeImmutable(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            // The same batch id means the same bytes; keep the existing file.
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        try FileManager.default.moveItem(at: temporary, to: url)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    // MARK: - sending

    /// The lane for a batch, given whether the scene is on screen.
    ///
    /// The scene phase says nothing about whether this process is running, and a request made by a
    /// running process is the only thing that reliably reaches the server promptly. So an inactive scene
    /// stays on the in-process lane unless the policy explicitly asks for the OS background session.
    static func lane(sceneIsActive: Bool, policy: Policy) -> UploadLane {
        sceneIsActive || !policy.useBackgroundLaneWhenInactive ? .process : .background
    }

    /// Whether `lane` still has a free slot. Each lane is budgeted on its own, so transfers the OS has
    /// deferred never block the in-process lane.
    static func hasRoom(lane: UploadLane, inFlight: Int, backgroundInFlight: Int, policy: Policy) -> Bool {
        switch lane {
        case .process: return inFlight < policy.maxInFlight
        case .background: return backgroundInFlight < policy.maxBackgroundInFlight
        }
    }

    /// Fill the in-flight budget with eligible batches, one backlog item and one fresh item per pass.
    private func sendEligible(identity: CloudPushIdentity) async throws {
        let lane = CloudTransportCoordinator.lane(sceneIsActive: CloudTransportCoordinator.applicationIsActive(),
                                                  policy: policy)
        guard CloudTransportCoordinator.hasRoom(lane: lane, inFlight: inFlight,
                                                backgroundInFlight: backgroundInFlight, policy: policy) else { return }
        let nowMs = now() * 1000
        let notInFlight: (CloudSealedBatch) -> Bool = { [promptLaneBatches] in promptLaneBatches[$0.batchId] == nil }
        let due = try await journal.batches(states: [.sealed, .failed], dueBeforeMs: nowMs,
                                            limit: max(policy.maxInFlight * 4, 8)).filter(notInFlight)
        guard !due.isEmpty else { return }
        // The oldest rows alone would never include a fresh batch while a backlog is longer than the
        // page, so the newest rows are read separately: a long backlog cannot starve live data.
        let newest = try await journal.batches(states: [.sealed, .failed], dueBeforeMs: nowMs,
                                               limit: policy.maxInFlight + promptLaneBatches.count,
                                               newestFirst: true).filter(notInFlight)
        let freshCutoff = nowMs - policy.freshWindowSeconds * 1000
        let backlog = due.filter { $0.createdAtMs < freshCutoff }
        let fresh = newest.filter { $0.createdAtMs >= freshCutoff }
        let backlogHasRoom = promptLaneBatches.values.filter { $0 }.count < policy.maxBacklogInFlight
        var queue: [CloudSealedBatch] = []
        if backlogHasRoom, let oldestBacklog = backlog.first { queue.append(oldestBacklog) }
        if let newestFresh = fresh.first, !queue.contains(where: { $0.batchId == newestFresh.batchId }) {
            queue.append(newestFresh)
        }
        if queue.isEmpty, backlogHasRoom { queue = Array(due.prefix(1)) }

        for batch in queue {
            guard CloudTransportCoordinator.hasRoom(lane: lane, inFlight: inFlight,
                                                    backgroundInFlight: backgroundInFlight, policy: policy) else { break }
            guard let fileURL = payloadFileURL(for: batch) else {
                // The file is gone but the records are not acknowledged: re-seal instead of dropping.
                try await releaseForReseal(batch)
                continue
            }
            switch lane {
            case .process:
                inFlight += 1
                promptLaneBatches[batch.batchId] = batch.createdAtMs < freshCutoff
                let sceneIsActive = CloudTransportCoordinator.applicationIsActive()
                Task { await self.uploadInProcess(batch, fileURL: fileURL, holdExecution: !sceneIsActive) }
            case .background:
                backgroundInFlight += 1
                let taskId: Int
                do {
                    taskId = try session.enqueueBackground(batchId: batch.batchId, fileURL: fileURL, scope: scope)
                } catch {
                    backgroundInFlight = max(0, backgroundInFlight - 1)
                    throw error
                }
                try await journal.markReserved(batchId: batch.batchId, taskId: String(taskId),
                                               taskKind: "background", authExpiresAtMs: nil)
            }
        }
    }

    /// Process lane: this process is executing, so send now and apply the receipt as soon as it lands.
    ///
    /// When the scene is not on screen the app is running on borrowed time (a BLE wake), so the upload
    /// holds an execution assertion until the receipt is applied. Once the slot is free the loop looks for
    /// more work straight away, so a backlog drains without waiting for the next capture to kick it.
    private func uploadInProcess(_ batch: CloudSealedBatch, fileURL: URL, holdExecution: Bool) async {
        let release: (@Sendable () -> Void)? = holdExecution
            ? await CloudTransportCoordinator.executionAssertion("cloud-upload")
            : nil
        var succeeded = false
        do {
            let outcome = try await session.uploadForeground(batchId: batch.batchId, fileURL: fileURL, scope: scope)
            succeeded = await handle(outcome: outcome)
        } catch let error as CloudUploadSession.UploadError {
            switch error {
            case .missingIdentity, .wrongAccount:
                await handleCredentialRejection(batch: batch, status: 0, detail: String(describing: error))
            default:
                await handleFailure(batch: batch, error: String(describing: error))
            }
        } catch {
            await handleFailure(batch: batch, error: String(describing: error))
        }
        inFlight = max(0, inFlight - 1)
        promptLaneBatches[batch.batchId] = nil
        release?()
        if succeeded { kick() }
    }

    // MARK: - outcomes

    /// The background lane's only completion path, so it releases that lane's in-flight slot here; the
    /// process lane releases its own slot when its upload returns.
    private func handleBackgroundOutcome(_ outcome: CloudUploadSession.Outcome) async {
        backgroundInFlight = max(0, backgroundInFlight - 1)
        let applied = await handle(outcome: outcome)
        if applied { kick() }
    }

    /// Apply a transfer outcome. A 200 body is the receiver's acknowledgement; anything else is a
    /// failure with its own retry treatment. Returns whether the batch was acknowledged.
    @discardableResult
    private func handle(outcome: CloudUploadSession.Outcome) async -> Bool {
        guard active else { return false }
        lastOutcomeAtMs = now() * 1000
        guard let batch = try? await journal.batches(states: [.sealed, .reserved, .uploaded, .failed],
                                                    dueBeforeMs: nil, limit: 256)
            .first(where: { $0.batchId == outcome.batchId }) else { return false }

        if outcome.isTransportFailure {
            await handleFailure(batch: batch, error: outcome.errorDescription ?? "transport")
            return false
        }
        if outcome.statusCode == 401 || outcome.statusCode == 403 {
            await handleCredentialRejection(batch: batch, status: outcome.statusCode, detail: "HTTP \(outcome.statusCode)")
            return false
        }
        guard outcome.statusCode == 200, let body = outcome.body else {
            await handleFailure(batch: batch, error: "HTTP \(outcome.statusCode)")
            return false
        }
        do {
            try await journal.markUploaded(batchId: batch.batchId)
            let acknowledged = try await applyReceipt(batch: batch, body: body)
            if !acknowledged {
                // A 200 whose acknowledgement does not match this batch is not delivery. `uploaded` is not a
                // state the send pass looks at again, so leaving the batch there would hold its records back
                // for good. The receiver deduplicates by batch id, so sending it again is safe.
                await handleFailure(batch: batch, error: lastError ?? "receipt not confirmed", forceRetry: true)
            }
            return acknowledged
        } catch {
            await handleFailure(batch: batch, error: String(describing: error))
            return false
        }
    }

    /// Validate and apply the receiver's acknowledgement.
    ///
    /// Three independent things must line up before a single record is released: the ack must name
    /// this exact batch (id, stream, device, end cursor, record count), the durability receipt must be
    /// a well-formed `verified_indexed` receipt for this owner, and its content digest must be the
    /// digest of the decoded body we sealed. Only then are the batch's records marked acknowledged.
    @discardableResult
    private func applyReceipt(batch: CloudSealedBatch, body: Data) async throws -> Bool {
        let ack = try PushAck.parse(body)
        guard ack.status == "accepted" else {
            lastError = "receiver status \(ack.status)"
            return false
        }
        let rebuilt = try await rebuildBatch(batch)
        if let rebuilt {
            guard ack.exactlyMatches(rebuilt.batch) else {
                lastError = "ack does not match the sealed batch \(batch.batchId)"
                return false
            }
        }
        guard let receipt = ack.durabilityReceipt else {
            // A transport-level "accepted" without a durability receipt is not proof of durable
            // intake; keep the file and try again rather than treating it as done.
            lastError = "no durability receipt for \(batch.batchId)"
            return false
        }
        if let rebuilt, let accountScope = try? AccountScope(projectURL: projectURL, userID: batch.ownerId) {
            guard receipt.matches(rebuilt.batch, owner: accountScope) else {
                lastError = "durability receipt does not match \(batch.batchId)"
                return false
            }
        }
        let outcome = try await journal.applyReceipt(batchId: batch.batchId,
                                                    contentSha256: receipt.contentSha256,
                                                    receiptJSON: String(data: body, encoding: .utf8) ?? "")
        switch outcome {
        case .acknowledged:
            // The cursor advances only now — after durable, checksum-matched acceptance.
            if let rebuilt, let endCursor = rebuilt.batch.endCursor,
               let data = try? JSONEncoder().encode(endCursor),
               let json = String(data: data, encoding: .utf8) {
                try await journal.saveAppendCursor(deviceId: rebuilt.deviceId, stream: rebuilt.stream,
                                                   endCursorJSON: json)
            }
            try await deleteFileIfUnreferenced(batch)
            return true
        case .duplicate:
            try await deleteFileIfUnreferenced(batch)
            return true
        case .checksumMismatch(let expected, let received):
            lastError = "receipt checksum mismatch for \(batch.batchId): \(expected) != \(received)"
        case .unknownBatch:
            lastError = "receipt for unknown batch \(batch.batchId)"
        case .malformed:
            lastError = "malformed receipt for \(batch.batchId)"
        }
        return false
    }

    /// Rebuild the wire batch from its durable membership.
    ///
    /// This is what makes reconciliation survive a relaunch: the in-memory batch is gone, but the
    /// entries are still in the journal, and the builder is deterministic, so the same batch (and the
    /// same batch id) can be reconstructed and used to validate the receipt.
    private func rebuildBatch(_ batch: CloudSealedBatch) async throws -> (batch: PushBatch, ownerId: String, deviceId: String, stream: CloudStreamKind)? {
        guard let identity = identity() else { return nil }
        // A receipt is only ever applied to a batch of the account this coordinator serves, and only
        // on the strength of that account's own credential.
        guard batch.scope == scope, identity.scope == scope else {
            throw CoordinatorError.ownershipMismatch("batch \(batch.batchId) is not this account's")
        }
        let candidate = CloudSealCandidate(ownerId: batch.ownerId, sourceId: batch.sourceId,
                                          deviceId: batch.deviceId, stream: batch.stream,
                                          firstSeq: batch.firstSeq, lastSeq: batch.lastSeq,
                                          recordCount: batch.recordCount, oldestReceivedAtMs: 0,
                                          byteSize: batch.contentLength,
                                          windowIdentity: batch.windowIdentity)
        let entries = try await journal.entries(for: candidate)
        guard !entries.isEmpty else { return nil }
        let plan = try CloudBatchBuilder.plan(entries: entries, stream: batch.stream,
                                              sourceId: batch.sourceId, deviceId: batch.deviceId,
                                              protocolVersion: negotiatedProtocolVersion ?? PushProtocol.version,
                                              startCursorJSON: nil)
        guard plan.batch.batchId == batch.batchId else {
            // A rebuilt batch with a different id means the membership changed under us; refuse to
            // release anything on the strength of a receipt for a different batch.
            lastError = "rebuilt batch id mismatch for \(batch.batchId)"
            return nil
        }
        return (plan.batch, batch.ownerId, batch.deviceId, batch.stream)
    }

    // MARK: - failure handling

    /// The receiver refused this installation's credential, or there is none to send with.
    ///
    /// That says nothing about the batch, so it is never blocked and never counts toward the attempt cap:
    /// the records stay exactly where they are and the batch is retried after a short wait, by which time
    /// the account layer will have rotated the credential or ended the session. Without a credential the
    /// loop idles instead of burning attempts.
    private func handleCredentialRejection(batch: CloudSealedBatch, status: Int, detail: String) async {
        let dueAtMs = now() * 1000 + Int(CloudTransportCoordinator.credentialRetrySeconds * 1000)
        try? await journal.markFailed(batchId: batch.batchId, error: "credential rejected: \(detail)",
                                      nextAttemptAtMs: dueAtMs, countAttempt: false)
        lastError = "credential rejected: \(detail)"
        noteCredentialRejected(status: status)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CloudTransportCoordinator.credentialRetrySeconds * 1_000_000_000) + 250_000_000)
            self?.kick()
        }
    }

    /// How long a batch waits after the receiver refused the credential before it is offered again.
    static let credentialRetrySeconds: Double = 30

    private func noteCredentialRejected(status: Int) {
        let seconds = now()
        guard seconds - credentialRejectedAtSeconds >= 30 else { return }
        credentialRejectedAtSeconds = seconds
        onCredentialRejected?(status)
    }

    private func handleFailure(batch: CloudSealedBatch, error: String, forceRetry: Bool = false) async {
        if !forceRetry, !CloudTransportCoordinator.isRetryable(error: error) {
            // A rejected batch will not become acceptable by waiting. The bytes and their records are
            // kept (an unacknowledged input is never pruned) but the batch stops consuming retries and
            // the condition is surfaced.
            try? await journal.markFailed(batchId: batch.batchId, error: error, nextAttemptAtMs: nil,
                                          blocked: true)
            lastError = "blocked: \(error)"
            return
        }
        if batch.attempts >= policy.maxAttempts {
            try? await journal.markFailed(batchId: batch.batchId,
                                          error: "attempt cap reached: \(error)", nextAttemptAtMs: nil,
                                          blocked: true)
            lastError = "attempt cap reached: \(error)"
            return
        }
        let backoff = CloudTransportCoordinator.backoffSeconds(attempt: batch.attempts + 1,
                                                              base: policy.retryBaseSeconds,
                                                              cap: policy.retryCapSeconds, jitter: random())
        let dueAtMs = now() * 1000 + Int(backoff * 1000)
        try? await journal.markFailed(batchId: batch.batchId, error: error, nextAttemptAtMs: dueAtMs)
        lastError = error
        // Nothing else wakes the loop when a backoff expires on a quiet link, so the retry schedules itself.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000) + 250_000_000)
            self?.kick()
        }
    }

    /// Bounded exponential backoff with full jitter: `min(cap, base · 2^min(attempt,10))`, spread over
    /// the whole interval. Full jitter (rather than a fixed fraction) is what keeps a fleet of phones
    /// that lost connectivity together from retrying in lockstep when the receiver comes back.
    static func backoffSeconds(attempt: Int, base: Double, cap: Double, jitter: Double) -> Double {
        let exponential = min(cap, base * pow(2, Double(min(max(0, attempt), 10))))
        return max(0.5, exponential * min(max(jitter, 0), 1))
    }

    /// Retryable failures are transport-level or the receiver asking us to come back; a rejected batch
    /// (malformed, unsupported, too large) will not become acceptable by waiting.
    static func isRetryable(error: String) -> Bool {
        let lowered = error.lowercased()
        for code in ["http 408", "http 425", "http 429", "http 500", "http 502", "http 503", "http 504"] {
            if lowered.contains(code) { return true }
        }
        if lowered.contains("transport") || lowered.contains("timed out") || lowered.contains("network")
            || lowered.contains("offline") || lowered.contains("connection") { return true }
        return false
    }

    // MARK: - launch reconciliation

    /// Reconcile durable jobs with the tasks the OS still holds.
    ///
    /// A job left `reserved` whose task is not among the session's outstanding tasks lost its task
    /// (process death, eviction, or a completion whose delegate never ran). It goes back to the
    /// eligible state so the next pass re-sends it — the receiver deduplicates by batch id, so a
    /// re-send after a lost response is harmless.
    private func reconcileTasksAtLaunch() async throws {
        // Only a reserved batch can lose its task, and asking the OS session for its tasks is a round trip to
        // the transfer daemon. Every pass reconciles, and a pass runs after each journal commit (about once a
        // second while the strap streams), so the round trip is skipped when nothing is reserved, which is
        // every pass unless the background lane is in use.
        let reserved = try await journal.batches(states: [.reserved], dueBeforeMs: nil, limit: 256)
        guard !reserved.isEmpty else { return }
        let outstanding = await session.outstandingTasks()
        let liveBatchIds = Set(outstanding.compactMap { $0.batchId })
        for batch in reserved {
            if liveBatchIds.contains(batch.batchId) { continue }
            try await journal.markFailed(batchId: batch.batchId,
                                         error: "task no longer present; re-sending", nextAttemptAtMs: now() * 1000)
        }
    }

    /// Delete payload files for batches that were already acknowledged but whose file survived a
    /// crash between "mark acknowledged" and "unlink" — the cleanup marker the deployed runtime also
    /// recovers at launch.
    private func cleanUpAcknowledgedFiles() async throws {
        let acked = try await journal.batches(states: [.acked], dueBeforeMs: nil, limit: 64)
        for batch in acked {
            if let url = payloadFileURL(for: batch) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// A sealed batch whose file vanished before acknowledgement: release it so its records are
    /// re-sealed on the next pass. The records themselves were never released, so nothing is lost.
    private func releaseForReseal(_ batch: CloudSealedBatch) async throws {
        try await journal.resealMissingPayload(batchId: batch.batchId)
    }

    /// Where a sealed batch's payload lives NOW.
    ///
    /// The journal stores the absolute path the file had when it was sealed, but the app's data
    /// container path changes across reinstalls and restores, so a stored path goes stale while the
    /// file itself survives. Payload files are always named `<batchId>.ndjson.gz` inside the current
    /// payload directory, so that location is authoritative and the stored path is only a fallback.
    private func payloadFileURL(for batch: CloudSealedBatch) -> URL? {
        let current = payloadDirectory.appendingPathComponent("\(batch.batchId).ndjson.gz")
        if FileManager.default.fileExists(atPath: current.path) { return current }
        let stored = URL(fileURLWithPath: batch.filePath)
        return FileManager.default.fileExists(atPath: stored.path) ? stored : nil
    }

    // MARK: - deletion

    /// Delete a payload file only after an acknowledged, checksum-matched receipt AND when no live
    /// task references it. Out-of-order acknowledgements therefore leave earlier batches (and their
    /// files) untouched: each batch is released on its own receipt, never by a global cursor.
    private func deleteFileIfUnreferenced(_ batch: CloudSealedBatch) async throws {
        guard (try await journal.batchState(batch.batchId)) == .acked else { return }
        let outstanding = await session.outstandingTasks()
        if outstanding.contains(where: { $0.batchId == batch.batchId }) { return }
        if let url = payloadFileURL(for: batch) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - negotiation

    private func adoptNegotiatedVersionIfNeeded(identity: CloudPushIdentity) async throws {
        guard negotiatedProtocolVersion == nil else { return }
        let stored = CloudTransportCoordinator.storedProtocolVersion(ownerId: identity.ownerId)
        if let stored { negotiatedProtocolVersion = stored; return }
        do {
            let capabilities = try await session.capabilities(scope: scope)
            // The credential is bound server-side to exactly one (account, source). A reply that names
            // anything else means this phone is holding the wrong credential, and nothing may be sealed
            // or sent until that is resolved.
            if let userId = capabilities.userId, userId.lowercased() != identity.ownerId.lowercased() {
                throw CoordinatorError.ownershipMismatch("receiver answered for a different account")
            }
            if let sourceId = capabilities.sourceId, sourceId.lowercased() != identity.sourceId.lowercased() {
                throw CoordinatorError.ownershipMismatch("receiver answered for a different source")
            }
            negotiatedProtocolVersion = capabilities.protocolVersion
            CloudTransportCoordinator.storeProtocolVersion(capabilities.protocolVersion, ownerId: identity.ownerId)
        } catch let error as CoordinatorError {
            lastError = String(describing: error)
            throw error
        } catch CloudUploadSession.UploadError.unexpectedStatus(let status, _) where status == 401 || status == 403 {
            lastError = "credential rejected: HTTP \(status)"
            noteCredentialRejected(status: status)
        } catch {
            // Keep the deployed default so capture is never blocked by a negotiation failure; the
            // value is renegotiated on a later pass.
            lastError = "capability negotiation failed: \(error)"
        }
    }

    private func negotiatedVersion(for stream: CloudStreamKind) throws -> String {
        let version = negotiatedProtocolVersion ?? PushProtocol.objectVersion
        // Scalar-extension streams (stepSample, sleepStateSample) and the receipt streams need at least
        // 1.1; the package enforces the same rule and would throw, so fail here with a clearer message.
        if [.stepSample, .sleepStateSample].contains(stream), version == PushProtocol.version {
            throw CoordinatorError.sealFailed("\(stream.rawValue) requires a negotiated protocol >= 1.1")
        }
        return version
    }

    static func storedProtocolVersion(ownerId: String) -> String? {
        UserDefaults.standard.string(forKey: "noop.cloud.protocolVersion.\(ownerId.lowercased())")
    }

    static func storeProtocolVersion(_ version: String, ownerId: String) {
        UserDefaults.standard.set(version, forKey: "noop.cloud.protocolVersion.\(ownerId.lowercased())")
    }

    // MARK: - maintenance

    /// Reap acknowledged work only, and report what is pending.
    @discardableResult
    public func maintenance() async -> CloudJournalStats {
        _ = try? await journal.pruneAcknowledged()
        return await journal.stats()
    }

    public func status() async -> (stats: CloudJournalStats, inFlight: Int, protocolVersion: String?, lastError: String?, lastOutcomeAtMs: Int?) {
        (await journal.stats(), inFlight + backgroundInFlight, negotiatedProtocolVersion, lastError, lastOutcomeAtMs)
    }

    private func protectPayloadDirectory() async {
        #if os(iOS)
        // The payload files are written from background wakes too, so they take the same
        // after-first-unlock protection as the journal and the store.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: payloadDirectory.path)
        #endif
    }

    /// Whether the app is currently executing in the foreground, as last reported by the app layer.
    ///
    /// Injected rather than read from `UIApplication` here: this actor does not run on the main actor,
    /// and querying application state from off the main thread is not safe. The app layer knows the
    /// scene phase, so it pushes the value and this only reads it.
    static var appIsActiveProvider: @Sendable () -> Bool = { true }

    static func applicationIsActive() -> Bool { appIsActiveProvider() }

    /// Asks the OS to keep this process running until the returned closure is called.
    ///
    /// An upload that starts while the scene is off screen has to finish before the app is suspended
    /// again, so it holds one of these for its whole duration. Injected by the iOS layer (UIKit's
    /// `beginBackgroundTask`); the default does nothing, which is correct anywhere the process is not
    /// suspended behind the user's back.
    static var executionAssertion: @Sendable (String) async -> (@Sendable () -> Void) = { _ in { } }
}
