import Foundation
@testable import Strand

/// A routed URLProtocol stub for the coach function: each request is answered by `handler` (status, body and
/// an optional delay) and recorded with its decoded JSON body, so the thread, context and side-call routes can
/// be driven without a socket. Installed only on a private session (`session()`), never globally.
final class CoachURLProtocolStub: URLProtocol {
    struct Reply {
        var status: Int = 200
        var body: Data = Data("{}".utf8)
        var delay: TimeInterval = 0

        static func json(_ object: Any, status: Int = 200, delay: TimeInterval = 0) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), delay: delay)
        }

        /// An OpenAI-style SSE stream that says `text` and stops.
        static func sse(_ text: String, delay: TimeInterval = 0) -> Reply {
            let chunk = ["choices": [["delta": ["content": text], "finish_reason": "stop"]]]
            let line = String(data: try! JSONSerialization.data(withJSONObject: chunk), encoding: .utf8)!
            return Reply(status: 200, body: Data("data: \(line)\n\ndata: [DONE]\n\n".utf8), delay: delay)
        }
    }

    struct Recorded {
        let method: String
        /// The path after `/coach/`, e.g. `threads` or `context/search`.
        let route: String
        let query: [String: String]
        let body: Any?
        let timeout: TimeInterval

        var json: [String: Any] { body as? [String: Any] ?? [:] }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (Recorded) -> Reply = { _ in Reply(status: 404, body: Data(#"{"error":"not_found"}"#.utf8)) }
    nonisolated(unsafe) private static var _requests: [Recorded] = []

    static var handler: (Recorded) -> Reply {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func reset() {
        lock.lock()
        _requests = []
        _handler = { _ in Reply(status: 404, body: Data(#"{"error":"not_found"}"#.utf8)) }
        lock.unlock()
    }

    static func requests(_ method: String, _ route: String) -> [Recorded] {
        requests.filter { $0.method == method && $0.route == route }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoachURLProtocolStub.self]
        return URLSession(configuration: config)
    }

    static let endpoint = URL(string: "https://coach.test/functions/v1/coach")!

    static func identity(owner: String) -> CloudPushIdentity {
        CloudPushIdentity(ownerId: owner, sourceId: "00000000-0000-4000-8000-0000000000a1",
                          tokenId: "00000000-0000-4000-8000-0000000000a2", uploadToken: "noop_test_token")
    }

    /// A client on the stub whose owner is read from `owner` on every request.
    static func api(owner: @escaping @Sendable () -> String?) -> CoachAPI {
        CoachAPI(session: session(), endpoint: { endpoint }, identity: { owner().map { identity(owner: $0) } })
    }

    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path
        let route = path.range(of: "/coach/").map { String(path[$0.upperBound...]) } ?? ""
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let data = request.httpBody ?? Self.read(request.httpBodyStream)
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let recorded = Recorded(method: request.httpMethod ?? "GET", route: route, query: query, body: body,
                                timeout: request.timeoutInterval)
        Self.lock.lock()
        Self._requests.append(recorded)
        let handler = Self._handler
        Self.lock.unlock()
        let reply = handler(recorded)
        let deliver = { [weak self] in
            guard let self, !self.cancelled else { return }
            let http = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() { cancelled = true }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
