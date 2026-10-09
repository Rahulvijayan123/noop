import Foundation

// MARK: - Wire types

struct CoachToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let arguments: String
}

enum CoachStreamEvent: Equatable, Sendable {
    case thinking(String)
    case content(String)
    case toolCalls([CoachToolCall])
    case done
}

enum CoachMode: String, Sendable { case chat, vision }

enum CoachAPIError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case dailyLimit
    case tooLarge
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sana runs through your cloud project. Turn on cloud mode in Settings to use it."
        case .unauthorized:
            return "This device isn't signed in to your cloud yet. Re-enroll it in Settings, then try again."
        case .dailyLimit:
            return "You've reached today's Sana limit. It resets tomorrow."
        case .tooLarge:
            return "That message or photo is too large to send."
        case .unavailable:
            return "Sana is temporarily unavailable. Please try again in a moment."
        }
    }
}

/// One OpenAI-shaped chat message as the relay expects it.
struct CoachWireMessage: Sendable {
    var role: String
    var content: String = ""
    var toolCallId: String? = nil
    var toolCalls: [CoachToolCall]? = nil
    var imageJPEG: Data? = nil

    var json: [String: Any] {
        var out: [String: Any] = ["role": role]
        if let toolCallId {
            out["tool_call_id"] = toolCallId
            out["content"] = content
        } else if let toolCalls {
            // Providers reject empty argument strings on replay, and a no-argument tool streams exactly that.
            out["tool_calls"] = toolCalls.map {
                ["id": $0.id, "type": "function",
                 "function": ["name": $0.name, "arguments": $0.arguments.isEmpty ? "{}" : $0.arguments]] as [String: Any]
            }
            if !content.isEmpty { out["content"] = content }
        } else if let imageJPEG {
            out["content"] = [
                ["type": "text", "text": content],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + imageJPEG.base64EncodedString()]],
            ] as [[String: Any]]
        } else {
            out["content"] = content
        }
        return out
    }
}

// MARK: - Stored conversation + memory

struct CoachMemory: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let content: String
    let topic: String
    let importance: Int
    var createdAt: String? = nil
    var updatedAt: String? = nil
    /// `tool | curator | user | legacy`.
    var source: String? = nil
    var confirmations: Int? = nil
    /// A safety-critical row the ranking always keeps (injury or health, importance 4 or more).
    var pinned: Bool? = nil
}

struct CoachMessageMeta: Codable, Equatable, Sendable {
    var toolNames: [String]?
    var viz: CoachViz?
    var hadImage: Bool?
    /// Model-written next questions for this answer, already screened by `CoachSafety`.
    var followUps: [String]? = nil
    /// A turn `CoachSafety.screenInput` refused, and its refusal. The server keeps it out of summaries,
    /// curation, search, recall, follow-ups and suggestions.
    var blocked: Bool? = nil
    /// What the vision model saw in the photo this question carried (≤ 1,200 characters).
    var imageContext: String? = nil
    /// The interactive card generated with this answer (`CoachGenUI`).
    var ui: CoachGeneratedUI? = nil
    /// What the screen this question was asked from showed (`CoachHandoff`, ≤ 2,400 characters). Every later turn
    /// of the chat reads it again.
    var screenContext: String? = nil

    init(toolNames: [String]? = nil, viz: CoachViz? = nil, hadImage: Bool? = nil, followUps: [String]? = nil,
         blocked: Bool? = nil, imageContext: String? = nil, ui: CoachGeneratedUI? = nil, screenContext: String? = nil) {
        self.toolNames = toolNames
        self.viz = viz
        self.hadImage = hadImage
        self.followUps = followUps
        self.blocked = blocked
        self.imageContext = imageContext
        self.ui = ui
        self.screenContext = screenContext
    }

    private enum CodingKeys: String, CodingKey {
        case toolNames, viz, hadImage, followUps, blocked, imageContext, ui, screenContext
    }

    /// Field by field, so one malformed value (an old visual shape, say) never drops the rest of the meta.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolNames = c.lossy([String].self, .toolNames)
        viz = c.lossy(CoachViz.self, .viz)
        hadImage = c.lossy(Bool.self, .hadImage)
        followUps = c.lossy([String].self, .followUps)
        blocked = c.lossy(Bool.self, .blocked)
        imageContext = c.lossy(String.self, .imageContext)
        ui = c.lossy(CoachGeneratedUI.self, .ui)
        screenContext = c.lossy(String.self, .screenContext)
    }

    /// `newer` over `self`, field by field: a non-nil field wins, so a re-save that only carries the visual
    /// or the follow-ups keeps everything already known.
    func merged(with newer: CoachMessageMeta?) -> CoachMessageMeta {
        guard let newer else { return self }
        return CoachMessageMeta(toolNames: newer.toolNames ?? toolNames, viz: newer.viz ?? viz,
                                hadImage: newer.hadImage ?? hadImage, followUps: newer.followUps ?? followUps,
                                blocked: newer.blocked ?? blocked, imageContext: newer.imageContext ?? imageContext,
                                ui: newer.ui ?? ui, screenContext: newer.screenContext ?? screenContext)
    }
}

struct CoachStoredMessage: Codable, Equatable, Sendable {
    let clientId: String
    let role: String
    let content: String
    let meta: CoachMessageMeta?
    let createdAt: String
    var threadId: String? = nil
    /// Sent only with the first row of a new thread: the title the server stores until the model names it.
    var threadTitle: String? = nil

    init(clientId: String, role: String, content: String, meta: CoachMessageMeta?, createdAt: String,
         threadId: String? = nil, threadTitle: String? = nil) {
        self.clientId = clientId
        self.role = role
        self.content = content
        self.meta = meta
        self.createdAt = createdAt
        self.threadId = threadId
        self.threadTitle = threadTitle
    }

    private enum CodingKeys: String, CodingKey { case clientId, role, content, meta, createdAt, threadId, threadTitle }

    /// A row without a client id or role is unusable and throws, so a lossy page drops it; everything else
    /// falls back (a bad `meta` decodes as nil instead of losing the message).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try c.decode(String.self, forKey: .clientId)
        role = try c.decode(String.self, forKey: .role)
        content = c.lossy(String.self, .content) ?? ""
        meta = c.lossy(CoachMessageMeta.self, .meta)
        createdAt = c.lossy(String.self, .createdAt) ?? ""
        threadId = c.lossy(String.self, .threadId)?.lowercased()
        threadTitle = c.lossy(String.self, .threadTitle)
    }
}

// MARK: - SSE parsing

/// Turns the relay's OpenAI-style SSE lines into harness events. Pure state machine so it can be
/// tested without a network: the relay already renames provider `reasoning_content` to `reasoning`,
/// and models that inline their reasoning in `<think>…</think>` are split here.
struct CoachSSEParser {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolDelta: Decodable {
                    struct Function: Decodable { let name: String?; let arguments: String? }
                    let index: Int?
                    let id: String?
                    let function: Function?
                }
                let content: String?
                let reasoning: String?
                let tool_calls: [ToolDelta]?
            }
            let delta: Delta?
            let finish_reason: String?
        }
        let choices: [Choice]?
    }

    private var insideThink = false
    private var buffer = ""
    private var pending: [Int: (id: String, name: String, args: String)] = [:]
    private var finished = false

    mutating func consume(line: String) -> [CoachStreamEvent] {
        guard !finished, line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return end() }
        guard let data = payload.data(using: .utf8),
              let choice = (try? JSONDecoder().decode(Chunk.self, from: data))?.choices?.first else { return [] }

        var events: [CoachStreamEvent] = []
        for tc in choice.delta?.tool_calls ?? [] {
            let i = tc.index ?? 0
            var call = pending[i] ?? (id: "", name: "", args: "")
            if let id = tc.id, !id.isEmpty { call.id = id }
            if let name = tc.function?.name, !name.isEmpty { call.name = name }
            call.args += tc.function?.arguments ?? ""
            pending[i] = call
        }
        if let r = choice.delta?.reasoning, !r.isEmpty { events.append(.thinking(r)) }
        if let text = choice.delta?.content, !text.isEmpty { events += route(text) }
        if choice.finish_reason != nil { events += end() }
        return events
    }

    /// Flushes anything held back when the connection closes without a terminal chunk.
    mutating func finish() -> [CoachStreamEvent] { finished ? [] : end() }

    private mutating func end() -> [CoachStreamEvent] {
        var events: [CoachStreamEvent] = []
        if !buffer.isEmpty { events.append(insideThink ? .thinking(buffer) : .content(buffer)); buffer = "" }
        let calls = pending.sorted { $0.key < $1.key }
            .filter { !$0.value.name.isEmpty }
            .map { CoachToolCall(id: $0.value.id.isEmpty ? "call_\($0.key)" : $0.value.id, name: $0.value.name, arguments: $0.value.args) }
        if !calls.isEmpty { events.append(.toolCalls(calls)) }
        events.append(.done)
        finished = true
        return events
    }

    private mutating func route(_ text: String) -> [CoachStreamEvent] {
        buffer += text
        var out: [CoachStreamEvent] = []
        while !buffer.isEmpty {
            let tag = insideThink ? "</think>" : "<think>"
            if let hit = buffer.range(of: tag) {
                let before = String(buffer[..<hit.lowerBound])
                if !before.isEmpty { out.append(insideThink ? .thinking(before) : .content(before)) }
                buffer = String(buffer[hit.upperBound...])
                insideThink.toggle()
                continue
            }
            // A tag can straddle two chunks; hold back only a suffix that could still become one.
            let held = Self.partialTagLength(buffer, tag: tag)
            let emit = String(buffer.dropLast(held))
            if !emit.isEmpty { out.append(insideThink ? .thinking(emit) : .content(emit)) }
            buffer = String(buffer.suffix(held))
            break
        }
        return out
    }

    private static func partialTagLength(_ s: String, tag: String) -> Int {
        for k in stride(from: min(tag.count - 1, s.count), to: 0, by: -1) where s.hasSuffix(String(tag.prefix(k))) {
            return k
        }
        return 0
    }
}

// MARK: - Thread, context and side-call wire types

/// What the server offers beyond the original single conversation. An old server never sends `features`, so
/// every flag reads false and the client keeps its single-thread behaviour: no sidebar, no context tools, no titles.
struct CoachFeatures: Codable, Equatable, Sendable {
    var threads: Bool
    var context: Bool

    static let none = CoachFeatures(threads: false, context: false)

    init(threads: Bool, context: Bool) {
        self.threads = threads
        self.context = context
    }

    private enum CodingKeys: String, CodingKey { case threads, context }

    /// The server sends `1`; a boolean or a numeric string is accepted too.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool {
            if let n = c.lossy(Int.self, key) { return n > 0 }
            if let b = c.lossy(Bool.self, key) { return b }
            if let s = c.lossy(String.self, key) { return (Int(s) ?? 0) > 0 || s == "true" }
            return false
        }
        threads = flag(.threads)
        context = flag(.context)
    }
}

struct CoachServerStatus: Equatable, Sendable {
    var ok: Bool
    var configured: Bool
    var features: CoachFeatures
}

/// A non-2xx answer from one of the thread, context or side-call routes, keeping the status so callers can tell
/// "gone" (404, 410) and "rejected" (400, 409) from "try again" (429, 5xx). Its message is the mapped `CoachAPIError`'s.
struct CoachRouteError: LocalizedError, Equatable, Sendable {
    let status: Int
    let code: String?

    var mapped: CoachAPIError {
        CoachAPI.error(forStatus: status, body: Data((code.map { #"{"error":"\#($0)"}"# } ?? "").utf8))
    }

    var errorDescription: String? { mapped.errorDescription }

    /// Retrying the same request later can succeed.
    var isTransient: Bool { status == 429 || status >= 500 || status == 408 }
}

/// `POST messages`: rows the server refused are listed by client id; the rest were saved.
struct CoachSaveResult: Decodable, Equatable, Sendable {
    struct Rejection: Decodable, Equatable, Sendable {
        let clientId: String
        let reason: String
    }

    var saved: Int
    var rejected: [Rejection]

    init(saved: Int, rejected: [Rejection] = []) {
        self.saved = saved
        self.rejected = rejected
    }

    private enum CodingKeys: String, CodingKey { case saved, rejected }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saved = c.lossy(Int.self, .saved) ?? 0
        rejected = c.lossyList(Rejection.self, .rejected)
    }
}

struct CoachTitleResult: Decodable, Equatable, Sendable {
    var title: String?
    var titleSource: String?
    var generated: Bool?
}

struct CoachMaintainResult: Decodable, Equatable, Sendable {
    /// `queued | done | skipped | busy`.
    var status: String?
    var summarized: Bool?
    var memoryOps: Int?
    var consolidated: Bool?

    private enum CodingKeys: String, CodingKey { case status, summarized, memoryOps, consolidated }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lossy(String.self, .status)
        summarized = c.lossy(Bool.self, .summarized)
        memoryOps = c.lossy(Int.self, .memoryOps) ?? c.lossy([CoachSkippedValue].self, .memoryOps)?.count
        consolidated = c.lossy(Bool.self, .consolidated)
    }
}

struct CoachFollowUpsResult: Decodable, Equatable, Sendable {
    var followUps: [String]
    var title: String?
    /// A title was asked for, but the server has no row for the thread yet; the phone asks `threads/:id/title`
    /// once the thread's rows are saved. False from a server that predates it.
    var titlePending: Bool

    private enum CodingKeys: String, CodingKey { case followUps, title, titlePending }

    init(followUps: [String], title: String? = nil, titlePending: Bool = false) {
        self.followUps = followUps
        self.title = title
        self.titlePending = titlePending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        followUps = c.lossyList(String.self, .followUps)
        title = c.lossy(String.self, .title)
        titlePending = c.lossy(Bool.self, .titlePending) ?? false
    }
}

struct CoachSuggestionsResult: Decodable, Equatable, Sendable {
    var suggestions: [CoachStarterSuggestion]
    /// `model | cache | fallback`.
    var source: String?

    private enum CodingKeys: String, CodingKey { case suggestions, source }

    init(suggestions: [CoachStarterSuggestion], source: String? = nil) {
        self.suggestions = suggestions
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suggestions = c.lossyList(CoachStarterSuggestion.self, .suggestions)
        source = c.lossy(String.self, .source)
    }
}

/// A coding key built from any string, for shapes whose keys may arrive camelCase or snake_case.
struct CoachAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

extension KeyedDecodingContainer where Key == CoachAnyKey {
    /// The first of `names` that holds a well-formed value.
    func first<T: Decodable>(_ type: T.Type, _ names: String...) -> T? {
        for name in names { if let v = lossy(T.self, CoachAnyKey(name)) { return v } }
        return nil
    }

    func firstList<T: Decodable>(_ type: T.Type, _ names: String...) -> [T] {
        for name in names where contains(CoachAnyKey(name)) {
            return lossyList(T.self, CoachAnyKey(name))
        }
        return []
    }
}

/// `POST context`: what exists in the user's history, never its contents (`docs/COACH_MEMORY.md` §3
/// `coach_context_manifest_v1`). Decoded leniently: keys may be camelCase or snake_case, `memories` may be the
/// ranked object or its bare list, and open loops may be strings or `{text}` objects.
struct CoachContextManifest: Codable, Equatable, Sendable {
    struct ThreadSummary: Codable, Equatable, Sendable {
        var id: String
        var title: String?
        var summary: String?
        var summaryThrough: String?
        var summaryMessages: Int
        var messageCount: Int
        var openLoops: [String]

        init(id: String, title: String? = nil, summary: String? = nil, summaryThrough: String? = nil,
             summaryMessages: Int = 0, messageCount: Int = 0, openLoops: [String] = []) {
            self.id = id.lowercased()
            self.title = title
            self.summary = summary
            self.summaryThrough = summaryThrough
            self.summaryMessages = summaryMessages
            self.messageCount = messageCount
            self.openLoops = openLoops
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CoachAnyKey.self)
            id = (c.first(String.self, "id") ?? "").lowercased()
            title = c.first(String.self, "title")
            summary = c.first(String.self, "summary")
            summaryThrough = c.first(String.self, "summaryThrough", "summary_through")
            summaryMessages = c.first(Int.self, "summaryMessages", "summary_messages") ?? 0
            messageCount = c.first(Int.self, "messageCount", "message_count") ?? 0
            openLoops = c.first([String].self, "openLoops", "open_loops")
                ?? c.firstList(OpenLoop.self, "openLoops", "open_loops").map(\.text)
        }
    }

    struct LibraryThread: Codable, Equatable, Sendable {
        var id: String
        var title: String?
        var lastMessageAt: String?
        var snippet: String?

        init(id: String, title: String? = nil, lastMessageAt: String? = nil, snippet: String? = nil) {
            self.id = id.lowercased()
            self.title = title
            self.lastMessageAt = lastMessageAt
            self.snippet = snippet
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CoachAnyKey.self)
            guard let id = c.first(String.self, "id", "threadId", "thread_id") else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "thread id"))
            }
            self.id = id.lowercased()
            title = c.first(String.self, "title")
            lastMessageAt = c.first(String.self, "lastMessageAt", "last_message_at")
            snippet = c.first(String.self, "snippet")
        }
    }

    struct Library: Codable, Equatable, Sendable {
        var threadCount: Int
        var firstAt: String?
        var lastAt: String?
        var recent: [LibraryThread]
        var relevant: [LibraryThread]

        init(threadCount: Int = 0, firstAt: String? = nil, lastAt: String? = nil,
             recent: [LibraryThread] = [], relevant: [LibraryThread] = []) {
            self.threadCount = threadCount
            self.firstAt = firstAt
            self.lastAt = lastAt
            self.recent = recent
            self.relevant = relevant
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CoachAnyKey.self)
            threadCount = c.first(Int.self, "threadCount", "thread_count") ?? 0
            firstAt = c.first(String.self, "firstAt", "first_at")
            lastAt = c.first(String.self, "lastAt", "last_at")
            recent = c.firstList(LibraryThread.self, "recent")
            relevant = c.firstList(LibraryThread.self, "relevant")
        }
    }

    struct OpenLoop: Codable, Equatable, Sendable {
        var threadId: String?
        var title: String?
        var text: String

        init(threadId: String? = nil, title: String? = nil, text: String) {
            self.threadId = threadId?.lowercased()
            self.title = title
            self.text = text
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
                self.init(text: text)
                return
            }
            let c = try decoder.container(keyedBy: CoachAnyKey.self)
            guard let text = c.first(String.self, "text") else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "open loop text"))
            }
            self.init(threadId: c.first(String.self, "threadId", "thread_id"), title: c.first(String.self, "title"), text: text)
        }
    }

    var memories: [CoachMemory]
    var memoryCount: Int
    var memoryTopics: [String: Int]
    var thread: ThreadSummary?
    var library: Library
    var openLoops: [OpenLoop]
    var memoryRevision: Int?

    init(memories: [CoachMemory] = [], memoryCount: Int = 0, memoryTopics: [String: Int] = [:],
         thread: ThreadSummary? = nil, library: Library = Library(), openLoops: [OpenLoop] = [],
         memoryRevision: Int? = nil) {
        self.memories = memories
        self.memoryCount = memoryCount
        self.memoryTopics = memoryTopics
        self.thread = thread
        self.library = library
        self.openLoops = openLoops
        self.memoryRevision = memoryRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CoachAnyKey.self)
        var ranked: (memories: [CoachMemory], total: Int?, topics: [String: Int]?) = ([], nil, nil)
        if (try? c.nestedUnkeyedContainer(forKey: CoachAnyKey("memories"))) != nil {
            ranked.memories = c.lossyList(CoachMemory.self, CoachAnyKey("memories"))
        } else if let nested = try? c.nestedContainer(keyedBy: CoachAnyKey.self, forKey: CoachAnyKey("memories")) {
            ranked = (nested.firstList(CoachMemory.self, "memories"), nested.first(Int.self, "total"),
                      nested.first([String: Int].self, "topics"))
        }
        memories = ranked.memories
        memoryCount = c.first(Int.self, "memoryCount", "memory_count") ?? ranked.total ?? ranked.memories.count
        memoryTopics = c.first([String: Int].self, "memoryTopics", "memory_topics") ?? ranked.topics
            ?? (c.first([String].self, "memoryTopics", "memory_topics") ?? []).reduce(into: [:]) { $0[$1] = 0 }
        thread = c.first(ThreadSummary.self, "thread").flatMap { $0.id.isEmpty ? nil : $0 }
        library = c.first(Library.self, "library") ?? Library()
        openLoops = c.firstList(OpenLoop.self, "openLoops", "open_loops")
        memoryRevision = c.first(Int.self, "memoryRevision", "memory_revision")
            ?? c.first(String.self, "memoryRevision", "memory_revision").flatMap { Int($0) }
    }

    /// Drops one forgotten memory so a cached manifest can never put it back into a prompt.
    func removingMemory(id: String) -> CoachContextManifest {
        var copy = self
        copy.memories.removeAll { $0.id == id }
        copy.memoryCount = max(0, copy.memoryCount - (memories.count - copy.memories.count))
        return copy
    }

    /// Drops every mention of a deleted thread (its summary, its library rows and its open loops), so a cached
    /// manifest can never bring a deleted chat back into a prompt.
    func removingThread(id: String) -> CoachContextManifest {
        let key = id.lowercased()
        var copy = self
        if copy.thread?.id == key { copy.thread = nil }
        copy.library.recent.removeAll { $0.id == key }
        copy.library.relevant.removeAll { $0.id == key }
        copy.openLoops.removeAll { $0.threadId == key }
        return copy
    }

    /// This manifest standing in for a fresh one (the fetch missed its wait): `relevant` was ranked for another
    /// question, so it goes; another thread's summary goes too (`thread` nil) when it is not `threadId`'s own.
    func asFallback(for threadId: String) -> CoachContextManifest {
        var copy = self
        copy.library.relevant = []
        if let own = copy.thread?.id, own != threadId.lowercased() { copy.thread = nil }
        return copy
    }
}

/// `POST context/search`.
struct CoachContextSearchResult: Decodable, Equatable, Sendable {
    struct Month: Decodable, Equatable, Sendable { var month: String; var hits: Int }
    struct Hit: Decodable, Equatable, Sendable {
        var threadId: String
        var title: String?
        var at: String?
        var role: String?
        var snippet: String?
    }
    struct ThreadHit: Decodable, Equatable, Sendable {
        var threadId: String
        var title: String?
        var lastMessageAt: String?
        var hits: Int?
        var snippet: String?
        var summary: String?
        var topics: [String]?
    }

    var terms: [String]
    var droppedTerms: [String]
    var totalHits: Int
    var months: [Month]
    var hits: [Hit]
    var threads: [ThreadHit]

    private enum CodingKeys: String, CodingKey { case terms, droppedTerms, totalHits, months, hits, threads }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terms = c.lossyList(String.self, .terms)
        droppedTerms = c.lossyList(String.self, .droppedTerms)
        totalHits = c.lossy(Int.self, .totalHits) ?? 0
        months = c.lossyList(Month.self, .months)
        hits = c.lossyList(Hit.self, .hits)
        threads = c.lossyList(ThreadHit.self, .threads)
    }
}

/// `POST context/thread`: one capped window of an earlier chat.
struct CoachContextThreadResult: Decodable, Equatable, Sendable {
    struct Info: Decodable, Equatable, Sendable {
        var id: String
        var title: String?
        var createdAt: String?
        var lastMessageAt: String?
        var messageCount: Int?
        var summary: String?
    }
    struct Line: Decodable, Equatable, Sendable {
        var role: String
        var at: String?
        var content: String
    }

    var thread: Info?
    var messages: [Line]
    /// `recent | around_matches`.
    var window: String?
    var hasMore: Bool
    var nextCursor: String?

    private enum CodingKeys: String, CodingKey { case thread, messages, window, hasMore, nextCursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thread = c.lossy(Info.self, .thread)
        messages = c.lossyList(Line.self, .messages)
        window = c.lossy(String.self, .window)
        hasMore = c.lossy(Bool.self, .hasMore) ?? false
        nextCursor = c.lossy(String.self, .nextCursor)
    }
}

/// `POST context/recall`: a server-side map over the matching chats. The answer is evidence, never the reply.
struct CoachRecallResult: Decodable, Equatable, Sendable {
    struct Source: Decodable, Equatable, Sendable {
        var threadId: String
        var title: String?
        var at: String?
    }
    struct Coverage: Decodable, Equatable, Sendable {
        var threadsMatched: Int?
        var threadsExamined: Int?
        var totalHits: Int?
        var truncated: Bool?
    }

    var answer: String
    var sources: [Source]
    var coverage: Coverage?
    /// `answered | partial | nothing_found | budget | unavailable`.
    var status: String

    private enum CodingKeys: String, CodingKey { case answer, sources, coverage, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answer = c.lossy(String.self, .answer) ?? ""
        sources = c.lossyList(Source.self, .sources)
        coverage = c.lossy(Coverage.self, .coverage)
        status = c.lossy(String.self, .status) ?? "unavailable"
    }
}

// MARK: - Client

/// Client for the `coach` edge function: model relay, memory, and conversation history. Authenticates
/// exactly like the score reads do, with the signed-in account's installation token as the bearer.
final class CoachAPI: @unchecked Sendable {
    static let shared: CoachAPI = {
        #if DEBUG
        if let seam = debugSeam(environment: ProcessInfo.processInfo.environment) {
            return CoachAPI(endpoint: { seam.endpoint }, identity: { seam.identity })
        }
        #endif
        return CoachAPI()
    }()

    /// Per-route request timeouts (`docs/COACH_MEMORY.md` §7.1). The model relay, the visual pipeline and
    /// the photo description keep their own.
    enum Timeout {
        static let recall: TimeInterval = 30
        static let search: TimeInterval = 10
        static let read: TimeInterval = 10
        static let followUps: TimeInterval = 12
        static let suggestions: TimeInterval = 12
        static let maintain: TimeInterval = 10
        static let standard: TimeInterval = 15
    }

    private let session: URLSession
    private let endpoint: @Sendable () -> URL?
    private let identity: @Sendable () -> CloudPushIdentity?

    init(session: URLSession = .shared,
         endpoint: @escaping @Sendable () -> URL? = { CoachAPI.derivedEndpoint() },
         identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() }) {
        self.session = session
        self.endpoint = endpoint
        self.identity = identity
    }

    /// The `coach` route, derived from the configured push receiver by swapping the function name, the
    /// same single-source-of-truth trick `ServerScoreRepository.derivedEndpoint` uses for `scores`.
    static func derivedEndpoint() -> URL? {
        guard let push = CloudPushSettings.receiverURL,
              var components = URLComponents(url: push, resolvingAgainstBaseURL: false) else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        guard parts.last == "push" else { return nil }
        parts[parts.count - 1] = "coach"
        components.path = "/" + parts.joined(separator: "/")
        return components.url
    }

    var isAvailable: Bool { endpoint() != nil && identity() != nil }

    /// The account every request is made as; local caches and the outbox are kept per owner.
    var ownerId: String? { identity()?.ownerId }

    #if DEBUG
    struct DebugSeam {
        let endpoint: URL
        let identity: CloudPushIdentity
    }

    /// `NARA_COACH_URL`, `NARA_COACH_TOKEN` and `NARA_COACH_OWNER` point `shared` at a local coach for UI tests
    /// and simulator runs (`simctl launch` passes them as `SIMCTL_CHILD_*`). Only a loopback or `.local` host
    /// with a `noop_` token is accepted, and only in DEBUG builds.
    static func debugSeam(environment env: [String: String]) -> DebugSeam? {
        guard let raw = env["NARA_COACH_URL"], let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local"),
              let token = env["NARA_COACH_TOKEN"], token.hasPrefix("noop_"), token.count > 5 else { return nil }
        let owner = env["NARA_COACH_OWNER"].flatMap { UUID(uuidString: $0)?.uuidString }
            ?? "00000000-0000-4000-8000-00000000c0ac"
        let identity = CloudPushIdentity(ownerId: owner, sourceId: "00000000-0000-4000-8000-00000000d0b6",
                                         tokenId: "00000000-0000-4000-8000-00000000d0b7", uploadToken: token)
        return DebugSeam(endpoint: url, identity: identity)
    }
    #endif

    static func error(forStatus status: Int, body: Data) -> CoachAPIError {
        let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
        switch status {
        case 401, 403: return .unauthorized
        case 413: return .tooLarge
        case 429 where code == "daily_limit": return .dailyLimit
        default: return .unavailable
        }
    }

    /// `expectedOwner` pins the request to one account: when the signed-in credential is someone else's (an
    /// account switch mid-flush), nothing is sent and `.unauthorized` is thrown.
    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                         body: Any? = nil, timeout: TimeInterval = Timeout.standard,
                         expectedOwner: String? = nil) throws -> URLRequest {
        guard let base = endpoint(), let id = identity() else { throw CoachAPIError.notConfigured }
        if let expectedOwner, id.ownerId.lowercased() != expectedOwner.lowercased() { throw CoachAPIError.unauthorized }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw CoachAPIError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        CloudReceiverAuth.apply(id, to: &req)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CoachAPIError.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(forStatus: http.statusCode, body: data) }
        return data
    }

    /// `send` for the routes that need the status of a failure: throws `CoachRouteError` instead of the mapped error.
    private func call(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CoachAPIError.unavailable }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw CoachRouteError(status: http.statusCode, code: code)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await call(req))
    }

    /// True when the relay answers and has its model key configured. Throws the mapped error on 401/5xx.
    func isReachable() async throws -> Bool {
        let status = try await status()
        return status.ok && status.configured
    }

    /// `GET status`, including the feature flags a thread-aware server adds.
    func status() async throws -> CoachServerStatus {
        struct Reply: Decodable {
            let ok: Bool
            let configured: Bool
            let features: CoachFeatures
            private enum CodingKeys: String, CodingKey { case ok, configured, features }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                ok = try c.decode(Bool.self, forKey: .ok)
                configured = try c.decode(Bool.self, forKey: .configured)
                features = c.lossy(CoachFeatures.self, .features) ?? .none
            }
        }
        let reply = try JSONDecoder().decode(Reply.self, from: try await send(try request("status", timeout: 10)))
        return CoachServerStatus(ok: reply.ok, configured: reply.configured, features: reply.features)
    }

    // MARK: Model relay

    func stream(mode: CoachMode, messages: [CoachWireMessage], tools: [[String: Any]]? = nil,
                reasoningEffort: String, temperature: Double, maxTokens: Int) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = ["mode": mode.rawValue, "messages": messages.map(\.json),
                                               "temperature": temperature, "max_tokens": maxTokens, "stream": true,
                                               "reasoning_effort": reasoningEffort]
                    if let tools { body["tools"] = tools; body["tool_choice"] = "auto" }
                    let req = try request("chat", method: "POST", body: body, timeout: 120)
                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw CoachAPIError.unavailable }
                    guard http.statusCode == 200 else {
                        var raw = Data()
                        for try await byte in bytes { raw.append(byte); if raw.count > 2048 { break } }
                        throw Self.error(forStatus: http.statusCode, body: raw)
                    }
                    var parser = CoachSSEParser()
                    for try await line in bytes.lines {
                        for event in parser.consume(line: line) { continuation.yield(event) }
                    }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Visual pipeline: `routeOnly` asks just whether the answer deserves a visual (and which kind);
    /// a request carrying that `route` designs and fact-checks it. A nil visual means "show nothing".
    func visual(_ request: CoachVisualRequest) async throws -> CoachVisualResponse {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let data = try await send(try self.request("visual", method: "POST", body: body, timeout: request.routeOnly ? 25 : 120))
        return try JSONDecoder().decode(CoachVisualResponse.self, from: data)
    }

    /// Stage one of the image pipeline: the vision model describes the photo, and the description is
    /// handed to the text model as context.
    func describeImage(_ jpeg: Data) async throws -> String {
        let prompt = "Describe what you see in this image concisely. Focus on health- and fitness-relevant details: "
            + "exercise form, food or nutrition labels, gym equipment, body composition, sleep or wearable screens, or injuries. "
            + "If nothing fitness-related is visible, describe the image generally in 2-3 sentences."
        let body: [String: Any] = ["mode": CoachMode.vision.rawValue, "stream": false, "temperature": 0.1,
                                   "messages": [CoachWireMessage(role: "user", content: prompt, imageJPEG: jpeg).json]]
        let data = try await send(try request("chat", method: "POST", body: body, timeout: 60))
        let content = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? String ?? ""
        return Self.stripThinking(content)
    }

    static func stripThinking(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        return s.replacingOccurrences(of: "</think>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Memory

    /// Without `query`, the server's default order (importance, then newest; 50 rows). With one, ranked by
    /// relevance. `limit` goes up to 200 on a thread-aware server. Rows that fail to decode are dropped.
    func memories(query: String? = nil, topic: String? = nil, limit: Int? = nil) async throws -> [CoachMemory] {
        struct Reply: Decodable {
            let memories: [CoachMemory]
            private enum CodingKeys: String, CodingKey { case memories }
            init(from decoder: Decoder) throws {
                memories = try decoder.container(keyedBy: CodingKeys.self).lossyList(CoachMemory.self, .memories)
            }
        }
        var items: [URLQueryItem] = []
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty { items.append(.init(name: "q", value: query)) }
        if let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty { items.append(.init(name: "topic", value: topic)) }
        if let limit { items.append(.init(name: "limit", value: String(min(max(limit, 1), 200)))) }
        return try JSONDecoder().decode(Reply.self, from: try await send(try request("memories", query: items))).memories
    }

    func saveMemory(content: String, topic: String, importance: Int, threadId: String? = nil) async throws -> CoachMemory {
        struct Reply: Decodable { let memory: CoachMemory }
        var body: [String: Any] = ["content": content, "topic": topic, "importance": importance]
        if let threadId { body["threadId"] = threadId }
        return try JSONDecoder().decode(Reply.self, from: try await send(try request("memories", method: "POST", body: body))).memory
    }

    func deleteMemory(id: String) async throws {
        _ = try await send(try request("memories/\(id)", method: "DELETE"))
    }

    func clearMemories() async throws {
        _ = try await send(try request("memories", method: "DELETE"))
    }

    // MARK: Profile

    /// The owner's saved profile, or nil before anything has been saved.
    func profile() async throws -> CloudProfile? {
        struct Reply: Decodable { let profile: CloudProfile? }
        return try JSONDecoder().decode(Reply.self, from: try await send(try request("profile", timeout: 15))).profile
    }

    func saveProfile(_ profile: CloudProfile) async throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        _ = try await send(try request("profile", method: "PUT", body: body, timeout: 15))
    }

    /// The account-wide preferences (`SettingsCloudSync`), keyed as the route stores them. Nil until some
    /// phone has saved one.
    func settings() async throws -> [String: Any]? {
        let reply = try JSONSerialization.jsonObject(with: try await send(try request("settings", timeout: 15)))
        return (reply as? [String: Any])?["settings"] as? [String: Any]
    }

    /// Saves the given keys; the account keeps the others as they were.
    func saveSettings(_ settings: [String: Any]) async throws {
        _ = try await send(try request("settings", method: "PUT", body: settings, timeout: 15))
    }

    // MARK: Conversation

    /// The latest `limit` messages across every thread, oldest first. Rows that fail to decode are dropped.
    func messages(limit: Int = 60) async throws -> [CoachStoredMessage] {
        let data = try await send(try request("messages", query: [URLQueryItem(name: "limit", value: String(limit))]))
        return try JSONDecoder().decode(CoachMessagePage.self, from: data).messages
    }

    /// One page of a thread, oldest first; `cursor` is the previous page's `nextCursor`.
    func messages(threadId: String, limit: Int = 60, cursor: String? = nil) async throws -> CoachMessagePage {
        var items = [URLQueryItem(name: "threadId", value: threadId.lowercased()),
                     URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200)))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await decode(CoachMessagePage.self, try request("messages", query: items))
    }

    /// Saves up to 40 rows. A 2xx can still list rows the server refused (`thread_deleted`, `thread_conflict`);
    /// any other answer throws `CoachRouteError` with its status. With `owner`, the rows go only under that
    /// account's credential (`CoachAPIError.unauthorized` otherwise), checked as each request is built.
    @discardableResult
    func saveMessages(_ messages: [CoachStoredMessage], asOwner owner: String? = nil) async throws -> CoachSaveResult {
        guard !messages.isEmpty else { return CoachSaveResult(saved: 0) }
        let rows = try messages.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let data = try await call(try request("messages", method: "POST", body: ["messages": rows], expectedOwner: owner))
        return (try? JSONDecoder().decode(CoachSaveResult.self, from: data)) ?? CoachSaveResult(saved: messages.count)
    }

    /// Every thread and message, or one thread's when `threadId` is given.
    func clearMessages(threadId: String? = nil) async throws {
        let query = threadId.map { [URLQueryItem(name: "threadId", value: $0.lowercased())] } ?? []
        _ = try await send(try request("messages", method: "DELETE", query: query))
    }

    // MARK: Threads and folders

    func threads(limit: Int = 50, cursor: String? = nil, folderId: String? = nil) async throws -> CoachThreadPage {
        var items = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let folderId { items.append(URLQueryItem(name: "folderId", value: folderId)) }
        return try await decode(CoachThreadPage.self, try request("threads", query: items))
    }

    /// Thread-grouped search; `record` stores a query of 3 or more characters in the user's recent searches.
    func searchThreads(query: String, record: Bool = false) async throws -> [CoachThread] {
        var items = [URLQueryItem(name: "q", value: query)]
        if record { items.append(URLQueryItem(name: "record", value: "1")) }
        return try await decode(CoachThreadPage.self, try request("threads", query: items, timeout: Timeout.search)).threads
    }

    func createThread(id: String, title: String? = nil, folderId: String? = nil) async throws -> CoachThread {
        var body: [String: Any] = ["id": id.lowercased()]
        if let title { body["title"] = title }
        if let folderId { body["folderId"] = folderId }
        return try await decode(ThreadReply.self, try request("threads", method: "POST", body: body)).thread
    }

    func thread(id: String) async throws -> CoachThread {
        try await decode(ThreadReply.self, try request("threads/\(id.lowercased())")).thread
    }

    /// `folderId: .some(nil)` takes the thread out of its folder; a nil argument leaves that field alone.
    func updateThread(id: String, title: String? = nil, folderId: String?? = nil, pinned: Bool? = nil) async throws -> CoachThread {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let folderId { body["folderId"] = folderId.map { $0 as Any } ?? NSNull() }
        if let pinned { body["pinned"] = pinned }
        return try await decode(ThreadReply.self, try request("threads/\(id.lowercased())", method: "PATCH", body: body)).thread
    }

    func deleteThread(id: String) async throws {
        _ = try await call(try request("threads/\(id.lowercased())", method: "DELETE"))
    }

    func generateTitle(threadId: String, question: String, answer: String? = nil, locale: String? = nil) async throws -> CoachTitleResult {
        var body: [String: Any] = ["question": question]
        if let answer { body["answer"] = answer }
        if let locale { body["locale"] = locale }
        return try await decode(CoachTitleResult.self, try request("threads/\(threadId.lowercased())/title", method: "POST", body: body))
    }

    /// Asks the server to fold new turns into the thread's summary and curate memories from them.
    @discardableResult
    func maintain(threadId: String) async throws -> CoachMaintainResult {
        try await decode(CoachMaintainResult.self,
                         try request("threads/\(threadId.lowercased())/maintain", method: "POST", body: [String: Any](),
                                     timeout: Timeout.maintain))
    }

    func folders() async throws -> [CoachFolder] {
        try await decode(CoachThreadPage.self, try request("folders")).folders
    }

    func createFolder(id: String, name: String) async throws -> CoachFolder {
        try await decode(FolderReply.self, try request("folders", method: "POST", body: ["id": id.lowercased(), "name": name])).folder
    }

    func updateFolder(id: String, name: String? = nil, sortOrder: Int? = nil) async throws -> CoachFolder {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let sortOrder { body["sortOrder"] = sortOrder }
        return try await decode(FolderReply.self, try request("folders/\(id.lowercased())", method: "PATCH", body: body)).folder
    }

    func deleteFolder(id: String) async throws {
        _ = try await call(try request("folders/\(id.lowercased())", method: "DELETE"))
    }

    private struct ThreadReply: Decodable { let thread: CoachThread }
    private struct FolderReply: Decodable { let folder: CoachFolder }

    // MARK: Side calls

    /// Next-question suggestions for a finished answer and, with `wantTitle`, the thread's title in the same call.
    func followUps(threadId: String?, question: String, answer: String, asked: [String] = [],
                   locale: String? = nil, wantTitle: Bool = false) async throws -> CoachFollowUpsResult {
        var body: [String: Any] = ["question": question, "answer": answer, "asked": asked]
        if let threadId { body["threadId"] = threadId.lowercased() }
        if let locale { body["locale"] = locale }
        if wantTitle { body["wantTitle"] = true }
        return try await decode(CoachFollowUpsResult.self,
                                try request("followups", method: "POST", body: body, timeout: Timeout.followUps))
    }

    func suggestions(state: CoachUserStateSnapshot?, fallback: [String], refresh: Bool = false,
                     locale: String? = nil) async throws -> CoachSuggestionsResult {
        var body: [String: Any] = ["fallback": fallback]
        if let state, let encoded = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) { body["state"] = encoded }
        if refresh { body["refresh"] = true }
        if let locale { body["locale"] = locale }
        return try await decode(CoachSuggestionsResult.self,
                                try request("suggestions", method: "POST", body: body, timeout: Timeout.suggestions))
    }

    // MARK: Context

    func context(threadId: String?, question: String?) async throws -> CoachContextManifest {
        var body: [String: Any] = [:]
        if let threadId { body["threadId"] = threadId.lowercased() }
        if let question, !question.isEmpty { body["question"] = String(question.prefix(2_000)) }
        return try await decode(CoachContextManifest.self, try request("context", method: "POST", body: body))
    }

    func contextSearch(query: String?, from: String? = nil, to: String? = nil, days: Int? = nil, limit: Int? = nil,
                       excludeThreadId: String? = nil) async throws -> CoachContextSearchResult {
        var body: [String: Any] = ["query": query ?? ""]
        if let from { body["from"] = from }
        if let to { body["to"] = to }
        if let days { body["days"] = days }
        if let limit { body["limit"] = limit }
        if let excludeThreadId { body["excludeThreadId"] = excludeThreadId.lowercased() }
        return try await decode(CoachContextSearchResult.self,
                                try request("context/search", method: "POST", body: body, timeout: Timeout.search))
    }

    func contextThread(threadId: String, query: String? = nil, cursor: String? = nil,
                       limit: Int? = nil) async throws -> CoachContextThreadResult {
        var body: [String: Any] = ["threadId": threadId.lowercased()]
        if let query, !query.isEmpty { body["query"] = query }
        if let cursor { body["cursor"] = cursor }
        if let limit { body["limit"] = limit }
        return try await decode(CoachContextThreadResult.self,
                                try request("context/thread", method: "POST", body: body, timeout: Timeout.read))
    }

    func contextRecall(question: String, keywords: String? = nil, threadId: String? = nil, includeCurrent: Bool = false,
                       from: String? = nil, to: String? = nil) async throws -> CoachRecallResult {
        var body: [String: Any] = ["question": question]
        if let keywords, !keywords.isEmpty { body["keywords"] = keywords }
        if let threadId { body["threadId"] = threadId.lowercased() }
        if includeCurrent { body["includeCurrent"] = true }
        if let from { body["from"] = from }
        if let to { body["to"] = to }
        return try await decode(CoachRecallResult.self,
                                try request("context/recall", method: "POST", body: body, timeout: Timeout.recall))
    }
}
