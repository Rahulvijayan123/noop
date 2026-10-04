import XCTest
@testable import Strand

/// An in-memory stand-in for Supabase Auth. It records every call so the tests can assert exactly what the
/// state machine asked of the backend, and it decides success or failure from the test, never from a network.
final class FakeAuthBackend: NaraAuthBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var continuation: AsyncStream<NaraAuthSessionEvent>.Continuation?

    var stored: NaraAuthSessionInfo?
    var signUpResult: Result<NaraSignUpResult, Error> = .success(.verificationRequired)
    var verifyResult: Result<NaraAuthSessionInfo, Error> = .failure(NaraAuthError.invalidOrExpiredCode)
    var signInResult: Result<NaraAuthSessionInfo, Error> = .failure(NaraAuthError.invalidCredentials)
    var resendResult: Result<Void, Error> = .success(())
    var recoveryResult: Result<Void, Error> = .success(())
    var updatePasswordResult: Result<Void, Error> = .success(())
    var tokenResult: Result<String, Error> = .success("jwt.access.token")

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    private func record(_ call: String) {
        lock.lock(); _calls.append(call); lock.unlock()
    }

    func restoreSession() async -> NaraAuthSessionInfo? {
        record("restore")
        return stored
    }

    func signUp(email: String, password: String) async throws -> NaraSignUpResult {
        record("signUp:\(email)")
        return try signUpResult.get()
    }

    func verifyCode(email: String, code: String, purpose: NaraAuthCodePurpose) async throws -> NaraAuthSessionInfo {
        record("verify:\(email):\(code):\(purpose == .signup ? "signup" : "recovery")")
        return try verifyResult.get()
    }

    func resendSignupCode(email: String) async throws {
        record("resend:\(email)")
        try resendResult.get()
    }

    func signIn(email: String, password: String) async throws -> NaraAuthSessionInfo {
        record("signIn:\(email)")
        return try signInResult.get()
    }

    func signOutLocal() async {
        record("signOut")
    }

    func sendRecoveryCode(email: String) async throws {
        record("recover:\(email)")
        try recoveryResult.get()
    }

    func updatePassword(_ password: String) async throws {
        record("updatePassword")
        try updatePasswordResult.get()
    }

    func validAccessToken() async throws -> String {
        record("token")
        return try tokenResult.get()
    }

    func sessionEvents() -> AsyncStream<NaraAuthSessionEvent> {
        AsyncStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func emit(_ event: NaraAuthSessionEvent) {
        lock.lock(); let continuation = self.continuation; lock.unlock()
        continuation?.yield(event)
    }

    static func session(userId: String = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", email: String = "a@example.com",
                        confirmed: Bool = true, anonymous: Bool = false) -> NaraAuthSessionInfo {
        NaraAuthSessionInfo(account: NaraAccount(userId: userId, email: email),
                            emailConfirmed: confirmed, isAnonymous: anonymous)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

@MainActor
final class NaraAuthTests: XCTestCase {

    private let clock = TestClock()

    private func service(_ backend: FakeAuthBackend?) -> NaraAuthService {
        NaraAuthService(backend: backend, now: { [clock] in clock.now })
    }

    // MARK: sign up -> emailed code -> session

    func testSignUpAsksForTheEmailedCodeThenVerifiesIntoASession() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await auth.start()
        XCTAssertEqual(auth.phase, .signedOut)

        await auth.signUp(email: "  New.User@Example.com ", password: "correct horse battery")
        XCTAssertEqual(auth.phase, .awaitingSignupCode(email: "new.user@example.com"),
                       "the address is normalised before it reaches Supabase and the code screen")
        XCTAssertNil(auth.failure)
        XCTAssertEqual(backend.calls.last, "signUp:new.user@example.com")

        backend.verifyResult = .success(FakeAuthBackend.session(userId: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
                                                                email: "new.user@example.com"))
        await auth.verifySignupCode(" 123 456 ")
        XCTAssertEqual(backend.calls.last, "verify:new.user@example.com:123456:signup",
                       "the code is verified as a signup code, for the address that signed up")
        guard case .signedIn(let account) = auth.phase else { return XCTFail("expected signed in, got \(auth.phase)") }
        XCTAssertEqual(account.userId, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "the canonical user id is lowercased")
        XCTAssertEqual(account.email, "new.user@example.com")
    }

    func testAWrongCodeKeepsTheSignUpWaitingAndNeverSignsIn() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await auth.start()
        await auth.signUp(email: "a@example.com", password: "password-123")
        backend.verifyResult = .failure(NaraAuthError.invalidOrExpiredCode)

        await auth.verifySignupCode("000000")
        XCTAssertEqual(auth.failure, .invalidOrExpiredCode)
        XCTAssertEqual(auth.phase, .awaitingSignupCode(email: "a@example.com"))
    }

    func testAMalformedCodeNeverReachesTheBackend() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await auth.start()
        await auth.signUp(email: "a@example.com", password: "password-123")
        let before = backend.calls.count

        for bad in ["", "12345", "12ab56", "123456789012"] {
            await auth.verifySignupCode(bad)
            XCTAssertEqual(auth.failure, .malformedCode, "\(bad) is not a code")
        }
        XCTAssertEqual(backend.calls.count, before)
    }

    func testAProjectThatAutoConfirmsIsNotTrustedUntilTheEmailIsVerified() async {
        let backend = FakeAuthBackend()
        backend.signUpResult = .success(.signedIn(FakeAuthBackend.session(confirmed: false)))
        let auth = service(backend)
        await auth.start()

        await auth.signUp(email: "a@example.com", password: "password-123")
        XCTAssertEqual(auth.failure, .emailNotConfirmed)
        XCTAssertEqual(auth.phase, .signedOut, "an unverified session never becomes the signed-in account")
    }

    func testAnAnonymousSessionIsNeverAnAccount() async {
        let backend = FakeAuthBackend()
        backend.stored = FakeAuthBackend.session(anonymous: true)
        let auth = service(backend)
        await auth.start()
        XCTAssertEqual(auth.phase, .signedOut)
    }

    func testWeakPasswordsAreRefusedBeforeAnyRequest() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await auth.start()
        await auth.signUp(email: "a@example.com", password: "short")
        XCTAssertEqual(auth.failure, .passwordTooShort)
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("signUp") })

        await auth.signUp(email: "not-an-email", password: "password-123")
        XCTAssertEqual(auth.failure, .invalidEmail)
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("signUp") })
    }

    // MARK: resend

    func testResendIsHeldBackUntilTheCooldownPasses() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await auth.start()
        await auth.signUp(email: "a@example.com", password: "password-123")

        await auth.resendSignupCode()
        XCTAssertEqual(auth.failure, .rateLimited, "the code that was just sent is still in flight")
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("resend") })

        clock.advance(by: NaraAuthService.resendCooldown + 1)
        await auth.resendSignupCode()
        XCTAssertNil(auth.failure)
        XCTAssertEqual(backend.calls.last, "resend:a@example.com")
    }

    // MARK: sign in / out

    func testSignInOfAnUnverifiedAccountSendsANewCodeAndAsksForIt() async {
        let backend = FakeAuthBackend()
        backend.signInResult = .failure(NaraAuthError.emailNotConfirmed)
        let auth = service(backend)
        await auth.start()

        await auth.signIn(email: "a@example.com", password: "password-123")
        XCTAssertEqual(auth.phase, .awaitingSignupCode(email: "a@example.com"))
        XCTAssertEqual(auth.failure, .emailNotConfirmed)
        XCTAssertEqual(backend.calls.suffix(2), ["signIn:a@example.com", "resend:a@example.com"])
    }

    func testWrongPasswordLeavesThePhoneSignedOut() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await auth.start()
        await auth.signIn(email: "a@example.com", password: "nope-nope-nope")
        XCTAssertEqual(auth.failure, .invalidCredentials)
        XCTAssertEqual(auth.phase, .signedOut)
    }

    func testRestoringAVerifiedSessionSignsInWithoutTheNetwork() async {
        let backend = FakeAuthBackend()
        backend.stored = FakeAuthBackend.session(userId: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")
        let auth = service(backend)
        XCTAssertEqual(auth.phase, .restoring)
        await auth.start()
        XCTAssertEqual(auth.phase.account?.userId, "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
        XCTAssertEqual(backend.calls, ["restore"], "restoring reads local storage only")
    }

    func testSignOutEndsTheSessionLocally() async {
        let backend = FakeAuthBackend()
        backend.stored = FakeAuthBackend.session()
        let auth = service(backend)
        await auth.start()
        XCTAssertNotNil(auth.phase.account)

        await auth.signOut()
        XCTAssertEqual(auth.phase, .signedOut)
        XCTAssertEqual(backend.calls.last, "signOut")
        do {
            _ = try await auth.accessToken()
            XCTFail("no token may be issued after sign-out")
        } catch {
            XCTAssertEqual(error as? NaraAuthError, .notSignedIn)
        }
    }

    func testARevokedSessionSignsThePhoneOut() async {
        let backend = FakeAuthBackend()
        backend.stored = FakeAuthBackend.session()
        let auth = service(backend)
        await auth.start()

        backend.tokenResult = .failure(NaraAuthError.sessionEnded)
        do {
            _ = try await auth.accessToken()
            XCTFail("expected the session to be refused")
        } catch {
            XCTAssertEqual(error as? NaraAuthError, .sessionEnded)
        }
        XCTAssertEqual(auth.phase, .signedOut, "a session the server refused for good must not linger")
        XCTAssertEqual(auth.notice, NaraAuthError.sessionEnded.errorDescription)
    }

    func testASessionEndedEventSignsOutButARefreshForAnotherAccountIsIgnored() async throws {
        let backend = FakeAuthBackend()
        backend.stored = FakeAuthBackend.session(userId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let auth = service(backend)
        await auth.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        backend.emit(.session(FakeAuthBackend.session(userId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(auth.phase.account?.userId, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                       "a session event never moves the bound account to someone else")

        backend.emit(.ended)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(auth.phase, .signedOut)
    }

    // MARK: password reset

    func testPasswordResetNeedsTheCodeAndANewPasswordAndEndsSignedIn() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await auth.start()

        await auth.requestPasswordReset(email: "A@Example.com")
        XCTAssertEqual(auth.phase, .awaitingRecoveryCode(email: "a@example.com"))

        await auth.completePasswordReset(code: "123456", newPassword: "short")
        XCTAssertEqual(auth.failure, .passwordTooShort)
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("verify") })

        backend.verifyResult = .success(FakeAuthBackend.session())
        await auth.completePasswordReset(code: "123456", newPassword: "a-brand-new-password")
        XCTAssertEqual(backend.calls.suffix(2), ["verify:a@example.com:123456:recovery", "updatePassword"])
        XCTAssertNotNil(auth.phase.account)
    }

    func testAResetThatCannotSetThePasswordDoesNotLeaveTheRecoverySessionSignedIn() async {
        let backend = FakeAuthBackend()
        backend.verifyResult = .success(FakeAuthBackend.session())
        backend.updatePasswordResult = .failure(NaraAuthError.weakPassword)
        let auth = service(backend)
        await auth.start()
        await auth.requestPasswordReset(email: "a@example.com")

        await auth.completePasswordReset(code: "123456", newPassword: "a-brand-new-password")
        XCTAssertEqual(auth.failure, .weakPassword)
        XCTAssertEqual(auth.phase, .signedOut)
        XCTAssertEqual(backend.calls.last, "signOut")
    }

    // MARK: unconfigured build

    func testABuildWithoutAnAuthProjectIsOfflineNara() async {
        let auth = service(nil)
        XCTAssertFalse(auth.isAvailable)
        await auth.start()
        XCTAssertEqual(auth.phase, .signedOut)
        await auth.signIn(email: "a@example.com", password: "password-123")
        XCTAssertEqual(auth.failure, .notConfigured)
    }
}
