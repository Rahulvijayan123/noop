import XCTest
import NoopPush
import WhoopProtocol
@testable import Strand

// Support for the end-to-end suite (`NaraEndToEndTests`).
//
// These tests drive the app's real account, transport and readback code against a real Supabase Auth +
// Postgres + PostgREST stack, the unmodified `push` and `scores` Edge functions and the real scoring worker.
// `supabase/tests/e2e/stack.sh up` builds that stack; its environment reaches the test process through
// `TEST_RUNNER_`-prefixed variables (see supabase/tests/e2e/README.md). Without a stack every test skips, so a
// plain `xcodebuild test` is unaffected.

struct E2EError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct E2EEnvironment {
    let gateway: URL
    let publishableKey: String
    let secretKey: String

    static func load() throws -> E2EEnvironment {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["NARA_E2E_GATEWAY"], let gateway = URL(string: raw),
              let publishable = env["NARA_E2E_PUBLISHABLE_KEY"], !publishable.isEmpty,
              let secret = env["NARA_E2E_SECRET_KEY"], !secret.isEmpty else {
            throw XCTSkip("No end-to-end stack. Run supabase/tests/e2e/stack.sh up and pass its environment to the test runner.")
        }
        return E2EEnvironment(gateway: gateway, publishableKey: publishable, secretKey: secret)
    }

    var pushEndpoint: URL { gateway.appendingPathComponent("functions/v1/push") }
    var authURL: URL { gateway.appendingPathComponent("auth/v1") }
    var scoresEndpoint: URL { gateway.appendingPathComponent("functions/v1/scores") }
}

/// Polls until `condition` holds or `timeout` passes. Returns whether it held.
func e2eWait(timeout: TimeInterval, interval: TimeInterval = 0.25,
             _ condition: @escaping () async throws -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return (try? await condition()) == true
}

// MARK: - Mail

/// The emails the Auth service handed to the SMTP sink. The code is read out of the real message GoTrue
/// rendered from the real template.
struct E2EMailbox {
    let env: E2EEnvironment

    struct Message { let subject: String; let code: String? }

    func code(for email: String, since: Date, timeout: TimeInterval = 25) async throws -> String {
        var found: String?
        let ok = await e2eWait(timeout: timeout, interval: 0.4) {
            let messages = try await self.messages(for: email, since: since)
            found = messages.last?.code
            return found != nil
        }
        guard ok, let found else { throw E2EError("no emailed code for \(email) within \(Int(timeout)) s") }
        return found
    }

    func messages(for email: String, since: Date) async throws -> [Message] {
        var components = URLComponents(url: env.gateway.appendingPathComponent("__e2e/mail"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "to", value: email),
                                 URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970 * 1000)))]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["messages"] as? [[String: Any]]) ?? []).map {
            Message(subject: ($0["subject"] as? String) ?? "", code: $0["code"] as? String)
        }
    }
}

// MARK: - Server inspection

/// Reads and changes server state the way an operator would (the secret key never reaches the app), and reads
/// it the way a signed-in user would (publishable key + that user's JWT) to prove what row-level security hides.
struct E2EServer {
    let env: E2EEnvironment

    private func request(_ path: String, method: String = "GET", query: String = "", body: Data? = nil,
                         userJWT: String? = nil, anonymous: Bool = false,
                         extra: [String: String] = [:]) -> URLRequest {
        var urlString = env.gateway.absoluteString + path
        if !query.isEmpty { urlString += "?" + query }
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = method
        if anonymous {
            request.setValue(env.publishableKey, forHTTPHeaderField: "apikey")
        } else if let userJWT {
            request.setValue(env.publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(userJWT)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(env.secretKey, forHTTPHeaderField: "apikey")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in extra { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Int, Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw E2EError("no HTTP response") }
        return (http.statusCode, data, http)
    }

    func rows(_ table: String, _ query: String = "", asUser jwt: String? = nil) async throws -> [[String: Any]] {
        let (status, data, _) = try await perform(request("/rest/v1/\(table)", query: query, userJWT: jwt))
        guard (200..<300).contains(status) else {
            throw E2EError("GET \(table) \(query) -> \(status) \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// The status a user-level read gets, for the cases where the correct answer is a refusal.
    func readStatus(_ table: String, _ query: String = "", asUser jwt: String? = nil) async throws -> Int {
        try await perform(request("/rest/v1/\(table)", query: query, userJWT: jwt)).0
    }

    func count(_ table: String, _ query: String = "", asUser jwt: String? = nil) async throws -> Int {
        let (status, data, http) = try await perform(
            request("/rest/v1/\(table)", query: query, userJWT: jwt, extra: ["Prefer": "count=exact", "Range": "0-0"]))
        guard (200..<300).contains(status) else {
            throw E2EError("count \(table) \(query) -> \(status) \(String(data: data, encoding: .utf8) ?? "")")
        }
        let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
        guard let total = range.split(separator: "/").last, let value = Int(total) else {
            throw E2EError("no count in Content-Range '\(range)'")
        }
        return value
    }

    @discardableResult
    func patch(_ table: String, _ query: String, _ body: [String: Any]) async throws -> Int {
        let data = try JSONSerialization.data(withJSONObject: body)
        let (status, response, _) = try await perform(
            request("/rest/v1/\(table)", method: "PATCH", query: query, body: data, extra: ["Prefer": "return=minimal"]))
        guard (200..<300).contains(status) else {
            throw E2EError("PATCH \(table) -> \(status) \(String(data: response, encoding: .utf8) ?? "")")
        }
        return status
    }

    func rpc(_ name: String, _ arguments: [String: Any]) async throws -> Any? {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let (status, response, _) = try await perform(request("/rest/v1/rpc/\(name)", method: "POST", body: data))
        guard (200..<300).contains(status) else {
            throw E2EError("rpc \(name) -> \(status) \(String(data: response, encoding: .utf8) ?? "")")
        }
        return response.isEmpty ? nil : try? JSONSerialization.jsonObject(with: response, options: [.fragmentsAllowed])
    }

    func deleteAuthUser(_ id: String) async throws {
        let (status, data, _) = try await perform(request("/auth/v1/admin/users/\(id)", method: "DELETE"))
        guard (200..<300).contains(status) else {
            throw E2EError("delete user -> \(status) \(String(data: data, encoding: .utf8) ?? "")")
        }
    }

    /// A write through the REST API as the given user (publishable key + that user's JWT), or as the operator
    /// when `userJWT` is nil. Returns the status and whatever rows came back.
    func write(_ table: String, method: String, query: String = "", body: [String: Any]? = nil,
               userJWT: String? = nil) async throws -> (status: Int, rows: [[String: Any]]) {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (status, response, _) = try await perform(
            request("/rest/v1/\(table)", method: method, query: query, body: data, userJWT: userJWT,
                    extra: ["Prefer": "return=representation"]))
        let rows = ((try? JSONSerialization.jsonObject(with: response)) as? [[String: Any]]) ?? []
        return (status, rows)
    }

    /// A function call through the REST API as the given user, returning the status and the decoded body.
    func callRPC(_ name: String, _ arguments: [String: Any], asUser jwt: String?,
                 anonymous: Bool = false) async throws -> (status: Int, body: Any?) {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let (status, response, _) = try await perform(
            request("/rest/v1/rpc/\(name)", method: "POST", body: data, userJWT: jwt, anonymous: anonymous))
        return (status, try? JSONSerialization.jsonObject(with: response, options: [.fragmentsAllowed]))
    }

    /// A read with the publishable key alone, as anyone holding the app's public configuration could make.
    func anonymousRows(_ table: String, _ query: String = "") async throws -> (status: Int, rows: [[String: Any]]) {
        var urlString = env.gateway.absoluteString + "/rest/v1/\(table)"
        if !query.isEmpty { urlString += "?" + query }
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue(env.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (status, data, _) = try await perform(request)
        return (status, ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? [])
    }

    /// The `devices` rows of an account as the operator sees them.
    func devices(of userId: String) async throws -> [[String: Any]] {
        try await rows("devices", "user_id=eq.\(userId)&select=id,external_device_id,user_id&order=created_at.asc")
    }

    /// An authenticated call to the push function with an arbitrary bearer, returning status and JSON body.
    func push(_ path: String, bearer: String, method: String = "POST", body: [String: Any]? = nil,
              headers: [String: String] = [:]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: env.pushEndpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(env.publishableKey, forHTTPHeaderField: "apikey")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (status, data, _) = try await perform(request)
        return (status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    /// A GET against the scores function with an arbitrary bearer.
    func scores(_ path: String, query: String = "", bearer: String) async throws -> (Int, [String: Any]) {
        var urlString = env.scoresEndpoint.appendingPathComponent(path).absoluteString
        if !query.isEmpty { urlString += "?" + query }
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(env.publishableKey, forHTTPHeaderField: "apikey")
        let (status, data, _) = try await perform(request)
        return (status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }
}

// MARK: - A phone

/// One installation of the app: its own Keychain stand-in, preferences, journal directory, Auth session store,
/// upload runtime and account controller, wired exactly as the app wires them. Building a second phone from the
/// first one's persisted pieces is a relaunch.
@MainActor
final class E2EPhone {
    let env: E2EEnvironment
    let label: String
    let directory: URL
    let secrets: MemorySecretStore
    let defaults: UserDefaults
    let store: CloudPushIdentityStore
    let authStorage: NaraMemoryAuthStorage
    let auth: NaraAuthService
    let runtime: CloudPushRuntime
    let controller: NaraAccountController
    let uploadFlag = UploadFlag()

    /// `restoring` builds a relaunch of another phone: the same journal directory, Keychain stand-in and
    /// preferences. Its Auth session comes back with it unless `withoutAuthSession` says the process was woken
    /// somewhere the session is not readable (a locked phone, a background relaunch).
    init(env: E2EEnvironment, label: String, restoring other: E2EPhone? = nil,
         withoutAuthSession: Bool = false) throws {
        self.env = env
        self.label = label
        directory = other?.directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("nara-e2e-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("journal"),
                                                withIntermediateDirectories: true)
        secrets = other?.secrets ?? MemorySecretStore()
        defaults = other?.defaults ?? isolatedDefaults("e2e-\(label)-\(UUID().uuidString.prefix(8))")
        authStorage = withoutAuthSession ? NaraMemoryAuthStorage() : (other?.authStorage ?? NaraMemoryAuthStorage())
        store = CloudPushIdentityStore(defaults: defaults, secrets: secrets)
        let backend = SupabaseAuthBackend(authURL: env.authURL, publishableKey: env.publishableKey,
                                          storage: authStorage)
        let receiver = CloudReceiverClient(session: .shared, endpoint: env.pushEndpoint,
                                           publishableKey: env.publishableKey)
        auth = NaraAuthService(backend: backend, recovery: receiver, defaults: defaults)
        runtime = CloudPushRuntime(journal: CloudJournal(),
                                   journalDirectory: directory.appendingPathComponent("journal"),
                                   identityStore: store,
                                   bundleIdentifier: "com.noopapp.e2e.\(label).\(UUID().uuidString.prefix(6).lowercased())")
        let box = uploadFlag
        controller = NaraAccountController(
            auth: auth, provisioner: receiver, runtime: runtime, store: store, defaults: defaults,
            appVersion: "e2e (1)",
            isConfigured: { true },
            uploadsEnabled: { box.value },
            setUploadsFlag: { box.value = $0 },
            protectedDataAvailable: { true })
    }

    /// The "upload to the cloud" switch, shared with the controller's closures.
    final class UploadFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = true
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    var account: NaraAccount? { auth.phase.account }

    /// The credential this phone uploads with, for the account that is signed in.
    var identity: CloudPushIdentity? { account.flatMap { store.identity(forOwner: $0.userId) } }

    /// The Supabase access token of the signed-in account, as a client would present it to PostgREST.
    func accessToken() async throws -> String { try await auth.accessToken() }

    /// Poll the dense intraday series the way the app reads it, until `ready` accepts what came back.
    func scoredSeries(deviceId: String, from: Int, to: Int, timeout: TimeInterval = 180,
                      ready: @escaping (IntradaySeriesWindow) -> Bool) async throws -> IntradaySeriesWindow {
        guard let repository = runtime.scoreRepository() else { throw E2EError("\(label): no running account to read for") }
        var last: IntradaySeriesWindow?
        var lastError: Error?
        let ok = await e2eWait(timeout: timeout, interval: 3) {
            do {
                let window = try await repository.intradaySeries(from: from, to: to, deviceId: deviceId,
                                                                 cacheKey: "e2e-\(self.label)")
                last = window
                lastError = nil
                return ready(window)
            } catch {
                lastError = error
                return false
            }
        }
        guard ok, let last else {
            throw E2EError("\(label): no scored series within \(Int(timeout)) s (last error \(String(describing: lastError)))")
        }
        return last
    }

    /// Sign up with a fresh address, read the emailed code, verify it, and wait for the cloud path to come up.
    @discardableResult
    func signUp(mailbox: E2EMailbox, email: String? = nil, password: String = "correct-horse-9") async throws -> NaraAccount {
        let address = email ?? "e2e-\(label.lowercased())-\(UUID().uuidString.prefix(8).lowercased())@example.test"
        let since = Date().addingTimeInterval(-1)
        await controller.start()
        await auth.signUp(email: address, password: password)
        guard case .awaitingSignupCode = auth.phase else {
            throw E2EError("sign-up did not ask for a code: phase \(auth.phase) failure \(String(describing: auth.failure))")
        }
        let code = try await mailbox.code(for: address, since: since)
        await auth.verifySignupCode(code)
        guard case .choosingSetup = auth.phase else {
            throw E2EError("verification did not reach the setup choice: phase \(auth.phase) failure \(String(describing: auth.failure))")
        }
        auth.continueAsNewAccount()
        guard case .signedIn(let account) = auth.phase else {
            throw E2EError("continuing did not sign in: phase \(auth.phase) failure \(String(describing: auth.failure))")
        }
        lastEmail = address
        lastPassword = password
        controller.refresh()
        await controller.settle()
        return account
    }

    private(set) var lastEmail = ""
    private(set) var lastPassword = ""

    func signIn(email: String, password: String) async throws {
        await controller.start()
        await auth.signIn(email: email, password: password)
        guard case .signedIn = auth.phase else {
            throw E2EError("sign-in failed: phase \(auth.phase) failure \(String(describing: auth.failure))")
        }
        controller.refresh()
        await controller.settle()
    }

    /// The heart-rate-measurement notifications a strap would deliver for `seconds` seconds ending at `end`,
    /// one per second, with `rr` beat intervals cycling through the given pattern.
    static func liveRecords(bpm: Int, rrPattern: [Int], seconds: Int, endingAt end: Int,
                            deviceId: String) -> [CloudJournalRecord] {
        (0..<seconds).flatMap { offset -> [CloudJournalRecord] in
            let ts = end - seconds + 1 + offset
            let rr = rrPattern[offset % rrPattern.count]
            return CloudCapture.standardHRRecords(hr: bpm, rr: [rr], contact: .supportedDetected, family: .whoop4,
                                                  at: ts, deviceId: deviceId, receivedAtMs: ts * 1000,
                                                  characteristic: "2A37", ledger: nil)
        }
    }

    /// Stage records and wait until every one has been acknowledged by the server.
    @discardableResult
    func capture(_ records: [CloudJournalRecord], timeout: TimeInterval = 60) async throws -> CloudJournalStats {
        let committed = await runtime.submitDurably(records)
        guard committed == records.count else { throw E2EError("journal committed \(committed) of \(records.count)") }
        await runtime.flushAndKick()
        // In the app a strap notification arrives every second and each commit kicks the transport, which is
        // what carries a group past its two-second seal age. A test submits everything at once, so it plays
        // the part of those later notifications.
        let drained = await e2eWait(timeout: timeout, interval: 0.4) {
            self.runtime.kick()
            let stats = await self.runtime.stats()
            return stats.pendingRecords == 0 && stats.sealedBatches == 0 && stats.uploadedBatches == 0
        }
        let stats = await runtime.stats()
        guard drained else {
            let status = await runtime.coordinatorIfRunning?.status()
            throw E2EError("upload did not drain: \(stats); coordinator \(String(describing: status))")
        }
        return stats
    }

    func tearDown() async {
        await runtime.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
