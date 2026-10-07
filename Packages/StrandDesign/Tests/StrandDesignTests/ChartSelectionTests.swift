#if !os(watchOS)
import XCTest
@testable import StrandDesign

/// The selection rules every kit chart shares: snap to the nearest x, step through xs for VoiceOver, and
/// what a tap does to a pinned selection.
final class ChartSelectionTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private var xs: [Date] { [0, 10, 20].map { base.addingTimeInterval($0) } }
    private func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    func testTheNearestXWins() {
        XCTAssertEqual(ChartSelection.nearest(to: at(4), in: xs), at(0))
        XCTAssertEqual(ChartSelection.nearest(to: at(6), in: xs), at(10))
        XCTAssertEqual(ChartSelection.nearest(to: at(10), in: xs), at(10))
        XCTAssertEqual(ChartSelection.nearest(to: at(-100), in: xs), at(0))
        XCTAssertEqual(ChartSelection.nearest(to: at(100), in: xs), at(20))
        XCTAssertNil(ChartSelection.nearest(to: at(0), in: []))
    }

    func testATieGoesToTheEarlierX() {
        XCTAssertEqual(ChartSelection.nearest(to: at(5), in: xs), at(0))
        XCTAssertEqual(ChartSelection.nearestIndex(to: at(15), in: xs), 1)
    }

    /// A day of per-second samples still answers correctly (the search is binary, not a scan).
    func testTheSearchHoldsOverALongSeries() {
        let dense = (0..<86_400).map { base.addingTimeInterval(Double($0)) }
        XCTAssertEqual(ChartSelection.nearestIndex(to: at(43_200.4), in: dense), 43_200)
        XCTAssertEqual(ChartSelection.nearestIndex(to: at(43_200.6), in: dense), 43_201)
    }

    func testVoiceOverStepsThroughTheXs() {
        XCTAssertEqual(ChartSelection.step(from: nil, in: xs, forward: true), at(0))
        XCTAssertEqual(ChartSelection.step(from: nil, in: xs, forward: false), at(20))
        XCTAssertEqual(ChartSelection.step(from: at(0), in: xs, forward: true), at(10))
        XCTAssertEqual(ChartSelection.step(from: at(10), in: xs, forward: false), at(0))
        XCTAssertEqual(ChartSelection.step(from: at(20), in: xs, forward: true), at(20), "stays at the end")
        XCTAssertEqual(ChartSelection.step(from: at(0), in: xs, forward: false), at(0), "stays at the start")
        XCTAssertEqual(ChartSelection.step(from: at(13), in: xs, forward: true), at(20), "steps from the nearest x")
        XCTAssertNil(ChartSelection.step(from: nil, in: [], forward: true))
    }

    /// The page's readout finds the selected day's point, or the selected week's bar.
    func testTheReadoutFindsThePointInTheSelectedDayOrBin() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.firstWeekday = 2
        let monday = ChartDay.date(forKey: "2026-10-05", calendar: cal)!
        let points = [DailyPoint(day: monday, value: 1), DailyPoint(day: monday.addingTimeInterval(86_400), value: 2)]
        let tuesdayEvening = monday.addingTimeInterval(86_400 + 20 * 3600)
        XCTAssertEqual(ChartSelection.point(for: tuesdayEvening, in: points, calendar: cal)?.value, 2)
        XCTAssertNil(ChartSelection.point(for: monday.addingTimeInterval(3 * 86_400), in: points, calendar: cal))
        XCTAssertNil(ChartSelection.point(for: nil, in: points, calendar: cal))
        let weeks = DailyBarChart.bin(points, by: .weekOfYear, aggregation: .mean, calendar: cal)
        XCTAssertEqual(ChartSelection.point(for: tuesdayEvening, in: weeks, unit: .weekOfYear, calendar: cal)?.value, 1.5)
    }

    func testTappingThePinnedXClearsItAndAnyOtherXMovesThePin() {
        XCTAssertNil(ChartSelection.afterTap(current: at(10), tapped: at(10)))
        XCTAssertEqual(ChartSelection.afterTap(current: at(10), tapped: at(20)), at(20))
        XCTAssertEqual(ChartSelection.afterTap(current: nil, tapped: at(0)), at(0))
        XCTAssertEqual(ChartSelection.afterTap(current: at(10), tapped: nil), at(10), "a tap off the data changes nothing")
    }
}
#endif
