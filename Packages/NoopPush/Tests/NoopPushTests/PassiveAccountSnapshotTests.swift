import Foundation
import XCTest
@testable import NoopPush

private final class PassiveCredentialSpy: AccountCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    var value: AccountAuthSession?
    var failLoad = false, failSave = false, failClear = false
    private var counts = [0, 0, 0]
    func counters() -> [Int] { lock.withLock { counts } }
    func load(projectURL: String) throws -> AccountAuthSession? {
        try lock.withLock {
            counts[0] += 1
            if failLoad { throw AccountAuthError.credentialUnavailable }
            return value
        }
    }
    func save(_ session: AccountAuthSession) throws {
        try lock.withLock {
            counts[1] += 1
            if failSave { throw AccountAuthError.credentialUnavailable }
            value = session
        }
    }
    func clear(projectURL: String) throws {
        try lock.withLock {
            counts[2] += 1
            if failClear { throw AccountAuthError.credentialUnavailable }
            value = nil
        }
    }
}
private final class PassiveNotificationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func changed() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
private actor PassiveAuthTransportSpy: AccountAuthTransport {
    private var calls = 0
    private var pending: CheckedContinuation<AccountAuthReply, Error>?
    private var arrived: CheckedContinuation<Void, Never>?
    func exchange(configuration: AccountAuthConfiguration, grant: AccountAuthGrant) async throws -> AccountAuthReply {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            arrived?.resume(); arrived = nil
        }
    }
    func waitForCall() async {
        if pending != nil { return }
        await withCheckedContinuation { arrived = $0 }
    }
    func answer(_ reply: AccountAuthReply) { pending?.resume(returning: reply); pending = nil }
    func count() -> Int { calls }
}

final class PassiveAccountSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "11111111-1111-4111-8111-111111111111"
    private func configuration() throws -> AccountAuthConfiguration {
        try .init(projectURL: "https://passive-fixture.invalid", anonKey: "synthetic-anon")
    }
    private func session(lifetime: TimeInterval = 3600) throws -> AccountAuthSession {
        .init(scope: try AccountScope(projectURL: configuration().projectURL, userID: owner),
              accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: now.addingTimeInterval(lifetime))
    }
    private func controller(_ store: PassiveCredentialSpy, _ transport: PassiveAuthTransportSpy = .init(),
                            _ notifications: PassiveNotificationSpy = .init()) -> AccountSessionController {
        let date = now
        return .init(credentials: store, transport: transport, now: { date }, changed: { notifications.changed() })
    }
    private func assertPassive(_ controller: AccountSessionController, store: PassiveCredentialSpy,
                               notifications: PassiveNotificationSpy, expected: PassiveAccountSnapshot.Status,
                               file: StaticString = #filePath, line: UInt = #line) {
        let before = controller.passiveSnapshot(), calls = store.counters(), changes = notifications.value
        for _ in 0..<40 {
            let snapshot = controller.passiveSnapshot()
            XCTAssertEqual(snapshot, before, file: file, line: line)
            XCTAssertEqual(snapshot.status(at: now), expected, file: file, line: line)
        }
        XCTAssertEqual(store.counters(), calls, file: file, line: line)
        XCTAssertEqual(notifications.value, changes, file: file, line: line)
    }
    private func reply(status: Int = 200) throws -> AccountAuthReply {
        .init(status: status, body: try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-rotated", "refresh_token": "synthetic-refresh-rotated",
            "expires_in": 3600, "user": ["id": owner]
        ]))
    }

    func testUnconfiguredDoesNotLoadOrConfigure() {
        let store = PassiveCredentialSpy(), events = PassiveNotificationSpy(), c = controller(store, .init(), events)
        assertPassive(c, store: store, notifications: events, expected: .notConfigured)
        XCTAssertNil(c.passiveSnapshot().configuration)
        XCTAssertFalse(c.passiveSnapshot().loaded)
        XCTAssertEqual(store.counters(), [0, 0, 0]); XCTAssertEqual(events.value, 0)
    }

    func testConfiguredUnloadedStaysUnknownAndExistingGetterIsNonpassiveControl() throws {
        let store = PassiveCredentialSpy(), events = PassiveNotificationSpy(), c = controller(store, .init(), events)
        store.value = try session(); c.configure(try configuration())
        let generation = c.passiveSnapshot().generation
        assertPassive(c, store: store, notifications: events, expected: .notLoaded)
        XCTAssertNil(c.passiveSnapshot().context); XCTAssertEqual(store.counters(), [0, 0, 0])
        // This is ordinary lifecycle resolution outside the passive probe, and a negative control.
        _ = c.identitySnapshot()
        XCTAssertEqual(store.counters(), [1, 0, 0])
        XCTAssertEqual(c.passiveSnapshot().generation, generation)
        assertPassive(c, store: store, notifications: events, expected: .ready)
    }

    func testLoadedAbsentIsSignedOutWithoutRepeatedReads() throws {
        let store = PassiveCredentialSpy(), events = PassiveNotificationSpy(), c = controller(store, .init(), events)
        c.configure(try configuration()); XCTAssertNil(c.storedSession())
        XCTAssertEqual(store.counters(), [1, 0, 0])
        assertPassive(c, store: store, notifications: events, expected: .signedOut)
        XCTAssertTrue(c.passiveSnapshot().loaded); XCTAssertNil(c.passiveSnapshot().session)
    }

    func testUnavailableDoesNotRetryUnlockOrChangeGenerationUntilOrdinaryLifecycle() throws {
        let store = PassiveCredentialSpy(), events = PassiveNotificationSpy(), c = controller(store, .init(), events)
        store.value = try session(); store.failLoad = true; c.configure(try configuration())
        XCTAssertNil(c.storedSession())
        let unavailable = c.passiveSnapshot(), changes = events.value
        assertPassive(c, store: store, notifications: events, expected: .unavailable)
        store.failLoad = false
        assertPassive(c, store: store, notifications: events, expected: .unavailable)
        XCTAssertEqual(store.counters(), [1, 0, 0]); XCTAssertEqual(events.value, changes)
        XCTAssertEqual(c.passiveSnapshot().generation, unavailable.generation)
        XCTAssertNotNil(c.storedSession())
        XCTAssertEqual(store.counters(), [2, 0, 0]); XCTAssertEqual(events.value, changes + 1)
        XCTAssertNotEqual(c.passiveSnapshot().generation, unavailable.generation)
        assertPassive(c, store: store, notifications: events, expected: .ready)
    }

    func testExpiredAndMinimumLifetimeBoundaryNeverRefresh() throws {
        for remaining in [-1.0, 0.0, 30.0, 30.001] {
            let store = PassiveCredentialSpy(), events = PassiveNotificationSpy(), c = controller(store, .init(), events)
            store.value = try session(lifetime: remaining); c.configure(try configuration()); _ = c.storedSession()
            assertPassive(c, store: store, notifications: events, expected: remaining > 30 ? .ready : .expired)
            XCTAssertEqual(store.counters(), [1, 0, 0])
            XCTAssertEqual(c.passiveSnapshot().session?.expiresAt, now.addingTimeInterval(remaining))
        }
    }

    func testFailedClearRemainsUnavailableWithoutRetryingCredentialWrite() throws {
        let store = PassiveCredentialSpy(), events = PassiveNotificationSpy(), c = controller(store, .init(), events)
        store.value = try session(); c.configure(try configuration()); _ = c.storedSession()
        let old = c.passiveSnapshot().context
        store.failClear = true; XCTAssertThrowsError(try c.clearSession())
        assertPassive(c, store: store, notifications: events, expected: .unavailable)
        store.failClear = false
        assertPassive(c, store: store, notifications: events, expected: .unavailable)
        XCTAssertNil(c.passiveSnapshot().session); XCTAssertTrue(c.passiveSnapshot().operationPending)
        XCTAssertNotEqual(c.passiveSnapshot().context, old); XCTAssertEqual(store.counters(), [1, 0, 1])
    }

    func testPendingRefreshSnapshotsDoNotCancelRestartOrWrite() async throws {
        let store = PassiveCredentialSpy(), events = PassiveNotificationSpy(), transport = PassiveAuthTransportSpy()
        let c = controller(store, transport, events)
        store.value = try session(lifetime: 10); c.configure(try configuration()); _ = c.storedSession()
        let generation = c.passiveSnapshot().generation
        let refresh = Task { try await c.authorizedSession() }
        await transport.waitForCall()
        XCTAssertTrue(c.passiveSnapshot().operationPending)
        assertPassive(c, store: store, notifications: events, expected: .unavailable)
        XCTAssertEqual(store.counters(), [1, 0, 0])
        let calls = await transport.count(); XCTAssertEqual(calls, 1)
        await transport.answer(try reply()); _ = try await refresh.value
        XCTAssertEqual(c.passiveSnapshot().generation, generation)
        XCTAssertEqual(store.counters(), [1, 1, 0])
        assertPassive(c, store: store, notifications: events, expected: .ready)
    }

    func testPendingSignInDoesNotPublishReadyOrCancelExistingAttempt() async throws {
        let store = PassiveCredentialSpy(), events = PassiveNotificationSpy(), transport = PassiveAuthTransportSpy()
        let c = controller(store, transport, events)
        store.value = try session(); c.configure(try configuration()); _ = c.storedSession()
        let generation = c.passiveSnapshot().generation
        let login = Task { try await c.signIn(email: "synthetic@example.test", password: "synthetic") }
        await transport.waitForCall()
        assertPassive(c, store: store, notifications: events, expected: .unavailable)
        let calls = await transport.count(); XCTAssertEqual(calls, 1)
        await transport.answer(try reply()); _ = try await login.value
        XCTAssertEqual(c.passiveSnapshot().generation, generation)
        assertPassive(c, store: store, notifications: events, expected: .ready)
    }

    func testDirtyRefreshCredentialCannotBeSavedByPassiveSnapshot() async throws {
        let store = PassiveCredentialSpy(), events = PassiveNotificationSpy(), transport = PassiveAuthTransportSpy()
        let c = controller(store, transport, events)
        store.value = try session(lifetime: 10); c.configure(try configuration()); _ = c.storedSession()
        store.failSave = true
        let refresh = Task { try await c.authorizedSession() }
        await transport.waitForCall(); await transport.answer(try reply())
        do { _ = try await refresh.value; XCTFail("Expected failed credential persistence") }
        catch { XCTAssertEqual(error as? AccountAuthError, .credentialUnavailable) }
        let dirty = c.passiveSnapshot()
        XCTAssertTrue(dirty.operationPending); XCTAssertEqual(dirty.session?.accessToken, "synthetic-rotated")
        assertPassive(c, store: store, notifications: events, expected: .unavailable)
        store.failSave = false
        assertPassive(c, store: store, notifications: events, expected: .unavailable)
        XCTAssertEqual(store.counters(), [1, 1, 0])
        _ = try await c.authorizedSession()
        XCTAssertEqual(store.counters(), [1, 2, 0])
        assertPassive(c, store: store, notifications: events, expected: .ready)
    }
}
