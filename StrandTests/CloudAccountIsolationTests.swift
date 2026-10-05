import XCTest
import NoopPush
import WhoopProtocol
@testable import Strand

/// One phone, two accounts. These pin the client-side half of the isolation guarantee: what is stored, what
/// the journal returns, what a coordinator will seal and send, and what the wire carries are all keyed by the
/// `(account, source)` pair, so signing A out and B in can never hand B anything of A's, or retag A's data.
final class CloudAccountIsolationTests: XCTestCase {

    private let ownerA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let ownerB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private var defaults: UserDefaults!
    private var secrets: MemorySecretStore!
    private var store: CloudPushIdentityStore!
    private var directory: URL!

    override func setUpWithError() throws {
        defaults = isolatedDefaults()
        secrets = MemorySecretStore()
        store = CloudPushIdentityStore(defaults: defaults, secrets: secrets)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nara-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CloudPushSettings.bundleStringOverride = nil
        CloudJournal.shared.endStaging()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - identity store

    func testEachAccountGetsItsOwnStableSourceId() {
        XCTAssertNil(store.existingSourceId(forOwner: ownerA))
        let a = store.sourceId(forOwner: ownerA)
        let b = store.sourceId(forOwner: ownerB)
        XCTAssertNotEqual(a, b, "there is no install-wide source id")
        XCTAssertEqual(store.sourceId(forOwner: ownerA), a)
        XCTAssertEqual(store.sourceId(forOwner: ownerA.uppercased()), a, "ids compare case-insensitively")
        XCTAssertEqual(store.sourceId(forOwner: ownerB), b)
        XCTAssertNotNil(UUID(uuidString: a))
    }

    func testAnInstallEnrolledWithACodeKeepsItsSourceForThatAccountAndNoOtherAccount() {
        let enrolledSource = UUID().uuidString.lowercased()
        defaults.set(enrolledSource, forKey: "noop.cloud.sourceId")
        defaults.set(ownerA, forKey: "noop.cloud.ownerId")

        // B signs in first on the migrated phone: B must not be handed the source that was bound to A.
        let b = store.sourceId(forOwner: ownerB)
        XCTAssertNotEqual(b, enrolledSource)

        let a = store.sourceId(forOwner: ownerA)
        XCTAssertEqual(a, enrolledSource, "the enrolling account keeps the source the server already bound")
        XCTAssertNotEqual(store.sourceId(forOwner: ownerB), a)
    }

    func testAnOrphanedLegacySourceIsNeverInherited() {
        defaults.set(UUID().uuidString.lowercased(), forKey: "noop.cloud.sourceId")
        let a = store.sourceId(forOwner: ownerA)
        XCTAssertNotEqual(a, defaults.string(forKey: "noop.cloud.sourceId"),
                          "a source with no recorded owner belongs to nobody")
    }

    func testCredentialsAreKeptPerAccountAndSourceAndNeverCross() throws {
        let sourceA = store.sourceId(forOwner: ownerA)
        let sourceB = store.sourceId(forOwner: ownerB)
        store.store(token: "noop_token_a", tokenId: UUID().uuidString, expiresAt: nil, ownerId: ownerA, sourceId: sourceA)
        store.store(token: "noop_token_b", tokenId: UUID().uuidString, expiresAt: nil, ownerId: ownerB, sourceId: sourceB)

        XCTAssertEqual(store.identity(forOwner: ownerA)?.uploadToken, "noop_token_a")
        XCTAssertEqual(store.identity(forOwner: ownerA)?.sourceId, sourceA)
        XCTAssertEqual(store.identity(forOwner: ownerB)?.uploadToken, "noop_token_b")
        XCTAssertEqual(store.identity(forOwner: ownerB)?.sourceId, sourceB)

        store.removeCredential(forOwner: ownerA)
        XCTAssertNil(store.identity(forOwner: ownerA))
        XCTAssertEqual(store.identity(forOwner: ownerB)?.uploadToken, "noop_token_b", "removing A touches nothing of B's")
    }

    func testStoringACredentialNeverMovesTheActiveAccount() {
        let source = store.sourceId(forOwner: ownerA)
        store.activate(ownerId: ownerB)
        store.store(token: "noop_token_a", tokenId: UUID().uuidString, expiresAt: nil, ownerId: ownerA, sourceId: source)
        XCTAssertEqual(store.currentOwnerId(), ownerB, "binding an account is its own explicit step")
        XCTAssertNil(store.current(), "B is active but holds no credential")
    }

    func testSigningOutRemovesTheCredentialButKeepsTheSourceForTheNextSignIn() {
        let source = store.sourceId(forOwner: ownerA)
        store.store(token: "noop_token_a", tokenId: UUID().uuidString, expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
                    ownerId: ownerA, sourceId: source)
        store.activate(ownerId: ownerA)
        XCTAssertNotNil(store.current())

        store.signOutCurrentOwner()
        XCTAssertNil(store.currentOwnerId())
        XCTAssertNil(store.current())
        XCTAssertNil(store.identity(forOwner: ownerA))
        XCTAssertNil(store.credentialExpiry(forOwner: ownerA))
        XCTAssertEqual(store.existingSourceId(forOwner: ownerA), source, "queued data stays addressable")
        XCTAssertFalse(secrets.accounts.contains { $0.contains("noop_token_a") })
    }

    func testRotatingASourceAbandonsTheOldOneAndItsCredential() {
        let old = store.sourceId(forOwner: ownerA)
        store.store(token: "noop_token_a", tokenId: UUID().uuidString, expiresAt: nil, ownerId: ownerA, sourceId: old)

        let fresh = store.rotateSourceId(forOwner: ownerA)
        XCTAssertNotEqual(fresh, old)
        XCTAssertEqual(store.existingSourceId(forOwner: ownerA), fresh)
        XCTAssertNil(store.identity(forOwner: ownerA), "the old credential is not carried to the new source")
        XCTAssertFalse(secrets.accounts.contains { $0.contains(old) })
    }

    func testForgettingOneAccountLeavesTheOtherUntouched() {
        let sourceA = store.sourceId(forOwner: ownerA)
        let sourceB = store.sourceId(forOwner: ownerB)
        store.store(token: "noop_token_a", tokenId: UUID().uuidString, expiresAt: nil, ownerId: ownerA, sourceId: sourceA)
        store.store(token: "noop_token_b", tokenId: UUID().uuidString, expiresAt: nil, ownerId: ownerB, sourceId: sourceB)
        store.activate(ownerId: ownerA)

        store.forget(ownerId: ownerA)
        XCTAssertNil(store.existingSourceId(forOwner: ownerA))
        XCTAssertNil(store.currentOwnerId())
        XCTAssertEqual(store.identity(forOwner: ownerB)?.sourceId, sourceB)
    }

    func testALegacyEnrollmentCredentialIsInertUnlessThisIsAMigrationBuild() {
        let source = UUID().uuidString.lowercased()
        defaults.set(source, forKey: "noop.cloud.sourceId")
        defaults.set(ownerA, forKey: "noop.cloud.ownerId")
        defaults.set(ownerA, forKey: "noop.cloud.tokenId.\(ownerA)")
        secrets.set("noop_legacy_token", account: "uploadToken.\(ownerA)")
        _ = store.sourceId(forOwner: ownerA)

        XCTAssertNil(store.identity(forOwner: ownerA), "tester builds never use an enrollment-code credential")

        CloudPushSettings.bundleStringOverride = { key in
            key == CloudPushSettings.allowLegacyEnrollmentInfoKey ? "YES" : nil
        }
        let legacy = store.identity(forOwner: ownerA)
        XCTAssertEqual(legacy?.provisioning, .legacyEnrollment)
        XCTAssertEqual(legacy?.sourceId, source)
        XCTAssertNil(store.identity(forOwner: ownerB), "and never for any account but the one that enrolled")
    }

    // MARK: - build configuration

    func testASecretKeyIsNeverAcceptedAsTheAppsKey() {
        XCTAssertTrue(CloudPushSettings.isForbiddenServerKey("sb_secret_abcdef0123456789"))
        XCTAssertTrue(CloudPushSettings.isForbiddenServerKey(jwt(role: "service_role")))
        XCTAssertFalse(CloudPushSettings.isForbiddenServerKey("sb_publishable_abcdef0123456789"))
        XCTAssertFalse(CloudPushSettings.isForbiddenServerKey(jwt(role: "anon")))
        XCTAssertFalse(CloudPushSettings.isForbiddenServerKey(""))

        CloudPushSettings.bundleStringOverride = { key in
            switch key {
            case CloudPushSettings.publishableKeyInfoKey: return "sb_secret_abcdef0123456789"
            case CloudPushSettings.endpointInfoKey: return "https://example.supabase.co/functions/v1/push"
            default: return nil
            }
        }
        XCTAssertEqual(CloudPushSettings.publishableKey, "")
        XCTAssertFalse(CloudPushSettings.isConfigured, "a build carrying a secret key counts as unconfigured")

        CloudPushSettings.bundleStringOverride = { key in
            switch key {
            case CloudPushSettings.publishableKeyInfoKey: return ""
            case CloudPushSettings.anonKeyInfoKey: return self.jwt(role: "service_role")
            case CloudPushSettings.endpointInfoKey: return "https://example.supabase.co/functions/v1/push"
            default: return nil
            }
        }
        XCTAssertEqual(CloudPushSettings.publishableKey, "", "the deprecated anon fallback is screened the same way")
        XCTAssertFalse(CloudPushSettings.isConfigured)
    }

    func testABuildIsConfiguredByAnEndpointAndAPublishableKeyAlone() {
        CloudPushSettings.bundleStringOverride = { key in
            switch key {
            case CloudPushSettings.publishableKeyInfoKey: return "sb_publishable_abcdef0123456789"
            case CloudPushSettings.endpointInfoKey: return "https://example.supabase.co/functions/v1/push"
            default: return nil
            }
        }
        XCTAssertTrue(CloudPushSettings.isConfigured)
        XCTAssertEqual(CloudPushSettings.fleetToken, "", "no shared fleet token is needed, or read, on the tester path")
        XCTAssertFalse(CloudPushSettings.allowLegacyEnrollment)
        XCTAssertEqual(CloudPushSettings.canonicalProjectURL, "https://example.supabase.co")
        XCTAssertEqual(CloudPushSettings.authURL?.absoluteString, "https://example.supabase.co/auth/v1")
    }

    func testTheFleetTokenIsReadOnlyByAnExplicitMigrationBuild() {
        CloudPushSettings.bundleStringOverride = { key in
            switch key {
            case CloudPushSettings.legacyFleetTokenInfoKey: return "fleet-secret"
            default: return nil
            }
        }
        XCTAssertEqual(CloudPushSettings.fleetToken, "", "a stray value in a local secrets file puts nothing on the wire")

        CloudPushSettings.bundleStringOverride = { key in
            switch key {
            case CloudPushSettings.legacyFleetTokenInfoKey: return "fleet-secret"
            case CloudPushSettings.allowLegacyEnrollmentInfoKey: return "true"
            default: return nil
            }
        }
        XCTAssertEqual(CloudPushSettings.fleetToken, "fleet-secret")
    }

    func testOnlyALegacyEnrolledInstallationEverSendsTheFleetHeader() {
        CloudPushSettings.bundleStringOverride = { key in
            switch key {
            case CloudPushSettings.legacyFleetTokenInfoKey: return "fleet-secret"
            case CloudPushSettings.allowLegacyEnrollmentInfoKey: return "true"
            default: return nil
            }
        }
        let url = URL(string: "https://example.supabase.co/functions/v1/push")!
        let modern = CloudPushIdentity(ownerId: ownerA, sourceId: UUID().uuidString, tokenId: UUID().uuidString,
                                       uploadToken: "noop_modern", provisioning: .supabaseAuth)
        var request = URLRequest(url: url)
        CloudReceiverAuth.apply(modern, to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop_modern")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-noop-fleet-token"),
                     "an Auth-provisioned installation never sends the shared token, even in a migration build")

        let legacy = CloudPushIdentity(ownerId: ownerA, sourceId: UUID().uuidString, tokenId: UUID().uuidString,
                                       uploadToken: "noop_legacy", provisioning: .legacyEnrollment)
        var legacyRequest = URLRequest(url: url)
        CloudReceiverAuth.apply(legacy, to: &legacyRequest)
        XCTAssertEqual(legacyRequest.value(forHTTPHeaderField: "x-noop-fleet-token"), "fleet-secret")

        CloudPushSettings.bundleStringOverride = nil
        var plain = URLRequest(url: url)
        CloudReceiverAuth.apply(legacy, to: &plain)
        XCTAssertNil(plain.value(forHTTPHeaderField: "x-noop-fleet-token"))
    }

    private func jwt(role: String) -> String {
        func b64(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return [b64(["alg": "HS256", "typ": "JWT"]), b64(["role": role, "iss": "supabase"]), "signature"].joined(separator: ".")
    }

    // MARK: - local history ownership

    func testTheFirstAccountClaimsOnDeviceHistoryAndNoOtherAccountMayReplayIt() {
        XCTAssertNil(CloudLocalDataBinding.owner(defaults: defaults))
        XCTAssertFalse(CloudLocalDataBinding.isOwner(ownerA, defaults: defaults))

        XCTAssertTrue(CloudLocalDataBinding.claimIfUnclaimed(by: ownerA, defaults: defaults))
        XCTAssertFalse(CloudLocalDataBinding.claimIfUnclaimed(by: ownerB, defaults: defaults),
                       "a second account cannot take over a claimed history")
        XCTAssertTrue(CloudLocalDataBinding.claimIfUnclaimed(by: ownerA.uppercased(), defaults: defaults))
        XCTAssertEqual(CloudLocalDataBinding.owner(defaults: defaults), ownerA)

        store.activate(ownerId: ownerB)
        XCTAssertFalse(CloudLocalDataBinding.signedInAccountOwnsLocalData(store: store, defaults: defaults))
        store.activate(ownerId: ownerA)
        XCTAssertTrue(CloudLocalDataBinding.signedInAccountOwnsLocalData(store: store, defaults: defaults))
        store.signOutCurrentOwner()
        XCTAssertFalse(CloudLocalDataBinding.signedInAccountOwnsLocalData(store: store, defaults: defaults),
                       "nobody signed in means nobody may replay it")
    }

    // MARK: - journal scoping

    private func journalRecord(ts: Int, bpm: Int, deviceId: String? = nil) -> CloudJournalRecord {
        let payload = try! PushProtocol.canonicalJson(.map([
            "key": .map(["ts": .int(Int64(ts))]),
            "data": .map(["bpm": .int(Int64(bpm))]),
        ])).data(using: .utf8)!
        return CloudJournalRecord(stream: .hrSample, encoding: .jsonRow, provenance: .live,
                                  characteristic: "2A37", family: "whoop4", receivedAtMs: ts * 1000,
                                  strapTs: ts, deviceId: deviceId, payload: payload)
    }

    private func configuration(_ owner: String, source: String, device: String = "my-whoop") -> CloudJournal.Configuration {
        .init(ownerId: owner, sourceId: source, deviceId: device)
    }

    private let sourceA = "a0a0a0a0-a0a0-4a0a-8a0a-a0a0a0a0a0a0"
    private let sourceB = "b0b0b0b0-b0b0-4b0b-8b0b-b0b0b0b0b0b0"

    func testAnotherAccountOnTheSameJournalFileSeesNoneOfTheFirstAccountsRecords() async throws {
        let journal = CloudJournal()
        try await journal.activate(configuration: configuration(ownerA, source: sourceA), directory: directory)
        journal.submit([journalRecord(ts: 1_700_000_000, bpm: 60), journalRecord(ts: 1_700_000_001, bpm: 61),
                        journalRecord(ts: 1_700_000_002, bpm: 62)])
        _ = await journal.flush()
        let statsA = await journal.stats()
        XCTAssertEqual(statsA.pendingRecords, 3)
        await journal.deactivate()

        try await journal.activate(configuration: configuration(ownerB, source: sourceB), directory: directory)
        let statsB = await journal.stats()
        XCTAssertEqual(statsB.pendingRecords, 0, "B starts with nothing of A's pending")
        let candidatesB = try await journal.sealCandidates(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 10_000)
        XCTAssertTrue(candidatesB.isEmpty, "A's records are not sealable by B")

        journal.submit([journalRecord(ts: 1_700_000_010, bpm: 70)])
        _ = await journal.flush()
        let sealableB = try await journal.sealCandidates(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 10_000)
        XCTAssertEqual(sealableB.count, 1)
        XCTAssertEqual(sealableB.first?.ownerId, ownerB)
        XCTAssertEqual(sealableB.first?.sourceId, sourceB)
        XCTAssertEqual(sealableB.first?.recordCount, 1)
        await journal.deactivate()

        // A comes back and finds exactly its own three, still stamped as A's.
        try await journal.activate(configuration: configuration(ownerA, source: sourceA), directory: directory)
        let statsAAgain = await journal.stats()
        XCTAssertEqual(statsAAgain.pendingRecords, 3, "A's queued records were not retagged to B, nor lost")
        let sealableA = try await journal.sealCandidates(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 10_000)
        XCTAssertEqual(sealableA.count, 1)
        XCTAssertEqual(sealableA.first?.ownerId, ownerA)
        XCTAssertEqual(sealableA.first?.sourceId, sourceA)
        XCTAssertEqual(sealableA.first?.recordCount, 3)
        await journal.deactivate()
    }

    func testARecordKeepsTheAccountThatWasSignedInWhenItArrived() async throws {
        let journal = CloudJournal()
        try await journal.activate(configuration: configuration(ownerA, source: sourceA), directory: directory)
        journal.submit([journalRecord(ts: 1_700_000_000, bpm: 60)])

        // The account switches before the record is committed: no flush in between.
        journal.beginStaging(scope: CloudDataScope(ownerId: ownerB, sourceId: sourceB), deviceId: "my-whoop")
        journal.submit([journalRecord(ts: 1_700_000_001, bpm: 70), journalRecord(ts: 1_700_000_002, bpm: 71)])
        _ = await journal.flush()
        await journal.deactivate()

        try await journal.activate(configuration: configuration(ownerA, source: sourceA), directory: directory)
        let statsA = await journal.stats()
        XCTAssertEqual(statsA.pendingRecords, 1, "the record that arrived under A stays A's")
        await journal.deactivate()

        try await journal.activate(configuration: configuration(ownerB, source: sourceB), directory: directory)
        let statsB = await journal.stats()
        XCTAssertEqual(statsB.pendingRecords, 2)
        await journal.deactivate()
    }

    func testNothingIsStampedOrCommittedWhileNobodyIsSignedIn() async throws {
        let journal = CloudJournal()
        try await journal.activate(configuration: configuration(ownerA, source: sourceA), directory: directory)
        await journal.deactivate()
        XCTAssertNil(journal.acceptingScope)

        journal.submit([journalRecord(ts: 1_700_000_000, bpm: 60)])
        journal.submit(journalRecord(ts: 1_700_000_001, bpm: 61))
        let committed = await journal.flush()
        XCTAssertEqual(committed, 0, "a record with no signed-in account is never given one")

        try await journal.activate(configuration: configuration(ownerB, source: sourceB), directory: directory)
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 0)
        await journal.deactivate()
    }

    func testAJournalWithNoActiveAccountHandsOutNothingAndRefusesWrites() async throws {
        let journal = try await journalReady(for: ownerA, source: sourceA)
        let candidates = try await journal.sealCandidates(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 10_000)
        let candidate = try XCTUnwrap(candidates.first)
        await journal.deactivate()

        let none = try await journal.sealCandidates(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 10_000)
        XCTAssertTrue(none.isEmpty, "with nobody signed in there is nothing to seal")
        let batches = try await journal.batches(states: [.sealed, .failed, .reserved, .blocked], dueBeforeMs: nil, limit: 10)
        XCTAssertTrue(batches.isEmpty)
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 0, "pending counts are per account, and there is none")
        let cursor = await journal.appendCursorJSON(deviceId: "my-whoop", stream: .hrSample)
        XCTAssertNil(cursor)

        do {
            try await journal.saveAppendCursor(deviceId: "my-whoop", stream: .hrSample, endCursorJSON: "{\"ts\":1}")
            XCTFail("a cursor can not be written for nobody")
        } catch {}
        do {
            try await journal.registerSeal(candidate, batchId: "batch-1", filePath: "/dev/null", contentSha256: "00",
                                           contentLength: 0)
            XCTFail("a seal can not be registered for nobody")
        } catch {}
    }

    func testAJournalRefusesToSealAnotherAccountsCandidate() async throws {
        let journal = try await journalReady(for: ownerA, source: sourceA)
        let candidates = try await journal.sealCandidates(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 10_000)
        let candidate = try XCTUnwrap(candidates.first)
        await journal.deactivate()

        try await journal.activate(configuration: configuration(ownerB, source: sourceB), directory: directory)
        let stolen = try await journal.entries(for: candidate)
        XCTAssertTrue(stolen.isEmpty, "B can not read the records A's candidate names")
        do {
            try await journal.registerSeal(candidate, batchId: "batch-a", filePath: "/dev/null", contentSha256: "00",
                                           contentLength: 0)
            XCTFail("B can not seal A's records")
        } catch {}
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 0)
        await journal.deactivate()

        try await journal.activate(configuration: configuration(ownerA, source: sourceA), directory: directory)
        let statsA = await journal.stats()
        XCTAssertEqual(statsA.pendingRecords, 2, "and A's records are still exactly where they were")
        await journal.deactivate()
    }

    func testAppendCursorsBelongToTheAccountThatEarnedThem() async throws {
        let journal = CloudJournal()
        try await journal.activate(configuration: configuration(ownerA, source: sourceA), directory: directory)
        try await journal.saveAppendCursor(deviceId: "my-whoop", stream: .hrSample, endCursorJSON: "{\"ts\":100}")
        let a = await journal.appendCursorJSON(deviceId: "my-whoop", stream: .hrSample)
        XCTAssertEqual(a, "{\"ts\":100}")
        await journal.deactivate()

        try await journal.activate(configuration: configuration(ownerB, source: sourceB), directory: directory)
        let b = await journal.appendCursorJSON(deviceId: "my-whoop", stream: .hrSample)
        XCTAssertNil(b, "B does not resume from A's cursor: that would skip data B never uploaded")
        await journal.deactivate()

        try await journal.activate(configuration: configuration(ownerA, source: sourceA), directory: directory)
        let aAgain = await journal.appendCursorJSON(deviceId: "my-whoop", stream: .hrSample)
        XCTAssertEqual(aAgain, "{\"ts\":100}")
        await journal.deactivate()
    }

    func testTheSameAccountOnANewSourceStartsFromNothingRatherThanReusingTheOldSourcesCursor() async throws {
        let journal = CloudJournal()
        try await journal.activate(configuration: configuration(ownerA, source: sourceA), directory: directory)
        try await journal.saveAppendCursor(deviceId: "my-whoop", stream: .hrSample, endCursorJSON: "{\"ts\":100}")
        await journal.deactivate()

        let rotated = "c0c0c0c0-c0c0-4c0c-8c0c-c0c0c0c0c0c0"
        try await journal.activate(configuration: configuration(ownerA, source: rotated), directory: directory)
        let cursor = await journal.appendCursorJSON(deviceId: "my-whoop", stream: .hrSample)
        XCTAssertNil(cursor, "a cursor is only valid for the source that earned it")
        await journal.deactivate()
    }

    // MARK: - coordinator

    private final class StubUploader: CloudUploading, @unchecked Sendable {
        struct Upload: Equatable {
            let batchId: String
            let scope: CloudDataScope?
        }

        private let lock = NSLock()
        private var _uploads: [Upload] = []
        private var _capabilityScopes: [CloudDataScope?] = []
        var onOutcome: (@Sendable (CloudUploadSession.Outcome) -> Void)?
        var capabilitiesUserId: String?
        var capabilitiesSourceId: String?
        var status = 401
        /// The body of the receiver's reply to a batch, by batch id. Nil sends none.
        var reply: (@Sendable (String) -> Data?)?

        var uploads: [Upload] { lock.lock(); defer { lock.unlock() }; return _uploads }
        var capabilityScopes: [CloudDataScope?] { lock.lock(); defer { lock.unlock() }; return _capabilityScopes }

        func capabilities(scope: CloudDataScope?) async throws -> PushCapabilities {
            record(capabilityScope: scope)
            return PushCapabilities(appendTables: PushCapabilities.all.appendTables,
                                    mutableTables: PushCapabilities.all.mutableTables, protocolVersion: "1.2",
                                    userId: capabilitiesUserId, sourceId: capabilitiesSourceId)
        }

        func uploadForeground(batchId: String, fileURL: URL, scope: CloudDataScope?) async throws -> CloudUploadSession.Outcome {
            record(upload: Upload(batchId: batchId, scope: scope))
            return CloudUploadSession.Outcome(batchId: batchId, statusCode: status, body: reply?(batchId),
                                              errorDescription: nil)
        }

        func enqueueBackground(batchId: String, fileURL: URL, scope: CloudDataScope?) throws -> Int { 1 }

        func outstandingTasks() async -> [(taskIdentifier: Int, batchId: String?)] { [] }

        private func record(capabilityScope: CloudDataScope?) {
            lock.lock(); _capabilityScopes.append(capabilityScope); lock.unlock()
        }

        private func record(upload: Upload) {
            lock.lock(); _uploads.append(upload); lock.unlock()
        }
    }

    private final class RejectionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _statuses: [Int] = []
        func record(_ status: Int) { lock.lock(); _statuses.append(status); lock.unlock() }
        var statuses: [Int] { lock.lock(); defer { lock.unlock() }; return _statuses }
    }

    /// A journal holding two ready batches' worth of records for `owner`, activated for them.
    private func journalReady(for owner: String, source: String, device: String = "my-whoop") async throws -> CloudJournal {
        var policy = CloudJournal.SealPolicy()
        policy.maxRecords = 2
        let journal = CloudJournal()
        try await journal.activate(configuration: configuration(owner, source: source, device: device),
                                   policy: policy, directory: directory)
        journal.submit([journalRecord(ts: 1_700_000_000, bpm: 60), journalRecord(ts: 1_700_000_001, bpm: 61)])
        _ = await journal.flush()
        return journal
    }

    private func eventually(_ condition: @escaping () async -> Bool, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    private func makeCoordinator(journal: CloudJournal, uploader: StubUploader, scope: CloudDataScope,
                                 identity: CloudPushIdentity?) -> CloudTransportCoordinator {
        CloudTransportCoordinator(journal: journal, session: uploader, scope: scope,
                                  payloadDirectory: directory.appendingPathComponent("payloads-\(scope.ownerId.prefix(4))"),
                                  projectURL: "https://example.supabase.co", identity: { identity },
                                  cloudEnabled: { true })
    }

    func testACoordinatorOnlyEverSendsItsOwnAccountsBatchesWithItsOwnScope() async throws {
        let owner = UUID().uuidString.lowercased()
        let journal = try await journalReady(for: owner, source: sourceA)
        let uploader = StubUploader()
        uploader.capabilitiesUserId = owner
        uploader.capabilitiesSourceId = sourceA
        let identity = CloudPushIdentity(ownerId: owner, sourceId: sourceA, tokenId: UUID().uuidString,
                                         uploadToken: "noop_a")
        let coordinator = makeCoordinator(journal: journal, uploader: uploader, scope: identity.scope, identity: identity)
        defer { UserDefaults.standard.removeObject(forKey: "noop.cloud.protocolVersion.\(owner)") }

        await coordinator.start()
        let sent = await eventually { !uploader.uploads.isEmpty }
        await coordinator.stop()
        await journal.deactivate()

        XCTAssertTrue(sent, "a ready batch is uploaded")
        XCTAssertTrue(uploader.uploads.allSatisfy { $0.scope == identity.scope },
                      "every upload names the one account it was sealed for")
        XCTAssertEqual(uploader.capabilityScopes.compactMap { $0 }, [identity.scope])
    }

    func testACredentialRejectionKeepsTheBatchAndAsksTheAccountLayerOnce() async throws {
        let owner = UUID().uuidString.lowercased()
        let journal = try await journalReady(for: owner, source: sourceA)
        let uploader = StubUploader()
        uploader.capabilitiesUserId = owner
        uploader.capabilitiesSourceId = sourceA
        uploader.status = 401
        let identity = CloudPushIdentity(ownerId: owner, sourceId: sourceA, tokenId: UUID().uuidString,
                                         uploadToken: "noop_revoked")
        let coordinator = makeCoordinator(journal: journal, uploader: uploader, scope: identity.scope, identity: identity)
        let rejections = RejectionLog()
        await coordinator.setOnCredentialRejected { rejections.record($0) }
        defer { UserDefaults.standard.removeObject(forKey: "noop.cloud.protocolVersion.\(owner)") }

        await coordinator.start()
        let rejected = await eventually { !rejections.statuses.isEmpty }
        await coordinator.stop()

        XCTAssertTrue(rejected)
        XCTAssertEqual(rejections.statuses, [401])
        let failed = try await journal.batches(states: [.failed], dueBeforeMs: nil, limit: 10)
        XCTAssertEqual(failed.count, 1, "the batch is kept for the next attempt")
        XCTAssertEqual(failed.first?.attempts, 0, "a refused credential says nothing about the batch")
        let blocked = try await journal.batches(states: [.blocked], dueBeforeMs: nil, limit: 10)
        XCTAssertTrue(blocked.isEmpty, "a revoked credential never strands the data behind it")
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 2, "nothing was released")
        await journal.deactivate()
    }

    /// A 200 whose acknowledgement is not "accepted" used to leave the batch in `uploaded`, a state the send
    /// pass never looks at, with its records held back for good. It goes back to be sent again instead.
    func testAnAcknowledgementThatIsNotAcceptedLeavesTheBatchToBeSentAgainRatherThanStranded() async throws {
        let owner = UUID().uuidString.lowercased()
        let journal = try await journalReady(for: owner, source: sourceA)
        let uploader = StubUploader()
        uploader.capabilitiesUserId = owner
        uploader.capabilitiesSourceId = sourceA
        uploader.status = 200
        uploader.reply = { batchId in
            Data("""
            {"protocolVersion":"1.2","batchId":"\(batchId)","stream":"hrSample","deviceId":"my-whoop",\
            "endCursor":null,"acceptedRows":0,"status":"rejected"}
            """.utf8)
        }
        let identity = CloudPushIdentity(ownerId: owner, sourceId: sourceA, tokenId: UUID().uuidString,
                                         uploadToken: "noop_a")
        let coordinator = makeCoordinator(journal: journal, uploader: uploader, scope: identity.scope, identity: identity)
        defer { UserDefaults.standard.removeObject(forKey: "noop.cloud.protocolVersion.\(owner)") }

        await coordinator.start()
        let requeued = await eventually {
            ((try? await journal.batches(states: [.failed], dueBeforeMs: nil, limit: 10)) ?? []).count == 1
        }
        await coordinator.stop()

        XCTAssertTrue(requeued, "the batch is queued for another attempt")
        let stranded = try await journal.batches(states: [.uploaded], dueBeforeMs: nil, limit: 10)
        XCTAssertTrue(stranded.isEmpty, "nothing is left in a state that is never sent again")
        let stats = await journal.stats()
        XCTAssertEqual(stats.uploadedBatches, 0)
        XCTAssertEqual(stats.pendingRecords, 2, "the records were never released")
        await journal.deactivate()
    }

    func testACoordinatorRefusesACredentialThatBelongsToAnotherAccount() async throws {
        let owner = UUID().uuidString.lowercased()
        let stranger = UUID().uuidString.lowercased()
        let journal = try await journalReady(for: owner, source: sourceA)
        let uploader = StubUploader()
        let wrong = CloudPushIdentity(ownerId: stranger, sourceId: sourceB, tokenId: UUID().uuidString,
                                      uploadToken: "noop_strangers")
        let coordinator = makeCoordinator(journal: journal, uploader: uploader,
                                          scope: CloudDataScope(ownerId: owner, sourceId: sourceA), identity: wrong)
        defer { UserDefaults.standard.removeObject(forKey: "noop.cloud.protocolVersion.\(owner)") }

        await coordinator.start()
        await coordinator.cycle()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await coordinator.stop()

        XCTAssertTrue(uploader.uploads.isEmpty, "nothing is sent with someone else's credential")
        XCTAssertTrue(uploader.capabilityScopes.isEmpty)
        let sealed = try await journal.batches(states: [.sealed, .failed, .reserved], dueBeforeMs: nil, limit: 10)
        XCTAssertTrue(sealed.isEmpty, "nor is anything sealed for it")
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 2)
        await journal.deactivate()
    }

    func testACoordinatorWithNoCredentialIdlesInsteadOfSending() async throws {
        let owner = UUID().uuidString.lowercased()
        let journal = try await journalReady(for: owner, source: sourceA)
        let uploader = StubUploader()
        let coordinator = makeCoordinator(journal: journal, uploader: uploader,
                                          scope: CloudDataScope(ownerId: owner, sourceId: sourceA), identity: nil)

        await coordinator.start()
        await coordinator.cycle()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await coordinator.stop()

        XCTAssertTrue(uploader.uploads.isEmpty)
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 2, "a signed-out phone keeps what it captured")
        await journal.deactivate()
    }

    func testAReceiverThatAnswersForAnotherAccountStopsTheCoordinatorBeforeAnythingIsSealed() async throws {
        let owner = UUID().uuidString.lowercased()
        let journal = try await journalReady(for: owner, source: sourceA)
        let uploader = StubUploader()
        uploader.capabilitiesUserId = UUID().uuidString.lowercased()
        uploader.capabilitiesSourceId = sourceA
        let identity = CloudPushIdentity(ownerId: owner, sourceId: sourceA, tokenId: UUID().uuidString,
                                         uploadToken: "noop_a")
        let coordinator = makeCoordinator(journal: journal, uploader: uploader, scope: identity.scope, identity: identity)
        defer { UserDefaults.standard.removeObject(forKey: "noop.cloud.protocolVersion.\(owner)") }

        await coordinator.start()
        let asked = await eventually { !uploader.capabilityScopes.isEmpty }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await coordinator.stop()

        XCTAssertTrue(asked)
        XCTAssertTrue(uploader.uploads.isEmpty, "a mismatched receiver gets no data")
        let sealed = try await journal.batches(states: [.sealed, .failed, .reserved], dueBeforeMs: nil, limit: 10)
        XCTAssertTrue(sealed.isEmpty)
        await journal.deactivate()
    }

    // MARK: - background / locked

    func testTheRuntimesCredentialLookupNeedsNoAuthSessionAndIsBoundToExactlyItsOwnScope() throws {
        let sourceA = store.sourceId(forOwner: ownerA)
        let sourceB = store.sourceId(forOwner: ownerB)
        store.store(token: "noop_token_a", tokenId: UUID().uuidString, expiresAt: nil, ownerId: ownerA, sourceId: sourceA)
        store.store(token: "noop_token_b", tokenId: UUID().uuidString, expiresAt: nil, ownerId: ownerB, sourceId: sourceB)
        let scopeA = CloudDataScope(ownerId: ownerA, sourceId: sourceA)
        let scopeB = CloudDataScope(ownerId: ownerB, sourceId: sourceB)
        let providerA = CloudPushRuntime.credentialProvider(for: scopeA, store: store)
        let providerB = CloudPushRuntime.credentialProvider(for: scopeB, store: store)
        let strayScope = CloudDataScope(ownerId: ownerA, sourceId: sourceB)
        let providerStray = CloudPushRuntime.credentialProvider(for: strayScope, store: store)

        // Locked phone, relaunched by a Bluetooth event, no Auth session anywhere: the credential is simply
        // read from the Keychain-backed store, and each runtime only ever gets the one bound to its scope.
        XCTAssertEqual(providerA()?.uploadToken, "noop_token_a")
        XCTAssertEqual(providerB()?.uploadToken, "noop_token_b")
        XCTAssertEqual(providerA()?.scope, scopeA)
        XCTAssertNil(providerStray(), "A's account paired with B's source resolves to nothing at all")

        store.removeCredential(forOwner: ownerA)
        XCTAssertNil(providerA(), "once A's credential is gone, A's runtime has nothing to send with")
        XCTAssertEqual(providerB()?.uploadToken, "noop_token_b", "and B's is untouched")

        // A new source for A: a runtime still aimed at the old source can not use the new source's credential.
        let rotated = store.rotateSourceId(forOwner: ownerA)
        store.store(token: "noop_token_a2", tokenId: UUID().uuidString, expiresAt: nil, ownerId: ownerA, sourceId: rotated)
        XCTAssertNil(providerA(), "the old scope never resolves to the new source's credential")
        XCTAssertEqual(CloudPushRuntime.credentialProvider(for: CloudDataScope(ownerId: ownerA, sourceId: rotated),
                                                         store: store)()?.uploadToken, "noop_token_a2")
    }
}
