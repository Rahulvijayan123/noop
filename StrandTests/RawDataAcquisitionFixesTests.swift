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

    /// WS-02-F01: write the frame's payload CRC32 trailer (last 4 bytes, zlib CRC32 over
    /// frame[8..<count-4], LE) so the frame is wire-valid. The golden fixture carries a zeroed
    /// trailer, and both helpers below mutate CRC-covered bytes, so every synthetic frame
    /// recomputes the trailer before it can be stored.
    private static func recomputePayloadCRC32(_ bytes: inout [UInt8]) {
        guard bytes.count == Whoop5RawImu.bufferLength else { return }
        let crc = crc32(bytes, 8, bytes.count - 4)
        let n = bytes.count - 4
        bytes[n] = UInt8(truncatingIfNeeded: crc & 0xFF)
        bytes[n + 1] = UInt8(truncatingIfNeeded: (crc >> 8) & 0xFF)
        bytes[n + 2] = UInt8(truncatingIfNeeded: (crc >> 16) & 0xFF)
        bytes[n + 3] = UInt8(truncatingIfNeeded: (crc >> 24) & 0xFF)
    }

    /// The golden frame with its 1-second baseTs patched (u32 LE at frame offset 15). Columns
    /// are untouched, so `Whoop5RawImu.rawColumns` still accepts the frame. The baseTs sits inside
    /// the CRC-covered payload, so the trailer is recomputed after patching.
    private func frame(baseTs: Int) -> [UInt8] {
        var bytes = Self.bytes(fromHex: Self.goldenFrameHex)
        bytes[15] = UInt8(truncatingIfNeeded: baseTs)
        bytes[16] = UInt8(truncatingIfNeeded: baseTs >> 8)
        bytes[17] = UInt8(truncatingIfNeeded: baseTs >> 16)
        bytes[18] = UInt8(truncatingIfNeeded: baseTs >> 24)
        Self.recomputePayloadCRC32(&bytes)
        return bytes
    }

    /// Same baseTs, deliberately different columns (flip ax[0]'s low byte at offset 28) — used
    /// to create a conflicting-duplicate timestamp. The flip is CRC-covered, so the trailer is
    /// recomputed: both records stay wire-valid, and the store sees a genuine conflicting pair
    /// rather than a corrupt frame.
    private func frameWithDifferentColumns(baseTs: Int) -> [UInt8] {
        var bytes = frame(baseTs: baseTs)
        bytes[28] ^= 0x01
        Self.recomputePayloadCRC32(&bytes)
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

    func testAStretchOfFailedFlushesDoesNotLeaveAnUnreadableOversizeBlock() throws {
        let store = ImuSessionFileStore.shared
        let sessionId = "stall-\(UUID().uuidString)"
        let deviceId = "stall-dev-\(UUID().uuidString)"
        let base = 1_758_000_000
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let sessionDirectory = support.appendingPathComponent("OpenWhoop/RawImuSessions/\(sessionId)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessionDirectory.path)
            _ = store.deleteFiles(sessionId); store.remove(id: sessionId)
        }
        store.start(id: sessionId, deviceId: deviceId, fromMs: Int64(base) * 1_000)

        // The folder stops accepting files, as it does when the disk is full or protected data is locked.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sessionDirectory.path)
        for i in 0..<75 {
            XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: base + i),
                                        receivedAtMs: 1_000 + Int64(i) * 1_000), 1)
        }
        XCTAssertEqual(store.stats(sessionId, from: base, to: base + 74).diskSeconds, 0,
                       "the folder was read-only, so nothing can be on disk yet")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessionDirectory.path)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: base + 75),
                                    receivedAtMs: 100_000), 1)
        store.complete(id: sessionId, toMs: Int64(base + 80) * 1_000)

        // 76 seconds are waiting by now. Written as ONE block, the reader rejects it (a block holds at
        // most 30) and the whole backlog, plus everything after it in the file, goes unreadable.
        let records = store.readRecords(deviceId: deviceId, fromTs: Int64(base), toTs: Int64(base + 80))
        XCTAssertEqual(records.map(\.ts), (0..<76).map { Int64(base + $0) },
                       "a backlog written as one oversize block is unreadable")
        XCTAssertTrue(store.lastReadQuality.isEmpty)
    }

    func testRangedReadSkipsOtherBucketsButKeepsEveryBoundarySecond() throws {
        let store = ImuSessionFileStore.shared
        let sessionId = "ranged-\(UUID().uuidString)"
        let deviceId = "ranged-dev-\(UUID().uuidString)"
        defer { _ = store.deleteFiles(sessionId); store.remove(id: sessionId) }
        // 1_757_998_800 is a multiple of 1800, so these four seconds straddle three 30-minute files:
        // the last second of the first, the first and last of the second, the first of the third.
        let bucket = 1_757_998_800
        store.start(id: sessionId, deviceId: deviceId, fromMs: Int64(bucket) * 1_000)
        for offset in [1_799, 1_800, 3_599, 3_600] {
            XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: bucket + offset),
                                        receivedAtMs: 1_000 + Int64(offset)), 1)
        }
        store.complete(id: sessionId, toMs: Int64(bucket + 4_000) * 1_000)

        func read(_ from: Int, _ to: Int) -> [Int] {
            store.readRecords(deviceId: deviceId, fromTs: Int64(from), toTs: Int64(to)).map { Int($0.ts) - bucket }
        }
        XCTAssertEqual(read(bucket + 1_800, bucket + 3_599), [1_800, 3_599], "exactly the middle file")
        XCTAssertEqual(read(bucket + 1_799, bucket + 1_800), [1_799, 1_800], "across the first boundary")
        XCTAssertEqual(read(bucket + 3_599, bucket + 3_600), [3_599, 3_600], "across the second boundary")
        XCTAssertEqual(read(bucket + 3_600, bucket + 9_999), [3_600], "the last file only")
        XCTAssertEqual(read(bucket, bucket + 1_798), [], "before the first second")
        XCTAssertEqual(read(bucket + 10_000, bucket + 20_000), [], "after everything")
        XCTAssertEqual(read(bucket, bucket + 10_000), [1_799, 1_800, 3_599, 3_600])
        XCTAssertEqual(store.stats(sessionId, from: bucket + 1_800, to: bucket + 3_599).diskSeconds, 2)
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
        // Everything up to now has reached the server (the object lane's watermark): age alone decides here.
        let uploadedThrough = store.uploadedThrough
        store.uploadedThrough = { _ in now }
        defer {
            store.uploadedThrough = uploadedThrough
            _ = store.deleteFiles(sessionId); store.remove(id: sessionId)
        }
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

    // MARK: - D7: raw IMU is kept until it is uploaded

    private func isolatedImuStore() -> ImuSessionFileStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-imu-retention-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ImuSessionFileStore(directory: directory, defaults: isolatedDefaults())
    }

    func testRetentionKeepsRawImuTheObjectLaneHasNotUploaded() throws {
        let store = isolatedImuStore()
        let sessionId = "evict-unuploaded"
        let completedId = "evict-unuploaded-done"
        let deviceId = "strap-a"
        let otherDevice = "strap-b"
        let now: Int64 = 1_800_000_000
        let day = Int64(86_400)
        var watermark: Int64? = nil
        store.uploadedThrough = { _ in watermark }
        store.uploadProtectionEnabled = { true }
        store.start(id: sessionId, deviceId: deviceId, fromMs: (now - 40 * day) * 1_000)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: Int(now - 35 * day)), receivedAtMs: 1_000), 1)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: Int(now)), receivedAtMs: 2_000), 1)
        XCTAssertNil(store.flushPendingFor(deviceId: deviceId))
        // A completed Raw Data session from five weeks ago, never uploaded either.
        store.register(id: completedId, deviceId: otherDevice, fromMs: (now - 36 * day) * 1_000,
                       toMs: (now - 36 * day + 60) * 1_000)
        XCTAssertEqual(store.append(deviceId: otherDevice, frame: frame(baseTs: Int(now - 36 * day)), receivedAtMs: 3_000), 1)
        XCTAssertNil(store.flushPendingFor(deviceId: otherDevice))

        let policy = ImuRetentionPolicy(maxAgeDays: 30, maxTotalBytes: 1_073_741_824)
        var evicted = store.evictExpired(now: now, policy: policy)
        XCTAssertFalse(evicted.contains(completedId), "a session not uploaded is kept however old")
        XCTAssertEqual(store.readRecords(deviceId: deviceId, fromTs: now - 35 * day, toTs: now - 35 * day).count, 1,
                       "an expired segment the lane has not uploaded is kept")
        XCTAssertEqual(store.readRecords(deviceId: otherDevice, fromTs: now - 36 * day, toTs: now - 36 * day).count, 1)

        // The lane's receipted cursor passes them: now they may go.
        watermark = now - 30 * day
        evicted = store.evictExpired(now: now, policy: policy)
        XCTAssertTrue(evicted.contains(completedId))
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: now - 35 * day, toTs: now - 35 * day).isEmpty)
        XCTAssertEqual(store.readRecords(deviceId: deviceId, fromTs: now, toTs: now).count, 1, "the live bucket stays")

        // A build with no cloud to upload to evicts by age alone, as before.
        store.uploadProtectionEnabled = { false }
        watermark = nil
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: Int(now - 33 * day)), receivedAtMs: 4_000), 1)
        XCTAssertNil(store.flushPendingFor(deviceId: deviceId))
        _ = store.evictExpired(now: now, policy: policy)
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: now - 33 * day, toTs: now - 33 * day).isEmpty)
    }

    func testOnlyTheHardCeilingEvictsRawImuThatWasNeverUploadedAndSaysSo() throws {
        let store = isolatedImuStore()
        let sessionId = "evict-ceiling"
        let deviceId = "strap-c"
        let now: Int64 = 1_800_000_000
        let day = Int64(86_400)
        var faults: [String] = []
        store.uploadedThrough = { _ in nil }
        store.uploadProtectionEnabled = { true }
        store.onUnuploadedEviction = { faults.append($0) }
        store.start(id: sessionId, deviceId: deviceId, fromMs: (now - 3 * day) * 1_000)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: Int(now - 2 * day)), receivedAtMs: 1_000), 1)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: frame(baseTs: Int(now)), receivedAtMs: 2_000), 1)
        XCTAssertNil(store.flushPendingFor(deviceId: deviceId))

        // Under the ceiling nothing that was not uploaded goes, even past the size cap.
        let roomy = ImuRetentionPolicy(maxAgeDays: 1, maxTotalBytes: 1, hardCeilingBytes: 1 << 40)
        _ = store.evictExpired(now: now, policy: roomy)
        XCTAssertEqual(store.readRecords(deviceId: deviceId, fromTs: now - 2 * day, toTs: now - 2 * day).count, 1)
        XCTAssertTrue(faults.isEmpty)

        // Over it, the oldest goes anyway (never the bucket being written), loudly.
        let tight = ImuRetentionPolicy(maxAgeDays: 30, maxTotalBytes: 1, hardCeilingBytes: 1)
        _ = store.evictExpired(now: now, policy: tight)
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: now - 2 * day, toTs: now - 2 * day).isEmpty)
        XCTAssertEqual(store.readRecords(deviceId: deviceId, fromTs: now, toTs: now).count, 1)
        XCTAssertEqual(faults.count, 1)
        XCTAssertTrue(faults.first?.contains("NOT been uploaded") == true)
        XCTAssertEqual(ImuRetentionPolicy(maxAgeDays: 30, maxTotalBytes: 1_000).hardCeilingBytes, 4_000,
                       "the default ceiling is four times the size cap")
    }

    func testUploadWatermarksOnlyMoveForward() {
        let marks = ImuUploadWatermarks(defaults: isolatedDefaults())
        XCTAssertNil(marks.uploadedThrough(localDeviceId: "My-Whoop"))
        marks.record(localDeviceId: "My-Whoop", through: 100)
        marks.record(localDeviceId: "my-whoop", through: 50)
        XCTAssertEqual(marks.uploadedThrough(localDeviceId: "my-whoop"), 100)
        XCTAssertTrue(ImuRetentionPolicy.isUploaded(endTs: 100, uploadedThrough: 100))
        XCTAssertFalse(ImuRetentionPolicy.isUploaded(endTs: 101, uploadedThrough: 100))
        XCTAssertFalse(ImuRetentionPolicy.isUploaded(endTs: 1, uploadedThrough: nil))
        XCTAssertTrue(ImuRetentionPolicy.isUploaded(endTs: nil, uploadedThrough: nil), "no data is nothing to keep")
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

    // MARK: - WS-02-F01/F02: payload-CRC + plausibility gate on the durable store

    private func makeRejectStore(suffix: String) -> (ImuSessionFileStore, String, String) {
        let deviceId = "imu-reject-\(suffix)-\(UUID().uuidString)"
        let sessionId = "imu-reject-\(suffix)-\(UUID().uuidString)"
        let store = ImuSessionFileStore.shared
        store.resetRawImuRejections()
        store.start(id: sessionId, deviceId: deviceId, fromMs: 1_758_000_000_000)
        return (store, deviceId, sessionId)
    }

    func testCorruptCRCFrameNeverStoredAndCounted() throws {
        // WS-02-F01: a header-valid 1244-byte frame whose payload CRC32 disagrees must be
        // counted-and-dropped at the store gate, never stored as IMU data.
        let (store, deviceId, sessionId) = makeRejectStore(suffix: "crc")
        defer { store.deleteFiles(sessionId); store.remove(id: sessionId) }

        var corrupt = frame(baseTs: 1_758_000_000)   // valid CRC first
        corrupt[28] ^= 0x40                          // flip a sample byte; trailer now wrong
        XCTAssertEqual(store.append(deviceId: deviceId, frame: corrupt, receivedAtMs: 1_000), 0,
                       "a payload-CRC-failed frame must never be stored")
        XCTAssertEqual(store.rawImuRejections[.payloadCRCMismatch], 1,
                       "the rejected frame must be counted with an explicit reason")
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000, toTs: 1_758_000_000).isEmpty,
                      "the corrupt second must not appear in any window")
    }

    func testGarbagePayloadFrameRejectedAndCounted() throws {
        // WS-02-F01: random garbage in the six sample columns (counts/ts intact) with a stale
        // trailer is rejected at the CRC gate — it must never reach a model window.
        let (store, deviceId, sessionId) = makeRejectStore(suffix: "garbage")
        defer { store.deleteFiles(sessionId); store.remove(id: sessionId) }

        var garbage = frame(baseTs: 1_758_000_000)
        let sampleRanges = [28..<228, 228..<428, 428..<630, 640..<840, 840..<1040, 1040..<1240]
        for range in sampleRanges {
            for off in range { garbage[off] = UInt8(truncatingIfNeeded: (off * 7 + 3) & 0xFF) }
        }
        XCTAssertEqual(store.append(deviceId: deviceId, frame: garbage, receivedAtMs: 1_000), 0,
                       "garbage payload must be rejected")
        XCTAssertEqual(store.rawImuRejections[.payloadCRCMismatch], 1)
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000, toTs: 1_758_000_000).isEmpty)
    }

    func testAllZeroFrameRejectedAsImplausibleNeverStationary() throws {
        // WS-02-F02: a CRC-valid all-zero frame (stuck/dead strap) must be rejected by the
        // plausibility gate — no gravity shell, so it can never become a "stationary" window.
        let (store, deviceId, sessionId) = makeRejectStore(suffix: "zero")
        defer { store.deleteFiles(sessionId); store.remove(id: sessionId) }

        var zero = [UInt8](repeating: 0, count: Whoop5RawImu.bufferLength)
        zero[15] = 0x80; zero[16] = 0xF3; zero[17] = 0xC8; zero[18] = 0x68   // ts = 1758000000
        zero[24] = 100; zero[25] = 0                                          // countA
        zero[630] = 100; zero[631] = 0                                        // countB
        Self.recomputePayloadCRC32(&zero)                                     // CRC-valid, samples zero
        XCTAssertEqual(store.append(deviceId: deviceId, frame: zero, receivedAtMs: 1_000), 0,
                       "an all-zero frame must be rejected")
        XCTAssertEqual(store.rawImuRejections[.zeroPayload], 1)
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000, toTs: 1_758_000_000).isEmpty,
                      "an all-zero frame must never become a stationary window")
    }

    func testStuckConstantFrameRejectedAsImplausible() throws {
        // WS-02-F02: a CRC-valid frame whose six columns are each exactly constant (pinned
        // sensor) is rejected — a real MEMS part always carries noise, so this is not raw motion.
        let (store, deviceId, sessionId) = makeRejectStore(suffix: "stuck")
        defer { store.deleteFiles(sessionId); store.remove(id: sessionId) }

        var stuck = [UInt8](repeating: 0, count: Whoop5RawImu.bufferLength)
        stuck[15] = 0x80; stuck[16] = 0xF3; stuck[17] = 0xC8; stuck[18] = 0x68
        stuck[24] = 100; stuck[25] = 0
        stuck[630] = 100; stuck[631] = 0
        func putU16(_ o: Int, _ v: Int) { stuck[o] = UInt8(v & 0xFF); stuck[o + 1] = UInt8((v >> 8) & 0xFF) }
        for i in 0..<100 {
            putU16(28 + 2 * i, 4117)        // ax pinned at 1 g
            putU16(228 + 2 * i, 0)          // ay pinned
            putU16(428 + 2 * i, 0)          // az pinned
            putU16(640 + 2 * i, 0)          // gx pinned
            putU16(840 + 2 * i, 0)          // gy pinned
            putU16(1040 + 2 * i, 0)         // gz pinned
        }
        Self.recomputePayloadCRC32(&stuck)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: stuck, receivedAtMs: 1_000), 0)
        XCTAssertEqual(store.rawImuRejections[.stuckConstantSamples], 1)
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000, toTs: 1_758_000_000).isEmpty)
    }

    func testRailPinnedFrameRejectedAsImplausible() throws {
        // WS-02-F02: a column pinned at the int16 full-scale rail for all 100 samples (sustained
        // clipping) is not real raw motion and must be rejected.
        let (store, deviceId, sessionId) = makeRejectStore(suffix: "rail")
        defer { store.deleteFiles(sessionId); store.remove(id: sessionId) }

        var rail = [UInt8](repeating: 0, count: Whoop5RawImu.bufferLength)
        rail[15] = 0x80; rail[16] = 0xF3; rail[17] = 0xC8; rail[18] = 0x68
        rail[24] = 100; rail[25] = 0
        rail[630] = 100; rail[631] = 0
        func putU16(_ o: Int, _ v: Int) { rail[o] = UInt8(v & 0xFF); rail[o + 1] = UInt8((v >> 8) & 0xFF) }
        for i in 0..<100 {
            putU16(28 + 2 * i, 32767)       // ax pinned at the rail
            putU16(228 + 2 * i, 4117 + i)   // other columns vary — not a "constant" frame
            putU16(428 + 2 * i, 4000 - i)
            putU16(640 + 2 * i, i)
            putU16(840 + 2 * i, 10)
            putU16(1040 + 2 * i, 20)
        }
        Self.recomputePayloadCRC32(&rail)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: rail, receivedAtMs: 1_000), 0)
        XCTAssertEqual(store.rawImuRejections[.saturatedRail], 1)
        XCTAssertTrue(store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000, toTs: 1_758_000_000).isEmpty)
    }

    func testValidGoldenFrameStillStored() throws {
        // WS-02-F01/F02 regression: the CRC-valid, plausible golden walking second must still be
        // accepted and stored — the gates add rejections for bad data, never for good data.
        let (store, deviceId, sessionId) = makeRejectStore(suffix: "golden")
        defer { store.deleteFiles(sessionId); store.remove(id: sessionId) }

        let good = frame(baseTs: 1_758_000_000)
        XCTAssertEqual(store.append(deviceId: deviceId, frame: good, receivedAtMs: 1_000), 1,
                       "a CRC-valid plausible frame must still be stored")
        XCTAssertTrue(store.rawImuRejections.isEmpty, "no rejections for a valid frame")
        let records = store.readRecords(deviceId: deviceId, fromTs: 1_758_000_000, toTs: 1_758_000_000)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.columns.count, 600)
        XCTAssertEqual(records.first?.ts, 1_758_000_000)
    }
}
