#if !os(watchOS)
import XCTest
@testable import StrandDesign

/// The kit's x-axis: a fixed window per range ending today, marks in the middle of their days (where a bar
/// plotted with `unit: .day` sits), the newest day or month always labelled, labels that never repeat and
/// never hang off the plot. Checked in zones either side of UTC and across clock changes, because the
/// one-day-early axis this replaces only showed up away from UTC.
final class ChartAxisTests: XCTestCase {

    private let zones = ["America/Los_Angeles", "Pacific/Auckland", "UTC"]

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// Labels with ICU's narrow no-break space ("12\u{202F}AM") read back as plain spaces.
    private func plain(_ labels: [String]) -> [String] {
        labels.map { $0.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
    }

    /// Noon on a given day in a zone.
    private func noon(_ key: String, _ cal: Calendar) -> Date {
        ChartDay.date(forKey: key, calendar: cal)!.addingTimeInterval(12 * 3600)
    }

    // MARK: Window

    func testEachRangeIsItsDaysEndingWithTodayOnLocalBoundaries() {
        for zone in zones {
            let cal = calendar(zone)
            let now = noon("2026-10-07", cal)
            for range in ChartRange.allCases where range != .all {
                let window = ChartAxis.window(range, now: now, firstDataDay: nil, calendar: cal)
                XCTAssertEqual(window.upperBound, cal.dateInterval(of: .day, for: now)!.end, "\(zone) \(range)")
                XCTAssertEqual(window.lowerBound, cal.startOfDay(for: window.lowerBound), "\(zone) \(range)")
                XCTAssertEqual(ChartAxis.dayCount(window, calendar: cal), range.days, "\(zone) \(range)")
            }
        }
    }

    func testAShortClockWindowDropsAnEdgeLabelThatWouldOverlapItsNeighbour() {
        // An event page: 30 minutes either side of a 30-minute event, starting 3 minutes before 8:00 PM.
        let cal = calendar("America/Los_Angeles")
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 19, minute: 57))!
        let window = start...start.addingTimeInterval(90 * 60)
        let layout = ChartAxis.layout(window, style: .hours, calendar: cal)
        XCTAssertEqual(layout.grid.count, 6, "every 15-minute tick keeps its grid line")
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let extents = layout.marks.indices.map { i -> ClosedRange<Double> in
            let at = layout.marks[i].timeIntervalSince(window.lowerBound) / span
            let width = ChartAxis.estimatedWidth(layout.labels[i]) / ChartAxis.assumedPlotWidth
            switch layout.anchors[i] {
            case .leading: return at...(at + width)
            case .trailing: return (at - width)...at
            case .center: return (at - width / 2)...(at + width / 2)
            }
        }
        for (a, b) in zip(extents, extents.dropFirst()) { XCTAssertLessThan(a.upperBound, b.lowerBound) }
        XCTAssertEqual(layout.marks.last, layout.grid.last, "the newest label always stays")
    }

    func testAllStartsAtTheFirstDataDayAndIsNeverShorterThanAWeek() {
        let cal = calendar("America/Los_Angeles")
        let now = noon("2026-10-07", cal)
        let first = ChartDay.date(forKey: "2026-06-29", calendar: cal)!
        let window = ChartAxis.window(.all, now: now, firstDataDay: first, calendar: cal)
        XCTAssertEqual(window.lowerBound, first)
        XCTAssertEqual(ChartAxis.dayCount(window, calendar: cal), 101)
        let recent = ChartDay.date(forKey: "2026-10-05", calendar: cal)!
        XCTAssertEqual(ChartAxis.dayCount(ChartAxis.window(.all, now: now, firstDataDay: recent, calendar: cal), calendar: cal), 7)
        XCTAssertEqual(ChartAxis.dayCount(ChartAxis.window(.all, now: now, firstDataDay: nil, calendar: cal), calendar: cal), 7)
    }

    func testAWindowSpanningAClockChangeStillCountsItsDays() {
        let la = calendar("America/Los_Angeles")
        let window = ChartAxis.window(.week, now: noon("2026-03-10", la), firstDataDay: nil, calendar: la)
        XCTAssertEqual(ChartAxis.dayCount(window, calendar: la), 7)
        XCTAssertEqual(ChartDay.key(for: window.lowerBound, calendar: la), "2026-03-04")
    }

    // MARK: Invariants over a year of windows

    /// For every day of a year (both clock changes included), in three zones, for every range: labels are
    /// distinct, marks ascend inside the window, day marks sit in the middle of distinct days, and the
    /// newest day (or month) is labelled.
    func testEveryWindowOfAYearKeepsTheAxisInvariants() {
        for zone in zones {
            let cal = calendar(zone)
            var now = noon("2026-01-01", cal)
            let firstData = ChartDay.date(forKey: "2023-05-17", calendar: cal)!
            for _ in 0..<366 {
                for range in ChartRange.allCases {
                    let window = ChartAxis.window(range, now: now, firstDataDay: firstData, calendar: cal)
                    let layout = ChartAxis.layout(window, style: range.axisStyle, calendar: cal)
                    let context = "\(zone) \(range) \(ChartDay.key(for: now, calendar: cal))"
                    XCTAssertEqual(Set(layout.labels).count, layout.labels.count, "repeated label \(layout.labels) \(context)")
                    XCTAssertEqual(layout.marks, layout.marks.sorted(), context)
                    XCTAssertFalse(layout.marks.isEmpty, context)
                    XCTAssertTrue(layout.marks.allSatisfy { window.contains($0) }, context)
                    XCTAssertEqual(layout.labels.count, layout.marks.count, context)
                    switch layout.style {
                    case .weekday, .dayOfMonth:
                        let starts = layout.marks.map { cal.startOfDay(for: $0) }
                        XCTAssertEqual(Set(starts).count, starts.count, "two marks in one day \(context)")
                        XCTAssertTrue(layout.marks.allSatisfy { ChartDay.center(of: $0, calendar: cal) == $0 },
                                      "a mark is off its day's centre \(context)")
                        XCTAssertEqual(starts.last, cal.startOfDay(for: now), "newest day unlabelled \(context)")
                    case .month:
                        XCTAssertTrue(cal.isDate(layout.marks.last!, equalTo: now, toGranularity: .month),
                                      "newest month unlabelled \(context)")
                    case .monthYear:
                        XCTAssertTrue(cal.isDate(layout.marks.last!, equalTo: now, toGranularity: .year), context)
                    case .hours:
                        XCTFail("a day range drew hours \(context)")
                    }
                }
                now = cal.date(byAdding: .day, value: 1, to: now)!
            }
        }
    }

    // MARK: Formats

    func testAWeekReadsByWeekday() {
        let cal = calendar("UTC")
        let layout = ChartAxis.layout(ChartAxis.window(.week, now: noon("2026-10-07", cal), firstDataDay: nil, calendar: cal),
                                      style: .weekday, calendar: cal)
        XCTAssertEqual(layout.labels, ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"])
    }

    /// Day numbers, with the month on the first mark of each month so "1" is never ambiguous.
    func testAMonthReadsByDayWithTheMonthOnItsFirstMark() {
        let cal = calendar("America/Los_Angeles")
        let layout = ChartAxis.layout(ChartAxis.window(.month, now: noon("2026-10-07", cal), firstDataDay: nil, calendar: cal),
                                      style: .dayOfMonth, calendar: cal)
        XCTAssertEqual(layout.labels, ["Sep 13", "19", "25", "Oct 1", "7"])
        XCTAssertEqual(layout.anchors.first, .center)
    }

    /// Month labels start on their month's boundary, where the grid line is, and read across the month.
    func testThreeMonthsReadByMonthFromEachBoundary() {
        let cal = calendar("Pacific/Auckland")
        let window = ChartAxis.window(.quarter, now: noon("2026-10-07", cal), firstDataDay: nil, calendar: cal)
        let layout = ChartAxis.layout(window, style: .month, calendar: cal)
        XCTAssertEqual(layout.labels, ["Jul", "Aug", "Sep", "Oct"])
        XCTAssertEqual(layout.grid.map { ChartDay.key(for: $0, calendar: cal) }, ["2026-08-01", "2026-09-01", "2026-10-01"])
        XCTAssertEqual(layout.marks.prefix(3).map { ChartDay.key(for: $0, calendar: cal) }, ["2026-07-10", "2026-08-01", "2026-09-01"])
        XCTAssertEqual(Array(layout.anchors.prefix(3)), [.leading, .leading, .leading])
    }

    /// A week of the newest month on a six-month axis is too narrow for "Oct": it is right-aligned at the
    /// window's end instead of being cut off.
    func testANarrowNewestMonthIsLabelledAtTheEnd() {
        let cal = calendar("UTC")
        let window = ChartAxis.window(.half, now: noon("2026-10-07", cal), firstDataDay: nil, calendar: cal)
        let layout = ChartAxis.layout(window, style: .month, calendar: cal)
        XCTAssertEqual(layout.labels.last, "Oct")
        XCTAssertEqual(layout.anchors.last, .trailing)
        XCTAssertEqual(layout.marks.last, window.upperBound.addingTimeInterval(-1))
    }

    /// A year window holds two Octobers; the year tells them apart, and the longer labels get more room.
    func testAYearWithTwoOfTheSameMonthAddsTheYear() {
        let cal = calendar("UTC")
        let window = ChartAxis.window(.year, now: noon("2026-10-07", cal), firstDataDay: nil, calendar: cal)
        let layout = ChartAxis.layout(window, style: .month, calendar: cal)
        XCTAssertEqual(layout.style, .monthYear)
        XCTAssertEqual(layout.labels, ["Oct 2025", "Feb 2026", "Jun", "Oct"])
    }

    func testYearsOfHistoryReadByYear() {
        let cal = calendar("UTC")
        let window = ChartAxis.window(.all, now: noon("2026-10-07", cal),
                                      firstDataDay: ChartDay.date(forKey: "2023-01-15", calendar: cal), calendar: cal)
        XCTAssertEqual(ChartAxis.layout(window, style: .monthYear, calendar: cal).labels, ["2023", "2024", "2025", "2026"])
    }

    func testAShortAllWindowReadsByDayNotByMonth() {
        let cal = calendar("UTC")
        let window = ChartAxis.window(.all, now: noon("2026-10-07", cal),
                                      firstDataDay: ChartDay.date(forKey: "2026-10-05", calendar: cal), calendar: cal)
        XCTAssertEqual(ChartAxis.layout(window, style: .monthYear, calendar: cal).style, .weekday)
        XCTAssertEqual(ChartAxis.effectiveStyle(.monthYear, window: ChartAxis.window(.all, now: noon("2026-10-07", cal),
            firstDataDay: ChartDay.date(forKey: "2026-09-01", calendar: cal), calendar: cal), calendar: cal), .monthYear)
    }

    // MARK: Hours

    /// A day ends on the midnight it began with; that closing mark would repeat "12 AM" on the edge.
    func testAFullDayDropsItsClosingMidnight() {
        let la = calendar("America/Los_Angeles")
        let start = ChartDay.date(forKey: "2026-10-07", calendar: la)!
        let layout = ChartAxis.layout(start...la.dateInterval(of: .day, for: start)!.end, style: .hours, calendar: la)
        XCTAssertEqual(plain(layout.labels), ["12 AM", "6 AM", "12 PM", "6 PM"])
        XCTAssertEqual(layout.anchors.first, .leading)
    }

    /// A compact card asks for four labels; the closing midnight must not count against them.
    func testACompactFullDayStillGetsFourLabels() {
        let la = calendar("America/Los_Angeles")
        let start = ChartDay.date(forKey: "2026-10-07", calendar: la)!
        let layout = ChartAxis.layout(start...la.dateInterval(of: .day, for: start)!.end, style: .hours, target: 4, calendar: la)
        XCTAssertEqual(plain(layout.labels), ["12 AM", "6 AM", "12 PM", "6 PM"])
    }

    /// Over more than a day the midnights carry the weekday instead of a second "12 AM".
    func testAWindowOverMidnightNamesTheDays() {
        let la = calendar("America/Los_Angeles")
        let start = ChartDay.date(forKey: "2026-10-06", calendar: la)!.addingTimeInterval(18 * 3600)
        let end = ChartDay.date(forKey: "2026-10-08", calendar: la)!
        let layout = ChartAxis.layout(start...end, style: .hours, calendar: la)
        XCTAssertEqual(Set(layout.labels).count, layout.labels.count, "\(layout.labels)")
        XCTAssertTrue(layout.labels.contains("Wed"), "midnight names its day: \(layout.labels)")
    }

    func testShortWindowsLabelMinutes() {
        let utc = calendar("UTC")
        let start = ChartDay.date(forKey: "2026-10-07", calendar: utc)!.addingTimeInterval(9 * 3600)
        let layout = ChartAxis.layout(start...start.addingTimeInterval(90 * 60), style: .hours, calendar: utc)
        XCTAssertEqual(plain(layout.labels).first, "9:00 AM")
        XCTAssertEqual(Set(layout.labels).count, layout.labels.count)
    }

    // MARK: Snapping and anchors

    func testBinnedBarsSnapTheWindowToWholeBins() {
        let utc = calendar("UTC")
        let window = ChartAxis.window(.quarter, now: noon("2026-10-07", utc), firstDataDay: nil, calendar: utc)
        let months = ChartAxis.snap(window, to: .month, calendar: utc)
        XCTAssertEqual(ChartDay.key(for: months.lowerBound, calendar: utc), "2026-07-01")
        XCTAssertEqual(ChartDay.key(for: months.upperBound, calendar: utc), "2026-11-01")
        var mondays = utc
        mondays.firstWeekday = 2
        let weeks = ChartAxis.snap(window, to: .weekOfYear, calendar: mondays)
        XCTAssertEqual(mondays.component(.weekday, from: weeks.lowerBound), 2)
        XCTAssertEqual(mondays.component(.weekday, from: weeks.upperBound), 2)
    }

    /// Swift Charts truncates an x label that does not fit inside the plot, so one centred near an edge is
    /// anchored on that edge instead.
    func testEdgeLabelsArePulledInsideThePlot() {
        let start = Date(timeIntervalSince1970: 0)
        let window = start...start.addingTimeInterval(1000)
        XCTAssertEqual(ChartAxis.anchor(for: start.addingTimeInterval(10), label: "Oct 7", in: window), .leading)
        XCTAssertEqual(ChartAxis.anchor(for: start.addingTimeInterval(500), label: "Oct 7", in: window), .center)
        XCTAssertEqual(ChartAxis.anchor(for: start.addingTimeInterval(990), label: "Oct 7", in: window), .trailing)
        XCTAssertEqual(ChartAxis.anchor(for: start.addingTimeInterval(990), label: "", in: window), .center,
                       "a label narrow enough to fit stays centred")
    }

    /// Labels that would overlap their neighbour go, oldest first; the newest always stays.
    func testOverlappingLabelsAreDroppedButNeverTheNewest() {
        let start = Date(timeIntervalSince1970: 0)
        let window = start...start.addingTimeInterval(1000)
        let marks = [0, 20, 500, 990].map { start.addingTimeInterval(Double($0)) }
        let kept = ChartAxis.droppingOverlaps(marks, labels: ["Oct 2025", "Nov", "Feb", "Oct"],
                                              anchors: [.leading, .leading, .leading, .trailing], in: window)
        XCTAssertEqual(kept, [1, 2, 3])
    }
}
#endif
