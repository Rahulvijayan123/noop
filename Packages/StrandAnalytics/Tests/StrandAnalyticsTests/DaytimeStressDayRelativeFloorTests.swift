import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// BaselineStandard fix F: the day-relative across-hour SD had no floor (only a 0.0001 "is it zero" check), so
/// a near-flat day turned a one-bpm wobble into a HIGH hour and could trip the sustained-high Breathe nudge.
final class DaytimeStressDayRelativeFloorTests: XCTestCase {

    private func hourHR(_ hour: Int, bpm: Int, n: Int = DaytimeStress.minHourHRSamples) -> [HRSample] {
        (0..<n).map { HRSample(ts: hour * 3_600 + $0, bpm: bpm) }
    }

    func testTheFloorsAreTheStandardOnes() {
        XCTAssertEqual(DaytimeStress.dayRelativeHRSDFloor, 1.253 * 3.0, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(DaytimeStress.dayRelativeHRSDFloor, BaselineStandard.scaleFloor(.restingHR))
        XCTAssertEqual(DaytimeStress.dayRelativeRMSSDSDFloor(reference: 40), 1.253 * 7.0, accuracy: 1e-12)
        XCTAssertEqual(DaytimeStress.dayRelativeRMSSDSDFloor(reference: 400), 400 * 0.05, accuracy: 1e-12)
    }

    func testANearFlatDayDoesNotReadAOneBpmHourAsHigh() {
        // Twelve waking hours at 60 bpm and three at 61: across-hour population SD ≈ 0.4 bpm. Without a floor
        // each 61 bpm hour read z ≈ (61 − 60) / 0.4 ≈ 2.5 → level ≈ 2.8 (HIGH), three in a row = sustained.
        var hr: [HRSample] = []
        for h in 7...18 { hr += hourHR(h, bpm: 60) }
        for h in 19...21 { hr += hourHR(h, bpm: 61) }
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        let last = r.scored.last!.level!
        XCTAssertEqual(last, DaytimeStress.squash(1.0 / DaytimeStress.dayRelativeHRSDFloor), accuracy: 1e-9,
                       "(61 − 60) / the 3.76 bpm floor")
        XCTAssertLessThan(last, DaytimeStress.highBandFloor)
        XCTAssertFalse(r.sustainedHigh)
    }
}
