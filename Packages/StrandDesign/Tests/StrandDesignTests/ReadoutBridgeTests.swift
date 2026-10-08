import XCTest
@testable import StrandDesign

/// The bridge from chart values to the readout above a chart: the selected point (or the latest), the date
/// line in the period the mark covers, "—" for a selected day without a reading, and the estimate flag.
final class ReadoutBridgeTests: XCTestCase {

    private let locale = Locale(identifier: "en_GB")

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 2
        return c
    }()

    private func day(_ d: Int, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: d))!
    }

    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 15))! }

    private var points: [DailyPoint] {
        [DailyPoint(day: day(3), value: 58), DailyPoint(day: day(5), value: 61.4, isEstimate: true),
         DailyPoint(day: day(7), value: 64)]
    }

    private let fmt: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0))) }

    func testPeriodFollowsTheBin() {
        XCTAssertEqual(ReadoutContent.Period(bin: .day), .day)
        XCTAssertEqual(ReadoutContent.Period(bin: .day, nightly: true), .night)
        XCTAssertEqual(ReadoutContent.Period(bin: .weekOfYear), .week)
        XCTAssertEqual(ReadoutContent.Period(bin: .month), .month)
    }

    func testNoSelectionShowsTheLatestPoint() {
        let content = ReadoutContent.daily(selection: nil, in: points, unit: "ms", format: fmt,
                                           context: "7-day avg 61 ms", now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(content.displayValue, "64")
        XCTAssertEqual(content.displayUnit, "ms")
        XCTAssertEqual(content.context, "7-day avg 61 ms")
        XCTAssertTrue(content.dateLine.contains("7"), content.dateLine)
        XCTAssertTrue(content.dateLine.contains("Oct"), content.dateLine)
        XCTAssertFalse(content.isEstimate)
    }

    func testSelectionAnywhereInTheDayShowsThatDaysPointWithItsEstimateFlag() {
        let evening = calendar.date(byAdding: .hour, value: 21, to: day(5))!
        let content = ReadoutContent.daily(selection: evening, in: points, unit: "ms", format: fmt,
                                           now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(content.displayValue, "61")
        XCTAssertTrue(content.isEstimate)
        XCTAssertTrue(content.dateLine.contains("5"), content.dateLine)
    }

    func testSelectedDayWithoutAReadingIsADashUnderThatDay() {
        let content = ReadoutContent.daily(selection: day(4), in: points, unit: "ms", format: fmt,
                                           now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(content.displayValue, "—")
        XCTAssertNil(content.displayUnit)
        XCTAssertTrue(content.dateLine.contains("4"), content.dateLine)
        XCTAssertFalse(content.isEstimate)
    }

    func testNoDataReservesAnEmptyDateLine() {
        let content = ReadoutContent.daily(selection: nil, in: [], unit: "ms", format: fmt,
                                           now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(content.displayValue, "—")
        XCTAssertEqual(content.dateLine, "")
    }

    func testNightlyPointReadsAsTheNightBeforeItsWakeDay() {
        let content = ReadoutContent.daily(points.last, unit: "ms", format: fmt, period: .night,
                                           now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(content.dateLine.contains("6"), content.dateLine)
        XCTAssertTrue(content.dateLine.contains("7"), content.dateLine)
    }

    func testBinnedSelectionShowsTheBinAndAWeekLine() {
        let daily = (0..<14).map { DailyPoint(day: day(1 + $0), value: Double(8_000 + $0 * 100)) }
        let weekly = DailyBarChart.bin(daily, by: .weekOfYear, aggregation: .mean, calendar: calendar)
        let content = ReadoutContent.daily(selection: day(8), in: weekly, bin: .weekOfYear, unit: "steps",
                                           format: fmt, now: now, calendar: calendar, locale: locale)
        // The week of Mon 5 Oct: days 5...11 average to 8,700.
        XCTAssertEqual(content.displayValue, "8,700")
        XCTAssertTrue(content.dateLine.hasPrefix("Week of"), content.dateLine)
        XCTAssertTrue(content.dateLine.contains("5"), content.dateLine)
    }

    func testValueColorOnlyForARealPoint() {
        let colored = ReadoutContent.daily(points.last, unit: "%", format: fmt, valueColor: { _ in .red },
                                           now: now, calendar: calendar, locale: locale)
        XCTAssertNotNil(colored.valueColor)
        let missing = ReadoutContent.daily(nil, unit: "%", format: fmt, valueColor: { _ in .red },
                                           now: now, calendar: calendar, locale: locale)
        XCTAssertNil(missing.valueColor)
    }

    #if !os(watchOS)
    func testIntradayReadoutUsesTheNearestSampleAndATimeLine() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14))!
        let samples = (0..<6).map { IntradayChart.Sample(time: start.addingTimeInterval(Double($0) * 300),
                                                         value: Double(60 + $0)) }
        let selected = start.addingTimeInterval(640)   // nearest is the 10-minute sample
        XCTAssertEqual(ChartSelection.sample(for: selected, in: samples)?.value, 62)
        let content = ReadoutContent.intraday(selection: selected, in: samples, unit: "bpm", format: fmt,
                                              now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(content.displayValue, "62")
        XCTAssertEqual(content.displayUnit, "bpm")
        XCTAssertTrue(content.dateLine.contains("14:10"), content.dateLine)

        let latest = ReadoutContent.intraday(selection: nil, in: samples, unit: "bpm", format: fmt,
                                             now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(latest.displayValue, "65")
        XCTAssertNil(ChartSelection.sample(for: nil, in: samples))
    }
    #endif

    #if DEBUG && !os(watchOS)
    func testDemoSelectionPicksTheFractionOfTheXPositions() {
        XCTAssertEqual(NaraChartDemoSelection.parse(["app", "--demo-chart-select", "0.7"]), 0.7)
        XCTAssertEqual(NaraChartDemoSelection.parse(["app", "--demo-chart-select", "3"]), 1)
        XCTAssertNil(NaraChartDemoSelection.parse(["app", "--demo-chart-select"]))
        XCTAssertNil(NaraChartDemoSelection.parse(["app", "--demo-chart-select", "x"]))
        XCTAssertNil(NaraChartDemoSelection.parse(["app"]))
        XCTAssertEqual(NaraChartDemoSelection.index(fraction: 0.7, count: 11), 7)
        XCTAssertEqual(NaraChartDemoSelection.index(fraction: 0, count: 5), 0)
        XCTAssertEqual(NaraChartDemoSelection.index(fraction: 1, count: 5), 4)
        XCTAssertEqual(NaraChartDemoSelection.index(fraction: 0.7, count: 1), 0)
        XCTAssertNil(NaraChartDemoSelection.index(fraction: 0.7, count: 0))
    }
    #endif
}
