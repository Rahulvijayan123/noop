#if !os(watchOS)
import XCTest
@testable import StrandDesign

/// Rules added after the kit gallery review: reference labels move to the leading edge when the newest data
/// would sit under them, stacked bars bin to mean nights, and a clock axis ends on labelled lines.
final class ChartLabelPlacementTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: d))! }

    private var window: ClosedRange<Date> { day(1)...day(31) }

    // MARK: Reference labels

    func testALabelStaysTrailingWhenTheNewestDataIsClearOfIt() {
        let marks = (1...30).map { NaraReferenceLabelPlacement.Extent(x: day($0), low: 40, high: 40) }
        let anchors = NaraReferenceLabelPlacement.anchors(for: [ChartReference(64, label: "Baseline 64")],
                                                          marks: marks, window: window, domain: 20...100)
        XCTAssertEqual(anchors, [.trailing])
    }

    func testALabelMovesLeadingWhenTheNewestPointWouldSitUnderIt() {
        var marks = (1...25).map { NaraReferenceLabelPlacement.Extent(x: day($0), low: 40, high: 40) }
        marks.append(.init(x: day(30), low: 66, high: 66))   // just above the rule, under the label
        let anchors = NaraReferenceLabelPlacement.anchors(for: [ChartReference(64, label: "Baseline 64")],
                                                          marks: marks, window: window, domain: 20...100)
        XCTAssertEqual(anchors, [.leading])
    }

    func testALabelStaysTrailingWhenBothEndsAreBusy() {
        let marks = [NaraReferenceLabelPlacement.Extent(x: day(1), low: 66, high: 66),
                     .init(x: day(30), low: 66, high: 66)]
        let anchors = NaraReferenceLabelPlacement.anchors(for: [ChartReference(64, label: "Baseline 64")],
                                                          marks: marks, window: window, domain: 20...100)
        XCTAssertEqual(anchors, [.trailing])
    }

    func testABarThroughTheGoalCountsAsUnderTheLabel() {
        let marks = [NaraReferenceLabelPlacement.Extent(x: day(30), low: 0, high: 12_000)]
        let anchors = NaraReferenceLabelPlacement.anchors(for: [ChartReference(10_000, label: "Goal 10,000")],
                                                          marks: marks, window: window, domain: 0...15_000)
        XCTAssertEqual(anchors, [.leading])
    }

    func testAnUnlabelledRuleNeedsNoPlacement() {
        let marks = [NaraReferenceLabelPlacement.Extent(x: day(30), low: 0.5, high: 0.5)]
        XCTAssertEqual(NaraReferenceLabelPlacement.anchors(for: [ChartReference(0.5)], marks: marks,
                                                           window: window, domain: -1...1), [.trailing])
    }

    // MARK: Stacked bins

    func testStackedDaysBinToTheMeanNightWithMissingCategoriesAsZero() {
        let days = [StackedBarChart.Day(day: day(7), values: ["deep": 60, "rem": 90]),
                    StackedBarChart.Day(day: day(8), values: ["deep": 80], isEstimate: true),
                    StackedBarChart.Day(day: day(14), values: ["deep": 70, "rem": 100], isEstimate: true)]
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        let bins = StackedBarChart.bin(days, by: .weekOfYear, calendar: weekCalendar)
        XCTAssertEqual(bins.count, 2)
        XCTAssertEqual(bins[0].day, day(7))                  // Monday 7 Sep
        XCTAssertEqual(bins[0].values["deep"], 70)
        XCTAssertEqual(bins[0].values["rem"], 45)
        XCTAssertTrue(bins[0].isEstimate)                    // one of two days is an estimate
        XCTAssertEqual(bins[1].values["rem"], 100)
        XCTAssertTrue(bins[1].isEstimate)
    }

    // MARK: Clock axis

    func testTheClockAxisEndsOnLabelledLines() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = la
        cal.locale = Locale(identifier: "en_US")
        // 22:18 to 07:42: the old axis ran 3...15 with ticks only on 4...14.
        let axis = RangeBarChart.clockAxis(earliest: 4.3, latest: 13.7, anchorHour: 18, calendar: cal)
        XCTAssertEqual(axis.ticks.first, axis.domain.upperBound)
        XCTAssertEqual(axis.ticks.last, axis.domain.lowerBound)
        XCTAssertLessThanOrEqual(axis.ticks.count - 1, 6)
        XCTAssertLessThanOrEqual(axis.domain.upperBound, -3)
        XCTAssertGreaterThanOrEqual(axis.domain.lowerBound, -16)
    }
}
#endif
