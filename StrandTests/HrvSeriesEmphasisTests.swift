import XCTest
@testable import Strand

/// D6-14: weak intraday HRV slots are hatched as untrusted time and kept out of the line and the read-out.
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
                       "1 reading left out of the line and latest value because you were moving.")
        XCTAssertEqual(HrvSeriesEmphasis.weakNote([point(0, 30, weak: true, reasons: [.movement]),
                                                   point(1, 30, weak: true, reasons: [.unknownContext, .sparseBeats])]),
                       "2 readings left out of the line and latest value because you were moving, "
                       + "activity was unclear, or there were few clean beats.")
    }

    func testPendingContextKeepsTheReadingInTheLineAndAsLatest() {
        let pending = point(2, 61, weak: false, reasons: [.contextPending])
        let points = [point(0, 60, weak: false), point(1, 62, weak: false), pending]
        XCTAssertEqual(HrvSeriesEmphasis.emphasis(of: pending), .full)
        XCTAssertEqual(HrvSeriesEmphasis.lineRuns(points, slotSeconds: 900).map(\.count), [3])
        XCTAssertEqual(HrvSeriesEmphasis.latestSupported(points)?.rmssd, 61)
        XCTAssertNil(HrvSeriesEmphasis.weakNote(points))
        XCTAssertEqual(HrvSeriesEmphasis.pendingNote(points),
                       "Activity context is not available yet for the latest readings.")
        XCTAssertEqual(HrvSeriesEmphasis.pendingNote([pending]),
                       "Activity context is not available yet for these readings.")
        XCTAssertNil(HrvSeriesEmphasis.pendingNote([point(0, 60, weak: false)]))
    }

    func testAPendingOnlyFlagFromTheServerNeverFadesAReading() {
        let json: [String: Any] = ["slot_s": t0, "weak": true, "reasons": ["context_pending"]]
        XCTAssertEqual(HrvSlotQuality(json: json)?.weak, false, "pending alone is not a weakness")
        let moving: [String: Any] = ["slot_s": t0, "weak": true, "reasons": ["movement", "context_pending"]]
        XCTAssertEqual(HrvSlotQuality(json: moving)?.weak, true)
        XCTAssertEqual(HrvSlotQuality(json: moving)?.reasons, [.movement, .contextPending])
    }
}
