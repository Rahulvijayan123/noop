import Foundation
import Combine

@MainActor
final class ManualEventCenter: ObservableObject {
    static let shared = ManualEventCenter()
    @Published private(set) var owner: String?
    @Published private(set) var entries: [ManualEventEntry] = []
    @Published private(set) var pendingIds: Set<UUID> = []
    /// Events whose latest revision the server refused, with its reason. They stay on the device.
    @Published private(set) var rejected: [UUID: String] = [:]
    /// The server's timestamp-aligned context per event, as last received (ManualEventContext).
    @Published private(set) var contexts: [UUID: ManualEventContext] = [:]
    /// Events whose stored context was built from an earlier revision (the event changed since).
    @Published private(set) var staleContexts: Set<UUID> = []
    @Published private(set) var syncing = false
    @Published private(set) var syncMessage: String?
    @Published var errorMessage: String?
    private var store: ManualEventStore?
    private let identity: () -> CloudPushIdentity?
    private let endpoint: () -> URL?
    private let session: URLSession
    private let automaticallySync: Bool
    /// When each event's context was last asked for, so the 30-second loop does not ask again too soon.
    private var contextRequestedAt: [UUID: Date] = [:]
    static let contextBatch = 25
    static let contextRetryInterval: TimeInterval = 300

    init(store: ManualEventStore? = nil, session: URLSession = .shared, automaticallySync: Bool = true,
         identity: @escaping () -> CloudPushIdentity? = { CloudPushIdentityStore.current() },
         endpoint: @escaping () -> URL? = { PlacementCloudSync.derivedEndpoint()?.appendingPathComponent("manual-events") }) {
        self.session = session
        self.automaticallySync = automaticallySync
        self.identity = identity
        self.endpoint = endpoint
        do { self.store = try store ?? ManualEventStore() }
        catch { errorMessage = "Could not open saved events. Try again after you unlock the device." }
    }

    var types: [ManualEventEntry] { entries.filter { $0.kind == .eventType && !$0.archived } }
    var presets: [ManualEventEntry] {
        entries.filter { $0.kind == .preset && !$0.archived }
            .sorted { ($0.durationMinutes ?? 0) < ($1.durationMinutes ?? 0) }
    }
    var events: [ManualEventEntry] {
        entries.filter { $0.kind == .event && !$0.archived }
            .sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning }
                return ($0.startUnixSeconds ?? 0) > ($1.startUnixSeconds ?? 0)
            }
    }
    var archived: [ManualEventEntry] {
        entries.filter(\.archived).sorted { ($0.archivedAt ?? 0) > ($1.archivedAt ?? 0) }
    }

    /// Account lifecycle calls this immediately on sign-in and sign-out, including while the tab is hidden.
    func bindAccount() {
        let next = identity()?.ownerId
        guard next != owner || (next != nil && store == nil) else { return }
        owner = next
        entries = []
        pendingIds = []
        rejected = [:]
        contexts = [:]
        staleContexts = []
        contextRequestedAt = [:]
        syncMessage = nil
        errorMessage = nil
        guard let next else { return }
        do {
            if store == nil { store = try ManualEventStore() }
            guard let store else { return }
            // Fixed UUIDs and an old timestamp make these safe to seed on another phone. A renamed or
            // archived cloud type always takes priority; the seed never resurrects it.
            for var entry in ManualEventEntry.defaultTypes + ManualEventEntry.defaultPresets {
                entry.timeZoneIdentifier = "UTC"
                try store.insert(ManualEventRevision(revisionId: entry.id, updatedAtMs: 1, entry: entry),
                                 owner: next, synced: false)
            }
            try store.retireLegacyDefaults(owner: next)
            try reload()
        } catch { errorMessage = "Could not read saved events. Your saved data was kept." }
    }

    private func reload() throws {
        guard let owner, let store else { return }
        entries = try store.latest(owner: owner)
        pendingIds = Set(try store.pending(owner: owner, limit: Int.max).map { $0.entry.id })
        rejected = try store.rejected(owner: owner)
        var decoded: [UUID: ManualEventContext] = [:]
        var stale: Set<UUID> = []
        let current = try store.latestRevisionIds(owner: owner)
        for (id, cached) in try store.contexts(owner: owner) {
            guard let context = ManualEventContext.decode(cached.body) else { continue }
            decoded[id] = context
            if current[id].map({ $0.uuidString.lowercased() != cached.revisionId }) ?? false { stale.insert(id) }
        }
        contexts = decoded
        staleContexts = stale
    }

    /// What an event counts as, resolved like the server: its own kind, else its type's current kind (the
    /// type's own field or factory default), else the factory default of its type id.
    func effectiveKind(of entry: ManualEventEntry) -> ManualEventEntry.ActivityKind? {
        if let own = entry.activityKind.flatMap(ManualEventEntry.ActivityKind.init(rawValue:)) { return own }
        guard entry.kind == .event else { return entry.effectiveActivityKind }
        if let type = entries.first(where: { $0.kind == .eventType && $0.id == entry.typeId }),
           let kind = type.effectiveActivityKind { return kind }
        return ManualEventEntry.ActivityKind.factoryDefault(for: entry.typeId)
    }

    /// The activity kind an event logged with `type` should carry: the type's own, else its factory default.
    func activityKind(for type: ManualEventEntry) -> String? {
        type.effectiveActivityKind?.rawValue
    }

    @discardableResult
    func save(_ entry: ManualEventEntry, for expectedOwner: String?) -> Bool {
        guard let owner, expectedOwner == owner, identity()?.ownerId == owner, let store else {
            errorMessage = "Sign in to your Nara account to save this event."
            return false
        }
        do {
            var entry = entry
            entry.label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.note?.isEmpty == true { entry.note = nil }
            // Every revision is kept forever and synced: saving what is already current adds nothing.
            if entries.contains(entry) { errorMessage = nil; return true }
            if entry.kind == .eventType && !entry.archived && types.contains(where: {
                $0.id != entry.id && $0.label.compare(entry.label, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                errorMessage = "An event type with this name already exists. Use that label again."
                return false
            }
            try store.save(entry, owner: owner)
            // The edit makes any context of this event out of date: ask again as soon as it has synced.
            contextRequestedAt[entry.id] = nil
            try reload()
            errorMessage = nil
            if automaticallySync { Task { await syncNow() } }
            return true
        } catch { errorMessage = "Could not save the event. Check the label and times, then try again."; return false }
    }

    func archive(_ entry: ManualEventEntry) {
        guard entries.contains(entry) else { return }
        var next = entry
        if next.isRunning { next.endUnixSeconds = max(next.startUnixSeconds ?? 0, Date().timeIntervalSince1970) }
        next.archived = true
        next.archivedAt = Date().timeIntervalSince1970
        // Keep the event's times and label in every prior revision.
        _ = save(next, for: owner)
    }

    func restore(_ entry: ManualEventEntry) {
        guard entries.contains(entry) else { return }
        var next = entry
        next.archived = false
        next.archivedAt = nil
        _ = save(next, for: owner)
    }

    func toggleFavorite(_ entry: ManualEventEntry) {
        guard entries.contains(entry) else { return }
        var next = entry
        next.favorite.toggle()
        _ = save(next, for: owner)
    }

    func stop(_ entry: ManualEventEntry) {
        guard entries.contains(entry) else { return }
        var next = entry
        next.endUnixSeconds = max(next.startUnixSeconds ?? 0, Date().timeIntervalSince1970)
        _ = save(next, for: owner)
    }

    func export() -> URL? {
        guard let owner, let store else { return nil }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("nara-events-\(UUID().uuidString).json")
            try encoder.encode(Export(schemaVersion: 1, revisions: store.history(owner: owner))).write(to: url, options: .atomic)
            return url
        } catch { errorMessage = "Could not export events. Try again."; return nil }
    }
    private struct Export: Encodable { let schemaVersion: Int; let revisions: [ManualEventRevision] }

    /// Only explicit per-revision acknowledgements mark a write synced. An unexpected reply keeps it pending.
    func syncNow() async {
        bindAccount()
        guard !syncing, let owner, let id = identity(), id.ownerId == owner, let store else { return }
        guard let url = endpoint() else { syncMessage = "Cloud sync is not configured. Events stay saved on this device."; return }
        syncing = true
        defer { syncing = false }
        do {
            // Pull the whole retained history through an account-specific cursor, including the archive.
            var pages = 0
            var allPagesRead = false
            while pages < 50 {
                guard identity()?.scope == id.scope else { return }
                let cursor = try store.cursor(owner: owner)
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "after", value: cursor)]
                var request = URLRequest(url: parts.url!, timeoutInterval: 30)
                CloudReceiverAuth.apply(id, to: &request)
                let reply: Page = try await send(request)
                guard reply.identity.userId.lowercased() == owner,
                      reply.identity.sourceId.lowercased() == id.sourceId else { throw SyncError.invalidReply }
                guard identity()?.scope == id.scope else { return }
                guard let next = Int64(reply.next), let previous = Int64(cursor), next >= previous,
                      !reply.hasMore || next > previous else { throw SyncError.invalidReply }
                // One revision this app cannot store (a conflict, or a rule it does not know) is skipped, so it
                // can never stop the rest of the history, or the uploads after it, from syncing.
                for revision in reply.revisions {
                    do { try store.insert(revision, owner: owner, synced: true) } catch {
                        NSLog("ManualEventSync: skipped cloud revision \(revision.revisionId): \(error)")
                    }
                }
                try store.setCursor(reply.next, owner: owner)
                pages += 1
                if !reply.hasMore { allPagesRead = true; break }
            }
            // Read every cloud revision before trimming a type: a later page may contain a restore.
            if allPagesRead { try store.retireLegacyDefaults(owner: owner) }
            // A bound keeps foreground work finite; pending writes resume on the next pass.
            var isolate = false
            for _ in 0..<40 {
                guard identity()?.scope == id.scope else { return }
                let batch = try store.pending(owner: owner, limit: isolate ? 1 : 25)
                if batch.isEmpty { break }
                var request = URLRequest(url: url, timeoutInterval: 30)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                CloudReceiverAuth.apply(id, to: &request)
                request.httpBody = try JSONEncoder().encode(Body(revisions: batch))
                let reply: Ack
                do { reply = try await send(request) } catch SyncError.refused(let status) {
                    // A server that refuses the whole request (one before per-item replies) is asked one
                    // revision at a time; a single refused revision is set aside so the rest can sync.
                    guard batch.count == 1 else { isolate = true; continue }
                    guard identity()?.scope == id.scope else { return }
                    try store.markRejected(owner: owner, reasons: [batch[0].revisionId: "http_\(status)"])
                    continue
                }
                let sent = Set(batch.map(\.revisionId))
                let refused = Dictionary((reply.rejected ?? []).compactMap { r in r.revisionId.map { ($0, r.reason) } },
                                         uniquingKeysWith: { a, _ in a })
                guard reply.identity.userId.lowercased() == owner,
                      reply.identity.sourceId.lowercased() == id.sourceId,
                      Set(reply.saved).isSubset(of: sent), Set(refused.keys).isSubset(of: sent),
                      Set(reply.saved).union(refused.keys) == sent else { throw SyncError.invalidReply }
                guard identity()?.scope == id.scope else { return }
                try store.markSynced(owner: owner, ids: reply.saved)
                try store.markRejected(owner: owner, reasons: refused)
            }
            guard self.owner == owner else { return }
            try reload()
            syncMessage = pendingIds.isEmpty ? nil : "Saved on this device. Cloud sync will continue."
            // Context is enrichment: a failed read leaves the events synced and is asked again later.
            try? await refreshContexts(url: url, id: id, owner: owner, store: store)
        } catch {
            guard self.owner == owner else { return }
            try? reload()
            syncMessage = (error as? SyncError) == .unsupported
                ? "Cloud event sync is not available yet. Events stay saved on this device."
                : "Saved on this device. Cloud sync will retry when the connection is ready."
        }
    }

    /// Ask the server for the context of the events that can still gain some: synced, ended or running,
    /// not archived, without a final context, and not asked about in the last five minutes. Newest first.
    private func refreshContexts(url: URL, id: CloudPushIdentity, owner: String, store: ManualEventStore) async throws {
        let now = Date()
        let wanted = events.filter { event in
            !pendingIds.contains(event.id) && rejected[event.id] == nil
                && (contexts[event.id]?.final != true || staleContexts.contains(event.id))
                && (contextRequestedAt[event.id].map { now.timeIntervalSince($0) >= Self.contextRetryInterval } ?? true)
        }.prefix(Self.contextBatch)
        guard !wanted.isEmpty else { return }
        for event in wanted { contextRequestedAt[event.id] = now }
        var parts = URLComponents(url: url.appendingPathComponent("context"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "ids", value: wanted.map { $0.id.uuidString.lowercased() }.joined(separator: ","))]
        var request = URLRequest(url: parts.url!, timeoutInterval: 30)
        CloudReceiverAuth.apply(id, to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return }
        // An older server without the route keeps the events as they are; nothing to retry sooner.
        guard (200..<300).contains(http.statusCode) else { return }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identity = root["identity"] as? [String: Any],
              (identity["userId"] as? String)?.lowercased() == owner,
              identityStillCurrent(id), let items = root["contexts"] as? [Any] else { return }
        for item in items {
            guard let body = try? JSONSerialization.data(withJSONObject: item),
                  let context = ManualEventContext.decode(body),
                  let entity = context.event?.id, let revision = context.event?.revisionId,
                  wanted.contains(where: { $0.id == entity }) else { continue }
            try store.saveContext(owner: owner, entityId: entity, revisionId: revision, body: body)
        }
        guard self.owner == owner else { return }
        try reload()
    }

    private func identityStillCurrent(_ id: CloudPushIdentity) -> Bool { identity()?.scope == id.scope }

    #if DEBUG
    /// Simulator screenshots only: show a context document without a server.
    func showContextForPreview(_ context: ManualEventContext, for id: UUID) { contexts[id] = context }
    #endif

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidReply }
        if http.statusCode == 404 || http.statusCode == 405 { throw SyncError.unsupported }
        if [400, 409, 413].contains(http.statusCode) { throw SyncError.refused(http.statusCode) }
        guard (200..<300).contains(http.statusCode) else { throw SyncError.invalidReply }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private enum SyncError: Error, Equatable { case invalidReply, unsupported, refused(Int) }
    private struct Identity: Decodable { let userId: String; let sourceId: String }
    private struct Body: Encodable { let revisions: [ManualEventRevision] }
    private struct Refusal: Decodable {
        let revisionId: UUID?; let reason: String
        enum CodingKeys: String, CodingKey { case revisionId = "revision_id", reason }
    }
    private struct Ack: Decodable { let saved: [UUID]; let rejected: [Refusal]?; let identity: Identity }
    private struct Page: Decodable {
        let revisions: [ManualEventRevision]; let next: String; let hasMore: Bool; let identity: Identity
        enum CodingKeys: String, CodingKey { case revisions, next, hasMore = "has_more", identity }
    }
}
