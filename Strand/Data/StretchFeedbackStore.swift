import Foundation
import SwiftUI
import StrandAnalytics

// MARK: - Local store

/// The wearer's verdicts on stretches of their day, kept on the phone until the server has them.
///
/// A verdict is the user's own data and cannot be rebuilt, so it lives in Application Support (and in device
/// backups) rather than in a cache folder. The file is tiny, so the whole set is read and rewritten whole,
/// atomically, under a lock.
final class StretchFeedbackStore: @unchecked Sendable {
    static let shared = StretchFeedbackStore()

    /// Older verdicts are dropped from the phone once the server has them, so the file stays small.
    static let keepSyncedDays = 120
    /// A file that cannot be read in full is copied aside before it is replaced; this many copies are kept.
    static let keepUnreadableCopies = 5
    static let unreadablePrefix = "stretch-feedback.unreadable-"

    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [StretchFeedback]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fm = FileManager.default
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
            let dir = base.appendingPathComponent("OpenWhoop/StretchFeedback", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            #if os(iOS)
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                  ofItemAtPath: dir.path)
            #endif
            self.fileURL = dir.appendingPathComponent("stretch-feedback.json")
        }
    }

    func all() -> [StretchFeedback] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Insert or replace the verdict stored under the same stretch key.
    @discardableResult
    func upsert(_ feedback: StretchFeedback) -> [StretchFeedback] {
        lock.lock(); defer { lock.unlock() }
        var rows = loadLocked()
        if let i = rows.firstIndex(where: { $0.stretchKey == feedback.stretchKey }) {
            rows[i] = feedback
        } else {
            rows.append(feedback)
        }
        saveLocked(rows)
        return rows
    }

    /// The saved "wrong, it was actually X" answers whose stretch overlaps `[from, to)`: what
    /// `ActivityContextCorrections` lays over the decoder's context when it is read.
    func corrections(overlapping from: Int, to: Int) -> [StretchFeedback] {
        all().filter { $0.verdict == .incorrect && $0.correctedLabel != nil && $0.endTs > from && $0.startTs < to }
    }

    func pending() -> [StretchFeedback] {
        all().filter(\.needsSync).sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Record that the server holds each `(id, updatedAt)`. A verdict edited after it was sent keeps its newer
    /// `updatedAt`, so it stays pending and goes out again.
    @discardableResult
    func markSynced(_ sent: [(id: UUID, updatedAt: Date)], at when: Date = Date()) -> [StretchFeedback] {
        lock.lock(); defer { lock.unlock() }
        var rows = loadLocked()
        for s in sent {
            guard let i = rows.firstIndex(where: { $0.id == s.id }) else { continue }
            if rows[i].updatedAt <= s.updatedAt { rows[i].syncedAt = max(when, rows[i].updatedAt) }
        }
        let cutoff = when.addingTimeInterval(-Double(Self.keepSyncedDays) * 86_400)
        rows.removeAll { !$0.needsSync && $0.updatedAt < cutoff }
        saveLocked(rows)
        return rows
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        cache = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadLocked() -> [StretchFeedback] {
        if let cache { return cache }
        var rows: [StretchFeedback] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // A file that is there but cannot be opened right now (iOS keeps it sealed until the phone has been
            // unlocked once after a restart) reads as empty for this call only. Remembering "empty" would let the
            // next save replace the answers that are really in it.
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            if !data.isEmpty {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
                if let entries = try? decoder.decode([Readable].self, from: data) {
                    rows = entries.compactMap(\.record)
                    if rows.count != entries.count { setAside(data) }
                } else {
                    setAside(data)
                }
            }
        }
        cache = rows
        return rows
    }

    /// One entry of the stored array. An entry that cannot be read comes back empty instead of failing the
    /// whole file, so the answers next to it are kept.
    private struct Readable: Decodable {
        let record: StretchFeedback?
        init(from decoder: Decoder) throws { record = try? StretchFeedback(from: decoder) }
    }

    /// Copy what was on disk aside before the next save replaces it. A verdict cannot be rebuilt, so a file
    /// this build could not fully read must not be destroyed by the save that follows.
    private func setAside(_ data: Data) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970)
        try? data.write(to: dir.appendingPathComponent("\(Self.unreadablePrefix)\(stamp).json"), options: [.atomic])
        let copies = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(Self.unreadablePrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in copies.dropLast(Self.keepUnreadableCopies) { try? fm.removeItem(at: old) }
    }

    private func saveLocked(_ rows: [StretchFeedback]) {
        cache = rows
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rows) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        if let date = StretchFeedbackDates.fractional.date(from: text) ?? StretchFeedbackDates.plain.date(from: text) {
            return date
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static let iso8601WithFractionalSeconds = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(StretchFeedbackDates.fractional.string(from: date))
    }
}

private enum StretchFeedbackDates {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
}

// MARK: - Upload

/// Sends stretch verdicts to the `scores` edge function (`POST /stretch-feedback`), where they are stored with
/// what the model predicted so they can be used to tune it. Best effort: anything that does not get through
/// stays on the phone and goes out on the next attempt, and a verdict is never dropped for failing to upload.
final class StretchFeedbackCloudSync: Sendable {
    static let batchSize = 25

    private let session: URLSession
    private let endpoint: @Sendable () -> URL?
    private let identity: @Sendable () -> CloudPushIdentity?
    private let store: StretchFeedbackStore

    init(store: StretchFeedbackStore = .shared,
         session: URLSession = .shared,
         endpoint: @escaping @Sendable () -> URL? = { PlacementCloudSync.derivedEndpoint() },
         identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() }) {
        self.store = store
        self.session = session
        self.endpoint = endpoint
        self.identity = identity
    }

    /// Why nothing could be sent at all.
    enum Blocked: Equatable {
        /// Nobody is signed in on this phone, or the server did not accept the credential it holds.
        case signedOut
        /// This build has no cloud address to send to.
        case noServer
    }

    struct Outcome: Equatable {
        var uploaded = 0
        var rejected = 0
        var blocked: Blocked?
        /// The server's reason for each verdict it did not take, by stretch key.
        var refusals: [String: String] = [:]
    }

    /// Upload every verdict that still needs it, oldest first, in batches. Throws on a transport or server
    /// error after recording whatever was accepted before it.
    @discardableResult
    func pushPending() async throws -> Outcome {
        var outcome = Outcome()
        let pending = store.pending()
        guard !pending.isEmpty else { return outcome }
        guard let id = identity() else { outcome.blocked = .signedOut; return outcome }
        guard let base = endpoint() else { outcome.blocked = .noServer; return outcome }

        for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
            let batch = Array(pending[start..<min(pending.count, start + Self.batchSize)])
            var request = URLRequest(url: base.appendingPathComponent("stretch-feedback"), timeoutInterval: 30)
            request.httpMethod = "POST"
            CloudReceiverAuth.apply(id, to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Body(feedback: batch.map(StretchFeedbackWire.init)))

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw StretchFeedbackSyncError.serverRejected }
            if http.statusCode == 401 || http.statusCode == 403 {
                outcome.blocked = .signedOut
                return outcome
            }
            guard (200..<300).contains(http.statusCode), Self.isReadable(data) else {
                throw StretchFeedbackSyncError.serverRejected
            }
            let result = Self.accepted(in: data, batch: batch)
            store.markSynced(result.accepted.map { (id: $0.id, updatedAt: $0.updatedAt) })
            outcome.uploaded += result.accepted.count
            outcome.rejected += result.rejected

            var reasons = Self.refusals(in: data)
            let took = Set(result.accepted.map(\.stretchKey))
            for f in batch where !took.contains(f.stretchKey) && reasons[f.stretchKey] == nil {
                reasons[f.stretchKey] = "not_confirmed"
            }
            outcome.refusals.merge(reasons) { _, new in new }
        }
        return outcome
    }

    private struct Body: Encodable { let feedback: [StretchFeedbackWire] }

    /// Whether a 2xx reply is the JSON object the route sends. Anything else (a captive portal's page, a proxy's
    /// error body) says nothing about what was stored, so the batch is tried again rather than guessed at.
    static func isReadable(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) != nil
    }

    /// The server's reason code for each verdict in `rejected`, by stretch key.
    static func refusals(in data: Data) -> [String: String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["rejected"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for row in rows {
            if let key = row["stretch_key"] as? String { out[key] = (row["reason"] as? String) ?? "rejected" }
        }
        return out
    }

    /// Which verdicts of `batch` the server took. `saved` and `ignored` (an older copy of something it already
    /// holds) are both done; `rejected` ones, and anything the reply does not name, stay queued. A reply that
    /// cannot be read takes nothing, so an unexpected body never loses a verdict.
    static func accepted(in data: Data, batch: [StretchFeedback]) -> (accepted: [StretchFeedback], rejected: Int) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], 0) }
        func keys(_ name: String) -> Set<String> {
            Set(((json[name] as? [[String: Any]]) ?? []).compactMap { $0["stretch_key"] as? String })
        }
        let done = keys("saved").union(keys("ignored"))
        let rejectedKeys = keys("rejected")
        return (batch.filter { done.contains($0.stretchKey) && !rejectedKeys.contains($0.stretchKey) },
                rejectedKeys.count)
    }
}

enum StretchFeedbackSyncError: Error {
    case serverRejected
}

// MARK: - Observable front for the UI

/// What the Heart rate page reads and writes verdicts through. Holds the stored verdicts so a stretch can show
/// that it has been answered, saves a new answer at once, and then sends whatever is waiting.
///
/// It also keeps the account of how sending went. A verdict that is saved but not yet sent can be in that state
/// for very different reasons (no connection, nobody signed in, the server turned it down), and the screens say
/// which one it is instead of promising it will go out "when you're online".
@MainActor
final class StretchFeedbackCenter: ObservableObject {
    static let shared = StretchFeedbackCenter()

    /// How the last attempt to send went, as far as this launch of the app knows.
    enum Delivery: Equatable {
        /// Nothing waiting, or nothing tried yet.
        case idle
        case sending
        /// Nobody is signed in to send for, or the server did not accept the credential.
        case needsSignIn
        /// This build has no cloud address.
        case noServer
        /// The network or the server failed; another attempt is already scheduled.
        case willRetry
        /// The server read at least one verdict and turned it down.
        case refused
    }

    /// Where one saved verdict stands.
    enum Standing: Equatable {
        case sent
        case sending
        case waiting
        case needsSignIn
        case noServer
        case willRetry
        case refused(reason: String)
    }

    @Published private(set) var records: [StretchFeedback]
    /// Verdicts saved here that the server has not confirmed yet.
    @Published private(set) var waitingToUpload: Int
    @Published private(set) var delivery: Delivery = .idle
    /// The server's reason for each verdict it turned down, by stretch key.
    @Published private(set) var refusals: [String: String] = [:]

    private let store: StretchFeedbackStore
    private let sync: StretchFeedbackCloudSync
    private let retryDelays: [TimeInterval]
    private var uploadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var uploadAgain = false
    private var failedRuns = 0

    /// `retryDelays` is how long to wait after the first, second, third… failed run before trying again; the
    /// last entry repeats.
    init(store: StretchFeedbackStore = .shared, sync: StretchFeedbackCloudSync? = nil,
         retryDelays: [TimeInterval] = [15, 45, 120, 300, 900]) {
        self.store = store
        self.sync = sync ?? StretchFeedbackCloudSync(store: store)
        self.retryDelays = retryDelays
        let rows = store.all()
        self.records = rows
        self.waitingToUpload = rows.filter(\.needsSync).count
    }

    func feedback(kind: StretchKind, start: Int, end: Int) -> StretchFeedback? {
        StretchFeedbackMatch.best(kind: kind, start: start, end: end, in: records)
    }

    func standing(of feedback: StretchFeedback) -> Standing {
        guard feedback.needsSync else { return .sent }
        if let reason = refusals[feedback.stretchKey] { return .refused(reason: reason) }
        switch delivery {
        case .sending: return .sending
        case .needsSignIn: return .needsSignIn
        case .noServer: return .noServer
        case .willRetry: return .willRetry
        case .idle, .refused: return .waiting
        }
    }

    /// Store `feedback` (replacing an earlier answer for the same stretch) and try to send it.
    func save(_ feedback: StretchFeedback) {
        records = store.upsert(feedback)
        waitingToUpload = records.filter(\.needsSync).count
        flush()
    }

    /// Send everything waiting, one run at a time. A request made during a run makes it go round once more.
    func flush() {
        guard uploadTask == nil else { uploadAgain = true; return }
        reload()
        guard waitingToUpload > 0 else { return }
        retryTask?.cancel()
        retryTask = nil
        delivery = .sending
        let sync = self.sync
        uploadTask = Task { [weak self] in
            var failed = false
            var blocked: StretchFeedbackCloudSync.Blocked?
            var refused: [String: String] = [:]
            repeat {
                self?.uploadAgain = false
                do {
                    let outcome = try await sync.pushPending()
                    failed = false
                    blocked = outcome.blocked
                    refused = outcome.refusals
                } catch {
                    failed = true
                }
                self?.reload()
            } while self?.uploadAgain == true && !Task.isCancelled
            self?.finishRun(failed: failed, blocked: blocked, refusals: refused)
            self?.uploadTask = nil
        }
    }

    /// `flush()`, returning once the run (and any run it queued) is over.
    func flushAndWait() async {
        flush()
        await uploadTask?.value
    }

    private func finishRun(failed: Bool, blocked: StretchFeedbackCloudSync.Blocked?, refusals found: [String: String]) {
        refusals = found.filter { key, _ in records.contains { $0.stretchKey == key && $0.needsSync } }
        if let blocked {
            failedRuns = 0
            delivery = blocked == .noServer ? .noServer : .needsSignIn
        } else if failed {
            failedRuns += 1
            delivery = .willRetry
            scheduleRetry()
        } else {
            failedRuns = 0
            delivery = refusals.isEmpty ? .idle : .refused
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard !retryDelays.isEmpty else { return }
        let delay = retryDelays[min(failedRuns - 1, retryDelays.count - 1)]
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.flush()
        }
    }

    private func reload() {
        records = store.all()
        waitingToUpload = records.filter(\.needsSync).count
    }
}
