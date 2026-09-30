import XCTest
@testable import NoopPush

final class PushDeviceRotationTests: XCTestCase {
    private struct Saved: Codable { let index: Int; let fingerprint: String? }
    private let caps = PushCapabilities(appendTables: [.hrSample], mutableTables: [])
    private func coordinator(_ source: RotationFixture) -> PushCoordinator {
        PushCoordinator(source: source, transport: source, progress: source,
                        sourceId: "11111111-1111-4111-8111-111111111111")
    }

    func testGrowingDiscoveryAfterRelaunchRestartsCycleBeforeNewLeadingSourceCanBeSkipped() async throws {
        let old = RotationFixture(["B","C","D","E","F"])
        let first = await coordinator(old).pushKnownDevices(maxDevices: 4, capabilities: caps)
        let firstVisits = await old.visited
        XCTAssertEqual(firstVisits, ["B","C","D","E"])
        XCTAssertEqual(first.nextDeviceIndex, 4)
        // Restore only the captured checkpoint into a fresh coordinator/process fixture.
        let saved = try JSONEncoder().encode(Saved(index: first.nextDeviceIndex, fingerprint: first.deviceListFingerprint))
        let checkpoint = try JSONDecoder().decode(Saved.self, from: saved)
        let expanded = RotationFixture(["A","B","C","D","E","F","G","H"])
        let second = await coordinator(expanded).pushKnownDevices(startDeviceIndex: checkpoint.index,
            expectedDeviceListFingerprint: checkpoint.fingerprint, maxDevices: 4, capabilities: caps)
        let restartedVisits = await expanded.visited
        XCTAssertEqual(restartedVisits, ["A","B","C","D"])
        XCTAssertEqual(second.nextDeviceIndex, 4, "changed membership must not falsely complete the old cycle")
        XCTAssertNotEqual(second.deviceListFingerprint, first.deviceListFingerprint)
        let third = await coordinator(expanded).pushKnownDevices(startDeviceIndex: second.nextDeviceIndex,
            expectedDeviceListFingerprint: second.deviceListFingerprint, maxDevices: 4, capabilities: caps)
        XCTAssertEqual(third.nextDeviceIndex, 0)
        let completedVisits = await expanded.visited
        XCTAssertEqual(completedVisits, ["A","B","C","D","E","F","G","H"])
    }

    func testLegacyCheckpointWithoutFingerprintRestartsAndSameSortedMembershipResumes() async {
        let f = RotationFixture(["H","G","F","E","D","C","B","A"])
        let legacy = await coordinator(f).pushKnownDevices(startDeviceIndex: 4, maxDevices: 4, capabilities: caps)
        let first = await f.visited
        XCTAssertEqual(first, ["A","B","C","D"])
        let reordered = RotationFixture(["B","D","F","H","G","E","C","A"])
        let resumed = await coordinator(reordered).pushKnownDevices(startDeviceIndex: legacy.nextDeviceIndex,
            expectedDeviceListFingerprint: legacy.deviceListFingerprint, maxDevices: 4, capabilities: caps)
        let rest = await reordered.visited
        XCTAssertEqual(rest, ["E","F","G","H"])
        XCTAssertEqual(resumed.deviceListFingerprint, legacy.deviceListFingerprint)
        XCTAssertEqual(resumed.nextDeviceIndex, 0)
    }

    func testBootstrapDeferralRetainsWorkWithoutInventingDatabaseFailureOrRotationProof() async {
        let f = RotationFixture([], deferred: true)
        let result = await coordinator(f).pushKnownDevices(startDeviceIndex: 4,
            expectedDeviceListFingerprint: String(repeating: "a", count: 64), maxDevices: 4, capabilities: caps)
        XCTAssertTrue(result.hasRetryableFailure); XCTAssertTrue(result.hasMoreAppendRows)
        XCTAssertEqual(result.rejectedBatches, 0); XCTAssertNil(result.failure)
        XCTAssertNil(result.deviceListFingerprint)
        let visited = await f.visited
        XCTAssertTrue(visited.isEmpty)
    }

    func testEverySavedLanePositionHasCircularFreshAndRawServiceBounds() {
        let lanes = PushLaneRotation.lanes
        XCTAssertEqual(lanes.count, 176)
        let requirements: [(PushSourceCommit.Kind, String, Int)] = [
            (.freshAppend, "hrSample", 4), (.freshAppend, "gravitySample", 4),
            (.binary, "rawBatch", 8)
        ] + PushAppendTable.allCases.filter { $0 != .hrSample && $0 != .gravitySample }
            .map { (.freshAppend, $0.wireName, 44) }
        for start in lanes.indices {
            for (kind, table, bound) in requirements {
                XCTAssertTrue((0..<bound).contains { offset in
                    let lane = lanes[(start + offset) % lanes.count]
                    return lane.0 == kind && lane.1 == table
                }, "No \(kind)/\(table) within \(bound) eligible turns from \(start)")
            }
        }
        for table in PushAppendTable.allCases {
            XCTAssertEqual(lanes.filter { $0.0 == .append && $0.1 == table.wireName }.count, 1)
        }
        for table in PushMutableTable.allCases {
            XCTAssertEqual(lanes.filter { $0.0 == .mutable && $0.1 == table.wireName }.count, 1)
        }
        for table in PushBinaryTable.allCases where table != .rawBatch {
            XCTAssertEqual(lanes.filter { $0.0 == .binary && $0.1 == table.wireName }.count, 1)
        }
    }

    func testOneRequestRelaunchesKeepPerDeviceFairnessAndPendingSelectionIdentity() async throws {
        let fixture = RotationFixture(["A", "B", "C"])
        let pending = ["A", "B", "C"].flatMap { device in
            var seen = Set<String>()
            return PushLaneRotation.lanes.compactMap { kind, table -> PushPendingLane? in
                let id = device + "/" + kind.rawValue + "/" + table
                guard seen.insert(id).inserted else { return nil }
                return .init(selectionID: id, kind: kind, table: table, deviceID: device)
            }
        }
        struct Position: Codable { var device = 0; var lane = 0; var recovery = 0; var fingerprint: String? }
        var position = Position()
        let records = RotationServices()
        for _ in 0..<(176 * 3 * 2) {
            position = try JSONDecoder().decode(Position.self, from: JSONEncoder().encode(position))
            let budget = PushWakeBudget(maximumRequests: 1)
            let run = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
                sourceId: "11111111-1111-4111-8111-111111111111", wakeBudget: budget)
                .pushKnownDevices(startDeviceIndex: position.device, startLaneIndex: position.lane,
                    startRecoveryIndex: position.recovery, expectedDeviceListFingerprint: position.fingerprint,
                    capabilities: .all, binaryEnabled: true, pendingLanes: pending, resumePreparedLane: { lane in
                        XCTAssertTrue(budget.admitRequest(bytes: 1))
                        await records.record(lane)
                        return .accepted(batchId: lane.selectionID, recordCount: 1, hasMore: true, batchCount: 1)
                    })
            XCTAssertEqual(run.acceptedBatches, 1, "the original per-wake request cap remains binding")
            position = .init(device: run.nextDeviceIndex, lane: run.nextLaneIndex,
                recovery: run.nextRecoveryIndex, fingerprint: run.deviceListFingerprint)
        }
        let visits = await records.values
        XCTAssertEqual(Set(visits.map(\.selectionID)), Set(pending.map(\.selectionID)))
        for device in ["A", "B", "C"] {
            let services = visits.filter { $0.deviceID == device }
            for (kind, table, bound) in [(PushSourceCommit.Kind.freshAppend, "hrSample", 4),
                                       (.freshAppend, "gravitySample", 4), (.binary, "rawBatch", 8)] {
                let indices = services.indices.filter { services[$0].kind == kind && services[$0].table == table }
                XCTAssertGreaterThan(indices.count, 3)
                XCTAssertTrue(zip(indices, indices.dropFirst()).allSatisfy { $1 - $0 <= bound })
            }
        }
        let writes = await fixture.sourceProgressWrites
        XCTAssertEqual(writes, 0, "scheduling/replay must not synthesize a source receipt or advance a cursor")
    }

    func testPriorScheduleFingerprintResetsOnlySchedulingBeforePreparedReplay() async throws {
        let fixture = RotationFixture(["A", "B"]), records = RotationServices()
        let oldFingerprint = PushDurabilityReceipt.sha256(try JSONEncoder().encode(["fresh-history-rounds-v1", "A", "B"]))
        let pending = PushPendingLane(selectionID: "retained-pending", kind: .freshAppend, table: "hrSample", deviceID: "A")
        let budget = PushWakeBudget(maximumRequests: 1)
        let run = await PushCoordinator(source: fixture, transport: fixture, progress: fixture,
            sourceId: "11111111-1111-4111-8111-111111111111", wakeBudget: budget)
            .pushKnownDevices(startDeviceIndex: 1, startLaneIndex: 83, expectedDeviceListFingerprint: oldFingerprint,
                capabilities: caps, pendingLanes: [pending], resumePreparedLane: { lane in
                    XCTAssertTrue(budget.admitRequest(bytes: 1)); await records.record(lane)
                    return .accepted(batchId: "same-retained-batch", recordCount: 1, hasMore: true, batchCount: 1)
                })
        let visits = await records.values, writes = await fixture.sourceProgressWrites
        XCTAssertEqual(visits.map(\.selectionID), ["retained-pending"])
        XCTAssertEqual(run.nextDeviceIndex, 0); XCTAssertEqual(run.nextLaneIndex, 1)
        XCTAssertNotEqual(run.deviceListFingerprint, oldFingerprint)
        XCTAssertEqual(writes, 0)
    }
}

private actor RotationServices {
    var values: [PushPendingLane] = []
    func record(_ value: PushPendingLane) { values.append(value) }
}

private actor RotationFixture: PushSnapshotSource, PushProgressStore, PushTransport {
    let devices: [String]
    let deferred: Bool
    var visited: [String] = []
    var remembered: Set<String> = []
    var sourceProgressWrites = 0
    init(_ devices: [String], deferred: Bool = false) { self.devices = devices; self.deferred = deferred }
    func knownDeviceIds(capabilities: PushCapabilities) throws -> [String] {
        if deferred { throw PushSourceReadError.deferred }; return devices
    }
    func knownDeviceIds() -> Set<String> { remembered }
    func rememberDeviceId(_ deviceId: String) { remembered.insert(deviceId) }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) -> PushAppendRecord? { nil }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushAppendRecord] {
        visited.append(deviceId); return []
    }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushBinaryRow] { [] }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) { sourceProgressWrites += 1 }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) -> [PushMutableRecord] { [] }
    func cursor(table: PushAppendTable, deviceId: String) -> PushCursor? { nil }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) { sourceProgressWrites += 1 }
    func binaryCursor(table: PushBinaryTable, deviceId: String) -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) { sourceProgressWrites += 1 }
    func window(table: PushMutableTable, deviceId: String) -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) { sourceProgressWrites += 1 }
    func post(_ batch: PushBatch) throws -> PushTransportResponse { throw PushProtocolException("unexpected transfer") }
    func postBinary(_ batch: PushBinaryBatch) throws -> PushTransportResponse { throw PushProtocolException("unexpected transfer") }
}
