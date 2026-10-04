import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The Today "N of 4 nights" baseline count must see a night whose sleep session carries HRV even when that
/// night's daily row is still an unscored stub.
final class LiquidBaselineNightsTests: XCTestCase {

    private func row(_ day: String, hrv: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    private func session(wakeLocal: String, minutes: Int, hrv: Double?) -> CachedSleepSession {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let end = Int(f.date(from: wakeLocal)!.timeIntervalSince1970)
        return CachedSleepSession(startTs: end - minutes * 60, endTs: end, efficiency: nil, restingHr: nil,
                                  avgHrv: hrv, stagesJSON: nil)
    }

    func testStubDayIsFilledFromItsSleepSession() {
        let days = [row("2026-09-30", hrv: 83.8), row("2026-10-01", hrv: nil), row("2026-10-02", hrv: 66.0)]
        let sleeps = [session(wakeLocal: "2026-10-01 10:04", minutes: 492, hrv: 74.1)]
        let out = LiquidTodayView.baselineNightlyHrv(days: days, sleeps: sleeps)
        XCTAssertEqual(out.dayKeys, ["2026-09-30", "2026-10-01", "2026-10-02"])
        XCTAssertEqual(out.hrv.compactMap { $0 }.count, 3)
        XCTAssertEqual(out.hrv[1] ?? 0, 74.1, accuracy: 1e-9)
    }

    func testScoredRowWinsOverSession() {
        let out = LiquidTodayView.baselineNightlyHrv(
            days: [row("2026-10-02", hrv: 66.0)],
            sleeps: [session(wakeLocal: "2026-10-02 10:06", minutes: 510, hrv: 99.0)])
        XCTAssertEqual(out.hrv, [66.0])
    }

    func testLongestSessionOfADayWinsAndNoHrvIsSkipped() {
        let out = LiquidTodayView.baselineNightlyHrv(
            days: [],
            sleeps: [session(wakeLocal: "2026-10-03 11:00", minutes: 540, hrv: 53.7),
                     session(wakeLocal: "2026-10-03 15:00", minutes: 40, hrv: 90.0),
                     session(wakeLocal: "2026-10-02 10:00", minutes: 480, hrv: nil)])
        XCTAssertEqual(out.dayKeys, ["2026-10-03"])
        XCTAssertEqual(out.hrv, [53.7])
    }
}
