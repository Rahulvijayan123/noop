import Foundation

/// One message waiting to reach the server. It belongs to one account (`ownerId`) and one thread, and is sent
/// only with that account's credential.
struct CoachOutboxEntry: Codable, Equatable, Sendable {
    var ownerId: String
    var threadId: String
    var clientId: String
    var role: String
    var content: String
    var meta: CoachMessageMeta?
    var createdAt: String
    var threadTitle: String?
    /// Refused by the server for a reason a retry cannot fix; kept for diagnosis, never sent again.
    var quarantined: Bool
    /// Bumped on every merge, so a flush that sent an older copy does not remove the newer one.
    var revision: Int

    init(ownerId: String, threadId: String, clientId: String, role: String, content: String,
         meta: CoachMessageMeta? = nil, createdAt: String, threadTitle: String? = nil,
         quarantined: Bool = false, revision: Int = 0) {
        self.ownerId = ownerId.lowercased()
        self.threadId = threadId.lowercased()
        self.clientId = clientId.lowercased()
        self.role = role
        self.content = content
        self.meta = meta
        self.createdAt = createdAt
        self.threadTitle = threadTitle
        self.quarantined = quarantined
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case ownerId, threadId, clientId, role, content, meta, createdAt, threadTitle, quarantined, revision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ownerId: try c.decode(String.self, forKey: .ownerId),
                  threadId: try c.decode(String.self, forKey: .threadId),
                  clientId: try c.decode(String.self, forKey: .clientId),
                  role: try c.decode(String.self, forKey: .role),
                  content: c.lossy(String.self, .content) ?? "",
                  meta: c.lossy(CoachMessageMeta.self, .meta),
                  createdAt: c.lossy(String.self, .createdAt) ?? CoachDates.string(Date()),
                  threadTitle: c.lossy(String.self, .threadTitle),
                  quarantined: c.lossy(Bool.self, .quarantined) ?? false,
                  revision: c.lossy(Int.self, .revision) ?? 0)
    }

    /// The row as `POST messages` takes it.
    var row: CoachStoredMessage {
        CoachStoredMessage(clientId: clientId, role: role, content: content, meta: meta, createdAt: createdAt,
                           threadId: threadId, threadTitle: threadTitle)
    }

    /// `newer` over `self`, field by field: content and role follow the newer copy, meta merges key by key (a
    /// non-nil field wins), a title is kept once known, and the first `createdAt` stays.
    func merged(with newer: CoachOutboxEntry) -> CoachOutboxEntry {
        var out = self
        out.role = newer.role
        out.content = newer.content.isEmpty && !content.isEmpty ? content : newer.content
        out.meta = (meta ?? CoachMessageMeta()).merged(with: newer.meta)
        out.threadTitle = newer.threadTitle ?? threadTitle
        out.revision = max(revision, newer.revision) + 1
        return out
    }
}

/// What one flush did: the client ids the server saved, each with its thread, and the threads whose rows it
/// dropped because the server has deleted them (`thread_deleted` or 410).
struct CoachFlushReport: Equatable, Sendable {
    var saved: [String: String] = [:]
    var deletedThreads = Set<String>()

    var savedIds: Set<String> { Set(saved.keys) }
    var savedThreads: Set<String> { Set(saved.values) }

    mutating func absorb(_ other: CoachFlushReport) {
        saved.merge(other.saved) { a, _ in a }
        deletedThreads.formUnion(other.deletedThreads)
    }
}

/// The persistent queue of unsent coach messages for one account (`<root>/outbox.json`).
///
/// - Entries merge by `clientId`, field by field, so a later re-save (the visual, the follow-ups) never loses
///   what an earlier one carried.
/// - One flush runs at a time; a flush asked for while another runs waits for it, then makes its own pass.
/// - Rows go in chunks of at most 20, one thread per chunk.
/// - Before every attempt (retries and bisected halves included) a chunk drops the rows no longer queued, so a
///   thread purged by a delete is never sent from a copy taken earlier.
/// - Network errors, 5xx and 429 are retried with backoff, then left for the next flush.
/// - Rows the server lists as rejected, or a chunk failing with 400, 409, 410 or 413, are bisected down to the
///   offending row, which is quarantined; a 410 or `thread_deleted` drops it instead.
/// - The file is capped at 2 MB, dropping quarantined rows first, then the oldest. It is read on first use, not
///   when the actor is made.
/// - `retire()` (another account signed in) stops sending; `discard()` (this account signed out) also empties it
///   and never writes the file again.
actor CoachOutbox {
    typealias Saver = @Sendable ([CoachStoredMessage]) async throws -> CoachSaveResult

    static let chunkSize = 20
    static let byteCap = 2 * 1024 * 1024

    let ownerId: String
    private let fileURL: URL?
    private let retryDelays: [UInt64]
    private var stored: [CoachOutboxEntry]?
    private var tail: Task<CoachFlushReport, Never>?
    private var retired = false
    private var discarded = false

    /// `fileURL` nil keeps the queue in memory only. `retryDelays` are the waits between attempts of one chunk.
    init(ownerId: String, fileURL: URL?, retryDelays: [TimeInterval] = [1, 4]) {
        self.ownerId = ownerId.lowercased()
        self.fileURL = fileURL
        self.retryDelays = retryDelays.map { UInt64(max(0, $0) * 1_000_000_000) }
    }

    /// The queue, read from the file the first time it is needed (off the caller's thread).
    private var entries: [CoachOutboxEntry] {
        get {
            if let stored { return stored }
            let owner = ownerId
            let loaded = (fileURL.flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode([CoachOutboxEntry].self, from: $0) } ?? [])
                .filter { $0.ownerId == owner && !$0.threadId.isEmpty }
            stored = loaded
            return loaded
        }
        set { stored = newValue }
    }

    /// Stops sending for good: a pass in progress ends before its next request. What is queued stays (and is still
    /// written) for the account's next sign-in.
    func retire() {
        retired = true
    }

    /// The account signed out: stops sending, empties the queue and never writes the file again, so nothing in
    /// flight can recreate it after the account's caches are deleted.
    func discard() {
        retired = true
        discarded = true
        stored = []
    }

    var isRetired: Bool { retired }

    // MARK: Queue

    /// Adds or merges rows. Rows stamped with another owner, or without a thread, are refused.
    func enqueue(_ new: [CoachOutboxEntry]) {
        guard !discarded else { return }
        var changed = false
        for entry in new where entry.ownerId == ownerId && !entry.threadId.isEmpty && !entry.clientId.isEmpty {
            if let i = entries.firstIndex(where: { $0.clientId == entry.clientId }) {
                entries[i] = entries[i].merged(with: entry)
            } else {
                entries.append(entry)
            }
            changed = true
        }
        if changed { persist() }
    }

    /// Rows still to send for one thread, oldest first; the open thread merges them into its page.
    func pending(threadId: String) -> [CoachOutboxEntry] {
        let id = threadId.lowercased()
        return sortedByTime(entries.filter { $0.threadId == id && !$0.quarantined })
    }

    var all: [CoachOutboxEntry] { entries }
    var pendingCount: Int { entries.filter { !$0.quarantined }.count }

    func contains(clientId: String) -> Bool {
        let id = clientId.lowercased()
        return entries.contains { $0.clientId == id && !$0.quarantined }
    }

    /// Empties one thread's rows: a deleted thread must not be recreated by a late save.
    func purge(threadId: String) {
        let id = threadId.lowercased()
        let before = entries.count
        entries.removeAll { $0.threadId == id }
        if entries.count != before { persist() }
    }

    func removeAll() {
        entries = []
        persist()
    }

    // MARK: Flush

    /// Sends everything pending for `ownerId` (nothing when it is not this outbox's owner) and returns the client
    /// ids the server has saved, including any saved by a flush that was already running.
    @discardableResult
    func flush(ownerId current: String?, save: @escaping Saver) async -> Set<String> {
        await flushReport(ownerId: current, save: save).savedIds
    }

    /// `flush`, also saying which thread each saved row belongs to and which threads the server has deleted.
    @discardableResult
    func flushReport(ownerId current: String?, save: @escaping Saver) async -> CoachFlushReport {
        let previous = tail
        let task = Task { () -> CoachFlushReport in
            _ = await previous?.value
            return await self.pass(ownerId: current, save: save)
        }
        tail = task
        var report = await task.value
        if let earlier = await previous?.value { report.absorb(earlier) }
        return report
    }

    private struct Outcome {
        var saved = Set<String>()
        var dropped = Set<String>()
        var quarantined = Set<String>()
        var deletedThreads = Set<String>()
        var stop = false

        mutating func absorb(_ other: Outcome) {
            saved.formUnion(other.saved)
            dropped.formUnion(other.dropped)
            quarantined.formUnion(other.quarantined)
            deletedThreads.formUnion(other.deletedThreads)
            stop = stop || other.stop
        }
    }

    private func pass(ownerId current: String?, save: Saver) async -> CoachFlushReport {
        guard !retired, let current, current.lowercased() == ownerId else { return CoachFlushReport() }
        let ready = entries.filter { !$0.quarantined }
        guard !ready.isEmpty else { return CoachFlushReport() }
        let sent = Dictionary(ready.map { ($0.clientId, $0.revision) }, uniquingKeysWith: { a, _ in a })
        let threadOf = Dictionary(ready.map { ($0.clientId, $0.threadId) }, uniquingKeysWith: { a, _ in a })

        var outcome = Outcome()
        for chunk in Self.chunks(sortedByTime(ready)) {
            outcome.absorb(await send(chunk, save: save))
            if outcome.stop { break }
        }

        // Only the copy that was sent leaves the queue; a merge made during the request keeps its newer copy.
        let finished = outcome.saved.union(outcome.dropped)
        entries.removeAll { finished.contains($0.clientId) && sent[$0.clientId] == $0.revision }
        for i in entries.indices where outcome.quarantined.contains(entries[i].clientId) { entries[i].quarantined = true }
        persist()
        var report = CoachFlushReport()
        for id in outcome.saved { if let thread = threadOf[id] { report.saved[id] = thread } }
        report.deletedThreads = Set(outcome.deletedThreads)
        return report
    }

    private func send(_ captured: [CoachOutboxEntry], save: Saver) async -> Outcome {
        var attempt = 0
        while true {
            // The chunk is a copy taken when the pass began; a purge (a deleted thread) or `removeAll` since then
            // must win over it, on the first attempt and on every retry.
            guard !retired, !Task.isCancelled else { return Outcome(stop: true) }
            let queued = Set(entries.lazy.filter { !$0.quarantined }.map(\.clientId))
            let chunk = captured.filter { queued.contains($0.clientId) }
            guard !chunk.isEmpty else { return Outcome() }
            do {
                let result = try await save(chunk.map(\.row))
                var reasons: [String: String] = [:]
                for r in result.rejected { reasons[r.clientId.lowercased()] = r.reason }
                var out = Outcome()
                for entry in chunk {
                    switch reasons[entry.clientId] {
                    case nil: out.saved.insert(entry.clientId)
                    case "thread_deleted":
                        out.dropped.insert(entry.clientId)
                        out.deletedThreads.insert(entry.threadId)
                    default: out.quarantined.insert(entry.clientId)
                    }
                }
                return out
            } catch let error as CoachRouteError where [400, 409, 410, 413, 422].contains(error.status) {
                guard chunk.count > 1 else {
                    var out = Outcome()
                    if error.status == 410 || error.code == "thread_deleted" {
                        out.dropped.insert(chunk[0].clientId)
                        out.deletedThreads.insert(chunk[0].threadId)
                    } else {
                        out.quarantined.insert(chunk[0].clientId)
                    }
                    return out
                }
                let mid = chunk.count / 2
                var out = await send(Array(chunk[..<mid]), save: save)
                if !out.stop { out.absorb(await send(Array(chunk[mid...]), save: save)) }
                return out
            } catch let error as CoachRouteError where error.status == 401 || error.status == 403 {
                return Outcome(stop: true)
            } catch let error as CoachAPIError where error == .notConfigured || error == .unauthorized {
                return Outcome(stop: true)
            } catch {
                guard attempt < retryDelays.count, !Task.isCancelled else { return Outcome(stop: true) }
                try? await Task.sleep(nanoseconds: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// One thread per chunk, at most `chunkSize` rows, threads in the order their oldest row was queued.
    static func chunks(_ rows: [CoachOutboxEntry]) -> [[CoachOutboxEntry]] {
        var order: [String] = []
        var byThread: [String: [CoachOutboxEntry]] = [:]
        for row in rows {
            if byThread[row.threadId] == nil { order.append(row.threadId) }
            byThread[row.threadId, default: []].append(row)
        }
        return order.flatMap { thread -> [[CoachOutboxEntry]] in
            let rows = byThread[thread] ?? []
            return stride(from: 0, to: rows.count, by: chunkSize).map { Array(rows[$0..<min($0 + chunkSize, rows.count)]) }
        }
    }

    private func sortedByTime(_ rows: [CoachOutboxEntry]) -> [CoachOutboxEntry] {
        rows.enumerated().sorted { a, b in
            let da = CoachDates.parse(a.element.createdAt) ?? .distantPast
            let db = CoachDates.parse(b.element.createdAt) ?? .distantPast
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Storage

    private func persist() {
        guard let fileURL, !discarded else { return }
        var data = (try? JSONEncoder().encode(entries)) ?? Data()
        while data.count > Self.byteCap, !entries.isEmpty {
            if let i = entries.firstIndex(where: \.quarantined) { entries.remove(at: i) } else { entries.removeFirst() }
            data = (try? JSONEncoder().encode(entries)) ?? Data()
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}
