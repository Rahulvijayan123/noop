import XCTest
@testable import StrandAnalytics

/// run1 D4-15: HRV readiness windows by calendar days, with a minimum-valid-nights rule.
final class HRVReadinessCalendarTests: XCTestCase {
    private func key(_ i: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let d = cal.date(byAdding: .day, value: i, to: cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!)!
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// 40 nightly readings, then a 21-day break, then 2 nights back. The night-indexed read happily
    /// reports a tier from a "7-night baseline" that is mostly a month old; the calendar read is nil.
    func testA21DayGapWithFewRecentNightsIsNotRead() {
        var keys: [String] = [], vals: [Double?] = []
        for i in 0..<40 { keys.append(key(i)); vals.append(60 + Double(i % 5)) }
        for i in 61..<63 { keys.append(key(i)); vals.append(40) }
        XCTAssertNotNil(HRVReadiness.evaluate(avgHrv: vals), "old behaviour: a tier off stale nights")
        XCTAssertNil(HRVReadiness.evaluate(avgHrv: vals, dayKeys: keys))
        // As of 30 days after the last night nothing recent exists either.
        XCTAssertNil(HRVReadiness.evaluate(avgHrv: vals, dayKeys: keys, asOfDay: key(92)))
    }

    /// Enough recent nights: the calendar read matches the night-indexed read on a gap-free history.
    func testAGapFreeHistoryMatchesTheNightIndexedRead() {
        let vals: [Double?] = (0..<70).map { 55 + Double($0 % 7) }
        let keys = (0..<70).map(key)
        XCTAssertEqual(HRVReadiness.evaluate(avgHrv: vals, dayKeys: keys), HRVReadiness.evaluate(avgHrv: vals))
        let short: [Double?] = Array(vals.prefix(20))
        XCTAssertEqual(HRVReadiness.evaluate(avgHrv: short, dayKeys: Array(keys.prefix(20))),
                       HRVReadiness.evaluate(avgHrv: short))
    }

    /// The minimum-valid-nights rule: three valid nights in the trailing week is not enough; four is.
    func testMinimumValidNightsInTheTrailingWeek() {
        var keys = (0..<30).map(key)
        var vals: [Double?] = (0..<30).map { 55 + Double($0 % 3) }
        // Last 7 calendar days: only 3 valid (the rest nil).
        for i in 23..<30 where ![23, 25, 27].contains(i) { vals[i] = nil }
        XCTAssertNil(HRVReadiness.evaluate(avgHrv: vals, dayKeys: keys))
        vals[29] = 50
        XCTAssertNotNil(HRVReadiness.evaluate(avgHrv: vals, dayKeys: keys))
        // A day after asOf is ignored.
        let asOf29 = HRVReadiness.evaluate(avgHrv: vals, dayKeys: keys)
        keys.append(key(31)); vals.append(200)
        XCTAssertEqual(HRVReadiness.evaluate(avgHrv: vals, dayKeys: keys, asOfDay: key(29)), asOf29)
        XCTAssertNotEqual(HRVReadiness.evaluate(avgHrv: vals, dayKeys: keys), asOf29)
    }
}
