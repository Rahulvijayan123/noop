import Foundation
import XCTest
import CryptoKit
import NoopPush
import WhoopProtocol
import WhoopStore
@testable import Strand

/// The phone half of the anchored PPG transport (Spec 01 §3, docs/model-integration/ppg-transport.md):
/// `PpgObjectSource` over the history store, its two gates (the default-off flag and a receiver that
/// negotiated 1.5), what it refuses to send, and how re-upload stays bounded without repeating a second.
///
/// The end-to-end test banks the shared golden's `phone_real_frames` rows in a real `WhoopStore`, runs one
/// object through the real `PushCoordinator` and `ImuObjectTransport` against a stubbed receiver, and checks
/// the uploaded bytes equal the golden byte for byte. The receiver's Deno tests and the worker's
/// `PpgTransportTests` read that same golden, so the three stacks are chained by one fixture.
final class PpgObjectLaneTests: XCTestCase {
    static let sourceId = "7d1e2f3a-4b5c-4d6e-8f70-8192a3b4c5d6"
    static let ownerId = "11111111-1111-4111-8111-111111111111"
    static let cloudDeviceId = "whoop-ppg-golden"
    static let now: Int64 = 1_780_930_000

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ppg-object-lane-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ReceiverStub.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - golden

    private static func goldenURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/NoopPush/Tests/NoopPushTests/Resources/ppg_anchor_v3_golden.json")
    }

    private func goldenVector(_ name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.goldenURL())) as? [String: Any]
        let vectors = try XCTUnwrap(object?["vectors"] as? [[String: Any]])
        return try XCTUnwrap(vectors.first { $0["name"] as? String == name })
    }

    /// The golden's phone rows exactly as the phone banks them: deltas, burst counter and base code.
    private func goldenStoreRows() throws -> [PpgWaveformSample] {
        let rows = try XCTUnwrap(try goldenVector("phone_real_frames")["rows"] as? [[String: Any]])
        return try rows.map { row in
            let hex = try XCTUnwrap(row["samples_hex"] as? String)
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(try XCTUnwrap(UInt8(hex[index..<next], radix: 16)))
                index = next
            }
            let deltas = stride(from: 0, to: bytes.count, by: 2).map {
                Int(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8))
            }
            return PpgWaveformSample(ts: try XCTUnwrap(row["ts"] as? Int), samples: deltas,
                                     burstIndex: row["burstIndex"] as? Int, baseCode: row["anchor"] as? Int)
        }
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    // MARK: - helpers

    private func deltas(_ seed: Int) -> [Int] { (0..<24).map { (($0 * 37 + seed) % 400) - 200 } }

    private func row(_ ts: Int, anchored: Bool = true, burst: Int? = 3) -> PpgWaveformSample {
        PpgWaveformSample(ts: ts, samples: deltas(ts), burstIndex: burst, baseCode: anchored ? 400_000 + ts % 1000 : nil)
    }

    private func limits(_ version: String = PushProtocol.ppgAnchorVersion,
                        bytes: Int = 4 * 1_048_576) -> PushSourceReadLimits {
        PushSourceReadLimits(maximumDecodedBytes: bytes, protocolVersion: version, shouldContinue: { true })
    }

    private func makeSource(_ store: any PpgObjectReading, now: Int64 = PpgObjectLaneTests.now,
                            lookback: Int64 = 14 * 24 * 3600,
                            sentThrough: @escaping @Sendable (String) async throws -> Int64? = { _ in nil },
                            allowed: @escaping @Sendable () -> Bool = { true }) -> PpgObjectSource {
        PpgObjectSource(store: store, deviceId: { Self.cloudDeviceId }, storeDeviceId: { _ in "my-whoop" },
                        now: { now }, lookbackSeconds: lookback, sentThrough: sentThrough, uploadAllowed: allowed)
    }

    private func page(_ source: PpgObjectSource, after cursor: Int64, limit: Int = 5_001,
                      version: String = PushProtocol.ppgAnchorVersion) async throws -> PushBinaryPage {
        try await source.binaryPage(table: .ppgWaveformSample, deviceId: Self.cloudDeviceId, afterRowId: cursor,
                                    limit: limit, limits: limits(version))
    }

    private func records(_ page: PushBinaryPage) -> [PushPpgWaveformRecord] {
        page.rows.compactMap { if case .ppgWaveform(let record) = $0 { return record } else { return nil } }
    }

    private func capabilities(_ version: String, streams: [String] = ["ppgWaveformSample", "rawImuSession"]) throws
        -> PushCapabilities {
        try PushCapabilities.parse(JSONSerialization.data(withJSONObject: [
            "type": "capabilities", "protocolVersion": version,
            "receiverStateId": Self.sourceId, "streams": streams,
            "objectLane": ["endpoint": "/functions/v1/push/objects", "maxObjectBytes": 8_000_000, "streams": streams],
        ]))
    }

    // MARK: - flag off

    func testTheFlagIsANoopPreferenceThatDefaultsOff() {
        XCTAssertEqual(PpgObjectUploadFeature.enabledKey, "noop.cloud.ppgAnchorUpload")
        let previous = UserDefaults.standard.object(forKey: PpgObjectUploadFeature.enabledKey)
        defer { UserDefaults.standard.set(previous, forKey: PpgObjectUploadFeature.enabledKey) }
        UserDefaults.standard.removeObject(forKey: PpgObjectUploadFeature.enabledKey)
        XCTAssertFalse(PpgObjectUploadFeature.isEnabled, "absent means off")
        PpgObjectUploadFeature.setEnabled(true)
        XCTAssertTrue(PpgObjectUploadFeature.isEnabled)
        PpgObjectUploadFeature.setEnabled(false)
        XCTAssertNil(UserDefaults.standard.object(forKey: PpgObjectUploadFeature.enabledKey))
    }

    func testFlagOffStagesNothingAndTheLaneOffersExactlyThePre15List() async throws {
        let store = FakePpgStore(rows: (1_780_900_000..<1_780_900_100).map { row($0) })
        let source = makeSource(store, allowed: { false })
        let result = try await page(source, after: 0)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(store.reads, 0, "a switched-off source never even reads the store")
        XCTAssertFalse(PpgObjectUploadFeature.laneOpen(featureEnabled: false, capabilities: try capabilities("1.5")))

        // The object lane's offer with the flag off is the one it sent before 1.5 existed, so a receiver
        // that advertises 1.5 still negotiates 1.3 with it and every raw-IMU object is byte-identical.
        let off = makeTransport(offersPpgAnchor: false)
        let negotiated = try await negotiatedVersion(off)
        XCTAssertEqual(ReceiverStub.requests.last?.request.value(forHTTPHeaderField: "noop-push-accept-version"),
                       "1.4,1.3,1.2,1.1,1.0")
        XCTAssertEqual(negotiated, "1.3")
    }

    func testFlagOnOffers15AndAnAdvertisingReceiverNegotiatesIt() async throws {
        let on = makeTransport(offersPpgAnchor: true)
        let negotiated = try await negotiatedVersion(on)
        XCTAssertEqual(ReceiverStub.requests.last?.request.value(forHTTPHeaderField: "noop-push-accept-version"),
                       PushProtocol.capabilitiesAcceptVersions)
        XCTAssertEqual(negotiated, "1.5")
        ReceiverStub.advertisesPpgAnchor = false
        let notAdvertised = try await negotiatedVersion(on)
        XCTAssertEqual(notAdvertised, "1.3", "a receiver without NOOP_PUSH_ADVERTISE_PPG_ANCHOR stays at 1.3")
    }

    // MARK: - flag on, receiver older than 1.5

    func testAReceiverBelow15GetsNothingEvenWithTheFlagOn() async throws {
        for version in ["1.2", "1.3", "1.4"] {
            XCTAssertFalse(PpgObjectUploadFeature.laneOpen(featureEnabled: true, capabilities: try capabilities(version)))
            let store = FakePpgStore(rows: (1_780_900_000..<1_780_900_100).map { row($0) })
            let result = try await page(makeSource(store), after: 0, version: version)
            XCTAssertTrue(result.rows.isEmpty, "no format below 3 carries the anchor (\(version))")
            XCTAssertEqual(store.reads, 0)
        }
        XCTAssertFalse(PpgObjectUploadFeature.laneOpen(featureEnabled: true,
                                                       capabilities: try capabilities("1.5", streams: ["rawImuSession"])),
                       "1.5 without the stream on the object lane is not an opening")
        XCTAssertTrue(PpgObjectUploadFeature.laneOpen(featureEnabled: true, capabilities: try capabilities("1.5")))
    }

    // MARK: - flag on, receiver 1.5: the real phone code path against the shared golden

    func testBankedRowsUploadThroughTheRealLaneAsTheSharedGoldenBytes() async throws {
        let store = try await WhoopStore.inMemory()
        var streams = Streams()
        streams.ppgWaveform = try goldenStoreRows()
        try await store.insert(streams, deviceId: "my-whoop")
        let source = makeSource(WhoopStorePpgReader(store: { store }))
        let golden = try goldenVector("phone_real_frames")
        let manifest = try XCTUnwrap(golden["manifest"] as? [String: Any])

        let transport = makeTransport(offersPpgAnchor: true)
        let caps = try await transport.capabilities()
        guard case .available(let negotiated) = caps else { return XCTFail("capabilities") }
        XCTAssertTrue(PpgObjectUploadFeature.laneOpen(featureEnabled: true, capabilities: negotiated))
        let progress = try ImuPushProgressStore(directory: directory)
        let coordinator = PushCoordinator(
            source: source, transport: transport, progress: progress, sourceId: Self.sourceId,
            destinationStillCurrent: { true },
            receiptOwner: try AccountScope(projectURL: "https://example.supabase.co", userID: Self.ownerId),
            objectProtocolVersion: negotiated.protocolVersion,
            associateReceipt: { _, _, _ in }, wakeBudget: PushWakeBudget(duration: 20))
        let lane = try XCTUnwrap(negotiated.objectLane)

        let result = await coordinator.pushObjects(.ppgWaveformSample, deviceId: Self.cloudDeviceId, lane: lane)
        guard case .accepted = result else { return XCTFail("expected an accepted object, got \(result)") }
        let sent = try XCTUnwrap(ReceiverStub.manifests.last)
        for key in ["batchId", "objectId", "contentSha256", "startTs", "endTs", "sampleCount", "protocolVersion",
                    "uncompressedBytes", "compressedBytes", "stream", "deviceId", "sourceId"] {
            XCTAssertEqual(sent[key] as? NSObject, manifest[key] as? NSObject, key)
        }
        let body = try XCTUnwrap(ReceiverStub.uploads.last)
        XCTAssertEqual(body.base64EncodedString(), golden["wire_base64"] as? String,
                       "the phone's wire bytes are the golden the receiver and the worker test against")
        XCTAssertEqual(hex(Data(SHA256.hash(data: body))), golden["wire_sha256"] as? String)

        // The cursor moved only on the verified receipt, to the last second sent; nothing goes up twice.
        let cursor = try await progress.binaryCursor(table: .ppgWaveformSample, deviceId: Self.cloudDeviceId)
        let end = try XCTUnwrap(golden["end_cursor"] as? [String: Any])
        XCTAssertEqual(cursor?.rowId, (end["rowId"] as? NSNumber)?.int64Value)
        XCTAssertEqual(cursor?.naturalKeyFingerprint, end["keySha256"] as? String)
        let again = await coordinator.pushObjects(.ppgWaveformSample, deviceId: Self.cloudDeviceId, lane: lane)
        guard case .noData = again else { return XCTFail("expected no data after the receipt, got \(again)") }
        XCTAssertEqual(ReceiverStub.uploads.count, 1)

        // The decoded object still carries what the store had, and nothing it did not.
        let decoded = try PushBinaryCodec.unpackPpgRecords(try XCTUnwrap(Data(hexString: golden["decoded_hex"] as? String)))
        XCTAssertEqual(decoded.map(\.anchor), try goldenStoreRows().map { $0.baseCode.map(UInt32.init) })
        XCTAssertTrue(decoded.allSatisfy { $0.clockSource == .strapRecordSecond && $0.subsecQ15 == nil
            && $0.frontEndFlags == nil && $0.recordIndex == nil })
    }

    // MARK: - what is never sent as anchored

    func testARowWithoutAnAnchorIsNeverSentAsAnchored() async throws {
        let base = 1_780_900_000
        let rows = [row(base, anchored: false), row(base + 1), row(base + 2, anchored: false), row(base + 3),
                    PpgWaveformSample(ts: base + 4, samples: [], burstIndex: 3, baseCode: 1),
                    PpgWaveformSample(ts: base + 5, samples: deltas(1), burstIndex: 3, baseCode: -1),
                    PpgWaveformSample(ts: base + 6, samples: deltas(1), burstIndex: 3, baseCode: Int(UInt32.max) + 1),
                    PpgWaveformSample(ts: base + 7, samples: deltas(1) + [40_000], burstIndex: 3, baseCode: 9),
                    PpgWaveformSample(ts: base + 8, samples: deltas(1), burstIndex: Int(Int32.max) + 1, baseCode: 9)]
        let store = FakePpgStore(rows: rows)
        let source = makeSource(store)
        let sent = records(try await page(source, after: 0))
        XCTAssertEqual(sent.map(\.ts), [Int64(base + 1), Int64(base + 3)])
        XCTAssertTrue(sent.allSatisfy { $0.anchor != nil && $0.clockSource == .strapRecordSecond })
        let legacy = try await source.binaryRecordAt(table: .ppgWaveformSample, deviceId: Self.cloudDeviceId,
                                                     rowId: Int64(base))
        XCTAssertNil(legacy)
        // The deltas go out exactly as banked (i16 LE), the base code as the u32 anchor.
        XCTAssertEqual(sent.first?.samples, Data(deltas(base + 1).flatMap { value -> [UInt8] in
            let bits = UInt16(bitPattern: Int16(value)); return [UInt8(bits & 0xFF), UInt8(bits >> 8)]
        }))
        XCTAssertEqual(sent.first?.anchor, UInt32(400_000 + (base + 1) % 1000))
    }

    func testALongAnchorlessStretchIsCrossedInBoundedStepsNotSentOrStuckOn() async throws {
        let base = 1_780_000_000
        let legacy = (0..<(PpgObjectSource.scanChunkRows * PpgObjectSource.maxScanChunksPerCall + 500))
            .map { row(base + $0, anchored: false) }
        let anchored = (0..<10).map { row(base + 200_000 + $0) }
        let store = FakePpgStore(rows: legacy + anchored)
        let source = makeSource(store, now: Int64(base + 300_000))
        let first = try await page(source, after: 0)
        XCTAssertTrue(first.rows.isEmpty, "one call reads a bounded number of chunks")
        XCTAssertLessThanOrEqual(store.reads, PpgObjectSource.maxScanChunksPerCall)
        let second = try await page(source, after: 0)
        XCTAssertEqual(records(second).map(\.ts), anchored.map { Int64($0.ts) },
                       "the next call resumes where the skip stopped and finds the anchored rows")
    }

    // MARK: - re-upload: bounded, no second twice

    func testPagingByCursorSendsEveryAnchoredSecondExactlyOnceWithinTheHorizon() async throws {
        let now = Int64(1_781_000_000)
        let lookback: Int64 = 2 * 24 * 3600
        let tooOld = (0..<50).map { row(Int(now - lookback) - 1_000 + $0) }
        // Bursts of 40 s every ~20 min across the horizon, a little of it anchor-less.
        var live: [PpgWaveformSample] = []
        var start = Int(now - lookback) + 60
        while start < Int(now) - 2 * 3600 {
            live += (0..<40).map { row(start + $0, anchored: ($0 + start) % 17 != 0) }
            start += 1_240
        }
        let store = FakePpgStore(rows: tooOld + live)
        let source = makeSource(store, now: now, lookback: lookback)
        var cursor: Int64 = 0
        var sent: [Int64] = []
        var objects = 0
        while objects < 100 {
            let next = try await page(source, after: cursor, limit: 1_001)
            guard !next.rows.isEmpty else { break }
            let rows = records(next)
            XCTAssertLessThan(rows.last!.ts - rows.first!.ts, PpgObjectSource.targetObjectWindowSeconds)
            sent += rows.map(\.ts)
            cursor = rows.last!.ts   // what a verified receipt advances it to
            objects += 1
        }
        XCTAssertEqual(sent, live.filter { $0.baseCode != nil }.map { Int64($0.ts) })
        XCTAssertEqual(Set(sent).count, sent.count, "no second twice")
        XCTAssertTrue(sent.allSatisfy { $0 > now - lookback }, "nothing older than the horizon")
    }

    func testAPrunedCursorRowNeverRestartsTheUploadFromTheHorizon() async throws {
        let base = 1_780_900_000
        let store = FakePpgStore(rows: (0..<100).map { row(base + $0) })
        // The coordinator restarts from an empty cursor when the row its cursor names is gone; the durable
        // cursor's second still fences what went up.
        let source = makeSource(store, sentThrough: { _ in Int64(base + 49) })
        let next = records(try await page(source, after: 0))
        XCTAssertEqual(next.first?.ts, Int64(base + 50))
        XCTAssertEqual(next.count, 50)
    }

    func testAnOpenHourWaitsForTheOffloadAndALimitSplitsWithoutOverlap() async throws {
        let base = 1_780_900_000
        let store = FakePpgStore(rows: (0..<120).map { row(base + $0) })
        let open = try await page(makeSource(store, now: Int64(base + 600)), after: 0)
        XCTAssertTrue(open.rows.isEmpty, "the hour may still be arriving with the offload")
        let settled = makeSource(store, now: Int64(base) + 2 * PpgObjectSource.targetObjectWindowSeconds)
        let firstHalf = try await page(settled, after: 0, limit: 60)
        XCTAssertEqual(records(firstHalf).count, 60)
        XCTAssertTrue(firstHalf.hasMore)
        let secondHalf = try await page(settled, after: records(firstHalf).last!.ts, limit: 60)
        XCTAssertEqual(records(secondHalf).map(\.ts), (60..<120).map { Int64(base + $0) })
        // A newer second past the hour closes it at once, without waiting for the clock.
        store.rows.append(row(base + Int(PpgObjectSource.targetObjectWindowSeconds) + 5))
        let closed = try await page(makeSource(store, now: Int64(base + 600)), after: 0)
        XCTAssertEqual(records(closed).count, 120)
        XCTAssertTrue(closed.hasMore)
    }

    func testTheCursorFingerprintIsThePpgIdentitySoTheCoordinatorKeepsIt() async throws {
        let store = FakePpgStore(rows: [row(1_780_900_000)])
        let source = makeSource(store)
        let fingerprint = try await source.binaryFingerprintAt(table: .ppgWaveformSample, deviceId: Self.cloudDeviceId,
                                                               rowId: 1_780_900_000,
                                                               protocolVersion: PushProtocol.ppgAnchorVersion)
        let expected = Data(SHA256.hash(data: Data("ppgWaveformSample\n\(Self.cloudDeviceId)\n1780900000\n3".utf8)))
        XCTAssertEqual(fingerprint, hex(expected))
    }

    // MARK: - fixtures

    private func makeTransport(offersPpgAnchor: Bool) -> ImuObjectTransport {
        ImuObjectTransport(
            endpoint: URL(string: "https://receiver.example/functions/v1/push")!,
            identity: {
                CloudPushIdentity(ownerId: Self.ownerId, sourceId: Self.sourceId,
                                  tokenId: "33333333-3333-4333-8333-333333333333", uploadToken: "noop-test-token")
            },
            session: ReceiverStub.session(),
            offersPpgAnchor: { offersPpgAnchor })
    }

    private func negotiatedVersion(_ transport: ImuObjectTransport) async throws -> String? {
        guard case .available(let caps) = try await transport.capabilities() else { return nil }
        return caps.protocolVersion
    }
}

// MARK: - Fakes

private final class FakePpgStore: PpgObjectReading, @unchecked Sendable {
    var rows: [PpgWaveformSample]
    private(set) var reads = 0

    init(rows: [PpgWaveformSample]) { self.rows = rows }

    func readPpgRecords(deviceId: String, fromTs: Int64, toTs: Int64, limit: Int) async throws -> [PpgWaveformSample] {
        reads += 1
        return Array(rows.filter { Int64($0.ts) >= fromTs && Int64($0.ts) <= toTs }
            .sorted { $0.ts < $1.ts }.prefix(limit))
    }
}

/// A receiver over URLProtocol: negotiates like `negotiateProtocol` (1.5 first only while advertised), takes
/// an object intent, the presigned PUT and the completion, and answers with a receipt for exactly the bytes
/// it was sent, so the coordinator's own receipt validation runs.
private final class ReceiverStub: URLProtocol {
    static var requests: [(request: URLRequest, body: Data?)] = []
    static var manifests: [[String: Any]] = []
    static var uploads: [Data] = []
    static var advertisesPpgAnchor = true

    static func reset() {
        requests = []; manifests = []; uploads = []; advertisesPpgAnchor = true
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiverStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.readBody(request)
        Self.requests.append((request, body))
        let path = request.url?.path ?? ""
        var response: [String: Any] = [:]
        switch (request.httpMethod ?? "", path) {
        case ("GET", _):
            let offered = (request.value(forHTTPHeaderField: "noop-push-accept-version") ?? "").split(separator: ",").map(String.init)
            let order = (Self.advertisesPpgAnchor ? ["1.5"] : []) + ["1.3", "1.2", "1.1", "1.0"]
            let version = order.first(where: offered.contains) ?? "1.0"
            let streams = ["ppgWaveformSample", "rawImuSession"]
            response = ["type": "capabilities", "protocolVersion": version,
                        "receiverStateId": PpgObjectLaneTests.sourceId, "streams": streams,
                        "objectLane": ["endpoint": "/functions/v1/push/objects", "maxObjectBytes": 8_000_000,
                                       "urlTtlSec": 900, "streams": streams]]
        case ("POST", "/functions/v1/push/objects"):
            let manifest = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]) ?? [:]
            Self.manifests.append(manifest)
            response = ["type": "objectIntent", "protocolVersion": manifest["protocolVersion"] ?? "",
                        "objectId": manifest["objectId"] ?? "", "objectKey": Self.objectKey(manifest),
                        "duplicate": false, "uploadUrl": "https://bucket.example/put-object",
                        "requiredHeaders": ["content-type": "application/octet-stream"]]
        case ("PUT", _):
            Self.uploads.append(body ?? Data())
        default:
            let manifest = Self.manifests.last ?? [:]
            let wire = Self.uploads.last ?? Data()
            response = ["type": "objectAck", "protocolVersion": manifest["protocolVersion"] ?? "",
                        "objectId": manifest["objectId"] ?? "", "status": "ready",
                        "objectKey": Self.objectKey(manifest), "duplicate": false,
                        "durabilityReceipt": [
                            "version": 1, "state": "verified_indexed",
                            "receiptId": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                            "ownerUserId": PpgObjectLaneTests.ownerId,
                            "deviceId": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                            "objectId": manifest["objectId"] ?? "", "batchId": manifest["batchId"] ?? "",
                            "sourceId": manifest["sourceId"] ?? "", "stream": manifest["stream"] ?? "",
                            "schemaVersion": PushProtocol.schemaVersion(stream: manifest["stream"] as? String ?? "",
                                                                        protocolVersion: manifest["protocolVersion"] as? String ?? ""),
                            "objectKey": Self.objectKey(manifest),
                            "contentSha256": manifest["contentSha256"] ?? "",
                            "wireSha256": Data(SHA256.hash(data: wire)).map { String(format: "%02x", $0) }.joined(),
                            "compressedBytes": wire.count, "uncompressedBytes": manifest["uncompressedBytes"] ?? 0,
                            "verifiedAt": "2026-10-08T00:00:00Z", "indexedAt": "2026-10-08T00:00:01Z",
                        ]]
        }
        let data = response.isEmpty ? Data() : ((try? JSONSerialization.data(withJSONObject: response)) ?? Data())
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func objectKey(_ manifest: [String: Any]) -> String {
        "v3/research/users/\(PpgObjectLaneTests.ownerId)/devices/dddddddd-dddd-4ddd-8ddd-dddddddddddd/"
            + "\(manifest["stream"] as? String ?? "")/\(manifest["objectId"] as? String ?? "").bin.gz"
    }

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private extension Data {
    init?(hexString: String?) {
        guard let hexString, hexString.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
