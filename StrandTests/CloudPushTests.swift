import XCTest
import SQLite3
import NoopPush
import WhoopProtocol
import WhoopStore
@testable import Strand


/// A URLProtocol stub so the repository's real request → parse → cache path runs with no network.
final class ScoreStub: URLProtocol {
    static var response: [String: Any] = [:]
    static var status: Int = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = (try? JSONSerialization.data(withJSONObject: ScoreStub.response)) ?? Data()
        let http = HTTPURLResponse(url: request.url!, statusCode: ScoreStub.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension ScoreStub {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScoreStub.self]
        return URLSession(configuration: config)
    }
}


/// Cloud capture/transport tests.
///
/// These cover the properties the cloud path is required to hold — not the HTTP round trip, which the
/// NoopPush package already tests against golden fixtures. What is tested here is the part the fork
/// owns: durable ordered capture, the sealing boundary, the receipt rule, and the failure policy.
///
/// Every test uses its own temporary directory, so nothing here touches the app's real store or the
/// real App Support container.
final class CloudPushTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-cloud-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - helpers

    private func makeJournal(ownerId: String = "11111111-1111-4111-8111-111111111111",
                             sourceId: String = "22222222-2222-4222-8222-222222222222",
                             deviceId: String = "my-whoop",
                             policy: CloudJournal.SealPolicy = CloudJournal.SealPolicy()) async throws -> CloudJournal {
        let journal = CloudJournal()
        try await journal.activate(configuration: .init(ownerId: ownerId, sourceId: sourceId, deviceId: deviceId),
                                   policy: policy, directory: directory)
        return journal
    }

    private func hrRecord(ts: Int, bpm: Int, deviceId: String? = nil) -> CloudJournalRecord {
        let payload = try! PushProtocol.canonicalJson(.map([
            "key": .map(["ts": .int(Int64(ts))]),
            "data": .map(["bpm": .int(Int64(bpm))]),
        ])).data(using: .utf8)!
        return CloudJournalRecord(stream: .hrSample, encoding: .jsonRow, provenance: .live,
                                  characteristic: "2A37", family: "whoop4", receivedAtMs: ts * 1000,
                                  strapTs: ts, deviceId: deviceId, payload: payload)
    }

    private func candidate(for stream: CloudStreamKind, deviceId: String = "my-whoop",
                           first: Int64, last: Int64, count: Int) -> CloudSealCandidate {
        CloudSealCandidate(ownerId: "11111111-1111-4111-8111-111111111111",
                           sourceId: "22222222-2222-4222-8222-222222222222",
                           deviceId: deviceId, stream: stream, firstSeq: first, lastSeq: last,
                           recordCount: count, oldestReceivedAtMs: 0, byteSize: 0, windowIdentity: nil)
    }

    // MARK: - durable ordered capture

    func testCommittedRecordsBecomePendingAndTransportEligibleTogether() async throws {
        let journal = try await makeJournal()
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 61),
                        hrRecord(ts: 1_700_000_001, bpm: 62)])
        let committed = await journal.flush()
        XCTAssertEqual(committed, 2)

        // `state = 0` IS transport eligibility, so "pending" and "eligible" are the same committed row.
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 2)
        let received = await journal.recordsReceived()
        XCTAssertEqual(received, 2)
    }

    func testReceiveSequenceContinuesAcrossReopen() async throws {
        let first = try await makeJournal()
        first.submit([hrRecord(ts: 10, bpm: 60)])
        _ = await first.flush()
        let firstCount = await first.recordsReceived()
        XCTAssertEqual(firstCount, 1)

        // A relaunch must continue the dense sequence, not restart it: a receiver detects a capture gap
        // from the sequence, so restarting it would hide one.
        let second = try await makeJournal()
        second.submit([hrRecord(ts: 11, bpm: 61)])
        _ = await second.flush()
        let secondCount = await second.recordsReceived()
        XCTAssertEqual(secondCount, 2)
    }

    func testUnacknowledgedRecordsAreNeverPruned() async throws {
        let journal = try await makeJournal()
        journal.submit([hrRecord(ts: 20, bpm: 60), hrRecord(ts: 21, bpm: 61)])
        _ = await journal.flush()

        // Retention runs with an aggressive window; unacknowledged work must survive it regardless.
        let pruned = try await journal.pruneAcknowledged(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 8 * 86_400_000)
        XCTAssertEqual(pruned.records, 0)
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 2)
    }

    func testStagingOverflowIsCountedAndHoldsTheHistoryCursor() async throws {
        let journal = try await makeJournal()
        // A bounded buffer must not silently drop: overflow is counted and holds the cursor so the
        // receiver sees a gap instead of a lie.
        let many = (0..<12_000).map { hrRecord(ts: 1_000 + $0, bpm: 60) }
        journal.submit(many)
        _ = await journal.flush()

        let stats = await journal.stats()
        XCTAssertGreaterThan(stats.overflowRecords, 0)
        XCTAssertTrue(stats.historyCursorHeld)
        let mayAdvance = await journal.historyCursorMayAdvance()
        XCTAssertFalse(mayAdvance)

        try await journal.clearHistoryHold()
        let mayAdvanceAfterClear = await journal.historyCursorMayAdvance()
        XCTAssertTrue(mayAdvanceAfterClear)
    }

    // MARK: - sealing boundary

    func testSealCandidateAppearsOnlyWhenTheGroupIsOldEnoughOrLargeEnough() async throws {
        var policy = CloudJournal.SealPolicy()
        policy.activeTargetSeconds = 2
        policy.maxRecords = 1_000
        let journal = try await makeJournal(policy: policy)
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 60)])
        _ = await journal.flush()

        // Fresh: not yet sealable (the ~2 s active-use target has not elapsed).
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let fresh = try await journal.sealCandidates(nowMs: now)
        XCTAssertTrue(fresh.isEmpty)

        // Same group, evaluated 3 s later: sealable on AGE alone.
        let candidates = try await journal.sealCandidates(nowMs: now + 3_000)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.stream, .hrSample)
        XCTAssertEqual(candidates.first?.recordCount, 1)
    }

    func testSealRegistersMembershipAndJobInOneTransaction() async throws {
        let journal = try await makeJournal()
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 60), hrRecord(ts: 1_700_000_001, bpm: 61)])
        _ = await journal.flush()
        let candidate = try await journal.sealCandidates(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 5_000)[0]
        let entries = try await journal.entries(for: candidate)
        let plan = try CloudBatchBuilder.plan(entries: entries, stream: .hrSample,
                                             sourceId: candidate.sourceId, deviceId: candidate.deviceId,
                                             protocolVersion: "1.1", startCursorJSON: nil)
        let file = directory.appendingPathComponent("\(plan.batch.batchId).ndjson.gz")
        try Data("sealed".utf8).write(to: file)
        try await journal.registerSeal(candidate, batchId: plan.batch.batchId, filePath: file.path,
                                       contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                       contentLength: 6, protocolVersion: "1.1", endCursorJSON: nil)

        let sealed = try await journal.batches(states: [.sealed], dueBeforeMs: nil, limit: 10)
        XCTAssertEqual(sealed.count, 1)
        XCTAssertEqual(sealed.first?.recordCount, 2)
        XCTAssertEqual(sealed.first?.firstSeq, candidate.firstSeq)
        // The membership moved out of the pending group in the same transaction as the job row.
        let remaining = try await journal.sealCandidates(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 5_000)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - receipts

    func testReceiptWithTheWrongChecksumReleasesNothing() async throws {
        let journal = try await makeJournal()
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 60)])
        _ = await journal.flush()
        let candidate = try await journal.sealCandidates(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 5_000)[0]
        let entries = try await journal.entries(for: candidate)
        let plan = try CloudBatchBuilder.plan(entries: entries, stream: .hrSample,
                                             sourceId: candidate.sourceId, deviceId: candidate.deviceId,
                                             protocolVersion: "1.1", startCursorJSON: nil)
        let file = directory.appendingPathComponent("\(plan.batch.batchId).ndjson.gz")
        try Data("sealed".utf8).write(to: file)
        try await journal.registerSeal(candidate, batchId: plan.batch.batchId, filePath: file.path,
                                       contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                       contentLength: 6, protocolVersion: "1.1", endCursorJSON: nil)

        let outcome = try await journal.applyReceipt(batchId: plan.batch.batchId,
                                                    contentSha256: String(repeating: "a", count: 64),
                                                    receiptJSON: "{}")
        guard case .checksumMismatch = outcome else {
            return XCTFail("a receipt that does not match the sealed bytes must not be accepted: \(outcome)")
        }
        // The records stay pending: upload success alone is never deletion authority.
        let afterBadReceipt = await journal.stats()
        XCTAssertEqual(afterBadReceipt.pendingRecords, 1)
        let stateAfterBadReceipt = try await journal.batchState(plan.batch.batchId)
        XCTAssertEqual(stateAfterBadReceipt, .sealed)
    }

    func testAcknowledgingOneBatchLeavesEarlierHolesIntact() async throws {
        let journal = try await makeJournal()
        // Two separate sealable groups (different devices), so they are independent batches.
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 60, deviceId: "my-whoop")])
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 61, deviceId: "whoop-second")])
        _ = await journal.flush()

        let now = Int(Date().timeIntervalSince1970 * 1000) + 5_000
        var sealedIds: [String] = []
        for candidate in try await journal.sealCandidates(nowMs: now) {
            let entries = try await journal.entries(for: candidate)
            let plan = try CloudBatchBuilder.plan(entries: entries, stream: .hrSample,
                                                 sourceId: candidate.sourceId, deviceId: candidate.deviceId,
                                                 protocolVersion: "1.1", startCursorJSON: nil)
            let file = directory.appendingPathComponent("\(plan.batch.batchId).ndjson.gz")
            try Data("sealed".utf8).write(to: file)
            try await journal.registerSeal(candidate, batchId: plan.batch.batchId, filePath: file.path,
                                           contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                           contentLength: 6, protocolVersion: "1.1", endCursorJSON: nil)
            sealedIds.append(plan.batch.batchId)
        }
        XCTAssertEqual(sealedIds.count, 2)

        // Acknowledge the SECOND batch only. The earlier batch must keep its records and its file.
        let second = try await journal.batches(states: [.sealed], dueBeforeMs: nil, limit: 10)
            .first { $0.batchId == sealedIds[1] }!
        let outcome = try await journal.applyReceipt(batchId: second.batchId,
                                                    contentSha256: second.contentSha256, receiptJSON: "{}")
        guard case .acknowledged = outcome else { return XCTFail("expected acknowledgement: \(outcome)") }
        let firstState = try await journal.batchState(sealedIds[0])
        XCTAssertEqual(firstState, .sealed)
        let pendingAfterSecondAck = await journal.stats()
        XCTAssertEqual(pendingAfterSecondAck.pendingRecords, 1)

        // A replayed acknowledgement of the same batch is harmless.
        let replay = try await journal.applyReceipt(batchId: second.batchId,
                                                   contentSha256: second.contentSha256, receiptJSON: "{}")
        XCTAssertEqual(replay, .duplicate)

        // Only the acknowledged batch is prunable.
        // Age past the acknowledgement-retention window (7 days), or nothing is prunable at all.
        let pruned = try await journal.pruneAcknowledged(nowMs: Int(Date().timeIntervalSince1970 * 1000) + 8 * 86_400_000)
        XCTAssertEqual(pruned.records, 1)
        let pendingAfterPrune = await journal.stats()
        XCTAssertEqual(pendingAfterPrune.pendingRecords, 1)
    }

    // MARK: - server score cache

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ScoreStub.self)
    }

    func testScoreCacheRoundTripsAndRefusesAnotherOwnersEntry() async throws {
        let owner = "11111111-1111-4111-8111-111111111111"
        let other = "33333333-3333-4333-8333-333333333333"
        let repo = ServerScoreRepository(session: ScoreStub.session(),
                                         endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
                                         directory: directory,
                                         identity: { CloudPushIdentity(ownerId: owner, sourceId: "22222222-2222-4222-8222-222222222222",
                                                                       tokenId: "t", uploadToken: "noop_x") })
        // A populated day: the server reports computed values.
        let body: [String: Any] = ["server_scoring": [
            "schema_version": 2, "day": "2026-09-01", "algorithm_version": "per_feature",
            "computed_at": "2026-09-01T06:00:00.000Z", "stale": false,
            "daily": ["result_revision": "sha256:abc", "timezone_id": "Europe/London"],
            "features": ["hrv": ["status": "available", "input_revision": "r1"]],
        ]]
        let snapshot = ServerScoreRepository.snapshot(day: "2026-09-01", deviceId: "my-whoop",
                                                     envelope: body, fetchedAtMs: 0)
        XCTAssertEqual(snapshot.status, .populated)
        XCTAssertEqual(snapshot.resultRevision, "sha256:abc")

        // Exercise the REAL path — request, parse, cache — through a stubbed transport, so this covers
        // the same code `refresh` uses rather than a test-only shortcut.
        ScoreStub.response = body
        ScoreStub.status = 200
        let fetched = try await repo.refresh(day: "2026-09-01", deviceId: "my-whoop")
        XCTAssertEqual(fetched.status, .populated)
        let readBack = await repo.cachedDay(day: "2026-09-01", deviceId: "my-whoop")
        XCTAssertEqual(readBack?.resultRevision, "sha256:abc")
        XCTAssertEqual(readBack?.status, .populated)

        // A different owner must NOT see it, and the entry must survive for the original owner.
        let otherRepo = ServerScoreRepository(session: ScoreStub.session(),
                                              endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
                                              directory: directory,
                                              identity: { CloudPushIdentity(ownerId: other, sourceId: "44444444-4444-4444-8444-444444444444",
                                                                            tokenId: "t", uploadToken: "noop_y") })
        let foreign = await otherRepo.cachedDay(day: "2026-09-01", deviceId: "my-whoop")
        XCTAssertNil(foreign, "another owner's cached result must never be returned")
        let stillThere = await repo.cachedDay(day: "2026-09-01", deviceId: "my-whoop")
        XCTAssertEqual(stillThere?.resultRevision, "sha256:abc", "the original owner's cache must survive")
    }

    func testScoreStatusDistinguishesNoResultFromAZero() {
        // A pending contract (daily == null) is `noData`, never a zeroed score.
        let pending: [String: Any] = ["server_scoring": [
            "schema_version": 2, "day": "2026-09-02", "daily": NSNull(), "computed_at": NSNull(),
            "stale": true, "features": ["sleep": ["status": "unavailable", "reason": "device_registration_pending"]],
        ]]
        let snapshot = ServerScoreRepository.snapshot(day: "2026-09-02", deviceId: "d",
                                                     envelope: pending, fetchedAtMs: 0)
        XCTAssertEqual(snapshot.status, .noData)
        // And a response with no server_scoring member at all is `unavailable`.
        let missing = ServerScoreRepository.snapshot(day: "2026-09-02", deviceId: "d",
                                                    envelope: [:], fetchedAtMs: 0)
        XCTAssertEqual(missing.status, .unavailable)
    }

    func testFreshnessNeverClaimsAFutureOrAbsentBoundary() async {
        let repo = ServerScoreRepository(endpoint: nil, directory: directory,
                                         identity: { nil })
        let label = await repo.freshnessLabel(for: nil)
        XCTAssertEqual(label, "No server result yet")
        // A future computed_at must not render as "just now"/an age at all.
        XCTAssertNil(ServerScoreRepository.relativeAge(from: "2099-01-01T00:00:00.000Z",
                                                       nowMs: Int(Date().timeIntervalSince1970 * 1000)))
    }

    // MARK: - wire mapping

    func testRowEncodingMatchesTheReceiverRegistryColumns() throws {
        let record = hrRecord(ts: 1_700_000_000, bpm: 58)
        let entry = CloudJournalEntry(seq: 1, record: record, ownerId: "o", deviceId: "d", sourceId: "s")
        let row = try CloudBatchBuilder.decodeRow(entry)
        XCTAssertEqual(row.rowId, 1)
        XCTAssertEqual(row.key["ts"], .int(1_700_000_000))
        XCTAssertEqual(row.data["bpm"], .int(58))
        // The package validates key/data against the registry, so a wrong column set throws here.
        XCTAssertNoThrow(try PushProtocol.appendBatch(table: .hrSample,
                                                      sourceId: "22222222-2222-4222-8222-222222222222",
                                                      deviceId: "my-whoop", startCursor: nil,
                                                      records: [row], protocolVersion: "1.1"))
    }

    func testReplaceWindowStreamsAreRefusedOnTheAppendPath() throws {
        XCTAssertNil(CloudBatchBuilder.appendTable(for: .dailyMetric))
        XCTAssertNil(CloudBatchBuilder.appendTable(for: .journal))
        XCTAssertThrowsError(try CloudBatchBuilder.plan(entries: [], stream: .dailyMetric,
                                                        sourceId: "22222222-2222-4222-8222-222222222222",
                                                        deviceId: "d", protocolVersion: "1.1",
                                                        startCursorJSON: nil))
    }

    func testReplaceWindowRowsOnTheExclusiveEndAreRefused() {
        // [start, end) — the receiver's rule (`noop_projection_coordinate`). A row on the exclusive end
        // belongs to the NEXT window; the live fleet shipped such rows and had them rejected, so the
        // rule is pinned here before any window-authoring code exists on this side.
        let day = Int64(1_789_228_800)
        let nextDay = Int64(1_789_430_400)
        XCTAssertTrue(CloudBatchBuilder.windowAdmits(coordinate: day, start: day, endExclusive: nextDay))
        XCTAssertTrue(CloudBatchBuilder.windowAdmits(coordinate: nextDay - 1, start: day, endExclusive: nextDay))
        XCTAssertFalse(CloudBatchBuilder.windowAdmits(coordinate: nextDay, start: day, endExclusive: nextDay),
                       "a row exactly on the window's exclusive end must be refused pre-upload")
        XCTAssertFalse(CloudBatchBuilder.windowAdmits(coordinate: day - 1, start: day, endExclusive: nextDay))

        // And the strongest form: no replace-window stream can be sealed as an append batch at all, so
        // the phone cannot emit a boundary row on the live path today.
        XCTAssertNil(CloudBatchBuilder.appendTable(for: .dailyMetric))
        XCTAssertThrowsError(try CloudBatchBuilder.plan(entries: [], stream: .dailyMetric,
                                                        sourceId: "22222222-2222-4222-8222-222222222222",
                                                        deviceId: "d", protocolVersion: "1.1",
                                                        startCursorJSON: nil))
    }

    func testJSONBridgingKeepsIntegersAndBooleansDistinct() {
        // JSONSerialization bridges both to NSNumber, so a naive cast would turn 1 into `true`.
        XCTAssertEqual(CloudBatchBuilder.jsonValue(NSNumber(value: 1)), .int(1))
        XCTAssertEqual(CloudBatchBuilder.jsonValue(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(CloudBatchBuilder.jsonValue("x"), .string("x"))
        XCTAssertEqual(CloudBatchBuilder.jsonValue(NSNull()), .null)
    }

    // MARK: - failure policy

    func testRetryClassification() {
        XCTAssertTrue(CloudTransportCoordinator.isRetryable(error: "HTTP 503"))
        XCTAssertTrue(CloudTransportCoordinator.isRetryable(error: "HTTP 429"))
        XCTAssertTrue(CloudTransportCoordinator.isRetryable(error: "transport failure: offline"))
        XCTAssertFalse(CloudTransportCoordinator.isRetryable(error: "HTTP 422"))
        XCTAssertFalse(CloudTransportCoordinator.isRetryable(error: "HTTP 400"))
    }

    func testBackoffIsBoundedAndJittered() {
        // Full jitter: the result is inside [0.5, cap] and never grows without bound.
        for attempt in 0...20 {
            let low = CloudTransportCoordinator.backoffSeconds(attempt: attempt, base: 5, cap: 3600, jitter: 0)
            let high = CloudTransportCoordinator.backoffSeconds(attempt: attempt, base: 5, cap: 3600, jitter: 1)
            XCTAssertGreaterThanOrEqual(low, 0.5)
            XCTAssertLessThanOrEqual(high, 3600)
            XCTAssertLessThanOrEqual(low, high)
        }
    }

    // MARK: - upload lanes

    func testAnInactiveSceneStaysOnTheInProcessLane() {
        // BLE keeps the process running with the screen locked. The OS background session defers a
        // transfer created off screen for hours, so the scene phase must not move uploads onto it.
        var policy = CloudTransportCoordinator.Policy()
        XCTAssertEqual(CloudTransportCoordinator.lane(sceneIsActive: true, policy: policy), .process)
        XCTAssertEqual(CloudTransportCoordinator.lane(sceneIsActive: false, policy: policy), .process)
        policy.useBackgroundLaneWhenInactive = true
        XCTAssertEqual(CloudTransportCoordinator.lane(sceneIsActive: true, policy: policy), .process)
        XCTAssertEqual(CloudTransportCoordinator.lane(sceneIsActive: false, policy: policy), .background)
    }

    func testEachLaneIsBudgetedOnItsOwn() {
        let policy = CloudTransportCoordinator.Policy()
        // Two transfers the OS has parked must not use up the slots live data needs.
        XCTAssertTrue(CloudTransportCoordinator.hasRoom(lane: .process, inFlight: 0,
                                                        backgroundInFlight: policy.maxBackgroundInFlight, policy: policy))
        XCTAssertFalse(CloudTransportCoordinator.hasRoom(lane: .background, inFlight: 0,
                                                         backgroundInFlight: policy.maxBackgroundInFlight, policy: policy))
        XCTAssertFalse(CloudTransportCoordinator.hasRoom(lane: .process, inFlight: policy.maxInFlight,
                                                         backgroundInFlight: 0, policy: policy))
        XCTAssertTrue(CloudTransportCoordinator.hasRoom(lane: .process, inFlight: policy.maxInFlight - 1,
                                                        backgroundInFlight: 0, policy: policy))
    }

    func testBacklogDrainsSeveralAtATimeWithFreshDataAhead() {
        struct B { let id: String; let at: Int }
        let policy = CloudTransportCoordinator.Policy()
        XCTAssertGreaterThanOrEqual(policy.maxBacklogInFlight, 3)
        XCTAssertGreaterThan(policy.maxInFlight, policy.maxBacklogInFlight)   // a slot always left for fresh data
        XCTAssertEqual(policy.sealMaxRecords, PushProtocolLimits.maxRecords)   // the protocol maximum, not 2,000
        let backlog = (0..<6).map { B(id: "old\($0)", at: $0) }
        let fresh = [B(id: "new1", at: 1_000), B(id: "new0", at: 900)]   // newest first
        func queue(inFlight: Int) -> [String] {
            CloudTransportCoordinator.admissionQueue(
                due: backlog, newest: fresh, id: \.id, createdAtMs: \.at, freshCutoffMs: 500,
                backlogInFlight: inFlight, policy: policy).map(\.id)
        }
        // Oldest backlog first, then the newest fresh batch, then more backlog up to the cap.
        XCTAssertEqual(queue(inFlight: 0), ["old0", "new1", "old1", "old2"])
        XCTAssertEqual(queue(inFlight: 2), ["old0", "new1"])
        // A full backlog budget still lets fresh data through.
        XCTAssertEqual(queue(inFlight: 3), ["new1"])
        // No backlog at all: just the fresh batch.
        XCTAssertEqual(CloudTransportCoordinator.admissionQueue(
            due: [B](), newest: fresh, id: \.id, createdAtMs: \.at, freshCutoffMs: 500,
            backlogInFlight: 0, policy: policy).map(\.id), ["new1"])
    }

    func testCatchUpWaitsForTheBacklogNotForLiveData() {
        var stats = CloudJournalStats.empty
        XCTAssertTrue(AppModel.cloudBacklogDrained(stats))
        // Live data in flight (a few seconds of records, a fresh file or two) is not a backlog.
        stats.pendingRecords = 120
        stats.sealedBatches = 2
        XCTAssertTrue(AppModel.cloudBacklogDrained(stats))
        // The morning of 2026-10-08: the night was handed over, ~170 files still to send.
        stats.sealedBatches = 8
        XCTAssertFalse(AppModel.cloudBacklogDrained(stats))
        stats.sealedBatches = 0
        stats.pendingRecords = 40_000
        XCTAssertFalse(AppModel.cloudBacklogDrained(stats))
    }

    func testSealTargetRelaxesOffScreen() {
        // On screen: inside the worker's ~once-a-minute republish of the current day.
        XCTAssertEqual(CloudPushRuntime.sealTargetSeconds(sceneActive: true), 10)
        // Off screen: one file per stream every few minutes, not a request every few seconds.
        XCTAssertGreaterThan(CloudPushRuntime.sealTargetSeconds(sceneActive: false),
                             CloudPushRuntime.sealTargetSeconds(sceneActive: true))
        XCTAssertLessThanOrEqual(CloudPushRuntime.sealTargetSeconds(sceneActive: false), 300)
    }

    // MARK: - capture seam

    func testCaptureIsANoOpWhenCloudIsNotRunning() {
        // The BLE path calls these unconditionally; with no runtime they must report a skip rather
        // than throw or block, which is what keeps an offline install byte-for-byte unchanged.
        let skip = CloudCapture.recordStandardHR(hr: 70, rr: [900], contact: .supportedDetected,
                                                 family: .whoop4, at: 1_700_000_000,
                                                 deviceId: "my-whoop", receivedAtMs: 1_700_000_000_000)
        XCTAssertEqual(skip, .notRunning)
    }

    // MARK: - heart-rate seconds (one bpm per second reaches the receiver)

    private func liveRecords(hr: Int, rr: [Int] = [], at ts: Int, ledger: CloudHeartRateLedger?) -> [CloudJournalRecord] {
        CloudCapture.standardHRRecords(hr: hr, rr: rr, contact: .supportedDetected, family: .whoop5, at: ts,
                                       deviceId: "whoop-MGB0214654", receivedAtMs: ts * 1000,
                                       characteristic: "2A37", ledger: ledger)
    }

    private func bpmValues(_ records: [CloudJournalRecord]) throws -> [Int] {
        try records.filter { $0.stream == .hrSample }.map { record in
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
            let data = try XCTUnwrap(payload["data"] as? [String: Any])
            return try XCTUnwrap(data["bpm"] as? Int)
        }
    }

    func testLedgerKeepsTheFirstSampleOfASecondAndDropsTheRest() {
        let ledger = CloudHeartRateLedger()
        let first = ledger.claim([HRSample(ts: 100, bpm: 70), HRSample(ts: 100, bpm: 74),
                                  HRSample(ts: 101, bpm: 71)], deviceId: "strap")
        XCTAssertEqual(first, [HRSample(ts: 100, bpm: 70), HRSample(ts: 101, bpm: 71)],
                       "a repeat inside one call keeps its first sample, as the local store does")
        let later = ledger.claim([HRSample(ts: 101, bpm: 75), HRSample(ts: 102, bpm: 72)], deviceId: "STRAP")
        XCTAssertEqual(later, [HRSample(ts: 102, bpm: 72)],
                       "a held second is not offered again, and the device id is not case sensitive")
        let other = ledger.claim([HRSample(ts: 100, bpm: 70)], deviceId: "other-strap")
        XCTAssertEqual(other.count, 1, "each device holds its own seconds")
        XCTAssertEqual(ledger.count(deviceId: "strap"), 3)
    }

    func testLedgerSeedMarksSecondsHeldAndResetForgetsThem() {
        let ledger = CloudHeartRateLedger()
        ledger.seed(["Whoop-A": [10, 11, 12], "empty": []])
        XCTAssertTrue(ledger.holds(11, deviceId: "whoop-a"))
        XCTAssertEqual(ledger.claim([HRSample(ts: 11, bpm: 60), HRSample(ts: 13, bpm: 61)], deviceId: "whoop-a"),
                       [HRSample(ts: 13, bpm: 61)])
        ledger.reset()
        XCTAssertEqual(ledger.count(deviceId: "whoop-a"), 0)
        XCTAssertEqual(ledger.claim([HRSample(ts: 11, bpm: 60)], deviceId: "whoop-a").count, 1)
    }

    func testLedgerForgetsSecondsOlderThanItsWindowOnceFull() {
        let ledger = CloudHeartRateLedger(retainSeconds: 100, capacity: 10)
        let now = 50_000
        _ = ledger.claim((0..<10).map { HRSample(ts: now - 5_000 + $0, bpm: 60) }, deviceId: "d", now: now)
        XCTAssertEqual(ledger.count(deviceId: "d"), 10)
        _ = ledger.claim([HRSample(ts: now, bpm: 61), HRSample(ts: now - 1, bpm: 62)], deviceId: "d", now: now)
        XCTAssertEqual(ledger.count(deviceId: "d"), 2, "the stale seconds are trimmed once the set is over capacity")
        XCTAssertTrue(ledger.holds(now, deviceId: "d"))
        XCTAssertFalse(ledger.holds(now - 5_000, deviceId: "d"))
    }

    func testStrapDoublingOneSecondSendsTheFirstBpmOnlyAndStillSendsTheBeat() throws {
        let ledger = CloudHeartRateLedger()
        let ts = 1_790_950_000
        let first = liveRecords(hr: 72, rr: [830], at: ts, ledger: ledger)
        let second = liveRecords(hr: 75, rr: [810], at: ts, ledger: ledger)
        XCTAssertEqual(try bpmValues(first), [72])
        XCTAssertEqual(try bpmValues(second), [], "a second bpm for the same second would be a conflict on the receiver")
        XCTAssertEqual(second.filter { $0.stream == .rrInterval }.count, 1, "the beat itself is still sent")
    }

    func testHistorySendsOnlySecondsTheLiveNotificationsDidNotCover() throws {
        let ledger = CloudHeartRateLedger()
        let base = 1_790_950_000
        for offset in 0..<3 {
            XCTAssertEqual(try bpmValues(liveRecords(hr: 70 + offset, at: base + offset, ledger: ledger)).count, 1)
        }
        // The offload returns seconds 0...5; the strap's bpm differs from what was heard live.
        let chunk = Streams(hr: (0..<6).map { HRSample(ts: base + $0, bpm: 80 + $0) })
        let fresh = CloudCapture.freshHeartRates(chunk, deviceId: "whoop-MGB0214654", ledger: ledger)
        XCTAssertEqual(fresh.hr.map(\.ts), [base + 3, base + 4, base + 5])
        let records = CloudCapture.rows(from: fresh, provenance: .history, family: .whoop5,
                                        wallClockRef: nil, deviceClockRef: nil, receivedAtMs: 0,
                                        characteristic: nil, deviceId: "whoop-MGB0214654")
        XCTAssertEqual(try bpmValues(records), [83, 84, 85])

        let resent = CloudCapture.freshHeartRates(chunk, deviceId: "whoop-MGB0214654", ledger: ledger)
        XCTAssertTrue(resent.hr.isEmpty, "a chunk the strap sends again adds nothing")
    }

    func testLiveSecondTheOffloadAlreadySentIsLeftOut() throws {
        let ledger = CloudHeartRateLedger()
        let ts = 1_790_950_000
        let chunk = Streams(hr: [HRSample(ts: ts, bpm: 64)])
        XCTAssertEqual(CloudCapture.freshHeartRates(chunk, deviceId: "whoop-MGB0214654", ledger: ledger).hr.count, 1)
        XCTAssertEqual(try bpmValues(liveRecords(hr: 66, at: ts, ledger: ledger)), [],
                       "the offload got there first, so the live sample for that second is dropped")
    }

    func testCaptureWithoutALedgerSendsEveryHeartRateRow() throws {
        let ts = 1_790_950_000
        XCTAssertEqual(try bpmValues(liveRecords(hr: 72, at: ts, ledger: nil)), [72])
        XCTAssertEqual(try bpmValues(liveRecords(hr: 75, at: ts, ledger: nil)), [75])
    }

    func testRecentStrapSecondsReadsTheJournalTailPerDeviceForTheOwner() async throws {
        let journal = try await makeJournal(deviceId: "my-whoop")
        journal.submit([hrRecord(ts: 10, bpm: 60, deviceId: "Strap-A"), hrRecord(ts: 11, bpm: 61, deviceId: "strap-a"),
                        hrRecord(ts: 12, bpm: 62)])
        _ = await journal.flush()
        let everything = await journal.recentStrapSeconds(stream: .hrSample, lastRecords: 100)
        XCTAssertEqual(Set(everything["strap-a"] ?? []), [10, 11])
        XCTAssertEqual(everything["my-whoop"], [12])

        let tail = await journal.recentStrapSeconds(stream: .hrSample, lastRecords: 1)
        XCTAssertEqual(tail["my-whoop"], [12])
        XCTAssertNil(tail["strap-a"], "only the newest records are read back")

        let otherStream = await journal.recentStrapSeconds(stream: .battery, lastRecords: 100)
        XCTAssertTrue(otherStream.isEmpty)

        let otherOwner = try await makeJournal(ownerId: "33333333-3333-4333-8333-333333333333", deviceId: "my-whoop")
        let theirs = await otherOwner.recentStrapSeconds(stream: .hrSample, lastRecords: 100)
        XCTAssertTrue(theirs.isEmpty, "another owner's seconds are not this owner's to skip")
    }

    // MARK: - blocked re-seal

    func testResealBlockedReturnsRecordsToPending() async throws {
        let journal = try await makeJournal()
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 58), hrRecord(ts: 1_700_000_001, bpm: 60),
                        hrRecord(ts: 1_700_000_002, bpm: 62)])
        _ = await journal.flush()
        let now = Int(Date().timeIntervalSince1970 * 1000) + 5_000
        let candidate = try await journal.sealCandidates(nowMs: now)[0]
        let entries = try await journal.entries(for: candidate)
        let plan = try CloudBatchBuilder.plan(entries: entries, stream: .hrSample,
                                             sourceId: candidate.sourceId, deviceId: candidate.deviceId,
                                             protocolVersion: "1.1", startCursorJSON: nil)
        try await journal.registerSeal(candidate, batchId: plan.batch.batchId, filePath: "unused",
                                       contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                       contentLength: 128, protocolVersion: "1.1", endCursorJSON: nil)
        try await journal.markFailed(batchId: plan.batch.batchId, error: "HTTP 422",
                                     nextAttemptAtMs: nil, blocked: true)
        try await journal.resealBlocked(batchId: plan.batch.batchId)
        let resealable = try await journal.sealCandidates(nowMs: now)
        XCTAssertEqual(resealable.first?.recordCount, 3, "records must return to the pending pool")
    }

    func testCappedSealTakesTheOldestRecordsAndLeavesTheRestPending() async throws {
        let journal = try await makeJournal()
        journal.submit((0..<5).map { hrRecord(ts: 1_700_000_000 + $0, bpm: 60 + $0) })
        _ = await journal.flush()
        let now = Int(Date().timeIntervalSince1970 * 1000) + 5_000
        let candidate = try await journal.sealCandidates(nowMs: now)[0]
        XCTAssertEqual(candidate.recordCount, 5)

        let entries = try await journal.entries(for: candidate, limit: 2)
        XCTAssertEqual(entries.map(\.seq), [candidate.firstSeq, candidate.firstSeq + 1])
        let plan = try CloudBatchBuilder.plan(entries: entries, stream: .hrSample,
                                             sourceId: candidate.sourceId, deviceId: candidate.deviceId,
                                             protocolVersion: "1.1", startCursorJSON: nil)
        XCTAssertEqual(plan.entries.count, 2)
        let covered = CloudSealCandidate(ownerId: candidate.ownerId, sourceId: candidate.sourceId,
                                         deviceId: candidate.deviceId, stream: candidate.stream,
                                         firstSeq: plan.entries.first!.seq, lastSeq: plan.entries.last!.seq,
                                         recordCount: plan.entries.count,
                                         oldestReceivedAtMs: candidate.oldestReceivedAtMs,
                                         byteSize: 128, windowIdentity: candidate.windowIdentity)
        try await journal.registerSeal(covered, batchId: plan.batch.batchId, filePath: "unused",
                                       contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                       contentLength: 128, protocolVersion: "1.1", endCursorJSON: nil)

        let remaining = try await journal.sealCandidates(nowMs: now)
        XCTAssertEqual(remaining.first?.recordCount, 3)
        XCTAssertEqual(remaining.first?.firstSeq, candidate.firstSeq + 2)
    }

    func testRescheduleFailedMakesBackedOffBatchesDueButKeepsTheirAttempts() async throws {
        let journal = try await makeJournal()
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 60)])
        _ = await journal.flush()
        let now = Int(Date().timeIntervalSince1970 * 1000) + 5_000
        let candidate = try await journal.sealCandidates(nowMs: now)[0]
        let plan = try CloudBatchBuilder.plan(entries: try await journal.entries(for: candidate), stream: .hrSample,
                                             sourceId: candidate.sourceId, deviceId: candidate.deviceId,
                                             protocolVersion: "1.1", startCursorJSON: nil)
        try await journal.registerSeal(candidate, batchId: plan.batch.batchId, filePath: "unused",
                                       contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                       contentLength: 128, protocolVersion: "1.1", endCursorJSON: nil)
        try await journal.markFailed(batchId: plan.batch.batchId, error: "HTTP 503",
                                     nextAttemptAtMs: now + 3_600_000)
        let beforeReschedule = try await journal.batches(states: [.failed], dueBeforeMs: now)
        XCTAssertTrue(beforeReschedule.isEmpty)

        try await journal.rescheduleFailed(dueAtMs: now)
        let due = try await journal.batches(states: [.failed], dueBeforeMs: now)
        XCTAssertEqual(due.map(\.batchId), [plan.batch.batchId])
        XCTAssertEqual(due.first?.attempts, 1, "the attempt cap must still count the failed attempt")
    }

    // MARK: - stale payload paths

    func testResealMissingPayloadFreesUnsentWorkButNeverReservedWork() async throws {
        let journal = try await makeJournal()
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 60), hrRecord(ts: 1_700_000_001, bpm: 61)])
        _ = await journal.flush()
        let now = Int(Date().timeIntervalSince1970 * 1000) + 5_000
        let candidate = try await journal.sealCandidates(nowMs: now)[0]
        let entries = try await journal.entries(for: candidate)
        let plan = try CloudBatchBuilder.plan(entries: entries, stream: .hrSample,
                                             sourceId: candidate.sourceId, deviceId: candidate.deviceId,
                                             protocolVersion: "1.1", startCursorJSON: nil)
        try await journal.registerSeal(candidate, batchId: plan.batch.batchId,
                                       filePath: "/var/mobile/Containers/Data/Application/STALE/payload.ndjson.gz",
                                       contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                       contentLength: 6, protocolVersion: "1.1", endCursorJSON: nil)

        // A reserved batch is owned by a live task; a missing-file reseal must not touch it.
        try await journal.markReserved(batchId: plan.batch.batchId, taskId: "7", taskKind: "background",
                                       authExpiresAtMs: nil)
        try await journal.resealMissingPayload(batchId: plan.batch.batchId)
        let reservedState = try await journal.batchState(plan.batch.batchId)
        XCTAssertEqual(reservedState, .reserved)
        let stillSealed = try await journal.sealCandidates(nowMs: now)
        XCTAssertTrue(stillSealed.isEmpty)

        // An unsent batch whose file is gone goes back to the pool instead of staying the queue head.
        try await journal.markFailed(batchId: plan.batch.batchId, error: "task no longer present",
                                     nextAttemptAtMs: nil)
        try await journal.resealMissingPayload(batchId: plan.batch.batchId)
        let goneState = try await journal.batchState(plan.batch.batchId)
        XCTAssertNil(goneState)
        let resealable = try await journal.sealCandidates(nowMs: now)
        XCTAssertEqual(resealable.first?.recordCount, 2)
    }

    // MARK: - strap history offload

    func testHistoryRowsCarryBandSleepStateAndDropRowsOutsideTheWireContract() throws {
        let streams = Streams(steps: [StepSample(ts: 1_790_748_000, counter: 12, activityClass: 1),
                                      StepSample(ts: 1_790_748_001, counter: 70_000)],
                              sleepState: [SleepStateSample(ts: 1_790_748_000, state: 2, rawByte: 0x20),
                                           SleepStateSample(ts: 1_790_748_001, state: 1),
                                           SleepStateSample(ts: 1_790_748_002, state: 1, rawByte: 0x30),
                                           SleepStateSample(ts: 1_790_748_003, state: 5)])
        let records = CloudCapture.rows(from: streams, provenance: .history, family: .whoop4,
                                        wallClockRef: nil, deviceClockRef: nil, receivedAtMs: 0,
                                        characteristic: nil, deviceId: "my-whoop")
        XCTAssertEqual(records.filter { $0.stream == .stepSample }.count, 1)
        let sleep = records.filter { $0.stream == .sleepStateSample }
        XCTAssertEqual(sleep.map(\.strapTs), [1_790_748_000, 1_790_748_001])
        XCTAssertTrue(records.allSatisfy { $0.provenance == .history })

        XCTAssertEqual(CloudBatchBuilder.appendTable(for: .sleepStateSample), .sleepStateSample)
        let rows = try sleep.enumerated().map { index, record in
            try CloudBatchBuilder.decodeRow(CloudJournalEntry(seq: Int64(index + 1), record: record,
                                                              ownerId: "o", deviceId: "d", sourceId: "s"))
        }
        XCTAssertNoThrow(try PushProtocol.appendBatch(table: .sleepStateSample,
                                                      sourceId: "22222222-2222-4222-8222-222222222222",
                                                      deviceId: "my-whoop", startCursor: nil,
                                                      records: rows, protocolVersion: "1.1"))
    }

    func testHistoryRowsCarryTheStrapSpo2EstimateAsEventRows() throws {
        let streams = Streams(v18Aux: [
            V18AuxSample(ts: 1_790_748_000, auxByte82: 97),
            V18AuxSample(ts: 1_790_748_001, auxByte82: 0),
            V18AuxSample(ts: 1_790_748_002, auxByte82: 128),
            V18AuxSample(ts: 1_790_748_003, auxByte82: 69),
            V18AuxSample(ts: 1_790_748_004, auxByte82: 93),
            V18AuxSample(ts: 1_790_748_005),
        ])
        let records = CloudCapture.rows(from: streams, provenance: .history, family: .whoop5,
                                        wallClockRef: nil, deviceClockRef: nil, receivedAtMs: 0,
                                        characteristic: nil, deviceId: "my-whoop")
        XCTAssertEqual(records.map(\.strapTs), [1_790_748_000, 1_790_748_004],
                       "only an in-band byte is a reading; 0, sentinels and codes are not")
        XCTAssertTrue(records.allSatisfy { $0.stream == .event && $0.provenance == .history })

        let rows = try records.enumerated().map { index, record in
            try CloudBatchBuilder.decodeRow(CloudJournalEntry(seq: Int64(index + 1), record: record,
                                                              ownerId: "o", deviceId: "d", sourceId: "s"))
        }
        XCTAssertNoThrow(try PushProtocol.appendBatch(table: .event,
                                                      sourceId: "22222222-2222-4222-8222-222222222222",
                                                      deviceId: "my-whoop", startCursor: nil,
                                                      records: rows, protocolVersion: "1.1"))
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: XCTUnwrap(records.first).payload) as? [String: Any])
        let key = try XCTUnwrap(payload["key"] as? [String: Any])
        XCTAssertEqual(key["kind"] as? String, Spo2StrapEstimate.eventKind)
        let data = try XCTUnwrap(payload["data"] as? [String: Any])
        XCTAssertEqual(Spo2StrapEstimate.percent(fromPayloadJSON: try XCTUnwrap(data["payloadJSON"] as? String)), 97)
    }

    // MARK: - hosted worker result

    private func hostedEnvelope(daily: [String: Any], revision: Any = "42") -> [String: Any] {
        ["server_scoring": ["hosted_snapshot": [
            "algorithm_version": "frwhoop-server-1", "result_revision": revision, "input_revision": "7",
            "computed_at": "2026-09-30T14:00:00.123456+00:00", "pending": true, "status": "partial",
            "status_reasons": ["gravity_empty"], "daily": daily,
            "sleep": [
                ["id": "s1", "start_at": "2026-09-30T06:00:00Z", "end_at": "2026-09-30T13:30:00Z",
                 "is_nap": false, "efficiency": 0.91, "resting_hr_bpm": 52, "hrv_rmssd_ms": 61.2,
                 "stages": [["start": 1_790_748_000, "end": 1_790_775_000, "stage": "light"]]],
                ["id": "bad", "start_at": "not a time", "end_at": "2026-09-30T13:30:00Z"],
            ],
        ] as [String: Any]]]
    }

    func testHostedResultReadsTheWorkerSnapshotWithoutInventingValues() throws {
        let daily: [String: Any] = ["sleep_total_min": 431.5, "sleep_efficiency": 0.91, "resting_hr_bpm": 52,
                                    "hrv_rmssd_ms": 61.2, "strain": 8.4, "restScore": 82, "steps": 4120,
                                    "sleepHrOnly": false, "exerciseCount": true]
        let snapshot = ServerScoreRepository.snapshot(day: "2026-09-30", deviceId: "my-whoop",
                                                      envelope: hostedEnvelope(daily: daily), fetchedAtMs: 0)
        let result = try XCTUnwrap(snapshot.hostedResult)
        XCTAssertEqual(result.daily.day, "2026-09-30")
        XCTAssertEqual(result.daily.totalSleepMin, 431.5)
        XCTAssertEqual(result.daily.restingHr, 52)
        XCTAssertEqual(result.daily.strain, 8.4)
        XCTAssertEqual(result.daily.steps, 4120)
        XCTAssertEqual(result.daily.sleepHrOnly, false)
        // No baseline yet: Charge stays absent, never zero. A JSON boolean is not a count.
        XCTAssertNil(result.daily.recovery)
        XCTAssertNil(result.daily.exerciseCount)
        XCTAssertEqual(result.restScore, 82)
        XCTAssertEqual(result.resultRevision, "42")
        XCTAssertTrue(result.pending)
        XCTAssertEqual(result.statusReasons, ["gravity_empty"])
        XCTAssertEqual(result.sleep.count, 1, "an unparseable night is dropped, not guessed")
        let night = try XCTUnwrap(result.sleep.first)
        XCTAssertEqual([night.startTs, night.endTs], [1_790_748_000, 1_790_775_000])
        XCTAssertEqual(night.restingHr, 52)
        XCTAssertEqual(night.efficiency, 0.91)
        XCTAssertNotNil(night.stagesJSON)

        let unrevisioned = ServerScoreRepository.snapshot(day: "2026-09-30", deviceId: "my-whoop",
                                                          envelope: hostedEnvelope(daily: daily, revision: 42),
                                                          fetchedAtMs: 0)
        XCTAssertNil(unrevisioned.hostedResult)
    }

    func testHostedResultReadsTheIntradayHrvSeriesAndDropsMalformedPoints() throws {
        let points: [Any] = [
            [1_790_870_700, 70.5, 612] as [Any],
            [1_790_869_800, 64.0, 480] as [Any],
            [1_790_871_600, "bad", 300] as [Any],
            [1_790_872_500, 0, 300] as [Any],
            [1_790_873_400, 55.0] as [Any],
            [true, 55.0, 100] as [Any],
        ]
        let daily: [String: Any] = ["hrv_rmssd_ms": 61.2, "hrv_series": ["slot_s": 900, "points": points] as [String: Any]]
        let snapshot = ServerScoreRepository.snapshot(day: "2026-09-30", deviceId: "my-whoop",
                                                      envelope: hostedEnvelope(daily: daily), fetchedAtMs: 0)
        let result = try XCTUnwrap(snapshot.hostedResult)
        XCTAssertEqual(result.hrvSeries.map(\.startTs), [1_790_869_800, 1_790_870_700],
                       "oldest first; a non-numeric, non-positive, short or boolean point is dropped")
        XCTAssertEqual(result.hrvSeries.map(\.rmssd), [64.0, 70.5])
        XCTAssertEqual(result.hrvSeries.first?.cleanBeats, 480)
        XCTAssertEqual(result.hrvSlotSeconds, 900)

        let none = ServerScoreRepository.snapshot(day: "2026-09-30", deviceId: "my-whoop",
                                                  envelope: hostedEnvelope(daily: ["hrv_rmssd_ms": 61.2]),
                                                  fetchedAtMs: 0)
        XCTAssertEqual(try XCTUnwrap(none.hostedResult).hrvSeries, [], "no series published is empty, not invented")
    }

    func testHostedResultAttachesTheWorkersSlotContextToEachPoint() throws {
        let points: [Any] = [[1_790_869_800, 64.0, 800] as [Any], [1_790_870_700, 41.0, 700] as [Any],
                             [1_790_871_600, 58.0, 650] as [Any]]
        let context: [Any] = [
            ["slot_s": 1_790_869_800, "weak": false, "reasons": [] as [Any], "moving_share": 0.0,
             "unknown_share": 0.1, "clean_coverage": 0.9] as [String: Any],
            ["slot_s": 1_790_870_700, "weak": true, "reasons": ["movement", "something_new"], "moving_share": 0.8,
             "unknown_share": 0.0, "clean_coverage": 0.8] as [String: Any],
            ["slot_s": 1_790_871_600, "reasons": ["movement"]] as [String: Any],   // malformed: no `weak`
        ]
        let daily: [String: Any] = ["hrv_series": ["slot_s": 900, "points": points, "context": context] as [String: Any]]
        let snapshot = ServerScoreRepository.snapshot(day: "2026-09-30", deviceId: "my-whoop",
                                                      envelope: hostedEnvelope(daily: daily), fetchedAtMs: 0)
        let series = try XCTUnwrap(snapshot.hostedResult).hrvSeries
        XCTAssertEqual(series.map(\.context?.weak), [false, true, nil])
        XCTAssertEqual(series[1].context?.reasons, [.movement], "an unknown reason code is skipped, the flag kept")
        XCTAssertEqual(series[1].context?.movingShare ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(series.map(\.rmssd), [64.0, 41.0, 58.0], "a flagged reading is kept, never dropped")
    }

    func testMaterializedHostedDayReplacesADriftedNightInsteadOfDoublingIt() async throws {
        let store = try await WhoopStore.inMemory()
        let computedId = HostedResultMaterializer.computedId(for: "my-whoop")
        // An earlier server pass keyed the same night 20 minutes later.
        _ = try await store.upsertSleepSessions([CachedSleepSession(startTs: 1_790_749_200, endTs: 1_790_775_000,
                                                                    efficiency: 0.8, restingHr: 55, avgHrv: 50,
                                                                    stagesJSON: nil)],
                                                deviceId: computedId)
        let snapshot = ServerScoreRepository.snapshot(
            day: "2026-09-30", deviceId: "my-whoop",
            envelope: hostedEnvelope(daily: ["recovery": 64, "strain": 8.4, "restScore": 82]), fetchedAtMs: 0)
        try await HostedResultMaterializer.persist(try XCTUnwrap(snapshot.hostedResult), store: store,
                                                   deviceId: "my-whoop")

        let days = try await store.dailyMetrics(deviceId: computedId, from: "2026-09-30", to: "2026-09-30")
        XCTAssertEqual(days.first?.recovery, 64)
        XCTAssertEqual(days.first?.strain, 8.4)
        let nights = try await store.sleepSessions(deviceId: computedId, from: 0, to: .max, limit: 10)
        XCTAssertEqual(nights.map(\.startTs), [1_790_748_000])
        let rest = try await store.metricSeries(deviceId: computedId, key: "sleep_performance",
                                                from: "2026-09-30", to: "2026-09-30")
        XCTAssertEqual(rest.map(\.value), [82])
        let source = try await store.scoreInputSource(deviceId: computedId, day: "2026-09-30", key: "recovery")
        XCTAssertEqual(source, "my-whoop")
    }

    func testHostedStrapSpo2EstimateLandsInTheSeriesTheBloodOxygenTileReadsAndNeverInSpo2Pct() async throws {
        let store = try await WhoopStore.inMemory()
        let computedId = HostedResultMaterializer.computedId(for: "my-whoop")
        let night: [String: Any] = ["restScore": 82, "spo2_candidate_pct": 96, "spo2_candidate_samples": 451]
        let result = try XCTUnwrap(ServerScoreRepository.snapshot(
            day: "2026-09-30", deviceId: "my-whoop", envelope: hostedEnvelope(daily: night), fetchedAtMs: 0).hostedResult)
        XCTAssertEqual(result.spo2Candidate, 96)
        XCTAssertEqual(result.spo2CandidateSamples, 451)
        XCTAssertNil(result.daily.spo2Pct, "a strap estimate is never the calibrated blood-oxygen figure")

        try await HostedResultMaterializer.persist(result, store: store, deviceId: "my-whoop")
        var stored = try await store.metricSeries(deviceId: computedId, key: "spo2_candidate",
                                                  from: "2026-09-30", to: "2026-09-30")
        XCTAssertEqual(stored.map(\.value), [96])
        let days = try await store.dailyMetrics(deviceId: computedId, from: "2026-09-30", to: "2026-09-30")
        XCTAssertNil(days.first?.spo2Pct)

        // A later pass that no longer finds an estimate clears the old one instead of leaving it behind.
        let cleared = try XCTUnwrap(ServerScoreRepository.snapshot(
            day: "2026-09-30", deviceId: "my-whoop", envelope: hostedEnvelope(daily: ["restScore": 82]),
            fetchedAtMs: 0).hostedResult)
        XCTAssertNil(cleared.spo2Candidate)
        try await HostedResultMaterializer.persist(cleared, store: store, deviceId: "my-whoop")
        stored = try await store.metricSeries(deviceId: computedId, key: "spo2_candidate",
                                              from: "2026-09-30", to: "2026-09-30")
        XCTAssertTrue(stored.isEmpty)
    }

    func testHostedStrapSpo2EstimateOutsideTheBandOrWithoutReadingsIsIgnored() throws {
        func result(_ daily: [String: Any]) throws -> HostedDayResult {
            try XCTUnwrap(ServerScoreRepository.snapshot(day: "2026-09-30", deviceId: "my-whoop",
                                                         envelope: hostedEnvelope(daily: daily),
                                                         fetchedAtMs: 0).hostedResult)
        }
        XCTAssertNil(try result(["spo2_candidate_pct": 61, "spo2_candidate_samples": 40]).spo2Candidate)
        XCTAssertNil(try result(["spo2_candidate_pct": 101, "spo2_candidate_samples": 40]).spo2Candidate)
        XCTAssertNil(try result(["spo2_candidate_pct": 96]).spo2Candidate, "a mean with no readings behind it")
        XCTAssertNil(try result(["spo2_candidate_pct": 96, "spo2_candidate_samples": 0]).spo2Candidate)
        XCTAssertNil(try result(["spo2_candidate_pct": true, "spo2_candidate_samples": 40]).spo2Candidate)
    }
    // MARK: - D1: cloud-off stops staging and the upload cycle (consent/privacy)

    /// The full D1 staging contract: disabling staging stops NEW records from entering the journal,
    /// already-committed records are retained, and re-enabling resumes without deleting anything.
    func testDisablingCloudStopsStagingAndReEnableResumesIt() async throws {
        let owner = "11111111-1111-4111-8111-111111111111"
        let source = "22222222-2222-4222-8222-222222222222"
        let journal = try await makeJournal(ownerId: owner, sourceId: source)
        journal.submit([hrRecord(ts: 10, bpm: 60)])
        _ = await journal.flush()
        var stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 1)

        // Cloud off: this is exactly what `CloudPushRuntime.stop()` -> `CloudJournal.deactivate()`
        // does when the master switch flips. Staging stops accepting NEW records; nothing is deleted.
        await journal.deactivate(flushFirst: false)
        XCTAssertNil(journal.acceptingScope)
        journal.submit([hrRecord(ts: 11, bpm: 61)])

        // Re-enable: `start()` -> `activate()` resumes staging and the retained record is still there.
        // A deactivated journal reports no scope at all, so what was staged while off is read back here.
        try await journal.activate(configuration: .init(ownerId: owner, sourceId: source, deviceId: "my-whoop"),
                                   directory: directory)
        _ = await journal.flush()
        stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 1,
                       "while cloud is off, no new record may be staged")
        journal.submit([hrRecord(ts: 12, bpm: 62)])
        _ = await journal.flush()
        let resumed = await journal.stats()
        XCTAssertEqual(resumed.pendingRecords, 2,
                       "re-enabling must resume staging with the retained records intact")
    }

    /// The D1 upload-cycle gate: with the master switch off, a cycle pass must not seal, upload or
    /// otherwise touch the durable work; flipping the switch back on resumes it.
    func testDisabledCloudStopsTheUploadCycleAndReEnableResumesIt() async throws {
        let owner = "11111111-1111-4111-8111-111111111111"
        let source = "22222222-2222-4222-8222-222222222222"
        let journal = try await makeJournal(ownerId: owner, sourceId: source)
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 60)])
        _ = await journal.flush()
        let now = Int(Date().timeIntervalSince1970 * 1000) + 5_000
        let candidate = try await journal.sealCandidates(nowMs: now)[0]
        let plan = try CloudBatchBuilder.plan(entries: try await journal.entries(for: candidate),
                                              stream: .hrSample, sourceId: candidate.sourceId,
                                              deviceId: candidate.deviceId, protocolVersion: "1.1",
                                              startCursorJSON: nil)
        let file = directory.appendingPathComponent("\(plan.batch.batchId).ndjson.gz")
        try Data("sealed".utf8).write(to: file)
        try await journal.registerSeal(candidate, batchId: plan.batch.batchId, filePath: file.path,
                                       contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                       contentLength: 6, protocolVersion: "1.1", endCursorJSON: nil)

        let identity = CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: "t", uploadToken: "noop_t")
        let session = CloudUploadSession(
            endpoint: URL(string: "http://127.0.0.1:1/functions/v1/push")!,
            bundleIdentifier: "com.test.\(UUID().uuidString)",
            identity: { identity })
        var enabled = false
        let coordinator = CloudTransportCoordinator(journal: journal, session: session, scope: identity.scope,
                                                    payloadDirectory: directory,
                                                    projectURL: "http://127.0.0.1",
                                                    identity: { identity },
                                                    cloudEnabled: { enabled })
        // Start with cloud off: the launch reconciliation may run, but the cycle must no-op.
        await coordinator.start()
        let offState = try await journal.batchState(plan.batch.batchId)
        XCTAssertEqual(offState, .sealed, "a disabled cloud must not upload a sealed batch")
        let offStats = await journal.stats()
        XCTAssertEqual(offStats.pendingRecords, 1,
                       "the sealed batch's records are retained while cloud is off")

        // Re-enable: the very next pass must pick the retained batch back up. The endpoint refuses
        // connections, so the attempt fails as a retryable transport error — the assertion is that
        // the batch LEFT `sealed` (the cycle ran), not that the upload succeeded.
        enabled = true
        await coordinator.cycle()
        let deadline = Date().addingTimeInterval(10)
        var state = try await journal.batchState(plan.batch.batchId)
        while state == .sealed, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            state = try await journal.batchState(plan.batch.batchId)
        }
        XCTAssertNotEqual(state, .sealed, "re-enabling must resume the upload cycle")
        let retained = await journal.stats()
        XCTAssertEqual(retained.pendingRecords, 1,
                       "a failed upload attempt must never delete the records")
    }

    // MARK: - D2: journal re-activation once protected data becomes available

    /// A locked-before-first-unlock launch fails `activate` with `protectedDataUnavailable`; the
    /// re-activation retry must succeed the moment the journal file becomes readable again, and
    /// capture must resume (live seconds after a locked launch reach the cloud).
    func testJournalReactivationSucceedsOnceProtectedDataIsAvailable() async throws {
        let config = CloudJournal.Configuration(ownerId: "11111111-1111-4111-8111-111111111111",
                                                sourceId: "22222222-2222-4222-8222-222222222222",
                                                deviceId: "my-whoop")
        let journal = CloudJournal()
        // The journal file exists (the OS created it earlier) but is unreadable while locked.
        let dbFile = directory.appendingPathComponent("journal.sqlite")
        try Data().write(to: dbFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbFile.path)
        guard !FileManager.default.isReadableFile(atPath: dbFile.path) else {
            throw XCTSkip("running with privileges that ignore file permissions; cannot simulate a locked journal")
        }
        do {
            try await journal.activate(configuration: config, directory: directory)
            XCTFail("activating over an unreadable journal must fail with protectedDataUnavailable")
        } catch {
            guard case CloudJournalError.protectedDataUnavailable = error else {
                return XCTFail("expected protectedDataUnavailable, got \(error)")
            }
        }
        let lockedStats = await journal.stats()
        XCTAssertFalse(lockedStats.historyCursorHeld)
        XCTAssertEqual(lockedStats.pendingRecords, 0,
                       "nothing is staged while the journal cannot open")

        // First unlock: the same data-availability signal the D2 retry polls becomes true.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbFile.path)
        try await journal.activate(configuration: config, directory: directory)
        journal.submit([hrRecord(ts: 10, bpm: 60)])
        let committed = await journal.flush()
        XCTAssertEqual(committed, 1, "live seconds after unlock must reach the cloud journal")
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 1)
    }

    // MARK: - T23: acquisition-time owner isolation on the seal/send paths

    /// The journal's seal and batch views are scoped to the CONFIGURED owner: after an account
    /// switch on the same store, owner A's pending records are not sealable (or even visible) under
    /// owner B, while B's own records flow normally.
    func testJournalSealAndBatchViewsAreScopedToTheConfiguredOwner() async throws {
        let ownerA = "11111111-1111-4111-8111-111111111111"
        let ownerB = "33333333-3333-4333-8333-333333333333"
        let source = "22222222-2222-4222-8222-222222222222"
        let journal = try await makeJournal(ownerId: ownerA, sourceId: source)
        journal.submit([hrRecord(ts: 10, bpm: 60)])
        _ = await journal.flush()

        // Switch to owner B on the SAME store (the T23 account-switch shape).
        try await journal.activate(configuration: .init(ownerId: ownerB, sourceId: source, deviceId: "my-whoop"),
                                   directory: directory)
        let now = Int(Date().timeIntervalSince1970 * 1000) + 5_000
        let aUnderB = try await journal.sealCandidates(nowMs: now)
        XCTAssertTrue(aUnderB.isEmpty,
                      "owner A's pending records must never be sealable under owner B")

        // Owner B's own records are sealable and carry B's owner stamp.
        journal.submit([hrRecord(ts: 11, bpm: 61)])
        _ = await journal.flush()
        let bCandidates = try await journal.sealCandidates(nowMs: now)
        XCTAssertEqual(bCandidates.count, 1)
        XCTAssertEqual(bCandidates.first?.ownerId, ownerB)
        let entries = try await journal.entries(for: bCandidates.first!)
        XCTAssertEqual(entries.map(\.ownerId), [ownerB])
        XCTAssertEqual(entries.map(\.record.strapTs), [11])

        // A's records are still retained under A (never deleted), just not visible to B.
        try await journal.activate(configuration: .init(ownerId: ownerA, sourceId: source, deviceId: "my-whoop"),
                                   directory: directory)
        let aCandidates = try await journal.sealCandidates(nowMs: now)
        XCTAssertEqual(aCandidates.map(\.stream), [.hrSample])
        XCTAssertEqual(aCandidates.first?.recordCount, 1,
                       "the original owner's pending records must survive the switch")
    }

    /// A coordinator serving owner B never sends a batch owner A sealed: it is not even visible to B's
    /// scope, so it stays sealed and retained under A, payload file included (contract C3).
    func testCrossOwnerBatchIsRetainedNotUploadedUnderADifferentOwner() async throws {
        let ownerA = "11111111-1111-4111-8111-111111111111"
        let ownerB = "33333333-3333-4333-8333-333333333333"
        let source = "22222222-2222-4222-8222-222222222222"
        let journal = try await makeJournal(ownerId: ownerA, sourceId: source)
        journal.submit([hrRecord(ts: 1_700_000_000, bpm: 60)])
        _ = await journal.flush()
        let now = Int(Date().timeIntervalSince1970 * 1000) + 5_000
        let candidate = try await journal.sealCandidates(nowMs: now)[0]
        let plan = try CloudBatchBuilder.plan(entries: try await journal.entries(for: candidate),
                                              stream: .hrSample, sourceId: candidate.sourceId,
                                              deviceId: candidate.deviceId, protocolVersion: "1.1",
                                              startCursorJSON: nil)
        let file = directory.appendingPathComponent("\(plan.batch.batchId).ndjson.gz")
        try Data("sealed".utf8).write(to: file)
        try await journal.registerSeal(candidate, batchId: plan.batch.batchId, filePath: file.path,
                                       contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                       contentLength: 6, protocolVersion: "1.1", endCursorJSON: nil)

        // The runtime now runs under owner B while the journal still holds owner A's sealed batch.
        let identityB = CloudPushIdentity(ownerId: ownerB, sourceId: source, tokenId: "t", uploadToken: "noop_b")
        let session = CloudUploadSession(
            endpoint: URL(string: "http://127.0.0.1:1/functions/v1/push")!,
            bundleIdentifier: "com.test.\(UUID().uuidString)",
            identity: { identityB })
        let coordinator = CloudTransportCoordinator(journal: journal, session: session, scope: identityB.scope,
                                                    payloadDirectory: directory,
                                                    projectURL: "http://127.0.0.1",
                                                    identity: { identityB },
                                                    cloudEnabled: { true })
        await coordinator.start()
        await coordinator.cycle()

        // The cross-owner batch is never transmitted under B's token.
        let state = try await journal.batchState(plan.batch.batchId)
        XCTAssertEqual(state, .sealed,
                       "another owner's batch must stay sealed, not be uploaded under a different owner")
        try await journal.activate(configuration: .init(ownerId: ownerA, sourceId: source, deviceId: "my-whoop"),
                                   directory: directory)
        let retained = await journal.stats()
        XCTAssertEqual(retained.pendingRecords, 1,
                       "the records stay retained under the original owner")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the payload file must be kept, not deleted")
    }

    /// The upload session refuses to send a batch for one account with another account's credential at
    /// SEND time (the T23 token-resolution rule), even when the coordinator guard is bypassed.
    func testUploadSessionRefusesToSendAnotherOwnersBatch() async throws {
        let ownerA = "11111111-1111-4111-8111-111111111111"
        let ownerB = "33333333-3333-4333-8333-333333333333"
        let source = "22222222-2222-4222-8222-222222222222"
        let session = CloudUploadSession(
            endpoint: URL(string: "http://127.0.0.1:1/functions/v1/push")!,
            bundleIdentifier: "com.test.\(UUID().uuidString)",
            identity: { CloudPushIdentity(ownerId: ownerB, sourceId: source,
                                          tokenId: "t", uploadToken: "noop_b") })
        let file = directory.appendingPathComponent("batch.ndjson.gz")
        try Data("sealed".utf8).write(to: file)
        let scopeA = CloudDataScope(ownerId: ownerA, sourceId: source)
        do {
            _ = try await session.uploadForeground(batchId: "b1", fileURL: file, scope: scopeA)
            XCTFail("uploading owner A's batch with owner B's token must be refused")
        } catch let error as CloudUploadSession.UploadError {
            guard case .wrongAccount = error else {
                return XCTFail("expected wrongAccount, got \(error)")
            }
        } catch {
            XCTFail("expected wrongAccount, got \(error)")
        }
        XCTAssertThrowsError(try session.enqueueBackground(batchId: "b2", fileURL: file, scope: scopeA),
                             "the background lane must refuse it too")
    }



}


// MARK: - Duplicate conflict keys + blocked re-seal (live defect 2026-09-30)

final class BatchDedupeTests: XCTestCase {
    /// Live defect: a sealed hrSample batch containing two records at the same
    /// ts was rejected whole by the receiver (`duplicate_record_key`, 422) and
    /// the batch blocked. The builder must keep ONE row per natural key (last
    /// writer wins, mirroring the receiver's upsert).
    func testBuilderDeduplicatesRepeatedConflictKeys() throws {
        func entry(seq: Int64, ts: Int, bpm: Int) -> CloudJournalEntry {
            let record = CloudJournalRecord(
                stream: .hrSample, encoding: .jsonRow, provenance: .live,
                characteristic: "2A37", family: nil,
                receivedAtMs: ts * 1000, strapTs: ts,
                payload: try! JSONSerialization.data(withJSONObject: [
                    "key": ["ts": ts], "data": ["bpm": bpm],
                ]))
            return CloudJournalEntry(seq: seq, record: record, ownerId: "11111111-1111-4111-8111-111111111111",
                                     deviceId: "d", sourceId: "22222222-2222-4222-8222-222222222222")
        }
        let entries = [
            entry(seq: 1, ts: 1790792481, bpm: 58),
            entry(seq: 2, ts: 1790792482, bpm: 59),
            entry(seq: 3, ts: 1790792481, bpm: 60),
            entry(seq: 4, ts: 1790792483, bpm: 61),
        ]
        let plan = try CloudBatchBuilder.plan(entries: entries, stream: .hrSample,
                                               sourceId: "22222222-2222-4222-8222-222222222222", deviceId: "d",
                                               protocolVersion: "1.0",
                                               startCursorJSON: nil,
                                               maximumDecodedBytes: 1 << 20)
        // The duplicate ts collapses to the LAST writer (bpm 60).
        XCTAssertEqual(plan.batch.recordCount, 3)
        XCTAssertEqual(plan.entries.count, 3)
        let body = String(data: plan.batch.body, encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("\"bpm\":58"), "first duplicate must be dropped")
        XCTAssertTrue(body.contains("\"bpm\":60"), "last writer must win")
    }

}

// MARK: - Mandatory sync: durability of the upload path

/// A receiver stand-in for the transport's durability rules: it answers capabilities for one account and every
/// upload with a fixed status and body, and records what was sent.
private final class DurabilityUploader: CloudUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _uploads: [String] = []
    var onOutcome: (@Sendable (CloudUploadSession.Outcome) -> Void)?
    let owner: String
    let source: String
    var status = 503
    var body: Data?

    init(owner: String, source: String) {
        self.owner = owner
        self.source = source
    }

    var uploads: [String] { lock.lock(); defer { lock.unlock() }; return _uploads }

    func capabilities(scope: CloudDataScope?) async throws -> PushCapabilities {
        PushCapabilities(appendTables: PushCapabilities.all.appendTables,
                         mutableTables: PushCapabilities.all.mutableTables, protocolVersion: "1.2",
                         userId: owner, sourceId: source)
    }

    func uploadForeground(batchId: String, fileURL: URL, scope: CloudDataScope?) async throws -> CloudUploadSession.Outcome {
        record(batchId)
        return CloudUploadSession.Outcome(batchId: batchId, statusCode: status, body: body, errorDescription: nil)
    }

    private func record(_ batchId: String) {
        lock.lock(); _uploads.append(batchId); lock.unlock()
    }

    func enqueueBackground(batchId: String, fileURL: URL, scope: CloudDataScope?) throws -> Int { 1 }
    func outstandingTasks() async -> [(taskIdentifier: Int, batchId: String?)] { [] }
}

/// A mutable value a `@Sendable` closure can read.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Signed in ⇒ syncing only holds if what is captured actually gets there: these pin the journal and transport
/// rules that keep queued data moving through pruning, crashes, outages, refusals and source changes, the
/// replay of what was captured while the runtime was down, and the two upload-path data fixes.
final class CloudSyncDurabilityTests: XCTestCase {

    private var directory: URL!
    private var owner = ""
    private let source = "22222222-2222-4222-8222-222222222222"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        owner = UUID().uuidString.lowercased()
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "noop.cloud.protocolVersion.\(owner)")
        try? FileManager.default.removeItem(at: directory)
    }

    private var payloadDirectory: URL { directory.appendingPathComponent("payload", isDirectory: true) }

    private func makeJournal(owner: String? = nil, source: String? = nil,
                             policy: CloudJournal.SealPolicy = CloudJournal.SealPolicy()) async throws -> CloudJournal {
        let journal = CloudJournal()
        try await journal.activate(configuration: .init(ownerId: owner ?? self.owner, sourceId: source ?? self.source,
                                                        deviceId: "my-whoop"),
                                   policy: policy, directory: directory)
        return journal
    }

    private func hr(ts: Int, bpm: Int = 60, device: String? = nil) -> CloudJournalRecord {
        let payload = try! PushProtocol.canonicalJson(.map([
            "key": .map(["ts": .int(Int64(ts))]),
            "data": .map(["bpm": .int(Int64(bpm))]),
        ])).data(using: .utf8)!
        return CloudJournalRecord(stream: .hrSample, encoding: .jsonRow, provenance: .live, characteristic: "2A37",
                                  family: "whoop5", receivedAtMs: ts * 1000, strapTs: ts, deviceId: device,
                                  payload: payload)
    }

    /// Seal everything pending for one device into a batch whose payload file is in the payload directory.
    @discardableResult
    private func seal(_ journal: CloudJournal, device: String = "my-whoop") async throws -> CloudSealedBatch {
        let future = Int(Date().timeIntervalSince1970 * 1000) + 7_200_000
        let candidates = try await journal.sealCandidates(nowMs: future)
        let candidate = try XCTUnwrap(candidates.first { $0.deviceId == device })
        let plan = try CloudBatchBuilder.plan(entries: try await journal.entries(for: candidate), stream: candidate.stream,
                                              sourceId: candidate.sourceId, deviceId: candidate.deviceId,
                                              protocolVersion: "1.2", startCursorJSON: nil)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        let file = payloadDirectory.appendingPathComponent("\(plan.batch.batchId).ndjson.gz")
        let wire = try PushBinaryCompression.gzip(plan.batch.body)
        try wire.write(to: file)
        try await journal.registerSeal(candidate, batchId: plan.batch.batchId, filePath: file.path,
                                       contentSha256: PushDurabilityReceipt.sha256(plan.batch.body),
                                       contentLength: wire.count, protocolVersion: "1.2", endCursorJSON: nil)
        let sealed = try await journal.batches(states: [.sealed], limit: 64)
        return try XCTUnwrap(sealed.first { $0.batchId == plan.batch.batchId })
    }

    private func coordinator(_ journal: CloudJournal, uploader: DurabilityUploader, now: Box<Int>,
                             identity: Box<CloudPushIdentity?>? = nil) -> CloudTransportCoordinator {
        let fallback = CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: UUID().uuidString,
                                         uploadToken: "noop_durability")
        let identityBox = identity ?? Box<CloudPushIdentity?>(fallback)
        return CloudTransportCoordinator(journal: journal, session: uploader,
                                         scope: CloudDataScope(ownerId: owner, sourceId: source),
                                         payloadDirectory: payloadDirectory, projectURL: "https://example.supabase.co",
                                         identity: { identityBox.value }, now: { now.value }, random: { 0.5 },
                                         cloudEnabled: { true })
    }

    private func eventually(_ seconds: Double = 5, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return try await condition()
    }

    // MARK: D1 journal pruning

    func testANewJournalReclaimsFreedSpaceAndAnExistingOneKeepsItsMode() async throws {
        let fresh = try await makeJournal()
        let freshMode = await fresh.autoVacuumMode()
        XCTAssertEqual(freshMode, 2, "a journal created now uses incremental auto-vacuum")
        await fresh.deactivate()

        // A journal an earlier build created (auto_vacuum NONE, tables already there) is not rebuilt.
        let legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(legacyDirectory.appendingPathComponent("journal.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE journal_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
                                    nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let legacy = CloudJournal()
        var policy = CloudJournal.SealPolicy()
        policy.ackedRetentionSeconds = 0
        try await legacy.activate(configuration: .init(ownerId: owner, sourceId: source, deviceId: "my-whoop"),
                                  policy: policy, directory: legacyDirectory)
        let legacyMode = await legacy.autoVacuumMode()
        XCTAssertEqual(legacyMode, 0, "an existing journal keeps the mode it was created with")
        legacy.submit([hr(ts: 1_700_000_000)])
        _ = await legacy.flush()
        let pruned = try await legacy.pruneAcknowledged()
        XCTAssertEqual(pruned.records, 0, "and pruning there works without a vacuum")
        await legacy.deactivate()
    }

    func testStartAndTheHourlyPassPruneAcknowledgedRows() async throws {
        var policy = CloudJournal.SealPolicy()
        policy.ackedRetentionSeconds = 0
        policy.activeTargetSeconds = 3600
        let journal = try await makeJournal(policy: policy)
        journal.submit([hr(ts: 1_700_000_000)])
        _ = await journal.flush()
        let first = try await seal(journal)
        _ = try await journal.applyReceipt(batchId: first.batchId, contentSha256: first.contentSha256, receiptJSON: "{}")
        var held = await journal.recentStrapSeconds(stream: .hrSample, lastRecords: 100)
        XCTAssertEqual(held["my-whoop"], [1_700_000_000], "an acknowledged row is kept until it is pruned")
        try await Task.sleep(nanoseconds: 20_000_000)   // a retention of 0 s still needs the row to be older

        let now = Box(1_800_000_000)
        let uploader = DurabilityUploader(owner: owner, source: source)
        let coordinator = coordinator(journal, uploader: uploader, now: now)
        await coordinator.start()
        held = await journal.recentStrapSeconds(stream: .hrSample, lastRecords: 100)
        XCTAssertNil(held["my-whoop"], "start() prunes acknowledged rows")

        journal.submit([hr(ts: 1_700_000_100)])
        _ = await journal.flush()
        let second = try await seal(journal)
        _ = try await journal.applyReceipt(batchId: second.batchId, contentSha256: second.contentSha256, receiptJSON: "{}")
        try await Task.sleep(nanoseconds: 20_000_000)
        now.value += 600
        await coordinator.cycle()
        held = await journal.recentStrapSeconds(stream: .hrSample, lastRecords: 100)
        XCTAssertEqual(held["my-whoop"], [1_700_000_100], "the loop does not prune more than hourly")

        now.value += 3_600
        await coordinator.cycle()
        held = await journal.recentStrapSeconds(stream: .hrSample, lastRecords: 100)
        XCTAssertNil(held["my-whoop"], "an hour later the loop prunes again")
        await coordinator.stop()
        await journal.deactivate()
    }

    // MARK: D5 stuck in `uploaded`

    func testABatchLeftUploadedByAnEarlierRunIsSentAgainAtLaunch() async throws {
        var policy = CloudJournal.SealPolicy()
        policy.activeTargetSeconds = 3600
        let journal = try await makeJournal(policy: policy)
        journal.submit([hr(ts: 1_700_000_000), hr(ts: 1_700_000_001)])
        _ = await journal.flush()
        let batch = try await seal(journal)
        // The 200 arrived, then the process died before the receipt was applied.
        try await journal.markUploaded(batchId: batch.batchId)

        let uploader = DurabilityUploader(owner: owner, source: source)
        let coordinator = coordinator(journal, uploader: uploader, now: Box(Int(Date().timeIntervalSince1970)))
        await coordinator.start()
        let resent = await eventually { uploader.uploads.contains(batch.batchId) }
        await coordinator.stop()

        XCTAssertTrue(resent, "the batch is sent again; the receiver answers a replayed id with its receipt")
        let stranded = try await journal.batches(states: [.uploaded], limit: 10)
        XCTAssertTrue(stranded.isEmpty, "nothing is left in a state no pass looks at")
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 2, "the records are still held until a receipt says otherwise")
        await journal.deactivate()
    }

    // MARK: D6 offline outages

    func testBatchesThatRanOutOfAttemptsOfflineAreRetriedWhenTheNetworkReturns() async throws {
        var policy = CloudJournal.SealPolicy()
        policy.activeTargetSeconds = 3600
        let journal = try await makeJournal(policy: policy)
        journal.submit([hr(ts: 1_700_000_000, device: "offline"), hr(ts: 1_700_000_000, device: "refused"),
                        hr(ts: 1_700_000_000, device: "later"), hr(ts: 1_700_000_000, device: "backoff")])
        _ = await journal.flush()
        let now = Box(1_800_000_000)
        // No credential: the loop idles, so only the recovery itself moves anything here.
        let coordinator = coordinator(journal, uploader: DurabilityUploader(owner: owner, source: source), now: now,
                                      identity: Box<CloudPushIdentity?>(nil))
        await coordinator.start()

        let offline = try await seal(journal, device: "offline")
        try await journal.markFailed(batchId: offline.batchId,
                                     error: "attempt cap reached: cloud: transport failure: The Internet connection appears to be offline.",
                                     nextAttemptAtMs: nil, blocked: true)
        let refused = try await seal(journal, device: "refused")
        try await journal.markFailed(batchId: refused.batchId, error: "HTTP 403 device_owner_conflict",
                                     nextAttemptAtMs: nil, blocked: true)
        let waiting = try await seal(journal, device: "backoff")
        try await journal.markFailed(batchId: waiting.batchId, error: "HTTP 503",
                                     nextAttemptAtMs: (now.value + 3_000) * 1000)

        await coordinator.recoverStalledWork()

        let blocked = try await journal.blockedBatches()
        XCTAssertEqual(blocked.map(\.batchId), [refused.batchId],
                       "an outage no longer strands a batch until the next launch; a refusal stays blocked")
        let candidates = try await journal.sealCandidates(nowMs: (now.value + 7_200) * 1000)
        XCTAssertTrue(candidates.contains { $0.deviceId == "offline" }, "its records are pending again, to be re-sealed")
        let due = try await journal.batches(states: [.failed], dueBeforeMs: now.value * 1000, limit: 10)
        XCTAssertEqual(due.map(\.batchId), [waiting.batchId], "a long backoff is cut short when the network returns")

        // Recoveries are bounded: another request within a minute changes nothing.
        let later = try await seal(journal, device: "later")
        try await journal.markFailed(batchId: later.batchId, error: "attempt cap reached: HTTP 503",
                                     nextAttemptAtMs: nil, blocked: true)
        await coordinator.recoverStalledWork()
        var stillBlocked = try await journal.blockedBatches().map(\.batchId)
        XCTAssertTrue(stillBlocked.contains(later.batchId))
        now.value += 61
        await coordinator.recoverStalledWork()
        stillBlocked = try await journal.blockedBatches().map(\.batchId)
        XCTAssertEqual(stillBlocked, [refused.batchId])
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 4, "no record was dropped by any of it")
        await coordinator.stop()
        await journal.deactivate()
    }

    // MARK: D8 a refusal that names the batch

    func testABatchRefusedForAnotherAccountsStrapIsBlockedInsteadOfRetriedEvery30Seconds() async throws {
        var policy = CloudJournal.SealPolicy()
        policy.activeTargetSeconds = 0
        let journal = try await makeJournal(policy: policy)
        journal.submit([hr(ts: 1_700_000_000), hr(ts: 1_700_000_001)])
        _ = await journal.flush()
        let uploader = DurabilityUploader(owner: owner, source: source)
        uploader.status = 403
        uploader.body = Data(#"{"type":"error","protocolVersion":"1.2","code":"device_owner_conflict"}"#.utf8)
        let coordinator = coordinator(journal, uploader: uploader, now: Box(Int(Date().timeIntervalSince1970)))
        let rejections = Box<[Int]>([])
        await coordinator.setOnCredentialRejected { status in rejections.value.append(status) }

        await coordinator.start()
        let blocked = await eventually { ((try? await journal.blockedBatches()) ?? []).count == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await coordinator.recoverStalledWork()
        await coordinator.cycle()

        XCTAssertTrue(blocked, "the refused batch is blocked like any batch the receiver will not take")
        XCTAssertTrue(rejections.value.isEmpty, "it is not a credential problem, so no new credential is asked for")
        XCTAssertEqual(uploader.uploads.count, 1, "and it is not sent again until the next launch")
        let code = await coordinator.permanentRejectionCode()
        XCTAssertEqual(code, "device_owner_conflict", "the reason is surfaced")
        let stats = await journal.stats()
        XCTAssertEqual(stats.blockedBatches, 1)
        XCTAssertEqual(stats.pendingRecords, 2, "the records are kept")
        XCTAssertNil(CloudTransportCoordinator.permanentRejectionCode(status: 403, body: Data(#"{"code":"installation_revoked"}"#.utf8)),
                     "any other 403 is still the credential's")
        await coordinator.stop()
        await journal.deactivate()
    }

    // MARK: D4 source rotation

    func testRecordsAnEarlierSourceStillHeldGoOutUnderTheNewOne() async throws {
        let oldSource = "a0a0a0a0-a0a0-4a0a-8a0a-a0a0a0a0a0a0"
        let newSource = "b0b0b0b0-b0b0-4b0b-8b0b-b0b0b0b0b0b0"
        let stranger = UUID().uuidString.lowercased()
        let journal = try await makeJournal(source: oldSource)
        journal.submit([hr(ts: 100)])
        _ = await journal.flush()
        let acked = try await seal(journal)
        _ = try await journal.applyReceipt(batchId: acked.batchId, contentSha256: acked.contentSha256, receiptJSON: "{}")
        journal.submit([hr(ts: 101), hr(ts: 102)])
        _ = await journal.flush()
        let unsent = try await seal(journal)
        journal.submit([hr(ts: 103)])
        _ = await journal.flush()
        // Another account's queue under the same source id is never touched.
        try await journal.activate(configuration: .init(ownerId: stranger, sourceId: oldSource, deviceId: "my-whoop"),
                                   directory: directory)
        journal.submit([hr(ts: 200)])
        _ = await journal.flush()

        // The server refused the old source; the account layer rotated it, and the runtime starts on the new one.
        try await journal.activate(configuration: .init(ownerId: owner, sourceId: newSource, deviceId: "my-whoop"),
                                   directory: directory)
        await CloudPushRuntime.adoptEarlierSources(journal: journal, payloadDirectory: payloadDirectory)

        let future = Int(Date().timeIntervalSince1970 * 1000) + 7_200_000
        let rotated = try await journal.sealCandidates(nowMs: future)
        let candidate = try XCTUnwrap(rotated.first)
        let entries = try await journal.entries(for: candidate)
        XCTAssertEqual(entries.map(\.record.strapTs), [101, 102, 103], "every unacknowledged record moved, in order")
        XCTAssertTrue(entries.allSatisfy { $0.sourceId == newSource })
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsent.filePath), "the dissolved batch's file is gone")

        try await journal.activate(configuration: .init(ownerId: owner, sourceId: oldSource, deviceId: "my-whoop"),
                                   directory: directory)
        let oldStats = await journal.stats()
        XCTAssertEqual(oldStats.pendingRecords, 0, "nothing is left stranded under the old source")
        let oldBatches = try await journal.batches(states: [.sealed, .failed, .blocked, .reserved, .uploaded], limit: 10)
        XCTAssertTrue(oldBatches.isEmpty)
        let ackedHeld = await journal.recentStrapSeconds(stream: .hrSample, lastRecords: 100)
        XCTAssertEqual(ackedHeld["my-whoop"]?.contains(100), true, "acknowledged rows keep their source")

        try await journal.activate(configuration: .init(ownerId: stranger, sourceId: oldSource, deviceId: "my-whoop"),
                                   directory: directory)
        let strangerStats = await journal.stats()
        XCTAssertEqual(strangerStats.pendingRecords, 1, "another account's records stay where they are")
        await journal.deactivate()
    }

    // MARK: D2 capture missed while the runtime was down

    /// A store stand-in holding one heart-rate row every `step` seconds of `range`, journaled the way the
    /// seeder journals (in slices the staging buffer takes).
    private func replaySender(_ journal: CloudJournal, holds range: Range<Int>, step: Int = 1, sent: Box<[Int]>,
                              failAt: Int? = nil) -> (Int, Int) async -> CloudHistorySeeder.WindowOutcome {
        { from, to in
            if let failAt, (from...to).contains(failAt) { return .failed }
            let first = max(from, range.lowerBound)
            let aligned = (first + step - 1) / step * step
            let last = min(to, range.upperBound - 1)
            guard aligned <= last else { return .empty }
            let seconds = Array(stride(from: aligned, through: last, by: step))
            for slice in stride(from: 0, to: seconds.count, by: 2_000) {
                journal.submit(seconds[slice..<min(slice + 2_000, seconds.count)].map { self.hr(ts: $0) })
                _ = await journal.flush()
            }
            sent.value += seconds
            // What the journal's own drain loop commits between a submit and the flush is not in the flush's count.
            return .sent(seconds.count)
        }
    }

    func testAResumedSyncReplaysOnlyWhatTheRuntimeMissedAndNothingTwice() async throws {
        let defaults = isolatedDefaults()
        let gaps = CloudCaptureGaps(defaults: defaults)
        let t = 1_800_000_000
        let hour = 3_600
        let journal = try await makeJournal()
        let sent = Box<[Int]>([])
        let store = (t - 12 * hour)..<t
        let key = "seed-test"

        // The runtime first runs at t-10h; the first seeder pass sends its look-back hour.
        gaps.noteRuntimeStarted(now: t - 10 * hour)
        var committed = await CloudHistorySeeder.replay(key: key, deviceId: "my-whoop", lookbackSeconds: hour,
                                                        windowSeconds: hour, defaults: defaults, gaps: gaps,
                                                        now: t - 10 * hour, send: replaySender(journal, holds: store, sent: sent))
        XCTAssertEqual(committed, hour)

        // Live until t-6h, then signed out (or paused) for three hours. Meanwhile an offload banked hours the
        // strap had buffered out of range, for this strap and for another one.
        gaps.noteLive(now: t - 6 * hour)
        gaps.noteMissedHistory(deviceId: "my-whoop", from: t - 9 * hour, to: t - 8 * hour, now: t - 5 * hour)
        gaps.noteMissedHistory(deviceId: "other-strap", from: t - 9 * hour, to: t - 8 * hour, now: t - 5 * hour)
        gaps.noteRuntimeStarted(now: t - 3 * hour)

        committed = await CloudHistorySeeder.replay(key: key, deviceId: "my-whoop", lookbackSeconds: hour,
                                                    windowSeconds: hour, defaults: defaults, gaps: gaps, now: t,
                                                    send: replaySender(journal, holds: store, sent: sent))
        XCTAssertEqual(committed, 4 * hour, "the three hours down and the offloaded hour, nothing else")
        XCTAssertEqual(Set(sent.value).count, sent.value.count, "no second was handed over twice")
        XCTAssertFalse(sent.value.contains { (t - 3 * hour)..<t ~= $0 }, "what was journaled live is not sent again")

        let again = await CloudHistorySeeder.replay(key: key, deviceId: "my-whoop", lookbackSeconds: hour,
                                                    windowSeconds: hour, defaults: defaults, gaps: gaps, now: t + 60,
                                                    send: replaySender(journal, holds: store, sent: sent))
        XCTAssertEqual(again, 0, "a second run replays nothing")
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 5 * hour, "the journal holds each second once")
        let held = await journal.recentStrapSeconds(stream: .hrSample, lastRecords: 100_000)
        XCTAssertEqual(Set(held["my-whoop"] ?? []).count, held["my-whoop"]?.count, "no duplicate rows in the journal")
        await journal.deactivate()
    }

    func testAnInterruptedReplayResumesWhereItStoppedAndIsBoundedToAMonth() async throws {
        let defaults = isolatedDefaults()
        let gaps = CloudCaptureGaps(defaults: defaults)
        let t = 1_800_000_000
        let hour = 3_600
        let day = 86_400
        let journal = try await makeJournal()
        let sent = Box<[Int]>([])
        let key = "seed-resume"
        gaps.noteRuntimeStarted(now: t - 45 * day)
        _ = await CloudHistorySeeder.replay(key: key, deviceId: "my-whoop", lookbackSeconds: 0, windowSeconds: hour,
                                            defaults: defaults, gaps: gaps, now: t - 45 * day,
                                            send: replaySender(journal, holds: 0..<0, sent: sent))
        // Down for 45 days (the phone was signed out over a long trip).
        gaps.noteRuntimeStarted(now: t)
        let pending = gaps.pending(after: 0, deviceId: "my-whoop", now: t)
        XCTAssertEqual(pending.first?.from, t - CloudCaptureGaps.replayWindowSeconds, "never more than a month back")

        let store = (t - 31 * day)..<t
        let recent = (t - 2 * hour)
        let first = await CloudHistorySeeder.replay(key: key, deviceId: "my-whoop", lookbackSeconds: 0,
                                                    windowSeconds: 6 * hour, defaults: defaults, gaps: gaps, now: t,
                                                    send: replaySender(journal, holds: store, step: 600, sent: sent,
                                                                       failAt: recent))
        XCTAssertGreaterThan(first, 0)
        XCTAssertFalse(sent.value.contains { $0 < t - 30 * day }, "nothing older than the replay window")
        let beforeResume = sent.value.count
        let rest = await CloudHistorySeeder.replay(key: key, deviceId: "my-whoop", lookbackSeconds: 0,
                                                   windowSeconds: 6 * hour, defaults: defaults, gaps: gaps, now: t,
                                                   send: replaySender(journal, holds: store, step: 600, sent: sent))
        XCTAssertGreaterThan(rest, 0, "the window that failed is retried")
        XCTAssertEqual(Set(sent.value).count, sent.value.count, "and nothing before it is sent again")
        XCTAssertEqual(sent.value.count, 30 * day / 600, "the whole month, once")
        XCTAssertGreaterThan(sent.value.count, beforeResume)
        await journal.deactivate()
    }

    func testAnOffloadBankedWhileTheRuntimeIsDownIsNotedByItsOwnSeconds() {
        let gaps = CloudCaptureGaps(defaults: isolatedDefaults())
        let now = Int(Date().timeIntervalSince1970)
        gaps.noteRuntimeStarted(now: now - 3_000)
        gaps.noteLive(now: now - 2_000)
        var streams = Streams()
        streams.hr = [HRSample(ts: now - 1_500, bpm: 60), HRSample(ts: now - 1_400, bpm: 61)]
        streams.gravity = [GravitySample(ts: now - 1_600, x: 0, y: 0, z: 1, dynAccel: nil)]
        CloudCapture.noteMissedHistory(streams, localDeviceId: "My-Whoop", gaps: gaps)
        CloudCapture.noteMissedHistory(Streams(), localDeviceId: "my-whoop", gaps: gaps)
        let pending = gaps.pending(after: 0, deviceId: "my-whoop", now: now)
        XCTAssertEqual(pending.map { $0.from..<$0.to }, [(now - 1_600)..<(now - 1_399)],
                       "the chunk's earliest to latest second, under the store's id; an empty chunk notes nothing")
    }

    func testAnInstallThatNeverSyncedRecordsNoGapsAndAStartedGapIsNeverGrown() {
        let gaps = CloudCaptureGaps(defaults: isolatedDefaults())
        gaps.noteMissedHistory(deviceId: "my-whoop", from: 100, to: 200, now: 1_000)
        XCTAssertEqual(gaps.latestSeq, 0, "nothing is owed to an account never synced from here")
        gaps.noteRuntimeStarted(now: 1_000)
        XCTAssertEqual(gaps.latestSeq, 0, "the first start is not a gap")
        gaps.noteLive(now: 2_000)
        gaps.noteMissedHistory(deviceId: "my-whoop", from: 500, to: 600, now: 2_100)
        gaps.noteMissedHistory(deviceId: "my-whoop", from: 600, to: 700, now: 2_100)
        XCTAssertEqual(gaps.latestSeq, 1, "contiguous chunks extend one gap")
        gaps.noteRuntimeStarted(now: 3_000)
        gaps.noteMissedHistory(deviceId: "my-whoop", from: 700, to: 800, now: 3_100)
        let all = gaps.pending(after: 0, deviceId: "my-whoop", now: 3_100)
        XCTAssertEqual(all.map(\.seq), [1, 2, 3], "after a start, a gap a seeder may have replayed is closed")
        XCTAssertEqual(all.first.map { $0.from..<$0.to }, 500..<700)
    }

    func testTheRuntimeNotesTheSpanItWasDownAndCarriesAnEarlierSourceOnStart() async throws {
        // A receiver nobody listens on, and no account signed in on this test host, so nothing is ever sent.
        CloudPushSettings.bundleStringOverride = { key in
            switch key {
            case CloudPushSettings.endpointInfoKey: return "http://127.0.0.1:1/functions/v1/push"
            case CloudPushSettings.publishableKeyInfoKey: return "sb_publishable_runtime_test"
            default: return nil
            }
        }
        defer { CloudPushSettings.bundleStringOverride = nil }
        let defaults = isolatedDefaults()
        let identityStore = CloudPushIdentityStore(defaults: defaults, secrets: MemorySecretStore())
        let oldSource = "a0a0a0a0-a0a0-4a0a-8a0a-a0a0a0a0a0a0"
        let journal = CloudJournal()
        try await journal.activate(configuration: .init(ownerId: owner, sourceId: oldSource, deviceId: "my-whoop"),
                                   directory: directory)
        journal.submit([hr(ts: 1_700_000_000)])
        _ = await journal.flush()
        await journal.deactivate()

        let gaps = CloudCaptureGaps(defaults: defaults)
        let wentDown = Int(Date().timeIntervalSince1970) - 7_200
        gaps.noteLive(now: wentDown)
        let runtime = CloudPushRuntime(journal: journal, journalDirectory: directory, identityStore: identityStore,
                                       bundleIdentifier: "com.noop.tests.\(UUID().uuidString)")
        let identity = CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: UUID().uuidString,
                                         uploadToken: "noop_runtime")
        try runtime.start(identity: identity, deviceId: "my-whoop")
        let noted = await eventually { gaps.pending(after: 0, deviceId: "my-whoop").contains { $0.from == wentDown } }
        XCTAssertTrue(noted, "the two hours the runtime was down are a gap for the seeders")
        let adopted = await eventually { await journal.stats().pendingRecords == 1 }
        XCTAssertTrue(adopted, "the record the old source held is pending under the new one")
        await runtime.stop()
        XCTAssertGreaterThanOrEqual(gaps.liveThrough ?? 0, Int(Date().timeIntervalSince1970) - 5,
                                    "stopping marks the journal live up to now")
    }

    // MARK: upload-path data fixes

    func testContactIsJournaledOnlyWhenItChangesPerStrap() throws {
        let ledger = CloudContactLedger()
        func contactRows(_ contact: StandardHRContact, _ device: String, _ ts: Int) -> Int {
            CloudCapture.standardHRRecords(hr: 61, rr: [], contact: contact, family: .whoop5, at: ts, deviceId: device,
                                           receivedAtMs: ts * 1000, characteristic: "2A37", ledger: nil,
                                           contactLedger: ledger).filter { $0.stream == .event }.count
        }
        XCTAssertEqual(contactRows(.unsupported, "a", 1), 1, "the first reading opens with the strap's state")
        XCTAssertEqual(contactRows(.unsupported, "a", 2), 0)
        XCTAssertEqual(contactRows(.unsupported, "a", 3), 0)
        XCTAssertEqual(contactRows(.unsupported, "b", 3), 1, "per strap")
        XCTAssertEqual(contactRows(.supportedDetected, "a", 4), 1, "a change is journaled")
        XCTAssertEqual(contactRows(.supportedDetected, "a", 5), 0)
        XCTAssertTrue(StandardHRMapping.shouldRecordContact(previous: .unsupported, current: .supportedDetected),
                      "the same rule the local store uses")
        // The heart-rate row of every reading is still sent.
        let rows = CloudCapture.standardHRRecords(hr: 61, rr: [], contact: .supportedDetected, family: .whoop5, at: 6,
                                                  deviceId: "a", receivedAtMs: 6_000, characteristic: "2A37",
                                                  ledger: nil, contactLedger: ledger)
        XCTAssertEqual(rows.map(\.stream), [.hrSample])
        ledger.reset()
        XCTAssertEqual(contactRows(.supportedDetected, "a", 7), 1, "a new run opens with the current state again")
    }

    private func suspectFlags(_ records: [CloudJournalRecord]) throws -> [Int: Any] {
        var out: [Int: Any] = [:]
        for record in records where record.stream == .rrInterval {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
            let key = try XCTUnwrap(object["key"] as? [String: Any])
            let data = try XCTUnwrap(object["data"] as? [String: Any])
            out[try XCTUnwrap(key["ts"] as? Int)] = data["tsSuspect"]
        }
        return out
    }

    func testRRRowsCarryTheFillFlagTheStoreWritesForTheSameBeat() async throws {
        var streams = Streams()
        streams.hr = [HRSample(ts: 10, bpm: 70), HRSample(ts: 11, bpm: 120), HRSample(ts: 12, bpm: 70),
                      HRSample(ts: 13, bpm: 70), HRSample(ts: 14, bpm: 70)]
        streams.rr = [RRInterval(ts: 10, rrMs: 500, srcChannel: .whoop5Standard),     // fill: flagged
                      RRInterval(ts: 11, rrMs: 500, srcChannel: .whoop5Historical),   // 120 bpm: a real beat
                      RRInterval(ts: 12, rrMs: 857, srcChannel: .whoop5Standard),     // not 500 ms
                      RRInterval(ts: 13, rrMs: 500, srcChannel: .whoop4Standard),     // not a WHOOP 5 transport
                      RRInterval(ts: 14, rrMs: 500, srcChannel: .whoop5Historical),   // fill: flagged
                      RRInterval(ts: 15, rrMs: 500, srcChannel: .whoop5Historical)]   // no heart rate that second
        let records = CloudCapture.rows(from: streams, provenance: .history, family: .whoop5, wallClockRef: nil,
                                        deviceClockRef: nil, receivedAtMs: 0, characteristic: nil, deviceId: "d")
        let flags = try suspectFlags(records)
        XCTAssertEqual(flags[10] as? Int, 1)
        XCTAssertEqual(flags[14] as? Int, 1)
        for ts in [11, 12, 13, 15] { XCTAssertTrue(flags[ts] is NSNull, "ts \(ts) is not flagged, as on disk") }

        // The store's own rule on the same beats gives the same answer.
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(streams, deviceId: "d")
        let stored = try await store.rrSuspectRowsForTest(deviceId: "d")
        for row in stored {
            XCTAssertEqual(row.tsSuspect == 1, (flags[row.ts] as? Int) == 1, "ts \(row.ts) matches the stored flag")
        }

        // The live path takes the flag from the rate before the ledger drops a second it already sent.
        let ledger = CloudHeartRateLedger()
        _ = ledger.claim([HRSample(ts: 20, bpm: 70)], deviceId: "d")
        let live = CloudCapture.standardHRRecords(hr: 70, rr: [500], contact: nil, family: .whoop5, at: 20, deviceId: "d",
                                                  receivedAtMs: 20_000, characteristic: "2A37", ledger: ledger)
        XCTAssertFalse(live.contains { $0.stream == .hrSample }, "the second was already sent")
        XCTAssertEqual(try suspectFlags(live)[20] as? Int, 1)
    }
}
