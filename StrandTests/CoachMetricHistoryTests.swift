import XCTest
import WhoopStore
@testable import Strand

/// `query_metric_history` and `find_days` over the synced days (`docs/COACH_MEMORY.md` §7.2): capped tables,
/// automatic coarsening, coverage, dashes for unmeasured stretches, thresholds and ordering.
final class CoachMetricHistoryTests: XCTestCase {
    private let utcZone = TimeZone(secondsFromGMT: 0)!
    /// 2026-10-07 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_374_400)

    private func day(_ offset: Int) -> String {
        CoachDates.day(now.addingTimeInterval(Double(offset) * 86_400), timeZone: utcZone)
    }

    private func metric(_ day: String, hrv: Double?, charge: Double? = 60, sleepMin: Double? = 450, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: 52, avgHrv: hrv, recovery: charge, strain: 40, exerciseCount: nil,
                    steps: steps)
    }

    /// 500 days ending today; HRV is 50 + (index mod 10), and the 31 days of 2026-05 are not measured.
    private lazy var rows: [DailyMetric] = (0..<500).reversed().map { back -> DailyMetric in
        let d = day(-back)
        let hrv: Double? = d.hasPrefix("2026-05") ? nil : 50 + Double(back % 10)
        return metric(d, hrv: hrv, steps: 8_000 + back)
    }

    func testMonthlyHistoryHasAHeaderCoverageAndRowsNewestFirst() {
        let text = CoachMetricHistory.history(days: rows, metric: .hrv, days: 365, group: .month, stat: .mean,
                                              now: now, timeZone: utcZone)
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("LONG-TERM HISTORY: HRV (ms), monthly mean, \(day(-364)) to 2026-10-07 (365 days): measured on 334 days (92% coverage)"), lines[0])
        XCTAssertTrue(text.contains("Whole window: mean"))
        XCTAssertTrue(text.contains("a dash means not measured"))
        let rowsShown = lines.filter { $0.hasPrefix("  ") }
        XCTAssertEqual(rowsShown.first?.hasPrefix("  2026-10:"), true, "newest first")
        XCTAssertEqual(rowsShown.last?.hasPrefix("  2025-10:"), true)
        XCTAssertTrue(rowsShown.contains("  2026-05: —"), "an unmeasured month is a dash, never zero")
        XCTAssertEqual(rowsShown.count, 13)
    }

    func testDailyTablesCoarsenPastOneHundredTwentyRows() {
        let text = CoachMetricHistory.history(days: rows, metric: .hrv, days: 365, group: .day, now: now, timeZone: utcZone)
        XCTAssertTrue(text.contains("weekly mean"))
        XCTAssertTrue(text.contains("Grouped by week because a day table would pass 120 rows."))
        XCTAssertLessThanOrEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("  ") }.count, CoachMetricHistory.maxRows)
        let short = CoachMetricHistory.history(days: rows, metric: .hrv, days: 30, group: .day, now: now, timeZone: utcZone)
        XCTAssertTrue(short.contains("daily mean"))
        XCTAssertTrue(short.contains("  2026-10-07: "))
    }

    func testLongWindowsAreCappedAtFourThousandDays() {
        let text = CoachMetricHistory.history(days: rows, metric: .charge, days: 9_999, group: .year, now: now, timeZone: utcZone)
        XCTAssertTrue(text.contains("(4000 days)"))
        XCTAssertTrue(text.contains("yearly mean"))
    }

    func testSumAndExplicitWindow() {
        let text = CoachMetricHistory.history(days: rows, metric: .steps, from: "2026-09-01", to: "2026-09-30", group: .month,
                                              stat: .sum, now: now, timeZone: utcZone)
        let expected = rows.filter { $0.day.hasPrefix("2026-09") }.compactMap(\.steps).reduce(0, +)
        XCTAssertTrue(text.contains("  2026-09: \(expected) (30 d)"), text)
        XCTAssertTrue(text.contains("total \(expected)"))
    }

    func testNoDataSaysWhatExists() {
        let text = CoachMetricHistory.history(days: rows, metric: .hrv, from: "2026-05-01", to: "2026-05-31", now: now, timeZone: utcZone)
        XCTAssertTrue(text.hasPrefix("No HRV recorded between 2026-05-01 and 2026-05-31."))
        XCTAssertTrue(text.contains("HRV exists on"))
        XCTAssertTrue(CoachMetricHistory.history(days: [], metric: .spo2, now: now, timeZone: utcZone).contains("no Blood oxygen data at all"))
    }

    func testFindDaysBelowAThresholdLowestFirst() {
        let text = CoachMetricHistory.findDays(days: rows, metric: .hrv, below: 52, order: .lowest, now: now, timeZone: utcZone)
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("MATCHING DAYS: HRV (ms) below 52.0"), lines[0])
        XCTAssertTrue(lines[0].contains("showing 10, lowest first"))
        XCTAssertTrue(text.contains("There are at least"))
        let shown = lines.filter { $0.hasPrefix("  ") }
        XCTAssertEqual(shown.count, 10)
        XCTAssertTrue(shown.allSatisfy { $0.contains(": 50.0 ms") }, "lowest first")
        XCTAssertTrue(shown[0].contains("charge 60, sleep 7.5 h"), "each day comes with its other headline numbers")
    }

    func testFindDaysOrderAndLimit() {
        let recent = CoachMetricHistory.findDays(days: rows, metric: .hrv, above: 58, limit: 99, order: .recent, now: now, timeZone: utcZone)
        let shown = recent.components(separatedBy: "\n").filter { $0.hasPrefix("  ") }
        XCTAssertEqual(shown.count, CoachMetricHistory.maxFindLimit)
        XCTAssertTrue(shown.allSatisfy { $0.contains(": 59.0 ms") })
        let days = shown.map { String($0.dropFirst(2).prefix(10)) }
        XCTAssertEqual(days, days.sorted(by: >), "newest first")
        let none = CoachMetricHistory.findDays(days: rows, metric: .hrv, below: 10, now: now, timeZone: utcZone)
        XCTAssertTrue(none.contains("No day in the window meets that condition."))
    }

    func testMetricNamesAndAliases() {
        XCTAssertEqual(CoachMetricHistory.metric(named: "hrv"), .hrv)
        XCTAssertEqual(CoachMetricHistory.metric(named: "HRV"), .hrv)
        XCTAssertEqual(CoachMetricHistory.metric(named: "sleepHours"), .sleepHours)
        XCTAssertEqual(CoachMetricHistory.metric(named: "sleep"), .sleepHours)
        XCTAssertEqual(CoachMetricHistory.metric(named: "Resting heart rate"), .rhr)
        XCTAssertEqual(CoachMetricHistory.metric(named: "recovery"), .charge)
        XCTAssertNil(CoachMetricHistory.metric(named: "vibes"))
        XCTAssertNil(CoachMetricHistory.metric(named: nil))
    }

    func testWeekKeysStartOnMonday() {
        XCTAssertEqual(CoachMetricHistory.key(for: "2026-10-07", group: .week), "week of 2026-10-05")
        XCTAssertEqual(CoachMetricHistory.key(for: "2026-10-04", group: .week), "week of 2026-09-28")
        XCTAssertEqual(CoachMetricHistory.key(for: "2026-10-07", group: .month), "2026-10")
        XCTAssertEqual(CoachMetricHistory.key(for: "2026-10-07", group: .year), "2026")
    }
}
