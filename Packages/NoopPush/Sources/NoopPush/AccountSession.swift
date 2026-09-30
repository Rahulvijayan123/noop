import Foundation
import CryptoKit

public struct AccountScope: Hashable, Codable, Sendable {
    public let projectURL: String
    public let userID: String

    public init(projectURL: String, userID: String) throws {
        self.projectURL = try Self.canonicalProjectURL(projectURL)
        guard let id = UUID(uuidString: userID) else { throw AccountAuthError.invalidIdentity }
        self.userID = id.uuidString.lowercased()
    }

    public var namespace: String { Self.digest("account-v1\u{0}\(projectURL)\u{0}\(userID)") }

    public static func canonicalProjectURL(_ value: String) throws -> String {
        guard var parts = URLComponents(string: value), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.scheme?.lowercased() == "https" ||
                (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host)),
              !parts.path.contains(".."), !value.contains("\u{0}") else {
            throw AccountAuthError.notConfigured
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let result = parts.string else { throw AccountAuthError.notConfigured }
        return result
    }

    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey { case projectURL, userID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(projectURL: c.decode(String.self, forKey: .projectURL),
                      userID: c.decode(String.self, forKey: .userID))
    }
}

public struct AccountSessionContext: Hashable, Sendable {
    public let scope: AccountScope
    public let generation: UUID
    public init(scope: AccountScope, generation: UUID) {
        self.scope = scope
        self.generation = generation
    }
}

public struct AccountIdentitySnapshot: Equatable, Sendable {
    public let projectURL: String?
    public let scope: AccountScope?
    public let generation: UUID
    public init(projectURL: String?, scope: AccountScope?, generation: UUID) {
        self.projectURL = projectURL
        self.scope = scope
        self.generation = generation
    }
    public var context: AccountSessionContext? {
        scope.map { AccountSessionContext(scope: $0, generation: generation) }
    }
}

public struct AccountAuthConfiguration: Equatable, Sendable {
    public let projectURL: String
    public let anonKey: String
    public init(projectURL: String, anonKey: String) throws {
        self.projectURL = try AccountScope.canonicalProjectURL(projectURL)
        guard !anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccountAuthError.notConfigured
        }
        self.anonKey = anonKey
    }
}

public struct AccountAuthSession: Codable, Equatable, Sendable {
    public let scope: AccountScope
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public var userId: String { scope.userID }
    public var isExpired: Bool { expiresAt <= Date().addingTimeInterval(60) }
    public init(scope: AccountScope, accessToken: String, refreshToken: String, expiresAt: Date) {
        self.scope = scope
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct AuthorizedCloudSession: Sendable {
    public let context: AccountSessionContext
    public let accessToken: String
    public let expiresAt: Date
    public init(context: AccountSessionContext, accessToken: String, expiresAt: Date) {
        self.context = context
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

/// Memory only. Taking this snapshot never configures, loads or refreshes credentials.
public struct PassiveAccountSnapshot: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case notConfigured = "NOT_CONFIGURED", notLoaded = "NOT_LOADED"
        case unavailable = "UNAVAILABLE", signedOut = "SIGNED_OUT", expired = "EXPIRED", ready = "READY"
    }
    public let configuration: AccountAuthConfiguration?
    public let session: AccountAuthSession?
    public let generation: UUID
    public let loaded: Bool
    public let failure: AccountAuthError?
    public let operationPending: Bool

    public func status(at date: Date, minimumLifetime: TimeInterval = 30) -> Status {
        guard configuration != nil else { return .notConfigured }
        guard failure != .credentialUnavailable, !operationPending else { return .unavailable }
        guard loaded else { return .notLoaded }
        guard let session else { return .signedOut }
        guard session.expiresAt > date.addingTimeInterval(minimumLifetime) else { return .expired }
        return .ready
    }

    public var context: AccountSessionContext? {
        session.map { AccountSessionContext(scope: $0.scope, generation: generation) }
    }
}

public enum AccountAuthError: Error, Equatable, Sendable {
    case notConfigured, signedOut, invalidIdentity, invalidCredentials, sessionRevoked, accountSwitchRequired
    case staleOperation, retryable, invalidResponse, credentialUnavailable, unboundCapture
    case recoveryCodeInvalid, recoveryExpired, reauthenticationRequired, reauthenticationInvalid
    case passwordRejected, passwordChangedSignInRequired
    case rejected(Int)
    public var isRetryable: Bool {
        switch self {
        case .retryable, .credentialUnavailable, .staleOperation: return true
        default: return false
        }
    }
}

public enum AccountAuthGrant: Sendable {
    case password(email: String, password: String)
    case refresh(String)
    case recover(email: String)
    case verifyRecovery(email: String, code: String)
    case updateRecoveredPassword(accessToken: String, password: String, nonce: String?)
    case reauthenticateRecovery(accessToken: String)

    public func request(configuration: AccountAuthConfiguration) throws -> URLRequest {
        let path: String
        var method = "POST"
        var accessToken: String?
        var payload: [String: String]?
        switch self {
        case .password(let email, let password):
            path = "/token?grant_type=password"; payload = ["email": email, "password": password]
        case .refresh(let token):
            path = "/token?grant_type=refresh_token"; payload = ["refresh_token": token]
        case .recover(let email):
            path = "/recover"; payload = ["email": email]
        case .verifyRecovery(let email, let code):
            path = "/verify"; payload = ["email": email, "token": code, "type": "recovery"]
        case .updateRecoveredPassword(let token, let password, let nonce):
            path = "/user"; method = "PUT"; accessToken = token; payload = ["password": password]
            if let nonce, !nonce.isEmpty { payload?["nonce"] = nonce }
        case .reauthenticateRecovery(let token):
            path = "/reauthenticate"; method = "GET"; accessToken = token
        }
        guard let url = URL(string: configuration.projectURL + "/auth/v1" + path) else {
            throw AccountAuthError.notConfigured
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        if let accessToken { request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization") }
        if let payload { request.httpBody = try JSONSerialization.data(withJSONObject: payload) }
        return request
    }
}

/// An opaque, process-local recovery handle. Credentials never leave the existing controller.
public struct AccountRecoveryChallenge: Equatable, Sendable {
    fileprivate let id: UUID
    public let runtimeContext: AccountSessionContext
}

public struct AccountAuthReply: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol AccountAuthTransport: Sendable {
    func exchange(configuration: AccountAuthConfiguration, grant: AccountAuthGrant) async throws -> AccountAuthReply
}

/// Implementations must commit the active-owner pointer only after the credential write succeeds.
/// A nil load means absent; inaccessible/corrupt storage must throw instead.
public protocol AccountCredentialStore: Sendable {
    func load(projectURL: String) throws -> AccountAuthSession?
    func save(_ session: AccountAuthSession) throws
    func clear(projectURL: String) throws
}

/// The lock permits synchronous logout fencing for existing UI callers. No network await holds it.
/// Refresh tasks are single-flight; only the generation that started a request may commit its result.
public final class AccountSessionController: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let credentials: any AccountCredentialStore
    private let transport: any AccountAuthTransport
    private let now: @Sendable () -> Date
    private let changed: @Sendable () -> Void
    private var configuration: AccountAuthConfiguration?
    private var session: AccountAuthSession?
    private var generation = UUID()
    private var loaded = false
    private var dirtyCredential = false
    private var pendingCredentialClear = false
    private var failure: AccountAuthError?
    private var refreshTask: (id: UUID, task: Task<AuthorizedCloudSession, Error>)?
    private var signInAttempt: UUID?
    private struct RecoveryAttempt {
        let challenge: AccountRecoveryChallenge
        let configuration: AccountAuthConfiguration
        let generation: UUID
        let email: String
        var verified: AccountAuthSession?
        var busy = false
    }
    private var recoveryAttempt: RecoveryAttempt?

    public init(credentials: any AccountCredentialStore, transport: any AccountAuthTransport,
                now: @escaping @Sendable () -> Date = { Date() },
                changed: @escaping @Sendable () -> Void = {}) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
        self.changed = changed
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    public func configure(_ value: AccountAuthConfiguration?) {
        let didChange = locked { () -> Bool in
            guard value != configuration else { return false }
            invalidateLocked()
            configuration = value
            loaded = false
            failure = nil
            return true
        }
        if didChange { changed() }
    }

    public var lastError: AccountAuthError? { locked { failure } }

    public func passiveSnapshot() -> PassiveAccountSnapshot {
        locked {
            PassiveAccountSnapshot(configuration: configuration, session: session, generation: generation,
                loaded: loaded, failure: failure,
                operationPending: dirtyCredential || pendingCredentialClear || refreshTask != nil || signInAttempt != nil)
        }
    }

    public func identitySnapshot() -> AccountIdentitySnapshot {
        _ = storedSession()
        return locked {
            return AccountIdentitySnapshot(projectURL: configuration?.projectURL,
                                           scope: session?.scope, generation: generation)
        }
    }

    public func storedSession() -> AccountAuthSession? {
        var recovered = false
        let result: AccountAuthSession? = locked {
            do {
                let wasUnavailable = !loaded && failure == .credentialUnavailable
                try loadLocked()
                recovered = wasUnavailable && session != nil
                if recovered { generation = UUID() }
                return session
            }
            catch { failure = .credentialUnavailable; return nil }
        }
        if recovered { changed() }
        return result
    }

    public func currentContext() -> AccountSessionContext? {
        identitySnapshot().context
    }

    public func isCurrent(_ context: AccountSessionContext) -> Bool {
        locked { generation == context.generation && session?.scope == context.scope &&
            configuration?.projectURL == context.scope.projectURL }
    }

    public func clearSession() throws {
        do {
            try locked {
                invalidateLocked()
                loaded = true
                pendingCredentialClear = true
                if let configuration { try credentials.clear(projectURL: configuration.projectURL) }
                pendingCredentialClear = false
                failure = nil
            }
        } catch {
            locked { failure = .credentialUnavailable }
            changed()
            throw AccountAuthError.credentialUnavailable
        }
        changed()
    }

    public func signIn(email: String, password: String, expectedScope: AccountScope? = nil,
                       allowingScopeChange: Bool = false,
                       expectedGeneration: UUID? = nil,
                       validateCommit: @escaping @Sendable () throws -> Void = {}) async throws -> AccountAuthSession {
        let start: (AccountAuthConfiguration, UUID, UUID)
        start = try locked {
            try loadLocked()
            guard let configuration else { throw AccountAuthError.notConfigured }
            guard expectedGeneration == nil || expectedGeneration == generation else { throw AccountAuthError.staleOperation }
            if pendingCredentialClear {
                do { try credentials.clear(projectURL: configuration.projectURL); pendingCredentialClear = false }
                catch { throw AccountAuthError.credentialUnavailable }
            }
            if let expectedScope, expectedScope.projectURL != configuration.projectURL {
                throw AccountAuthError.invalidIdentity
            }
            let attempt = UUID()
            recoveryAttempt = nil
            signInAttempt = attempt
            return (configuration, generation, attempt)
        }
        defer { locked { if signInAttempt == start.2 { signInAttempt = nil } } }
        let result = try await exchange(start.0, grant: .password(email: email, password: password))
        try Task.checkCancellation()
        let parsed = try parse(result, configuration: start.0, refreshing: false)
        try locked {
            guard generation == start.1, configuration == start.0, signInAttempt == start.2 else {
                throw AccountAuthError.staleOperation
            }
            let requiredScope = expectedScope ?? (allowingScopeChange ? nil : session?.scope)
            guard requiredScope == nil || parsed.scope == requiredScope else {
                throw AccountAuthError.accountSwitchRequired
            }
            try Task.checkCancellation()
            try validateCommit()
            do { try credentials.save(parsed) }
            catch { failure = .credentialUnavailable; throw AccountAuthError.credentialUnavailable }
            // Only a committed owner transition retires running work. Augmenting the same
            // owner leaves its durable jobs and captured runtime generation intact.
            if session?.scope != parsed.scope { invalidateLocked() }
            else { refreshTask?.task.cancel(); refreshTask = nil }
            session = parsed
            loaded = true
            dirtyCredential = false
            failure = nil
        }
        changed()
        return parsed
    }

    public func beginRecovery(email: String, runtimeContext: AccountSessionContext,
                              validateRuntime: @escaping @Sendable () throws -> Void) async throws -> AccountRecoveryChallenge {
        let start: RecoveryAttempt = try locked {
            try loadLocked()
            guard let configuration else { throw AccountAuthError.notConfigured }
            guard configuration.projectURL == runtimeContext.scope.projectURL,
                  session == nil || session?.scope == runtimeContext.scope else { throw AccountAuthError.invalidIdentity }
            guard signInAttempt == nil, !pendingCredentialClear else { throw AccountAuthError.staleOperation }
            try Task.checkCancellation()
            try validateRuntime()
            let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty, email.utf8.count <= 320 else { throw AccountAuthError.invalidCredentials }
            let attempt = RecoveryAttempt(challenge: .init(id: UUID(), runtimeContext: runtimeContext),
                configuration: configuration, generation: generation, email: email, busy: true)
            recoveryAttempt = attempt
            return attempt
        }
        do {
            let reply = try await exchange(start.configuration, grant: .recover(email: start.email))
            try checkRecoveryReply(reply)
            try locked {
                try validateRecoveryLocked(start.challenge, validateRuntime: validateRuntime)
                recoveryAttempt?.busy = false
            }
            return start.challenge
        } catch {
            cancelRecovery(start.challenge)
            throw error
        }
    }

    public func verifyRecovery(_ challenge: AccountRecoveryChallenge, code: String,
                               validateRuntime: @escaping @Sendable () throws -> Void) async throws {
        let start = try acquireRecovery(challenge, validateRuntime: validateRuntime)
        defer { releaseRecovery(challenge) }
        guard !code.isEmpty, code.utf8.count <= 32 else { throw AccountAuthError.recoveryCodeInvalid }
        let reply = try await exchange(start.configuration, grant: .verifyRecovery(email: start.email, code: code))
        try checkRecoveryReply(reply)
        let verified = try parse(reply, configuration: start.configuration, refreshing: false)
        try locked {
            try validateRecoveryLocked(challenge, validateRuntime: validateRuntime)
            guard verified.scope == challenge.runtimeContext.scope else {
                recoveryAttempt = nil
                throw AccountAuthError.accountSwitchRequired
            }
            recoveryAttempt?.verified = verified
        }
    }

    public func sendRecoveryReauthentication(_ challenge: AccountRecoveryChallenge,
                                            validateRuntime: @escaping @Sendable () throws -> Void) async throws {
        let start = try acquireRecovery(challenge, validateRuntime: validateRuntime)
        defer { releaseRecovery(challenge) }
        let verified = try recoverySession(start)
        let reply = try await exchange(start.configuration, grant: .reauthenticateRecovery(accessToken: verified.accessToken))
        try checkRecoveryReply(reply)
        try locked { try validateRecoveryLocked(challenge, validateRuntime: validateRuntime) }
    }

    /// A successful password update is followed by the ordinary sign-in and Keychain commit path.
    /// Recovery tokens are never published to upload/readback or persisted across a relaunch.
    public func completeRecovery(_ challenge: AccountRecoveryChallenge, password: String, nonce: String? = nil,
                                 validateRuntime: @escaping @Sendable () throws -> Void) async throws -> AccountAuthSession {
        let start = try acquireRecovery(challenge, validateRuntime: validateRuntime)
        defer { releaseRecovery(challenge) }
        let verified = try recoverySession(start)
        guard !password.isEmpty, password.utf8.count <= 4096 else { throw AccountAuthError.passwordRejected }
        let reply = try await exchange(start.configuration,
            grant: .updateRecoveredPassword(accessToken: verified.accessToken, password: password, nonce: nonce))
        try checkRecoveryReply(reply)
        do {
            let body = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any]
            guard let userID = body?["id"] as? String,
                  try AccountScope(projectURL: start.configuration.projectURL, userID: userID) == verified.scope else {
                throw AccountAuthError.invalidIdentity
            }
            try locked {
                try validateRecoveryLocked(challenge, validateRuntime: validateRuntime)
                recoveryAttempt = nil
            }
            return try await signIn(email: start.email, password: password, expectedScope: verified.scope,
                                    expectedGeneration: start.generation,
                                    validateCommit: validateRuntime)
        } catch {
            cancelRecovery(challenge)
            // The remote password is already changed even if cancellation or Keychain commit fails.
            throw AccountAuthError.passwordChangedSignInRequired
        }
    }

    public func cancelRecovery(_ challenge: AccountRecoveryChallenge) {
        locked { if recoveryAttempt?.challenge == challenge { recoveryAttempt = nil } }
    }

    private func acquireRecovery(_ challenge: AccountRecoveryChallenge,
                                 validateRuntime: @Sendable () throws -> Void) throws -> RecoveryAttempt {
        try locked {
            try validateRecoveryLocked(challenge, validateRuntime: validateRuntime)
            guard var attempt = recoveryAttempt, !attempt.busy else { throw AccountAuthError.staleOperation }
            attempt.busy = true
            recoveryAttempt = attempt
            return attempt
        }
    }

    private func releaseRecovery(_ challenge: AccountRecoveryChallenge) {
        locked { if recoveryAttempt?.challenge == challenge { recoveryAttempt?.busy = false } }
    }

    private func validateRecoveryLocked(_ challenge: AccountRecoveryChallenge,
                                        validateRuntime: @Sendable () throws -> Void) throws {
        try Task.checkCancellation()
        guard let attempt = recoveryAttempt, attempt.challenge == challenge,
              attempt.generation == generation, attempt.configuration == configuration,
              signInAttempt == nil else { throw AccountAuthError.staleOperation }
        try validateRuntime()
    }

    private func recoverySession(_ attempt: RecoveryAttempt) throws -> AccountAuthSession {
        guard let verified = attempt.verified, verified.scope == attempt.challenge.runtimeContext.scope else {
            throw AccountAuthError.invalidIdentity
        }
        guard verified.expiresAt > now().addingTimeInterval(60) else { throw AccountAuthError.recoveryExpired }
        return verified
    }

    private func checkRecoveryReply(_ reply: AccountAuthReply) throws {
        guard reply.body.count <= 128 * 1024 else { throw AccountAuthError.invalidResponse }
        if reply.status == 429 || reply.status == 408 || reply.status >= 500 { throw AccountAuthError.retryable }
        guard reply.status != 200 else { return }
        let body = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        switch (body?["error_code"] ?? body?["error"]) as? String {
        case "otp_expired", "otp_disabled": throw AccountAuthError.recoveryCodeInvalid
        case "reauthentication_needed", "reauth_nonce_missing": throw AccountAuthError.reauthenticationRequired
        case "reauthentication_not_valid": throw AccountAuthError.reauthenticationInvalid
        case "weak_password", "same_password": throw AccountAuthError.passwordRejected
        case "session_not_found", "session_expired", "bad_jwt": throw AccountAuthError.recoveryExpired
        default: throw AccountAuthError.rejected(reply.status)
        }
    }

    public func authorizedSession(refreshing rejectedContext: AccountSessionContext? = nil,
                                  rejectedAccessToken: String? = nil) async throws -> AuthorizedCloudSession {
        _ = storedSession()
        let selected: (AuthorizedCloudSession?, Task<AuthorizedCloudSession, Error>?) = try locked {
            try loadLocked()
            guard let configuration else { throw AccountAuthError.notConfigured }
            guard let session else { throw AccountAuthError.signedOut }
            if let rejectedContext {
                guard rejectedContext == AccountSessionContext(scope: session.scope, generation: generation) else {
                    throw AccountAuthError.staleOperation
                }
            }
            if dirtyCredential {
                do { try credentials.save(session); dirtyCredential = false; failure = nil }
                catch { throw AccountAuthError.credentialUnavailable }
            }
            if (rejectedContext == nil || (rejectedAccessToken != nil && rejectedAccessToken != session.accessToken)),
               session.expiresAt > now().addingTimeInterval(60) {
                return (AuthorizedCloudSession(context: .init(scope: session.scope, generation: generation),
                                               accessToken: session.accessToken, expiresAt: session.expiresAt), nil)
            }
            if let refreshTask { return (nil, refreshTask.task) }
            let context = AccountSessionContext(scope: session.scope, generation: generation)
            let id = UUID()
            let task = Task { try await self.refresh(configuration, session: session, context: context, id: id) }
            refreshTask = (id, task)
            return (nil, task)
        }
        if let pending = selected.1 {
            let result = try await pending.value
            guard isCurrent(result.context) else { throw AccountAuthError.staleOperation }
            return result
        }
        guard let selected = selected.0, isCurrent(selected.context) else { throw AccountAuthError.staleOperation }
        return selected
    }

    private func refresh(_ configuration: AccountAuthConfiguration, session: AccountAuthSession,
                         context: AccountSessionContext, id: UUID) async throws -> AuthorizedCloudSession {
        defer { locked { if refreshTask?.id == id { refreshTask = nil } } }
        do {
            let reply = try await exchange(configuration, grant: .refresh(session.refreshToken))
            let refreshed = try parse(reply, configuration: configuration, refreshing: true)
            return try locked {
                guard isCurrent(context), self.configuration == configuration, refreshTask?.id == id else {
                    throw AccountAuthError.staleOperation
                }
                guard refreshed.scope == context.scope else { throw AccountAuthError.invalidIdentity }
                // Keep rotated credentials in memory if persistence is temporarily unavailable.
                self.session = refreshed
                dirtyCredential = true
                do { try credentials.save(refreshed); dirtyCredential = false; failure = nil }
                catch { failure = .credentialUnavailable; throw AccountAuthError.credentialUnavailable }
                return AuthorizedCloudSession(context: context, accessToken: refreshed.accessToken,
                                              expiresAt: refreshed.expiresAt)
            }
        } catch {
            let current = locked { isCurrent(context) && self.configuration == configuration && refreshTask?.id == id }
            guard current else { throw AccountAuthError.staleOperation }
            if error as? AccountAuthError == .sessionRevoked {
                let didClear = locked { () -> Bool in
                    guard isCurrent(context) else { return false }
                    invalidateLocked(); loaded = true
                    pendingCredentialClear = true
                    do { try credentials.clear(projectURL: configuration.projectURL); pendingCredentialClear = false; failure = .sessionRevoked }
                    catch { failure = .credentialUnavailable }
                    return true
                }
                if didClear { changed() }
            }
            throw error
        }
    }

    private func loadLocked() throws {
        guard !loaded, let configuration else { return }
        do {
            let value = try credentials.load(projectURL: configuration.projectURL)
            guard value == nil || value?.scope.projectURL == configuration.projectURL else {
                throw AccountAuthError.invalidIdentity
            }
            if let value {
                guard !value.accessToken.isEmpty, !value.refreshToken.isEmpty,
                      value.expiresAt.timeIntervalSince1970.isFinite else {
                    throw AccountAuthError.credentialUnavailable
                }
            }
            session = value; loaded = true; failure = nil
        } catch { failure = .credentialUnavailable; throw AccountAuthError.credentialUnavailable }
    }

    private func invalidateLocked() {
        generation = UUID()
        signInAttempt = nil
        recoveryAttempt = nil
        session = nil
        dirtyCredential = false
        refreshTask?.task.cancel()
        refreshTask = nil
    }

    private func exchange(_ configuration: AccountAuthConfiguration, grant: AccountAuthGrant) async throws -> AccountAuthReply {
        do { return try await transport.exchange(configuration: configuration, grant: grant) }
        catch let error as AccountAuthError { throw error }
        catch { throw AccountAuthError.retryable }
    }

    private func parse(_ reply: AccountAuthReply, configuration: AccountAuthConfiguration,
                       refreshing: Bool) throws -> AccountAuthSession {
        guard reply.body.count <= 128 * 1024 else { throw AccountAuthError.invalidResponse }
        if reply.status == 429 || reply.status == 408 || reply.status >= 500 { throw AccountAuthError.retryable }
        let body = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        guard reply.status == 200 else {
            let code = (body?["error_code"] ?? body?["error"]) as? String ?? ""
            if refreshing, [400, 401].contains(reply.status),
               ["refresh_token_not_found", "refresh_token_already_used", "invalid_grant", "session_not_found"].contains(code) {
                throw AccountAuthError.sessionRevoked
            }
            if !refreshing, [400, 401].contains(reply.status) { throw AccountAuthError.invalidCredentials }
            throw AccountAuthError.rejected(reply.status)
        }
        guard let body, let access = body["access_token"] as? String, !access.isEmpty,
              let refresh = body["refresh_token"] as? String, !refresh.isEmpty,
              let seconds = body["expires_in"] as? Double, seconds.isFinite, seconds > 0,
              let user = body["user"] as? [String: Any], let userID = user["id"] as? String else {
            throw AccountAuthError.invalidResponse
        }
        return AccountAuthSession(scope: try .init(projectURL: configuration.projectURL, userID: userID),
                                  accessToken: access, refreshToken: refresh, expiresAt: now().addingTimeInterval(seconds))
    }
}
