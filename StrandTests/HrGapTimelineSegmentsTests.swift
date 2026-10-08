import XCTest
@testable import Strand

/// Pins where the Deep Timeline's line lifts (`FullDayChartView.gapSegments`). A bucketed series breaks
/// where a bucket is skipped (the `hrGapSegments` rule); a raw series breaks where a step is more than three
/// times its typical step, never under five seconds, so a dropped second of 1 Hz heart rate does not split
/// the line but an hour off the wrist does.
final class HrGapTimelineSegmentsTests: XCTestCase {

    private func dates(_ seconds: [Int]) -> [Date] {
        seconds.map { Date(timeIntervalSince1970: TimeInterval(1_760_000_000 + $0)) }
    }

    func testBucketedSeriesBreaksWhereABucketIsSkipped() {
        let ids = FullDayChartView.gapSegments(dates: dates([0, 300, 600, 1_500, 1_800]), bucketSeconds: 300, isRaw: false)
        XCTAssertEqual(ids, ["0", "0", "0", "1", "1"])
    }

    func testRawHeartRateToleratesADroppedSecond() {
        let ids = FullDayChartView.gapSegments(dates: dates([0, 1, 2, 4, 5, 6]), bucketSeconds: 1, isRaw: true)
        XCTAssertEqual(Set(ids).count, 1, "a 2 s hiccup in 1 Hz data is not a gap")
    }

    func testRawHeartRateBreaksAcrossAMinuteWithNothing() {
        let ids = FullDayChartView.gapSegments(dates: dates([0, 1, 2, 3, 63, 64]), bucketSeconds: 1, isRaw: true)
        XCTAssertEqual(ids, ["0", "0", "0", "0", "1", "1"])
    }

    func testRawSparseStreamUsesItsOwnCadence() {
        // A once-a-minute stream: three minutes between readings is still the same run, four is a gap.
        XCTAssertEqual(Set(FullDayChartView.gapSegments(dates: dates([0, 60, 120, 300]), bucketSeconds: 1, isRaw: true)).count, 1)
        XCTAssertEqual(FullDayChartView.gapSegments(dates: dates([0, 60, 120, 400]), bucketSeconds: 1, isRaw: true),
                       ["0", "0", "0", "1"])
    }

    func testShortSeries() {
        XCTAssertEqual(FullDayChartView.gapSegments(dates: [], bucketSeconds: 300, isRaw: false), [])
        XCTAssertEqual(FullDayChartView.gapSegments(dates: dates([0]), bucketSeconds: 300, isRaw: false), ["0"])
    }
}
