import Foundation
import XCTest
@testable import NoopPush

final class AccountRecoveryTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let other = "22222222-2222-4222-8222-222222222222"

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testRESTRequestsUseRecoveryTypeAndAuthenticatedPasswordMutationWithoutRedirect() throws {
        let configuration = try AccountAuthConfiguration(projectURL: "https://fixture.invalid", anonKey: "synthetic-anon")
        let grants: [(AccountAuthGrant, String, String)] = [
            (.recover(email: "fixture@example.test"), "/auth/v1/recover", "POST"),
            (.verifyRecovery(email: "fixture@example.test", code: "12345678"), "/auth/v1/verify", "POST"),
            (.updateRecoveredPassword(accessToken: "synthetic-recovery", password: "synthetic-new", nonce: "87654321"), "/auth/v1/user", "PUT"),
            (.reauthenticateRecovery(accessToken: "synthetic-recovery"), "/auth/v1/reauthenticate", "GET")
        ]
        for (index, item) in grants.enumerated() {
            let request = try item.0.request(configuration: configuration)
            XCTAssertEqual(request.url?.host, "fixture.invalid")
            XCTAssertEqual(request.url?.path, item.1)
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, item.2)
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "synthetic-anon")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), index > 1 ? "Bearer synthetic-recovery" : nil)
            let body = try request.httpBody.map { try JSONSerialization.jsonObject(with: $0) as? [String: String] }
            XCTAssertNil(body??["redirect_to"])
            if index == 1 { XCTAssertEqual(body??["type"], "recovery"); XCTAssertEqual(body??["token"], "12345678") }
            if index == 2 { XCTAssertEqual(body??["nonce"], "87654321"); XCTAssertEqual(body??["password"], "synthetic-new") }
            if index == 3 { XCTAssertNil(request.httpBody) }
        }
    }

    func testSameOwnerRecoveryUsesOrdinarySignInAndPersistsOnlyFinalSession() async throws {
        let f = try fixture()
        let before = f.controller.identitySnapshot()
        let challenge = try await begin(f)
        try await verify(f, challenge)
        XCTAssertEqual(f.controller.identitySnapshot(), before)
        XCTAssertEqual(f.store.saves, 0)
        XCTAssertNil(f.controller.storedSession())
        let finish = Task { try await f.controller.completeRecovery(challenge, password: "synthetic-new", validateRuntime: {}) }
        await f.transport.wait(3)
        XCTAssertEqual(f.store.saves, 0)
        assertEqual(await f.transport.kind(2), "update")
        await f.transport.answer(2, user(owner))
        await f.transport.wait(4)
        assertEqual(await f.transport.kind(3), "password")
        XCTAssertEqual(f.store.saves, 0)
        await f.transport.answer(3, session(owner, token: "synthetic-normal"))
        let result = try await finish.value
        XCTAssertEqual(result.accessToken, "synthetic-normal")
        XCTAssertEqual(f.store.saves, 1)
        XCTAssertEqual(f.store.clears, 0)
        let relaunched = AccountSessionController(credentials: f.store, transport: f.transport)
        relaunched.configure(f.configuration)
        XCTAssertEqual(relaunched.storedSession(), result)
        await expect(.staleOperation) { try await relaunched.verifyRecovery(challenge, code: "12345678", validateRuntime: {}) }
    }

    func testForeignOwnerNeverChangesPasswordOrPersistsRecoverySession() async throws {
        let f = try fixture()
        let challenge = try await begin(f)
        let task = Task { try await f.controller.verifyRecovery(challenge, code: "12345678", validateRuntime: {}) }
        await f.transport.wait(2)
        await f.transport.answer(1, session(other))
        await expect(.accountSwitchRequired) { try await task.value }
        await expect(.staleOperation) { _ = try await f.controller.completeRecovery(challenge, password: "synthetic", validateRuntime: {}) }
        assertEqual(await f.transport.count, 2)
        XCTAssertEqual(f.store.saves, 0)
        XCTAssertEqual(f.store.clears, 0)
    }

    func testInvalidExpiredAndForeignRecoveryPreserveExactExistingSameOwnerSession() async throws {
        for outcome in ["invalid", "expired", "foreign"] {
            let f = try fixture()
            let retained = AccountAuthSession(scope: f.runtime.scope, accessToken: "synthetic-retained",
                refreshToken: "synthetic-retained-refresh", expiresAt: Date().addingTimeInterval(3600))
            try f.store.save(retained)
            let before = f.controller.identitySnapshot()
            let challenge = try await begin(f)
            let task = Task { try await f.controller.verifyRecovery(challenge, code: "12345678", validateRuntime: {}) }
            await f.transport.wait(2)
            await f.transport.answer(1, outcome == "foreign" ? session(other) : failure("otp_expired", status: outcome == "invalid" ? 400 : 403))
            await expect(outcome == "foreign" ? .accountSwitchRequired : .recoveryCodeInvalid) { try await task.value }
            XCTAssertEqual(f.controller.storedSession(), retained)
            XCTAssertEqual(f.controller.identitySnapshot(), before)
            XCTAssertEqual(f.store.saves, 1)
            XCTAssertEqual(f.store.clears, 0)
            assertEqual(await f.transport.count, 2)
        }
    }

    func testGenerationRuntimeChangeAndCancellationAfterPasswordDispatchNeverPublishSession() async throws {
        for change in ["configure", "runtime", "cancel"] {
            let f = try fixture()
            let challenge = try await begin(f)
            try await verify(f, challenge)
            let fence = RecoveryRuntimeFence()
            let task = Task { try await f.controller.completeRecovery(challenge, password: "synthetic-new", validateRuntime: { try fence.validate() }) }
            await f.transport.wait(3)
            if change == "configure" { f.controller.configure(try .init(projectURL: "https://replacement.invalid", anonKey: "synthetic")) }
            if change == "runtime" { fence.invalidate() }
            if change == "cancel" { task.cancel() }
            await f.transport.answer(2, user(owner))
            await expect(.passwordChangedSignInRequired) { _ = try await task.value }
            XCTAssertNil(f.controller.storedSession())
            XCTAssertEqual(f.store.saves, 0)
            assertEqual(await f.transport.count, 3)
        }
    }

    func testInvalidAndExpiredCodesLeaveExistingSessionAndAllowRetry() async throws {
        for status in [400, 403, 422] {
            let f = try fixture()
            let challenge = try await begin(f)
            let task = Task { try await f.controller.verifyRecovery(challenge, code: "bad", validateRuntime: {}) }
            await f.transport.wait(2)
            await f.transport.answer(1, failure("otp_expired", status: status))
            await expect(.recoveryCodeInvalid) { try await task.value }
            XCTAssertNil(f.controller.storedSession())
            XCTAssertEqual(f.store.saves, 0)
            try await verify(f, challenge, index: 2)
            XCTAssertEqual(f.store.saves, 0)
        }
    }

    func testGenerationChangesAndCancellationFenceVerificationAndPasswordDispatch() async throws {
        for change in ["configure", "logout", "runtime", "cancel"] {
            let f = try fixture()
            let challenge = try await begin(f)
            let fence = RecoveryRuntimeFence()
            let task = Task { try await f.controller.verifyRecovery(challenge, code: "12345678", validateRuntime: { try fence.validate() }) }
            await f.transport.wait(2)
            if change == "configure" { f.controller.configure(try .init(projectURL: "https://replacement.invalid", anonKey: "synthetic")) }
            if change == "logout" { try f.controller.clearSession() }
            if change == "runtime" { fence.invalidate() }
            if change == "cancel" { task.cancel() }
            await f.transport.answer(1, session(owner))
            do { try await task.value; XCTFail("Stale verification accepted") } catch {}
            do { _ = try await f.controller.completeRecovery(challenge, password: "synthetic", validateRuntime: { try fence.validate() }); XCTFail("Stale mutation dispatched") } catch {}
            assertEqual(await f.transport.count, 2)
            XCTAssertEqual(f.store.saves, 0)
        }
    }

    func testRuntimeReplacementAfterVerifiedCodePreventsPasswordMutation() async throws {
        let f = try fixture()
        let challenge = try await begin(f)
        try await verify(f, challenge)
        await expect(.staleOperation) {
            _ = try await f.controller.completeRecovery(challenge, password: "synthetic", validateRuntime: { throw AccountAuthError.staleOperation })
        }
        assertEqual(await f.transport.count, 2)
    }

    func testRelaunchDropsTemporaryRecoveryAndKeepsExistingCredential() async throws {
        let f = try fixture()
        let challenge = try await begin(f)
        try await verify(f, challenge)
        let relaunched = AccountSessionController(credentials: f.store, transport: f.transport)
        relaunched.configure(f.configuration)
        await expect(.staleOperation) { _ = try await relaunched.completeRecovery(challenge, password: "synthetic", validateRuntime: {}) }
        XCTAssertNil(relaunched.storedSession())
        assertEqual(await f.transport.count, 2)
    }

    func testPersistenceFailureAfterPasswordMutationRequiresNormalSignInAndNeverSavesRecoveryToken() async throws {
        let f = try fixture()
        let challenge = try await begin(f)
        try await verify(f, challenge)
        f.store.failSave = true
        let task = Task { try await f.controller.completeRecovery(challenge, password: "synthetic-new", validateRuntime: {}) }
        await f.transport.wait(3)
        await f.transport.answer(2, user(owner))
        await f.transport.wait(4)
        await f.transport.answer(3, session(owner, token: "synthetic-normal"))
        await expect(.passwordChangedSignInRequired) { _ = try await task.value }
        XCTAssertNil(f.controller.storedSession())
        XCTAssertEqual(f.store.saves, 0)
        XCTAssertEqual(f.store.clears, 0)
        await expect(.staleOperation) { _ = try await f.controller.completeRecovery(challenge, password: "synthetic", validateRuntime: {}) }
    }

    func testSecurePasswordChangeUsesExplicitReauthenticationAndNonce() async throws {
        let f = try fixture()
        let challenge = try await begin(f)
        try await verify(f, challenge)
        let first = Task { try await f.controller.completeRecovery(challenge, password: "synthetic-new", validateRuntime: {}) }
        await f.transport.wait(3)
        await f.transport.answer(2, failure("reauthentication_needed", status: 422))
        await expect(.reauthenticationRequired) { _ = try await first.value }
        assertEqual(await f.transport.count, 3)
        let send = Task { try await f.controller.sendRecoveryReauthentication(challenge, validateRuntime: {}) }
        await f.transport.wait(4)
        assertEqual(await f.transport.kind(3), "reauthenticate")
        await f.transport.answer(3, .init(status: 200, body: Data("{}".utf8)))
        try await send.value
        let finish = Task { try await f.controller.completeRecovery(challenge, password: "synthetic-new", nonce: "87654321", validateRuntime: {}) }
        await f.transport.wait(5)
        assertEqual(await f.transport.nonce(4), "87654321")
        await f.transport.answer(4, user(owner))
        await f.transport.wait(6)
        await f.transport.answer(5, session(owner, token: "synthetic-normal"))
        _ = try await finish.value
        XCTAssertEqual(f.store.saves, 1)
    }

    func testForeignProjectRejectedBeforeEmailAndExpiredRecoveryBeforePassword() async throws {
        let f = try fixture()
        let foreign = AccountSessionContext(scope: try .init(projectURL: "https://other.invalid", userID: owner), generation: UUID())
        await expect(.invalidIdentity) { _ = try await f.controller.beginRecovery(email: "fixture@example.test", runtimeContext: foreign, validateRuntime: {}) }
        assertEqual(await f.transport.count, 0)
        let challenge = try await begin(f)
        let task = Task { try await f.controller.verifyRecovery(challenge, code: "12345678", validateRuntime: {}) }
        await f.transport.wait(2)
        await f.transport.answer(1, session(owner, seconds: 10))
        try await task.value
        await expect(.recoveryExpired) { _ = try await f.controller.completeRecovery(challenge, password: "synthetic", validateRuntime: {}) }
        assertEqual(await f.transport.count, 2)
    }

    private struct Fixture {
        let store: RecoveryCredentialMemory
        let transport: RecoveryTransport
        let controller: AccountSessionController
        let configuration: AccountAuthConfiguration
        let runtime: AccountSessionContext
    }
    private func fixture() throws -> Fixture {
        let configuration = try AccountAuthConfiguration(projectURL: "https://fixture.invalid", anonKey: "synthetic-anon")
        let store = RecoveryCredentialMemory()
        let transport = RecoveryTransport()
        let controller = AccountSessionController(credentials: store, transport: transport)
        controller.configure(configuration)
        return Fixture(store: store, transport: transport, controller: controller, configuration: configuration,
            runtime: .init(scope: try .init(projectURL: configuration.projectURL, userID: owner), generation: UUID()))
    }
    private func begin(_ f: Fixture) async throws -> AccountRecoveryChallenge {
        let task = Task { try await f.controller.beginRecovery(email: "fixture@example.test", runtimeContext: f.runtime, validateRuntime: {}) }
        await f.transport.wait(1)
        await f.transport.answer(0, .init(status: 200, body: Data("{}".utf8)))
        return try await task.value
    }
    private func verify(_ f: Fixture, _ challenge: AccountRecoveryChallenge, index: Int = 1) async throws {
        let task = Task { try await f.controller.verifyRecovery(challenge, code: "12345678", validateRuntime: {}) }
        await f.transport.wait(index + 1)
        await f.transport.answer(index, session(owner))
        try await task.value
    }
    private func session(_ id: String, token: String = "synthetic-recovery", seconds: Int = 3600) -> AccountAuthReply {
        .init(status: 200, body: try! JSONSerialization.data(withJSONObject: ["access_token": token,
            "refresh_token": "synthetic-refresh", "expires_in": seconds, "user": ["id": id]]))
    }
    private func user(_ id: String) -> AccountAuthReply { .init(status: 200, body: Data("{\"id\":\"\(id)\"}".utf8)) }
    private func failure(_ code: String, status: Int) -> AccountAuthReply { .init(status: status, body: Data("{\"error_code\":\"\(code)\"}".utf8)) }
    private func expect(_ expected: AccountAuthError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? AccountAuthError, expected) }
    }
}

private final class RecoveryRuntimeFence: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func invalidate() { lock.withLock { valid = false } }
    func validate() throws { try lock.withLock { if !valid { throw AccountAuthError.staleOperation } } }
}

private final class RecoveryCredentialMemory: AccountCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountAuthSession?
    var saves = 0
    var clears = 0
    var failSave = false
    func load(projectURL: String) throws -> AccountAuthSession? { lock.withLock { value } }
    func save(_ session: AccountAuthSession) throws {
        try lock.withLock {
            if failSave { throw AccountAuthError.credentialUnavailable }
            value = session; saves += 1
        }
    }
    func clear(projectURL: String) throws { lock.withLock { value = nil; clears += 1 } }
}

private actor RecoveryTransport: AccountAuthTransport {
    private var requests: [(AccountAuthGrant, CheckedContinuation<AccountAuthReply, Error>)] = []
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int { requests.count }
    func exchange(configuration: AccountAuthConfiguration, grant: AccountAuthGrant) async throws -> AccountAuthReply {
        try await withCheckedThrowingContinuation { continuation in
            requests.append((grant, continuation))
            let ready = waiting.filter { requests.count >= $0.0 }
            waiting.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func wait(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }
    func answer(_ index: Int, _ reply: AccountAuthReply) { requests[index].1.resume(returning: reply) }
    func kind(_ index: Int) -> String {
        switch requests[index].0 {
        case .password: return "password"
        case .recover: return "recover"
        case .verifyRecovery: return "verify"
        case .updateRecoveredPassword: return "update"
        case .reauthenticateRecovery: return "reauthenticate"
        case .refresh: return "refresh"
        }
    }
    func nonce(_ index: Int) -> String? {
        if case .updateRecoveredPassword(_, _, let nonce) = requests[index].0 { return nonce }
        return nil
    }
}
