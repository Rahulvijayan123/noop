import Foundation

/// The thread list and side state as last seen, so the sidebar and the welcome screen draw before the network.
struct CoachThreadsSnapshot: Codable, Equatable, Sendable {
    var threads: [CoachThread]
    var folders: [CoachFolder]
    var nextCursor: String?
    var hasMore: Bool
    var savedAt: Date
    /// The server's features when the list was saved, so a launch knows them before `status` answers.
    var features: CoachFeatures?
    /// Threads deleted here whose `DELETE threads/:id` has not been confirmed yet; retried before the next flush.
    var pendingDeletes: [String]?

    init(threads: [CoachThread] = [], folders: [CoachFolder] = [], nextCursor: String? = nil, hasMore: Bool = false,
         savedAt: Date = Date(), features: CoachFeatures? = nil, pendingDeletes: [String]? = nil) {
        self.threads = threads
        self.folders = folders
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.savedAt = savedAt
        self.features = features
        self.pendingDeletes = pendingDeletes
    }
}

/// Sana's on-device caches for one account, under `<AppSupport>/OpenWhoop/Coach/<ownerId>/`:
/// `threads.json`, `suggestions.json`, `manifests/<threadId>.json`, `messages/<threadId>.json` (the last 60
/// messages of the 10 most recently opened threads) and the outbox. Everything is keyed by the owner, so signing
/// A out and B in can never show B A's chats or send A's unsent turns with B's credential.
///
/// Reads are synchronous and small: `attach()` loads them before the first frame. A missing or corrupt file
/// reads as empty.
struct CoachLocalStore: Sendable {
    static let messagesPerThread = 60
    static let threadsWithMessages = 10
    static let manifestsKept = 12

    let ownerId: String
    let root: URL

    /// `base` defaults to Application Support; tests pass a temporary directory. Nil when the owner id is not a
    /// plain identifier, so it can never name a path outside the coach folder.
    init?(ownerId: String, base: URL? = nil) {
        let owner = ownerId.lowercased()
        guard Self.isSafeComponent(owner) else { return nil }
        self.ownerId = owner
        self.root = Self.coachRoot(base: base).appendingPathComponent(owner, isDirectory: true)
    }

    /// `<base>/OpenWhoop/Coach/`.
    static func coachRoot(base: URL? = nil) -> URL {
        let support = base ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("OpenWhoop", isDirectory: true).appendingPathComponent("Coach", isDirectory: true)
    }

    /// Deletes every cache and the outbox for `ownerId`. Runs on sign-out and account reset, through
    /// `CoachChatViewModel.removeAccountData(ownerId:)`, which first makes every live chat let go of them.
    static func removeAll(ownerId: String, base: URL? = nil) {
        guard let store = CoachLocalStore(ownerId: ownerId, base: base) else { return }
        try? FileManager.default.removeItem(at: store.root)
    }

    private static func isSafeComponent(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }
    }

    // MARK: Files

    var outboxURL: URL { root.appendingPathComponent("outbox.json") }
    private var threadsURL: URL { root.appendingPathComponent("threads.json") }
    private var suggestionsURL: URL { root.appendingPathComponent("suggestions.json") }
    private var manifestsDir: URL { root.appendingPathComponent("manifests", isDirectory: true) }
    private var messagesDir: URL { root.appendingPathComponent("messages", isDirectory: true) }

    private func file(in dir: URL, threadId: String) -> URL? {
        let id = threadId.lowercased()
        guard Self.isSafeComponent(id) else { return nil }
        return dir.appendingPathComponent(id + ".json")
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // MARK: Threads

    func loadThreads() -> CoachThreadsSnapshot? { read(CoachThreadsSnapshot.self, at: threadsURL) }

    func saveThreads(_ snapshot: CoachThreadsSnapshot) { write(snapshot, to: threadsURL) }

    // MARK: Suggestions

    func loadSuggestions() -> CoachCachedSuggestions? { read(CoachCachedSuggestions.self, at: suggestionsURL) }

    func saveSuggestions(_ cached: CoachCachedSuggestions) { write(cached, to: suggestionsURL) }

    func removeSuggestions() { try? FileManager.default.removeItem(at: suggestionsURL) }

    // MARK: Manifests

    func loadManifest(threadId: String) -> CoachContextManifest? {
        file(in: manifestsDir, threadId: threadId).flatMap { read(CoachContextManifest.self, at: $0) }
    }

    func saveManifest(_ manifest: CoachContextManifest, threadId: String) {
        guard let url = file(in: manifestsDir, threadId: threadId) else { return }
        write(manifest, to: url)
        prune(manifestsDir, keep: Self.manifestsKept)
    }

    /// The most recently saved manifest of any thread: a new chat's starting point until its own arrives.
    func latestManifest() -> CoachContextManifest? {
        newestFirst(in: manifestsDir).lazy.compactMap { self.read(CoachContextManifest.self, at: $0) }.first
    }

    /// Rewrites every cached manifest through `transform` (dropping a forgotten memory, say). Oldest first, so
    /// the files keep their order and `latestManifest()` still returns the newest.
    func updateManifests(_ transform: (CoachContextManifest) -> CoachContextManifest) {
        for url in newestFirst(in: manifestsDir).reversed() {
            guard let manifest = read(CoachContextManifest.self, at: url) else { continue }
            write(transform(manifest), to: url)
        }
    }

    func removeAllManifests() { try? FileManager.default.removeItem(at: manifestsDir) }

    // MARK: Messages

    func loadMessages(threadId: String) -> [CoachStoredMessage] {
        file(in: messagesDir, threadId: threadId).flatMap { read([CoachStoredMessage].self, at: $0) } ?? []
    }

    /// Keeps the newest 60 rows of the thread and the 10 most recently written threads.
    func saveMessages(_ rows: [CoachStoredMessage], threadId: String) {
        guard let url = file(in: messagesDir, threadId: threadId) else { return }
        write(Array(rows.suffix(Self.messagesPerThread)), to: url)
        prune(messagesDir, keep: Self.threadsWithMessages)
    }

    func removeThread(id: String) {
        for dir in [messagesDir, manifestsDir] {
            if let url = file(in: dir, threadId: id) { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Housekeeping

    private func newestFirst(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da != db ? da > db : a.lastPathComponent < b.lastPathComponent
        }
    }

    private func prune(_ dir: URL, keep: Int) {
        for url in newestFirst(in: dir).dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }
}
