import Foundation
import Combine

/// The chat list behind the sidebar: threads, folders, the precomputed sections, search, and the optimistic
/// edits (`docs/COACH_MEMORY.md` §7.1). The sidebar observes this store and never the view model, so a streaming
/// reply does not redraw the drawer. Actions that touch the open conversation (open, new chat, delete, rename)
/// go through the `onOpen`, `onNewChat`, `onDelete` and `onRename` hooks, which `CoachChatViewModel` sets; the
/// sidebar calls `select`, `requestNewChat`, `requestDelete` and `requestRename`.
///
/// Every edit is applied locally first and rolled back if the server refuses it. The list is cached per owner
/// in `threads.json`, so the drawer draws before the network answers; the file is written once per main-actor
/// turn, off the main thread.
@MainActor
final class CoachThreadStore: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, failed }

    @Published private(set) var threads: [CoachThread] = [] { didSet { if !batching { rebuildSections() } } }
    @Published private(set) var folders: [CoachFolder] = [] { didSet { if !batching { rebuildSections() } } }
    @Published private(set) var sections: [CoachThreadSection] = []
    /// Nil while no search is active; otherwise the local title matches, replaced by the server's ranked hits.
    @Published private(set) var searchResults: [CoachThread]?
    @Published private(set) var isSearching = false
    /// Bound to the search field; every change runs `search(_:)`.
    @Published var query = "" { didSet { if query != oldValue { search(query) } } }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hasMore = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    /// The open conversation, for the `.isSelected` trait.
    @Published var currentThreadId: String?
    /// False while a reply streams: rows can't be opened and New chat is disabled.
    @Published var canSwitchThreads = true
    /// The server has the thread routes. Without them the store stays empty and never touches the network.
    @Published private(set) var isEnabled = false
    /// The server's features as last seen, cached with the list so the next launch knows them before `status`.
    private(set) var features: CoachFeatures = .none
    /// Generated titles pass the safety screens before they are shown; the age picks the stricter rules.
    var userAge: Int?

    var onOpen: ((CoachThread) -> Void)?
    var onNewChat: (() -> Void)?
    var onDelete: ((String) -> Void)?
    /// `(id, title)`: the view model renames, so the header follows the row and is restored if the server refuses.
    var onRename: ((String, String) -> Void)?

    static let pageSize = 50
    static let searchDebounce: TimeInterval = 0.3

    private let api: CoachAPI
    private let now: () -> Date
    private(set) var local: CoachLocalStore?
    private var nextCursor: String?
    private var searchTask: Task<Void, Never>?
    /// Deleted this session: a server page that races the delete must not bring them back.
    private var deletedIds = Set<String>()
    /// Deletes the server has not confirmed (a local-only chat's DELETE failed). Persisted with the list, kept out
    /// of every page, and retried by `retryPendingDeletes()` before the next flush.
    private(set) var pendingDeletes = Set<String>()
    private var retryingDeletes = false
    private var generation = 0
    /// Set while one change assigns both `threads` and `folders`, so the sections are rebuilt once.
    private var batching = false
    /// The coalesced `threads.json` write for this main-actor turn.
    private var writeScheduled = false
    /// One serial queue for every store's writes: they land in order, and `flushWrites()` can wait for them.
    private static let writer = DispatchQueue(label: "noop.coach.threads-writer", qos: .utility)

    init(api: CoachAPI = .shared, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.now = now
    }

    // MARK: Owner

    /// Empties the store and loads `local`'s cached list (`snapshot` when the caller has already read it): a sign-in
    /// as another account never shows the last one's chats. The previous owner's pending write lands first.
    func reset(local: CoachLocalStore?, features: CoachFeatures, snapshot preloaded: CoachThreadsSnapshot?? = nil) {
        flushWrites()
        generation += 1
        searchTask?.cancel()
        self.local = local
        self.features = features
        isEnabled = features.threads
        nextCursor = nil
        hasMore = false
        isLoadingMore = false
        searchResults = nil
        isSearching = false
        errorMessage = nil
        currentThreadId = nil
        phase = .idle
        if query != "" { query = "" }
        let snapshot = preloaded ?? local?.loadThreads()
        pendingDeletes = Set(snapshot?.pendingDeletes ?? [])
        deletedIds = pendingDeletes
        batch {
            folders = snapshot?.folders ?? []
            threads = (snapshot?.threads ?? []).filter { !pendingDeletes.contains($0.id) }
        }
        nextCursor = snapshot?.nextCursor
        hasMore = snapshot?.hasMore ?? false
    }

    /// Turns the thread routes on or off once the server's features are known.
    func setFeatures(_ features: CoachFeatures) {
        guard features != self.features else { return }
        self.features = features
        isEnabled = features.threads
        persist()
    }

    func thread(id: String) -> CoachThread? {
        let key = id.lowercased()
        return threads.first { $0.id == key }
    }

    // MARK: Loading

    /// The first page from the server. Rows the phone created that the server does not list yet are kept: those
    /// still local-only, and those that were local-only or touched when the request went out (a save can land,
    /// and clear `localOnly`, after the server read its list).
    func refresh() async {
        guard isEnabled else { return }
        let gen = generation
        let pendingAtRequest = Set(threads.filter { $0.localOnly == true }.map(\.id))
        let requestedAt = now()
        phase = threads.isEmpty ? .loading : phase
        do {
            let page = try await api.threads(limit: Self.pageSize)
            guard gen == generation else { return }
            let listed = Set(page.threads.map(\.id))
            let pending = threads.filter { t in
                guard !listed.contains(t.id), !deletedIds.contains(t.id) else { return false }
                return t.localOnly == true || pendingAtRequest.contains(t.id) || (t.activityDate ?? .distantPast) >= requestedAt
            }
            batch {
                folders = page.folders
                threads = page.threads.filter { !deletedIds.contains($0.id) }.map(screened) + pending
            }
            nextCursor = page.nextCursor
            hasMore = page.hasMore && page.nextCursor != nil
            phase = .ready
            persist()
        } catch {
            guard gen == generation else { return }
            phase = threads.isEmpty ? .failed : .ready
        }
    }

    func loadMore() async {
        guard isEnabled, hasMore, !isLoadingMore, let cursor = nextCursor else { return }
        let gen = generation
        isLoadingMore = true
        defer { if gen == generation { isLoadingMore = false } }
        guard let page = try? await api.threads(limit: Self.pageSize, cursor: cursor), gen == generation else { return }
        let known = Set(threads.map(\.id))
        threads += page.threads.filter { !known.contains($0.id) && !deletedIds.contains($0.id) }.map(screened)
        nextCursor = page.nextCursor
        hasMore = page.hasMore && page.nextCursor != nil
        persist()
    }

    // MARK: Search

    /// Cached titles are filtered at once; the server's ranked search follows after a 300 ms pause in typing.
    func search(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = nil
            isSearching = false
            return
        }
        searchResults = localMatches(q)
        guard isEnabled else { return }
        isSearching = true
        let gen = generation
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.searchDebounce * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let hits = try? await self.api.searchThreads(query: q)
            guard !Task.isCancelled, gen == self.generation,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q || self.query.isEmpty else { return }
            self.isSearching = false
            guard let hits else { return }
            let ranked = hits.filter { !self.deletedIds.contains($0.id) }.map(self.screened)
            let rankedIds = Set(ranked.map(\.id))
            self.searchResults = ranked + self.localMatches(q).filter { !rankedIds.contains($0.id) }
        }
    }

    /// Stores the query in the user's recent searches (used for starter suggestions). Called when a search is
    /// submitted or one of its results is opened.
    func recordSearch(_ text: String? = nil) {
        let q = (text ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, q.count >= 3 else { return }
        let api = self.api
        Task { _ = try? await api.searchThreads(query: q, record: true) }
    }

    func localMatches(_ q: String) -> [CoachThread] {
        let needle = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let hits = threads.filter { t in
            [t.title, t.preview].compactMap { $0 }.contains {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
            }
        }
        return CoachThreadSections.newestFirstWithDates(hits).map(\.thread)
    }

    // MARK: Intents (sidebar → view model)

    func select(_ thread: CoachThread) {
        guard canSwitchThreads else { return }
        if searchResults != nil { recordSearch() }
        onOpen?(thread)
    }

    func requestNewChat() {
        guard canSwitchThreads else { return }
        onNewChat?()
    }

    func requestDelete(id: String) { onDelete?(id.lowercased()) }

    /// The sidebar's rename. Through the view model when it is listening (the header follows, and is restored if
    /// the server refuses); otherwise straight to `rename`.
    func requestRename(id: String, title: String) {
        if let onRename {
            onRename(id.lowercased(), title)
        } else {
            Task { await rename(id: id, title: title) }
        }
    }

    // MARK: Optimistic edits

    @discardableResult
    func rename(id: String, title raw: String) async -> Bool {
        let title = CoachModelText.collapsed(raw)
        guard (1...120).contains(title.count) else { return false }
        return await edit(id: id, change: { $0.title = title; $0.titleSource = "user" }) {
            try await $0.updateThread(id: id, title: title)
        }
    }

    /// `folderId` nil takes the thread out of its folder.
    @discardableResult
    func move(id: String, folderId: String?) async -> Bool {
        let folder = folderId?.lowercased()
        return await edit(id: id, change: { $0.folderId = folder }) {
            try await $0.updateThread(id: id, folderId: .some(folder))
        }
    }

    @discardableResult
    func setPinned(id: String, _ pinned: Bool) async -> Bool {
        await edit(id: id, change: { $0.pinned = pinned }) { try await $0.updateThread(id: id, pinned: pinned) }
    }

    /// Removes the row at once and on the server. The server is asked even for a chat still marked local-only:
    /// its save may already have landed (a lost response, a launch flush of an earlier session's rows) or still be
    /// in flight, and the server tombstones an id it has never seen, so a late save can't bring the chat back.
    /// True when the chat is gone for the user: deleted, or local-only with the DELETE left in `pendingDeletes`
    /// to retry. False (the row is put back) when the server still has a chat it refused to delete.
    @discardableResult
    func delete(id: String) async -> Bool {
        let key = id.lowercased()
        let gen = generation, local = self.local
        deletedIds.insert(key)
        let removed = threads.first { $0.id == key }
        threads.removeAll { $0.id == key }
        searchResults?.removeAll { $0.id == key }
        persist()
        guard isEnabled else {
            local?.removeThread(id: key)
            return true
        }
        do {
            try await api.deleteThread(id: key)
            local?.removeThread(id: key)
            return true
        } catch let error as CoachRouteError where error.status == 404 || error.status == 410 {
            local?.removeThread(id: key)
            return true
        } catch {
            guard gen == generation else { return false }
            if removed?.localOnly == true {
                // Nothing to put back: the user deleted a chat that only this phone knew for sure.
                pendingDeletes.insert(key)
                local?.removeThread(id: key)
                persist()
                return true
            }
            // The server still has the chat: it comes back, with its cached messages untouched.
            deletedIds.remove(key)
            if let removed, !threads.contains(where: { $0.id == key }) {
                threads.append(removed)
                persist()
            }
            errorMessage = "Couldn't delete that chat. Try again."
            return false
        }
    }

    /// Sends the deletes that failed earlier. Each leaves `pendingDeletes` once the server confirms it (or never
    /// had the chat); the rest wait for the next flush.
    func retryPendingDeletes() async {
        guard isEnabled, !pendingDeletes.isEmpty, !retryingDeletes else { return }
        retryingDeletes = true
        defer { retryingDeletes = false }
        let gen = generation
        for key in pendingDeletes.sorted() {
            do {
                try await api.deleteThread(id: key)
            } catch let error as CoachRouteError where error.status == 404 || error.status == 410 {
            } catch {
                continue
            }
            guard gen == generation else { return }
            pendingDeletes.remove(key)
        }
        persist()
    }

    /// Local only: the row of a thread the server refused to save, or deleted elsewhere.
    func remove(id: String) {
        let key = id.lowercased()
        deletedIds.insert(key)
        threads.removeAll { $0.id == key }
        searchResults?.removeAll { $0.id == key }
        persist()
    }

    /// Deleted on this phone this session (or waiting for the server to confirm a delete).
    func isDeleted(_ id: String) -> Bool { deletedIds.contains(id.lowercased()) }

    /// The optimistic row a send creates or moves to the top: a new thread is `localOnly` until the server lists
    /// it, unless `knownOnServer` (a server thread opened from search that the loaded pages do not hold). A thread
    /// deleted this session is never brought back.
    func touch(id: String, title: String?, titleSource: String? = nil, preview: String?, at date: Date,
               addedMessages: Int = 1, knownOnServer: Bool = false) {
        let key = id.lowercased()
        guard !deletedIds.contains(key) else { return }
        let stamp = CoachDates.string(date)
        if let i = threads.firstIndex(where: { $0.id == key }) {
            var t = threads[i]
            if t.title == nil, let title { t.title = title; t.titleSource = titleSource ?? t.titleSource }
            if let preview { t.preview = String(CoachModelText.collapsed(preview).prefix(160)) }
            t.lastMessageAt = stamp
            t.updatedAt = stamp
            t.messageCount += addedMessages
            t.pendingMessages += addedMessages
            if t.needsMaintenance != nil { t.needsMaintenance = true }
            threads[i] = t
        } else {
            threads.append(CoachThread(id: key, title: title, titleSource: titleSource ?? (title == nil ? "none" : "fallback"),
                                       origin: "app", createdAt: stamp, updatedAt: stamp, lastMessageAt: stamp,
                                       messageCount: addedMessages,
                                       preview: preview.map { String(CoachModelText.collapsed($0).prefix(160)) },
                                       pendingMessages: addedMessages, localOnly: knownOnServer ? nil : true))
        }
        persist()
    }

    /// The server has saved rows of this thread.
    func markSaved(id: String) {
        let key = id.lowercased()
        guard let i = threads.firstIndex(where: { $0.id == key }), threads[i].localOnly == true else { return }
        threads[i].localOnly = nil
        persist()
        // Edits made before the server knew the thread were local only; send them now, and take the server's row
        // back (a refresh that raced them may have put the server's older copy in the list).
        let t = threads[i]
        guard isEnabled, t.hasUserTitle || t.pinned || t.folderId != nil else { return }
        let api = self.api
        let gen = generation
        Task { [weak self] in
            guard let saved = try? await api.updateThread(id: key, title: t.hasUserTitle ? t.title : nil,
                                                          folderId: t.folderId.map { .some($0) }, pinned: t.pinned ? true : nil),
                  let self, gen == self.generation else { return }
            self.apply(saved)
        }
    }

    /// A generated title, never over one the user typed.
    func setTitle(id: String, title: String, source: String = "auto") {
        let key = id.lowercased()
        guard let i = threads.firstIndex(where: { $0.id == key }), !threads[i].hasUserTitle || source == "user" else { return }
        threads[i].title = title
        threads[i].titleSource = source
        persist()
    }

    /// The server's view of one thread (after a PATCH, say), keeping a local-only marker it can't know about.
    func apply(_ thread: CoachThread) {
        guard !deletedIds.contains(thread.id) else { return }
        let thread = screened(thread)
        if let i = threads.firstIndex(where: { $0.id == thread.id }) {
            var t = thread
            t.snippet = threads[i].snippet
            threads[i] = t
        } else {
            threads.append(thread)
        }
        persist()
    }

    func markMaintained(id: String) {
        let key = id.lowercased()
        guard let i = threads.firstIndex(where: { $0.id == key }) else { return }
        threads[i].pendingMessages = 0
        if threads[i].needsMaintenance != nil { threads[i].needsMaintenance = false }
        persist()
    }

    // MARK: Folders

    @discardableResult
    func createFolder(name raw: String) async -> CoachFolder? {
        let name = CoachModelText.collapsed(raw)
        guard (1...60).contains(name.count) else { return nil }
        let stamp = CoachDates.string(now())
        let folder = CoachFolder(id: UUID().uuidString.lowercased(), name: name,
                                 sortOrder: (folders.map(\.sortOrder).max() ?? -1) + 1, createdAt: stamp, updatedAt: stamp)
        folders.append(folder)
        persist()
        guard isEnabled else { return folder }
        do {
            let saved = try await api.createFolder(id: folder.id, name: name)
            if let i = folders.firstIndex(where: { $0.id == folder.id }) { folders[i] = saved }
            persist()
            return saved
        } catch {
            folders.removeAll { $0.id == folder.id }
            persist()
            errorMessage = "Couldn't create that folder. Try again."
            return nil
        }
    }

    @discardableResult
    func renameFolder(id: String, name raw: String) async -> Bool {
        let key = id.lowercased(), name = CoachModelText.collapsed(raw)
        guard (1...60).contains(name.count), let i = folders.firstIndex(where: { $0.id == key }) else { return false }
        let before = folders[i]
        folders[i].name = name
        persist()
        guard isEnabled else { return true }
        do {
            let saved = try await api.updateFolder(id: key, name: name)
            if let j = folders.firstIndex(where: { $0.id == key }) { folders[j] = saved }
            persist()
            return true
        } catch {
            if let j = folders.firstIndex(where: { $0.id == key }) { folders[j] = before }
            persist()
            errorMessage = "Couldn't rename that folder. Try again."
            return false
        }
    }

    /// The folder goes; its chats stay, out of any folder.
    @discardableResult
    func deleteFolder(id: String) async -> Bool {
        let key = id.lowercased()
        guard let folder = folders.first(where: { $0.id == key }) else { return false }
        let members = threads.filter { $0.folderId == key }.map(\.id)
        folders.removeAll { $0.id == key }
        threads = threads.map { t in var t = t; if t.folderId == key { t.folderId = nil }; return t }
        persist()
        guard isEnabled else { return true }
        do {
            try await api.deleteFolder(id: key)
            return true
        } catch let error as CoachRouteError where error.status == 404 {
            return true
        } catch {
            folders.append(folder)
            threads = threads.map { t in var t = t; if members.contains(t.id) { t.folderId = key }; return t }
            persist()
            errorMessage = "Couldn't delete that folder. Try again."
            return false
        }
    }

    // MARK: Private

    private func edit(id: String, change: (inout CoachThread) -> Void,
                      send: (CoachAPI) async throws -> CoachThread) async -> Bool {
        let key = id.lowercased()
        guard let i = threads.firstIndex(where: { $0.id == key }) else { return false }
        let before = threads[i]
        change(&threads[i])
        persist()
        guard isEnabled, before.localOnly != true else { return true }
        do {
            let saved = screened(try await send(api))
            if let j = threads.firstIndex(where: { $0.id == key }) {
                var merged = saved
                merged.snippet = threads[j].snippet
                // A later local edit of the same row wins over this older reply.
                change(&merged)
                threads[j] = merged
            }
            persist()
            return true
        } catch {
            if let j = threads.firstIndex(where: { $0.id == key }) { threads[j] = before }
            persist()
            errorMessage = "Couldn't update that chat. Try again."
            return false
        }
    }

    /// A generated title that fails the screens is dropped, so the row falls back to its preview. A title the
    /// user typed is theirs and stays.
    private func screened(_ thread: CoachThread) -> CoachThread {
        guard let title = thread.title, !thread.hasUserTitle else { return thread }
        var t = thread
        t.title = CoachModelText.title(title, userAge: userAge)
        return t
    }

    private func rebuildSections() {
        sections = CoachThreadSections.sections(threads: threads, folders: folders, now: now())
    }

    /// Assigns `threads` and `folders` together with a single rebuild of the sections.
    private func batch(_ change: () -> Void) {
        batching = true
        change()
        batching = false
        rebuildSections()
    }

    /// Marks the cached list dirty. Every change in one main-actor turn shares one write, which is encoded and
    /// written on the background writer.
    private func persist() {
        guard isEnabled, local != nil, !writeScheduled else { return }
        writeScheduled = true
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self, self.writeScheduled, gen == self.generation else { return }
            self.writeNow()
        }
    }

    private func writeNow() {
        writeScheduled = false
        guard isEnabled, let local else { return }
        let snapshot = CoachThreadsSnapshot(threads: threads, folders: folders, nextCursor: nextCursor, hasMore: hasMore,
                                            savedAt: now(), features: features,
                                            pendingDeletes: pendingDeletes.isEmpty ? nil : pendingDeletes.sorted())
        Self.writer.async { local.saveThreads(snapshot) }
    }

    /// Writes a pending change now and waits until every queued write has reached the disk (owner change,
    /// sign-out, tests).
    func flushWrites() {
        if writeScheduled { writeNow() }
        Self.waitForWrites()
    }

    /// Waits until every store's queued `threads.json` write has landed (before an account's folder is deleted).
    static func waitForWrites() { writer.sync {} }
}
