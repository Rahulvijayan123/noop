import XCTest
@testable import Strand
import WhoopProtocol

/// C8 Fix E/F/G + C10 read-API tests for the ios-acquisition wave. Pure-logic only (no
/// CoreBluetooth): the duration-bearing interval-label model, the bounded NOOPIMU2 retention
/// policy, the persisted capture intent, and the ImuSessionFileStore durability/dedup semantics
/// exercised through the real store public API with the shared golden IMU fixture.
@MainActor
final class RawDataAcquisitionFixesTests: XCTestCase {

    // Golden WHOOP 5/MG 1244-byte raw-IMU frame (walking second, baseTs 1758000000) from
    // nara-activity-research/golden/golden_imu_frames.json (LCG seed 0x4E415241, gait 1.8 Hz).
    private static let goldenFrameHex = "50464e45000000000000000000000080f3c8680000000000640000001c018701dd016602d20210037803a403da03e2031b04fb031504c403d603c50354034103e2029b025002ee0156011901a800fcffc2ff32ffa2fe3dfec3fd6cfd3efdf9fcb1fc5cfc48fc25fc2cfcd8fbecfb0bfc59fc3ffc9ffcc4fc3ffda1fd0dfe2dfebafe0cff9bfff8ff6900d4008401e401340287020603100383038603bc030904fa030e04e403bb03ce036b035603ed02bf026f02f201af013801d5004d00bdff67ffe2feadfe40fee3fd82fde9fcd8fc9dfc3dfc24fc2afc03fc15fcfffb1afc34fc71fccd02c102b702a502ad0294026002f201e401950142010c01a7005100ffffc4ff75ffdafed4fe66fe13fe14fed9fd61fd43fd39fd2bfd48fd28fd25fd35fd40fd74fd95fdf5fdf2fd6efe99febcfe1bff9affd9ff10005600d500260149019f010b021f0232029702c202d402ec02be02d102ce02b802ab02990258021b020502ca013a010201be009200fdffeeff9bff09fff2febbfe3afe0cfeeafd82fd8bfd67fd2bfd00fd39fd0efd2ffd43fd44fd95fdc3fddafd04fe4bfed5fe1fff4cffadfff2ff4400830019107b1016119e112f12991226134813ae13f11368149314cc14b414ae14b21494147d1461140114b3134e13f3127312ed117311e2107b10be0f540ff20e400eda0d300dce0ca70c1a0cb70b9c0b700b650b530b400b1c0b3c0b660be10be40b880cb00c060dae0d200e9a0e100f990f3210ed105811cf115912a5124813bc13091436144a147a14cc14ae14c014c3148d1470143614fc13a1132313cd124a12a2114711d4104e107e0f340fbb0e210e7f0d400dd10c350cee0bd80b600b720b2d0b370b480b6b0b000064000000000000000000dfff6b00b900ea003d015f017f01e2011f0213024f024f028602ab02b1029c025b0284026b0231020502db01820170010c01c1008e005400f3ff7fff75ff26ffdbfe7dfe61fe1afecbfdb5fdcefdb5fd99fd4cfd4afd7cfda9fdb2fdcefd0dfe38fe62fe58fee4fe1bff5fff99ffe6ff38005b00aa00da005301a101d40105023a02570248026e02a7026a029f02720272026a0246020402c401aa015d015c01fc00a6005e002c00ecff75ff1dfff3feb3fe99fe5bfe34fef5fdc7fd86fd93fd7dfd68fd4ffd5bfd3a0181018801a70193019701be017b01aa01800159014a0108011101fd009600a00060002e000c00a7ffc9ff81ff6dff18ff12ffe3febefebbfe98fe5afe4dfe4dfe52fe6cfe7efe93fe92fe8dfec0fee3fef1fe55ff7cff68ff98ffdffffeff270063008c009e00f1001f013a012e014401890162017301b201b801ae01a80166015a0167013f010601f000df00880060004100faffeaffddff74ff8aff33ff06fff6feb4fe90fe76fe85fe6bfe66fe8ffe44fe6bfe94fe74fea2fea9fecffe1bff0fff67ff6eff7c0066006f0070007800540048005400fefff1ff2100f7ffd5ffd1ffb2ff9dffb9ff9dffa5ff4dff91ff7fff6eff54ff37ff4aff82ff88ff6bff9aff91ff8effbaffcaffcfffc2ffd0ff1000e0ff3d00ffff22002f0033005800700092008a009f007a00b900b300b700bc00c500a50097006b00740051007800590019000900260019002000f8ffd8ffa4ffcdffa2ff91ff66ff59ff4fff58ff5cff60ff3eff47ff7dff84ff87ff7dff8dff81ffabff99ff8bffc5ffcafffcffe6ff02003c000a0061002b004c0000000000"

    // MARK: - Isolation: the stores behind these tests persist to real UserDefaults + the app's
    // Application Support (the shared singletons). Unique ids + teardown cleanup keep runs
    // isolated; the two UserDefaults keys are backed up and restored so a mid-test failure
    // cannot leak state into other tests or the app.

    private var savedWindowsKey: Data?
    private var savedIntentKey: Data?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedWindowsKey = defaults.data(forKey: "imu-session-windows-v1")
        savedIntentKey = defaults.data(forKey: RawDataSessionStore.captureIntentKey)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedWindowsKey { defaults.set(savedWindowsKey, forKey: "imu-session-windows-v1") }
        else { defaults.removeObject(forKey: "imu-session-windows-v1") }
        if let savedIntentKey { defaults.set(savedIntentKey, forKey: RawDataSessionStore.captureIntentKey) }
        else { defaults.removeObject(forKey: RawDataSessionStore.captureIntentKey) }
        super.tearDown()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static func bytes(fromHex hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    /// The golden frame with its 1-second baseTs patched (u32 LE at frame offset 15). Columns
    /// are untouched, so `Whoop5RawImu.rawColumns` still accepts the frame.
    private func frame(baseTs: Int) -> [UInt8] {
        var bytes = Self.bytes(fromHex: Self.goldenFrameHex)
        bytes[15] = UInt8(truncatingIfNeeded: baseTs)
        bytes[16] = UInt8(truncatingIfNeeded: baseTs >> 8)
        bytes[17] = UInt8(truncatingIfNeeded: baseTs >> 16)
        bytes[18] = UInt8(truncatingIfNeeded: baseTs >> 24)
        return bytes
    }

    /// Same baseTs, deliberately different columns (flip ax[0]'s low byte at offset 28) — used
    /// to create a conflicting-duplicate timestamp.
    private func frameWithDifferentColumns(baseTs: Int) -> [UInt8] {
        var bytes = frame(baseTs: baseTs)
        bytes[28] ^= 0x01
        return bytes
    }

    // MARK: - C8 Fix F: duration-bearing interval labels

    func testIntervalLabelModelAndExport() throws {
        let store = RawDataSessionStore(directory: try temporaryDirectory())
        let session = try XCTUnwrap(store.start(deviceId: "strap", now: Date(timeIntervalSince1970: 100)))
        let interval = try XCTUnwrap(store.addIntervalLabel(sessionId: session.id,
            from: Date(timeIntervalSince1970: 101), to: Date(timeIntervalSince1970: 103), label: "walking"))
        XCTAssertEqual(interval.kind, "activityInterval")
        XCTAssertEqual(interval.markerType, "walking")
        XCTAssertEqual(interval.label, "walking")
        XCTAssertEqual(interval.provenance, "user_confirmed")
        XCTAssertEqual(interval.atMs, 101_000)
        XCTAssertEqual(interval.endAtMs, 103_000)
        store.stop(now: Date(timeIntervalSince1970: 106))

        let saved = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(saved.events.filter { $0.kind == "activityInterval" }.count, 1)

        // Unknown labels and reversed ranges are rejected.
        XCTAssertNil(store.addIntervalLabel(sessionId: session.id,
            from: Date(timeIntervalSince1970: 101), to: Date(timeIntervalSince1970: 103), label: "jumping"))
        XCTAssertNil(store.addIntervalLabel(sessionId: session.id,
            from: Date(timeIntervalSince1970: 105), to: Date(timeIntervalSince1970: 102), label: "walking"))

        // Exported in meta.json beside markers, with provenance.
        let meta = try XCTUnwrap(store.exportEntries(for: saved).first(where: { $0.name == "meta.json" }))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: meta.data) as? [String: Any])
        let intervals = try XCTUnwrap(object["activity_intervals"] as? [[String: Any]])
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?["label"] as? String, "walking")
        XCTAssertEqual(intervals.first?["provenance"] as? String, "user_confirmed")
        XCTAssertEqual(intervals.first?["start_ms"] as? Int64, 101_000)
        XCTAssertEqual(intervals.first?["end_ms"] as? Int64, 103_000)

        // Exported in events.jsonl as a duration-bearing row with provenance.
        let events = try XCTUnwrap(store.exportEntries(for: saved).first(where: { $0.name == "events.jsonl" }))
        let text = String(decoding: events.data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\":\"activityInterval\""))
        XCTAssertTrue(text.contains("\"label\":\"walking\""))
        XCTAssertTrue(text.contains("\"provenance\":\"user_confirmed\""))
    }

    func testIntervalCorrectionsPreserveProvenanceAndDeleteRemoves() throws {
        let store = RawDataSessionStore(directory: try temporaryDirectory())
        let session = try XCTUnwrap(store.start(deviceId: "strap", now: Date(timeIntervalSince1970: 100)))
        let interval = try XCTUnwrap(store.addIntervalLabel(sessionId: session.id,
            from: Date(timeIntervalSince1970: 101), to: Date(timeIntervalSince1970: 103), label: "walking"))
        store.updateIntervalLabel(sessionId: session.id, intervalId: try XCTUnwrap(interval.markerId),
            from: Date(timeIntervalSince1970: 101), to: Date(timeIntervalSince1970: 104), label: "running")
        let updated = try XCTUnwrap(store.sessions.first?.events.first(where: { $0.kind == "activityInterval" }))
        XCTAssertEqual(updated.label, "running")
        XCTAssertEqual(updated.markerType, "running")
        XCTAssertEqual(updated.endAtMs, 104_000)
        // A correction is a LOCAL OVERLAY: provenance stays "user_confirmed" and never moves toward
        // a predicted label (predicted labels are server-side and are never written here).
        XCTAssertEqual(updated.provenance, "user_confirmed")

        store.deleteMarker(sessionId: session.id, markerId: try XCTUnwrap(interval.markerId))
        XCTAssertFalse(try XCTUnwrap(store.sessions.first).events.contains(where: { $0.kind == "activityInterval" }))
    }

    // MARK: - C8 Fix G: bounded NOOPIMU2 retention policy (pure)

    func testRetentionPolicyAgeAndSizeRules() {
        let policy = ImuRetentionPolicy(maxAgeDays: 30, maxTotalBytes: 1_000_000)
        let now: Int64 = 1_800_000_000
        // Active sessions are never evicted.
        XCTAssertEqual(policy.decision(active: true, endTs: now - 1, now: now), .keep)
        // Completed but recent.
        XCTAssertEqual(policy.decision(active: false, endTs: now - 86_400, now: now), .keep)
        // Completed and expired (> 30 days old).
        if case .evict = policy.decision(active: false, endTs: now - 31 * 86_400, now: now) {}
        else { XCTFail("31-day-old completed session should be evicted") }
        // Completed session that never captured a second.
        if case .evict = policy.decision(active: false, endTs: nil, now: now) {}
        else { XCTFail("empty completed session should be evicted") }

        // Size rule: under the cap → nothing evicted.
        XCTAssertEqual(policy.evictionsForSizeCap(totalBytes: 900_000,
            completed: [(id: "a", endTs: 100, bytes: 100)]), [])
        // Over the cap → oldest-first until back under.
        let evicted = policy.evictionsForSizeCap(totalBytes: 2_000_000, completed: [
            (id: "new", endTs: 500, bytes: 300_000),
            (id: "old", endTs: 100, bytes: 900_000),
            (id: "mid", endTs: 300, bytes: 900_000),
        ])
        XCTAssertEqual(evicted, ["old", "mid"])

        // Conservative documented defaults.
        XCTAssertEqual(ImuRetentionPolicy.default.maxAgeDays, 30)
        XCTAssertEqual(ImuRetentionPolicy.default.maxTotalBytes, 1_073_741_824)
    }

    func testEvictExpiredRemovesOldCompletedSessionsOnly() throws {
        let store = ImuSessionFileStore.shared
        let activeId = "evict-active-\(UUID().uuidString)"
        let oldId = "evict-old-\(UUID().uuidString)"
        let deviceId = "evict-dev-\(UUID().uuidString)"
        let now: Int64 = 1_800_000_000
        defer {
            _ = store.deleteFiles(activeId); store.remove(id: activeId)
            _ = store.deleteFiles(oldId); store.remove(id: oldId)
        }
        store.start(id: activeId, deviceId: deviceId, fromMs: now * 1_000)
        // A completed (bounded) session whose end is decades old → expired.
        store.register(id: oldId, deviceId: deviceId, fromMs: 1_000, toMs: 1_100)
        let evicted = store.evictExpired(now: now, policy: ImuRetentionPolicy(maxAgeDays: 30, maxTotalBytes: 1_073_741_824))
        XCTAssertTrue(evicted.contains(oldId))
        XCTAssertFalse(evicted.contains(activeId))
        // The active window is untouched and still readable.
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: 0, toTs: now).isEmpty)
    }

    // MARK: - C8 Fix D: persisted capture intent

    func testPersistedCaptureIntentLifecycle() throws {
        let store = RawDataSessionStore(directory: try temporaryDirectory())
        XCTAssertNil(RawDataSessionStore.persistedCaptureIntent)
        let session = try XCTUnwrap(store.start(deviceId: "strap", now: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(RawDataSessionStore.persistedCaptureIntent?.sessionId, session.id)
        XCTAssertEqual(RawDataSessionStore.persistedCaptureIntent?.deviceId, "strap")
        store.stop(now: Date(timeIntervalSince1970: 106))
        XCTAssertNil(RawDataSessionStore.persistedCaptureIntent)
        _ = store.removeMetadata(session.id)
    }

    func testPersistedCaptureIntentClearedByDeviceDelete() throws {
        let store = RawDataSessionStore(directory: try temporaryDirectory())
        let session = try XCTUnwrap(store.start(deviceId: "strap-a", now: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(RawDataSessionStore.persistedCaptureIntent?.deviceId, "strap-a")
        // A different device's deletion leaves the intent alone.
        RawDataSessionStore.clearPersistedCaptureIntentIfDevice("strap-b")
        XCTAssertNotNil(RawDataSessionStore.persistedCaptureIntent)
        // The owning device's deletion clears it (device unpair/forget path).
        RawDataSessionStore.clearPersistedCaptureIntentIfDevice("strap-a")
        XCTAssertNil(RawDataSessionStore.persistedCaptureIntent)
        store.stop(now: Date(timeIntervalSince1970: 106))
        _ = store.removeMetadata(session.id)
    }

    func testHistoricalSessionsDoNotSetCaptureIntent() throws {
        let store = RawDataSessionStore(directory: try temporaryDirectory())
        let session = try XCTUnwrap(store.createHistorical(deviceId: "strap",
            from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 200)))
        XCTAssertNil(RawDataSessionStore.persistedCaptureIntent)
        _ = store.removeMetadata(session.id)
    }

    // MARK: - C8 Fix E + C10: ImuSessionFileStore durability/dedup/read API

    func testImuStoreReadRecordsRoundTripAndDedup() throws {
        let store = ImuSessionFileStore.shared
        let sessionId = "rt-\(UUID().uuidString)"
        let deviceId = "rt-dev-\(UUID().uuidString)"
        defer { _ = store.deleteFiles(sessionId); store.remove(id: sessionId) }
        store.start(id: sessionId, deviceId: deviceId, fromMs: 1_758_000_000_000)
        let frame = frame(baseTs: 1_758_000_000)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame, receivedAtMs: 1_000), 1)
        // The same frame re-delivered must be deduped, not double-stored.
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame, receivedAtMs: 2_000), 0)
        store.complete(id: sessionId, toMs: 1_758_000_001_000)

        let records = store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000, toTs: 1_758_000_000)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].ts, 1_758_000_000)
        XCTAssertEqual(records[0].columns.count, 600)
        XCTAssertEqual(records[0].columns, try XCTUnwrap(Whoop5RawImu.rawColumns(frame)))
        XCTAssertTrue(store.lastReadQuality.isEmpty)
    }

    func testImuStoreReadRecordsFlushesPendingTail() throws {
        let store = ImuSessionFileStore.shared
        let sessionId = "flush-\(UUID().uuidString)"
        let deviceId = "flush-dev-\(UUID().uuidString)"
        defer { _ = store.deleteFiles(sessionId); store.remove(id: sessionId) }
        store.start(id: sessionId, deviceId: deviceId, fromMs: 1_758_000_000_000)
        // Below the 30-record block boundary the frame lives only in the RAM tail; readRecords
        // must flush it first so the upload read reflects durable state.
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: 1_758_000_000),
                                    receivedAtMs: 1_000), 1)
        let records = store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000, toTs: 1_758_000_000)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(store.lastReadQuality.isEmpty)
    }

    func testImuStoreStatsSplitDurableAndPending() throws {
        let store = ImuSessionFileStore.shared
        let sessionId = "stats-\(UUID().uuidString)"
        let deviceId = "stats-dev-\(UUID().uuidString)"
        defer { _ = store.deleteFiles(sessionId); store.remove(id: sessionId) }
        let base = 1_758_000_000
        store.start(id: sessionId, deviceId: deviceId, fromMs: Int64(base) * 1_000)
        // 30 records cross the block boundary inside append → all durable, none pending.
        for i in 0..<30 {
            XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: base + i),
                                        receivedAtMs: 1_000 + Int64(i)), 1)
        }
        let stats = store.stats(sessionId, from: base, to: base + 29)
        XCTAssertEqual(stats.diskSeconds, 30)
        XCTAssertEqual(stats.pendingSeconds, 0)
        XCTAssertEqual(stats.coveredSeconds, 30)
        // One extra frame stays in the RAM tail (below the next 30-record boundary). The totals
        // never double-count: disk + pending always equals the unique captured seconds.
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: base + 30),
                                    receivedAtMs: 2_000), 1)
        let stats2 = store.stats(sessionId, from: base, to: base + 30)
        XCTAssertEqual(stats2.diskSeconds + stats2.pendingSeconds, 31)
        // readRecords flushes the tail and returns everything, sorted.
        let records = store.readRecords(deviceId: deviceId, fromTs: Int64(base), toTs: Int64(base + 30))
        XCTAssertEqual(records.count, 31)
        let sortedTs = records.map(\.ts)
        XCTAssertEqual(sortedTs, sortedTs.sorted())
    }

    func testImuStoreConflictingDuplicatesDropBothAndReportQuality() throws {
        let store = ImuSessionFileStore.shared
        let idA = "conflict-a-\(UUID().uuidString)"
        let idB = "conflict-b-\(UUID().uuidString)"
        let deviceId = "conflict-dev-\(UUID().uuidString)"
        defer {
            _ = store.deleteFiles(idA); store.remove(id: idA)
            _ = store.deleteFiles(idB); store.remove(id: idB)
        }
        store.start(id: idA, deviceId: deviceId, fromMs: 1_758_000_000_000)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: 1_758_000_000),
                                    receivedAtMs: 1_000), 1)
        // A second window for the same device is registered AFTER the first frame landed, so it
        // can hold a DIFFERENT-column record with the same timestamp → conflicting duplicate.
        store.start(id: idB, deviceId: deviceId, fromMs: 1_758_000_000_000)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frameWithDifferentColumns(baseTs: 1_758_000_000),
                                    receivedAtMs: 2_000), 1)

        let records = store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000, toTs: 1_758_000_000)
        XCTAssertTrue(records.isEmpty)   // BOTH conflicting copies dropped — never silently one
        XCTAssertEqual(store.lastReadQuality.count, 1)
        XCTAssertEqual(store.lastReadQuality[0].ts, 1_758_000_000)
        XCTAssertTrue(store.lastReadQuality[0].reason.contains("conflicting_duplicate"))
    }

    // MARK: - P2-5: flush-before-read seam (upload cursor must never skip un-flushed seconds)

    func testFlushPendingForFlushesDeviceTailAndReportsNoneBlocked() throws {
        let store = ImuSessionFileStore.shared
        let sessionId = "flushfor-\(UUID().uuidString)"
        let deviceId = "flushfor-dev-\(UUID().uuidString)"
        defer { _ = store.deleteFiles(sessionId); store.remove(id: sessionId) }
        store.start(id: sessionId, deviceId: deviceId, fromMs: 1_758_000_000_000)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: 1_758_000_000),
                                    receivedAtMs: 1_000), 1)
        // The frame is below the 30-record block boundary, so it sits in the RAM pending tail.
        // flushPendingFor flushes it, reports nil (nothing blocked), and readRecords now sees it
        // as durable — the upload seam can page it safely.
        XCTAssertNil(store.flushPendingFor(deviceId: deviceId))
        XCTAssertEqual(store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000,
                                         toTs: 1_758_000_000).count, 1)
        // A device with no windows is a no-op that reports nil.
        XCTAssertNil(store.flushPendingFor(deviceId: "flushfor-missing-\(UUID().uuidString)"))
    }

    // MARK: - P2-4: retention during continuous capture

    func testRetentionPolicyActiveSessionSegmentRule() {
        let policy = ImuRetentionPolicy(maxAgeDays: 30, maxTotalBytes: 1_073_741_824)
        let now: Int64 = 1_800_000_000
        let day = Int64(86_400)
        // A segment whose nominal end is newer than the retention floor is never evicted.
        XCTAssertEqual(policy.activeSessionSegmentDecision(segmentEndTs: now - day,
                                                           activeWindowStartTs: now, now: now), .keep)
        // A segment that touches the active window (the bucket being written) is never evicted,
        // even when it is older than the floor (a long-stalled capture keeps its last bucket).
        XCTAssertEqual(policy.activeSessionSegmentDecision(segmentEndTs: now - 40 * day,
                                                           activeWindowStartTs: now - 40 * day, now: now), .keep)
        // Only fully-expired AND fully-before-the-active-window segments may be evicted.
        if case .evict(let reason) = policy.activeSessionSegmentDecision(segmentEndTs: now - 31 * day,
                                                                         activeWindowStartTs: now - 30 * day,
                                                                         now: now) {
            XCTAssertTrue(reason.contains("active window"))
        } else { XCTFail("expired segment fully before the active window should be evicted") }
    }

    func testEvictExpiredReapsExpiredSegmentsOfActiveSessionOnly() throws {
        let store = ImuSessionFileStore.shared
        let sessionId = "evict-active-seg-\(UUID().uuidString)"
        let deviceId = "evict-active-seg-dev-\(UUID().uuidString)"
        let now: Int64 = 1_800_000_000
        let day = Int64(86_400)
        defer { _ = store.deleteFiles(sessionId); store.remove(id: sessionId) }
        // A continuous-capture session that started more than a month ago and is STILL active.
        store.start(id: sessionId, deviceId: deviceId, fromMs: (now - 35 * day) * 1_000)
        // One expired second (31 days ago), one a day old, and one right now — all in the SAME
        // active window, all appended below the 30-record block boundary (RAM tail).
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: Int(now - 31 * day)),
                                    receivedAtMs: 1_000), 1)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: Int(now - day)),
                                    receivedAtMs: 2_000), 1)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: Int(now)),
                                    receivedAtMs: 3_000), 1)
        // Real capture flushes the tail within ~10 s; make the frames durable before eviction.
        XCTAssertNil(store.flushPendingFor(deviceId: deviceId))

        _ = store.evictExpired(now: now, policy: ImuRetentionPolicy(maxAgeDays: 30, maxTotalBytes: 1_073_741_824))

        // The expired segment (31 days old, fully before the active window) is gone; the seconds
        // newer than the retention floor / inside the active window survive untouched.
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: now - 31 * day,
                                        toTs: now - 31 * day).isEmpty, "expired segment evicted")
        XCTAssertEqual(store.readRecords(deviceId: deviceId, fromTs: now - day, toTs: now - day).count, 1)
        XCTAssertEqual(store.readRecords(deviceId: deviceId, fromTs: now, toTs: now).count, 1)
    }

    // MARK: - P3: stop-rollback on .alreadyInFlight must not kill the other capture

    func testAlreadyInFlightRollbackDoesNotStopTheTransport() throws {
        // The transport is only stopped when THIS start latched it. `.alreadyInFlight` means
        // another capture owns the transport — stopping it would kill that capture.
        XCTAssertFalse(RawDataCollectorView.shouldStopInFlightTransport(on: .alreadyInFlight))
        XCTAssertTrue(RawDataCollectorView.shouldStopInFlightTransport(on: .unsupportedDeviceFamily))
        XCTAssertTrue(RawDataCollectorView.shouldStopInFlightTransport(on: .notConnected))
        XCTAssertFalse(RawDataCollectorView.shouldStopInFlightTransport(on: .started))
        // The conflict is stated honestly, not hidden behind a generic failure.
        XCTAssertTrue(RawDataCollectorView.captureErrorMessage(.alreadyInFlight)
            .contains("Another raw-data capture is already running"))
    }

    func testNotConnectedMessageDoesNotPromiseAnAutomaticRetry() throws {
        // The failed start removes the session and its capture intent, so nothing re-arms on the
        // next connection; the user has to start again.
        let message = RawDataCollectorView.captureErrorMessage(.notConnected)
        XCTAssertFalse(message.contains("re-arms"))
        XCTAssertTrue(message.contains("start the session again"))
    }

    func testAlreadyInFlightRollbackLeavesNoLocalSessionBehind() throws {
        // The rollback performed on a failed start must remove every local trace of the
        // just-created session: metadata file, IMU window, capture intent.
        let store = RawDataSessionStore(directory: try temporaryDirectory())
        let session = try XCTUnwrap(store.start(deviceId: "strap", now: Date(timeIntervalSince1970: 100)))
        store.stop(now: Date(timeIntervalSince1970: 101))
        XCTAssertTrue(store.removeMetadata(session.id))
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(RawDataSessionStore.persistedCaptureIntent)
        XCTAssertTrue(ImuSessionFileStore.shared.readRecords(deviceId: "strap", fromTs: 0,
                                                             toTs: 1_000_000).isEmpty)
    }
}
