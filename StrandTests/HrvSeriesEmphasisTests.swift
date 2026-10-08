import XCTest
@testable import Strand

/// D6-14: weak intraday HRV slots are drawn de-emphasised and kept out of the line and the read-out.
final class HrvSeriesEmphasisTests: XCTestCase {
    private let t0 = 1_790_869_800

    private func point(_ slot: Int, _ rmssd: Double, weak: Bool? = nil,
                       reasons: [HrvSlotQuality.Reason] = []) -> HrvSeriesPoint {
        HrvSeriesPoint(startTs: t0 + slot * 900, rmssd: rmssd, cleanBeats: 600,
                       context: weak.map { HrvSlotQuality(weak: $0, reasons: reasons) })
    }

    func testEmphasisFollowsTheWorkersWeakFlag() {
        XCTAssertEqual(HrvSeriesEmphasis.emphasis(of: point(0, 60, weak: false)), .full)
        XCTAssertEqual(HrvSeriesEmphasis.emphasis(of: point(0, 60, weak: true, reasons: [.movement])), .deemphasised)
        XCTAssertEqual(HrvSeriesEmphasis.emphasis(of: point(0, 60)), .full,
                       "a point from a snapshot without context keeps its old look")
    }

    func testWeakPointsBreakTheLineAndNeverBecomeTheLatestValue() {
        let points = [point(0, 60, weak: false), point(1, 62, weak: false),
                      point(2, 30, weak: true, reasons: [.movement]),
                      point(3, 58, weak: false), point(4, 25, weak: true, reasons: [.sparseBeats])]
        let runs = HrvSeriesEmphasis.lineRuns(points, slotSeconds: 900)
        XCTAssertEqual(runs.map { $0.map(\.rmssd) }, [[60, 62], [58]],
                       "the line never bridges across a weak slot and never includes one")
        XCTAssertEqual(HrvSeriesEmphasis.latestSupported(points)?.rmssd, 58)
        XCTAssertNil(HrvSeriesEmphasis.latestSupported([point(0, 30, weak: true)]))
    }

    func testAMissingSlotStillBreaksTheLine() {
        let runs = HrvSeriesEmphasis.lineRuns([point(0, 60), point(1, 61), point(3, 59)], slotSeconds: 900)
        XCTAssertEqual(runs.map(\.count), [2, 1])
    }

    func testWeakNoteExplainsWhy() {
        XCTAssertNil(HrvSeriesEmphasis.weakNote([point(0, 60, weak: false), point(1, 60)]))
        XCTAssertEqual(HrvSeriesEmphasis.weakNote([point(0, 30, weak: true, reasons: [.movement])]),
                       "1 faded reading left out of the line and latest value because you were moving.")
        XCTAssertEqual(HrvSeriesEmphasis.weakNote([point(0, 30, weak: true, reasons: [.movement]),
                                                   point(1, 30, weak: true, reasons: [.unknownContext, .sparseBeats])]),
                       "2 faded readings left out of the line and latest value because you were moving, "
                       + "activity was unclear, or there were few clean beats.")
    }
}
