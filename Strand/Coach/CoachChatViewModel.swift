import Combine
import Foundation
import WhoopStore

// CoachChatViewModel — the Sana conversation: safety screens, the photo pipeline, the streaming tool loop, the
// thread the user is in, and persistence through the per-owner outbox (`docs/COACH_MEMORY.md` §7.3).
//
// API for the views (everything is main-actor):
//   State      messages, isGenerating, phase, connection, errorMessage, wasScrubbed, deepMode, pendingImage,
//              memories, isLoadingMemories,
//              threadId (the open thread; `.id(threadId)` resets the composer), threadTitle (nil = "Your health
//              assistant"), threadPhase (.loading while a thread's server page loads; show a placeholder only
//              when `messages` is also empty), hasEarlier / isLoadingEarlier ("Load earlier"),
//              starterSuggestions (the welcome chips), features (`threads` gates the sidebar and titles, `context`
//              the history tools), canSwitchThreads (false while a reply streams).
//   Sidebar    `threadStore` (observe it directly; never observe the view model from the drawer).
//   Lifecycle  attach(repo:engine:profile:) then `await start()`; both are safe to repeat. attach() also notices a
//              change of account and resets everything to that account's caches.
//   Chat       send(_:) -> Bool (false: nothing sent, keep the draft), stop(), retryStalled(),
//              followUps(for:) -> [String] (the pills under an answer), selectSuggestion(_:),
//              queuePrompt(_:) -> Bool (Today launcher, Siri, --coach-prompt: a new chat, after any running reply;
//              clear `pendingPrompt` only when it returns true), noteUserInteraction().
//   Threads    newChat(), open(_:) async, loadEarlier() async, deleteThread(id:) async,
//              renameThread(id:title:) async, moveThread(id:folderId:) async, setPinned(id:_:) async,
//              createFolder(name:) async, renameFolder(id:name:) async, deleteFolder(id:) async.
//   Memory     refreshMemories() async (up to 200), forget(_:) async, forgetAllMemories() async.

struct CoachChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }

    /// Also the row's `clientId` on the server.
    let id: UUID
    let role: Role
    var content: String
    var isStreaming = false
    var imageData: Data?
    /// A restored message whose photo was not kept; the bubble shows a marker instead of the picture.
    var hadImage = false
    var toolNames: [String] = []
    /// Streamed reasoning and the tool rounds that interleaved with it, shown as the expandable trace.
    var thinking = ""
    var toolMarks: [CoachToolMark] = []
    var thinkingDuration: TimeInterval?
    /// The designed, fact-checked visual drawn beneath the answer, and where its generation stands.
    var viz: CoachViz?
    var vizPhase: CoachVizPhase = .none
    /// Cut short by the stall watchdog; shows Retry instead of passing a partial answer off as final.
    var didStall = false
    var createdAt = Date()
    /// Model-written next questions for this answer, already screened; nil until they arrive.
    var followUps: [String]?
    /// A turn `CoachSafety.screenInput` refused, and its refusal. Kept out of summaries, memory and suggestions.
    var blocked = false
    /// What the vision model saw in this question's photo (at most 1,200 characters).
    var imageContext: String?

    init(id: UUID = UUID(), role: Role, content: String, isStreaming: Bool = false, imageData: Data? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.imageData = imageData
        self.hadImage = imageData != nil
    }

    var clientId: String { id.uuidString.lowercased() }

    /// A stored row as the chat shows it; nil for a row the phone can't place (an unknown role or a non-UUID id).
    init?(stored row: CoachStoredMessage) {
        guard let role = Role(rawValue: row.role), let id = UUID(uuidString: row.clientId) else { return nil }
        self.init(id: id, role: role, content: row.content)
        let meta = row.meta
        hadImage = meta?.hadImage ?? false
        toolNames = meta?.toolNames ?? []
        if let viz = meta?.viz, viz.isRenderable {
            self.viz = viz
            vizPhase = .ready
        }
        followUps = meta?.followUps
        blocked = meta?.blocked ?? false
        imageContext = meta?.imageContext
        createdAt = CoachDates.parse(row.createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// Everything known about the message, so a re-save never blanks a field an earlier save carried.
    var meta: CoachMessageMeta {
        CoachMessageMeta(toolNames: toolNames.isEmpty ? nil : toolNames, viz: viz, hadImage: hadImage ? true : nil,
                         followUps: followUps, blocked: blocked ? true : nil, imageContext: imageContext)
    }

    func stored(threadId: String, threadTitle: String? = nil) -> CoachStoredMessage {
        CoachStoredMessage(clientId: clientId, role: role.rawValue, content: content, meta: meta,
                           createdAt: CoachDates.string(createdAt), threadId: threadId.lowercased(), threadTitle: threadTitle)
    }

    /// The server's copy of this message over the local one: content and meta from the server, while the
    /// in-memory parts (the photo, the reasoning trace) stay. A message still streaming is left alone.
    func merged(withServer server: CoachChatMessage) -> CoachChatMessage {
        guard !isStreaming else { return self }
        var out = self
        if !server.content.isEmpty { out.content = server.content }
        if !server.toolNames.isEmpty { out.toolNames = server.toolNames }
        if let viz = server.viz { out.viz = viz; out.vizPhase = .ready }
        out.hadImage = hadImage || server.hadImage
        out.followUps = server.followUps ?? followUps
        out.blocked = blocked || server.blocked
        out.imageContext = server.imageContext ?? imageContext
        out.createdAt = server.createdAt
        return out
    }
}

/// Where a tool round happened in the reasoning stream, so the trace can interleave findings with lookups.
struct CoachToolMark: Equatable {
    let offset: Int
    let labels: [String]
    /// What the model said just before calling the tools ("I'll pull up your sleep data"). Shown as a step in
    /// the reasoning block, never as answer text.
    var note: String = ""
}

enum CoachThinkingPhase {
    case idle, analyzingImage, lookingUpData, generating

    var label: String {
        switch self {
        case .idle: return ""
        case .analyzingImage: return "Analyzing image…"
        case .lookingUpData: return "Looking up your data…"
        case .generating: return "Sana is thinking…"
        }
    }
}

enum CoachConnection: Equatable {
    case checking, online
    case offline(String)
}

/// Whether the open thread's server page has arrived. Cached messages show during `.loading`.
enum CoachThreadPhase: Equatable {
    case loading, ready
}

/// Drives the coach conversations: safety screens, the photo pipeline, the streaming tool loop, the open thread,
/// memory, and persistence to the user's cloud project.
@MainActor
final class CoachChatViewModel: ObservableObject {
    @Published private(set) var messages: [CoachChatMessage] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var phase: CoachThinkingPhase = .idle
    @Published private(set) var connection: CoachConnection = .checking
    @Published private(set) var memories: [CoachMemory] = []
    @Published private(set) var isLoadingMemories = false
    @Published private(set) var wasScrubbed = false
    @Published var errorMessage: String?
    @Published var deepMode = false
    @Published var pendingImage: Data?

    @Published private(set) var threadId = UUID()
    @Published private(set) var threadTitle: String?
    @Published private(set) var threadPhase: CoachThreadPhase = .ready
    @Published private(set) var hasEarlier = false
    @Published private(set) var isLoadingEarlier = false
    @Published private(set) var starterSuggestions: [CoachStarterSuggestion] = []
    @Published private(set) var features: CoachFeatures = .none
    /// Answers whose model follow-ups are still on their way; the keyword fallback waits for them.
    @Published private var followUpsWaiting: Set<UUID> = []

    /// The chat list. The sidebar observes it directly.
    let threadStore: CoachThreadStore

    var canSwitchThreads: Bool { !isGenerating }

    static let maxToolRounds = 4
    private static let toolRoundTokens = 1_200
    private static let answerTokens = 4_096
    private static let historyWindow = CoachContextPrompt.historyWindow
    private static let historyAssistantChars = 2_500
    private static let toolPayloadCap = 10_000
    private static let flushInterval: TimeInterval = 0.04
    /// In a round where tools are on offer, the opening of the reply is held this many characters before it
    /// shows as the answer. A tool call ends a round, and whatever came before it is narration, not answer; the
    /// stream only says so at the end, so a short preamble is kept out of the bubble instead of flashing in it.
    private static let preambleHold = 180
    private static let stallGrace: TimeInterval = 45
    /// Tools can run longer than a token gap; this keeps the stall watchdog from firing mid-tool.
    static let toolHeartbeat: TimeInterval = 5
    static let pageSize = 60
    /// A turn waits this long for a fresh manifest before it uses the cached one.
    static let manifestWait: TimeInterval = 1.2
    static let imageContextCap = 1_200
    static let memoryListLimit = 200
    private static let quietBeforeMaintain: TimeInterval = 600
    private static let suggestionPrefetchInterval: TimeInterval = 900

    private let api: CoachAPI
    private let baseDirectory: URL?
    private let now: () -> Date
    private let followUpFallbackDelay: TimeInterval
    private let readsDeviceHistory: Bool
    private var repo: Repository?
    private var engine: AICoachEngine?
    private var profile: ProfileStore?

    private var attached = false
    private var ownerId: String?
    private var local: CoachLocalStore?
    private var outbox: CoachOutbox?
    private var started = false

    private struct Turn {
        let assistantId: UUID
        let userId: UUID
        let threadId: String
        let question: String
        let image: Data?
        let isFirstTurn: Bool
    }

    private var turn: Turn?
    private var streamTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastActivity = Date()
    private var lastImage: Data?
    private var memoriesStale = false
    /// Background work tied to one answer, with the thread it belongs to so deleting the thread cancels it.
    private var visualTasks: [UUID: (thread: String, task: Task<Void, Never>)] = [:]
    private var followUpTasks: [UUID: (thread: String, task: Task<Void, Never>)] = [:]

    /// Changes whenever the open thread does, so a late page for the previous thread is dropped.
    private var openToken = UUID()
    private var earlierCursor: String?
    /// The open thread has rows on the server (it was opened from the list, or a send was saved).
    private var threadOnServer = false
    private var threadTitleSource: String?
    private var launchThread: CoachThread?
    private var deletedThreads = Set<String>()
    /// Which thread each queued client id belongs to, to mark threads saved after a flush.
    private var rowThreads: [String: String] = [:]
    private var manifestCache: [String: CoachContextManifest] = [:]
    private var queuedPrompts: [String] = []

    private var suggestionsShownAt = Date.distantPast
    private var lastSuggestionPrefetch = Date.distantPast
    private var userTouched = false
    private var workoutCount: Int?
    private var journalDayCount: Int?
    private var workoutStamps: [CoachWorkoutStamp] = []
    private var cancellables = Set<AnyCancellable>()

    /// `baseDirectory` replaces Application Support for the per-owner caches (tests); `readsDeviceHistory` false
    /// keeps the workout and journal counts from opening the wearable database (tests).
    init(api: CoachAPI = .shared, baseDirectory: URL? = nil, now: @escaping () -> Date = Date.init,
         followUpFallbackDelay: TimeInterval = 4,
         readsDeviceHistory: Bool = true) {
        self.api = api
        self.baseDirectory = baseDirectory
        self.now = now
        self.followUpFallbackDelay = followUpFallbackDelay
        self.readsDeviceHistory = readsDeviceHistory
        threadStore = CoachThreadStore(api: api, now: now)
        threadStore.onOpen = { [weak self] thread in Task { await self?.open(thread) } }
        threadStore.onNewChat = { [weak self] in self?.newChat() }
        threadStore.onDelete = { [weak self] id in Task { await self?.deleteThread(id: id) } }
        // A rename from the sidebar retitles the header too.
        threadStore.$threads
            .sink { [weak self] threads in self?.syncTitle(from: threads) }
            .store(in: &cancellables)
    }

    /// Age drives the stricter under-18 rules; the profile always holds a date of birth.
    private var userAge: Int? { profile?.age }

    private var threadKey: String { threadId.uuidString.lowercased() }

    private static var locale: String { Bundle.main.preferredLocalizations.first ?? "en" }

    // MARK: Lifecycle

    func attach(repo: Repository, engine: AICoachEngine, profile: ProfileStore) {
        self.repo = repo
        self.engine = engine
        self.profile = profile
        threadStore.userAge = profile.age
        attachOwner()
    }

    /// Reads the signed-in owner and, the first time or when it has changed, loads that owner's caches and
    /// picks the launch thread: the newest cached thread when it was active on the same local day (its cached
    /// messages show at once, the server page follows in `start()`), otherwise a new chat. The choice is made
    /// once per owner and never revisited after a send or a pending prompt.
    private func attachOwner() {
        let owner = api.ownerId?.lowercased()
        if attached, owner == ownerId { return }
        if attached { resetForOwnerChange() }
        attached = true
        ownerId = owner
        local = owner.flatMap { CoachLocalStore(ownerId: $0, base: baseDirectory) }
        outbox = owner.map { CoachOutbox(ownerId: $0, fileURL: local?.outboxURL) }
        let snapshot = local?.loadThreads()
        features = snapshot?.features ?? .none
        threadStore.reset(local: local, features: features)

        if features.threads, let pick = CoachThreadLaunch.pick(threads: threadStore.threads, now: now()) {
            show(pick)
            launchThread = pick
        } else {
            startNewChat()
        }
        showStarters()
    }

    /// Another account signed in: nothing of the last one's stays on screen or in flight.
    private func resetForOwnerChange() {
        streamTask?.cancel()
        watchdog?.cancel()
        for (_, side) in visualTasks { side.task.cancel() }
        for (_, side) in followUpTasks { side.task.cancel() }
        visualTasks = [:]
        followUpTasks = [:]
        turn = nil
        isGenerating = false
        phase = .idle
        started = false
        connection = .checking
        memories = []
        manifestCache = [:]
        queuedPrompts = []
        deletedThreads = []
        rowThreads = [:]
        launchThread = nil
        userTouched = false
        workoutCount = nil
        journalDayCount = nil
        workoutStamps = []
        threadStore.canSwitchThreads = true
    }

    func start() async {
        attachOwner()
        guard !started else { return }
        started = true
        if messages.isEmpty, !userTouched { showStarters() }
        await checkConnection()
        guard connection == .online else {
            started = false
            // Offline: the cached launch thread is all there is; its server page follows on the next start.
            if threadPhase == .loading { threadPhase = .ready }
            return
        }

        if readsDeviceHistory, workoutCount == nil { await loadDeviceHistory() }
        if features.threads {
            Task { [weak self] in await self?.refreshStarters(swap: true) }
            if let pick = launchThread {
                launchThread = nil
                let token = openToken
                Task { [weak self] in await self?.reconcile(threadId: pick.id, token: token) }
            }
        }
        async let memoriesLoaded: Void = refreshMemories()
        if features.threads {
            await threadStore.refresh()
            maintainQuietThreads()
        }
        await flushOutbox()
        if features.context { prefetchManifest(threadId: threadKey) }
        await memoriesLoaded
    }

    func checkConnection() async {
        guard api.isAvailable else {
            connection = .offline(CoachAPIError.notConfigured.errorDescription ?? "")
            return
        }
        connection = .checking
        do {
            let status = try await api.status()
            apply(features: status.features)
            connection = status.ok && status.configured ? .online : .offline(CoachAPIError.unavailable.errorDescription ?? "")
        } catch {
            connection = .offline(Self.userFacing(error))
        }
    }

    private func apply(features new: CoachFeatures) {
        if features != new { features = new }
        threadStore.setFeatures(new)
    }

    /// The user tapped, typed or scrolled: a late server set of starter suggestions no longer replaces the local one.
    func noteUserInteraction() { userTouched = true }

    // MARK: Memory

    /// The memory sheet's list: up to 200 rows on a thread-aware server, the original 50 otherwise.
    func refreshMemories() async {
        isLoadingMemories = true
        defer { isLoadingMemories = false }
        if let fresh = try? await api.memories(limit: features.threads ? Self.memoryListLimit : nil) {
            memories = fresh
            memoriesStale = false
        }
    }

    func forget(_ memory: CoachMemory) async {
        do {
            try await api.deleteMemory(id: memory.id)
            memories.removeAll { $0.id == memory.id }
            // A cached manifest must never put a forgotten fact back into a prompt.
            manifestCache = manifestCache.mapValues { $0.removingMemory(id: memory.id) }
            local?.updateManifests { $0.removingMemory(id: memory.id) }
        } catch {
            errorMessage = Self.userFacing(error)
        }
    }

    func forgetAllMemories() async {
        do {
            try await api.clearMemories()
            memories = []
            manifestCache = [:]
            local?.removeAllManifests()
            // The server clears its suggestion cache too; the phone's copy may quote what was forgotten.
            local?.removeSuggestions()
            if messages.isEmpty { showStarters() }
        } catch {
            errorMessage = Self.userFacing(error)
        }
    }

    /// Deletes every chat on the server and on the phone.
    func clearConversation() async {
        stop()
        for (_, side) in visualTasks { side.task.cancel() }
        for (_, side) in followUpTasks { side.task.cancel() }
        visualTasks = [:]
        followUpTasks = [:]
        await outbox?.removeAll()
        for thread in threadStore.threads { local?.removeThread(id: thread.id); threadStore.remove(id: thread.id) }
        startNewChat()
        showStarters()
        do { try await api.clearMessages() } catch { errorMessage = Self.userFacing(error) }
    }

    // MARK: Sending

    /// Returns false when nothing was sent (empty, or a reply is already streaming) so the composer keeps its text.
    @discardableResult
    func send(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil, !isGenerating else { return false }

        userTouched = true
        errorMessage = nil
        pendingImage = nil
        let scrubbed = text.isEmpty ? nil : CoachPIIScrubber.scrub(text)
        let clean = scrubbed?.text ?? text
        wasScrubbed = (scrubbed?.redactions ?? 0) > 0

        let key = threadKey
        let isNewThread = messages.isEmpty && !threadOnServer
        let screen = clean.isEmpty ? CoachSafety.InputResult.pass : CoachSafety.screenInput(clean, userAge: userAge)
        let refusal = screen.blocked ? screen.refusal : nil
        var fallbackTitle: String?
        // An old server has no titles (the header keeps "Your health assistant"), and a refused question never
        // names the chat.
        if isNewThread, threadTitle == nil, features.threads, refusal == nil {
            fallbackTitle = CoachThreadTitle.fallback(from: clean)
            threadTitle = fallbackTitle
            threadTitleSource = "fallback"
        }

        var user = CoachChatMessage(role: .user, content: clean.isEmpty ? "What do you see in this image?" : clean, imageData: image)
        user.createdAt = nextStamp()
        user.blocked = refusal != nil
        messages.append(user)
        threadStore.currentThreadId = key
        threadStore.touch(id: key, title: fallbackTitle, titleSource: fallbackTitle == nil ? nil : "fallback",
                          preview: user.content, at: user.createdAt)

        if let refusal {
            var reply = CoachChatMessage(role: .assistant, content: refusal)
            reply.blocked = true
            reply.createdAt = nextStamp()
            messages.append(reply)
            persist([user.id, reply.id])
            threadStore.touch(id: key, title: nil, preview: refusal, at: reply.createdAt)
            wasScrubbed = false
            return true
        }
        // The question is saved now, not with the answer: a reply that never finishes still leaves it in history.
        persist([user.id], threadTitle: fallbackTitle)
        var reply = CoachChatMessage(role: .assistant, content: "", isStreaming: true)
        reply.createdAt = nextStamp()
        messages.append(reply)
        begin(Turn(assistantId: reply.id, userId: user.id, threadId: key, question: user.content, image: image,
                   isFirstTurn: isNewThread))
        return true
    }

    func stop() { streamTask?.cancel() }

    func retryStalled() {
        guard !isGenerating, let last = messages.last, last.role == .assistant, last.didStall,
              let user = messages.last(where: { $0.role == .user }) else { return }
        messages.removeLast()
        var reply = CoachChatMessage(role: .assistant, content: "", isStreaming: true)
        reply.createdAt = nextStamp()
        messages.append(reply)
        errorMessage = nil
        begin(Turn(assistantId: reply.id, userId: user.id, threadId: threadKey, question: user.content, image: lastImage,
                   isFirstTurn: !messages.contains { $0.role == .assistant && $0.id != reply.id && !$0.didStall }))
    }

    /// A question from outside the chat (the Today launcher, Siri, `--coach-prompt`) goes into a new chat. While a
    /// reply is generating it waits for that reply to end. False when it can't be taken yet (empty, or before
    /// `attach`), so the caller keeps its pending prompt.
    @discardableResult
    func queuePrompt(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, repo != nil else { return false }
        launchThread = nil
        if isGenerating {
            queuedPrompts.append(text)
        } else {
            sendInNewChat(text)
        }
        return true
    }

    /// A welcome chip. A `continue` chip reopens its earlier chat and asks there; the rest ask in this one.
    func selectSuggestion(_ suggestion: CoachStarterSuggestion) {
        userTouched = true
        guard suggestion.kind == .continue, let id = suggestion.threadId, features.threads, !isGenerating else {
            send(suggestion.text)
            return
        }
        let thread = threadStore.thread(id: id) ?? CoachThread(id: id)
        Task { [weak self] in
            guard let self else { return }
            await self.open(thread)
            self.send(suggestion.text)
        }
    }

    /// The pills under an answer: the model's follow-ups once they arrive; the keyword fallback after a 4 s
    /// timeout, a failure, or for an answer that never had any. Refusals and unfinished answers get none.
    func followUps(for message: CoachChatMessage) -> [String] {
        guard message.role == .assistant, !message.blocked, !message.isStreaming, !message.didStall,
              !message.content.isEmpty else { return [] }
        if let server = message.followUps, !server.isEmpty { return Array(server.prefix(3)) }
        if followUpsWaiting.contains(message.id) { return [] }
        return CoachFollowUps.forAnswer(message.content)
    }

    private func sendInNewChat(_ text: String) {
        if !messages.isEmpty || threadOnServer { startNewChat() }
        userTouched = true
        send(text)
    }

    private func drainQueuedPrompt() {
        guard !isGenerating, !queuedPrompts.isEmpty else { return }
        let next = queuedPrompts.removeFirst()
        Task { [weak self] in
            guard let self, !self.isGenerating else {
                self?.queuedPrompts.insert(next, at: 0)
                return
            }
            self.sendInNewChat(next)
        }
    }

    private func begin(_ turn: Turn) {
        self.turn = turn
        lastImage = turn.image
        isGenerating = true
        threadStore.canSwitchThreads = false
        phase = turn.image == nil ? .generating : .analyzingImage
        streamTask = Task { await respond(turn) }
    }

    /// Strictly increasing timestamps: history reloads ordered by time, so a reply never ties with its question.
    private func nextStamp() -> Date {
        max(now(), (messages.last?.createdAt ?? .distantPast).addingTimeInterval(0.005))
    }

    // MARK: Turn

    private func respond(_ turn: Turn) async {
        guard let repo, let engine else { return finish(turn, toolNames: [], evidence: []) }
        let deep = deepMode
        let question = turn.question
        let useContext = features.context
        let id = turn.assistantId
        var toolNames: [String] = []
        var evidence: [String] = []
        defer {
            watchdog?.cancel()
            finish(turn, toolNames: toolNames, evidence: evidence)
        }

        // The manifest is fetched while the photo is described, so a photo turn pays for neither twice.
        let manifestFetch = useContext ? fetchManifest(threadId: turn.threadId, question: question) : nil

        // Stage one of the photo pipeline: the vision model describes the image, and only that text reaches the chat model.
        var imageContext = ""
        if let image = turn.image {
            imageContext = (try? await api.describeImage(image)) ?? ""
            guard !Task.isCancelled else { return }
            if imageContext.isEmpty {
                imageContext = "(The photo could not be analyzed. Tell the user you couldn't see it and ask them to describe it or try again.)"
            } else {
                let saved = String(imageContext.prefix(Self.imageContextCap))
                updateMessage(turn.userId, in: turn.threadId, persist: true, flush: false) { $0.imageContext = saved }
            }
            phase = .generating
        }

        let refs = CoachThreadRefs()
        let system: String
        if useContext {
            let manifest = await manifest(for: turn.threadId, fetch: manifestFetch)
            guard !Task.isCancelled else { return }
            let count = max(manifest?.thread?.messageCount ?? 0, messages.filter { $0.id != id }.count)
            let context = CoachTurnContext(manifest: manifest, memories: memories, coverage: coverage(repo),
                                           messageCount: count, isFirstTurn: turn.isFirstTurn,
                                           currentThreadId: turn.threadId, refs: refs)
            system = CoachPrompt.system(context: context, imageContext: imageContext, userAge: userAge)
        } else {
            if memoriesStale { await refreshMemories() }
            guard !Task.isCancelled else { return }
            system = CoachPrompt.system(memories: memories, imageContext: imageContext, userAge: userAge)
        }
        var wire = [CoachWireMessage(role: "system", content: system)]
        wire += history(before: id)

        startWatchdog(for: id, ceiling: 180)
        let executor = CoachToolExecutor(repo: repo, engine: engine, api: api,
                                         threadId: features.threads ? turn.threadId : nil, refs: refs, userAge: userAge)
        // One per-intent bundle for every round of the turn.
        let tools = CoachToolExecutor.definitions(for: question, context: useContext)

        for round in 0...Self.maxToolRounds {
            guard !Task.isCancelled else { break }
            lastActivity = Date()
            let useTools = round < Self.maxToolRounds
            var calls: [CoachToolCall] = []
            var buffer = ""
            var lastFlush = Date()
            var failed = false
            var held = ""
            var released = !useTools

            func show(_ text: String) {
                if phase != .idle { phase = .idle }
                markFirstAnswerToken(id)
                buffer += text
                // Coalesce UI updates: one SwiftUI pass per ~40ms instead of per token.
                if Date().timeIntervalSince(lastFlush) >= Self.flushInterval {
                    append(buffer, to: id); buffer = ""; lastFlush = Date()
                }
            }

            do {
                let events = api.stream(
                    mode: .chat, messages: wire, tools: useTools ? tools : nil,
                    reasoningEffort: CoachPrompt.reasoningEffort(forUserText: question, isToolRound: useTools, deep: deep),
                    temperature: 0.3, maxTokens: deep || !useTools ? Self.answerTokens : Self.toolRoundTokens)
                for try await event in events {
                    guard !Task.isCancelled else { break }
                    lastActivity = Date()
                    switch event {
                    case .content(let text):
                        if released {
                            show(text)
                        } else {
                            held += text
                            if held.count > Self.preambleHold { released = true; show(held); held = "" }
                        }
                    case .thinking(let text): appendThinking(text, to: id)
                    case .toolCalls(let c): calls = c
                    case .done: break
                    }
                }
            } catch {
                if !Task.isCancelled { errorMessage = Self.userFacing(error) }
                failed = true
            }
            // Held text with no tool call behind it was the answer all along.
            if !held.isEmpty, calls.isEmpty { show(held); held = "" }
            if !buffer.isEmpty { append(buffer, to: id) }
            if failed || calls.isEmpty || Task.isCancelled { break }

            // Anything said before a tool call is narration, not the answer; the real answer follows the results.
            let narration = Self.narration(from: (message(id)?.content ?? "") + held)
            resetAnswerForToolRound(id)
            phase = .lookingUpData
            wire.append(CoachWireMessage(role: "assistant", toolCalls: calls))
            var labels: [String] = []
            for call in calls {
                let label = CoachToolDisplayNames.label(for: call.name)
                if !labels.contains(label) { labels.append(label) }
                if !toolNames.contains(label) { toolNames.append(label) }
            }
            markToolRound(labels, note: narration, on: id)
            let results = await runTools(calls, executor: executor)
            for (call, result) in zip(calls, results) {
                if call.name == "save_memory" { memoriesStale = true }
                if CoachVisualEvidence.dataTools.contains(call.name), !result.isEmpty { evidence.append(result) }
                let capped = result.count > Self.toolPayloadCap
                    ? String(result.prefix(Self.toolPayloadCap)) + "\n…[truncated — ask for more specific detail]"
                    : result
                wire.append(CoachWireMessage(role: "tool", content: capped, toolCallId: call.id))
            }
            lastActivity = Date()
            phase = .generating
        }
    }

    /// The calls of one round run concurrently; results come back in call order. A heartbeat keeps the stall
    /// watchdog quiet while a slow lookup (recall, say) runs.
    private func runTools(_ calls: [CoachToolCall], executor: CoachToolExecutor) async -> [String] {
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.toolHeartbeat * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.lastActivity = Date()
            }
        }
        defer { heartbeat.cancel() }
        let tasks = calls.map { call in Task { await executor.execute(name: call.name, arguments: call.arguments) } }
        return await withTaskCancellationHandler {
            var results: [String] = []
            for task in tasks { results.append(await task.value) }
            return results
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }
    }

    private func history(before id: UUID) -> [CoachWireMessage] {
        let prior = messages.prefix { $0.id != id }
        var recent = Array(prior.filter { !$0.content.isEmpty && !$0.isStreaming }.suffix(Self.historyWindow))
        while recent.first?.role == .assistant { recent.removeFirst() }
        return recent.map { m in
            switch m.role {
            case .user: return CoachWireMessage(role: "user", content: m.content)
            case .assistant:
                let limit = Self.historyAssistantChars
                return CoachWireMessage(role: "assistant", content: m.content.count > limit ? String(m.content.prefix(limit)) + "…" : m.content)
            }
        }
    }

    /// Trips when a stream goes quiet for `stallGrace` seconds, or runs past `ceiling`, leaving any partial
    /// answer in place with a Retry button instead of an endless spinner.
    private func startWatchdog(for id: UUID, ceiling: TimeInterval) {
        watchdog?.cancel()
        let began = Date()
        lastActivity = began
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled, self.isGenerating else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastActivity) >= Self.stallGrace || now.timeIntervalSince(began) >= ceiling else { continue }
                guard let idx = self.index(id) else { return }
                self.messages[idx].didStall = true
                self.errorMessage = self.messages[idx].content.isEmpty
                    ? "This is taking longer than usual — Coach may be busy. Tap Retry to try again."
                    : "The response stalled partway through. Tap Retry to try again."
                self.streamTask?.cancel()
                return
            }
        }
    }

    private func finish(_ turn: Turn, toolNames: [String], evidence: [String]) {
        defer {
            phase = .idle
            isGenerating = false
            wasScrubbed = false
            streamTask = nil
            if self.turn?.assistantId == turn.assistantId { self.turn = nil }
            threadStore.canSwitchThreads = true
            drainQueuedPrompt()
        }
        // The thread was deleted or the account changed mid-reply: nothing of this turn is kept.
        guard turn.threadId == threadKey, let idx = index(turn.assistantId) else { return }
        messages[idx].isStreaming = false

        let body = CoachVisualEvidence.stripTextCharts(CoachAPI.stripThinking(messages[idx].content))
        var answer: String?
        if body.isEmpty {
            if messages[idx].didStall {
                messages[idx].content = "Coach didn't finish answering."
            } else {
                messages.remove(at: idx)
                if errorMessage == nil, !Task.isCancelled { errorMessage = "Coach returned an empty reply. Please try again." }
                saveLocalMessages()
                return
            }
        } else {
            let screen = CoachSafety.screenOutput(body, userAge: userAge)
            messages[idx].content = screen.text
            messages[idx].toolNames = toolNames
            messages[idx].createdAt = max(now(), (message(turn.userId)?.createdAt ?? .distantPast).addingTimeInterval(0.005))
            if screen.clean, !messages[idx].didStall { answer = screen.text }
        }
        guard !messages[idx].didStall, let user = message(turn.userId) else {
            saveLocalMessages()
            return
        }
        let reply = messages[idx]
        let firstAnswer = !messages.contains {
            $0.role == .assistant && $0.id != reply.id && !$0.blocked && !$0.didStall && !$0.content.isEmpty
        }
        let titleOpen = threadTitleSource == nil || ["none", "fallback", "legacy"].contains(threadTitleSource ?? "")
        threadStore.touch(id: turn.threadId, title: nil, preview: reply.content, at: reply.createdAt)
        persist([reply.id], afterSave: { [weak self] in self?.afterSave(threadId: turn.threadId) })
        if let answer {
            startVisual(for: reply.id, threadId: turn.threadId, question: user.content, answer: answer, evidence: evidence)
            startFollowUps(for: reply.id, threadId: turn.threadId, question: user.content, answer: answer,
                           wantTitle: firstAnswer && titleOpen)
        }
    }

    private func index(_ id: UUID) -> Int? { messages.lastIndex { $0.id == id } }

    private func message(_ id: UUID) -> CoachChatMessage? { index(id).map { messages[$0] } }

    private func append(_ text: String, to id: UUID) {
        guard let idx = index(id) else { return }
        messages[idx].content += text
    }

    private func appendThinking(_ text: String, to id: UUID) {
        guard let idx = index(id) else { return }
        messages[idx].thinking += text
    }

    private func markFirstAnswerToken(_ id: UUID) {
        guard let idx = index(id), messages[idx].thinkingDuration == nil else { return }
        messages[idx].thinkingDuration = max(0, now().timeIntervalSince(messages[idx].createdAt))
    }

    /// The pre-tool narration tidied into one short line for the reasoning block.
    private static func narration(from raw: String) -> String {
        let flat = CoachAPI.stripThinking(raw)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > 220 ? String(flat.prefix(220)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }

    private func markToolRound(_ labels: [String], note: String, on id: UUID) {
        guard let idx = index(id) else { return }
        messages[idx].toolMarks.append(CoachToolMark(offset: messages[idx].thinking.count, labels: labels, note: note))
        messages[idx].toolNames = Array(Set(messages[idx].toolNames).union(labels)).sorted()
    }

    private func resetAnswerForToolRound(_ id: UUID) {
        guard let idx = index(id) else { return }
        messages[idx].content = ""
        messages[idx].thinkingDuration = nil
    }

    // MARK: Context

    private func fetchManifest(threadId: String, question: String?) -> Task<CoachContextManifest?, Never> {
        let api = self.api
        return Task { try? await api.context(threadId: threadId, question: question) }
    }

    /// A fresh manifest if it arrives within 1.2 s, otherwise the cached one (this thread's, else the newest of
    /// any). A late answer still lands in the cache for the next turn.
    private func manifest(for threadId: String, fetch: Task<CoachContextManifest?, Never>?) async -> CoachContextManifest? {
        let cached = manifestCache[threadId] ?? local?.loadManifest(threadId: threadId) ?? local?.latestManifest()
        guard let fetch else { return cached }
        if let fresh = await Self.value(of: fetch, within: Self.manifestWait) {
            store(fresh, threadId: threadId)
            return fresh
        }
        Task { [weak self] in
            if let late = await fetch.value { self?.store(late, threadId: threadId) }
        }
        return cached
    }

    private func prefetchManifest(threadId: String) {
        let fetch = fetchManifest(threadId: threadId, question: nil)
        Task { [weak self] in
            if let fresh = await fetch.value { self?.store(fresh, threadId: threadId) }
        }
    }

    private func store(_ manifest: CoachContextManifest, threadId: String) {
        guard !deletedThreads.contains(threadId) else { return }
        manifestCache[threadId] = manifest
        local?.saveManifest(manifest, threadId: threadId)
    }

    private func coverage(_ repo: Repository) -> CoachDataCoverage {
        CoachDataCoverage.make(days: repo.days, workouts: workoutCount, journalDays: journalDayCount)
    }

    private func loadDeviceHistory() async {
        guard let repo else { return }
        let rows = await repo.workoutRows()
        workoutCount = rows.count
        workoutStamps = rows.map { CoachWorkoutStamp(startTs: $0.startTs, sport: $0.sport) }
        journalDayCount = Set(await repo.journalEntries().map(\.day)).count
    }

    /// The first of `task`'s value and a timeout; the task keeps running either way.
    static func value<T>(of task: Task<T?, Never>, within seconds: TimeInterval) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = CoachOnce()
            Task {
                let value = await task.value
                if gate.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: After the answer

    /// (c) of the finish step: the reply is saved, so the server can fold the turn into the summary and curate
    /// memories; then the manifest is refreshed and the next starter set prefetched.
    private func afterSave(threadId: String) {
        guard features.threads, !deletedThreads.contains(threadId) else { return }
        let api = self.api
        Task { [weak self] in
            let result = try? await api.maintain(threadId: threadId)
            guard let self, !self.deletedThreads.contains(threadId) else { return }
            if let status = result?.status, ["queued", "done", "skipped"].contains(status) {
                self.threadStore.markMaintained(id: threadId)
            }
            if self.features.context { self.prefetchManifest(threadId: threadId) }
            if self.now().timeIntervalSince(self.lastSuggestionPrefetch) >= Self.suggestionPrefetchInterval {
                self.lastSuggestionPrefetch = self.now()
                await self.refreshStarters(swap: false)
            }
        }
    }

    private func startFollowUps(for id: UUID, threadId: String, question: String, answer: String, wantTitle: Bool) {
        guard features.threads else { return }
        let asked = Array(messages.filter { $0.role == .user && !$0.blocked }.map(\.content).suffix(12))
        let age = userAge
        let api = self.api
        let delay = followUpFallbackDelay
        followUpsWaiting.insert(id)
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.followUpsWaiting.remove(id)
        }
        followUpTasks[id]?.task.cancel()
        let task = Task { [weak self] in
            defer {
                timer.cancel()
                self?.followUpsWaiting.remove(id)
                self?.followUpTasks[id] = nil
            }
            do {
                let result = try await api.followUps(threadId: threadId, question: question, answer: String(answer.prefix(3_000)),
                                                     asked: asked, locale: Self.locale, wantTitle: wantTitle)
                guard let self, !Task.isCancelled else { return }
                let screened = CoachModelText.followUps(result.followUps, asked: asked, userAge: age)
                if !screened.isEmpty {
                    self.updateMessage(id, in: threadId, persist: true) { $0.followUps = screened }
                }
                if wantTitle, let title = CoachModelText.title(result.title, userAge: age) {
                    self.applyGeneratedTitle(title, threadId: threadId)
                }
            } catch {
                // The title still comes from its own route when the combined call fails.
                guard wantTitle, !Task.isCancelled,
                      let reply = try? await api.generateTitle(threadId: threadId, question: question, answer: answer,
                                                               locale: Self.locale),
                      let title = CoachModelText.title(reply.title, userAge: age) else { return }
                self?.applyGeneratedTitle(title, threadId: threadId)
            }
        }
        followUpTasks[id] = (threadId, task)
    }

    private func applyGeneratedTitle(_ title: String, threadId: String) {
        guard !deletedThreads.contains(threadId) else { return }
        threadStore.setTitle(id: threadId, title: title, source: "auto")
        if threadId == threadKey, threadTitleSource != "user" {
            threadTitle = title
            threadTitleSource = "auto"
        }
    }

    /// The header follows the list: a rename in the sidebar, or a newer title the server sent with a refresh.
    /// A title the user typed here is only replaced by another one the user typed.
    private func syncTitle(from threads: [CoachThread]) {
        guard features.threads, let current = threads.first(where: { $0.id == threadKey }),
              let title = current.title, !title.isEmpty, title != threadTitle,
              current.hasUserTitle || threadTitleSource != "user" else { return }
        threadTitle = title
        threadTitleSource = current.titleSource
    }

    // MARK: Visual

    /// Runs after the answer has landed so the text is never held up: pre-route gate, a silent route-only call,
    /// a "generating" placeholder, then design + fact-check (one retry). Anything that fails shows nothing.
    private func startVisual(for id: UUID, threadId: String, question: String, answer: String, evidence: [String]) {
        let hasDigits = answer.rangeOfCharacter(from: .decimalDigits) != nil
        guard !evidence.isEmpty || hasDigits else { return }
        let composed = CoachVisualEvidence.compose(evidence)
        visualTasks[id]?.task.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.visualTasks[id] = nil }
            guard let routed = try? await self.api.visual(CoachVisualRequest(question: question, answer: answer, evidence: composed, routeOnly: true)),
                  let route = routed.route, !Task.isCancelled else { return }
            self.updateMessage(id, in: threadId, persist: false) { $0.viz = nil; $0.vizPhase = .generating }
            var visual: CoachViz?
            for attempt in 0..<2 {
                guard !Task.isCancelled else { break }
                let reply = try? await self.api.visual(CoachVisualRequest(question: question, answer: answer, evidence: composed, route: route))
                if let candidate = reply?.visual, candidate.isRenderable { visual = candidate; break }
                if reply?.outcome == "rejected" { break }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            }
            guard !Task.isCancelled else { return }
            self.updateMessage(id, in: threadId, persist: visual != nil) { $0.viz = visual; $0.vizPhase = visual == nil ? .none : .ready }
        }
        visualTasks[id] = (threadId, task)
    }

    /// Changes one message wherever it lives: in the open chat, or (after a switch) in its thread's cached copy.
    /// `persist` saves the full row again through the outbox.
    private func updateMessage(_ id: UUID, in threadId: String, persist save: Bool, flush: Bool = true,
                               _ change: (inout CoachChatMessage) -> Void) {
        if threadId == threadKey, let i = index(id) {
            change(&messages[i])
            if save { persist([id], flush: flush) }
            return
        }
        guard save, let local, !deletedThreads.contains(threadId) else { return }
        var rows = local.loadMessages(threadId: threadId)
        let clientId = id.uuidString.lowercased()
        guard let r = rows.firstIndex(where: { $0.clientId == clientId }), var m = CoachChatMessage(stored: rows[r]) else { return }
        change(&m)
        rows[r] = m.stored(threadId: threadId)
        local.saveMessages(rows, threadId: threadId)
        enqueue([m], threadId: threadId, threadTitle: nil, flush: flush, afterSave: nil)
    }

    // MARK: Threads

    /// A fresh chat with a client UUID. Nothing is stored until the first send.
    func newChat() {
        guard !isGenerating else { return }
        userTouched = true
        launchThread = nil
        guard !messages.isEmpty || threadOnServer || threadPhase != .ready else { return }
        startNewChat()
        showStarters()
    }

    /// Switches to `thread`: its cached messages show at once, then the server page and any unsent rows merge in.
    /// Refused while a reply is generating.
    func open(_ thread: CoachThread) async {
        guard !isGenerating else { return }
        userTouched = true
        launchThread = nil
        let key = thread.id.lowercased()
        if key == threadKey, threadPhase == .ready, !messages.isEmpty { return }
        show(thread)
        await reconcile(threadId: key, token: openToken)
    }

    /// The previous page of the open thread, merged in front of what is shown.
    func loadEarlier() async {
        guard hasEarlier, !isLoadingEarlier, let cursor = earlierCursor else { return }
        let token = openToken, key = threadKey
        isLoadingEarlier = true
        defer { if token == openToken { isLoadingEarlier = false } }
        guard let page = try? await api.messages(threadId: key, limit: Self.pageSize, cursor: cursor),
              token == openToken else { return }
        messages = Self.merge(local: messages, server: page.messages, outbox: [])
        hasEarlier = page.hasMore && page.nextCursor != nil
        earlierCursor = page.nextCursor
    }

    /// Cancels the thread's work, empties its outbox rows, and removes it here and on the server. Deleting the
    /// open thread starts a new chat (stopping a reply in progress).
    func deleteThread(id: String) async {
        let key = id.lowercased()
        deletedThreads.insert(key)
        for (msg, side) in visualTasks where side.thread == key { side.task.cancel(); visualTasks[msg] = nil }
        for (msg, side) in followUpTasks where side.thread == key { side.task.cancel(); followUpTasks[msg] = nil }
        if key == threadKey {
            if isGenerating { streamTask?.cancel() }
            startNewChat()
            showStarters()
        }
        manifestCache[key] = nil
        rowThreads = rowThreads.filter { $0.value != key }
        await outbox?.purge(threadId: key)
        local?.removeThread(id: key)
        await threadStore.delete(id: key)
    }

    func renameThread(id: String, title: String) async {
        let key = id.lowercased()
        let clean = CoachModelText.collapsed(title)
        let before = (threadTitle, threadTitleSource)
        if key == threadKey, !clean.isEmpty {
            threadTitle = clean
            threadTitleSource = "user"
        }
        if !(await threadStore.rename(id: key, title: clean)), key == threadKey {
            (threadTitle, threadTitleSource) = before
        }
    }

    func moveThread(id: String, folderId: String?) async { await threadStore.move(id: id, folderId: folderId) }

    func setPinned(id: String, _ pinned: Bool) async { await threadStore.setPinned(id: id, pinned) }

    @discardableResult
    func createFolder(name: String) async -> CoachFolder? { await threadStore.createFolder(name: name) }

    func renameFolder(id: String, name: String) async { await threadStore.renameFolder(id: id, name: name) }

    func deleteFolder(id: String) async { await threadStore.deleteFolder(id: id) }

    private func startNewChat() {
        openToken = UUID()
        threadId = UUID()
        threadTitle = nil
        threadTitleSource = nil
        threadOnServer = false
        messages = []
        hasEarlier = false
        earlierCursor = nil
        isLoadingEarlier = false
        threadPhase = .ready
        clearThreadUI()
        threadStore.currentThreadId = threadKey
    }

    /// Puts `thread` on screen from the caches, before the server answers.
    private func show(_ thread: CoachThread) {
        openToken = UUID()
        threadId = UUID(uuidString: thread.id) ?? UUID()
        threadTitle = thread.title.flatMap { $0.isEmpty ? nil : $0 }
        threadTitleSource = thread.titleSource
        threadOnServer = thread.localOnly != true
        messages = (local?.loadMessages(threadId: threadKey) ?? []).compactMap(CoachChatMessage.init(stored:))
        hasEarlier = false
        earlierCursor = nil
        isLoadingEarlier = false
        threadPhase = .loading
        clearThreadUI()
        threadStore.currentThreadId = threadKey
    }

    private func clearThreadUI() {
        errorMessage = nil
        wasScrubbed = false
        pendingImage = nil
        followUpsWaiting = []
    }

    /// Merges the server's newest page and the thread's unsent rows into what is shown, by client id.
    private func reconcile(threadId key: String, token: UUID) async {
        let unsent = await outbox?.pending(threadId: key).map(\.row) ?? []
        guard token == openToken else { return }
        if !unsent.isEmpty { messages = Self.merge(local: messages, server: [], outbox: unsent) }
        do {
            let page = try await api.messages(threadId: key, limit: Self.pageSize)
            guard token == openToken else { return }
            let pending = await outbox?.pending(threadId: key).map(\.row) ?? []
            guard token == openToken else { return }
            messages = Self.merge(local: messages, server: page.messages, outbox: pending)
            hasEarlier = page.hasMore && page.nextCursor != nil
            earlierCursor = page.nextCursor
            if !page.messages.isEmpty { threadOnServer = true }
        } catch {
            guard token == openToken else { return }
            if messages.isEmpty { errorMessage = "Couldn't load this chat. Check your connection and try again." }
        }
        threadPhase = .ready
        saveLocalMessages()
        if features.context { prefetchManifest(threadId: key) }
    }

    /// Server rows over cached ones by client id (the photo and the reasoning trace stay), then unsent outbox
    /// rows over both, ordered by time. A message still streaming is never replaced.
    static func merge(local: [CoachChatMessage], server: [CoachStoredMessage],
                      outbox: [CoachStoredMessage]) -> [CoachChatMessage] {
        var byId: [UUID: CoachChatMessage] = [:]
        var order: [UUID] = []
        func put(_ m: CoachChatMessage) {
            if byId[m.id] == nil { order.append(m.id) }
            byId[m.id] = m
        }
        let localById = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for row in server {
            guard let m = CoachChatMessage(stored: row) else { continue }
            put(localById[m.id].map { $0.merged(withServer: m) } ?? m)
        }
        for m in local where byId[m.id] == nil { put(m) }
        for row in outbox {
            guard let m = CoachChatMessage(stored: row) else { continue }
            put(byId[m.id].map { $0.merged(withServer: m) } ?? m)
        }
        return order.enumerated()
            .compactMap { offset, id in byId[id].map { (offset, $0) } }
            .sorted { a, b in a.1.createdAt != b.1.createdAt ? a.1.createdAt < b.1.createdAt : a.0 < b.0 }
            .map(\.1)
    }

    private func maintainQuietThreads() {
        guard features.threads else { return }
        let cutoff = now().addingTimeInterval(-Self.quietBeforeMaintain)
        let quiet = threadStore.threads
            .filter { $0.pendingMessages > 0 && $0.localOnly != true && ($0.activityDate ?? .distantFuture) < cutoff }
            .sorted { ($0.activityDate ?? .distantPast) > ($1.activityDate ?? .distantPast) }
            .prefix(3)
        let api = self.api
        for thread in quiet {
            Task { [weak self] in
                guard let status = (try? await api.maintain(threadId: thread.id))?.status,
                      ["queued", "done", "skipped"].contains(status) else { return }
                self?.threadStore.markMaintained(id: thread.id)
            }
        }
    }

    // MARK: Starter suggestions

    private func localStarters() -> [CoachStarterSuggestion] {
        let days = repo?.days ?? []
        return CoachStarterSuggestions.local(today: days.last, recent: days, userAge: userAge)
    }

    /// The cached server set when it is from today, otherwise the phone's own.
    private func showStarters() {
        let own = localStarters()
        if features.threads, let cached = local?.loadSuggestions(), cached.day == CoachDates.day(now()) {
            starterSuggestions = CoachStarterSuggestions.merge(server: cached.suggestions, local: own, userAge: userAge)
        } else {
            starterSuggestions = own
        }
        suggestionsShownAt = now()
    }

    /// Asks the server for a personalised set. It is always cached for the next new chat; `swap` also shows it,
    /// but only within 1.5 s of the welcome screen appearing and before the user has touched anything.
    private func refreshStarters(swap: Bool) async {
        guard features.threads else { return }
        let own = localStarters()
        let shownAt = suggestionsShownAt
        let wd = engine?.baseline?.watchdogResult
        let state = CoachUserStateSnapshot.make(days: repo?.days ?? [], workouts: workoutStamps,
                                                watchdogSeverity: wd?.severity.rawValue, watchdogHeadline: wd?.headline,
                                                now: now())
        guard let result = try? await api.suggestions(state: state, fallback: own.map(\.text), locale: Self.locale) else { return }
        let server = CoachStarterSuggestions.screened(result.suggestions, userAge: userAge)
        guard !server.isEmpty else { return }
        if result.source != "fallback" {
            local?.saveSuggestions(CoachCachedSuggestions(suggestions: server, day: CoachDates.day(now()),
                                                          source: result.source, savedAt: now()))
        }
        guard swap, messages.isEmpty,
              CoachStarterSuggestions.shouldSwap(shownAt: shownAt, arrivedAt: now(), userTouched: userTouched) else { return }
        starterSuggestions = CoachStarterSuggestions.merge(server: server, local: own, userAge: userAge)
    }

    // MARK: Persistence

    /// Saves the open thread's rows for `ids` (each with its full current meta) through the outbox and, unless
    /// told otherwise, flushes now. `afterSave` runs once the last of them is confirmed saved.
    private func persist(_ ids: [UUID], threadTitle: String? = nil, flush: Bool = true,
                         afterSave: (() -> Void)? = nil) {
        let rows = ids.compactMap { id in messages.first { $0.id == id } }
        saveLocalMessages()
        enqueue(rows, threadId: threadKey, threadTitle: threadTitle, flush: flush, afterSave: afterSave)
    }

    private func enqueue(_ rows: [CoachChatMessage], threadId: String, threadTitle: String?, flush: Bool,
                         afterSave: (() -> Void)?) {
        guard let outbox, let owner = ownerId, !rows.isEmpty, !deletedThreads.contains(threadId) else { return }
        let entries = rows.map { m in
            CoachOutboxEntry(ownerId: owner, threadId: threadId, clientId: m.clientId, role: m.role.rawValue,
                             content: m.content, meta: m.meta, createdAt: CoachDates.string(m.createdAt),
                             threadTitle: threadTitle)
        }
        for entry in entries { rowThreads[entry.clientId] = threadId }
        let ids = Set(entries.map(\.clientId))
        Task { [weak self] in
            await outbox.enqueue(entries)
            guard flush, let self else { return }
            let saved = await self.flushOutbox()
            if ids.isSubset(of: saved) { afterSave?() }
        }
    }

    @discardableResult
    private func flushOutbox() async -> Set<String> {
        guard let outbox else { return [] }
        let api = self.api
        let saved = await outbox.flush(ownerId: api.ownerId) { rows in try await api.saveMessages(rows) }
        var threads = Set<String>()
        for id in saved { if let t = rowThreads.removeValue(forKey: id) { threads.insert(t) } }
        for thread in threads {
            threadStore.markSaved(id: thread)
            if thread == threadKey { threadOnServer = true }
        }
        return saved
    }

    /// The open thread's newest messages, for an instant reopen.
    private func saveLocalMessages() {
        guard let local, !deletedThreads.contains(threadKey) else { return }
        let rows = messages.filter { !$0.isStreaming && !$0.content.isEmpty }.map { $0.stored(threadId: threadKey) }
        guard !rows.isEmpty else { return }
        local.saveMessages(rows, threadId: threadKey)
    }

    private static func userFacing(_ error: Error) -> String {
        if let known = error as? CoachAPIError { return known.errorDescription ?? "" }
        if let route = error as? CoachRouteError { return route.errorDescription ?? "" }
        if (error as NSError).domain == NSURLErrorDomain { return "Couldn't reach Sana. Check your connection and try again." }
        return CoachAPIError.unavailable.errorDescription ?? ""
    }
}

/// A one-shot latch for racing two tasks.
final class CoachOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
