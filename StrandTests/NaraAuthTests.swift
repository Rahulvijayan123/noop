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

/// The receiver's account-recovery route, scripted by the test.
final class FakeAccountRecovery: NaraAccountRecovering, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(accessToken: String, code: String)] = []

    var result: Result<String, Error> = .failure(CloudReceiverError.recoveryCodeInvalid)

    var requests: [(accessToken: String, code: String)] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func recoverAccount(accessToken: String, enrollmentCode: String) async throws -> String {
        lock.lock(); _requests.append((accessToken, enrollmentCode)); lock.unlock()
        return try result.get()
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
    private let defaults = isolatedDefaults()
    private let recovery = FakeAccountRecovery()

    private func service(_ backend: FakeAuthBackend?) -> NaraAuthService {
        NaraAuthService(backend: backend, recovery: recovery, defaults: defaults, now: { [clock] in clock.now })
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
        guard case .choosingSetup(let fresh) = auth.phase else {
            return XCTFail("a new account chooses how to start before it is signed in, got \(auth.phase)")
        }
        XCTAssertNil(auth.phase.account, "nothing may bind to an account that has not chosen yet")

        auth.continueAsNewAccount()
        guard case .signedIn(let account) = auth.phase else { return XCTFail("expected signed in, got \(auth.phase)") }
        XCTAssertEqual(account, fresh)
        XCTAssertEqual(account.userId, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "the canonical user id is lowercased")
        XCTAssertEqual(account.email, "new.user@example.com")
    }

    // MARK: setup choice and enrollment-code recovery

    private let freshId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let legacyId = "c4383464-0000-4000-8000-000000000001"

    /// Sign up and verify, leaving the service at the setup choice for `freshId`.
    private func verifiedNewAccount(_ backend: FakeAuthBackend, _ auth: NaraAuthService) async {
        await auth.start()
        await auth.signUp(email: "me@example.com", password: "password-123")
        backend.verifyResult = .success(FakeAuthBackend.session(userId: freshId, email: "me@example.com"))
        backend.tokenResult = .success("jwt-for-new")
        await auth.verifySignupCode("12345678")
    }

    func testThePendingSetupChoiceSurvivesARelaunchAndContinuingEndsIt() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await verifiedNewAccount(backend, auth)
        XCTAssertEqual(auth.phase, .choosingSetup(NaraAccount(userId: freshId, email: "me@example.com")))

        backend.stored = FakeAuthBackend.session(userId: freshId, email: "me@example.com")
        let relaunched = service(backend)
        await relaunched.start()
        XCTAssertEqual(relaunched.phase, .choosingSetup(NaraAccount(userId: freshId, email: "me@example.com")),
                       "quitting the app must not skip the choice")

        relaunched.continueAsNewAccount()
        let again = service(backend)
        await again.start()
        XCTAssertEqual(again.phase.account?.userId, freshId, "once chosen, the account restores signed in")
    }

    func testAnExistingAccountSigningInIsNotAskedToChoose() async {
        let backend = FakeAuthBackend()
        backend.signInResult = .success(FakeAuthBackend.session(userId: legacyId))
        let auth = service(backend)
        await auth.start()
        await auth.signIn(email: "a@example.com", password: "password-123")
        XCTAssertEqual(auth.phase.account?.userId, legacyId)
    }

    func testRecoveringWithAnEnrollmentCodeSignsIntoTheRecoveredAccount() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await verifiedNewAccount(backend, auth)
        recovery.result = .success(legacyId)
        backend.signInResult = .success(FakeAuthBackend.session(userId: legacyId, email: "me@example.com"))

        await auth.recoverAccount(enrollmentCode: " nara-abcd-efgh-jkmn-pqrs-tvwx ")
        XCTAssertNil(auth.failure)
        XCTAssertEqual(recovery.requests.map(\.accessToken), ["jwt-for-new"],
                       "the recovery is authorised by the new sign-up's own session")
        XCTAssertEqual(recovery.requests.map(\.code), ["NARAABCDEFGHJKMNPQRSTVWX"], "the code is sent canonical")
        XCTAssertEqual(backend.calls.last, "signIn:me@example.com",
                       "the sign-up's credentials now open the recovered account")
        XCTAssertEqual(auth.phase.account?.userId, legacyId)

        backend.stored = FakeAuthBackend.session(userId: legacyId, email: "me@example.com")
        let relaunched = service(backend)
        await relaunched.start()
        XCTAssertEqual(relaunched.phase.account?.userId, legacyId, "a recovered account is not asked to choose again")
    }

    func testARecoveryAfterARelaunchAsksForAFreshSignInWithTheEmailFilledIn() async {
        let backend = FakeAuthBackend()
        let first = service(backend)
        await verifiedNewAccount(backend, first)
        backend.stored = FakeAuthBackend.session(userId: freshId, email: "me@example.com")
        let auth = service(backend)
        await auth.start()
        recovery.result = .success(legacyId)

        await auth.recoverAccount(enrollmentCode: "NARA-ABCD-EFGH-JKMN-PQRS-TVWX")
        XCTAssertNil(auth.failure)
        XCTAssertEqual(auth.phase, .signedOut, "the password is not kept across launches, so sign in again")
        XCTAssertEqual(auth.suggestedEmail, "me@example.com")
        XCTAssertEqual(backend.calls.last, "signOut", "the deleted sign-up's session is dropped")
        XCTAssertNotNil(auth.notice)
    }

    func testARefusedRecoveryStaysOnTheChoiceWithTheReason() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await verifiedNewAccount(backend, auth)
        let cases: [(CloudReceiverError, NaraAuthError)] = [
            (.recoveryCodeInvalid, .enrollmentCodeInvalid),
            (.recoveryAlreadyUsed, .recoveryAlreadyUsed),
            (.recoveryAccountActive, .recoveryAccountActive),
            (.recoveryAccountNotEmpty, .recoveryAccountNotEmpty),
            (.rateLimited(retryAfter: 3600), .rateLimited),
            (.transport, .network),
        ]
        for (refusal, expected) in cases {
            recovery.result = .failure(refusal)
            await auth.recoverAccount(enrollmentCode: "NARAABCDEFGHJKMNPQRSTVWX")
            XCTAssertEqual(auth.failure, expected)
            XCTAssertEqual(auth.phase, .choosingSetup(NaraAccount(userId: freshId, email: "me@example.com")))
        }
        XCTAssertFalse(backend.calls.contains("signOut"))
    }

    func testARejectedSessionDuringRecoverySignsOut() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await verifiedNewAccount(backend, auth)
        recovery.result = .failure(CloudReceiverError.sessionRejected)

        await auth.recoverAccount(enrollmentCode: "NARAABCDEFGHJKMNPQRSTVWX")
        XCTAssertEqual(auth.failure, .sessionEnded)
        XCTAssertEqual(auth.phase, .signedOut)
    }

    func testAMalformedEnrollmentCodeNeverReachesTheServer() async {
        let backend = FakeAuthBackend()
        let auth = service(backend)
        await verifiedNewAccount(backend, auth)
        for bad in ["", "NARA", "NARA-ABCD-EFGH-JKMN-PQRS-TVW", "NARA-ABCD-EFGH-JKMN-PQRS-TVWXY",
                    "NOPE-ABCD-EFGH-JKMN-PQRS-TVWX", "NARA-ABCD-EFGH-JKMN-PQRS-TVWU"] {
            await auth.recoverAccount(enrollmentCode: bad)
            XCTAssertEqual(auth.failure, .malformedEnrollmentCode, "\(bad) is not an enrollment code")
        }
        XCTAssertTrue(recovery.requests.isEmpty)
    }

    func testEnrollmentCodesAreReadTheWayTheServerReadsThem() throws {
        XCTAssertEqual(try NaraAuthService.normalizedEnrollmentCode("nara-1lo0-abcd-efgh-jkmn-pqrs"),
                       "NARA1100ABCDEFGHJKMNPQRS", "I/L read as 1 and O as 0, like the server")
        XCTAssertEqual(try NaraAuthService.normalizedEnrollmentCode("NARA ABCD\tEFGH JKMN PQRS TVWX"),
                       "NARAABCDEFGHJKMNPQRSTVWX")
    }

    func testRecoveryIsOnlyOfferedAtTheSetupChoice() async {
        let backend = FakeAuthBackend()
        backend.stored = FakeAuthBackend.session(userId: legacyId)
        let auth = service(backend)
        await auth.start()
        await auth.recoverAccount(enrollmentCode: "NARAABCDEFGHJKMNPQRSTVWX")
        XCTAssertEqual(auth.failure, .notAwaitingCode)
        XCTAssertTrue(recovery.requests.isEmpty)
        XCTAssertEqual(auth.phase.account?.userId, legacyId)
    }

    func testSigningUpWithARegisteredEmailSuggestsSigningIn() async {
        let backend = FakeAuthBackend()
        backend.signUpResult = .success(.alreadyRegistered)
        let auth = service(backend)
        await auth.start()
        await auth.signUp(email: "Me@Example.com", password: "password-123")
        XCTAssertEqual(auth.failure, .accountExists)
        XCTAssertEqual(auth.phase, .signedOut)
        XCTAssertEqual(auth.suggestedEmail, "me@example.com")
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
