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
}

struct CoachMessageMeta: Codable, Equatable, Sendable {
    var toolNames: [String]?
    var viz: CoachViz?
    var hadImage: Bool?
}

struct CoachStoredMessage: Codable, Equatable, Sendable {
    let clientId: String
    let role: String
    let content: String
    let meta: CoachMessageMeta?
    let createdAt: String
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

// MARK: - Client

/// Client for the `coach` edge function: model relay, memory, and conversation history. Authenticates
/// exactly like the score reads do, with the installation token as bearer plus the fleet token header.
final class CoachAPI: @unchecked Sendable {
    static let shared = CoachAPI()

    private let session: URLSession
    private let endpoint: @Sendable () -> URL?
    private let fleetToken: @Sendable () -> String
    private let identity: @Sendable () -> CloudPushIdentity?

    init(session: URLSession = .shared,
         endpoint: @escaping @Sendable () -> URL? = { CoachAPI.derivedEndpoint() },
         fleetToken: @escaping @Sendable () -> String = { CloudPushSettings.fleetToken },
         identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() }) {
        self.session = session
        self.endpoint = endpoint
        self.fleetToken = fleetToken
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

    var isAvailable: Bool { endpoint() != nil && !fleetToken().isEmpty && identity() != nil }

    static func error(forStatus status: Int, body: Data) -> CoachAPIError {
        let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
        switch status {
        case 401, 403: return .unauthorized
        case 413: return .tooLarge
        case 429 where code == "daily_limit": return .dailyLimit
        default: return .unavailable
        }
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                         body: Any? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        let fleet = fleetToken()
        guard let base = endpoint(), !fleet.isEmpty, let id = identity() else { throw CoachAPIError.notConfigured }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw CoachAPIError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(id.uploadToken)", forHTTPHeaderField: "Authorization")
        req.setValue(fleet, forHTTPHeaderField: "x-noop-fleet-token")
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

    /// True when the relay answers and has its model key configured. Throws the mapped error on 401/5xx.
    func isReachable() async throws -> Bool {
        struct Reply: Decodable { let ok: Bool; let configured: Bool }
        let reply = try JSONDecoder().decode(Reply.self, from: try await send(try request("status", timeout: 10)))
        return reply.ok && reply.configured
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

    func memories() async throws -> [CoachMemory] {
        struct Reply: Decodable { let memories: [CoachMemory] }
        return try JSONDecoder().decode(Reply.self, from: try await send(try request("memories"))).memories
    }

    func saveMemory(content: String, topic: String, importance: Int) async throws -> CoachMemory {
        struct Reply: Decodable { let memory: CoachMemory }
        let body: [String: Any] = ["content": content, "topic": topic, "importance": importance]
        return try JSONDecoder().decode(Reply.self, from: try await send(try request("memories", method: "POST", body: body))).memory
    }

    func deleteMemory(id: String) async throws {
        _ = try await send(try request("memories/\(id)", method: "DELETE"))
    }

    func clearMemories() async throws {
        _ = try await send(try request("memories", method: "DELETE"))
    }

    // MARK: Conversation

    func messages(limit: Int = 60) async throws -> [CoachStoredMessage] {
        struct Reply: Decodable { let messages: [CoachStoredMessage] }
        let data = try await send(try request("messages", query: [URLQueryItem(name: "limit", value: String(limit))]))
        return try JSONDecoder().decode(Reply.self, from: data).messages
    }

    func saveMessages(_ messages: [CoachStoredMessage]) async throws {
        guard !messages.isEmpty else { return }
        let rows = try messages.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        _ = try await send(try request("messages", method: "POST", body: ["messages": rows]))
    }

    func clearMessages() async throws {
        _ = try await send(try request("messages", method: "DELETE"))
    }
}
