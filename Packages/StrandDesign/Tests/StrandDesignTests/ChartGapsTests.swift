#if !os(watchOS)
import XCTest
@testable import StrandDesign

/// Kit lines lift wherever the series skips more than its cadence, and wherever the method changes. The run
/// ids decide where, so they are pinned here rather than in a screenshot.
final class ChartGapsTests: XCTestCase {

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func days(_ offsets: [Int], from key: String = "2026-10-01", zone: String = "UTC") -> [Date] {
        let cal = calendar(zone)
        let start = ChartDay.date(forKey: key, calendar: cal)!
        return offsets.map { cal.startOfDay(for: cal.date(byAdding: .day, value: $0, to: start)!) }
    }

    private func breaks(_ runs: [String]) -> [Int] {
        runs.indices.filter { $0 > 0 && runs[$0] != runs[$0 - 1] }
    }

    func testANightlySeriesBreaksAcrossAMissingNight() {
        let d = days([0, 1, 2, 4, 5])
        let runs = ChartGaps.runs(d, series: Array(repeating: "default", count: 5), cadence: .daily, calendar: calendar("UTC"))
        XCTAssertEqual(runs, ["default#0", "default#0", "default#0", "default#1", "default#1"])
    }

    /// Consecutive local days are 23 and 25 hours apart around a clock change; they are still consecutive.
    func testClockChangesDoNotBreakANightlyLine() {
        let la = calendar("America/Los_Angeles")
        for key in ["2026-03-05", "2026-10-29"] {
            let d = days(Array(0..<7), from: key, zone: "America/Los_Angeles")
            let runs = ChartGaps.runs(d, series: Array(repeating: "s", count: d.count), cadence: .daily, calendar: la)
            XCTAssertEqual(Set(runs).count, 1, "a clock change broke the line in the week of \(key)")
        }
    }

    func testAWeeklySeriesBreaksOnlyAfterTenDays() {
        let cal = calendar("UTC")
        let series = Array(repeating: "s", count: 6)
        XCTAssertEqual(breaks(ChartGaps.runs(days([0, 7, 14, 21, 35, 42]), series: series, cadence: .weekly, calendar: cal)), [4])
        XCTAssertEqual(breaks(ChartGaps.runs(days([0, 7, 14, 24, 31, 41]), series: series, cadence: .weekly, calendar: cal)), [],
                       "ten days apart still joins")
    }

    func testASparseSeriesBreaksOnlyBeyondItsLongestGap() {
        let runs = ChartGaps.runs(days([0, 20, 41, 63]), series: Array(repeating: "w", count: 4),
                                  cadence: .sparse(maxGapDays: 21), calendar: calendar("UTC"))
        XCTAssertEqual(breaks(runs), [3])
    }

    /// The intraday rule is `hrGapSegments`, not a second implementation of it.
    func testBucketsFollowHrGapSegments() {
        let ts = [0, 300, 600, 1200, 1500, 1800, 3000]
        let dates = ts.map { Date(timeIntervalSince1970: 1_790_000_000 + Double($0)) }
        let runs = ChartGaps.runs(dates, series: Array(repeating: "hr", count: ts.count), cadence: .buckets(seconds: 300))
        let expected = hrGapSegments(bucketTs: ts.map { 1_790_000_000 + $0 }, bucketSeconds: 300)
        XCTAssertEqual(breaks(runs), breaks(expected))
        XCTAssertEqual(breaks(runs), [3, 6])
    }

    /// The adaptive rule is `TrendChart.gapSegments`.
    func testAdaptiveFollowsTrendChartGapSegments() {
        for offsets in [[0, 1, 2, 4, 5], [0, 7, 14, 21, 35, 42], [0, 1, 2, 3]] {
            let d = days(offsets)
            let runs = ChartGaps.runs(d, series: Array(repeating: "x", count: d.count), cadence: .adaptive)
            let expected = TrendChart.gapSegments(dates: d, segments: Array(repeating: "x", count: d.count))
            XCTAssertEqual(breaks(runs), breaks(expected), "\(offsets)")
        }
    }

    func testAMethodChangeBreaksTheLineWithoutAGap() {
        let runs = ChartGaps.runs(days([0, 1, 2, 3]), series: ["nes", "nes", "uth", "uth"], cadence: .daily,
                                  calendar: calendar("UTC"))
        XCTAssertEqual(runs, ["nes#0", "nes#0", "uth#1", "uth#1"])
    }

    /// A method that resumes after another one gets a new id, so Charts cannot join it across the other.
    func testAResumedSeriesIsNotJoinedAcrossTheInterruption() {
        let runs = ChartGaps.runs(days([0, 1, 2]), series: ["a", "b", "a"], cadence: .daily, calendar: calendar("UTC"))
        XCTAssertEqual(Set(runs).count, 3)
    }

    func testDegenerateInputs() {
        XCTAssertEqual(ChartGaps.runs([], series: [], cadence: .daily), [])
        XCTAssertEqual(ChartGaps.runs(days([0]), series: ["s"], cadence: .daily), ["s#0"])
        XCTAssertEqual(ChartGaps.runs(days([0, 1]), series: ["s"], cadence: .daily), ["s"], "mismatched input is returned as given")
    }
}
#endif
