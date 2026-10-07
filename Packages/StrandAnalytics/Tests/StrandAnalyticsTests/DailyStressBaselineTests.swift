import XCTest
import WhoopStore
@testable import StrandAnalytics

/// BaselineStandard fix E: the Stress screen's daily baseline (`DailyStressBaseline`).
final class DailyStressBaselineTests: XCTestCase {

    typealias BS = BaselineStandard

    private func key(_ i: Int) -> String { BS.dayKey(BS.epochDay("2026-06-01")! + i) }

    private func day(_ i: Int, rhr: Int?, hrv: Double?) -> DailyMetric {
        DailyMetric(day: key(i), totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testFewerThanFourPriorDaysGiveNoRead() {
        // The shipped model scored from ONE prior row.
        let days = (0..<4).map { day($0, rhr: 55, hrv: 60) }
        let trend = DailyStressBaseline.trend(days: days)
        XCTAssertNil(trend[key(1)])
        XCTAssertNil(trend[key(3)], "3 prior days is still learning")
        let five = days + [day(4, rhr: 58, hrv: 50)]
        XCTAssertNotNil(DailyStressBaseline.trend(days: five)[key(4)])
    }

    func testAFlatHistoryIsFlooredNotNearZero() {
        // Identical nights: the shipped population SD was 0 (floor 0.0001), so +2 bpm read as z ≈ 20000.
        let days = (0..<10).map { day($0, rhr: 55, hrv: 60) } + [day(10, rhr: 57, hrv: 60)]
        let s = DailyStressBaseline.trend(days: days)[key(10)]!
        XCTAssertEqual(s.raw, 2.0, accuracy: 1e-9, "(57 − 55) / the 1 bpm floor")
        XCTAssertEqual(s.rhrDelta!, 2, accuracy: 1e-9)
        XCTAssertEqual(s.hrvDeltaMs!, 0, accuracy: 1e-9)
    }

    func testHRVIsComparedOnLn() {
        let days = (0..<10).map { day($0, rhr: nil, hrv: 60) } + [day(10, rhr: nil, hrv: 48)]
        let s = DailyStressBaseline.trend(days: days)[key(10)]!
        XCTAssertEqual(s.raw, -(log(48) - log(60)) / 0.05, accuracy: 1e-9, "ln drop over the 0.05 ln floor")
        XCTAssertEqual(s.hrvDeltaMs!, -12, accuracy: 1e-9)
    }

    func testPastPointsNeverMoveWhenNewNightsArrive() {
        let base = (0..<40).map { day($0, rhr: 52 + ($0 % 4), hrv: 55 + Double(($0 * 3) % 11)) }
        let early = DailyStressBaseline.trend(days: Array(base.prefix(25)))
        let late = DailyStressBaseline.trend(days: base)
        for i in 0..<25 { XCTAssertEqual(early[key(i)], late[key(i)], "day \(i) was rescored by the future") }
    }

    func testTheWindowIsThirtyCalendarDaysAndConfoundersStayOut() {
        let days = (0..<50).map { day($0, rhr: 55, hrv: 60) }
        let ref = DailyStressBaseline.reference(days: days, asOf: key(45))
        XCTAssertEqual(ref.restingHR.n, 30)
        let logs = [key(40): LBDayLog(alcohol: true)]
        XCTAssertEqual(DailyStressBaseline.reference(days: days, asOf: key(45),
                                                     context: BS.Context(dayLogs: logs)).restingHR.n, 29)
    }
}
