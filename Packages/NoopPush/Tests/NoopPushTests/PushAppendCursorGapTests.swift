import XCTest
@testable import NoopPush

/// RR provenance promotion moves an already-sent row to MAX(rowid)+1. When that row was the saved cursor,
/// the fingerprint probe finds nothing at the cursor rowid; the lane must resume there instead of at zero.
final class PushAppendCursorGapTests: XCTestCase {
    private let sourceID = "11111111-1111-4111-8111-111111111111"
    private func coordinator(_ source: any PushSnapshotSource, _ fixture: CursorGapFixture) -> PushCoordinator {
        PushCoordinator(source: source, transport: fixture, progress: fixture, sourceId: sourceID)
    }

    func testPromotedCursorRowResumesAfterVacatedRowIdAndReexportsOnlyTheMovedRow() async throws {
        let fixture = CursorGapFixture(timestamps: [1, 2])
        guard case .accepted = await coordinator(fixture, fixture).pushAppend(.rrInterval, deviceId: "device") else {
            return XCTFail("first page should be accepted")
        }
        let first = await fixture.sent[0]
        await fixture.append(timestamp: 3)
        await fixture.promote(rowId: 2)

        guard case .accepted = await coordinator(fixture, fixture).pushAppend(.rrInterval, deviceId: "device") else {
            return XCTFail("resumed page should be accepted")
        }
        let second = await fixture.sent[1]
        XCTAssertEqual(second.startCursor, first.endCursor, "a vacated cursor slot must keep the durable position")
        let resent = await fixture.sentRowIDs[1]
        XCTAssertEqual(resent, [3, 4], "only rows above the vacated slot, including the promoted row, are sent")
    }

    func testAccountFenceForwardsVacatedProbe() async throws {
        let fixture = CursorGapFixture(timestamps: [1, 2])
        let owner = try AccountScope(projectURL: "https://fixture.invalid", userID: "22222222-2222-4222-8222-222222222222")
        let admission = try AccountPushAdmission(context: .init(scope: owner, generation: UUID()), captureScope: owner,
            sourceID: sourceID, isCurrent: { _ in true })
        let fenced = AccountFencedSnapshot(source: fixture, admission: admission)
        _ = await coordinator(fenced, fixture).pushAppend(.rrInterval, deviceId: "device")
        await fixture.append(timestamp: 3)
        await fixture.promote(rowId: 2)
        _ = await coordinator(fenced, fixture).pushAppend(.rrInterval, deviceId: "device")
        let resent = await fixture.sentRowIDs.last
        XCTAssertEqual(resent, [3, 4])
    }

    func testReplacedRowOrCursorAboveMaximumStillRestartsFromZero() async throws {
        for mutation in [CursorGapFixture.Mutation.replaceCursorRow, .deleteTail] {
            let fixture = CursorGapFixture(timestamps: [1, 2])
            _ = await coordinator(fixture, fixture).pushAppend(.rrInterval, deviceId: "device")
            await fixture.apply(mutation)
            guard case .accepted = await coordinator(fixture, fixture).pushAppend(.rrInterval, deviceId: "device") else {
                return XCTFail("restarted page should be accepted for \(mutation)")
            }
            let second = await fixture.sent[1]
            XCTAssertNil(second.startCursor, "\(mutation) cannot prove the cursor slot was vacated")
            let resent = await fixture.sentRowIDs[1]
            XCTAssertEqual(resent.first, 1, "\(mutation) must restart at the table head")
        }
    }

    func testAdaptersWithoutGapProbeKeepRestartBehavior() async throws {
        let fixture = CursorGapFixture(timestamps: [1, 2])
        let legacy = LegacyGapSource(fixture: fixture)
        _ = await coordinator(legacy, fixture).pushAppend(.rrInterval, deviceId: "device")
        await fixture.append(timestamp: 3)
        await fixture.promote(rowId: 2)
        _ = await coordinator(legacy, fixture).pushAppend(.rrInterval, deviceId: "device")
        let resent = await fixture.sentRowIDs.last
        XCTAssertEqual(resent, [1, 3, 4])
    }
}

private actor CursorGapFixture: PushSnapshotSource, PushProgressStore, PushTransport {
    enum Mutation { case replaceCursorRow, deleteTail }
    private(set) var rows: [PushAppendRecord]
    private(set) var sent: [PushBatch] = []
    private(set) var sentRowIDs: [[Int64]] = []
    private var saved: PushCursor?

    init(timestamps: [Int64]) {
        rows = timestamps.enumerated().map { CursorGapFixture.record(rowId: Int64($0.offset + 1), ts: $0.element, source: 6) }
    }
    static func record(rowId: Int64, ts: Int64, source: Int64) -> PushAppendRecord {
        .init(rowId: rowId, key: ["ts": .int(ts), "rrMs": .int(800), "seq": .int(0)],
              data: ["ord": .int(0), "srcChannel": .int(source), "tsSuspect": .bool(false)])
    }
    func append(timestamp: Int64) {
        rows.append(Self.record(rowId: (rows.map(\.rowId).max() ?? 0) + 1, ts: timestamp, source: 6))
    }
    /// Mirrors StreamStore's promote UPDATE: same natural key, new provenance, rowid = MAX(rowid) + 1.
    func promote(rowId: Int64) {
        guard let index = rows.firstIndex(where: { $0.rowId == rowId }) else { return }
        let moved = rows.remove(at: index)
        rows.append(Self.record(rowId: (rows.map(\.rowId).max() ?? 0) + 1, ts: moved.key["ts"]!.int64Value!, source: 5))
    }
    func apply(_ mutation: Mutation) {
        switch mutation {
        case .replaceCursorRow: rows = [Self.record(rowId: 1, ts: 10, source: 6), Self.record(rowId: 2, ts: 20, source: 6)]
        case .deleteTail: rows.removeAll { $0.rowId == 2 }
        }
    }

    func knownDeviceIds(capabilities: PushCapabilities) -> [String] { ["device"] }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) -> PushAppendRecord? {
        rows.first { $0.rowId == rowId }
    }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushAppendRecord] {
        Array(rows.filter { $0.rowId > afterRowId }.sorted { $0.rowId < $1.rowId }.prefix(limit))
    }
    func appendRowIdVacated(table: PushAppendTable, rowId: Int64) -> Bool {
        !rows.contains { $0.rowId == rowId } && (rows.map(\.rowId).max() ?? 0) > rowId
    }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) -> [PushMutableRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushBinaryRow] { [] }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) {}

    func knownDeviceIds() -> Set<String> { ["device"] }
    func rememberDeviceId(_ deviceId: String) {}
    func cursor(table: PushAppendTable, deviceId: String) -> PushCursor? { saved }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) { saved = cursor }
    func binaryCursor(table: PushBinaryTable, deviceId: String) -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) {}
    func window(table: PushMutableTable, deviceId: String) -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) {}

    func post(_ batch: PushBatch) throws -> PushTransportResponse {
        sent.append(batch)
        let lines = String(decoding: batch.body, as: UTF8.self).split(separator: "\n").dropFirst()
        sentRowIDs.append(try lines.map { line in
            let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let ts = ((record["key"] as? [String: Any])?["ts"] as? NSNumber)?.int64Value
            return rows.first { $0.key["ts"]?.int64Value == ts }?.rowId ?? -1
        })
        let end = batch.endCursor!
        return .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
            "protocolVersion": batch.protocolVersion, "batchId": batch.batchId, "stream": batch.table.wireName,
            "deviceId": batch.deviceId, "acceptedRows": batch.recordCount, "status": "accepted",
            "endCursor": ["rowId": end.rowId, "keySha256": end.naturalKeyFingerprint],
        ]))
    }
    func postBinary(_ batch: PushBinaryBatch) throws -> PushTransportResponse { throw PushProtocolException("unexpected binary") }
}

/// An adapter that predates the gap probe inherits the protocol default.
private struct LegacyGapSource: PushSnapshotSource {
    let fixture: CursorGapFixture
    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] { ["device"] }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? {
        await fixture.appendRecordAt(table: table, deviceId: deviceId, rowId: rowId)
    }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] {
        await fixture.appendRows(table: table, deviceId: deviceId, afterRowId: afterRowId, limit: limit)
    }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] { [] }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {}
}
