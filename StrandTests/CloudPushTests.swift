import XCTest
import NoopPush
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
                                         fleetToken: "noop_test",
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
                                              fleetToken: "noop_test", directory: directory,
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
        let repo = ServerScoreRepository(endpoint: nil, fleetToken: "", directory: directory,
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

    // MARK: - capture seam

    func testCaptureIsANoOpWhenCloudIsNotRunning() {
        // The BLE path calls these unconditionally; with no runtime they must report a skip rather
        // than throw or block, which is what keeps an offline install byte-for-byte unchanged.
        let skip = CloudCapture.recordStandardHR(hr: 70, rr: [900], contact: .supportedDetected,
                                                 family: .whoop4, at: 1_700_000_000,
                                                 deviceId: "my-whoop", receivedAtMs: 1_700_000_000_000)
        XCTAssertEqual(skip, .notRunning)
    }
}
