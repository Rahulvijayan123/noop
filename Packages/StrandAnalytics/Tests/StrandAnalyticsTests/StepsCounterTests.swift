import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Unit tests for the shared windowed step kernel `StepsCounter.stepsInWindow` (#398). The same
/// wrap-aware positive-delta math the daily total uses (see StepsDailyTests), but exercised directly and
/// order-independently so a manual-workout window can reuse it. Returns the RAW motion-tick total (before
/// the caller's `stepTicksPerStep` calibration). Mirrors the Android StepsCounterTest vectors value-for-value.
final class StepsCounterTests: XCTestCase {

    private func step(_ ts: Int, _ counter: Int, _ activityClass: Int? = nil) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: activityClass)
    }

    func testSumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(60, 150), step(120, 220)]), 120)
    }

    func testSortsUnorderedInput() {
        // Same three samples shuffled — the kernel sorts by ts, so the result is identical (120).
        XCTAssertEqual(StepsCounter.stepsInWindow([step(120, 220), step(0, 100), step(60, 150)]), 120)
    }

    func testHandlesU16Wraparound() {
        // 65500 -> 20 wraps: (20 - 65500) & 0xFFFF = 56, a small real increment; then 20 -> 80 => 60.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 65_500), step(60, 20), step(120, 80)]), 116)
    }

    func testFewerThanTwoSamplesIsNil() {
        XCTAssertNil(StepsCounter.stepsInWindow([]))
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100)]))
    }

    func testNoForwardMovementIsNil() {
        // Flat counter across the window => no positive delta => nil (not 0).
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 500), step(60, 500), step(120, 500)]))
    }

    func testDropsBigGapDeltaAsBoundary() {
        // A jump >= 512 (sync-gap / reboot boundary) is dropped; the real 40 + 30 survive.
        // 100 -> 140 (=40) -> 5000 (=4860, dropped) -> 5030 (=30) => 70.
        XCTAssertEqual(StepsCounter.stepsInWindow(
            [step(0, 100), step(60, 140), step(120, 5_000), step(180, 5_030)]), 70)
    }

    func testMaxStepDeltaBoundaryIsExclusive() {
        // Exactly maxStepDelta (512) is dropped; 511 counts.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 0), step(128, 512)]), nil)   // absolute guard
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 0), step(128, 511)]), 511)
    }

    func testRejectsBurstsThatAreNeitherGaitNorABoutBlock() {
        // Four ticks a second is the gait ceiling and six ticks is the smallest block the strap credits, so
        // five in one second is neither; twenty-one is above the largest block we accept.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(1, 104)]), 4)
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100), step(1, 105)]))
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100), step(1, 121)]))
        // The same seven ticks spread over time stay recoverable.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(2, 107)]), 7)
    }

    func testBoutBlockBoundsAreInclusive() {
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100, 0), step(1, 105, 0)]))
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100, 0), step(1, 106, 0)]), 6)
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100, 0), step(1, 120, 0)]), 20)
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100, 0), step(1, 121, 0)]))
    }

    func testBoutBlockCountsWhateverItsLabelOnAClassedDay() {
        // A block of exactly six is always labelled still: the label flips to walk on the seventh step.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100, 0), step(1, 106, 0)]), 6)
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100, 0), step(1, 107, 1)]), 7)
        // One missing 1 Hz record is tolerated; three seconds is no longer a block and the label decides.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100, 0), step(2, 106, 0)]), 6)
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100, 0), step(3, 106, 0)]))
        // Small still-labelled increments are not blocks and stay rejected.
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100, 0), step(1, 102, 0)]))
    }

    func testUnlabelledBlockOnAClassedDayIsStillRejected() {
        // Unknown stays unknown: a record with no label is rejected on a classed day, block or not.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100, 1), step(1, 101, 1), step(2, 108, nil)]), 1)
        // On a wholly unclassed legacy window every plausible increment counts, blocks included.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(1, 107)]), 7)
    }

    func testBoutBlockIsWrapAwareAndCounterResetsAreNotBlocks() {
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 65_530, 0), step(1, 4, 0)]), 10)
        // A reset drops the counter, so the u16 difference is ~65,500: far above any block.
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 100, 0), step(1, 94, 0)]))
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 60_849, 0), step(1, 6, 0)]))
    }

    /// A live walking test on a WHOOP 5/MG: bouts of a few steps with brief stops between them, as
    /// (second, increment, activity class) for every second the counter moved. Six bursts, each opening with
    /// a 6 or 7 tick block, then one lone block 45 s after the last movement. The old class and 4 ticks/second
    /// gates kept only the 42 smooth ticks of the bursts and discarded every block (39 ticks in the bursts).
    private static let walkTest: [(at: Int, ticks: Int, cls: Int)] = [
        (14, 6, 0), (22, 7, 1), (23, 1, 1), (30, 6, 0), (33, 1, 1), (34, 2, 1), (35, 1, 1), (36, 2, 1),
        (37, 1, 1), (38, 1, 1), (40, 2, 1), (41, 2, 1), (42, 1, 1), (43, 2, 1), (44, 1, 1), (45, 2, 1),
        (46, 1, 1), (56, 7, 1), (57, 2, 1), (58, 1, 1), (64, 6, 0), (65, 2, 1), (66, 1, 1), (67, 1, 1),
        (73, 7, 1), (74, 1, 1), (75, 2, 1), (78, 2, 1), (79, 2, 1), (80, 1, 1), (81, 2, 1), (82, 2, 1),
        (83, 1, 1), (84, 2, 1), (129, 6, 0),
    ]

    private func walkTestStream(through last: Int) -> [StepSample] {
        var moves: [Int: (ticks: Int, cls: Int)] = [:]
        for move in Self.walkTest { moves[move.at] = (move.ticks, move.cls) }
        var counter = 343
        return (0...last).map { second in
            guard let move = moves[second] else { return step(second, counter, 0) }
            counter += move.ticks
            return step(second, counter, move.cls)
        }
    }

    func testRecordedWalkTestCountsEveryBoutBlock() {
        XCTAssertEqual(StepsCounter.stepsInWindow(walkTestStream(through: 100)), 81)
        XCTAssertEqual(StepsCounter.stepsInWindow(walkTestStream(through: 130)), 87)
    }

    func testWindowsThatShareOneBoundarySampleSumToTheDayTotal() throws {
        // The per-minute series re-reads the sample before each window's first increment. Because a block is
        // judged from that pair alone, any such partition of the day adds up to the whole.
        let stream = walkTestStream(through: 130)
        let whole = try XCTUnwrap(StepsCounter.stepsInWindow(stream))
        for width in [2, 7, 11, 60] {
            var parts = 0
            var start = 0
            while start < stream.count - 1 {
                let end = min(start + width, stream.count)
                parts += StepsCounter.stepsInWindow(Array(stream[start..<end])) ?? 0
                start = end - 1
            }
            XCTAssertEqual(parts, whole, "window width \(width)")
        }
    }

    func testClassedStreamCountsOnlyWalkAndRunDeltas() {
        // Attribute each counter delta to the later sample, matching the strap's per-record class.
        // still: +10 ignored; walk: +20; run: +15; unknown: +25 ignored => 35 locomotion ticks.
        XCTAssertEqual(StepsCounter.stepsInWindow([
            step(0, 100, 0),
            step(10, 110, 0),
            step(20, 130, 1),
            step(30, 145, 2),
            step(40, 170, nil),
        ]), 35)
    }

    func testLegacyUnclassedStreamKeepsCounterFallback() {
        // Rows written before activityClass existed must retain their historical estimate.
        XCTAssertEqual(StepsCounter.stepsInWindow([
            step(0, 100), step(10, 140), step(20, 170),
        ]), 70)
    }
}
