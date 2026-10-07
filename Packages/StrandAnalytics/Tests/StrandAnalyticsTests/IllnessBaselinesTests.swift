import XCTest
import WhoopStore
@testable import StrandAnalytics

/// BaselineStandard fix C: the illness early warning's z-scores (`IllnessBaselines`).
final class IllnessBaselinesTests: XCTestCase {

    typealias BS = BaselineStandard

    private func key(_ i: Int) -> String { BS.dayKey(BS.epochDay("2026-05-01")! + i) }

    private func day(_ i: Int, rhr: Int? = 52, hrv: Double? = 60, resp: Double? = 15, skin: Double? = 0.0) -> DailyMetric {
        DailyMetric(day: key(i), totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil,
                    skinTempDevC: skin, respRateBpm: resp)
    }

    /// 40 ordinary days with a little variation.
    private func history(_ n: Int = 40) -> [DailyMetric] {
        (0..<n).map { i in
            day(i, rhr: 52 + (i % 3) - 1, hrv: 60 * (1 + 0.08 * Double((i % 5) - 2) / 2),
                resp: 15 + 0.2 * Double(i % 3 - 1), skin: 0.1 * Double(i % 3 - 1))
        }
    }

    func testAnImportedAbsoluteSkinRowNeverReadsAsAHugeZ() {
        // The audit case: the recent rows came from a WHOOP CSV import whose skin column is ABSOLUTE °C.
        var days = history()
        days[38] = day(38, skin: 33.4)
        days[39] = day(39, skin: 33.6)
        let r = IllnessBaselines.evaluate(days: days)
        XCTAssertNil(r.skinTemp.zIllnessward, "no deviation in the recent window → no skin comparison")
        XCTAssertNil(r.skinTemp.engineReading, "absent, not z ≈ 110")
        // A genuine +0.6 °C deviation reads as a moderate, finite z.
        days[38] = day(38, skin: 0.6); days[39] = day(39, skin: 0.6)
        let z = IllnessBaselines.evaluate(days: days).skinTemp.zIllnessward!
        XCTAssertGreaterThan(z, 0.5)
        XCTAssertLessThan(z, 3, "against a floored deviation spread (σ ≥ 0.376 °C), not /0.3 of an absolute")
    }

    func testHRVIsScoredOnLnAndLabelledFromTheSameCentre() {
        var days = history()
        days[38] = day(38, hrv: 42); days[39] = day(39, hrv: 42)
        let s = IllnessBaselines.evaluate(days: days).hrv
        XCTAssertEqual(s.recent!, 42, accuracy: 1e-9, "geometric mean of the recent days")
        let fold = BS.causalFold(BS.series(days, day: \.day, value: \.avgHrv).filter { $0.key >= key(9) && $0.key <= key(36) },
                                 metric: .hrvRmssd, from: key(9), through: key(38))
        let state = fold.before[key(38)]!
        XCTAssertEqual(s.baseline!, exp(state.baseline), accuracy: 1e-9, "label centre = the z's fold centre")
        XCTAssertEqual(s.zIllnessward!, -Baselines.deviation(log(42), state: state).z, accuracy: 1e-12)
        XCTAssertGreaterThan(s.zIllnessward!, 1, "an HRV drop is illness-ward")
    }

    func testTheBaseIsTheCalendarWindowEndingThreeDaysAgo() {
        let s = IllnessBaselines.evaluate(days: history()).restingHR
        XCTAssertEqual(s.n, 28, "days 9…36: 28 calendar days, the guard day and the recent days excluded")
        // A missing week inside the window stays missing (not refilled from older days).
        let gappy = history().filter { !(20..<27).contains(Int(BS.epochDay($0.day)! - BS.epochDay(key(0))!)) }
        XCTAssertEqual(IllnessBaselines.evaluate(days: gappy).restingHR.n, 21)
    }

    func testConfoundedDaysStayOutOfTheBase() {
        let logs = [key(20): LBDayLog(feltIll: true), key(21): LBDayLog(travel: true)]
        let s = IllnessBaselines.evaluate(days: history(), context: BS.Context(dayLogs: logs)).restingHR
        XCTAssertEqual(s.n, 26)
    }

    func testFewerThanFourBaseDaysGiveNoZ() {
        let days = history().enumerated().map { i, d in
            (9...36).contains(i) && i > 11 ? day(i, rhr: nil, hrv: nil, resp: nil, skin: nil) : d
        }
        let r = IllnessBaselines.evaluate(days: days)
        XCTAssertEqual(r.restingHR.n, 3)
        XCTAssertNil(r.restingHR.zIllnessward)
        XCTAssertEqual(r.restingHR.engineReading?.present, false)
    }

    func testTheRaiseGateNeedsRestingHRAndHRVBothTrusted() {
        // HRV only on 10 base days (usable, not trusted); resting HR on all 28 (trusted).
        let days = history().enumerated().map { i, d in
            (9...26).contains(i) ? day(i, rhr: d.restingHr, hrv: nil, resp: d.respRateBpm, skin: d.skinTempDevC) : d
        }
        let r = IllnessBaselines.evaluate(days: days)
        XCTAssertTrue(r.restingHR.trusted)
        XCTAssertTrue(r.hrv.usable)
        XCTAssertFalse(r.hrv.trusted)
        XCTAssertFalse(r.baselineTrusted, "was RHR OR HRV; now both must be trusted")
        XCTAssertTrue(IllnessBaselines.evaluate(days: history()).baselineTrusted)
    }
}
