import Foundation
import Combine

/// The chat list behind the sidebar: threads, folders, the precomputed sections, search, and the optimistic
/// edits (`docs/COACH_MEMORY.md` §7.1). The sidebar observes this store and never the view model, so a streaming
/// reply does not redraw the drawer. Actions that touch the open conversation (open, new chat, delete) go through
/// the `onOpen`, `onNewChat` and `onDelete` hooks, which `CoachChatViewModel` sets.
///
/// Every edit is applied locally first and rolled back if the server refuses it. The list is cached per owner
/// in `threads.json`, so the drawer draws before the network answers.
@MainActor
final class CoachThreadStore: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, failed }

    @Published private(set) var threads: [CoachThread] = [] { didSet { rebuildSections() } }
    @Published private(set) var folders: [CoachFolder] = [] { didSet { rebuildSections() } }
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

    static let pageSize = 50
    static let searchDebounce: TimeInterval = 0.3

    private let api: CoachAPI
    private let now: () -> Date
    private(set) var local: CoachLocalStore?
    private var nextCursor: String?
    private var searchTask: Task<Void, Never>?
    /// Deleted this session: a server page that races the delete must not bring them back.
    private var deletedIds = Set<String>()
    private var generation = 0

    init(api: CoachAPI = .shared, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.now = now
    }

    // MARK: Owner

    /// Empties the store and loads `local`'s cached list: a sign-in as another account never shows the last one's chats.
    func reset(local: CoachLocalStore?, features: CoachFeatures) {
        generation += 1
        searchTask?.cancel()
        self.local = local
        self.features = features
        isEnabled = features.threads
        deletedIds = []
        nextCursor = nil
        hasMore = false
        isLoadingMore = false
        searchResults = nil
        isSearching = false
        errorMessage = nil
        currentThreadId = nil
        phase = .idle
        if query != "" { query = "" }
        let snapshot = local?.loadThreads()
        folders = snapshot?.folders ?? []
        threads = snapshot?.threads ?? []
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

    /// The first page from the server. Rows the phone created that the server does not list yet are kept.
    func refresh() async {
        guard isEnabled else { return }
        let gen = generation
        phase = threads.isEmpty ? .loading : phase
        do {
            let page = try await api.threads(limit: Self.pageSize)
            guard gen == generation else { return }
            let listed = Set(page.threads.map(\.id))
            let pending = threads.filter { $0.localOnly == true && !listed.contains($0.id) }
            folders = page.folders
            threads = page.threads.filter { !deletedIds.contains($0.id) }.map(screened) + pending
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
        return threads.filter { t in
            [t.title, t.preview].compactMap { $0 }.contains {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
            }
        }
        .sorted { ($0.activityDate ?? .distantPast) > ($1.activityDate ?? .distantPast) }
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

    /// Removes the row at once and on the server. A thread the server never saw needs no call.
    @discardableResult
    func delete(id: String) async -> Bool {
        let key = id.lowercased()
        deletedIds.insert(key)
        let removed = threads.first { $0.id == key }
        threads.removeAll { $0.id == key }
        searchResults?.removeAll { $0.id == key }
        local?.removeThread(id: key)
        persist()
        guard isEnabled, removed?.localOnly != true else { return true }
        do {
            try await api.deleteThread(id: key)
            return true
        } catch let error as CoachRouteError where error.status == 404 || error.status == 410 {
            return true
        } catch {
            deletedIds.remove(key)
            if let removed, !threads.contains(where: { $0.id == key }) {
                threads.append(removed)
                persist()
            }
            errorMessage = "Couldn't delete that chat. Try again."
            return false
        }
    }

    /// Local only: the row of a thread the server refused to save.
    func remove(id: String) {
        let key = id.lowercased()
        threads.removeAll { $0.id == key }
        persist()
    }

    /// The optimistic row a send creates or moves to the top: new threads are `localOnly` until the server lists them.
    func touch(id: String, title: String?, titleSource: String? = nil, preview: String?, at date: Date,
               addedMessages: Int = 1) {
        let key = id.lowercased()
        let stamp = CoachDates.string(date)
        if let i = threads.firstIndex(where: { $0.id == key }) {
            var t = threads[i]
            if t.title == nil, let title { t.title = title; t.titleSource = titleSource ?? t.titleSource }
            if let preview { t.preview = String(CoachModelText.collapsed(preview).prefix(160)) }
            t.lastMessageAt = stamp
            t.updatedAt = stamp
            t.messageCount += addedMessages
            t.pendingMessages += addedMessages
            threads[i] = t
        } else {
            threads.append(CoachThread(id: key, title: title, titleSource: titleSource ?? (title == nil ? "none" : "fallback"),
                                       origin: "app", createdAt: stamp, updatedAt: stamp, lastMessageAt: stamp,
                                       messageCount: addedMessages,
                                       preview: preview.map { String(CoachModelText.collapsed($0).prefix(160)) },
                                       pendingMessages: addedMessages, localOnly: true))
        }
        deletedIds.remove(key)
        persist()
    }

    /// The server has saved rows of this thread.
    func markSaved(id: String) {
        let key = id.lowercased()
        guard let i = threads.firstIndex(where: { $0.id == key }), threads[i].localOnly == true else { return }
        threads[i].localOnly = nil
        persist()
        // Edits made before the server knew the thread were local only; send them now.
        let t = threads[i]
        guard isEnabled, t.hasUserTitle || t.pinned || t.folderId != nil else { return }
        let api = self.api
        Task {
            _ = try? await api.updateThread(id: key, title: t.hasUserTitle ? t.title : nil,
                                            folderId: t.folderId.map { .some($0) }, pinned: t.pinned ? true : nil)
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

    private func persist() {
        guard isEnabled, let local else { return }
        local.saveThreads(CoachThreadsSnapshot(threads: threads, folders: folders, nextCursor: nextCursor, hasMore: hasMore,
                                               savedAt: now(), features: features))
    }
}
