import XCTest
import WhoopStore
@testable import StrandAnalytics

/// BaselineStandard fixes H and I: the Today "HRV X% vs baseline" read and the Coach usuals (`PersonalUsual`).
final class PersonalUsualTests: XCTestCase {

    typealias BS = BaselineStandard

    private func key(_ i: Int) -> String { BS.dayKey(BS.epochDay("2026-08-01")! + i) }

    private func day(_ i: Int, hrv: Double?, rhr: Int? = 52, skin: Double? = nil) -> DailyMetric {
        DailyMetric(day: key(i), totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil,
                    skinTempDevC: skin)
    }

    func testTheUsualIsTheLnMedianOfThe28CalendarDaysBefore() {
        // 60 old nights at 40 ms, then 28 nights alternating 55/65 ms, then today. The shipped mean of EVERY
        // prior row read ~47 ms; the usual reads the geometric centre of the last 28 days only.
        let days = (0..<60).map { day($0, hrv: 40) } + (60..<88).map { day($0, hrv: $0 % 2 == 0 ? 55 : 65) }
            + [day(88, hrv: 66)]
        let ref = PersonalUsual.usual(days: days, metric: .hrvRmssd, asOf: key(88))
        XCTAssertEqual(ref.n, 28)
        XCTAssertEqual(ref.centerNative, (55.0 * 65.0).squareRoot(), accuracy: 1e-9, "median of ln, shown via exp")
        let pct = PersonalUsual.hrvDeltaPercent(todayMs: 66, day: key(88), days: days)
        XCTAssertEqual(pct, Int(((66 / (55.0 * 65.0).squareRoot()) - 1) * 100 + 0.5))
    }

    func testTheUsualIsCausalAndNeedsFourNights() {
        let days = (0..<3).map { day($0, hrv: 50) } + [day(3, hrv: 80), day(4, hrv: 80)]
        XCTAssertNil(PersonalUsual.hrvDeltaPercent(todayMs: 80, day: key(3), days: days), "3 prior nights")
        // Day 4's own value and later values never enter its usual.
        let ref = PersonalUsual.usual(days: days + [day(5, hrv: 200)], metric: .hrvRmssd, asOf: key(4))
        XCTAssertEqual(ref.n, 4)
        XCTAssertEqual(ref.centerNative, 50, accuracy: 1e-9, "median of 50, 50, 50, 80")
    }

    func testSDNNNightsAreExcludedAndNeverCompared() {
        var days = (0..<10).map { day($0, hrv: 55) }
        days[7] = day(7, hrv: 170)   // an Apple SDNN night on the same column
        days.append(day(10, hrv: 170))
        let ctx = BS.Context(sdnnDays: [key(7), key(10)])
        XCTAssertEqual(PersonalUsual.usual(days: days, metric: .hrvRmssd, asOf: key(10), context: ctx).n, 9)
        XCTAssertNil(PersonalUsual.hrvDeltaPercent(todayMs: 170, day: key(10), days: days, context: ctx))
    }

    func testTheMethodMismatchGuardIsKept() {
        let priors: [Double] = [55, 60, 56, 59]
        XCTAssertEqual(PersonalUsual.hrvDeltaPercent(todayMs: 69, priorRmssdMs: priors), 20)
        XCTAssertEqual(PersonalUsual.hrvDeltaPercent(todayMs: 115, priorRmssdMs: priors), 100)
        XCTAssertNil(PersonalUsual.hrvDeltaPercent(todayMs: 176, priorRmssdMs: priors))
        XCTAssertNil(PersonalUsual.hrvDeltaPercent(todayMs: 20, priorRmssdMs: priors))
        XCTAssertNil(PersonalUsual.hrvDeltaPercent(todayMs: 69, priorRmssdMs: [55, 60, 56]))
    }

    func testCoachPhraseStatesTheCountAndNeverQuotesBelowFour() {
        let few = (0..<3).map { day($0, hrv: 55) }
        XCTAssertEqual(PersonalUsual.phrase(PersonalUsual.usual(days: few, metric: .hrvRmssd, asOf: key(3)), unit: " ms"),
                       "still learning (3 of 4 nights)")
        let many = (0..<20).map { day($0, hrv: 55) }
        XCTAssertEqual(PersonalUsual.phrase(PersonalUsual.usual(days: many, metric: .restingHR, asOf: key(20)), unit: " bpm"),
                       "52 bpm (28-day usual, median of 20 nights)")
    }

    func testSkinUsualReadsDeviationRowsOnly() {
        let days = (0..<10).map { day($0, hrv: 55, skin: 0.2) } + (10..<14).map { day($0, hrv: 55, skin: 33.5) }
        let ref = PersonalUsual.usual(days: days, metric: .skinTempDeviation, asOf: key(14))
        XCTAssertEqual(ref.n, 10, "imported absolute °C rows are not deviations")
        XCTAssertEqual(ref.centerNative, 0.2, accuracy: 1e-12)
    }
}
