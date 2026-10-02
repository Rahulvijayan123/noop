import XCTest
@testable import frwhoop_worker

/// Pure-logic tests for ActivityLane: per-second timeline reconstruction,
/// contiguous-run splitting (gaps / clock resets never filled), run-request
/// building (C10 serve protocol), job-row array parsing, and UTC day bounds.
/// No DB, no B2, no Python.
final class ActivityLaneTests: XCTestCase {

    // MARK: - Timeline reconstruction

    func testBuildTimelineSortsAndDedupesIdenticalSeconds() throws {
        let colsA = [Int16](repeating: 3, count: 600)
        let colsB = [Int16](repeating: 4, count: 600)
        let records = [
            Npb1ImuDecoder.Record(rowId: 3, ts: 3, columns: colsA),
            Npb1ImuDecoder.Record(rowId: 1, ts: 1, columns: colsB),
            Npb1ImuDecoder.Record(rowId: 3, ts: 3, columns: colsA),  // identical duplicate
        ]
        let timeline = try ActivityLane.buildTimeline(records: records)
        XCTAssertEqual(timeline.seconds, [1, 3])
        XCTAssertEqual(timeline.columns.count, 2 * 600)
        XCTAssertEqual(Array(timeline.columns[0..<600]), colsB)
        XCTAssertEqual(Array(timeline.columns[600..<1200]), colsA)
    }

    func testBuildTimelineRejectsConflictingDuplicateSecond() throws {
        let records = [
            Npb1ImuDecoder.Record(rowId: 5, ts: 5, columns: [Int16](repeating: 1, count: 600)),
            Npb1ImuDecoder.Record(rowId: 5, ts: 5, columns: [Int16](repeating: 2, count: 600)),
        ]
        XCTAssertThrowsError(try ActivityLane.buildTimeline(records: records)) { error in
            guard let ae = error as? ActivityLane.ActivityError,
                  case .deterministic(let detail) = ae else {
                return XCTFail("expected deterministic error, got \(error)")
            }
            XCTAssertTrue(detail.hasPrefix("conflicting_duplicate_second"))
        }
    }

    // MARK: - Run splitting (never fill)

    func testSplitRunsContiguousSingleRun() {
        let seconds = [Int64](1000...1010)
        XCTAssertEqual(ActivityLane.splitRuns(seconds: seconds), [ActivityLane.Run(start: 1000, end: 1011)])
    }

    func testSplitRunsAtGap() {
        // seconds 0..6 and 8..11: second 7 missing -> two runs, no fill.
        var seconds: [Int64] = []
        seconds.append(contentsOf: (0...6).map { Int64($0) })
        seconds.append(contentsOf: (8...11).map { Int64($0) })
        XCTAssertEqual(ActivityLane.splitRuns(seconds: seconds),
                                   [ActivityLane.Run(start: 0, end: 7), ActivityLane.Run(start: 8, end: 12)])
    }

    func testSplitRunsAtClockReset() {
        // A backward jump is a clock reset -> new run, never a fill.
        // 100,101,102 form a run; 99 (reset) starts a new run; 100 continues it.
        let seconds: [Int64] = [100, 101, 102, 99, 100]
        XCTAssertEqual(ActivityLane.splitRuns(seconds: seconds),
                                   [ActivityLane.Run(start: 100, end: 103), ActivityLane.Run(start: 99, end: 101)])
    }

    func testSplitRunsEmpty() {
        XCTAssertEqual(ActivityLane.splitRuns(seconds: []), [])
    }

    func testSplitRunsSingleSecond() {
        XCTAssertEqual(ActivityLane.splitRuns(seconds: [7]), [ActivityLane.Run(start: 7, end: 8)])
    }

    /// golden_imu_mixed.json layout: walking 1000-1005, stationary 1006,
    /// gap second 1007, walking 1008-1011 (C9). Decoding the fixture and
    /// splitting must yield exactly two runs with the gap intact.
    func testGoldenMixedSplitsIntoTwoRuns() throws {
        guard let path = goldenFixturePath("golden_imu_mixed.json") else {
            throw XCTSkip("golden_imu_mixed.json not found; set FRWHOOP_GOLDEN_DIR")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = try XCTUnwrap((try JSONSerialization.jsonObject(with: data)) as? [String: Any])
        let hexFrames = try XCTUnwrap(obj["frames"] as? [String])
        let records = hexFrames.map { npb1Record(fromFrameHex: $0) }
        let timeline = try ActivityLane.buildTimeline(records: records)
        let runs = ActivityLane.splitRuns(seconds: timeline.seconds)
        XCTAssertEqual(runs.count, 2, "gap at second 1007 must split the timeline")
        XCTAssertEqual(runs[0], ActivityLane.Run(start: 1_758_001_000, end: 1_758_001_007))
        XCTAssertEqual(runs[1], ActivityLane.Run(start: 1_758_001_008, end: 1_758_001_012))
        // No fill: the gap second is simply absent from the timeline.
        XCTAssertFalse(timeline.seconds.contains(1_758_001_007))
    }

    // MARK: - Run request building (C10 serve protocol)

    func testRunRequestColumnsPerSecondAndBoundaryContext() throws {
        // Timeline: seconds 100..103 plus boundary seconds 99 and 104 so head
        // and tail can be exercised; run is [100, 103).
        let columns = [Int16](repeating: 9, count: 600)
        let records = [99, 100, 101, 102, 103, 104].map { ts in
            Npb1ImuDecoder.Record(rowId: Int64(ts), ts: Int64(ts), columns: columns)
        }
        let timeline = try ActivityLane.buildTimeline(records: records)
        let request = ActivityLane.runRequest(timeline: timeline, run: ActivityLane.Run(start: 100, end: 103))

        XCTAssertEqual(request.startTs, 100)
        XCTAssertEqual(request.endTs, 103)
        XCTAssertEqual(request.columnsB64.count, 3)
        // Each column decodes to exactly 1200 bytes of i16 = 9.
        for b64 in request.columnsB64 {
            let data = Data(base64Encoded: b64)
            XCTAssertEqual(data?.count, 1200)
            XCTAssertEqual(data?.prefix(2).map { $0 }, [9, 0])
        }
        // Head: up to 3 seconds before 100 -> [99]. Tail: seconds 103..106
        // present in timeline -> [103, 104].
        XCTAssertEqual(request.headB64.count, 1)
        XCTAssertEqual(request.tailB64.count, 2)
    }

    func testRunRequestEmptyBoundaryAtDataEdge() throws {
        // Run starts at the first second and ends at the last: no head/tail.
        let columns = [Int16](repeating: 0, count: 600)
        let records = [Int64(100), 101, 102].map {
            Npb1ImuDecoder.Record(rowId: $0, ts: $0, columns: columns)
        }
        let timeline = try ActivityLane.buildTimeline(records: records)
        let request = ActivityLane.runRequest(timeline: timeline, run: ActivityLane.Run(start: 100, end: 103))
        XCTAssertTrue(request.headB64.isEmpty)
        XCTAssertTrue(request.tailB64.isEmpty)
        XCTAssertEqual(request.columnsB64.count, 3)
    }

    // MARK: - Job row parsing

    func testParsePGArray() {
        XCTAssertEqual(ActivityLane.parsePGArray("{a,b,c}"), ["a", "b", "c"])
        XCTAssertEqual(ActivityLane.parsePGArray(#"{"a","b"}"#), ["a", "b"])
        XCTAssertEqual(ActivityLane.parsePGArray("{\"esc\\\"aped\"}"), ["esc\"aped"])
        XCTAssertEqual(ActivityLane.parsePGArray("{}"), [])
        XCTAssertEqual(ActivityLane.parsePGArray(nil), [])
        XCTAssertEqual(ActivityLane.parsePGArray("not-an-array"), [])
    }

    // MARK: - UTC day bounds

    func testUTCDayBounds() {
        let bounds = ActivityLane.utcDayBounds("2026-09-15")
        // 2026-09-15 00:00 UTC epoch.
        XCTAssertEqual(bounds?.start, 1_789_430_400)
        XCTAssertEqual(bounds?.end, 1_789_430_400 + 86_400)
    }

    func testUTCDayBoundsRejectsMalformed() {
        XCTAssertNil(ActivityLane.utcDayBounds("not-a-date"))
        XCTAssertNil(ActivityLane.utcDayBounds("2026-13-40"))
    }

    // MARK: - Fixture helpers (mirror the decoder tests)

    private func goldenFixturePath(_ name: String) -> String? {
        if let dir = ProcessInfo.processInfo.environment["FRWHOOP_GOLDEN_DIR"], !dir.isEmpty {
            let p = dir + "/" + name
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        for c in ["Tests/frwhoop-workerTests/Resources/" + name,
                  "../../../nara-activity-research/golden/" + name,
                  "../../nara-activity-research/golden/" + name,
                  "nara-activity-research/golden/" + name]
        where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return nil
    }

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
