import XCTest
@testable import Strand

final class HRVDualSeriesTests: XCTestCase {
    func testMergeKeepsBothStatisticsSeparateAndSortsByDay() {
        let merged = HRVDualSeries.merge(
            rmssd: [(day: "2026-10-02", value: 66.4), (day: "2026-09-30", value: 83.8)],
            sdnn: [(day: "2026-09-30", value: 98.0), (day: "2026-10-02", value: 79.7)])
        XCTAssertEqual(merged.map(\.day), ["2026-09-30", "2026-10-02"])
        XCTAssertEqual(merged[0].rmssd, 83.8)
        XCTAssertEqual(merged[0].sdnn, 98.0)
        XCTAssertEqual(merged[1].rmssd, 66.4)
        XCTAssertEqual(merged[1].sdnn, 79.7)
    }

    func testNightWithOnlyOneNumberStillPlots() {
        let merged = HRVDualSeries.merge(
            rmssd: [(day: "2026-09-29", value: 70)],
            sdnn: [(day: "2026-09-30", value: 90)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].rmssd, 70)
        XCTAssertNil(merged[0].sdnn)
        XCTAssertNil(merged[1].rmssd)
        XCTAssertEqual(merged[1].sdnn, 90)
    }

    func testNonPositiveAndNonFiniteReadingsAreDropped() {
        let merged = HRVDualSeries.merge(
            rmssd: [(day: "2026-10-01", value: 0), (day: "2026-10-02", value: .nan)],
            sdnn: [(day: "2026-10-01", value: -3)])
        XCTAssertTrue(merged.isEmpty)
    }

    func testWindowDropsSdnnBeforeFirstVisibleDay() {
        let sdnn = [(day: "2026-09-01", value: 80.0), (day: "2026-10-01", value: 92.8)]
        XCTAssertEqual(HRVDualSeries.window(sdnn, firstDay: "2026-09-20").map(\.day), ["2026-10-01"])
        XCTAssertEqual(HRVDualSeries.window(sdnn, firstDay: nil).count, 2)
    }

    func testSegmentsBreakAcrossLongGapsOnly() {
        let day = 86_400.0
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let dates = [0, 1, 2, 7, 8].map { t0.addingTimeInterval(Double($0) * day) }
        XCTAssertEqual(HRVDualSeries.segmentIDs(dates: dates), [0, 0, 0, 1, 1])
    }

    func testRatioUsesOnlyNightsWithBothNumbers() throws {
        let merged = HRVDualSeries.merge(
            rmssd: [(day: "2026-09-29", value: 100), (day: "2026-09-30", value: 80), (day: "2026-10-01", value: 60)],
            sdnn: [(day: "2026-09-30", value: 100), (day: "2026-10-01", value: 72)])
        let ratio = try XCTUnwrap(HRVDualSeries.ratio(merged))
        XCTAssertEqual(ratio, (100.0 + 72.0) / (80.0 + 60.0), accuracy: 1e-9)
        XCTAssertNil(HRVDualSeries.ratio(HRVDualSeries.merge(rmssd: [(day: "2026-10-01", value: 60)], sdnn: [])))
    }
}
