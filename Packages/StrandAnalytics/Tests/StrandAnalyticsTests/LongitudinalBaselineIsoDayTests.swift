import XCTest
@testable import StrandAnalytics

/// `isoFromEpochDay` names a day for every epoch of every window of the baseline replay, so it is hand-built
/// rather than formatted. It must stay byte-identical to the `%04d-%02d-%02d` it replaced.
final class LongitudinalBaselineIsoDayTests: XCTestCase {
    func testIsoStringMatchesFormatter() {
        for year in stride(from: 0, through: 9999, by: 7) {
            for month in 1...12 {
                for day in [1, 9, 10, 28, 31] {
                    XCTAssertEqual(LongitudinalBaseline.isoString(year: year, month: month, day: day),
                                   String(format: "%04d-%02d-%02d", year, month, day))
                }
            }
        }
    }

    func testOutOfRangeFallsBackToTheFormatter() {
        XCTAssertEqual(LongitudinalBaseline.isoString(year: -5, month: 3, day: 4), String(format: "%04d-%02d-%02d", -5, 3, 4))
        XCTAssertEqual(LongitudinalBaseline.isoString(year: 12_345, month: 3, day: 4), "12345-03-04")
        XCTAssertEqual(LongitudinalBaseline.isoString(year: 2026, month: 13, day: 4), String(format: "%04d-%02d-%02d", 2026, 13, 4))
    }

    func testEpochDayRoundTripAndKnownDays() {
        XCTAssertEqual(LongitudinalBaseline.isoFromEpochDay(0), "1970-01-01")
        XCTAssertEqual(LongitudinalBaseline.isoFromEpochDay(20_000), "2024-10-04")
        for z in stride(from: -50_000, through: 60_000, by: 13) {
            let iso = LongitudinalBaseline.isoFromEpochDay(z)
            XCTAssertEqual(LongitudinalBaseline.isoEpochDay(iso), z, iso)
        }
    }
}
