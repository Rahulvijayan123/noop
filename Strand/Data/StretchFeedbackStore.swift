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
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
            rows = (try? decoder.decode([StretchFeedback].self, from: data)) ?? []
        }
        cache = rows
        return rows
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

    struct Outcome: Equatable {
        var uploaded = 0
        var rejected = 0
    }

    /// Upload every verdict that still needs it, oldest first, in batches. Throws on a transport or server
    /// error after recording whatever was accepted before it.
    @discardableResult
    func pushPending() async throws -> Outcome {
        var outcome = Outcome()
        guard let id = identity(), let base = endpoint() else { return outcome }
        let pending = store.pending()
        guard !pending.isEmpty else { return outcome }

        for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
            let batch = Array(pending[start..<min(pending.count, start + Self.batchSize)])
            var request = URLRequest(url: base.appendingPathComponent("stretch-feedback"), timeoutInterval: 30)
            request.httpMethod = "POST"
            CloudReceiverAuth.apply(id, to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Body(feedback: batch.map(StretchFeedbackWire.init)))

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw StretchFeedbackSyncError.serverRejected
            }
            let result = Self.accepted(in: data, batch: batch)
            store.markSynced(result.accepted.map { (id: $0.id, updatedAt: $0.updatedAt) })
            outcome.uploaded += result.accepted.count
            outcome.rejected += result.rejected
        }
        return outcome
    }

    private struct Body: Encodable { let feedback: [StretchFeedbackWire] }

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
@MainActor
final class StretchFeedbackCenter: ObservableObject {
    static let shared = StretchFeedbackCenter()

    @Published private(set) var records: [StretchFeedback]
    /// Verdicts saved here that the server has not confirmed yet.
    @Published private(set) var waitingToUpload: Int

    private let store: StretchFeedbackStore
    private let sync: StretchFeedbackCloudSync
    private var uploadTask: Task<Void, Never>?
    private var uploadAgain = false

    init(store: StretchFeedbackStore = .shared, sync: StretchFeedbackCloudSync? = nil) {
        self.store = store
        self.sync = sync ?? StretchFeedbackCloudSync(store: store)
        let rows = store.all()
        self.records = rows
        self.waitingToUpload = rows.filter(\.needsSync).count
    }

    func feedback(kind: StretchKind, start: Int, end: Int) -> StretchFeedback? {
        StretchFeedbackMatch.best(kind: kind, start: start, end: end, in: records)
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
        guard waitingToUpload > 0 else { return }
        let sync = self.sync
        uploadTask = Task { [weak self] in
            repeat {
                self?.uploadAgain = false
                _ = try? await sync.pushPending()
                self?.reload()
            } while self?.uploadAgain == true && !Task.isCancelled
            self?.uploadTask = nil
        }
    }

    private func reload() {
        records = store.all()
        waitingToUpload = records.filter(\.needsSync).count
    }
}
