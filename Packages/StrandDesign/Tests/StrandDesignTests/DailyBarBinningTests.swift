#if !os(watchOS)
import XCTest
@testable import StrandDesign

/// Long ranges aggregate daily bars to weeks or months, and the aggregation is explicit: a weekly MEAN of
/// steps per observed day is not a weekly SUM of zone minutes. Pinned here because the two read the same on
/// screen and differ by a factor of seven.
final class DailyBarBinningTests: XCTestCase {

    private func calendar(firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// Monday 5 October 2026 to Monday 12 October, values 1...8, the 7th an estimate.
    private func week(_ cal: Calendar) -> [DailyPoint] {
        (0..<8).map { offset in
            let day = cal.startOfDay(for: cal.date(byAdding: .day, value: offset,
                                                   to: ChartDay.date(forKey: "2026-10-05", calendar: cal)!)!)
            return DailyPoint(day: day, value: Double(offset + 1), isEstimate: offset == 6)
        }
    }

    func testAWeeklyMeanAveragesTheDaysThatHaveAValue() {
        let cal = calendar()
        let bins = DailyBarChart.bin(week(cal), by: .weekOfYear, aggregation: .mean, calendar: cal)
        XCTAssertEqual(bins.map(\.value), [4, 8])
        XCTAssertEqual(bins.map { ChartDay.key(for: $0.day, calendar: cal) }, ["2026-10-05", "2026-10-12"])
    }

    func testAWeeklySumTotalsThem() {
        let cal = calendar()
        XCTAssertEqual(DailyBarChart.bin(week(cal), by: .weekOfYear, aggregation: .sum, calendar: cal).map(\.value), [28, 8])
    }

    /// The bin is the calendar's week, so a Sunday-first locale moves Sunday into the next week.
    func testTheWeekFollowsTheCalendarsFirstWeekday() {
        let sundays = calendar(firstWeekday: 1)
        let bins = DailyBarChart.bin(week(sundays), by: .weekOfYear, aggregation: .sum, calendar: sundays)
        XCTAssertEqual(bins.map(\.value), [21, 15])
    }

    func testAMonthlyBinStartsAtTheMonth() {
        let cal = calendar()
        let days = ["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"].enumerated().map { index, key in
            DailyPoint(day: ChartDay.date(forKey: key, calendar: cal)!, value: Double(index) * 10)
        }
        let bins = DailyBarChart.bin(days, by: .month, aggregation: .mean, calendar: cal)
        XCTAssertEqual(bins.map { ChartDay.key(for: $0.day, calendar: cal) }, ["2026-09-01", "2026-10-01"])
        XCTAssertEqual(bins.map(\.value), [5, 25])
    }

    /// A week or month is drawn as an estimate when at least half its days are; one estimated day does not
    /// turn a month of measurements into an estimate.
    func testABinIsAnEstimateWhenAtLeastHalfItsDaysAre() {
        let cal = calendar()
        XCTAssertEqual(DailyBarChart.bin(week(cal), by: .weekOfYear, aggregation: .mean, calendar: cal).map(\.isEstimate),
                       [false, false], "one estimated day in seven")
        let mostly = week(cal).enumerated().map { index, point in
            DailyPoint(day: point.day, value: point.value, isEstimate: index < 4)
        }
        XCTAssertEqual(DailyBarChart.bin(mostly, by: .weekOfYear, aggregation: .mean, calendar: cal).map(\.isEstimate),
                       [true, false])
        let day = ChartDay.date(forKey: "2026-10-07", calendar: cal)!
        let half = [DailyPoint(day: day, value: 1, isEstimate: true), DailyPoint(day: day, value: 2)]
        XCTAssertEqual(DailyBarChart.bin(half, by: .day, aggregation: .mean, calendar: cal).first?.isEstimate, true)
    }

    func testTwoReadingsOnOneDayBecomeOneBarAndNonFiniteValuesAreIgnored() {
        let cal = calendar()
        let day = ChartDay.date(forKey: "2026-10-07", calendar: cal)!
        let bins = DailyBarChart.bin([DailyPoint(day: day, value: 2), DailyPoint(day: day.addingTimeInterval(3600), value: 4),
                                      DailyPoint(day: day, value: .nan)], by: .day, aggregation: .mean, calendar: cal)
        XCTAssertEqual(bins.count, 1)
        XCTAssertEqual(bins.first?.value, 3)
        XCTAssertTrue(DailyBarChart.bin([], by: .month, aggregation: .sum, calendar: cal).isEmpty)
    }

    // MARK: Trailing mean

    func testTheTrailingMeanCoversTheLastNDays() {
        let cal = calendar()
        let start = ChartDay.date(forKey: "2026-10-01", calendar: cal)!
        let points = [3.0, 6, 9, 12].enumerated().map { index, value in
            DailyPoint(day: cal.date(byAdding: .day, value: index, to: start)!, value: value)
        }
        XCTAssertEqual(DailyBarChart.trailingMean(points, count: 3, calendar: cal).map(\.value), [3, 4.5, 6, 9])
    }

    /// Missing days are not counted as zero: the mean is over the days that have a value.
    func testTheTrailingMeanSkipsMissingDays() {
        let cal = calendar()
        let start = ChartDay.date(forKey: "2026-10-01", calendar: cal)!
        let points = [(0, 2.0), (1, 4.0), (5, 9.0)].map { offset, value in
            DailyPoint(day: cal.date(byAdding: .day, value: offset, to: start)!, value: value)
        }
        XCTAssertEqual(DailyBarChart.trailingMean(points, count: 3, calendar: cal).map(\.value), [2, 3, 9])
    }

    func testTheTrailingMeanCanRunOverWeeks() {
        let cal = calendar()
        let weeks = DailyBarChart.bin(week(cal), by: .weekOfYear, aggregation: .mean, calendar: cal)
        XCTAssertEqual(DailyBarChart.trailingMean(weeks, count: 2, unit: .weekOfYear, calendar: cal).map(\.value), [4, 6])
    }
}
#endif
