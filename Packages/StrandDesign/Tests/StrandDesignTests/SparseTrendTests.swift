#if !os(watchOS)
import XCTest
@testable import StrandDesign

/// The trend line behind sparse readings (weight, body fat) is display-only smoothing over a centred
/// window. The median is the default because one odd weigh-in should barely move it.
final class SparseTrendTests: XCTestCase {

    private let cal: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return calendar
    }()

    private func readings(_ values: [(Int, Double)]) -> [DailyPoint] {
        let start = ChartDay.date(forKey: "2026-10-01", calendar: cal)!
        return values.map { offset, value in
            DailyPoint(day: cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: start)!), value: value)
        }
    }

    private var week: [DailyPoint] {
        readings([(0, 70), (1, 70.2), (2, 85), (3, 70.4), (4, 70.1), (5, 70.3), (6, 70.2)])
    }

    func testTheRollingMedianShrugsOffAnOutlier() {
        let trend = SparsePointsChart.trendLine(week, .rollingMedian(days: 4), calendar: cal)
        XCTAssertEqual(trend.count, week.count)
        XCTAssertEqual(trend[2].value, 70.2, accuracy: 1e-9, "the 85 kg reading is not the trend")
    }

    func testTheRollingMeanAveragesTheSameWindow() {
        let trend = SparsePointsChart.trendLine(week, .rollingMean(days: 4), calendar: cal)
        XCTAssertEqual(trend[2].value, (70 + 70.2 + 85 + 70.4 + 70.1) / 5, accuracy: 1e-9)
        XCTAssertEqual(trend[0].value, (70 + 70.2 + 85) / 3, accuracy: 1e-9, "the window is cut at the first reading")
    }

    func testTheWindowIsHalfTheSpanEitherSide() {
        let apart = readings([(0, 60), (10, 80)])
        let trend = SparsePointsChart.trendLine(apart, .rollingMean(days: 14), calendar: cal)
        XCTAssertEqual(trend.map(\.value), [60, 80], "readings ten days apart are outside each other's 7-day reach")
        let near = SparsePointsChart.trendLine(readings([(0, 60), (7, 80)]), .rollingMean(days: 14), calendar: cal)
        XCTAssertEqual(near.map(\.value), [70, 70])
    }

    func testTheTrendIsDatedAtEachReadingInOrder() {
        let shuffled = Array(week.reversed())
        let trend = SparsePointsChart.trendLine(shuffled, .rollingMedian(days: 4), calendar: cal)
        XCTAssertEqual(trend.map(\.day), week.map(\.day))
    }

    func testNoTrendAndDegenerateInputs() {
        XCTAssertTrue(SparsePointsChart.trendLine(week, .none, calendar: cal).isEmpty)
        XCTAssertTrue(SparsePointsChart.trendLine([], .rollingMedian(days: 14), calendar: cal).isEmpty)
        XCTAssertEqual(SparsePointsChart.trendLine(readings([(0, 64)]), .rollingMedian(days: 14), calendar: cal).map(\.value), [64])
        XCTAssertEqual(SparsePointsChart.trendLine(readings([(0, 64), (1, .nan)]), .rollingMean(days: 14), calendar: cal).count, 1)
    }

    func testTheMedianOfAnEvenWindowIsTheMiddlePair() {
        XCTAssertEqual(SparsePointsChart.median([1, 9, 3, 7]), 5)
        XCTAssertEqual(SparsePointsChart.median([4]), 4)
        XCTAssertTrue(SparsePointsChart.median([]).isNaN)
    }
}
#endif
