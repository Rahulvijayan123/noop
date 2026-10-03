import XCTest
@testable import Strand

/// The Today hero rings must follow live data: Baseline fills while it is still learning, Watchdog tracks
/// heart rate against resting and max, and Recovery states what it does not know.
final class HeroRingsTests: XCTestCase {

    private typealias Display = LiquidTodayView.ChargeDisplay

    func testLearningProgressScalesWithNights() {
        XCTAssertEqual(HeroRings.learningProgress(nights: 0, needed: 4), 0)
        XCTAssertEqual(HeroRings.learningProgress(nights: 1, needed: 4), 25)
        XCTAssertEqual(HeroRings.learningProgress(nights: 3, needed: 4), 75)
        XCTAssertEqual(HeroRings.learningProgress(nights: 9, needed: 4), 100)
        XCTAssertEqual(HeroRings.learningProgress(nights: 2, needed: 0), 0)
    }

    func testHeartLoadIsShareOfReserve() {
        XCTAssertEqual(HeroRings.heartLoad(bpm: 60, resting: 60, max: 180), 0)
        XCTAssertEqual(HeroRings.heartLoad(bpm: 120, resting: 60, max: 180), 50)
        XCTAssertEqual(HeroRings.heartLoad(bpm: 200, resting: 60, max: 180), 100)
        XCTAssertEqual(HeroRings.heartLoad(bpm: 50, resting: 60, max: 180), 0)
    }

    func testHeartLoadIsNilWithoutAUsableReading() {
        XCTAssertNil(HeroRings.heartLoad(bpm: nil, resting: 60, max: 180))
        XCTAssertNil(HeroRings.heartLoad(bpm: 0, resting: 60, max: 180))
        XCTAssertNil(HeroRings.heartLoad(bpm: 90, resting: 180, max: 180))
    }

    func testWatchdogStatusBands() {
        XCTAssertEqual(HeroRings.watchdogStatus(load: 5), String(localized: "Calm"))
        XCTAssertEqual(HeroRings.watchdogStatus(load: 30), String(localized: "Active"))
        XCTAssertEqual(HeroRings.watchdogStatus(load: 80), String(localized: "Elevated"))
        XCTAssertEqual(HeroRings.watchdogStatus(load: nil), String(localized: "No data"))
    }

    func testRecoveryStatusBands() {
        XCTAssertEqual(HeroRings.recoveryStatus(score: 80), String(localized: "On track"))
        XCTAssertEqual(HeroRings.recoveryStatus(score: 50), String(localized: "Building"))
        XCTAssertEqual(HeroRings.recoveryStatus(score: 10), String(localized: "Behind"))
        XCTAssertEqual(HeroRings.recoveryStatus(score: nil), String(localized: "No data"))
    }

    func testBaselineRingFillsWhileCalibrating() {
        XCTAssertEqual(Display.calibrating(nights: 1).ringValue, 25)
        XCTAssertEqual(Display.scored(pct: 72).ringValue, 72)
        XCTAssertEqual(Display.carried(pct: 58, caption: "Last night").ringValue, 58)
        XCTAssertNil(Display.noData.ringValue)
    }
}
