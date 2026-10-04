import XCTest
@testable import NoopPush

/// Golden end-to-end contract for the `rawImuSession` object lane (CONTRACTS C1 + C9).
///
/// The golden fixture (`golden_imu_frames.json`) holds 12 contiguous WHOOP 5/MG raw-IMU frames
/// generated with a known LCG. This test walks the production decode path:
///   golden frame hex → 600 i16 axis-major columns → `PushRawImuRecord`
///   → `PushBinaryCodec.pack` (NPB1 kind=4) → decode → identical columns + ts
/// and then drives the real `PushCoordinator` with those rows to prove the cursor only advances
/// on a verified receipt (upload-verify report §4).
final class ImuObjectLaneIntegrationTests: XCTestCase {

    // MARK: - Golden helpers

    private static let imuBufferLength = 1244
    // FRAME-absolute offsets (Whoop5RawImu.swift:41-46): ts@15 u32 LE, countA@24, ax@28, ay@228,
    // az@428, countB@630, gx@640, gy@840, gz@1040; 100 i16 LE samples per axis.
    private static let tsOff = 15, axOff = 28, ayOff = 228, azOff = 428
    private static let countBOff = 630, gxOff = 640, gyOff = 840, gzOff = 1040
    private static let accelScale = 1.0 / 4096.0
    private static let gyroScale = 2000.0 / 32768.0

    private struct GoldenFrame {
        let baseTs: Int
        let columns: [Int16]   // 600 i16 axis-major
    }

    private func loadGoldenFrames() throws -> (frames: [GoldenFrame], expected: [String: Any]) {
        let framesURL = try XCTUnwrap(Bundle.module.url(forResource: "golden_imu_frames", withExtension: "json"))
        let expectedURL = try XCTUnwrap(Bundle.module.url(forResource: "golden_imu_expected", withExtension: "json"))
        let framesObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: framesURL)) as? [String: Any])
        let expected = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? [String: Any])
        let rawFrames = try XCTUnwrap(framesObject["frames"] as? [String])
        var out: [GoldenFrame] = []
        for raw in rawFrames {
            let bytes = [UInt8](hex: raw)
            XCTAssertEqual(bytes.count, Self.imuBufferLength, "golden frame must be 1244 bytes")
            let baseTs = Self.u32(bytes, Self.tsOff)
            var columns = [Int16](repeating: 0, count: 600)
            for (channelIndex, offset) in [Self.axOff, Self.ayOff, Self.azOff,
                                           Self.gxOff, Self.gyOff, Self.gzOff].enumerated() {
                for i in 0..<100 {
                    columns[channelIndex * 100 + i] = Self.i16(bytes, offset + 2 * i)
                }
            }
            out.append(GoldenFrame(baseTs: baseTs, columns: columns))
        }
        return (out, expected)
    }

    private func imuRow(_ frame: GoldenFrame) -> PushRawImuRecord {
        var data = Data(capacity: frame.columns.count * 2)
        for value in frame.columns {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return PushRawImuRecord(rowId: Int64(frame.baseTs), ts: Int64(frame.baseTs), columns: data)
    }

    /// Minimal NPB1 rawImuSession decoder (kind=4): magic "NPB1", version 1, kind 4, u32 count,
    /// then per record i64 rowId, i64 ts, u32 blob length, blob. Mirrors the worker-side decoder
    /// contract (upload-verify report §4 "NPB1 layout").
    private func unpackImu(_ bytes: Data) throws -> [PushRawImuRecord] {
        let data = [UInt8](bytes)
        var offset = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= data.count - offset else {
                throw PushProtocolException("truncated rawImuSession object")
            }
            defer { offset += count }
            return data[offset..<(offset + count)]
        }
        func le64(_ slice: ArraySlice<UInt8>) -> Int64 {
            slice.enumerated().reduce(0) { $0 | Int64($1.element) << ($1.offset * 8) }
        }
        func le32(_ slice: ArraySlice<UInt8>) -> Int {
            slice.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        }
        XCTAssertEqual(Data(try take(4)), PushBinaryCodec.magic, "NPB1 magic")
        XCTAssertEqual(Data(try take(1)), Data([1]), "format version")
        XCTAssertEqual(Data(try take(1)), Data([4]), "kind must be rawImuSession=4")
        let count = le32(try take(4))
        XCTAssertGreaterThan(count, 0)
        var records: [PushRawImuRecord] = []
        for _ in 0..<count {
            let rowId = le64(try take(8))
            let ts = le64(try take(8))
            let length = le32(try take(4))
            XCTAssertEqual(length, PushBinaryCodec.imuRecordPayloadBytes)
            records.append(PushRawImuRecord(rowId: rowId, ts: ts, columns: Data(try take(length))))
        }
        XCTAssertEqual(offset, data.count, "no trailing bytes")
        return records
    }

    // MARK: - Golden round-trip

    func testGoldenFramesSurviveNpb1RoundTrip() throws {
        let (frames, expected) = try loadGoldenFrames()
        XCTAssertEqual(frames.count, 12)
        XCTAssertEqual(expected["nFrames"] as? Int, 12)
        let baseTs = expected["baseTs"] as? Int
        XCTAssertEqual(frames.first?.baseTs, baseTs)

        // First-sample physical values (scaled) must match the golden expected values — this pins
        // the axis order and scales, i.e. that the columns really are ax,ay,az,gx,gy,gz at the
        // documented LSB scales.
        let first = frames[0].columns
        let firstSample: [String: Any] = try XCTUnwrap(expected["firstSample"] as? [String: Any])
        XCTAssertEqual(Double(first[0]) * Self.accelScale, try XCTUnwrap(firstSample["ax"] as? Double), accuracy: 1e-9)
        XCTAssertEqual(Double(first[100]) * Self.accelScale, try XCTUnwrap(firstSample["ay"] as? Double), accuracy: 1e-9)
        XCTAssertEqual(Double(first[200]) * Self.accelScale, try XCTUnwrap(firstSample["az"] as? Double), accuracy: 1e-9)
        XCTAssertEqual(Double(first[300]) * Self.gyroScale, try XCTUnwrap(firstSample["gx"] as? Double), accuracy: 1e-9)
        XCTAssertEqual(Double(first[400]) * Self.gyroScale, try XCTUnwrap(firstSample["gy"] as? Double), accuracy: 1e-9)
        XCTAssertEqual(Double(first[500]) * Self.gyroScale, try XCTUnwrap(firstSample["gz"] as? Double), accuracy: 1e-9)

        // pack → decode → identical columns + ts
        let rows = frames.map { .rawImuSession(imuRow($0)) as PushBinaryRow }
        let packed = try PushBinaryCodec.pack(table: .rawImuSession, rows: rows)
        XCTAssertEqual([UInt8](packed[0..<4]), [UInt8]("NPB1".utf8))
        let decoded = try unpackImu(packed)
        XCTAssertEqual(decoded.count, frames.count)
        for (record, frame) in zip(decoded, frames) {
            XCTAssertEqual(record.ts, Int64(frame.baseTs))
            XCTAssertEqual(record.rowId, Int64(frame.baseTs), "rowId mirrors ts")
            XCTAssertEqual(record.columns.count, PushBinaryCodec.imuRecordPayloadBytes)
            // Columns must be byte-identical after the round trip.
            var expectedData = Data(capacity: frame.columns.count * 2)
            for value in frame.columns {
                var le = value.littleEndian
                withUnsafeBytes(of: &le) { expectedData.append(contentsOf: $0) }
            }
            XCTAssertEqual(record.columns, expectedData)
        }

        // The object batch identity is deterministic and stable across builds for the golden rows.
        let batch = try PushProtocol.binaryObjectBatch(
            table: .rawImuSession, sourceId: sourceA, deviceId: "strap-a", startCursor: nil,
            rows: rows, protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes
        )
        XCTAssertEqual(batch.sampleCount, frames.count)
        XCTAssertEqual(batch.startTs, Int64(baseTs ?? 0))
        XCTAssertEqual(batch.endTs, Int64((baseTs ?? 0) + frames.count))
    }

    // MARK: - Coordinator integration: cursor advances only on a verified receipt

    func testCoordinatorAdvancesCursorOnlyAfterVerifiedReceipt() async throws {
        let (frames, _) = try loadGoldenFrames()
        let rows: [PushBinaryRow] = frames.prefix(5).map { .rawImuSession(imuRow($0)) }
        let lane = PushObjectLane(
            endpoint: "/api/push/objects", maxObjectBytes: Int64(PushProtocolLimits.maxObjectWireBytes),
            urlTtlSec: 3600, streams: [.rawImuSession]
        )

        // First pass: the receiver never acks. The cursor must NOT advance and the in-flight
        // record must be kept (uploaded), so the next pass resumes the same object.
        let progress = MemoryObjectProgress()
        let failingTransport = FakeObjectTransport(
            onIntent: { manifest in
                PushObjectIntent(objectId: manifest.objectId, objectKey: "k/unacked",
                                 uploadUrl: "https://b2.example/put", requiredHeaders: [:],
                                 expiresAt: nil, duplicate: false)
            },
            onUpload: { _, _ in },
            onComplete: { _ in
                throw PushTransportException(PushFailure.http(status: 503, receiverCode: "verification_pending"))
            }
        )
        let firstResult = await PushCoordinator(
            source: FakeImuSource(rows: rows),
            transport: failingTransport,
            progress: progress,
            sourceId: sourceA,
            receiptOwner: objectReceiptOwner,
            associateReceipt: { _, _, _ in XCTFail("receipt must not associate without a valid ack") },
        ).pushObjects(.rawImuSession, deviceId: "dev", lane: lane)
        guard case .rejected = firstResult else {
            return XCTFail("unacked object must be rejected, got \(firstResult)")
        }
        let cursorAfterFailure = try await progress.binaryCursor(table: .rawImuSession, deviceId: "dev")
        XCTAssertNil(cursorAfterFailure, "cursor must not advance without a verified receipt")
        let inFlight = try await progress.inFlightObject(table: .rawImuSession, deviceId: "dev")
        XCTAssertEqual(inFlight?.uploaded, true, "in-flight record survives a failed completion for resume")

        // Second pass: the receiver acks with a matching verified receipt. The cursor advances and
        // the in-flight record is cleared by the next cursor save.
        let batch = try PushProtocol.binaryObjectBatch(
            table: .rawImuSession, sourceId: sourceA, deviceId: "dev", startCursor: nil,
            rows: rows, protocolVersion: PushProtocol.objectVersion,
            decodedLimit: PushProtocolLimits.maxObjectDecodedBytes
        )
        let acknowledging = FakeObjectTransport(
            onIntent: { manifest in
                PushObjectIntent(objectId: manifest.objectId, objectKey: objectReceiptKey(batch),
                                 uploadUrl: "https://b2.example/put", requiredHeaders: [:],
                                 expiresAt: nil, duplicate: false)
            },
            onUpload: { _, _ in },
            onComplete: { object in
                PushObjectAck(objectId: object, status: "ready", objectKey: objectReceiptKey(batch),
                              duplicate: false, durabilityReceipt: try objectReceiptFixture(batch))
            }
        )
        let secondResult = await PushCoordinator(
            source: FakeImuSource(rows: rows),
            transport: acknowledging,
            progress: progress,
            sourceId: sourceA,
            receiptOwner: objectReceiptOwner,
            associateReceipt: { uploaded, acknowledgedRows, _ in
                XCTAssertEqual(uploaded.batchId, batch.batchId)
                XCTAssertEqual(acknowledgedRows.count, rows.count)
            },
        ).pushObjects(.rawImuSession, deviceId: "dev", lane: lane)
        guard case .accepted = secondResult else {
            return XCTFail("verified object must be accepted, got \(secondResult)")
        }
        let cursor = try await progress.binaryCursor(table: .rawImuSession, deviceId: "dev")
        let last = try XCTUnwrap(rows.last)
        let lastRecord: PushRawImuRecord
        guard case .rawImuSession(let record) = last else { return XCTFail("row kind") }
        lastRecord = record
        XCTAssertEqual(cursor?.rowId, lastRecord.rowId, "cursor advances to the last acknowledged row")
        let storedInFlight = try await progress.inFlightObject(table: .rawImuSession, deviceId: "dev")
        XCTAssertNil(storedInFlight, "in-flight record is released after a verified receipt")
    }
}

// MARK: - Helpers (mirrors PushObjectLaneTests.swift)

private let sourceA = "3a3486dd-5030-4e17-a00d-a781399890f9"

private let objectReceiptOwner = try! AccountScope(projectURL: "https://fixture.invalid", userID: "11111111-1111-4111-8111-111111111111")
private let objectReceiptCanonicalDevice = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
private func objectReceiptKey(_ batch: PushBinaryBatch) -> String {
    "v3/research/users/\(objectReceiptOwner.userID)/devices/\(objectReceiptCanonicalDevice)/\(batch.wireName)/fixture/verified"
}
private func objectReceiptFixture(_ batch: PushBinaryBatch) throws -> PushDurabilityReceipt {
    let object: [String: Any] = ["version": 1, "state": "verified_indexed",
        "receiptId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "ownerUserId": objectReceiptOwner.userID,
        "deviceId": objectReceiptCanonicalDevice,
        "objectId": batch.objectId, "batchId": batch.batchId, "sourceId": batch.sourceId,
        "stream": batch.wireName, "schemaVersion": 1,
        "objectKey": objectReceiptKey(batch),
        "contentSha256": batch.contentSha256, "wireSha256": batch.wireSHA256,
        "compressedBytes": batch.wireBytes, "uncompressedBytes": batch.uncompressedBytes,
        "verifiedAt": "2026-09-18T00:00:00Z", "indexedAt": "2026-09-18T00:00:01Z"]
    return try JSONDecoder().decode(PushDurabilityReceipt.self, from: JSONSerialization.data(withJSONObject: object))
}

private final class MemoryObjectProgress: PushProgressStore {
    private var inflight: [String: PushInFlightObject] = [:]
    private var cursors: [String: PushCursor] = [:]
    func knownDeviceIds() async throws -> Set<String> { [] }
    func rememberDeviceId(_ deviceId: String) async throws {}
    func cursor(table: PushAppendTable, deviceId: String) async throws -> PushCursor? { nil }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async throws {}
    func binaryCursor(table: PushBinaryTable, deviceId: String) async throws -> PushCursor? {
        cursors["\(table.wireName).\(deviceId)"]
    }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) async throws {
        cursors["\(table.wireName).\(deviceId)"] = cursor
        inflight.removeValue(forKey: "\(table.wireName).\(deviceId)")
    }
    func window(table: PushMutableTable, deviceId: String) async throws -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async throws {}
    func inFlightObject(table: PushBinaryTable, deviceId: String) async throws -> PushInFlightObject? {
        inflight["\(table.wireName).\(deviceId)"]
    }
    func saveInFlightObject(table: PushBinaryTable, deviceId: String, object: PushInFlightObject?) async throws {
        let key = "\(table.wireName).\(deviceId)"
        if let object { inflight[key] = object } else { inflight.removeValue(forKey: key) }
    }
}

private struct FakeImuSource: PushSnapshotSource {
    let rows: [PushBinaryRow]
    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] { ["dev"] }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? { nil }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] { [] }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? {
        rows.first { row in
            if case .rawImuSession(let r) = row { return r.rowId == rowId }
            return false
        }
    }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] {
        rows.filter { row in
            if case .rawImuSession(let r) = row { return r.rowId > afterRowId }
            return false
        }.prefix(limit).map { $0 }
    }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {}
}

private struct FakeObjectTransport: PushTransport {
    var onIntent: (PushObjectManifest) async throws -> PushObjectIntent = { _ in
        throw PushTransportException(PushFailure(code: .localData))
    }
    var onUpload: (PushObjectIntent, Data) async throws -> Void = { _, _ in }
    var onComplete: (String) async throws -> PushObjectAck = { _ in
        throw PushTransportException(PushFailure(code: .localData))
    }
    func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        throw PushTransportException(PushFailure(code: .localData))
    }
    func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) async throws -> PushObjectIntent {
        try await onIntent(manifest)
    }
    func uploadObject(_ intent: PushObjectIntent, body: Data) async throws {
        try await onUpload(intent, body)
    }
    func completeObject(objectId: String, lane: PushObjectLane) async throws -> PushObjectAck {
        try await onComplete(objectId)
    }
}

// MARK: - Hex / LE helpers

private extension Array where Element == UInt8 {
    init(hex: String) {
        var value = hex
        if value.hasPrefix("0x") { value.removeFirst(2) }
        var out: [UInt8] = []
        out.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2, limitedBy: value.endIndex) ?? value.endIndex
            if let byte = UInt8(value[index..<next], radix: 16) { out.append(byte) }
            index = next
        }
        self = out
    }
}

private extension ImuObjectLaneIntegrationTests {
    static func u32(_ f: [UInt8], _ o: Int) -> Int {
        Int(f[o]) | (Int(f[o + 1]) << 8) | (Int(f[o + 2]) << 16) | (Int(f[o + 3]) << 24)
    }
    static func i16(_ f: [UInt8], _ o: Int) -> Int16 {
        let v = Int(f[o]) | (Int(f[o + 1]) << 8)
        return Int16(truncatingIfNeeded: v >= 32768 ? v - 65536 : v)
    }
}
