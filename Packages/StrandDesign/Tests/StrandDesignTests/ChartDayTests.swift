import XCTest
@testable import StrandDesign

/// Daily charts plot each value at the LOCAL start of the day its key names.
///
/// The detail page parsed `yyyy-MM-dd` keys at UTC midnight and handed those instants to an axis that marks
/// local days, so for anyone west of UTC every reading sat on the evening before its day: points between
/// "Oct 4" and "Oct 5" for the 5th, and no label at all on the newest day. These pin the bridge in fixed
/// zones on both sides of UTC (and on it), across clock changes, and under a non-Gregorian calendar.
final class ChartDayTests: XCTestCase {

    private let zones = ["America/Los_Angeles", "Pacific/Auckland", "UTC"]

    private func calendar(_ zone: String, _ identifier: Calendar.Identifier = .gregorian) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// The defect, stated directly: the key's date has the key's day as its LOCAL day, at local midnight.
    func testAKeyLandsAtTheStartOfItsOwnLocalDayInEveryZone() throws {
        for zone in zones {
            let cal = calendar(zone)
            let date = try XCTUnwrap(ChartDay.date(forKey: "2026-10-07", calendar: cal), zone)
            let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 10, 7, 0, 0], zone)
        }
    }

    /// Every day of two years survives key -> date -> key in each zone, including both clock changes.
    func testEveryDayOfTwoYearsRoundTrips() throws {
        let utc = calendar("UTC")
        let start = try XCTUnwrap(ChartDay.date(forKey: "2025-01-01", calendar: utc))
        for zone in zones + ["America/Santiago"] {
            let cal = calendar(zone)
            for offset in 0..<730 {
                let key = ChartDay.key(for: start.addingTimeInterval(Double(offset) * 86_400 + 43_200), calendar: utc)
                let date = try XCTUnwrap(ChartDay.date(forKey: key, calendar: cal), "\(zone) \(key)")
                XCTAssertEqual(ChartDay.key(for: date, calendar: cal), key, "\(zone) \(key)")
                XCTAssertEqual(date, cal.startOfDay(for: date), "\(zone) \(key) is not its day's first instant")
            }
        }
    }

    /// A Buddhist or Japanese calendar must not move a Gregorian key five centuries.
    func testKeysAreGregorianWhateverCalendarTheViewerUses() throws {
        for identifier in [Calendar.Identifier.buddhist, .japanese] {
            let cal = calendar("America/Los_Angeles", identifier)
            let date = try XCTUnwrap(ChartDay.date(forKey: "2026-10-07", calendar: cal))
            XCTAssertEqual(ChartDay.key(for: date, calendar: cal), "2026-10-07")
            XCTAssertEqual(date, ChartDay.date(forKey: "2026-10-07", calendar: calendar("America/Los_Angeles")))
        }
    }

    func testMalformedAndImpossibleKeysAreRejected() {
        let cal = calendar("UTC")
        for key in ["", "2026-02-30", "2026-13-01", "2026-1-07", "26-10-07", "2026/10/07", "2026-+1-07",
                    "abcd-ef-gh", "2026-10-07T00", " 2026-10-07"] {
            XCTAssertNil(ChartDay.date(forKey: key, calendar: cal), "\"\(key)\" parsed")
        }
        XCTAssertNotNil(ChartDay.date(forKey: "2028-02-29", calendar: cal), "a leap day is a real day")
    }

    /// Call sites that still hold UTC-midnight dates get the same calendar day locally.
    func testAUTCMidnightBecomesTheSameCalendarDayLocally() throws {
        let utcMidnight = try XCTUnwrap(ChartDay.date(forKey: "2026-10-07", calendar: calendar("UTC")))
        for zone in zones {
            let cal = calendar(zone)
            let local = ChartDay.day(fromUTCMidnight: utcMidnight, calendar: cal)
            XCTAssertEqual(ChartDay.key(for: local, calendar: cal), "2026-10-07", zone)
            XCTAssertEqual(local, cal.startOfDay(for: local), zone)
        }
    }

    #if !os(watchOS)
    /// The bridge from `TrendPoint` keeps the day and the segment.
    func testTheTrendPointBridgeKeepsTheDayAndSeries() throws {
        let la = calendar("America/Los_Angeles")
        let utcMidnight = try XCTUnwrap(ChartDay.date(forKey: "2026-10-07", calendar: calendar("UTC")))
        let point = DailyPoint(TrendPoint(date: utcMidnight, value: 61, segment: "rmssd"), dayIsUTC: true, calendar: la)
        XCTAssertEqual(ChartDay.key(for: point.day, calendar: la), "2026-10-07")
        XCTAssertEqual(point.series, "rmssd")
        XCTAssertEqual(point.value, 61)
        XCTAssertNil(DailyPoint(key: "2026-02-30", value: 1, calendar: la))
        XCTAssertEqual(DailyPoint(key: "2026-10-07", value: 1, calendar: la)?.day, ChartDay.date(forKey: "2026-10-07", calendar: la))
    }
    #endif

    /// A mark plotted with `unit: .day` sits half way through the REAL day, 23 or 25 hours on a clock change.
    func testTheCentreOfAClockChangeDayIsHalfWayThroughIt() throws {
        let la = calendar("America/Los_Angeles")
        for (key, hours) in [("2026-03-08", 23.0), ("2026-11-01", 25.0), ("2026-10-07", 24.0)] {
            let start = try XCTUnwrap(ChartDay.date(forKey: key, calendar: la))
            let centre = ChartDay.center(of: start, calendar: la)
            XCTAssertEqual(centre.timeIntervalSince(start), hours * 3600 / 2, accuracy: 0.5, key)
            XCTAssertEqual(la.startOfDay(for: centre), start, key)
        }
    }

    func testDaysBetweenCountsCalendarDaysAcrossAClockChange() throws {
        let la = calendar("America/Los_Angeles")
        let before = try XCTUnwrap(ChartDay.date(forKey: "2026-03-07", calendar: la))
        let after = try XCTUnwrap(ChartDay.date(forKey: "2026-03-09", calendar: la))
        XCTAssertEqual(ChartDay.daysBetween(before, after, calendar: la), 2)
        XCTAssertEqual(ChartDay.daysBetween(after.addingTimeInterval(-60), after, calendar: la), 1)
        XCTAssertEqual(ChartDay.daysBetween(after, before, calendar: la), -2)
    }
}
