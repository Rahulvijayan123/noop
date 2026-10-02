import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A minimal HTTP/1.1 stub server for the inference-client tests.
///
/// It binds 127.0.0.1 on an EPHEMERAL port (`port: 0`) and reports the port the
/// kernel assigned, which is the same shape the repo's existing Deno test helper
/// uses (`supabase/functions/tests/local_objects.ts:19`). It exists so the
/// failure taxonomy can be exercised for real — a refused connection, a real
/// timeout, a real non-200, a real malformed body — instead of mocked.
final class StubHTTPServer {
    struct Response {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = ["Content-Type": "application/json"]
        /// Sleep before answering, to force a client-side timeout.
        var delaySeconds: Double = 0
        /// When true the connection is accepted and then never answered.
        var neverRespond: Bool = false

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(text.utf8),
                    headers: ["Content-Type": "application/json"])
        }
    }

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var requests: [Request] = []
    private var handler: (Request) -> Response

    let port: UInt16
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(handler: @escaping (Request) -> Response) {
        self.handler = handler
        // A client that aborts mid-response (the timeout test) must not kill the
        // test process with SIGPIPE.
        _ = signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket() failed")
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0, "bind() failed")
        precondition(listen(fd, 16) == 0, "listen() failed")
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        self.port = UInt16(bigEndian: assigned.sin_port)
        self.listenFD = fd
        let queue = DispatchQueue(label: "stub-http-server-\(port)")
        queue.async { [weak self] in self?.acceptLoop() }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        if !already { close(listenFD) }
    }

    /// Every request the stub has served, in order.
    var servedRequests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    /// Replace the handler (used by tests that change behaviour mid-run).
    func setHandler(_ newHandler: @escaping (Request) -> Response) {
        lock.lock(); handler = newHandler; lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            serve(client)
            close(client)
        }
    }

    private func serve(_ client: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let request = readRequest(client) else { return }
        lock.lock()
        requests.append(request)
        let respond = handler
        lock.unlock()
        let response = respond(request)
        if response.neverRespond {
            // Hold the connection open WITHOUT answering, so the CLIENT's own
            // deadline is what fires. Closing here would surface as a transport
            // failure instead of a timeout, which is a different taxonomy case.
            var waited = 0.0
            while !isStopped && waited < 5.0 {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
            return
        }
        if response.delaySeconds > 0 { Thread.sleep(forTimeInterval: response.delaySeconds) }
        var head = "HTTP/1.1 \(response.status) \(StubHTTPServer.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func readRequest(_ client: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let read = recv(client, &chunk, chunk.count, 0)
            if read <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<read])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 1 << 20 { return nil }
        }
        guard let separator = headerEnd else { return nil }
        let headerText = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self)
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""
        var headers: [String: String] = [:]
        lines.removeFirst()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        var body = Data(buffer[separator.upperBound...])
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < expected {
            let read = recv(client, &chunk, chunk.count, 0)
            if read <= 0 { break }
            body.append(contentsOf: chunk[0..<read])
        }
        return Request(method: method, path: path, headers: headers, body: body)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// A loopback port that nothing is listening on: bind an ephemeral port, read it,
/// then close the socket. A connection to it is refused.
func closedLoopbackPort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &assigned) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    let port = UInt16(bigEndian: assigned.sin_port)
    close(fd)
    return port
}
