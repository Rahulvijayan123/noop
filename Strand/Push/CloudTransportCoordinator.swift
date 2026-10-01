import Foundation
import NoopPush

/// One owner-scoped coordinator for sealing, uploading and receipt reconciliation.
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

    public struct Policy: Sendable {
        /// At most this many uploads in flight. Two is the spec's measured starting point.
        public var maxInFlight: Int = 2
        /// A batch older than this is "backlog" rather than "fresh"; one of each is admitted per pass
        /// so a long backlog can never starve newly captured data (and vice versa).
        public var freshWindowSeconds: Int = 30
        public var retryBaseSeconds: Double = 5
        public var retryCapSeconds: Double = 3600
        public var maxAttempts: Int = 12
        /// Bounded per pass, so one pass cannot turn into an unbounded drain.
        public var maxSealsPerPass: Int = 4
        public var sealMaxRecords: Int = 2_000
        public var sealMaxBytes: Int = 1 << 20
        public var acceptedRetentionSeconds: Int = 7 * 24 * 3600
        public init() {}
    }

    public enum CoordinatorError: Error, CustomStringConvertible {
        case notConfigured
        case sealFailed(String)
        case unsupportedStream(CloudStreamKind)

        public var description: String {
            switch self {
            case .notConfigured: return "cloud: coordinator not configured"
            case .sealFailed(let why): return "cloud: seal failed: \(why)"
            case .unsupportedStream(let s): return "cloud: \(s.rawValue) is not an append stream"
            }
        }
    }

    private let journal: CloudJournal
    private let session: CloudUploadSession
    private let payloadDirectory: URL
    private let identity: @Sendable () -> CloudPushIdentity?
    private let projectURL: String
    private let policy: Policy
    private let now: @Sendable () -> Int
    private let random: @Sendable () -> Double

    private var inFlight = 0
    private var cycleScheduled = false
    private var active = false
    private var negotiatedProtocolVersion: String?
    private var lastError: String?
    private var lastOutcomeAtMs: Int?

    public init(journal: CloudJournal, session: CloudUploadSession, payloadDirectory: URL,
                projectURL: String, identity: @escaping @Sendable () -> CloudPushIdentity?,
                policy: Policy = Policy(),
                now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.journal = journal
        self.session = session
        self.payloadDirectory = payloadDirectory
        self.projectURL = projectURL
        self.identity = identity
        self.policy = policy
        self.now = now
        self.random = random
    }

    // MARK: - lifecycle

    public func start() async {
        active = true
        try? FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        await protectPayloadDirectory()
        session.onOutcome = { [weak self] outcome in
            guard let self else { return }
            Task { await self.handle(outcome: outcome) }
        }
        try? await reconcileTasksAtLaunch()
        try? await cleanUpAcknowledgedFiles()
        try? await resealBlockedBatches()
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
        guard let identity = identity() else {
            lastError = "no installation identity"
            return
        }
        do {
            try await adoptNegotiatedVersionIfNeeded(identity: identity)
            try await reconcileTasksAtLaunch()
            try await sealReady(identity: identity)
            try await sendEligible(identity: identity)
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - sealing

    /// Seal each ready group into an immutable file and register it as a durable job.
    ///
    /// A group becomes ready on AGE (the ~2 s active-use target) or on size. The file is written to a
    /// temporary name in the same directory and then renamed, so a reader can never observe a partial
    /// payload, and a re-seal after a crash lands on the same name because the batch id is derived
    /// from the batch's identity and lines.
    private func sealReady(identity: CloudPushIdentity) async throws {
        let candidates = try await journal.sealCandidates(limit: policy.maxSealsPerPass)
        for candidate in candidates {
            guard CloudBatchBuilder.appendTable(for: candidate.stream) != nil else {
                // Replace-window / archive streams are not authored by the phone in cloud mode.
                continue
            }
            let entries = try await journal.entries(for: candidate)
            guard !entries.isEmpty else { continue }
            let protocolVersion = try negotiatedVersion(for: candidate.stream)
            let startCursorJSON = await journal.appendCursorJSON(deviceId: candidate.deviceId,
                                                                stream: candidate.stream)
            let plan: CloudBatchBuilder.Plan
            do {
                plan = try CloudBatchBuilder.plan(entries: entries, stream: candidate.stream,
                                                  sourceId: identity.sourceId, deviceId: candidate.deviceId,
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

    /// Fill the in-flight budget with eligible batches, one backlog item and one fresh item per pass.
    private func sendEligible(identity: CloudPushIdentity) async throws {
        guard inFlight < policy.maxInFlight else { return }
        let due = try await journal.batches(states: [.sealed, .failed], dueBeforeMs: now() * 1000,
                                            limit: max(policy.maxInFlight * 4, 8))
        guard !due.isEmpty else { return }
        let nowMs = now() * 1000
        let freshCutoff = nowMs - policy.freshWindowSeconds * 1000
        let backlog = due.filter { $0.createdAtMs < freshCutoff }
        let fresh = due.filter { $0.createdAtMs >= freshCutoff }
        var queue: [CloudSealedBatch] = []
        if let oldestBacklog = backlog.first { queue.append(oldestBacklog) }
        if let newestFresh = fresh.last { queue.append(newestFresh) }
        if queue.isEmpty { queue = Array(due.prefix(1)) }

        for batch in queue {
            guard inFlight < policy.maxInFlight else { break }
            guard FileManager.default.fileExists(atPath: batch.filePath) else {
                // The file is gone but the records are not acknowledged: re-seal instead of dropping.
                try await releaseForReseal(batch)
                continue
            }
            inFlight += 1
            let appIsActive = CloudTransportCoordinator.applicationIsActive()
            if appIsActive {
                Task { await self.uploadOnForegroundLane(batch, identity: identity) }
            } else {
                let taskId = session.enqueueBackground(batchId: batch.batchId,
                                                       fileURL: URL(fileURLWithPath: batch.filePath))
                try await journal.markReserved(batchId: batch.batchId, taskId: String(taskId),
                                               taskKind: "background", authExpiresAtMs: nil)
            }
        }
    }

    /// Prompt lane: the app is executing, so send now and apply the receipt as soon as it lands.
    private func uploadOnForegroundLane(_ batch: CloudSealedBatch, identity: CloudPushIdentity) async {
        defer { inFlight = max(0, inFlight - 1) }
        do {
            let outcome = try await session.uploadForeground(batchId: batch.batchId,
                                                            fileURL: URL(fileURLWithPath: batch.filePath))
            await handle(outcome: outcome)
        } catch {
            await handleFailure(batch: batch, error: String(describing: error))
        }
    }

    // MARK: - outcomes

    /// Apply a transfer outcome. A 200 body is the receiver's acknowledgement; anything else is a
    /// failure with its own retry treatment.
    private func handle(outcome: CloudUploadSession.Outcome) async {
        guard active else { return }
        inFlight = max(0, inFlight - 1)
        lastOutcomeAtMs = now() * 1000
        guard let batch = try? await journal.batches(states: [.sealed, .reserved, .uploaded, .failed],
                                                    dueBeforeMs: nil, limit: 256)
            .first(where: { $0.batchId == outcome.batchId }) else { return }

        if outcome.isTransportFailure {
            await handleFailure(batch: batch, error: outcome.errorDescription ?? "transport")
            return
        }
        guard outcome.statusCode == 200, let body = outcome.body else {
            await handleFailure(batch: batch, error: "HTTP \(outcome.statusCode)")
            return
        }
        do {
            try await journal.markUploaded(batchId: batch.batchId)
            try await applyReceipt(batch: batch, body: body)
        } catch {
            await handleFailure(batch: batch, error: String(describing: error))
        }
    }

    /// Validate and apply the receiver's acknowledgement.
    ///
    /// Three independent things must line up before a single record is released: the ack must name
    /// this exact batch (id, stream, device, end cursor, record count), the durability receipt must be
    /// a well-formed `verified_indexed` receipt for this owner, and its content digest must be the
    /// digest of the decoded body we sealed. Only then are the batch's records marked acknowledged.
    private func applyReceipt(batch: CloudSealedBatch, body: Data) async throws {
        let ack = try PushAck.parse(body)
        guard ack.status == "accepted" else {
            lastError = "receiver status \(ack.status)"
            return
        }
        let rebuilt = try await rebuildBatch(batch)
        if let rebuilt {
            guard ack.exactlyMatches(rebuilt.batch) else {
                lastError = "ack does not match the sealed batch \(batch.batchId)"
                return
            }
        }
        guard let receipt = ack.durabilityReceipt else {
            // A transport-level "accepted" without a durability receipt is not proof of durable
            // intake; keep the file and try again rather than treating it as done.
            lastError = "no durability receipt for \(batch.batchId)"
            return
        }
        if let rebuilt, let scope = try? AccountScope(projectURL: projectURL, userID: rebuilt.ownerId) {
            guard receipt.matches(rebuilt.batch, owner: scope) else {
                lastError = "durability receipt does not match \(batch.batchId)"
                return
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
        case .duplicate:
            try await deleteFileIfUnreferenced(batch)
        case .checksumMismatch(let expected, let received):
            lastError = "receipt checksum mismatch for \(batch.batchId): \(expected) != \(received)"
        case .unknownBatch:
            lastError = "receipt for unknown batch \(batch.batchId)"
        case .malformed:
            lastError = "malformed receipt for \(batch.batchId)"
        }
    }

    /// Rebuild the wire batch from its durable membership.
    ///
    /// This is what makes reconciliation survive a relaunch: the in-memory batch is gone, but the
    /// entries are still in the journal, and the builder is deterministic, so the same batch (and the
    /// same batch id) can be reconstructed and used to validate the receipt.
    private func rebuildBatch(_ batch: CloudSealedBatch) async throws -> (batch: PushBatch, ownerId: String, deviceId: String, stream: CloudStreamKind)? {
        guard let identity = identity() else { return nil }
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
        return (plan.batch, identity.ownerId, batch.deviceId, batch.stream)
    }

    // MARK: - failure handling

    private func handleFailure(batch: CloudSealedBatch, error: String) async {
        if !CloudTransportCoordinator.isRetryable(error: error) {
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
        let outstanding = await session.outstandingTasks()
        let liveTaskIds = Set(outstanding.map { String($0.taskIdentifier) })
        let liveBatchIds = Set(outstanding.compactMap { $0.batchId })
        let reserved = try await journal.batches(states: [.reserved], dueBeforeMs: nil, limit: 256)
        for batch in reserved {
            if liveBatchIds.contains(batch.batchId) { continue }
            _ = liveTaskIds
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
            let url = URL(fileURLWithPath: batch.filePath)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// A sealed batch whose file vanished before acknowledgement: release it so its records are
    /// re-sealed on the next pass. The records themselves were never released, so nothing is lost.
    private func releaseForReseal(_ batch: CloudSealedBatch) async throws {
        try await journal.markFailed(batchId: batch.batchId,
                                     error: "payload file missing; will re-seal", nextAttemptAtMs: nil)
    }

    // MARK: - deletion

    /// Delete a payload file only after an acknowledged, checksum-matched receipt AND when no live
    /// task references it. Out-of-order acknowledgements therefore leave earlier batches (and their
    /// files) untouched: each batch is released on its own receipt, never by a global cursor.
    private func deleteFileIfUnreferenced(_ batch: CloudSealedBatch) async throws {
        guard (try await journal.batchState(batch.batchId)) == .acked else { return }
        let outstanding = await session.outstandingTasks()
        if outstanding.contains(where: { $0.batchId == batch.batchId }) { return }
        let url = URL(fileURLWithPath: batch.filePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - negotiation

    private func adoptNegotiatedVersionIfNeeded(identity: CloudPushIdentity) async throws {
        guard negotiatedProtocolVersion == nil else { return }
        let stored = CloudTransportCoordinator.storedProtocolVersion(ownerId: identity.ownerId)
        if let stored { negotiatedProtocolVersion = stored; return }
        do {
            let capabilities = try await session.capabilities()
            negotiatedProtocolVersion = capabilities.protocolVersion
            CloudTransportCoordinator.storeProtocolVersion(capabilities.protocolVersion, ownerId: identity.ownerId)
            if let userId = capabilities.userId, userId.lowercased() != identity.ownerId.lowercased() {
                lastError = "receiver reports a different owner than the enrolled identity"
            }
        } catch {
            // Keep the deployed default so capture is never blocked by a negotiation failure; the
            // value is renegotiated on a later pass.
            lastError = "capability negotiation failed: \(error)"
        }
    }

    private func negotiatedVersion(for stream: CloudStreamKind) throws -> String {
        let version = negotiatedProtocolVersion ?? PushProtocol.objectVersion
        // Scalar-extension streams (stepSample) and the receipt streams need at least 1.1; the package
        // enforces the same rule and would throw, so fail here with a clearer message.
        if stream == .stepSample, version == PushProtocol.version {
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
        (await journal.stats(), inFlight, negotiatedProtocolVersion, lastError, lastOutcomeAtMs)
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
}
