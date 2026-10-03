import Foundation
import Foundation
import XCTest
import CryptoKit
import NoopPush
@testable import Strand

/// App-side tests for the rawImuSession object lane (CONTRACTS C1 + C10, upload-verify report §4).
///
/// What is covered here is the part the fork owns: the source's paging/cursor/fingerprint logic
/// against the C10 read API, the durable cursor + in-flight progress store, the transport's
/// request shapes, and the journal's NDJSON-sealing exclusion. The HTTP round trip and the
/// `PushCoordinator` state machine are covered by NoopPush's own tests
/// (`ImuObjectLaneIntegrationTests`), including the golden NPB1 round trip.
final class ImuObjectLaneTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imu-object-lane-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - helpers

    private func columns(_ seed: Int16) -> [Int16] {
        (0..<600).map { Int16(truncatingIfNeeded: seed &+ Int16($0)) }
    }

    private func records(ts range: ClosedRange<Int64>, receivedAtMs: Int64 = 0) -> [ImuSourceRecord] {
        range.map { ImuSourceRecord(ts: $0, receivedAtMs: receivedAtMs, columns: columns(Int16(truncatingIfNeeded: $0))) }
    }

    private func makeSource(store: FakeImuStore, now: Int64 = 1_758_000_000, lookback: Int64 = 14 * 24 * 3600) -> ImuObjectSource {
        ImuObjectSource(store: store, deviceId: { "dev" }, now: { now }, lookbackSeconds: lookback)
    }

    private func sourceLimits() -> PushSourceReadLimits {
        PushSourceReadLimits(maximumDecodedBytes: PushProtocolLimits.maxObjectDecodedBytes,
                             protocolVersion: PushProtocol.objectVersion,
                             shouldContinue: { true })
    }

    // MARK: - source paging / window bounding

    func testBinaryPagePagesStrictlyAfterCursor() async throws {
        let store = FakeImuStore(records: records(ts: 1_000...1_399))
        let source = makeSource(store: store, now: 50_000)
        let page = try await source.binaryPage(table: .rawImuSession, deviceId: "dev", afterRowId: 999,
                                               limit: 5_001, limits: sourceLimits())
        XCTAssertEqual(page.rows.count, 300, "target window is 300 s")
        XCTAssertTrue(page.hasMore, "more records remain beyond the 300 s window")
        var previousRowID: Int64 = 0
        for row in page.rows {
            guard case .rawImuSession(let record) = row else { return XCTFail("row kind") }
            XCTAssertEqual(record.rowId, record.ts, "rowId mirrors ts")
            XCTAssertGreaterThan(record.rowId, previousRowID, "strict rowid order required by the codec")
            previousRowID = record.rowId
            XCTAssertEqual(record.columns.count, PushBinaryCodec.imuRecordPayloadBytes)
        }
        guard case .rawImuSession(let firstRecord) = page.rows[0] else { return XCTFail("row kind") }
        XCTAssertEqual(firstRecord.ts, 1_000)
        guard case .rawImuSession(let lastRecord) = page.rows[299] else { return XCTFail("row kind") }
        XCTAssertEqual(lastRecord.ts, 1_299)
    }

    func testCursorIsExclusiveAndWindowRestartsAfterIt() async throws {
        let store = FakeImuStore(records: records(ts: 1_000...1_399))
        let source = makeSource(store: store, now: 50_000)
        // Cursor at 1_100: the next page must start at 1_101 and contain the following 300 s.
        let page = try await source.binaryPage(table: .rawImuSession, deviceId: "dev", afterRowId: 1_100,
                                               limit: 5_001, limits: sourceLimits())
        XCTAssertEqual(page.rows.count, 299)
        guard case .rawImuSession(let first) = page.rows[0] else { return XCTFail("row kind") }
        XCTAssertEqual(first.ts, 1_101)
        XCTAssertFalse(page.hasMore)
    }

    func testFreshCursorProbeFindsOldestRecords() async throws {
        // Records live at epoch seconds; an empty cursor must not scan from ts=0.
        let store = FakeImuStore(records: records(ts: 4_000...4_299))
        let source = makeSource(store: store, now: 5_000, lookback: 3_000)
        let page = try await source.binaryPage(table: .rawImuSession, deviceId: "dev", afterRowId: 0,
                                               limit: 5_001, limits: sourceLimits())
        guard case .rawImuSession(let first) = page.rows.first else { return XCTFail("row kind") }
        XCTAssertEqual(first.ts, 4_000, "fresh cursor anchors at the oldest stored record")
        XCTAssertEqual(page.rows.count, 300)
    }

    func testProbeSpansGapsBeyondTheOneHourHardWindow() async throws {
        // A gap longer than the 1 h hard window between the cursor and the next records must still
        // be found by the bounded forward probe.
        let store = FakeImuStore(records: records(ts: 1_000...1_200) + records(ts: 5_000...5_299))
        let source = makeSource(store: store, now: 50_000)
        let page = try await source.binaryPage(table: .rawImuSession, deviceId: "dev", afterRowId: 1_200,
                                               limit: 5_001, limits: sourceLimits())
        XCTAssertEqual(page.rows.count, 300)
        guard case .rawImuSession(let first) = page.rows.first else { return XCTFail("row kind") }
        XCTAssertEqual(first.ts, 5_000)
        XCTAssertFalse(page.hasMore)
    }

    func testEmptyStoreReturnsNoData() async throws {
        let store = FakeImuStore(records: [])
        let source = makeSource(store: store, now: 5_000, lookback: 3_000)
        let page = try await source.binaryPage(table: .rawImuSession, deviceId: "dev", afterRowId: 0,
                                               limit: 5_001, limits: sourceLimits())
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    // MARK: - P2-5 flush-before-read / cursor never skips un-flushed seconds

    func testPendingTailFlushedBeforePageAndNeverSkippedByCursor() async throws {
        // P2-5: a second still buffered in the store's RAM pending tail (its flush failed) is NOT
        // durable. The source must not page at or past it, so the coordinator's cursor only ever
        // advances over durable seconds; once the flush succeeds the buffered second uploads.
        let store = FakeImuStore(records: records(ts: 1_000...1_299), pendingFrontier: 1_100)
        let source = makeSource(store: store, now: 50_000)

        // First page: only seconds BELOW the buffered second may be sent (cursor stops at 1_099).
        let page = try await source.binaryPage(table: .rawImuSession, deviceId: "dev", afterRowId: 999,
                                               limit: 5_001, limits: sourceLimits())
        XCTAssertEqual(page.rows.count, 100)
        guard case .rawImuSession(let last) = try XCTUnwrap(page.rows.last) else { return XCTFail("row kind") }
        XCTAssertEqual(last.ts, 1_099, "cursor must not advance at or past the buffered second")

        // The next page is fenced by the still-buffered second: nothing may be sent past it.
        let blocked = try await source.binaryPage(table: .rawImuSession, deviceId: "dev", afterRowId: 1_099,
                                                  limit: 5_001, limits: sourceLimits())
        XCTAssertTrue(blocked.rows.isEmpty)

        // The flush succeeds: the previously-buffered second is now durable and gets uploaded.
        store.pendingFrontier = nil
        let flushed = try await source.binaryPage(table: .rawImuSession, deviceId: "dev", afterRowId: 1_099,
                                                  limit: 5_001, limits: sourceLimits())
        XCTAssertEqual(flushed.rows.count, 200)
        guard case .rawImuSession(let first) = try XCTUnwrap(flushed.rows.first) else { return XCTFail("row kind") }
        XCTAssertEqual(first.ts, 1_100, "the previously-buffered second uploads after its flush")
    }

    func testDistantBufferedSecondDoesNotFenceOlderDurableData() async throws {
        // P2-5: the flush frontier only fences reads AT the buffered second. A far-future buffered
        // second (the normal recent-tail case) must not block older durable data from uploading.
        let store = FakeImuStore(records: records(ts: 1_000...1_299), pendingFrontier: 1_758_000_000)
        let source = makeSource(store: store, now: 50_000)
        let page = try await source.binaryPage(table: .rawImuSession, deviceId: "dev", afterRowId: 999,
                                               limit: 5_001, limits: sourceLimits())
        XCTAssertEqual(page.rows.count, 300)
        guard case .rawImuSession(let last) = try XCTUnwrap(page.rows.last) else { return XCTFail("row kind") }
        XCTAssertEqual(last.ts, 1_299)
    }

    // MARK: - cursor / fingerprint

    func testBinaryFingerprintMatchesRawImuSessionIdentity() async throws {
        let store = FakeImuStore(records: records(ts: 1_000...1_099))
        let source = makeSource(store: store, now: 50_000)
        guard let row = try await source.binaryRecordAt(table: .rawImuSession, deviceId: "dev", rowId: 1_000) else {
            return XCTFail("record 1_000 must be readable")
        }
        let fingerprint = try PushProtocol.binaryKeyFingerprint(table: .rawImuSession, deviceId: "dev", row: row)
        // C1: endCursor fingerprint = sha256("rawImuSession\n{deviceId}\n{ts}").
        let expected = SHA256.hash(data: Data("rawImuSession\ndev\n1000".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fingerprint, expected)

        let atCursor = try await source.binaryFingerprintAt(table: .rawImuSession, deviceId: "dev",
                                                            rowId: 1_000, protocolVersion: PushProtocol.objectVersion)
        XCTAssertEqual(atCursor, expected)
        // A row the store no longer has yields no fingerprint, so the coordinator restarts the cursor.
        let missing = try await source.binaryFingerprintAt(table: .rawImuSession, deviceId: "dev",
                                                           rowId: 9_999, protocolVersion: PushProtocol.objectVersion)
        XCTAssertNil(missing)
    }

    // MARK: - durable progress store

    func testProgressStoreCursorAndInFlightSurviveReopen() async throws {
        let store = try ImuPushProgressStore(directory: directory)
        try await store.saveInFlightObject(
            table: .rawImuSession, deviceId: "dev",
            object: PushInFlightObject(objectId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                                       objectKey: "v3/research/users/u/devices/d/rawImuSession/k.bin.zst",
                                       contentSha256: "ab" + String(repeating: "0", count: 62), uploaded: true)
        )
        let cursor = PushCursor(rowId: 1_758_000_300,
                                naturalKeyFingerprint: String(repeating: "c", count: 64))
        try await store.saveBinaryCursor(table: .rawImuSession, deviceId: "dev", cursor: cursor)

        // Reopen on the same file: state must survive relaunch.
        let reopened = try ImuPushProgressStore(directory: directory)
        let loaded = try await reopened.binaryCursor(table: .rawImuSession, deviceId: "dev")
        XCTAssertEqual(loaded?.rowId, cursor.rowId)
        XCTAssertEqual(loaded?.naturalKeyFingerprint, cursor.naturalKeyFingerprint)
        // saveBinaryCursor releases the in-flight object for the same (stream, device).
        let inFlight = try await reopened.inFlightObject(table: .rawImuSession, deviceId: "dev")
        XCTAssertNil(inFlight)
    }

    func testInFlightObjectResumesAcrossReopen() async throws {
        let store = try ImuPushProgressStore(directory: directory)
        try await store.saveInFlightObject(
            table: .rawImuSession, deviceId: "dev",
            object: PushInFlightObject(objectId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                                       objectKey: "k/resume",
                                       contentSha256: "cd" + String(repeating: "0", count: 62),
                                       uploaded: false)
        )
        let reopened = try ImuPushProgressStore(directory: directory)
        let loaded = try await reopened.inFlightObject(table: .rawImuSession, deviceId: "dev")
        XCTAssertEqual(loaded?.objectId, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        XCTAssertEqual(loaded?.objectKey, "k/resume")
        XCTAssertEqual(loaded?.uploaded, false)
        try await reopened.saveInFlightObject(table: .rawImuSession, deviceId: "dev", object: nil)
        let cleared = try await reopened.inFlightObject(table: .rawImuSession, deviceId: "dev")
        XCTAssertNil(cleared)
    }

    // MARK: - journal sealing exclusion

    func testRawImuSessionIsExcludedFromNdjsonSealingLikeRawBatch() async throws {
        let journal = CloudJournal()
        try await journal.activate(
            configuration: .init(ownerId: "11111111-1111-4111-8111-111111111111",
                                 sourceId: "22222222-2222-4222-8222-222222222222",
                                 deviceId: "my-whoop"),
            policy: CloudJournal.SealPolicy(), directory: directory)
        journal.submit([imuJournalRecord(ts: 1_700_000_000)])
        journal.submit([hrJournalRecord(ts: 1_700_000_000)])
        let committed = await journal.flush()
        XCTAssertEqual(committed, 2)

        let farFutureMs = Int(Date().timeIntervalSince1970 * 1000) + 60_000
        let candidates = try await journal.sealCandidates(limit: 8, nowMs: farFutureMs)
        // rawImuSession is archive/object-lane only: it must never appear as an NDJSON seal group.
        XCTAssertEqual(candidates.map(\.stream), [.hrSample])
        // Both rows stay pending; the object lane releases rawImuSession rows by cursor, never by seal.
        let stats = await journal.stats()
        XCTAssertEqual(stats.pendingRecords, 2)
    }

    private func imuJournalRecord(ts: Int) -> CloudJournalRecord {
        CloudJournalRecord(stream: .rawImuSession, encoding: .jsonRow, provenance: .live,
                           receivedAtMs: ts * 1000, strapTs: ts,
                           payload: Data("{\"stream\":\"rawImuSession\"}".utf8))
    }

    private func hrJournalRecord(ts: Int) -> CloudJournalRecord {
        let payload = try! PushProtocol.canonicalJson(.map([
            "key": .map(["ts": .int(Int64(ts))]),
            "data": .map(["bpm": .int(Int64(62))]),
        ])).data(using: .utf8)!
        return CloudJournalRecord(stream: .hrSample, encoding: .jsonRow, provenance: .live,
                                  receivedAtMs: ts * 1000, strapTs: ts, payload: payload)
    }

    // MARK: - transport request shapes

    func testCreateObjectIntentRequestShape() async throws {
        let stub = ObjectLaneStub.self
        stub.reset()
        let manifest = try makeManifest()
        stub.responseProvider = { _ in try! self.intentResponse(objectId: manifest.objectId) }

        let transport = makeTransport(session: ObjectLaneStub.session())
        let intent = try await transport.createObjectIntent(manifest, lane: lane())
        XCTAssertEqual(intent.objectId, manifest.objectId)

        let (request, body) = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://receiver.example/functions/v1/push/objects")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop-test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-noop-fleet-token"), "noop-fleet")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "noop-push-accept-version"), PushProtocol.capabilitiesAcceptVersions)
        XCTAssertEqual(body, try manifest.encode())
    }

    func testUploadObjectSendsPresignedPutWithRequiredHeaders() async throws {
        let stub = ObjectLaneStub.self
        stub.reset()
        stub.status = 200

        let transport = makeTransport(session: ObjectLaneStub.session())
        let intent = PushObjectIntent(
            objectId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            objectKey: "v3/research/users/u/devices/d/rawImuSession/k.bin.zst",
            uploadUrl: "https://bucket.example/put-object",
            requiredHeaders: ["content-type": "application/octet-stream"],
            expiresAt: nil, duplicate: false
        )
        try await transport.uploadObject(intent, body: Data([0x01, 0x02, 0x03]))

        let (request, body) = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://bucket.example/put-object")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/octet-stream")
        XCTAssertEqual(body, Data([0x01, 0x02, 0x03]))
    }

    func testCompleteObjectRequestShape() async throws {
        let stub = ObjectLaneStub.self
        stub.reset()
        stub.response = try ackResponse()

        let transport = makeTransport(session: ObjectLaneStub.session())
        let objectId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let ack = try await transport.completeObject(objectId: objectId, lane: lane())
        XCTAssertEqual(ack.objectId, objectId)
        XCTAssertEqual(ack.status, "ready")

        let (request, _) = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://receiver.example/functions/v1/push/objects/\(objectId)/complete")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop-test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-noop-fleet-token"), "noop-fleet")
    }

    func testConflictMapsToReceiverCodeAndIsThrown() async throws {
        let stub = ObjectLaneStub.self
        stub.reset()
        stub.status = 409
        stub.response = Data("""
        {"type":"error","protocolVersion":"1.2","code":"object_id_conflict"}
        """.utf8)

        let transport = makeTransport(session: ObjectLaneStub.session())
        do {
            _ = try await transport.createObjectIntent(try makeManifest(), lane: lane())
            return XCTFail("409 must throw")
        } catch let error as PushTransportException {
            XCTAssertEqual(error.failure.receiverCode, "object_id_conflict")
            XCTAssertEqual(error.failure.httpStatus, 409)
        }
    }

    // MARK: - fixtures

    private func makeTransport(session: URLSession) -> ImuObjectTransport {
        ImuObjectTransport(
            endpoint: URL(string: "https://receiver.example/functions/v1/push")!,
            fleetToken: "noop-fleet",
            identity: {
                CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
                                  sourceId: "22222222-2222-4222-8222-222222222222",
                                  tokenId: "33333333-3333-4333-8333-333333333333",
                                  uploadToken: "noop-test-token")
            },
            session: session
        )
    }

    private func lane() -> PushObjectLane {
        PushObjectLane(endpoint: "/functions/v1/push/objects", maxObjectBytes: 8_000_000,
                       urlTtlSec: 900, streams: [.rawImuSession])
    }

    private func makeManifest() throws -> PushObjectManifest {
        var data = Data(count: PushBinaryCodec.imuRecordPayloadBytes)
        for index in 0..<PushBinaryCodec.imuColumnsPerRecord {
            let value = Int16(truncatingIfNeeded: index)
            data[index * 2] = UInt8(truncatingIfNeeded: value)
            data[index * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        let row = PushRawImuRecord(rowId: 1_700_000_000, ts: 1_700_000_000, columns: data)
        let batch = try PushProtocol.binaryObjectBatch(
            table: .rawImuSession, sourceId: "22222222-2222-4222-8222-222222222222",
            deviceId: "dev", startCursor: nil, rows: [.rawImuSession(row)],
            protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes
        )
        return PushObjectManifest(batch: batch)
    }

    private func intentResponse(objectId: String) throws -> Data {
        let object: [String: Any] = [
            "type": "objectIntent", "protocolVersion": PushProtocol.objectVersion,
            "objectId": objectId,
            "objectKey": "v3/research/users/u/devices/d/rawImuSession/\(objectId).bin.zst",
            "duplicate": false,
            "uploadUrl": "https://bucket.example/put-object",
            "requiredHeaders": ["content-type": "application/octet-stream"],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func ackResponse() throws -> Data {
        let object: [String: Any] = [
            "type": "objectAck", "protocolVersion": PushProtocol.objectVersion,
            "objectId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "status": "ready", "objectKey": "v3/research/users/u/devices/d/rawImuSession/k.bin.zst",
            "duplicate": false,
            "durabilityReceipt": [
                "version": 1, "state": "verified_indexed",
                "receiptId": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                "ownerUserId": "11111111-1111-4111-8111-111111111111",
                "deviceId": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                "objectId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "batchId": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
                "sourceId": "22222222-2222-4222-8222-222222222222",
                "stream": "rawImuSession", "schemaVersion": 1,
                "objectKey": "v3/research/users/u/devices/d/rawImuSession/k.bin.zst",
                "contentSha256": String(repeating: "a", count: 64),
                "wireSha256": String(repeating: "b", count: 64),
                "compressedBytes": 1200, "uncompressedBytes": 1210,
                "verifiedAt": "2026-09-18T00:00:00Z", "indexedAt": "2026-09-18T00:00:01Z",
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

// MARK: - Fakes

private final class FakeImuStore: ImuObjectReading, @unchecked Sendable {
    var records: [ImuSourceRecord]
    /// First non-durable (still-buffered) second, simulating a failed flush in the real store's
    /// RAM pending tail. `flushPendingFor` returns it and `readImuRecords` never yields it
    /// (mirrors the real store: buffered rows are not on disk until their flush succeeds).
    var pendingFrontier: Int64?

    init(records: [ImuSourceRecord], pendingFrontier: Int64? = nil) {
        self.records = records
        self.pendingFrontier = pendingFrontier
    }

    func readImuRecords(deviceId: String, fromTs: Int64, toTs: Int64) async throws -> [ImuSourceRecord] {
        records.filter { $0.ts >= fromTs && $0.ts <= toTs && (pendingFrontier == nil || $0.ts < pendingFrontier!) }
    }

    func flushPendingFor(deviceId: String) async throws -> Int64? { pendingFrontier }
}

/// URLProtocol stub that records every request (including its body) and returns a canned
/// response, so the real request → parse path runs with no network (pattern from
/// CloudPushTests.ScoreStub).
private final class ObjectLaneStub: URLProtocol {
    static var requests: [(request: URLRequest, body: Data?)] = []
    static var response: Data = Data()
    static var status: Int = 200
    static var responseProvider: ((URLRequest) -> Data?)?

    static func reset() {
        requests = []
        response = Data()
        status = 200
        responseProvider = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append((request, Self.readBody(request)))
        let body = Self.responseProvider?(request) ?? Self.response
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 8192
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObjectLaneStub.self]
        return URLSession(configuration: configuration)
    }
}
