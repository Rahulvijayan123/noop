#if !os(watchOS)
import XCTest
@testable import StrandDesign

/// `TrendChart` lifts its line across missing readings. The run ids decide where, so they are pinned here
/// rather than in a screenshot.
final class TrendChartGapTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func dates(_ offsets: [Double]) -> [Date] { offsets.map { start.addingTimeInterval($0 * day) } }

    func testANightlySeriesBreaksAcrossAMissingNight() {
        let d = dates([0, 1, 2, 4, 5])
        let runs = TrendChart.gapSegments(dates: d, segments: Array(repeating: "default", count: d.count))
        XCTAssertEqual(runs, ["default#0", "default#0", "default#0", "default#1", "default#1"])
    }

    func testAWeeklySeriesBreaksOnlyAcrossAMissingWeek() {
        let d = dates([0, 7, 14, 21, 35, 42])
        let runs = TrendChart.gapSegments(dates: d, segments: Array(repeating: "s", count: d.count))
        XCTAssertEqual(Set(runs.prefix(4)).count, 1, "steady weekly readings stay one line")
        XCTAssertNotEqual(runs[3], runs[4], "a skipped week is a gap")
        XCTAssertEqual(runs[4], runs[5])
    }

    func testCallerSegmentsStaySeparateWithinARun() {
        let d = dates([0, 1, 2, 3])
        let runs = TrendChart.gapSegments(dates: d, segments: ["a", "a", "b", "b"])
        XCTAssertEqual(runs, ["a#0", "a#0", "b#0", "b#0"])
    }

    func testShortSeriesPassThrough() {
        XCTAssertEqual(TrendChart.gapSegments(dates: [], segments: []), [])
        XCTAssertEqual(TrendChart.gapSegments(dates: dates([0]), segments: ["x"]), ["x"])
    }
}
#endif
