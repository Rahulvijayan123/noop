import Foundation
import Combine

// MARK: - Value types

/// The signed-in account. `userId` is the Supabase `auth.users.id` and the ONLY cloud user id: every
/// source id, installation credential, journal row and score is rooted at it.
public struct NaraAccount: Equatable, Sendable {
    public let userId: String
    public let email: String?

    public init(userId: String, email: String?) {
        self.userId = userId.lowercased()
        self.email = email
    }
}

/// What a backend knows about a session. Tokens are deliberately absent: they never leave the backend
/// except through `NaraAuthBackend.validAccessToken()`.
struct NaraAuthSessionInfo: Equatable, Sendable {
    let account: NaraAccount
    let emailConfirmed: Bool
    let isAnonymous: Bool

    /// Only a verified, non-anonymous email account may bind this phone to the cloud.
    var isVerifiedAccount: Bool { emailConfirmed && !isAnonymous }
}

enum NaraSignUpResult: Equatable, Sendable {
    /// The account exists (or looks like it does) and an emailed code must be entered.
    case verificationRequired
    /// The project does not require confirmation and returned a session straight away.
    case signedIn(NaraAuthSessionInfo)
}

enum NaraAuthCodePurpose: Sendable {
    case signup
    case recovery
}

enum NaraAuthSessionEvent: Equatable, Sendable {
    /// A session exists (sign-in, token refresh, user update).
    case session(NaraAuthSessionInfo)
    /// The session ended: signed out, revoked, deleted or its refresh token was rejected for good.
    case ended
}

/// Typed, user-presentable failures. The cases are what the UI branches on; the messages are Nara's
/// own wording and never echo a server string.
public enum NaraAuthError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidEmail
    case passwordTooShort
    case weakPassword
    case invalidCredentials
    case emailNotConfirmed
    case invalidOrExpiredCode
    case malformedCode
    case rateLimited
    case signupsDisabled
    case emailNotAllowed
    case accountDisabled
    case sessionEnded
    case notSignedIn
    case notAwaitingCode
    case network
    case other

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "This build of Nara isn't set up for accounts yet.")
        case .invalidEmail: return String(localized: "Enter a valid email address.")
        case .passwordTooShort: return String(localized: "Use a password of at least 8 characters.")
        case .weakPassword: return String(localized: "That password is too easy to guess. Choose a stronger one.")
        case .invalidCredentials: return String(localized: "That email and password don't match.")
        case .emailNotConfirmed: return String(localized: "This email isn't verified yet. We sent you a new code.")
        case .invalidOrExpiredCode: return String(localized: "That code is wrong or has expired. Request a new one.")
        case .malformedCode: return String(localized: "Enter the code from the email (digits only).")
        case .rateLimited: return String(localized: "Too many attempts. Wait a minute and try again.")
        case .signupsDisabled: return String(localized: "New sign-ups are closed right now.")
        case .emailNotAllowed: return String(localized: "This email address can't be used for Nara.")
        case .accountDisabled: return String(localized: "This account has been disabled.")
        case .sessionEnded: return String(localized: "You were signed out. Sign in again to continue.")
        case .notSignedIn: return String(localized: "Sign in to your Nara account first.")
        case .notAwaitingCode: return String(localized: "Start again from the sign-in screen.")
        case .network: return String(localized: "Couldn't reach Nara. Check your connection and try again.")
        case .other: return String(localized: "Something went wrong. Try again.")
        }
    }
}

// MARK: - Backend seam

/// The few Supabase Auth operations Nara uses. The real implementation wraps `supabase-swift`'s
/// `AuthClient`; tests substitute an in-memory fake, so the state machine is exercised without a network.
protocol NaraAuthBackend: Sendable {
    /// The stored session, read locally (no network). May hold an expired access token; the refresh
    /// token is used lazily by `validAccessToken()`.
    func restoreSession() async -> NaraAuthSessionInfo?
    func signUp(email: String, password: String) async throws -> NaraSignUpResult
    func verifyCode(email: String, code: String, purpose: NaraAuthCodePurpose) async throws -> NaraAuthSessionInfo
    func resendSignupCode(email: String) async throws
    func signIn(email: String, password: String) async throws -> NaraAuthSessionInfo
    /// End THIS session only. Never fails: a server that can't be reached still leaves the phone signed out.
    func signOutLocal() async
    func sendRecoveryCode(email: String) async throws
    func updatePassword(_ password: String) async throws
    /// A non-expired access token, refreshing first if needed.
    func validAccessToken() async throws -> String
    func sessionEvents() -> AsyncStream<NaraAuthSessionEvent>
}

// MARK: - Service

/// Email + password accounts on Supabase Auth, verified with an emailed one-time code.
///
///     sign up ─► code emailed (Resend → Supabase SMTP) ─► verifyOTP(.signup) ─► verified session
///
/// Resend is only Supabase's SMTP delivery provider. There is no Nara-side verification or token system:
/// a session exists only after Supabase itself has confirmed the email, and `phase == .signedIn` is the
/// one fact the rest of the app (installation provisioning, the upload runtime) is allowed to build on.
@MainActor
public final class NaraAuthService: ObservableObject {

    public enum Phase: Equatable {
        /// Reading the stored session at launch.
        case restoring
        case signedOut
        /// Signed up (or tried to sign in) with an unverified email; waiting for the emailed code.
        case awaitingSignupCode(email: String)
        /// A password reset code was requested; waiting for code + new password.
        case awaitingRecoveryCode(email: String)
        case signedIn(NaraAccount)

        public var account: NaraAccount? {
            if case .signedIn(let account) = self { return account }
            return nil
        }
    }

    public static let minimumPasswordLength = 8
    public static let resendCooldown: TimeInterval = 60

    @Published public private(set) var phase: Phase = .restoring
    @Published public private(set) var isBusy = false
    @Published public private(set) var failure: NaraAuthError?
    @Published public private(set) var notice: String?
    @Published public private(set) var resendAvailableAt: Date?

    private let backend: (any NaraAuthBackend)?
    private let now: @Sendable () -> Date
    private var started = false
    private var eventsTask: Task<Void, Never>?

    /// The service the app uses: real Supabase Auth when the build carries a project + publishable key,
    /// otherwise unavailable (and the app is offline NOOP).
    public static let shared: NaraAuthService = {
        NaraAuthService(backend: SupabaseAuthBackend.makeConfigured())
    }()

    init(backend: (any NaraAuthBackend)?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.backend = backend
        self.now = now
    }

    /// False when this build has no Auth project configured.
    public var isAvailable: Bool { backend != nil }

    deinit { eventsTask?.cancel() }

    // MARK: lifecycle

    /// Read the stored session and start following session changes. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        guard let backend else {
            phase = .signedOut
            return
        }
        if let info = await backend.restoreSession(), info.isVerifiedAccount {
            phase = .signedIn(info.account)
        } else {
            phase = .signedOut
        }
        eventsTask = Task { [weak self] in
            for await event in backend.sessionEvents() {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: NaraAuthSessionEvent) {
        switch event {
        case .session(let info):
            guard info.isVerifiedAccount else { return }
            // A refresh or profile update for the account that is already signed in changes nothing.
            // A session for a DIFFERENT account only ever arrives through this service's own sign-in
            // paths, which set the phase themselves; ignoring it here keeps the bound account stable.
            if case .signedIn(let current) = phase, current.userId != info.account.userId { return }
            if case .signedIn = phase { phase = .signedIn(info.account) }
        case .ended:
            if case .signedIn = phase {
                phase = .signedOut
                notice = NaraAuthError.sessionEnded.errorDescription
            }
        }
    }

    // MARK: sign up / verify

    public func signUp(email rawEmail: String, password: String) async {
        await run {
            guard let backend = self.backend else { throw NaraAuthError.notConfigured }
            let email = try Self.normalizedEmail(rawEmail)
            try Self.checkPassword(password)
            switch try await backend.signUp(email: email, password: password) {
            case .verificationRequired:
                self.phase = .awaitingSignupCode(email: email)
                self.resendAvailableAt = self.now().addingTimeInterval(Self.resendCooldown)
                self.notice = String(localized: "We emailed you a code. Enter it to finish creating your account.")
            case .signedIn(let info):
                try self.adopt(info)
            }
        }
    }

    public func verifySignupCode(_ rawCode: String) async {
        await run {
            guard let backend = self.backend else { throw NaraAuthError.notConfigured }
            guard case .awaitingSignupCode(let email) = self.phase else { throw NaraAuthError.notAwaitingCode }
            let code = try Self.normalizedCode(rawCode)
            let info = try await backend.verifyCode(email: email, code: code, purpose: .signup)
            try self.adopt(info)
        }
    }

    public func resendSignupCode() async {
        await run {
            guard let backend = self.backend else { throw NaraAuthError.notConfigured }
            guard case .awaitingSignupCode(let email) = self.phase else { throw NaraAuthError.notAwaitingCode }
            if let until = self.resendAvailableAt, until > self.now() { throw NaraAuthError.rateLimited }
            try await backend.resendSignupCode(email: email)
            self.resendAvailableAt = self.now().addingTimeInterval(Self.resendCooldown)
            self.notice = String(localized: "A new code is on its way.")
        }
    }

    // MARK: sign in / out

    public func signIn(email rawEmail: String, password: String) async {
        await run {
            guard let backend = self.backend else { throw NaraAuthError.notConfigured }
            let email = try Self.normalizedEmail(rawEmail)
            guard !password.isEmpty else { throw NaraAuthError.invalidCredentials }
            do {
                let info = try await backend.signIn(email: email, password: password)
                try self.adopt(info)
            } catch NaraAuthError.emailNotConfirmed {
                // The account exists but never finished verification: send a fresh code and ask for it.
                self.phase = .awaitingSignupCode(email: email)
                try? await backend.resendSignupCode(email: email)
                self.resendAvailableAt = self.now().addingTimeInterval(Self.resendCooldown)
                throw NaraAuthError.emailNotConfirmed
            }
        }
    }

    public func signOut() async {
        isBusy = true
        defer { isBusy = false }
        await backend?.signOutLocal()
        failure = nil
        notice = nil
        phase = .signedOut
    }

    /// Leave a code-entry screen without finishing it.
    public func cancelPending() {
        if case .signedIn = phase { return }
        failure = nil
        notice = nil
        phase = .signedOut
    }

    // MARK: password reset

    public func requestPasswordReset(email rawEmail: String) async {
        await run {
            guard let backend = self.backend else { throw NaraAuthError.notConfigured }
            let email = try Self.normalizedEmail(rawEmail)
            try await backend.sendRecoveryCode(email: email)
            self.phase = .awaitingRecoveryCode(email: email)
            self.resendAvailableAt = self.now().addingTimeInterval(Self.resendCooldown)
            self.notice = String(localized: "If that email has an account, we sent a code to reset the password.")
        }
    }

    public func completePasswordReset(code rawCode: String, newPassword: String) async {
        await run {
            guard let backend = self.backend else { throw NaraAuthError.notConfigured }
            guard case .awaitingRecoveryCode(let email) = self.phase else { throw NaraAuthError.notAwaitingCode }
            let code = try Self.normalizedCode(rawCode)
            try Self.checkPassword(newPassword)
            let info = try await backend.verifyCode(email: email, code: code, purpose: .recovery)
            do {
                try await backend.updatePassword(newPassword)
            } catch {
                // The recovery code is single use and has been spent. Do not stay signed in on a session
                // that never finished its reset; ask the person to start over.
                await backend.signOutLocal()
                self.phase = .signedOut
                throw error
            }
            try self.adopt(info)
            self.notice = String(localized: "Your password was changed.")
        }
    }

    // MARK: token access

    /// A valid Supabase access token for the signed-in account, refreshed first when needed. A session the
    /// server has permanently rejected signs the phone out here rather than leaving a zombie account.
    func accessToken() async throws -> String {
        guard let backend else { throw NaraAuthError.notConfigured }
        guard case .signedIn = phase else { throw NaraAuthError.notSignedIn }
        do {
            return try await backend.validAccessToken()
        } catch let error as NaraAuthError {
            if error == .sessionEnded { handle(.ended) }
            throw error
        }
    }

    // MARK: plumbing

    private func adopt(_ info: NaraAuthSessionInfo) throws {
        guard info.isVerifiedAccount else { throw NaraAuthError.emailNotConfirmed }
        phase = .signedIn(info.account)
        failure = nil
        resendAvailableAt = nil
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        failure = nil
        notice = nil
        defer { isBusy = false }
        do {
            try await operation()
        } catch let error as NaraAuthError {
            failure = error
        } catch {
            failure = .other
        }
    }

    static func normalizedEmail(_ raw: String) throws -> String {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.count <= 254, parts.count == 2, !parts[0].isEmpty,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !email.contains(" ") else { throw NaraAuthError.invalidEmail }
        return email
    }

    static func checkPassword(_ password: String) throws {
        guard password.count >= minimumPasswordLength else { throw NaraAuthError.passwordTooShort }
    }

    /// The emailed code: digits only, 6 to 10 of them (the project's configured OTP length).
    static func normalizedCode(_ raw: String) throws -> String {
        let stripped = raw.filter { !$0.isWhitespace && $0 != "-" }
        guard (6...10).contains(stripped.count), stripped.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw NaraAuthError.malformedCode
        }
        return stripped
    }
}
