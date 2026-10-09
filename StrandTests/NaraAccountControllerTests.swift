import XCTest
@testable import Strand

/// The account layer end to end on the client: a verified session in, a scoped credential and a running
/// upload path out, and the reverse on sign-out. A model of the server's provisioning rules stands in for the
/// network, so the same phone can be signed into two accounts and what each account ends up holding checked.
@MainActor
final class NaraAccountControllerTests: XCTestCase {

    private let ownerA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let ownerB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private var defaults: UserDefaults!
    private var secrets: MemorySecretStore!
    private var store: CloudPushIdentityStore!
    private var clock: TestClock!
    private var backend: FakeAuthBackend!
    private var auth: NaraAuthService!
    private var server: FakeProvisioningServer!
    private var runtime: FakeRuntime!
    private var controller: NaraAccountController!
    private var uploadsOn = true
    private var protectedData = true
    private var configured = true

    override func setUp() async throws {
        defaults = isolatedDefaults()
        secrets = MemorySecretStore()
        store = CloudPushIdentityStore(defaults: defaults, secrets: secrets)
        clock = TestClock()
        backend = FakeAuthBackend()
        server = FakeProvisioningServer(clock: clock)
        runtime = FakeRuntime()
        uploadsOn = true
        protectedData = true
        configured = true
        makeControllerStack()
    }

    private func makeControllerStack() {
        auth = NaraAuthService(backend: backend, defaults: defaults, now: { [clock] in clock!.now })
        controller = NaraAccountController(
            auth: auth, provisioner: server, runtime: runtime, store: store, defaults: defaults,
            appVersion: "1.0 (1)",
            isConfigured: { [unowned self] in self.configured },
            uploadsEnabled: { [unowned self] in self.uploadsOn },
            setUploadsFlag: { [unowned self] in self.uploadsOn = $0 },
            protectedDataAvailable: { [unowned self] in self.protectedData },
            now: { [clock] in clock!.now },
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
    }

    private func signIn(_ owner: String) async {
        backend.signInResult = .success(FakeAuthBackend.session(userId: owner, email: "\(owner.prefix(1))@example.com"))
        backend.tokenResult = .success("jwt-for-\(owner)")
        await auth.signIn(email: "\(owner.prefix(1))@example.com", password: "password-123")
        controller.refresh()
        await controller.settle()
    }

    private func signOut() async {
        await controller.signOut()
    }

    private func scope(_ owner: String) -> CloudDataScope {
        CloudDataScope(ownerId: owner, sourceId: store.existingSourceId(forOwner: owner) ?? "")
    }

    // MARK: provisioning

    func testSignInLinksThisPhoneToTheAccountAndStartsItsRuntimeOnly() async throws {
        uploadsOn = false
        await controller.start()
        XCTAssertEqual(controller.bootstrap, .idle)
        XCTAssertNil(runtime.runningScope)

        await signIn(ownerA)

        XCTAssertEqual(controller.bootstrap, .ready)
        let identity = try XCTUnwrap(store.identity(forOwner: ownerA))
        XCTAssertEqual(identity.ownerId, ownerA)
        XCTAssertEqual(identity.provisioning, .supabaseAuth)
        XCTAssertEqual(server.installationOwner(of: identity.sourceId), ownerA,
                       "the server bound the source to the account the session proved")
        XCTAssertEqual(server.currentToken(of: identity.sourceId), identity.uploadToken)
        XCTAssertEqual(runtime.runningScope, identity.scope)
        XCTAssertEqual(store.currentOwnerId(), ownerA)

        let call = try XCTUnwrap(server.calls.first)
        XCTAssertEqual(call.accessToken, "jwt-for-\(ownerA)", "the account is proved by the session's own token")
        XCTAssertNil(call.currentToken, "first time on this phone: nothing to present")
        XCTAssertEqual(server.calls.count, 1)
        XCTAssertTrue(uploadsOn, "signing in is the person choosing to sync")
    }

    func testARestartReusesTheStoredCredentialWithoutAskingTheServer() async throws {
        await controller.start()
        await signIn(ownerA)
        let first = try XCTUnwrap(store.identity(forOwner: ownerA))
        XCTAssertEqual(server.calls.count, 1)

        // Relaunch: a new process, the same Keychain and defaults, the session restored from storage.
        runtime = FakeRuntime()
        backend = FakeAuthBackend()
        backend.stored = FakeAuthBackend.session(userId: ownerA)
        backend.tokenResult = .success("jwt-for-\(ownerA)")
        makeControllerStack()
        await controller.start()

        XCTAssertEqual(controller.bootstrap, .ready)
        XCTAssertEqual(server.calls.count, 1, "no network is needed to resume uploading")
        XCTAssertEqual(runtime.runningScope, first.scope)
        XCTAssertEqual(store.identity(forOwner: ownerA), first)
    }

    func testACredentialNearExpiryIsRefreshedWhileTheOldOneIsPresented() async throws {
        await controller.start()
        await signIn(ownerA)
        let first = try XCTUnwrap(store.identity(forOwner: ownerA))

        clock.advance(by: 340 * 86_400)
        controller.refresh()
        await controller.settle()

        let second = try XCTUnwrap(store.identity(forOwner: ownerA))
        XCTAssertEqual(server.calls.last?.currentToken, first.uploadToken)
        XCTAssertNotEqual(second.uploadToken, first.uploadToken)
        XCTAssertEqual(second.sourceId, first.sourceId, "a refresh never moves the account to a different source")
    }

    // MARK: sign-out and account switching

    func testSignOutStopsUploadingAndRemovesTheCredentialButKeepsTheAccountsSource() async throws {
        await controller.start()
        await signIn(ownerA)
        let identity = try XCTUnwrap(store.identity(forOwner: ownerA))

        await signOut()

        XCTAssertEqual(auth.phase, .signedOut)
        XCTAssertNil(runtime.runningScope)
        XCTAssertNil(store.identity(forOwner: ownerA), "a signed-out account holds no live upload credential")
        XCTAssertNil(store.currentOwnerId())
        XCTAssertNil(store.current())
        XCTAssertEqual(store.existingSourceId(forOwner: ownerA), identity.sourceId,
                       "its queued data stays addressable under the same source")
        XCTAssertFalse(secrets.accounts.contains { $0.contains(identity.uploadToken) })
        XCTAssertEqual(controller.bootstrap, .idle)
    }

    func testTwoAccountsOnOnePhoneNeverShareASourceOrACredential() async throws {
        await controller.start()
        await signIn(ownerA)
        let a = try XCTUnwrap(store.identity(forOwner: ownerA))
        await signOut()

        await signIn(ownerB)
        let b = try XCTUnwrap(store.identity(forOwner: ownerB))

        XCTAssertNotEqual(a.sourceId, b.sourceId, "the source id is minted per account, never per phone")
        XCTAssertNotEqual(a.uploadToken, b.uploadToken)
        XCTAssertEqual(server.installationOwner(of: a.sourceId), ownerA)
        XCTAssertEqual(server.installationOwner(of: b.sourceId), ownerB)
        XCTAssertEqual(runtime.runningScope, b.scope)
        XCTAssertNil(server.calls.last?.currentToken, "B was not handed anything of A's to present")

        // While B is signed in, A's scope can not obtain a credential from the provider the runtime uses.
        let providerForA = CloudPushRuntime.credentialProvider(for: a.scope, store: store)
        XCTAssertNil(providerForA(), "A's scope never resolves to B's credential, or to none of A's")
        let providerForB = CloudPushRuntime.credentialProvider(for: b.scope, store: store)
        XCTAssertEqual(providerForB(), b)

        // A comes back: same source as before, a fresh credential, and B's is gone.
        await signOut()
        await signIn(ownerA)
        let aAgain = try XCTUnwrap(store.identity(forOwner: ownerA))
        XCTAssertEqual(aAgain.sourceId, a.sourceId, "the account keeps its source across sign-outs")
        XCTAssertEqual(runtime.runningScope, aAgain.scope)
        XCTAssertNil(store.identity(forOwner: ownerB))
        XCTAssertEqual(server.installationOwner(of: a.sourceId), ownerA, "no source ever changed hands")
        XCTAssertEqual(server.installationOwner(of: b.sourceId), ownerB)
    }

    func testASessionThatMovesToAnotherAccountRetiresTheFirstAccountsRuntime() async throws {
        await controller.start()
        await signIn(ownerA)
        let a = try XCTUnwrap(store.identity(forOwner: ownerA))

        // The sign-in screen is not reachable while signed in, but the service must still never leave A's
        // runtime running for B if the session is replaced underneath.
        await signIn(ownerB)

        let b = try XCTUnwrap(store.identity(forOwner: ownerB))
        XCTAssertEqual(runtime.runningScope, b.scope)
        XCTAssertNil(store.identity(forOwner: ownerA), "A's credential did not outlive A's session")
        XCTAssertEqual(store.currentOwnerId(), ownerB)
        XCTAssertNotEqual(a.sourceId, b.sourceId)
    }

    // MARK: failure handling

    func testASourceTheServerWillNotGiveThisAccountIsAbandonedAndNeverReused() async throws {
        await controller.start()
        // Someone else already holds the source this phone would pick for A (a copied or restored container).
        backend.signInResult = .success(FakeAuthBackend.session(userId: ownerA))
        let taken = store.sourceId(forOwner: ownerA)
        server.claim(sourceId: taken, owner: ownerB)

        await signIn(ownerA)

        let identity = try XCTUnwrap(store.identity(forOwner: ownerA))
        XCTAssertNotEqual(identity.sourceId, taken, "A moved to a fresh source rather than taking B's")
        XCTAssertEqual(server.installationOwner(of: taken), ownerB, "B's installation was never touched")
        XCTAssertEqual(server.installationOwner(of: identity.sourceId), ownerA)
        XCTAssertEqual(server.calls.map(\.sourceId), [taken, identity.sourceId])
        XCTAssertEqual(controller.bootstrap, .ready)
    }

    func testARevokedInstallationBlocksUntilThePersonSetsThePhoneUpAgain() async throws {
        await controller.start()
        let revoked = store.sourceId(forOwner: ownerA)
        server.claim(sourceId: revoked, owner: ownerA)
        server.revokeInstallation(sourceId: revoked)
        await signIn(ownerA)

        guard case .blocked = controller.bootstrap else { return XCTFail("expected blocked, got \(controller.bootstrap)") }
        XCTAssertNil(runtime.runningScope)
        XCTAssertNil(store.identity(forOwner: ownerA))
        XCTAssertEqual(store.existingSourceId(forOwner: ownerA), revoked)

        await controller.resetPhoneLink()
        XCTAssertEqual(controller.bootstrap, .ready)
        let fresh = try XCTUnwrap(store.identity(forOwner: ownerA))
        XCTAssertNotEqual(fresh.sourceId, revoked, "the revoked source is abandoned, not revived")
    }

    func testARejectedSessionSignsTheAccountOutAndStopsTheRuntime() async throws {
        await controller.start()
        await signIn(ownerA)
        XCTAssertNotNil(runtime.runningScope)

        server.provisionFaults = [CloudReceiverError.sessionRejected]
        clock.advance(by: 340 * 86_400)
        controller.refresh()
        await controller.settle()

        XCTAssertEqual(auth.phase, .signedOut)
        XCTAssertNil(runtime.runningScope)
        XCTAssertNil(store.identity(forOwner: ownerA))
        XCTAssertNotNil(controller.notice)
    }

    func testAnAnswerForAnotherAccountIsRefusedAndStoresNothing() async throws {
        await controller.start()
        server.answerForOwner = ownerB
        await signIn(ownerA)

        guard case .blocked = controller.bootstrap else { return XCTFail("expected blocked, got \(controller.bootstrap)") }
        XCTAssertNil(store.identity(forOwner: ownerA))
        XCTAssertNil(store.identity(forOwner: ownerB))
        XCTAssertNil(runtime.runningScope)
    }

    func testATransientFailureRetriesByItselfAndNothingStartsMeanwhile() async throws {
        await controller.start()
        server.provisionFaults = [CloudReceiverError.transport]
        await signIn(ownerA)

        guard case .retrying = controller.bootstrap else { return XCTFail("expected retrying, got \(controller.bootstrap)") }
        XCTAssertNil(runtime.runningScope)
        XCTAssertNil(store.identity(forOwner: ownerA))

        controller.refresh()
        await controller.settle()
        XCTAssertEqual(controller.bootstrap, .ready)
        XCTAssertNotNil(runtime.runningScope)
    }

    func testARateLimitIsNotRetriedBeforeTheServerSaidItMayBe() async throws {
        let delays = DelayRecorder()
        auth = NaraAuthService(backend: backend, defaults: defaults, now: { [clock] in clock!.now })
        controller = NaraAccountController(
            auth: auth, provisioner: server, runtime: runtime, store: store, defaults: defaults,
            appVersion: "1.0 (1)", isConfigured: { true }, uploadsEnabled: { true }, setUploadsFlag: { _ in },
            protectedDataAvailable: { true }, now: { [clock] in clock!.now },
            sleep: { delays.record($0); try? await Task.sleep(nanoseconds: 3_600_000_000_000) })
        await controller.start()
        server.provisionFaults = [CloudReceiverError.rateLimited(retryAfter: 300)]
        await signIn(ownerA)

        guard case .retrying = controller.bootstrap else { return XCTFail("expected retrying, got \(controller.bootstrap)") }
        for _ in 0..<100 where delays.values.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThanOrEqual(delays.values.last ?? 0, 300)
    }

    // MARK: rejected credential

    func testARejectedCredentialIsReplacedOnceAndNotInATightLoop() async throws {
        await controller.start()
        await signIn(ownerA)
        let first = try XCTUnwrap(store.identity(forOwner: ownerA))

        server.revoke(sourceId: first.sourceId)
        controller.credentialRejected(scope: first.scope, status: 401)
        await controller.settle()

        let second = try XCTUnwrap(store.identity(forOwner: ownerA))
        XCTAssertNotEqual(second.uploadToken, first.uploadToken, "the account asked for, and got, a replacement")
        XCTAssertEqual(second.sourceId, first.sourceId)
        let callsAfterFirst = server.calls.count

        // A burst of further rejections inside the cool-down asks for nothing more.
        server.revoke(sourceId: first.sourceId)
        controller.credentialRejected(scope: first.scope, status: 401)
        controller.credentialRejected(scope: first.scope, status: 401)
        await controller.settle()
        XCTAssertEqual(server.calls.count, callsAfterFirst)

        clock.advance(by: 3_600)
        controller.credentialRejected(scope: first.scope, status: 401)
        await controller.settle()
        XCTAssertEqual(server.calls.count, callsAfterFirst + 1)
        XCTAssertNotEqual(store.identity(forOwner: ownerA)?.uploadToken, second.uploadToken)
    }

    func testARejectionForSomeoneElsesScopeIsIgnored() async throws {
        await controller.start()
        await signIn(ownerA)
        let calls = server.calls.count
        let stranger = CloudDataScope(ownerId: ownerB, sourceId: UUID().uuidString)

        controller.credentialRejected(scope: stranger, status: 401)
        await controller.settle()
        XCTAssertEqual(server.calls.count, calls)
    }

    // MARK: always-on sync

    func testARestoredSessionWithAnOldOptOutSyncsAgain() async throws {
        await controller.start()
        await signIn(ownerA)
        let identity = try XCTUnwrap(store.identity(forOwner: ownerA))
        let calls = server.calls.count

        // Relaunch with the opt-out an older build could store, the session restored from storage.
        uploadsOn = false
        runtime = FakeRuntime()
        backend = FakeAuthBackend()
        backend.stored = FakeAuthBackend.session(userId: ownerA)
        backend.tokenResult = .success("jwt-for-\(ownerA)")
        makeControllerStack()
        await controller.start()

        XCTAssertTrue(uploadsOn, "a signed-in account always syncs")
        XCTAssertEqual(controller.bootstrap, .ready)
        XCTAssertEqual(runtime.runningScope, identity.scope)
        XCTAssertEqual(server.calls.count, calls, "the stored credential is reused")
    }

    func testSyncStatusComesFromTheRunningTransportOnly() async throws {
        let status = CloudSyncStatus(pendingRecords: 12, oldestPendingAt: clock.now, queuedBatches: 1,
                                     inFlight: 0, lastAttemptAt: nil, lastError: "receiver status 503")
        runtime.reportedSyncStatus = status
        await controller.start()
        let signedOut = await controller.syncStatus()
        XCTAssertNil(signedOut, "nothing is running while signed out")

        await signIn(ownerA)
        let signedIn = await controller.syncStatus()
        XCTAssertEqual(signedIn, status)
        XCTAssertEqual(signedIn?.isUpToDate, false)

        await signOut()
        let afterSignOut = await controller.syncStatus()
        XCTAssertNil(afterSignOut)
    }

    func testSyncStatusIsUpToDateOnlyWhenNothingIsWaiting() {
        var stats = CloudJournalStats.empty
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let drained = CloudSyncStatus(stats: stats, inFlight: 0, lastAttemptAtMs: 1_699_999_990_000,
                                      lastError: nil, now: now)
        XCTAssertTrue(drained.isUpToDate)
        XCTAssertNil(drained.oldestPendingAt)
        XCTAssertEqual(drained.lastAttemptAt, Date(timeIntervalSince1970: 1_699_999_990))

        stats.pendingRecords = 4
        stats.oldestPendingAgeSeconds = 60
        stats.uploadedBatches = 1
        let waiting = CloudSyncStatus(stats: stats, inFlight: 1, lastAttemptAtMs: nil, lastError: nil, now: now)
        XCTAssertFalse(waiting.isUpToDate)
        XCTAssertEqual(waiting.oldestPendingAt, now.addingTimeInterval(-60))
        XCTAssertEqual(waiting.queuedBatches, 1)
        XCTAssertEqual(waiting.inFlight, 1)
    }

    // MARK: on-device history

    func testTheFirstAccountClaimsTheOnDeviceHistoryAndAnotherAccountDoesNotInheritIt() async throws {
        await controller.start()
        await signIn(ownerA)
        XCTAssertTrue(controller.ownsLocalHistory)
        XCTAssertEqual(CloudLocalDataBinding.owner(defaults: defaults), ownerA)

        await signOut()
        await signIn(ownerB)
        XCTAssertFalse(controller.ownsLocalHistory, "B is signed in on A's phone: A's saved history is not B's")
        XCTAssertEqual(CloudLocalDataBinding.owner(defaults: defaults), ownerA)
        XCTAssertFalse(CloudLocalDataBinding.signedInAccountOwnsLocalData(store: store, defaults: defaults))

        await signOut()
        await signIn(ownerA)
        XCTAssertTrue(controller.ownsLocalHistory)
        XCTAssertTrue(CloudLocalDataBinding.signedInAccountOwnsLocalData(store: store, defaults: defaults))
    }

    // MARK: setup choice

    func testANewAccountLinksNothingUntilItChoosesHowToStart() async throws {
        uploadsOn = false
        await controller.start()
        await auth.signUp(email: "b@example.com", password: "password-123")
        backend.verifyResult = .success(FakeAuthBackend.session(userId: ownerB, email: "b@example.com"))
        backend.tokenResult = .success("jwt-for-\(ownerB)")
        await auth.verifySignupCode("12345678")
        controller.refresh()
        await controller.settle()

        guard case .choosingSetup = auth.phase else { return XCTFail("expected the setup choice, got \(auth.phase)") }
        XCTAssertEqual(controller.bootstrap, .idle)
        XCTAssertTrue(server.calls.isEmpty, "provisioning first would give the account data and rule out recovery")
        XCTAssertNil(CloudLocalDataBinding.owner(defaults: defaults), "the phone's history is not claimed yet")
        XCTAssertNil(runtime.runningScope)
        XCTAssertFalse(uploadsOn)

        auth.continueAsNewAccount()
        for _ in 0..<100 where controller.bootstrap != .ready { try await Task.sleep(nanoseconds: 10_000_000) }
        await controller.settle()
        XCTAssertTrue(uploadsOn, "choosing is the person's decision to use the cloud account")
        XCTAssertEqual(controller.bootstrap, .ready)
        XCTAssertEqual(server.calls.map(\.expectedOwnerId), [ownerB])
        XCTAssertEqual(CloudLocalDataBinding.owner(defaults: defaults), ownerB)
        XCTAssertEqual(runtime.runningScope?.ownerId, ownerB)
    }

    // MARK: wearable link

    func testTheStrapIsLinkedOncePerAccountAndNeverToASecondAccount() async throws {
        await controller.start()
        await signIn(ownerA)
        let a = try XCTUnwrap(store.identity(forOwner: ownerA))

        let linked = await controller.confirmWearableIfNeeded(provisionalDeviceId: "my-whoop", serial: "MGB0214654")
        XCTAssertTrue(linked)
        let again = await controller.confirmWearableIfNeeded(provisionalDeviceId: "my-whoop", serial: "MGB0214654")
        XCTAssertTrue(again)
        XCTAssertEqual(server.confirmations, [
            .init(scope: a.scope, provisionalDeviceId: "my-whoop", serial: "MGB0214654"),
        ], "a confirmed strap is not confirmed again")

        // Another account on the same phone, with the same strap in range, can not take it over.
        await signOut()
        await signIn(ownerB)
        let stolen = await controller.confirmWearableIfNeeded(provisionalDeviceId: "my-whoop", serial: "MGB0214654")
        XCTAssertFalse(stolen, "the server refused to move the strap to B")
        XCTAssertEqual(server.confirmations.count, 2)
        XCTAssertNil(defaults.string(forKey: NaraAccountController.wearableKey(scope: try XCTUnwrap(store.identity(forOwner: ownerB)).scope)),
                     "a refused link is not remembered as done")

        // A returns and is still linked: nothing more to send.
        await signOut()
        await signIn(ownerA)
        let back = await controller.confirmWearableIfNeeded(provisionalDeviceId: "my-whoop", serial: "MGB0214654")
        XCTAssertTrue(back)
        XCTAssertEqual(server.confirmations.count, 2)
    }

    func testNoStrapIsLinkedWhileNobodyIsSignedIn() async throws {
        await controller.start()
        let linked = await controller.confirmWearableIfNeeded(provisionalDeviceId: "my-whoop", serial: "MGB0214654")
        XCTAssertFalse(linked)
        XCTAssertTrue(server.confirmations.isEmpty)
    }

    // MARK: background / locked phone

    func testTheUploadCredentialDoesNotDependOnTheAuthSession() async throws {
        await controller.start()
        await signIn(ownerA)
        let identity = try XCTUnwrap(store.identity(forOwner: ownerA))

        // A background relaunch: no Auth session can be read (the phone is locked, the network is down),
        // but the runtime's credential provider still resolves the account's own credential.
        let provider = CloudPushRuntime.credentialProvider(for: identity.scope, store: store)
        XCTAssertEqual(provider(), identity)
        XCTAssertEqual(store.current(), identity, "startIfEnabled picks the credential up the same way")
    }

    func testNoSessionBeforeTheFirstUnlockDoesNotDiscardTheCredential() async throws {
        await controller.start()
        await signIn(ownerA)
        let identity = try XCTUnwrap(store.identity(forOwner: ownerA))

        // The app is relaunched in the background right after a reboot: protected storage is unreadable, so
        // the stored session comes back empty. That is "can't tell yet", not "signed out".
        protectedData = false
        runtime = FakeRuntime()
        backend = FakeAuthBackend()
        makeControllerStack()
        await controller.start()

        XCTAssertEqual(store.identity(forOwner: ownerA), identity)
        XCTAssertEqual(store.currentOwnerId(), ownerA)
    }

    func testASignedOutPhoneWithAStaleCredentialIsCleanedUpOnceDataIsReadable() async throws {
        await controller.start()
        await signIn(ownerA)

        runtime = FakeRuntime()
        backend = FakeAuthBackend()
        makeControllerStack()
        await controller.start()

        XCTAssertNil(store.identity(forOwner: ownerA), "no session and readable storage: the credential is removed")
        XCTAssertNil(store.currentOwnerId())
    }

    func testABuildWithoutACloudProjectDoesNothing() async throws {
        configured = false
        await controller.start()
        await signIn(ownerA)
        XCTAssertEqual(controller.bootstrap, .idle)
        XCTAssertTrue(server.calls.isEmpty)
        XCTAssertNil(runtime.runningScope)
    }
}

final class DelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        lock.lock(); _values.append(value); lock.unlock()
    }

    var values: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }
}
