import Foundation
import NoopPush

/// The HTTP layer for the push receiver.
///
/// Two lanes, one wire contract:
///
///  - **Foreground fast path.** An ordinary `URLSession` uploads an already-sealed file immediately
///    when the app is running. There is deliberately no delay, no queue drain and no "wait for ten
///    batches" step: an eligible file is sent as soon as it exists.
///  - **One stable background session.** A single `URLSession` with a fixed identifier and
///    file-backed tasks, so a transfer that the OS suspends mid-flight can be resumed and reported
///    after the app is relaunched for it. The app delegate must forward
///    `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to
///    `takeBackgroundCompletionHandler(_:)`; the handler is invoked once the system says the session's
///    events are finished.
///
/// Background outcomes arrive through the delegate, not through an `await`, because a background
/// transfer may finish while this process does not exist. The coordinator therefore reconciles from
/// the DURABLE job table (`sealed_batch.task_id`) rather than from in-memory task state, and a
/// re-upload of the same bytes is safe: the batch id is derived from the batch's identity and lines,
/// so the receiver returns the stored acknowledgement instead of accepting the batch twice.
public final class CloudUploadSession: NSObject, @unchecked Sendable {

    public enum Lane: Sendable {
        /// Ordinary session, awaited by the caller. Used while the app is executing.
        case foreground
        /// Stable background session, file task, delegate-reported.
        case background
    }

    public struct Outcome: Sendable {
        public let batchId: String
        public let statusCode: Int
        public let body: Data?
        public let errorDescription: String?
        public var isTransportFailure: Bool { errorDescription != nil }
    }

    public enum UploadError: Error, CustomStringConvertible {
        case notConfigured
        case missingIdentity
        case unexpectedStatus(Int, String?)
        case transport(String)

        public var description: String {
            switch self {
            case .notConfigured: return "cloud: receiver not configured"
            case .missingIdentity: return "cloud: no installation identity"
            case .unexpectedStatus(let code, let body): return "cloud: HTTP \(code) \(body ?? "")"
            case .transport(let message): return "cloud: transport failure: \(message)"
            }
        }
    }

    /// Stable per-app background session identifier. It must not change between launches, or the OS
    /// loses the association with in-flight transfers (and with the completion handler hand-off).
    public static func backgroundIdentifier(bundleIdentifier: String?) -> String {
        (bundleIdentifier ?? "com.noopapp.noop") + ".cloud.upload"
    }

    private let endpoint: URL
    private let fleetToken: String
    private let identifier: String
    private let identity: @Sendable () -> CloudPushIdentity?
    private let now: @Sendable () -> Int

    private let stateLock = NSLock()
    private var taskBatchIds: [Int: String] = [:]
    private var pendingData: [Int: Data] = [:]
    private var foregroundWaiters: [Int: CheckedContinuation<Outcome, Error>] = [:]
    private var completionHandler: (() -> Void)?

    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        // Not discretionary: the payload is small and the user-visible promise is prompt progress.
        // The OS may still defer a background-initiated transfer; that is why recovery is durable
        // rather than dependent on any single task.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Reported for every background task that finishes, including after a relaunch.
    public var onOutcome: (@Sendable (Outcome) -> Void)?

    public init(endpoint: URL, fleetToken: String, bundleIdentifier: String?,
                identity: @escaping @Sendable () -> CloudPushIdentity?,
                now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.endpoint = endpoint
        self.fleetToken = fleetToken
        self.identifier = CloudUploadSession.backgroundIdentifier(bundleIdentifier: bundleIdentifier)
        self.identity = identity
        self.now = now
        super.init()
    }

    // MARK: - Request construction (the wire contract)

    /// The exact header set the deployed receiver requires.
    ///
    /// `Authorization` is the per-installation `noop_…` bearer and `x-noop-fleet-token` is the
    /// classified fleet credential. Both are required on every ingest request; the fleet token alone
    /// cannot authorize personal data, and the installation token is what binds the batch to an owner
    /// server-side (the body cannot choose another owner).
    func request(for batch: PushBatch, wireBytes: Int, gzipped: Bool) throws -> URLRequest {
        guard let identity = identity() else { throw UploadError.missingIdentity }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(identity.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue(fleetToken, forHTTPHeaderField: "x-noop-fleet-token")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(PushProtocol.capabilitiesAcceptVersions, forHTTPHeaderField: "noop-push-accept-version")
        if gzipped { request.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
        request.setValue(String(wireBytes), forHTTPHeaderField: "Content-Length")
        return request
    }

    /// Capability negotiation. `GET` on the receiver root, with the same credentials as ingest.
    public func capabilities() async throws -> PushCapabilities {
        guard let identity = identity() else { throw UploadError.missingIdentity }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(identity.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue(fleetToken, forHTTPHeaderField: "x-noop-fleet-token")
        request.setValue(PushProtocol.capabilitiesAcceptVersions, forHTTPHeaderField: "noop-push-accept-version")
        request.timeoutInterval = 20
        let (data, response) = try await foregroundSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadError.transport("no response") }
        guard http.statusCode == 200 else {
            throw UploadError.unexpectedStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        return try PushCapabilities.parse(data)
    }

    // MARK: - Uploads

    /// Foreground upload: awaits the receiver's acknowledgement. Used while the app is executing so a
    /// captured record can reach the server within seconds of arriving.
    public func uploadForeground(batchId: String, fileURL: URL) async throws -> Outcome {
        guard let identity = identity() else { throw UploadError.missingIdentity }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(identity.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue(fleetToken, forHTTPHeaderField: "x-noop-fleet-token")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(PushProtocol.capabilitiesAcceptVersions, forHTTPHeaderField: "noop-push-accept-version")
        // The sealed file IS the wire body (gzip applied at seal time), so what we hash, what we
        // upload and what we later delete are the same bytes.
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await foregroundSession.upload(for: request, fromFile: fileURL)
            guard let http = response as? HTTPURLResponse else {
                return Outcome(batchId: batchId, statusCode: 0, body: nil, errorDescription: "no response")
            }
            return Outcome(batchId: batchId, statusCode: http.statusCode, body: data, errorDescription: nil)
        } catch {
            throw UploadError.transport(error.localizedDescription)
        }
    }

    /// Background upload: hands a file task to the stable background session and returns its
    /// identifier. The outcome arrives through `onOutcome` (possibly in a later process lifetime).
    @discardableResult
    public func enqueueBackground(batchId: String, fileURL: URL) -> Int {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let identity = identity() {
            request.setValue("Bearer \(identity.uploadToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(fleetToken, forHTTPHeaderField: "x-noop-fleet-token")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(PushProtocol.capabilitiesAcceptVersions, forHTTPHeaderField: "noop-push-accept-version")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
        stateLock.lock()
        taskBatchIds[task.taskIdentifier] = batchId
        stateLock.unlock()
        task.resume()
        return task.taskIdentifier
    }

    /// Every background task the OS still knows about, so a relaunch can reconcile durable jobs with
    /// live tasks instead of re-uploading blindly.
    public func outstandingTasks() async -> [(taskIdentifier: Int, batchId: String?)] {
        let tasks = await backgroundSession.allTasks
        let map = snapshotTaskBatchIds()
        return tasks.map { ($0.taskIdentifier, map[$0.taskIdentifier]) }
    }

    /// Synchronous snapshot of the task -> batch map. Kept as a plain method so the lock is never
    /// taken directly inside an async context (NSLock is not async-safe).
    private func snapshotTaskBatchIds() -> [Int: String] {
        stateLock.lock(); defer { stateLock.unlock() }
        return taskBatchIds
    }

    // MARK: - Background completion hand-off

    /// Called from the app delegate's `handleEventsForBackgroundURLSession`. If the session has no
    /// outstanding work, the handler is invoked immediately (the system requires it to be called).
    public func takeBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        stateLock.lock()
        let outstanding = !taskBatchIds.isEmpty
        if outstanding {
            completionHandler = handler
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        handler()
    }

    private func finishBackgroundEventsIfIdle() {
        // Synchronous by design: called from delegate callbacks and from the completion-handler path.
        stateLock.lock()
        let idle = taskBatchIds.isEmpty
        let handler = idle ? completionHandler : nil
        if idle { completionHandler = nil }
        stateLock.unlock()
        handler?()
    }
}

extension CloudUploadSession: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateLock.lock()
        pendingData[dataTask.taskIdentifier, default: Data()].append(data)
        stateLock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        let batchId = taskBatchIds.removeValue(forKey: task.taskIdentifier)
        let body = pendingData.removeValue(forKey: task.taskIdentifier)
        stateLock.unlock()

        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let outcome = Outcome(batchId: batchId ?? "", statusCode: status, body: body,
                              errorDescription: error?.localizedDescription)
        if batchId != nil { onOutcome?(outcome) }
        finishBackgroundEventsIfIdle()
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        finishBackgroundEventsIfIdle()
    }
}
