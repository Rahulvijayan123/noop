import XCTest
import zlib
@testable import NoopPush

/// Protocol 1.5 / NPB1 format 3 PPG: the anchor, record clock, raw header phase/flags and saturation
/// flags survive packing, the streaming phone path and every decoder; older formats never drop them
/// silently; old bytes decode unchanged.
///
/// `ppg_anchor_v3_golden.json` is the cross-stack byte fixture: this suite writes it (set
/// `NOOP_PPG_ANCHOR_GOLDEN_OUTPUT` to regenerate), and the receiver's Deno tests and the worker's
/// SensorBiomarker tests read the same file. The `phone_real_frames` vector carries the two real v26
/// frames WhoopProtocol pins (`Whoop5PpgWaveformTests`) plus two synthetic neighbours; it is exactly
/// what `PpgObjectSource` produces from those rows banked in WhoopStore.
final class PpgAnchorTransportTests: XCTestCase {
    static let sourceId = "7d1e2f3a-4b5c-4d6e-8f70-8192a3b4c5d6"
    static let deviceId = "whoop-ppg-golden"

    struct GoldenRow {
        let record: PushPpgWaveformRecord
        let provenance: String
    }

    static func deltas(_ values: [Int]) -> Data {
        var out = Data(capacity: values.count * 2)
        for value in values {
            let v = UInt16(bitPattern: Int16(value))
            out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8))
        }
        return out
    }

    /// Rows as the phone banks them: rowId == ts, the strap's burst counter and base code, and the
    /// record-second clock. The phone keeps neither the header phase nor the flags byte today.
    static func phoneRows() -> [GoldenRow] {
        func row(_ ts: Int64, burst: Int32, anchor: UInt32, _ values: [Int], _ provenance: String) -> GoldenRow {
            GoldenRow(record: .init(rowId: ts, ts: ts, burstIndex: burst, samples: deltas(values),
                                    anchor: anchor, clockSource: .strapRecordSecond), provenance: provenance)
        }
        return [
            row(1_780_917_232, burst: 1, anchor: 378_307,
                [-1432, -1332, -1139, -954, -629, -436, -326, -294, -147, -170, -43, -5,
                 -201, -918, -1563, -1833, -1313, -930, -616, -293, -422, -380, -235, -164],
                "real v26 frame burst-1 (WhoopProtocol Whoop5PpgWaveformTests)"),
            row(1_780_917_233, burst: 1, anchor: 362_374,
                [-120, -98, -60, 210, 640, 980, 820, 610, 400, 180, 40, -30,
                 -90, -140, -170, -190, -200, -205, -210, -205, -200, -190, -180, -170],
                "synthetic continuation of burst 1 (base = previous 25th point - 158)"),
            row(1_780_917_234, burst: 1, anchor: 361_700,
                [32767, -12, 14, -9, 7, -5, 3, -2, 1, 0, -1, 2,
                 -3, 4, -5, 6, -7, 8, -9, 10, -11, 12, -13, 14],
                "synthetic burst-1 second with a delta at the +i16 rail"),
            row(1_780_918_392, burst: 2, anchor: 434_252,
                [-643, -543, -284, 1177, 2384, 3572, 2943, 3128, 2385, 489, -195, -243,
                 -743, -402, -294, -370, -884, -352, 408, 576, 969, 1439, 1328, 402],
                "real v26 frame burst-2 (WhoopProtocol Whoop5PpgWaveformTests)"),
        ]
    }

    /// Every format 3 member at both presence states, plus edge values no phone produces today.
    static func allMemberRows() -> [GoldenRow] {
        let small = Array(repeating: [5, -3], count: 12).flatMap { $0 }
        return [
            GoldenRow(record: .init(rowId: 1, ts: 1_800_000_000, burstIndex: 7, samples: deltas(small),
                recordIndex: Int64(UInt32.max), anchor: 100_000, clockSource: .strapRecordSecond,
                subsecQ15: 3932, frontEndFlags: 0x80), provenance: "synthetic: every member present"),
            GoldenRow(record: .init(rowId: 2, ts: 1_800_000_001, burstIndex: nil, samples: deltas(small)),
                provenance: "synthetic: format 3 record with no anchor and an unknown clock"),
            GoldenRow(record: .init(rowId: 3, ts: 1_800_000_002, burstIndex: 7,
                samples: deltas([-32768] + Array(small.dropFirst())), recordIndex: 5, anchor: UInt32.max,
                clockSource: .strapRecordSecond, subsecQ15: 32767, frontEndFlags: 0x00),
                provenance: "synthetic: -i16 rail delta, u32-max anchor, maximum Q15 phase"),
            GoldenRow(record: .init(rowId: 4, ts: 1_800_000_003, burstIndex: 7,
                samples: deltas(small + [1]), anchor: 100_500, clockSource: .strapRecordSecond),
                provenance: "synthetic: 25 deltas (a native-rate variant, carried verbatim)"),
        ]
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("noop-ppg-anchor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func gunzip(_ bytes: Data, size: Int) throws -> Data {
        var decoded = Data(count: max(size, 1)), stream = z_stream()
        XCTAssertEqual(inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { inflateEnd(&stream) }
        let status = bytes.withUnsafeBytes { input in decoded.withUnsafeMutableBytes { output in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(output.count)
            return inflate(&stream, Z_FINISH)
        }}
        XCTAssertEqual(status, Z_STREAM_END)
        return decoded.prefix(Int(stream.total_out))
    }

    private func json(_ row: GoldenRow) -> [String: Any] {
        let r = row.record
        return [
            "rowId": r.rowId, "ts": r.ts,
            "burstIndex": r.burstIndex.map { NSNumber(value: $0) } ?? NSNull(),
            "recordIndex": r.recordIndex.map { NSNumber(value: $0) } ?? NSNull(),
            "anchor": r.anchor.map { NSNumber(value: $0) } ?? NSNull(),
            "clockSource": Int(r.clockSource.rawValue),
            "subsecQ15": r.subsecQ15.map { NSNumber(value: $0) } ?? NSNull(),
            "frontEndFlags": r.frontEndFlags.map { NSNumber(value: $0) } ?? NSNull(),
            "sampleFlags": Int(PushBinaryCodec.ppgSampleFlags(r.samples)),
            "samples_hex": hex(r.samples),
            "provenance": row.provenance,
        ]
    }

    /// The batch exactly as the phone's object lane builds it: the streaming encoder into an
    /// account-owned directory (the coordinator's wake-budgeted path), protocol 1.5.
    private func phoneBatch(_ rows: [GoldenRow]) throws -> PushBinaryBatch {
        try PushProtocol.binaryObjectBatch(table: .ppgWaveformSample, sourceId: Self.sourceId,
            deviceId: Self.deviceId, startCursor: nil, rows: rows.map { .ppgWaveform($0.record) },
            protocolVersion: PushProtocol.ppgAnchorVersion, decodedLimit: 4 * 1_048_576,
            payloadDirectory: try directory())
    }

    func testGoldenVectorsMatchTheCodecAndTheStreamingPhonePath() throws {
        var vectors: [[String: Any]] = []
        for (name, rows) in [("phone_real_frames", Self.phoneRows()), ("all_members", Self.allMemberRows())] {
            let packed = try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: rows.map { .ppgWaveform($0.record) },
                                                  ppgAnchorV3: true)
            XCTAssertEqual(packed[4], PushBinaryCodec.ppgAnchorFormatVersion)
            let batch = try phoneBatch(rows)
            XCTAssertEqual(batch.contentSha256, PushBinaryCodec.sha256Hex(packed),
                           "the streaming phone path and the in-memory packer must emit identical bytes")
            XCTAssertEqual(batch.uncompressedBytes, packed.count)
            let wire = try batch.payload
            XCTAssertEqual(try gunzip(wire, size: packed.count), packed)
            let manifest = PushObjectManifest(batch: batch)
            XCTAssertEqual(manifest.protocolVersion, "1.5")
            let manifestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest.encode()) as? [String: Any])
            vectors.append([
                "name": name,
                "rows": rows.map(json),
                "decoded_hex": hex(packed),
                "decoded_sha256": PushBinaryCodec.sha256Hex(packed),
                "wire_encoding": "gzip",
                "wire_base64": wire.base64EncodedString(),
                "wire_sha256": batch.wireSHA256,
                "manifest": manifestObject,
                "end_cursor": ["rowId": batch.endCursor!.rowId, "keySha256": batch.endCursor!.naturalKeyFingerprint],
            ])
        }
        let value: [String: Any] = [
            "schema": "noop-push-ppg-anchor-golden/1",
            "protocol_version": PushProtocol.ppgAnchorVersion,
            "schema_version": PushProtocol.schemaVersion(stream: "ppgWaveformSample", protocolVersion: "1.5"),
            "npb1_format_version": Int(PushBinaryCodec.ppgAnchorFormatVersion),
            "source_id": Self.sourceId,
            "device_id": Self.deviceId,
            "contains_real_frames": "the two published WhoopProtocol v26 frames only; every other record is synthetic",
            "vectors": vectors,
        ]
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        if let path = ProcessInfo.processInfo.environment["NOOP_PPG_ANCHOR_GOLDEN_OUTPUT"] {
            try encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
        } else {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "ppg_anchor_v3_golden", withExtension: "json"))
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
            XCTAssertEqual(value as NSDictionary, expected)
        }
    }

    func testFormat3RoundTripPreservesEveryMember() throws {
        for rows in [Self.phoneRows(), Self.allMemberRows()] {
            let packed = try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: rows.map { .ppgWaveform($0.record) },
                                                  ppgAnchorV3: true)
            let decoded = try PushBinaryCodec.unpackPpgRecords(packed)
            XCTAssertEqual(decoded.count, rows.count)
            for (got, want) in zip(decoded, rows.map(\.record)) {
                XCTAssertEqual(got.rowId, want.rowId); XCTAssertEqual(got.ts, want.ts)
                XCTAssertEqual(got.burstIndex, want.burstIndex); XCTAssertEqual(got.recordIndex, want.recordIndex)
                XCTAssertEqual(got.anchor, want.anchor); XCTAssertEqual(got.clockSource, want.clockSource)
                XCTAssertEqual(got.subsecQ15, want.subsecQ15); XCTAssertEqual(got.frontEndFlags, want.frontEndFlags)
                XCTAssertEqual(got.samples, want.samples)
            }
            XCTAssertEqual(packed.count, 10 + (try rows.reduce(0) {
                $0 + (try PushBinaryCodec.packedRowSize(.ppgWaveform($1.record), ppgAnchorV3: true)) }))
            XCTAssertEqual(try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: decoded.map(PushBinaryRow.ppgWaveform),
                                                    ppgAnchorV3: true), packed)
        }
    }

    func testSaturationFlagIsDerivedFromTheDeltas() {
        XCTAssertEqual(PushBinaryCodec.ppgSampleFlags(Self.deltas([1, -2, 3])), 0)
        XCTAssertEqual(PushBinaryCodec.ppgSampleFlags(Self.deltas([1, 32767])), 1)
        XCTAssertEqual(PushBinaryCodec.ppgSampleFlags(Self.deltas([-32768, 0])), 1)
        XCTAssertEqual(PushBinaryCodec.ppgSampleFlags(Self.deltas([32766, -32767])), 0)
        XCTAssertEqual(PushBinaryCodec.ppgSampleFlags(Data([0xFF])), 0, "a trailing odd byte is not a sample")
    }

    func testOlderFormatsRefuseAnchorMembersInsteadOfDroppingThem() throws {
        let anchored = Self.phoneRows().map { PushBinaryRow.ppgWaveform($0.record) }
        XCTAssertThrowsError(try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: anchored))
        XCTAssertThrowsError(try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: anchored, ppgIdentityV2: true))
        for version in ["1.2", "1.3", "1.4"] {
            XCTAssertThrowsError(try PushProtocol.binaryObjectBatch(table: .ppgWaveformSample, sourceId: Self.sourceId,
                deviceId: Self.deviceId, startCursor: nil, rows: anchored, protocolVersion: version), version)
        }
        var iterator = anchored.makeIterator()
        XCTAssertThrowsError(try PushBinaryStreamEncoder.visitDecodedBytes(table: .ppgWaveformSample,
            rowCount: anchored.count, ppgIdentityV2: true, nextRow: { iterator.next() }, consume: { _ in }))
    }

    func testDecoderRejectsMalformedFormat3() throws {
        let row = Self.allMemberRows()[0].record
        let packed = try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: [.ppgWaveform(row)], ppgAnchorV3: true)
        // Header 10 | rowId 8 | ts 8 | index 1+8 | burst 1+4 = offset 40: hasAnchor.
        let hasAnchor = 40, clock = 45, hasSubsec = 46, hasFlags = 49, sampleFlags = 51
        XCTAssertEqual(packed[hasAnchor], 1); XCTAssertEqual(packed[clock], 1)
        XCTAssertEqual(packed[hasSubsec], 1); XCTAssertEqual(packed[hasFlags], 1); XCTAssertEqual(packed[sampleFlags], 0)
        for (offset, value) in [(hasAnchor, UInt8(2)), (clock, 2), (hasSubsec, 2), (hasFlags, 9), (sampleFlags, 1), (sampleFlags, 2)] {
            var bad = packed; bad[offset] = value
            XCTAssertThrowsError(try PushBinaryCodec.unpackPpgRecords(bad), "offset \(offset) value \(value)")
        }
        for size in 0..<packed.count { XCTAssertThrowsError(try PushBinaryCodec.unpackPpgRecords(packed.prefix(size))) }
        XCTAssertThrowsError(try PushBinaryCodec.unpackPpgRecords(packed + Data([0])))
        var future = packed; future[4] = 4
        XCTAssertThrowsError(try PushBinaryCodec.unpackPpgRecords(future))
    }

    func testOldFormatsDecodeUnchangedWithNoInferredMembers() throws {
        let v1 = Data([0x4e, 0x50, 0x42, 0x31, 1, 1, 1, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0x32, 0, 0, 0, 0, 0, 0, 0,
                       0, 1, 0, 0, 0, 0x0a])
        let v2 = try PushBinaryCodec.pack(table: .ppgWaveformSample,
            rows: [.ppgWaveform(.init(rowId: 1, ts: 100, burstIndex: 3, samples: Data([1, 2]), recordIndex: 9))],
            ppgIdentityV2: true)
        for bytes in [v1, v2] {
            let records = try PushBinaryCodec.unpackPpgRecords(bytes)
            XCTAssertTrue(records.allSatisfy { $0.anchor == nil && $0.clockSource == .unknown
                && $0.subsecQ15 == nil && $0.frontEndFlags == nil })
            XCTAssertEqual(try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: records.map(PushBinaryRow.ppgWaveform),
                                                    ppgIdentityV2: bytes[4] == 2), bytes)
        }
    }

    func testSchemaNegotiationAndReceiptBinding() throws {
        XCTAssertEqual(PushProtocol.schemaVersion(stream: "ppgWaveformSample", protocolVersion: "1.5"), 3)
        XCTAssertEqual(PushProtocol.schemaVersion(stream: "ppgWaveformSample", protocolVersion: "1.3"), 2)
        // 1.5 is not a superset of 1.4: auxiliary identity and scalar provenance stay exclusive to 1.4.
        XCTAssertEqual(PushProtocol.schemaVersion(stream: "v18AuxSample", protocolVersion: "1.5"), 1)
        XCTAssertEqual(PushProtocol.schemaVersion(stream: "stepSample", protocolVersion: "1.5"), 1)
        XCTAssertEqual(PushProtocol.schemaVersion(stream: "rawImuSession", protocolVersion: "1.5"), 1)
        XCTAssertTrue(PushProtocol.isObjectVersion("1.5") && PushProtocol.hasPPGIdentity("1.5"))
        XCTAssertTrue(PushProtocol.hasPPGAnchor("1.5"))
        XCTAssertFalse(["1.0", "1.1", "1.2", "1.3", "1.4"].contains(where: PushProtocol.hasPPGAnchor))
        // A scalar append at 1.5 carries the 1.3 contract: provenance is still refused.
        let step = PushAppendRecord(rowId: 1, key: ["ts": .int(100)],
            data: ["counter": .int(4), "activityClass": .null,
                   "provenance": .map(["v": .int(1), "origin": .string("legacy-unknown")])])
        XCTAssertThrowsError(try PushProtocol.appendBatch(table: .stepSample, sourceId: Self.sourceId, deviceId: "d",
            startCursor: nil, records: [step], protocolVersion: "1.5"))
        let plain = PushAppendRecord(rowId: 1, key: ["ts": .int(100)], data: ["counter": .int(4), "activityClass": .null])
        XCTAssertEqual(try PushProtocol.appendBatch(table: .stepSample, sourceId: Self.sourceId, deviceId: "d",
            startCursor: nil, records: [plain], protocolVersion: "1.5").protocolVersion, "1.5")

        let batch = try phoneBatch(Self.phoneRows())
        let manifest = PushObjectManifest(batch: batch)
        let owner = try AccountScope(projectURL: "https://example.supabase.co",
                                     userID: "11111111-1111-4111-8111-111111111111")
        func receipt(schema: Int) -> PushDurabilityReceipt {
            .init(version: 1, state: "verified_indexed", receiptId: "22222222-2222-4222-8222-222222222222",
                  ownerUserId: owner.userID, deviceId: "33333333-3333-4333-8333-333333333333",
                  objectId: manifest.objectId, batchId: manifest.batchId, sourceId: manifest.sourceId,
                  stream: manifest.stream, schemaVersion: schema,
                  objectKey: "v3/research/users/\(owner.userID)/devices/33333333-3333-4333-8333-333333333333/ppgWaveformSample/x.bin.gz",
                  contentSha256: manifest.contentSha256, wireSha256: batch.wireSHA256,
                  compressedBytes: manifest.compressedBytes, uncompressedBytes: manifest.uncompressedBytes,
                  verifiedAt: "2026-10-08T00:00:00Z", indexedAt: "2026-10-08T00:00:01Z")
        }
        XCTAssertTrue(receipt(schema: 3).matches(manifest, owner: owner, wireSHA256: batch.wireSHA256, wireBytes: batch.wireBytes))
        XCTAssertFalse(receipt(schema: 2).matches(manifest, owner: owner, wireSHA256: batch.wireSHA256, wireBytes: batch.wireBytes),
                       "a receipt must attest the schema the bytes were packed with")
    }

    func testAnchoredSelectionSurvivesPreparedRoundTrip() throws {
        let rows = Self.allMemberRows().map { PushBinaryRow.ppgWaveform($0.record) }
        let batch = try PushProtocol.binaryObjectBatch(table: .ppgWaveformSample, sourceId: Self.sourceId,
            deviceId: Self.deviceId, startCursor: nil, rows: rows, protocolVersion: "1.5")
        let lane = PushObjectLane(endpoint: "/objects", maxObjectBytes: Int64(PushProtocolLimits.maxObjectWireBytes),
                                  urlTtlSec: 60, streams: [.ppgWaveformSample])
        let manifest = PushObjectManifest(batch: batch)
        let commit = PushSourceCommit(kind: .binary, table: "ppgWaveformSample", deviceID: Self.deviceId,
                                      batchIDs: [batch.batchId], cursor: batch.endCursor)
        let model = try PushPreparedSelection(binary: batch, rows: rows, manifest: manifest, lane: lane, commit: commit)
        let restored = try XCTUnwrap(PushPreparedSelection.decode(model.encoded()).restoredObject())
        XCTAssertEqual((try restored.batch.payload), (try batch.payload))
        let restoredRecords = restored.rows.compactMap { row -> PushPpgWaveformRecord? in
            if case .ppgWaveform(let r) = row { return r }; return nil }
        XCTAssertEqual(restoredRecords.map(\.anchor), Self.allMemberRows().map(\.record.anchor))
        XCTAssertEqual(restoredRecords.map(\.subsecQ15), Self.allMemberRows().map(\.record.subsecQ15))
        XCTAssertEqual(restoredRecords.map(\.clockSource), Self.allMemberRows().map(\.record.clockSource))
    }
}
