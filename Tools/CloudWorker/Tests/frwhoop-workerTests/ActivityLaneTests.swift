import XCTest
import CZstd
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

    // MARK: - Run sub-splitting (audit P1-2) + boundary contiguity (audit P3-5)

    /// A 13-hour contiguous timeline (46,800 s) must split into multiple
    /// bounded requests whose serialized lines all stay under the service's
    /// 64 MiB cap, with no request exceeding maxRequestBodySeconds.
    func testRunRequestsSplit13HourContiguousTimelineUnderCap() throws {
        let start: Int64 = 1_758_000_000
        let seconds = (0..<46_800).map { start + Int64($0) }
        var timeline = ActivityLane.ImuTimeline()
        timeline.seconds = seconds
        timeline.columns = [Int16](repeating: 5, count: seconds.count * 600)
        let requests = ActivityLane.runRequests(
            timeline: timeline, run: ActivityLane.Run(start: start, end: start + 46_800))

        XCTAssertGreaterThan(requests.count, 1, "a 13 h run must not be a single request")
        for (i, request) in requests.enumerated() {
            XCTAssertLessThanOrEqual(request.columnsB64.count, ActivityLane.maxRequestBodySeconds,
                                     "chunk \(i) body must be bounded")
            let lineBytes = try requestJSONBytes(request)
            XCTAssertLessThan(lineBytes, 64 * 1024 * 1024,
                              "chunk \(i) request line must stay under the 64 MiB cap")
        }
        // Bodies partition the run at second boundaries, in order.
        let bodies = requests.map { ($0.startTs, $0.endTs) }
        XCTAssertEqual(bodies.first?.0, Int(start))
        XCTAssertEqual(bodies.last?.1, Int(start + 46_800))
        for i in 1..<bodies.count {
            XCTAssertEqual(bodies[i].0, bodies[i - 1].1, "chunks must be contiguous, not overlapping")
        }
        // Interior chunks carry the full 3-s head/tail filter state from the
        // contiguous timeline; the run's data edges carry none beyond it.
        for i in 1..<(requests.count - 1) {
            XCTAssertEqual(requests[i].headB64.count, ActivityLane.boundarySeconds)
            XCTAssertEqual(requests[i].tailB64.count, ActivityLane.boundarySeconds)
        }
    }

    /// The day fold must see every window at most once across chunk
    /// boundaries, with the ONLY loss being the single 4-s window that
    /// straddles each interior boundary — the serve protocol's documented
    /// full-containment rule (windows must be fully inside the chunk body, so
    /// a window whose 4 s span a boundary has data in two chunks and is
    /// dropped by both; verified empirically against the real serve.py). No
    /// other window is duplicated or lost.
    func testRunRequestsNoWindowDuplicatedOrLostAtChunkBoundaries() throws {
        let start: Int64 = 100_000
        let seconds = (0..<7_300).map { start + Int64($0) }   // ~2 h contiguous
        var timeline = ActivityLane.ImuTimeline()
        timeline.seconds = seconds
        timeline.columns = [Int16](repeating: 0, count: seconds.count * 600)
        let run = ActivityLane.Run(start: start, end: start + 7_300)
        let chunkSeconds = 1_800
        let requests = ActivityLane.runRequests(timeline: timeline, run: run,
                                                maxBodySeconds: chunkSeconds)

        // Whole-run window grid: 4-s windows, 2-s hop, fully inside the run.
        var wholeRun: Set<Int> = []
        var w = Int(start)
        while w + 4 <= Int(start) + 7_300 { wholeRun.insert(w); w += 2 }

        // Simulate serve's emission per chunk (windows fully inside the body,
        // anchored at the chunk start): collect starts, dedupe.
        var seen = Set<Int>()
        for request in requests {
            var w = request.startTs
            while w + 4 <= request.endTs {
                XCTAssertTrue(seen.insert(w).inserted, "window at \(w) emitted by two chunks")
                w += 2
            }
        }

        // Expected loss: exactly one straddling window per interior boundary
        // (boundary-2, on the whole-run grid, spans [boundary-2, boundary+2)).
        var boundaries: [Int] = []
        var b = Int(start) + chunkSeconds
        while b < Int(start) + 7_300 { boundaries.append(b); b += chunkSeconds }
        var expected = wholeRun
        for boundary in boundaries {
            expected.remove(boundary - 2)
        }
        // Bodies partition the run at second boundaries (never overlap), so
        // the only loss is the protocol's boundary straddle.
        for i in 1..<requests.count {
            XCTAssertEqual(requests[i].startTs, requests[i - 1].endTs)
        }
        XCTAssertEqual(seen, expected, "no window lost or duplicated beyond the boundary straddle")
    }

    /// Chunks adjacent to a data gap pass NO fabricated head/tail: a missing
    /// second ends the boundary chain (audit P3-5). Interior chunks of a
    /// contiguous run keep the full 3-s filter state.
    func testRunRequestsGapAdjacentChunksPassNoFabricatedBoundary() {
        // Seconds 0..29 and 31..60: a 1-s gap at second 30.
        var seconds: [Int64] = []
        seconds.append(contentsOf: (0..<30).map { Int64($0) })
        seconds.append(contentsOf: (31..<61).map { Int64($0) })
        var timeline = ActivityLane.ImuTimeline()
        timeline.seconds = seconds
        timeline.columns = [Int16](repeating: 0, count: seconds.count * 600)

        // Run A [0,30) at maxBody 10: the last chunk [20,30) must NOT fabricate
        // a tail across the gap (second 30 is missing; second 31 is not
        // contiguous with the chunk).
        let runA = ActivityLane.Run(start: 0, end: 30)
        let reqA = ActivityLane.runRequests(timeline: timeline, run: runA, maxBodySeconds: 10)
        XCTAssertEqual(reqA.count, 3)
        XCTAssertEqual(reqA[2].startTs, 20)
        XCTAssertEqual(reqA[2].endTs, 30)
        XCTAssertTrue(reqA[2].tailB64.isEmpty, "chunk ending at a gap must not fabricate a tail")
        // Interior chunk [10,20) has full tail state (seconds 20,21,22 exist
        // and are contiguous).
        XCTAssertEqual(reqA[1].tailB64.count, ActivityLane.boundarySeconds)

        // Run B [31,61): the first chunk [31,41) must NOT fabricate a head
        // across the gap (second 30 missing).
        let runB = ActivityLane.Run(start: 31, end: 61)
        let reqB = ActivityLane.runRequests(timeline: timeline, run: runB, maxBodySeconds: 10)
        XCTAssertEqual(reqB.count, 3)
        XCTAssertEqual(reqB[0].startTs, 31)
        XCTAssertTrue(reqB[0].headB64.isEmpty, "chunk starting after a gap must not fabricate a head")
        // Interior chunk [41,51) has full head state (seconds 38,39,40).
        XCTAssertEqual(reqB[1].headB64.count, ActivityLane.boundarySeconds)
    }

    /// Head/tail boundary context is contiguous with the run edge only: a
    /// present-but-discontiguous second (separated by a missing second) is
    /// never included (audit P3-5 — the old boundarySeconds silently merged
    /// such a second into resample state).
    func testBoundarySecondsNeverBridgeAGap() {
        // Timeline seconds 97, 99, 100..104: second 98 is missing, so 99 is
        // present but NOT contiguous with 100.
        let columns = [Int16](repeating: 0, count: 600)
        let records = [Int64(97), 99, 100, 101, 102, 103, 104].map {
            Npb1ImuDecoder.Record(rowId: $0, ts: $0, columns: columns)
        }
        let timeline = try! ActivityLane.buildTimeline(records: records)

        let head = ActivityLane.headBoundary(timeline: timeline, runStart: 100)
        XCTAssertEqual(head.count, 1, "only the contiguous second 99, never 97")
        let tail = ActivityLane.tailBoundary(timeline: timeline, runEnd: 103)
        XCTAssertEqual(tail.count, 2, "contiguous seconds 103,104")

        // A run starting at the data edge gets no head at all.
        let noHead = ActivityLane.headBoundary(timeline: timeline, runStart: 97)
        XCTAssertTrue(noHead.isEmpty, "97 is the first second")
        // A run at the data edge gets no tail either.
        let noTail = ActivityLane.tailBoundary(timeline: timeline, runEnd: 105)
        XCTAssertTrue(noTail.isEmpty, "105 is the last second")
    }

    // MARK: - Model version resolution (audit P1-3 / P3-6)

    func testResolvedVersionsUseReportedOrBaselineFallback() {
        // The child's reported versions flow into the document unchanged.
        let (model, preprocessing) = ActivityLane.resolvedVersions(
            reportedModel: "hart-activity-v1",
            reportedPreprocessing: "hart-activity-preprocess-v1")
        XCTAssertEqual(model, "hart-activity-v1")
        XCTAssertEqual(preprocessing, "hart-activity-preprocess-v1")

        // Fallback when the child reported nothing: what serve reports for
        // the baseline manifest — never a hard-coded 'hart-activity-1'.
        let (fbModel, fbPreprocessing) = ActivityLane.resolvedVersions(
            reportedModel: nil, reportedPreprocessing: nil)
        XCTAssertEqual(fbModel, "baseline-v0")
        XCTAssertEqual(fbPreprocessing, "1.0.0")
        // Empty strings behave like nil (a partial ping must not stamp junk).
        let (emptyModel, emptyPre) = ActivityLane.resolvedVersions(
            reportedModel: "", reportedPreprocessing: "")
        XCTAssertEqual(emptyModel, "baseline-v0")
        XCTAssertEqual(emptyPre, "1.0.0")
    }

    // MARK: - Supersede release semantics (audit P2-2)

    /// releaseLease must pass the CLAIMED revision to fail_activity_context_v2.
    /// The fenced fail RPC treats a mismatch (the queue moved past us) as a
    /// CLEAN release — counters reset, no backoff, no dead-letter — and an
    /// unchanged revision as one honest backoff. Passing the row's CURRENT
    /// revision would record a failure + backoff against a never-processed
    /// revision (reproduced live in the audit).
    func testReleaseFailurePassesClaimedRevision() {
        // Superseded: current input_revision (6) > claimed (5) -> the RPC sees
        // a mismatch and releases cleanly. The failure call must carry 5.
        let superseded = ActivityLane.releaseFailure(claimedRevision: 5)
        XCTAssertEqual(superseded.revision, 5)
        XCTAssertTrue(superseded.error.contains("claimed_revision=5"))

        // Unchanged revision: still passes the claimed revision (== current),
        // which the RPC counts as one honest backoff.
        let unchanged = ActivityLane.releaseFailure(claimedRevision: 5)
        XCTAssertEqual(unchanged.revision, 5)
    }

    // MARK: - Lease renewal around downloads (audit P3-4)

    /// The lease must be renewed BEFORE each object's download, not only
    /// before inference: a long B2 download/decode phase can outlive the
    /// 300 s lease and make the later publish return NULL.
    func testLoadObjectsRenewsLeaseBeforeEachObjectDownload() throws {
        // Three records across two seconds' worth of NPB1 data, compressed.
        let record = Npb1ImuDecoder.Record(rowId: 1, ts: 1_758_000_000,
                                           columns: [Int16](repeating: 7, count: 600))
        let packed = try Npb1ImuDecoder.pack(records: [record, record])
        let wire = try zstdCompress(packed)
        let digest = sha256Hex(packed)

        let objects = [
            (id: "obj-1", digest: digest, key: "k1"),
            (id: "obj-2", digest: digest, key: "k2"),
            (id: "obj-3", digest: digest, key: "k3"),
        ]
        var renewOrder: [String] = []
        var renewCount = 0
        var downloadOrder: [String] = []
        let records = try ActivityLane.loadObjects(
            objects: objects,
            renew: {
                renewCount += 1
                renewOrder.append("renew")
                return true
            },
            download: { key in
                downloadOrder.append("download:\(key)")
                return wire
            })
        XCTAssertEqual(renewCount, 3, "renew must be called once per object")
        XCTAssertEqual(downloadOrder.count, 3)
        // Renew strictly precedes each download.
        XCTAssertEqual(renewOrder.count, downloadOrder.count)
        for i in 0..<renewOrder.count {
            XCTAssertEqual(renewOrder[i], "renew")
            XCTAssertEqual(downloadOrder[i], "download:k\(i + 1)")
        }
        XCTAssertEqual(records.count, 2 * 3, "all decoded records are collected")
    }

    /// A lost lease during the download phase aborts deterministically as
    /// `.stale` (the queue owns the job again) without settling a failure.
    func testLoadObjectsStopsWhenLeaseLostDuringDownload() throws {
        let record = Npb1ImuDecoder.Record(rowId: 1, ts: 1, columns: [Int16](repeating: 0, count: 600))
        let packed = try Npb1ImuDecoder.pack(records: [record])
        let wire = try zstdCompress(packed)
        let digest = sha256Hex(packed)
        let objects = [
            (id: "o1", digest: digest, key: "k1"),
            (id: "o2", digest: digest, key: "k2"),
        ]
        var renews = 0
        XCTAssertThrowsError(try ActivityLane.loadObjects(
            objects: objects,
            renew: {
                renews += 1
                return renews == 1   // second object's renew fails
            },
            download: { _ in wire })) { error in
            guard let pe = error as? PostgresClient.Error else {
                return XCTFail("expected PostgresClient.Error, got \(error)")
            }
            XCTAssertEqual(pe.kind, .stale)
        }
        XCTAssertEqual(renews, 2, "the failing renew is still attempted")
    }

    /// A digest mismatch on one object is a deterministic input error.
    func testLoadObjectsRejectsDigestMismatch() throws {
        let record = Npb1ImuDecoder.Record(rowId: 1, ts: 1, columns: [Int16](repeating: 0, count: 600))
        let packed = try Npb1ImuDecoder.pack(records: [record])
        let wire = try zstdCompress(packed)
        let objects = [(id: "o1", digest: String(repeating: "0", count: 64), key: "k1")]
        XCTAssertThrowsError(try ActivityLane.loadObjects(
            objects: objects,
            renew: { true },
            download: { _ in wire })) { error in
            guard let ae = error as? ActivityLane.ActivityError,
                  case .deterministic(let detail) = ae else {
                return XCTFail("expected deterministic error, got \(error)")
            }
            XCTAssertTrue(detail.hasPrefix("digest_mismatch"))
        }
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

    // MARK: - Helpers

    /// Serialize one RunRequest exactly as `ActivityPythonService.infer` does
    /// (sorted keys, newline) and return the line byte count — the quantity
    /// `roundTrip` compares against `maxRequestBytes`.
    private func requestJSONBytes(_ r: ActivityPythonService.RunRequest) throws -> Int {
        let request: [String: Any] = [
            "op": "infer",
            "run": [
                "start_ts": r.startTs,
                "end_ts": r.endTs,
                "sample_rate_hz": 100,
                "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"],
                "units": ["accel": "g", "gyro": "deg/s"],
                "columns_b64": r.columnsB64,
            ],
            "head_b64": r.headB64,
            "tail_b64": r.tailB64,
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        return data.count + 1
    }

    /// zstd-compress raw NPB1 bytes for the injected download closure
    /// (mirrors ArchiveLane.zstdCompress; level 3 is fine for tests).
    private func zstdCompress(_ data: Data) throws -> Data {
        let bound = Int(CZstd.ZSTD_compressBound(data.count))
        var dst = [UInt8](repeating: 0, count: bound)
        let written: Int = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            dst.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
                Int(CZstd.ZSTD_compress(out.baseAddress, out.count, src.baseAddress, src.count, 3))
            }
        }
        guard CZstd.ZSTD_isError(written) == 0, written > 0, written <= bound else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "zstd compress failed"])
        }
        return Data(dst[0..<written])
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
