import XCTest
import WhoopStore
@testable import StrandAnalytics

/// BaselineStandard fix G: ReadinessEngine (calendar windows, robust floored respiration, confounders) and
/// HRVReadiness (standard ln SD floor).
final class ReadinessBaselineStandardTests: XCTestCase {

    typealias BS = BaselineStandard

    private func key(_ i: Int) -> String { BS.dayKey(BS.epochDay("2026-04-01")! + i) }

    private func day(_ i: Int, hrv: Double? = 60, rhr: Int? = 52, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: key(i), totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil,
                    respRateBpm: resp)
    }

    private func respSignal(_ r: ReadinessEngine.Readiness) -> ReadinessEngine.Signal? {
        r.signals.first { $0.key == "respRate" }
    }

    func testRespirationIsRobustAndFloored() {
        // A very steady sleeper: 15.0/15.1 alternating (sample SD ≈ 0.05). Tonight 15.4: the shipped mean ± SD
        // read z ≈ 7 → "up vs baseline – sometimes an early sign of getting sick". With the robust median/MAD
        // and the 0.3 /min floor it is z ≈ 1.2: nothing.
        let days = (0..<30).map { day($0, resp: $0 % 2 == 0 ? 15.0 : 15.1) } + [day(30, resp: 15.4)]
        XCTAssertNil(respSignal(ReadinessEngine.evaluate(days: days, today: key(30))))
        // A real rise still flags.
        let sick = (0..<30).map { day($0, resp: $0 % 2 == 0 ? 15.0 : 15.1) } + [day(30, resp: 16.0)]
        XCTAssertEqual(respSignal(ReadinessEngine.evaluate(days: sick, today: key(30)))?.flag, .bad)
    }

    func testBaselineWindowIsThirtyCalendarDaysNotThirtyRows() {
        // 20 nights at 40 ms long ago, a 30-day gap, then 8 nights at 70 ms: the shipped "last 30 rows" reached
        // back across the gap and mixed both eras; the calendar window only holds the 8 recent nights.
        let old = (0..<20).map { day($0, hrv: 40) }
        let recent = (50..<58).map { day($0, hrv: 70) }
        let r = ReadinessEngine.evaluate(days: old + recent + [day(58, hrv: 70)], today: key(58))
        guard case let .metric(_, baseline, _, _)? = r.signals.first(where: { $0.key == "hrv" })?.evidenceData else {
            return XCTFail("8 calendar-window nights ≥ 7 must still give an HRV signal")
        }
        XCTAssertEqual(baseline, 70, accuracy: 0.5, "only the 30 calendar days before today")
    }

    func testConfoundedNightsStayOutOfTheBaseline() {
        // Eight nights, two of them logged alcohol nights at 30 ms: with them out, 6 nights < the 7-night minimum.
        var days = (0..<8).map { day($0, hrv: 60) }
        days[2] = day(2, hrv: 30); days[5] = day(5, hrv: 30)
        days.append(day(8, hrv: 60))
        let logs = [key(2): LBDayLog(alcohol: true), key(5): LBDayLog(alcohol: true)]
        let without = ReadinessEngine.evaluate(days: days, today: key(8))
        let with = ReadinessEngine.evaluate(days: days, today: key(8), context: BS.Context(dayLogs: logs))
        XCTAssertNotNil(without.signals.first { $0.key == "hrv" })
        XCTAssertNil(with.signals.first { $0.key == "hrv" }, "6 clean nights are below the 7-night minimum")
    }

    func testHRVReadinessFloorIsTheStandardLnFloor() {
        XCTAssertEqual(HRVReadiness.longSDFloor, 0.05)
        // An ultra-stable history (60 ± 0.1 ms) whose last week dips 1 %: the 1e-9 floor read "suppressed".
        let flat = (0..<53).map { i -> Double? in 60 + (i % 2 == 0 ? 0.1 : -0.1) }
        let week = (0..<7).map { i -> Double? in 59.4 + (i % 2 == 0 ? 0.1 : -0.1) }
        XCTAssertEqual(HRVReadiness.evaluate(avgHrv: flat + week)?.tier, .normal)
    }
}
