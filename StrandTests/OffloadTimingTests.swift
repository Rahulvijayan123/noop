import XCTest
@testable import Strand

/// The per-offload timing line that says how much of each history burst is the phone's commit (the strap is
/// idle until the ack) and how much is the strap and the radio.
final class OffloadTimingTests: XCTestCase {
    func testShortOffloadsSayNothing() {
        var timing = OffloadTiming()
        for _ in 0..<4 { timing.record(commitMs: 30) }
        XCTAssertNil(timing.line())
    }

    func testLineSplitsLinkFromPhoneCommit() throws {
        var timing = OffloadTiming()
        for ms in [20, 30, 40, 50, 60, 70, 80, 90, 100, 400] { timing.record(commitMs: ms) }
        timing.linkMs = 3_000
        timing.bytes = 30 * 1_024
        timing.decodeMs = 100
        timing.storeMs = 500
        timing.cursorMs = 50
        timing.journalWaitMs = 10
        let line = try XCTUnwrap(timing.line())
        XCTAssertTrue(line.contains("chunks=10"), line)
        XCTAssertTrue(line.contains("bytes=30KB"), line)
        XCTAssertTrue(line.contains("link=3.0s (10.0 KB/s)"), line)
        XCTAssertTrue(line.contains("phoneCommit=0.9s"), line)
        XCTAssertTrue(line.contains("median=70ms p90=400ms"), line)
        XCTAssertTrue(line.contains("store 0.5s"), line)
    }

    func testDurationToMilliseconds() {
        XCTAssertEqual(Backfiller.ms(.milliseconds(470)), 470)
        XCTAssertEqual(Backfiller.ms(.seconds(2) + .milliseconds(5)), 2_005)
    }
}
