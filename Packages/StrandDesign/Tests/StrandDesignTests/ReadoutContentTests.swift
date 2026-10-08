import XCTest
@testable import StrandDesign

/// What the readout above a chart prints. The view is a fixed frame; these are the rules that decide its
/// text: "—" with no unit for a missing value, one spoken string for VoiceOver, and date lines that say
/// which day, night, week or month a value covers.
///
/// Date assertions check the parts a reader relies on (the day, the month, the year when it is needed)
/// rather than whole strings, because ICU's exact punctuation and spacing (thin spaces around an
/// interval's dash, for one) changes between OS releases.
final class ReadoutContentTests: XCTestCase {

    private let locale = Locale(identifier: "en_GB")

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // Monday, as in en_GB
        return c
    }()

    /// 2026-10-07 14:05 UTC, a Wednesday.
    private var wednesday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 5))!
    }

    // MARK: Values and units

    func testMissingValueIsADashWithNoUnit() {
        let missing = ReadoutContent(dateLine: "Tue 7 Oct", value: nil, unit: "ms")
        XCTAssertEqual(missing.displayValue, "—")
        XCTAssertNil(missing.displayUnit)

        let blank = ReadoutContent(dateLine: "Tue 7 Oct", value: "  ", unit: "ms")
        XCTAssertEqual(blank.displayValue, "—")
        XCTAssertNil(blank.displayUnit)
    }

    func testUnitSitsBesideARealValueOnly() {
        let hrv = ReadoutContent(dateLine: "Tue 7 Oct", value: "62", unit: "ms")
        XCTAssertEqual(hrv.displayValue, "62")
        XCTAssertEqual(hrv.displayUnit, "ms")
        XCTAssertNil(ReadoutContent(dateLine: "", value: "62", unit: "").displayUnit)
        XCTAssertNil(ReadoutContent(dateLine: "", value: "4.2", unit: nil).displayUnit)
    }

    func testAccessibilityTextReadsAsOneSentence() {
        let content = ReadoutContent(dateLine: "Tue 7 Oct", value: "62", unit: "ms", context: "7-day avg 61 ms")
        XCTAssertEqual(content.accessibilityText, "Tue 7 Oct, 62 ms, 7-day avg 61 ms")

        let estimate = ReadoutContent(dateLine: "Week of 29 Sep", value: "9,412", unit: "steps", isEstimate: true)
        XCTAssertEqual(estimate.accessibilityText, "Week of 29 Sep, 9,412 steps, estimate")

        let missing = ReadoutContent(dateLine: "Tue 7 Oct", value: nil, unit: "ms")
        XCTAssertEqual(missing.accessibilityText, "Tue 7 Oct, No value")
    }

    // MARK: Date lines

    func testDayLineNamesTheWeekdayDayAndMonth() {
        let line = ReadoutContent.dateLine(wednesday, period: .day, now: wednesday, calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("Wed"), line)
        XCTAssertTrue(line.contains("7"), line)
        XCTAssertTrue(line.contains("Oct"), line)
        XCTAssertFalse(line.contains("2026"), "the current year is implied: \(line)")
    }

    func testDayLineAddsTheYearOutsideTheCurrentYear() {
        let nextYear = calendar.date(byAdding: .year, value: 1, to: wednesday)!
        let line = ReadoutContent.dateLine(wednesday, period: .day, now: nextYear, calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("2026"), line)
    }

    func testMonthLineAlwaysCarriesTheYear() {
        let line = ReadoutContent.dateLine(wednesday, period: .month, now: wednesday, calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("Oct"), line)
        XCTAssertTrue(line.contains("2026"), line)
    }

    /// A week is named by its first day in the calendar's own week (Monday here), whichever day of it the
    /// caller passes.
    func testWeekLineStartsOnTheCalendarsFirstWeekday() {
        let line = ReadoutContent.dateLine(wednesday, period: .week, now: wednesday, calendar: calendar, locale: locale)
        XCTAssertTrue(line.hasPrefix("Week of"), line)
        XCTAssertTrue(line.contains("5"), "Monday 5 Oct starts the week: \(line)")
        XCTAssertFalse(line.contains("7"), line)
    }

    /// A night is named by both of its days: the evening it started and the morning it was woken on.
    func testNightLineSpansBedtimeDayToWakeDay() {
        let line = ReadoutContent.dateLine(wednesday, period: .night, now: wednesday, calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("Tue"), line)
        XCTAssertTrue(line.contains("Wed"), line)
        XCTAssertTrue(line.contains("6"), line)
        XCTAssertTrue(line.contains("7"), line)
    }

    func testTimeLineCarriesTheClockTime() {
        let line = ReadoutContent.dateLine(wednesday, period: .time, now: wednesday, calendar: calendar, locale: locale)
        XCTAssertTrue(line.contains("14:05"), line)
        XCTAssertTrue(line.contains("7"), line)
    }
}
