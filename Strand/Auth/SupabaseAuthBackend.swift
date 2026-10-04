import Foundation
import Auth

/// `NaraAuthBackend` over `supabase-swift`'s `AuthClient`.
///
/// This file is the only one that imports the Supabase package. It is configured with the project's
/// PUBLISHABLE key only (sent as `apikey`); there is no code path in the app that can hold a secret key.
/// The session is persisted by `NaraKeychainAuthStorage` (this device only, available after first unlock).
struct SupabaseAuthBackend: NaraAuthBackend {
    private let client: AuthClient

    /// The backend for this build, or nil when it carries no Auth project (offline NOOP).
    static func makeConfigured() -> SupabaseAuthBackend? {
        guard let url = CloudPushSettings.authURL, !CloudPushSettings.publishableKey.isEmpty else { return nil }
        return SupabaseAuthBackend(authURL: url, publishableKey: CloudPushSettings.publishableKey)
    }

    init(authURL: URL, publishableKey: String,
         storage: any AuthLocalStorage = NaraKeychainAuthStorage(),
         fetch: @escaping AuthClient.FetchHandler = { try await URLSession.shared.data(for: $0) }) {
        let storageKey = "nara.auth.session.\(authURL.host ?? "project")"
        client = AuthClient(configuration: AuthClient.Configuration(
            url: authURL,
            headers: ["apikey": publishableKey],
            storageKey: storageKey,
            localStorage: storage,
            fetch: fetch,
            autoRefreshToken: true,
            emitLocalSessionAsInitialSession: true))
    }

    // MARK: NaraAuthBackend

    func restoreSession() async -> NaraAuthSessionInfo? {
        client.currentSession.map { Self.info($0.user) }
    }

    func signUp(email: String, password: String) async throws -> NaraSignUpResult {
        do {
            let response = try await client.signUp(email: email, password: password)
            if let session = response.session {
                return .signedIn(Self.info(session.user))
            }
            // With confirmations on, Supabase answers a sign-up for an already-confirmed email with a
            // stand-in user that has no identities, and sends no code.
            if response.user.identities?.isEmpty == true { return .alreadyRegistered }
            return .verificationRequired
        } catch {
            throw Self.map(error)
        }
    }

    func verifyCode(email: String, code: String, purpose: NaraAuthCodePurpose) async throws -> NaraAuthSessionInfo {
        do {
            let type: EmailOTPType = purpose == .signup ? .signup : .recovery
            let response = try await client.verifyOTP(email: email, token: code, type: type)
            guard let session = response.session else { throw NaraAuthError.invalidOrExpiredCode }
            return Self.info(session.user)
        } catch {
            throw Self.map(error)
        }
    }

    func resendSignupCode(email: String) async throws {
        do {
            try await client.resend(email: email, type: .signup)
        } catch {
            throw Self.map(error)
        }
    }

    func signIn(email: String, password: String) async throws -> NaraAuthSessionInfo {
        do {
            let session = try await client.signIn(email: email, password: password)
            return Self.info(session.user)
        } catch {
            throw Self.map(error)
        }
    }

    func signOutLocal() async {
        // `.local` ends only this phone's session; the account's other devices stay signed in. The library
        // removes the stored session before it contacts the server, so a network failure still signs out.
        try? await client.signOut(scope: .local)
    }

    func sendRecoveryCode(email: String) async throws {
        do {
            try await client.resetPasswordForEmail(email)
        } catch {
            throw Self.map(error)
        }
    }

    func updatePassword(_ password: String) async throws {
        do {
            _ = try await client.update(user: UserAttributes(password: password))
        } catch {
            throw Self.map(error)
        }
    }

    func validAccessToken() async throws -> String {
        do {
            return try await client.session.accessToken
        } catch {
            // A refresh the server rejected for good removes the stored session; a refresh that merely
            // could not reach the server leaves it in place and is only a connectivity problem.
            if client.currentSession == nil { throw NaraAuthError.sessionEnded }
            throw Self.map(error)
        }
    }

    func sessionEvents() -> AsyncStream<NaraAuthSessionEvent> {
        let changes = client.authStateChanges
        return AsyncStream { continuation in
            let task = Task {
                for await (event, session) in changes {
                    switch event {
                    case .signedOut, .userDeleted:
                        continuation.yield(.ended)
                    case .signedIn, .tokenRefreshed, .userUpdated, .passwordRecovery:
                        if let session { continuation.yield(.session(Self.info(session.user))) }
                    default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: mapping

    static func info(_ user: User) -> NaraAuthSessionInfo {
        NaraAuthSessionInfo(account: NaraAccount(userId: user.id.uuidString, email: user.email),
                            emailConfirmed: user.emailConfirmedAt != nil,
                            isAnonymous: user.isAnonymous)
    }

    static func map(_ error: Error) -> NaraAuthError {
        if let known = error as? NaraAuthError { return known }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return .network }
        guard let auth = error as? AuthError else { return .other }
        switch auth {
        case .weakPassword:
            return .weakPassword
        case .sessionMissing, .refreshDiscarded:
            return .sessionEnded
        case .api(_, let code, _, let response):
            switch code {
            case .invalidCredentials: return .invalidCredentials
            case .emailNotConfirmed: return .emailNotConfirmed
            case .otpExpired: return .invalidOrExpiredCode
            case .overEmailSendRateLimit, .overRequestRateLimit: return .rateLimited
            case .signupDisabled, .emailProviderDisabled: return .signupsDisabled
            case .emailAddressNotAuthorized: return .emailNotAllowed
            case .userBanned: return .accountDisabled
            case .weakPassword: return .weakPassword
            case .sessionNotFound, .sessionExpired, .refreshTokenNotFound, .refreshTokenAlreadyUsed,
                 .badJWT, .invalidJWT, .userNotFound, .noAuthorization:
                return .sessionEnded
            default: break
            }
            if response.statusCode == 429 { return .rateLimited }
            return .other
        default:
            return .other
        }
    }
}
