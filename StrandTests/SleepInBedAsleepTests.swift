import XCTest
import WhoopStore
@testable import Strand

/// The Sleep page's window row separates In bed (the night's window start, when the wrist went still) from
/// Asleep (the first sleep epoch of the staged night). Reported night: in bed 01:47:57, staged wake until
/// 02:54:00, and the row said "Asleep 01:47".
final class SleepInBedAsleepTests: XCTestCase {

    private let bed = 1_791_190_077      // 2026-10-05 01:47:57 PDT
    private let asleep = 1_791_194_040   // 02:54:00
    private let wake = 1_791_221_534     // 10:32:14

    private func night(_ stagesJSON: String) -> Night? {
        let s = CachedSleepSession(startTs: bed, endTs: wake, efficiency: nil, restingHr: nil, avgHrv: nil,
                                   stagesJSON: stagesJSON)
        return SleepModel.mergeDay([s], habitualMidsleepSec: nil, motionByStart: [:])
    }

    func testAsleepIsTheFirstSleepEpochAndInBedIsTheWindowStart() throws {
        let n = try XCTUnwrap(night("""
            [{"start":\(bed),"end":\(asleep),"stage":"wake"},{"start":\(asleep),"end":\(asleep + 3_600),"stage":"light"},
             {"start":\(asleep + 3_600),"end":\(wake),"stage":"deep"}]
            """))
        XCTAssertEqual(n.session.effectiveStartTs, bed, "In bed stays the window start")
        XCTAssertEqual(n.asleepTs, asleep)
        XCTAssertEqual(n.asleepText, Night.clockString(asleep))
        XCTAssertNotEqual(n.asleepText, n.onsetText)
    }

    func testANightAsleepFromItsStartShowsTheSameTimeForBoth() throws {
        let n = try XCTUnwrap(night("""
            [{"start":\(bed),"end":\(asleep),"stage":"light"},{"start":\(asleep),"end":\(wake),"stage":"deep"}]
            """))
        XCTAssertEqual(n.asleepTs, bed)
    }

    func testAnImportedNightWithoutATimelineHasNoSeparateAsleepTime() throws {
        let n = try XCTUnwrap(night(#"{"light":300,"deep":90,"rem":100,"awake":30}"#))
        XCTAssertNil(n.asleepTs, "durations alone cannot say when sleep began; the row keeps its two-time form")
    }
}
