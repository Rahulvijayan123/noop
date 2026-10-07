import XCTest
@testable import StrandDesign

/// The one range set, and the control that only offers what the history can fill.
final class ChartRangeTests: XCTestCase {

    func testTheRangesAndTheirDays() {
        XCTAssertEqual(ChartRange.allCases.map(\.rawValue), ["W", "M", "3M", "6M", "Y", "All"])
        XCTAssertEqual(ChartRange.allCases.map(\.days), [7, 30, 90, 180, 365, nil])
        XCTAssertTrue(ChartRange.allCases.allSatisfy { !$0.label.isEmpty && !$0.accessibilityName.isEmpty })
        XCTAssertEqual(Set(ChartRange.allCases.map(\.accessibilityName)).count, ChartRange.allCases.count)
    }

    func testEachRangeAsksForTheAxisTheDocNames() {
        XCTAssertEqual(ChartRange.allCases.map(\.axisStyle), [.weekday, .dayOfMonth, .month, .month, .month, .monthYear])
    }

    /// Daily totals bin exactly like the steps detail (`MetricDetailSteps.resolution`): W and M daily,
    /// 3M weekly, 6M and longer monthly. Steps and every other total page must agree.
    func testTotalsBinMatchesTheStepsDetailRule() {
        XCTAssertEqual(ChartRange.week.totalsBin, .day)
        XCTAssertEqual(ChartRange.month.totalsBin, .day)
        XCTAssertEqual(ChartRange.quarter.totalsBin, .weekOfYear)
        XCTAssertEqual(ChartRange.half.totalsBin, .month)
        XCTAssertEqual(ChartRange.year.totalsBin, .month)
        XCTAssertEqual(ChartRange.all.totalsBin, .month)
    }

    // MARK: Availability

    /// A locked range is not shown at all (no disabled "Y" between "6M" and "All"); All always is.
    func testOnlyAvailableRangesAreShownPlusAll() {
        let upToQuarter = RangeControl.visibleOptions(ChartRange.allCases) { ($0.days ?? 0) <= 90 }
        XCTAssertEqual(upToQuarter, [.week, .month, .quarter, .all])
        XCTAssertEqual(RangeControl.visibleOptions(ChartRange.allCases) { _ in false }, [.all])
    }

    func testOptionsComeOutInCanonicalOrderWithoutDuplicates() {
        XCTAssertEqual(RangeControl.visibleOptions([.all, .year, .week, .week]) { _ in true }, [.week, .year, .all])
        XCTAssertEqual(RangeControl.visibleOptions([.week, .month]) { _ in true }, [.week, .month],
                       "All is only added when the screen offers it")
    }

    func testTheControlHidesWhenOneOptionRemains() {
        XCTAssertTrue(RangeControl.isHidden(visible: [.all]))
        XCTAssertTrue(RangeControl.isHidden(visible: []))
        XCTAssertFalse(RangeControl.isHidden(visible: [.week, .all]))
    }

    /// The stored selection is coerced for display only, by the same rule as `ExploreRangeGating`: the
    /// largest shown finite range no longer than it, never a jump to All.
    func testALockedSelectionShowsAsTheLargestRangeThatFits() {
        let visible: [ChartRange] = [.week, .month, .quarter, .all]
        XCTAssertEqual(RangeControl.displayedSelection(.year, visible: visible), .quarter)
        XCTAssertEqual(RangeControl.displayedSelection(.half, visible: visible), .quarter)
        XCTAssertEqual(RangeControl.displayedSelection(.month, visible: visible), .month)
        XCTAssertEqual(RangeControl.displayedSelection(.all, visible: visible), .all)
        XCTAssertEqual(RangeControl.displayedSelection(.week, visible: [.month, .all]), .month,
                       "nothing shorter is shown, so the shortest shown range")
        XCTAssertEqual(RangeControl.displayedSelection(.half, visible: [.all]), .all)
        XCTAssertNil(RangeControl.displayedSelection(.half, visible: []))
    }
}
