import XCTest
@testable import frwhoop_worker

/// Golden + malformed tests for the worker's NPB1 rawImuSession decoder
/// (`Npb1ImuDecoder`). The exact wire layout is pinned two ways:
///   1. against the shared root-owned golden fixtures
///      (nara-activity-research/golden/golden_imu_frames.json +
///      golden_imu_expected.json, CONTRACTS C9), and
///   2. against the NoopPush streaming-npb1-golden rawImuSession vector,
///      embedded below so the layout check never depends on a file.
/// Sample time semantics: record ts is the frame baseTs and sample i of a
/// record is at ts + i/100 (resample-invariant — never BLE arrival time).
final class Npb1ImuDecoderTests: XCTestCase {

    // MARK: - Golden fixtures (shared, root-owned)

    /// Locate the root-owned golden fixtures. The test runner's cwd is the
    /// package root, so both the integration location (package Resources) and
    /// the research-dir location on this machine are tried; the fixture dir
    /// can also be pointed at with FRWHOOP_GOLDEN_DIR.
    private func goldenFixturePath(_ name: String) -> String? {
        if let dir = ProcessInfo.processInfo.environment["FRWHOOP_GOLDEN_DIR"], !dir.isEmpty {
            let p = dir + "/" + name
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        let candidates = [
            "Tests/frwhoop-workerTests/Resources/" + name,
            "../../../nara-activity-research/golden/" + name,
            "../../nara-activity-research/golden/" + name,
            "nara-activity-research/golden/" + name,
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return nil
    }

    private func goldenJSON(_ name: String) throws -> [String: Any] {
        guard let path = goldenFixturePath(name) else {
            throw XCTSkip("golden fixture \(name) not found; set FRWHOOP_GOLDEN_DIR")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw XCTSkip("golden fixture \(name) is not a JSON object")
        }
        return obj
    }

    /// The whoop5-raw-imu-frame fixture layout (C9): magic "PFNE", ts u32 LE
    /// at offset 15, counts u16 at 24/630, axis-major columns starting at
    /// 28/228/428/640/840/1040. The NPB1 record columns blob is the six axis
    /// blocks concatenated (1200 B).
    private func npb1Record(fromFrameHex hex: String) -> Npb1ImuDecoder.Record {
        let frame = hexData(hex)
        let ts = Int64(UInt32(frame[15]) | (UInt32(frame[16]) << 8)
            | (UInt32(frame[17]) << 16) | (UInt32(frame[18]) << 24))
        var columns = [Int16](repeating: 0, count: 600)
        let axes: [(start: Int, block: Int)] = [(28, 0), (228, 1), (428, 2), (640, 3), (840, 4), (1040, 5)]
        for (start, block) in axes {
            for i in 0..<100 {
                let off = start + i * 2
                let lo = UInt16(frame[off])
                let hi = UInt16(frame[off + 1])
                columns[block * 100 + i] = Int16(bitPattern: lo | (hi << 8))
            }
        }
        return Npb1ImuDecoder.Record(rowId: ts, ts: ts, columns: columns)
    }

    /// Decode the golden frames -> exact expected records and values
    /// (golden_imu_expected.json), including resample-invariant baseTs
    /// semantics (ts = baseTs + frame ordinal; sample i at ts + i/100).
    func testGoldenFramesDecodeToExactExpectedValues() throws {
        let frames = try goldenJSON("golden_imu_frames.json")
        let expected = try goldenJSON("golden_imu_expected.json")
        guard let hexFrames = frames["frames"] as? [String], !hexFrames.isEmpty else {
            return XCTFail("golden_imu_frames.json has no frames")
        }
        guard let baseTs = (frames["baseTs"] as? NSNumber)?.intValue else {
            return XCTFail("golden fixture missing baseTs")
        }
        let records = hexFrames.map { npb1Record(fromFrameHex: $0) }
        let packed = try Npb1ImuDecoder.pack(records: records)
        let decoded = try Npb1ImuDecoder.decode(packed)

        // nFrames and the exact last frame baseTs.
        XCTAssertEqual(decoded.count, (expected["nFrames"] as? NSNumber)?.intValue ?? -1)
        XCTAssertEqual(decoded.count, hexFrames.count)
        // resample-invariant baseTs semantics: one record per contiguous
        // second, ts = baseTs + ordinal, rowId mirrors ts.
        for (i, record) in decoded.enumerated() {
            XCTAssertEqual(record.ts, Int64(baseTs + i), "record \(i) ts")
            XCTAssertEqual(record.rowId, record.ts, "rowId mirrors ts")
            XCTAssertEqual(record.columns.count, 600)
        }
        XCTAssertEqual(decoded.last?.ts, Int64((expected["lastFrameBaseTs"] as? NSNumber)?.intValue ?? -1))

        // Exact first-sample values (scaled from the raw i16 by the fixture
        // scales: accel 1/4096 g/LSB, gyro 2000/32768 deg/s per LSB).
        let first = expected["firstSample"] as? [String: Any] ?? [:]
        let accelScale = 0.000244140625
        let gyroScale = 0.06103515625
        let c = decoded[0].columns
        XCTAssertEqual(Double(c[0]) * accelScale, (first["ax"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-6)
        XCTAssertEqual(Double(c[100]) * accelScale, (first["ay"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-6)
        XCTAssertEqual(Double(c[200]) * accelScale, (first["az"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-6)
        XCTAssertEqual(Double(c[300]) * gyroScale, (first["gx"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-4)
        XCTAssertEqual(Double(c[400]) * gyroScale, (first["gy"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-4)
        XCTAssertEqual(Double(c[500]) * gyroScale, (first["gz"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-4)

        // az mean of the first frame's 100 samples. Accumulate in Double:
        // the raw i16 sum exceeds Int16.max and would overflow an Int16 reduce.
        let azMean = c[200..<300].reduce(0.0) { $0 + Double($1) } / 100.0 * accelScale
        XCTAssertEqual(azMean, (expected["azMeanFirstFrame"] as? NSNumber)?.doubleValue ?? -1, accuracy: 1e-5)
    }

    /// The mixed fixture splits at second 7 (1007 missing): two runs, no fill
    /// (see ActivityLaneTests for the timeline/split assertions; here we pin
    /// that the fixture decodes to 11 records with the gap intact).
    func testGoldenMixedFramesDecodeWithGapIntact() throws {
        let mixed = try goldenJSON("golden_imu_mixed.json")
        guard let hexFrames = mixed["frames"] as? [String], !hexFrames.isEmpty else {
            return XCTFail("golden_imu_mixed.json has no frames")
        }
        let records = hexFrames.map { npb1Record(fromFrameHex: $0) }
        let packed = try Npb1ImuDecoder.pack(records: records)
        let decoded = try Npb1ImuDecoder.decode(packed)
        XCTAssertEqual(decoded.count, hexFrames.count)
        let seconds = decoded.map { Int($0.ts) }
        // walking 1000-1005, stationary 1006, gap 1007, walking 1008-1011.
        XCTAssertEqual(seconds, [1758001000, 1758001001, 1758001002, 1758001003,
                                 1758001004, 1758001005, 1758001006, 1758001008,
                                 1758001009, 1758001010, 1758001011])
    }

    // MARK: - NoopPush streaming-npb1-golden layout pin (self-contained)

    /// `decoded_base64` of the rawImuSession vector in
    /// Packages/NoopPush/Tests/NoopPushTests/Resources/streaming-npb1-golden.json
    /// (encoding gzip). Pins the exact header + record layout without any file.
    func testStreamingNpb1GoldenLayout() throws {
        let b64 = "TlBCMQEEAQAAAGQAAAAAAAAAZAAAAAAAAACwBAAAAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7"
            + "PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGSk5SV"
            + "lpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t/g4eLj5OXm5+jp6uvs7e7v"
            + "8PHy8/T19vf4+fr7/P3+/wABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj9AQUJDREVGR0hJ"
            + "SktMTU5PUFFSU1RVVldYWVpbXF1eX2BhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ent8fX5/gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp+goaKj"
            + "pKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+v8DBwsPExcbHyMnKy8zNzs/Q0dLT1NXW19jZ2tvc3d7f4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9"
            + "/v8AAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZX"
            + "WFlaW1xdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+f4CBgoOEhYaHiImKi4yNjo+QkZKTlJWWl5iZmpucnZ6foKGio6SlpqeoqaqrrK2ur7Cx"
            + "srO0tba3uLm6u7y9vr/AwcLDxMXGx8jJysvMzc7P0NHS09TV1tfY2drb3N3e3+Dh4uPk5ebn6Onq6+zt7u/w8fLz9PX29/j5+vv8/f7/AAECAwQFBgcICQoL"
            + "DA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2Rl"
            + "ZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGSk5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/"
            + "wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t/g4eLj5OXm5+jp6uvs7e7v8PHy8/T19vf4+fr7/P3+/wABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZ"
            + "GhscHR4fICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj9AQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpbXF1eX2BhYmNkZWZnaGlqa2xtbm9wcXJz"
            + "dHV2d3h5ent8fX5/gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp+goaKjpKWmp6ipqqusra6v"
        guard let decoded = Data(base64Encoded: b64) else {
            return XCTFail("embedded golden base64 is invalid")
        }
        let records = try Npb1ImuDecoder.decode(decoded)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].rowId, 100)
        XCTAssertEqual(records[0].ts, 100)
        XCTAssertEqual(Array(records[0].columns.prefix(6)), [256, 770, 1284, 1798, 2312, 2826])
    }

    // MARK: - Round trip

    func testPackRoundTrip() throws {
        let records = [
            Npb1ImuDecoder.Record(rowId: 1, ts: 1_758_000_000,
                                  columns: [Int16](repeating: 7, count: 600)),
            Npb1ImuDecoder.Record(rowId: 2, ts: 1_758_000_001,
                                  columns: Array((0..<600).map { Int16($0 % 250) })),
        ]
        let decoded = try Npb1ImuDecoder.decode(Npb1ImuDecoder.pack(records: records))
        XCTAssertEqual(decoded, records)
    }

    // MARK: - Strict bounds checks

    func testRejectsWrongMagic() {
        var bad = Data("APB1".utf8)  // "NPB1" with a corrupted magic byte
        bad.append(contentsOf: [1, 4, 0, 0, 0, 0])
        XCTAssertThrowsError(try Npb1ImuDecoder.decode(bad)) { error in
            XCTAssertEqual(error as? Npb1ImuDecoder.DecodeError, .notNpb1)
        }
    }

    func testRejectsWrongKind() {
        // NPB1, version 1, kind 3 (rawBatch), count 1 -> unsupported kind.
        var data = Data("NPB1".utf8)
        data.append(contentsOf: [1, 3, 1, 0, 0, 0])
        XCTAssertThrowsError(try Npb1ImuDecoder.decode(data)) { error in
            XCTAssertEqual(error as? Npb1ImuDecoder.DecodeError, .unsupportedKind(3))
        }
    }

    func testRejectsWrongVersion() {
        var data = Data("NPB1".utf8)
        data.append(contentsOf: [2, 4, 1, 0, 0, 0])
        XCTAssertThrowsError(try Npb1ImuDecoder.decode(data)) { error in
            XCTAssertEqual(error as? Npb1ImuDecoder.DecodeError, .unsupportedVersion(2))
        }
    }

    func testRejectsTruncatedRecord() {
        let record = Npb1ImuDecoder.Record(rowId: 1, ts: 10, columns: [Int16](repeating: 0, count: 600))
        var packed = try! Npb1ImuDecoder.pack(records: [record])
        packed.removeLast(10)  // truncate inside the columns blob
        XCTAssertThrowsError(try Npb1ImuDecoder.decode(packed)) { error in
            guard case .truncated = error as! Npb1ImuDecoder.DecodeError else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testRejectsTrailingBytes() {
        let record = Npb1ImuDecoder.Record(rowId: 1, ts: 10, columns: [Int16](repeating: 0, count: 600))
        var packed = try! Npb1ImuDecoder.pack(records: [record])
        packed.append(0x00)
        XCTAssertThrowsError(try Npb1ImuDecoder.decode(packed)) { error in
            guard case .trailingBytes(1) = error as! Npb1ImuDecoder.DecodeError else {
                return XCTFail("expected trailingBytes, got \(error)")
            }
        }
    }

    func testRejectsEmptyObject() {
        var data = Data("NPB1".utf8)
        data.append(contentsOf: [1, 4, 0, 0, 0, 0])
        XCTAssertThrowsError(try Npb1ImuDecoder.decode(data)) { error in
            XCTAssertEqual(error as? Npb1ImuDecoder.DecodeError, .emptyObject)
        }
    }

    func testRejectsNonPositiveRowId() {
        let columns = [Int16](repeating: 0, count: 600)
        var out = Data("NPB1".utf8); out.append(contentsOf: [1, 4])
        out.append(contentsOf: [1, 0, 0, 0])
        // rowId = 0
        out.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        // ts = 10
        out.append(contentsOf: [10, 0, 0, 0, 0, 0, 0, 0])
        // length = 1200
        out.append(contentsOf: [0xB0, 0x04, 0, 0])
        for v in columns {
            let le = v.littleEndian
            withUnsafeBytes(of: le) { out.append(contentsOf: $0) }
        }
        XCTAssertThrowsError(try Npb1ImuDecoder.decode(out)) { error in
            guard case .malformedRecord(0, _) = error as! Npb1ImuDecoder.DecodeError else {
                return XCTFail("expected malformedRecord, got \(error)")
            }
        }
    }

    func testRejectsShortColumnBlobAsTruncated() {
        // A record whose declared blob length is not 1200 can never satisfy
        // the exact-size contract: the object is 1230 bytes per record, so a
        // shorter blob is caught as truncated (never yielding partial
        // records).
        var out = Data("NPB1".utf8); out.append(contentsOf: [1, 4])
        out.append(contentsOf: [1, 0, 0, 0])
        out.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0])  // rowId
        out.append(contentsOf: [10, 0, 0, 0, 0, 0, 0, 0]) // ts
        out.append(contentsOf: [0x10, 0, 0, 0])           // length 16 != 1200
        out.append(contentsOf: [UInt8](repeating: 0, count: 16))
        XCTAssertThrowsError(try Npb1ImuDecoder.decode(out)) { error in
            guard case .truncated = error as! Npb1ImuDecoder.DecodeError else {
                return XCTFail("expected truncated, got \(error)")
            }
        }
    }

    func testPackRejectsWrongColumnCount() {
        let bad = Npb1ImuDecoder.Record(rowId: 1, ts: 2, columns: [Int16](repeating: 0, count: 599))
        XCTAssertThrowsError(try Npb1ImuDecoder.pack(records: [bad])) { error in
            XCTAssertEqual(error as? Npb1ImuDecoder.DecodeError, .unexpectedColumnCount(599))
        }
    }

    // MARK: - Helpers

    private func hexData(_ hex: String) -> Data {
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<next], radix: 16)!)
            i = next
        }
        return out
    }
}
