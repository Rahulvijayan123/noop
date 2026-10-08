import XCTest
@testable import Strand

/// The Events screens' pure pieces: grouping, the phase statistics, the formats, the aligned recovery curves
/// and the treatment calendar's weekday header.
final class EventsPresentationTests: XCTestCase {

    private let sample = HealthEvent.sample

    func testRootShowsTheNewestThreeDaysNewestFirst() {
        let days = EventGrouping.days(sample, filter: .all, limit: 3)
        XCTAssertEqual(days.count, 3)
        XCTAssertTrue(Calendar.current.isDateInToday(days[0].day))
        XCTAssertEqual(days[0].events.map(\.id), ["ev-3", "ev-2", "ev-1"])
        XCTAssertTrue(zip(days, days.dropFirst()).allSatisfy { $0.day > $1.day })
    }

    func testFilterKeepsOnlyItsOrigin() {
        let detected = EventGrouping.days(sample, filter: .detected).flatMap(\.events)
        XCTAssertFalse(detected.isEmpty)
        XCTAssertTrue(detected.allSatisfy { $0.origin == .detected })
        let reported = EventGrouping.days(sample, filter: .reported).flatMap(\.events)
        XCTAssertEqual(detected.count + reported.count, sample.count)
    }

    func testMonthsKeepDayOrder() {
        let days = EventGrouping.days(sample, filter: .all)
        let months = EventGrouping.months(days)
        XCTAssertEqual(months.flatMap(\.days).map(\.day), days.map(\.day))
    }

    func testPhaseStatsOnTheFeaturedEvent() throws {
        let event = try XCTUnwrap(sample.first { $0.id == "ev-2" })
        let physiology = try XCTUnwrap(event.physiology)
        let hrv = EventPhaseStats(physiology: physiology, metric: physiology.metrics[0])
        let before = try XCTUnwrap(hrv.mean(.before))
        let during = try XCTUnwrap(hrv.mean(.during))
        XCTAssertLessThan(during, before)
        XCTAssertLessThan(try XCTUnwrap(hrv.change(.during)), 0)
        XCTAssertEqual(try XCTUnwrap(hrv.change(.during)), (during - before) / before * 100, accuracy: 1e-9)
        // The resting readout is the lowest HRV reading during the event.
        let extreme = try XCTUnwrap(hrv.extreme())
        XCTAssertEqual(extreme.phase, .during)
        XCTAssertLessThanOrEqual(extreme.point.value, during)

        let heart = EventPhaseStats(physiology: physiology, metric: physiology.metrics[1])
        let peak = try XCTUnwrap(heart.extreme())
        XCTAssertGreaterThanOrEqual(peak.point.value, try XCTUnwrap(heart.mean(.during)))
    }

    func testFormats() {
        XCTAssertEqual(EventFormat.percentChange(-53.4), "−53 %")
        XCTAssertEqual(EventFormat.percentChange(18.2), "+18 %")
        XCTAssertEqual(EventFormat.percentChange(0.3), "0 %")
        XCTAssertEqual(EventFormat.duration(168 * 60), "2 h 48 m")
        XCTAssertEqual(EventFormat.duration(180 * 60), "3 h")
        XCTAssertEqual(EventFormat.duration(45 * 60), "45 min")
        XCTAssertEqual(EventFormat.share(0.87), "87")
    }

    func testCadenceIsTheMedianStep() throws {
        let physiology = try XCTUnwrap(sample.first { $0.id == "ev-2" }?.physiology)
        XCTAssertEqual(EventWindowChart.cadenceSeconds(physiology.metrics[0].points), 900)
        XCTAssertEqual(EventWindowChart.cadenceSeconds([]), 300)
    }

    func testRecoveryCurveStartsAtTheEventEnd() throws {
        let event = try XCTUnwrap(sample.first { $0.id == "ev-2" })
        let curve = try XCTUnwrap(EventRecoveryCurves.curve(for: event, metricName: "HRV"))
        XCTAssertEqual(curve.points.first?.offset, 0)
        XCTAssertTrue(curve.points.allSatisfy { $0.offset >= 0 && $0.run == 0 })
        XCTAssertNil(EventRecoveryCurves.curve(for: event, metricName: "Steps"))
        XCTAssertNil(EventRecoveryCurves.curve(for: try XCTUnwrap(sample.first { $0.id == "ev-1" }), metricName: "HRV"))
    }

    func testCalendarHeaderFollowsTheFirstWeekday() {
        var monday = Calendar(identifier: .gregorian)
        monday.locale = Locale(identifier: "en_GB")
        monday.firstWeekday = 2
        XCTAssertEqual(TreatmentMonthGrid.weekdaySymbols(calendar: monday), ["M", "T", "W", "T", "F", "S", "S"])
        var sunday = Calendar(identifier: .gregorian)
        sunday.locale = Locale(identifier: "en_US")
        sunday.firstWeekday = 1
        XCTAssertEqual(TreatmentMonthGrid.weekdaySymbols(calendar: sunday), ["S", "M", "T", "W", "T", "F", "S"])
    }
}
