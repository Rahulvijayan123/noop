#if !os(watchOS)
import XCTest
@testable import StrandDesign

/// The pure geometry inside the stacked, floating and dot charts: stack order and shares, the evening-to-
/// morning clock axis, and the level a mood value lands on.
final class ChartGeometryTests: XCTestCase {

    // MARK: Stacks

    private let stages = ["light": 200.0, "deep": 60, "rem": 90]
    private let order = ["deep", "rem", "light"]

    func testAStackFollowsTheCategoryOrderFromTheBottom() {
        let segments = StackedBarChart.segments(stages, order: order)
        XCTAssertEqual(segments.map(\.category), ["deep", "rem", "light"])
        XCTAssertEqual(segments.map(\.start), [0, 60, 150])
        XCTAssertEqual(segments.last?.end, 350)
    }

    /// The highlighted stage sits on the axis, so its own height reads straight off it.
    func testTheHighlightedCategoryMovesToTheBottom() {
        let segments = StackedBarChart.segments(stages, order: order, highlighted: "light")
        XCTAssertEqual(segments.map(\.category), ["light", "deep", "rem"])
        XCTAssertEqual(segments.first.map { $0.end - $0.start }, 200)
    }

    func testANormalisedStackIsShareOfTheDay() {
        let segments = StackedBarChart.segments(stages, order: order, normalised: true)
        XCTAssertEqual(segments.last?.end ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual((segments.first?.end ?? 0), 60 / 350 * 100, accuracy: 1e-9)
    }

    func testEmptyAndUnknownCategories() {
        let segments = StackedBarChart.segments(["deep": 60, "awake": 20, "rem": 0, "light": -5, "nap": .nan], order: order)
        XCTAssertEqual(segments.map(\.category), ["deep", "awake"], "zero, negative and non-finite are left out; unknown go last")
        XCTAssertTrue(StackedBarChart.segments([:], order: order).isEmpty)
        XCTAssertTrue(StackedBarChart.segments(["deep": 0], order: order, normalised: true).isEmpty)
    }

    // MARK: Clock axis

    private let la: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func time(_ key: String, _ hour: Int, _ minute: Int = 0) -> Date {
        la.date(bySettingHour: hour, minute: minute, second: 0, of: ChartDay.date(forKey: key, calendar: la)!)!
    }

    func testANightIsOneRunFromEveningToMorning() {
        let wakeDay = ChartDay.date(forKey: "2026-10-07", calendar: la)!
        XCTAssertEqual(RangeBarChart.clockOffset(time("2026-10-06", 23), wakeDay: wakeDay, calendar: la), 5)
        XCTAssertEqual(RangeBarChart.clockOffset(time("2026-10-07", 0, 30), wakeDay: wakeDay, calendar: la), 6.5)
        XCTAssertEqual(RangeBarChart.clockOffset(time("2026-10-07", 7), wakeDay: wakeDay, calendar: la), 13)
        XCTAssertEqual(RangeBarChart.clockOffset(time("2026-10-06", 19), wakeDay: wakeDay, anchorHour: 18, calendar: la), 1)
    }

    /// On the night the clocks go forward 23:00 to 07:00 is seven hours, but the bars still start on the
    /// 11 PM line and end on the 7 AM line like every other night.
    func testAClockChangeDoesNotMoveABedtimeOffItsHour() {
        let wakeDay = ChartDay.date(forKey: "2026-03-08", calendar: la)!
        let bed = time("2026-03-07", 23)
        let wake = time("2026-03-08", 7)
        XCTAssertEqual(wake.timeIntervalSince(bed), 7 * 3600)
        XCTAssertEqual(RangeBarChart.clockOffset(bed, wakeDay: wakeDay, calendar: la), 5)
        XCTAssertEqual(RangeBarChart.clockOffset(wake, wakeDay: wakeDay, calendar: la), 13)
    }

    func testTypicalTimesOfDayWrapAroundTheAnchor() {
        XCTAssertEqual(RangeBarChart.timeOfDayOffset(time("2026-10-07", 22, 30), calendar: la), 4.5)
        XCTAssertEqual(RangeBarChart.timeOfDayOffset(time("2026-10-07", 6, 30), calendar: la), 12.5)
        XCTAssertEqual(RangeBarChart.timeOfDayOffset(time("2026-10-07", 18), calendar: la), 0)
    }

    /// Evening at the top: the axis is negated, so the earliest time is the highest value.
    func testTheClockAxisRunsEveningToMorningOnWholeHours() {
        let axis = RangeBarChart.clockAxis(earliest: 5, latest: 13, anchorHour: 18, calendar: la)
        XCTAssertEqual(axis.domain, -14 ... -4)
        XCTAssertEqual(axis.ticks, [-4, -6, -8, -10, -12, -14])
        XCTAssertEqual(axis.labels.map { $0.replacingOccurrences(of: "\u{202F}", with: " ") },
                       ["10 PM", "12 AM", "2 AM", "4 AM", "6 AM", "8 AM"])
    }

    // MARK: Levels

    func testAValueLandsOnTheNearestLevelInsideTheScale() {
        XCTAssertEqual(DotStripChart.level(for: 3.4, in: 1...5), 3)
        XCTAssertEqual(DotStripChart.level(for: 3.5, in: 1...5), 4)
        XCTAssertEqual(DotStripChart.level(for: 7, in: 1...5), 5)
        XCTAssertEqual(DotStripChart.level(for: -1, in: 1...5), 1)
        XCTAssertEqual(DotStripChart.level(for: .nan, in: 1...5), 1)
    }
}
#endif
