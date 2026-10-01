import SwiftUI

struct CoachChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }

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

    init(id: UUID = UUID(), role: Role, content: String, isStreaming: Bool = false, imageData: Data? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.imageData = imageData
        self.hadImage = imageData != nil
    }
}

/// Where a tool round happened in the reasoning stream, so the trace can interleave findings with lookups.
struct CoachToolMark: Equatable {
    let offset: Int
    let labels: [String]
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

/// Drives one coach conversation: safety screens, the photo pipeline, the streaming tool loop,
/// memory, and persistence to the user's cloud project.
@MainActor
final class CoachChatViewModel: ObservableObject {
    @Published private(set) var messages: [CoachChatMessage] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var phase: CoachThinkingPhase = .idle
    @Published private(set) var connection: CoachConnection = .checking
    @Published private(set) var memories: [CoachMemory] = []
    @Published private(set) var wasScrubbed = false
    @Published var errorMessage: String?
    @Published var deepMode = false
    @Published var pendingImage: Data?

    static let maxToolRounds = 4
    private static let toolRoundTokens = 1_200
    private static let answerTokens = 4_096
    private static let historyWindow = 28
    private static let historyAssistantChars = 2_500
    private static let toolPayloadCap = 10_000
    private static let flushInterval: TimeInterval = 0.04
    private static let stallGrace: TimeInterval = 45

    private let api: CoachAPI
    private var repo: Repository?
    private var engine: AICoachEngine?
    private var streamTask: Task<Void, Never>?
    private var visualTasks: [UUID: Task<Void, Never>] = [:]
    private var watchdog: Task<Void, Never>?
    private var lastActivity = Date()
    private var lastImage: Data?
    private var profile: ProfileStore?
    private var memoriesStale = false
    private var started = false
    // ponytail: unsaved turns live in memory only; a force-quit while offline drops them. Upgrade path: persist the queue to disk.
    private var unsaved: [CoachStoredMessage] = []

    init(api: CoachAPI = .shared) { self.api = api }

    func attach(repo: Repository, engine: AICoachEngine, profile: ProfileStore) {
        self.repo = repo
        self.engine = engine
        self.profile = profile
    }

    /// Age drives the stricter under-18 rules; the profile always holds a date of birth.
    private var userAge: Int? { profile?.age }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await checkConnection()
        guard connection == .online else { started = false; return }
        await refreshMemories()
        await flushUnsaved()
    }

    func checkConnection() async {
        guard api.isAvailable else {
            connection = .offline(CoachAPIError.notConfigured.errorDescription ?? "")
            return
        }
        connection = .checking
        do {
            connection = try await api.isReachable() ? .online : .offline(CoachAPIError.unavailable.errorDescription ?? "")
        } catch {
            connection = .offline(Self.userFacing(error))
        }
    }

    func refreshMemories() async {
        if let fresh = try? await api.memories() { memories = fresh; memoriesStale = false }
    }

    func forget(_ memory: CoachMemory) async {
        do {
            try await api.deleteMemory(id: memory.id)
            memories.removeAll { $0.id == memory.id }
        } catch {
            errorMessage = Self.userFacing(error)
        }
    }

    func forgetAllMemories() async {
        do {
            try await api.clearMemories()
            memories = []
        } catch {
            errorMessage = Self.userFacing(error)
        }
    }

    func clearConversation() async {
        stop()
        visualTasks.values.forEach { $0.cancel() }
        visualTasks = [:]
        messages = []
        unsaved = []
        errorMessage = nil
        do { try await api.clearMessages() } catch { errorMessage = Self.userFacing(error) }
    }

    // MARK: Sending

    /// Returns false when nothing was sent (empty, or a reply is already streaming) so the composer keeps its text.
    @discardableResult
    func send(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil, !isGenerating else { return false }

        errorMessage = nil
        pendingImage = nil
        let scrubbed = text.isEmpty ? nil : CoachPIIScrubber.scrub(text)
        let clean = scrubbed?.text ?? text
        wasScrubbed = (scrubbed?.redactions ?? 0) > 0

        let user = CoachChatMessage(role: .user, content: clean.isEmpty ? "What do you see in this image?" : clean, imageData: image)
        messages.append(user)

        if !clean.isEmpty {
            let screen = CoachSafety.screenInput(clean, userAge: userAge)
            if screen.blocked, let refusal = screen.refusal {
                let reply = CoachChatMessage(role: .assistant, content: refusal)
                messages.append(reply)
                enqueue([user, reply])
                wasScrubbed = false
                return true
            }
        }
        messages.append(CoachChatMessage(role: .assistant, content: "", isStreaming: true))
        begin(image: image)
        return true
    }

    func stop() { streamTask?.cancel() }

    func retryStalled() {
        guard !isGenerating, let last = messages.last, last.role == .assistant, last.didStall else { return }
        messages.removeLast()
        messages.append(CoachChatMessage(role: .assistant, content: "", isStreaming: true))
        errorMessage = nil
        begin(image: lastImage)
    }

    private func begin(image: Data?) {
        lastImage = image
        isGenerating = true
        phase = image == nil ? .generating : .analyzingImage
        streamTask = Task { await respond(image: image) }
    }

    // MARK: Turn

    private func respond(image: Data?) async {
        guard let repo, let engine else { return finish(toolNames: [], evidence: []) }
        let deep = deepMode
        let question = messages.last(where: { $0.role == .user })?.content ?? ""
        var toolNames: [String] = []
        var evidence: [String] = []
        defer {
            watchdog?.cancel()
            finish(toolNames: toolNames, evidence: evidence)
        }

        // Stage one of the photo pipeline: the vision model describes the image, and only that text reaches the chat model.
        var imageContext = ""
        if let image {
            imageContext = (try? await api.describeImage(image)) ?? ""
            guard !Task.isCancelled else { return }
            if imageContext.isEmpty {
                imageContext = "(The photo could not be analyzed. Tell the user you couldn't see it and ask them to describe it or try again.)"
            }
            phase = .generating
        }
        if memoriesStale { await refreshMemories() }
        guard !Task.isCancelled else { return }

        var wire = [CoachWireMessage(role: "system", content: CoachPrompt.system(memories: memories, imageContext: imageContext, userAge: userAge))]
        wire += history()

        startWatchdog(ceiling: 180)
        let executor = CoachToolExecutor(repo: repo, engine: engine, api: api)
        // One per-intent bundle for every round of the turn.
        let tools = CoachToolExecutor.definitions(for: question)

        for round in 0...Self.maxToolRounds {
            guard !Task.isCancelled else { break }
            lastActivity = Date()
            let useTools = round < Self.maxToolRounds
            var calls: [CoachToolCall] = []
            var buffer = ""
            var lastFlush = Date()
            var failed = false

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
                        if phase != .idle { phase = .idle }
                        markFirstAnswerToken()
                        buffer += text
                        // Coalesce UI updates: one SwiftUI pass per ~40ms instead of per token.
                        if Date().timeIntervalSince(lastFlush) >= Self.flushInterval {
                            append(buffer); buffer = ""; lastFlush = Date()
                        }
                    case .thinking(let text): appendThinking(text)
                    case .toolCalls(let c): calls = c
                    case .done: break
                    }
                }
            } catch {
                if !Task.isCancelled { errorMessage = Self.userFacing(error) }
                failed = true
            }
            if !buffer.isEmpty { append(buffer) }
            if failed || calls.isEmpty || Task.isCancelled { break }

            // Anything said before a tool call is scratch reasoning; the real answer follows the results.
            resetAnswerForToolRound()
            phase = .lookingUpData
            wire.append(CoachWireMessage(role: "assistant", toolCalls: calls))
            var labels: [String] = []
            for call in calls {
                let label = CoachToolDisplayNames.label(for: call.name)
                if !labels.contains(label) { labels.append(label) }
                if !toolNames.contains(label) { toolNames.append(label) }
            }
            markToolRound(labels)
            for call in calls {
                let result = await executor.execute(name: call.name, arguments: call.arguments)
                if call.name == "save_memory" { memoriesStale = true }
                if CoachVisualEvidence.dataTools.contains(call.name), !result.isEmpty { evidence.append(result) }
                let capped = result.count > Self.toolPayloadCap
                    ? String(result.prefix(Self.toolPayloadCap)) + "\n…[truncated — ask for more specific detail]"
                    : result
                wire.append(CoachWireMessage(role: "tool", content: capped, toolCallId: call.id))
                lastActivity = Date()
            }
            phase = .generating
        }
    }

    private func history() -> [CoachWireMessage] {
        var recent = Array(messages.dropLast().filter { !$0.content.isEmpty }.suffix(Self.historyWindow))
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
    private func startWatchdog(ceiling: TimeInterval) {
        watchdog?.cancel()
        let began = Date()
        lastActivity = began
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled, self.isGenerating else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastActivity) >= Self.stallGrace || now.timeIntervalSince(began) >= ceiling else { continue }
                guard let idx = self.messages.indices.last, self.messages[idx].role == .assistant else { return }
                self.messages[idx].didStall = true
                self.errorMessage = self.messages[idx].content.isEmpty
                    ? "This is taking longer than usual — Coach may be busy. Tap Retry to try again."
                    : "The response stalled partway through. Tap Retry to try again."
                self.streamTask?.cancel()
                return
            }
        }
    }

    private func finish(toolNames: [String], evidence: [String]) {
        defer {
            phase = .idle
            isGenerating = false
            wasScrubbed = false
            streamTask = nil
        }
        guard let idx = messages.indices.last, messages[idx].role == .assistant else { return }
        messages[idx].isStreaming = false

        let body = CoachVisualEvidence.stripTextCharts(CoachAPI.stripThinking(messages[idx].content))
        var answer: String?
        if body.isEmpty {
            if messages[idx].didStall {
                messages[idx].content = "Coach didn't finish answering."
            } else {
                messages.removeLast()
                if errorMessage == nil, !Task.isCancelled { errorMessage = "Coach returned an empty reply. Please try again." }
                return
            }
        } else {
            let screen = CoachSafety.screenOutput(body, userAge: userAge)
            messages[idx].content = screen.text
            messages[idx].toolNames = toolNames
            messages[idx].createdAt = Date()
            if screen.clean, !messages[idx].didStall { answer = screen.text }
        }
        if !messages[idx].didStall, idx > 0, messages[idx - 1].role == .user {
            enqueue([messages[idx - 1], messages[idx]])
            if let answer { startVisual(for: messages[idx].id, question: messages[idx - 1].content, answer: answer, evidence: evidence) }
        }
    }

    private func append(_ text: String) {
        guard let idx = messages.indices.last else { return }
        messages[idx].content += text
    }

    private func appendThinking(_ text: String) {
        guard let idx = messages.indices.last else { return }
        messages[idx].thinking += text
    }

    private func markFirstAnswerToken() {
        guard let idx = messages.indices.last, messages[idx].thinkingDuration == nil else { return }
        messages[idx].thinkingDuration = max(0, Date().timeIntervalSince(messages[idx].createdAt))
    }

    private func markToolRound(_ labels: [String]) {
        guard let idx = messages.indices.last else { return }
        messages[idx].toolMarks.append(CoachToolMark(offset: messages[idx].thinking.count, labels: labels))
        messages[idx].toolNames = Array(Set(messages[idx].toolNames).union(labels)).sorted()
    }

    private func resetAnswerForToolRound() {
        guard let idx = messages.indices.last else { return }
        messages[idx].content = ""
        messages[idx].thinkingDuration = nil
    }

    // MARK: Visual

    /// Runs after the answer has landed so the text is never held up: pre-route gate, a silent route-only call,
    /// a "generating" placeholder, then design + fact-check (one retry). Anything that fails shows nothing.
    private func startVisual(for id: UUID, question: String, answer: String, evidence: [String]) {
        let hasDigits = answer.rangeOfCharacter(from: .decimalDigits) != nil
        guard !evidence.isEmpty || hasDigits else { return }
        let composed = CoachVisualEvidence.compose(evidence)
        visualTasks[id]?.cancel()
        visualTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.visualTasks[id] = nil }
            guard let routed = try? await self.api.visual(CoachVisualRequest(question: question, answer: answer, evidence: composed, routeOnly: true)),
                  let route = routed.route, !Task.isCancelled else { return }
            self.setViz(nil, phase: .generating, for: id)
            var visual: CoachViz?
            for attempt in 0..<2 {
                guard !Task.isCancelled else { break }
                let reply = try? await self.api.visual(CoachVisualRequest(question: question, answer: answer, evidence: composed, route: route))
                if let candidate = reply?.visual, candidate.isRenderable { visual = candidate; break }
                if reply?.outcome == "rejected" { break }
                if attempt == 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            }
            self.setViz(visual, phase: visual == nil ? .none : .ready, for: id)
            if visual != nil, let message = self.messages.first(where: { $0.id == id }) { self.enqueue([message]) }
        }
    }

    private func setViz(_ viz: CoachViz?, phase: CoachVizPhase, for id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].viz = viz
        messages[idx].vizPhase = phase
    }

    // MARK: Persistence

    private func enqueue(_ turn: [CoachChatMessage]) {
        // History reloads ordered by timestamp, so a reply must never tie with (or precede) the question it answers.
        var previous = Date.distantPast
        unsaved += turn.map { m in
            let stamp = max(m.createdAt, previous.addingTimeInterval(0.005))
            previous = stamp
            return CoachStoredMessage(
                clientId: m.id.uuidString.lowercased(), role: m.role.rawValue, content: m.content,
                meta: CoachMessageMeta(toolNames: m.toolNames.isEmpty ? nil : m.toolNames, viz: m.viz,
                                       hadImage: m.hadImage ? true : nil),
                createdAt: Self.iso.string(from: stamp))
        }
        Task { await flushUnsaved() }
    }

    private func flushUnsaved() async {
        guard !unsaved.isEmpty else { return }
        let batch = unsaved
        do {
            try await api.saveMessages(batch)
            let saved = Set(batch.map(\.clientId))
            unsaved.removeAll { saved.contains($0.clientId) }
        } catch {
            // Kept in `unsaved` and retried with the next turn.
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func userFacing(_ error: Error) -> String {
        if let known = error as? CoachAPIError { return known.errorDescription ?? "" }
        if (error as NSError).domain == NSURLErrorDomain { return "Couldn't reach Sana. Check your connection and try again." }
        return CoachAPIError.unavailable.errorDescription ?? ""
    }
}
