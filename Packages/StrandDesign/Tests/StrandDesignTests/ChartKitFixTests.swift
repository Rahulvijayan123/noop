#if !os(watchOS)
import XCTest
@testable import StrandDesign

/// The kit review's fixes, pinned: the scrub selects the bar under the finger, a held step starts at the
/// window's edge, a day keeps its calendar day across time zones, summed partial bins are flagged, All bins
/// by its real span, fitted axes do not waste a third of the plot, short runs survive downsampling, stacked
/// bars can sum, range bars bin in public, jittered intraday samples do not break, and the hours axis stays on
/// round clock times through a clock change.
final class ChartKitFixTests: XCTestCase {

    private func calendar(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        cal.firstWeekday = firstWeekday
        cal.locale = Locale(identifier: "en_US")
        return cal
    }

    private func day(_ key: String, _ cal: Calendar) -> Date { ChartDay.date(forKey: key, calendar: cal)! }

    private func plain(_ labels: [String]) -> [String] {
        labels.map { $0.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
    }

    // MARK: Scrub snapping

    /// Marks sit in the middle of their day, so a finger on the right half of Monday's bar (18:00, nearer
    /// Tuesday's START than Monday's) still selects Monday.
    func testAFingerOnTheRightHalfOfABarSelectsThatBar() {
        let cal = calendar("America/Los_Angeles")
        let monday = day("2026-10-05", cal)
        let xs = (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }
        let evening = monday.addingTimeInterval(18 * 3600)
        XCTAssertEqual(ChartSelection.nearest(to: evening, in: xs, unit: .day, calendar: cal), monday)
        XCTAssertEqual(ChartSelection.nearest(to: evening, in: xs), xs[1], "the raw rule picks the next start")
        XCTAssertEqual(ChartSelection.nearest(to: monday.addingTimeInterval(-3600), in: xs, unit: .day, calendar: cal), monday,
                       "before the first bar: the nearest middle")
    }

    func testWeeklyAndMonthlyBinsSelectTheBinUnderTheFinger() {
        let cal = calendar("America/Los_Angeles")
        let weeks = ["2026-09-21", "2026-09-28", "2026-10-05"].map { day($0, cal) }
        let saturdayNoon = day("2026-10-03", cal).addingTimeInterval(12 * 3600)
        XCTAssertEqual(ChartSelection.nearest(to: saturdayNoon, in: weeks, unit: .weekOfYear, calendar: cal), weeks[1])
        let months = ["2026-06-01", "2026-07-01", "2026-08-01"].map { day($0, cal) }
        let lateJune = day("2026-06-30", cal).addingTimeInterval(20 * 3600)
        XCTAssertEqual(ChartSelection.nearest(to: lateJune, in: months, unit: .month, calendar: cal), months[0])
    }

    /// Over a missing day the nearest bar's middle wins, not the nearest start.
    func testOverAGapTheNearestMiddleWins() {
        let cal = calendar("UTC")
        let xs = [day("2026-10-01", cal), day("2026-10-05", cal)]
        let gap = day("2026-10-03", cal).addingTimeInterval(13 * 3600)   // 49 h after Oct 1's middle, 47 h before Oct 5's
        XCTAssertEqual(ChartSelection.nearest(to: gap, in: xs, unit: .day, calendar: cal), xs[1])
        XCTAssertNil(ChartSelection.nearest(to: gap, in: [], unit: .day, calendar: cal))
        XCTAssertEqual(ChartSelection.nearest(to: gap, in: xs, unit: nil, calendar: cal), ChartSelection.nearest(to: gap, in: xs))
    }

    // MARK: Step line held into the window

    func testAReadingBeforeTheWindowIsHeldAcrossIt() {
        let cal = calendar("America/Los_Angeles")
        let now = day("2026-10-07", cal).addingTimeInterval(15 * 3600)
        let window = ChartAxis.window(.week, now: now, firstDataDay: nil, calendar: cal)
        let reading = DailyPoint(key: "2026-09-24", value: 44, calendar: cal)!   // 13 days ago, 7 before the window
        let layout = StepLineChart.layout([reading], window: window, cadence: .sparse(maxGapDays: 42),
                                          holdsLatest: true, calendar: cal)
        XCTAssertTrue(layout.windowed.isEmpty)
        XCTAssertEqual(layout.steps.map(\.value), [44, 44], "a flat line across the window")
        XCTAssertEqual(layout.steps.first?.x, window.lowerBound, "from the window's leading edge")
        XCTAssertEqual(layout.steps.last?.day, day("2026-10-07", cal), "held to today")
    }

    func testAStaleReadingBeforeTheWindowIsNotDrawn() {
        let cal = calendar("America/Los_Angeles")
        let now = day("2026-10-07", cal).addingTimeInterval(15 * 3600)
        let window = ChartAxis.window(.month, now: now, firstDataDay: nil, calendar: cal)
        let reading = DailyPoint(key: "2026-08-18", value: 44, calendar: cal)!   // 50 days ago
        let layout = StepLineChart.layout([reading], window: window, cadence: .sparse(maxGapDays: 42),
                                          holdsLatest: true, calendar: cal)
        XCTAssertTrue(layout.steps.isEmpty)
    }

    /// A weekly estimate on day 3 of the window: days 1 and 2 hold the previous estimate.
    func testTheFirstDaysOfAWindowHoldThePreviousReading() {
        let cal = calendar("America/Los_Angeles")
        let now = day("2026-10-07", cal).addingTimeInterval(15 * 3600)
        let window = ChartAxis.window(.week, now: now, firstDataDay: nil, calendar: cal)   // Oct 1 ... Oct 7
        let points = [DailyPoint(key: "2026-09-26", value: 41, calendar: cal)!,
                      DailyPoint(key: "2026-10-03", value: 43, calendar: cal)!]
        let layout = StepLineChart.layout(points, window: window, cadence: .sparse(maxGapDays: 42),
                                          holdsLatest: true, calendar: cal)
        XCTAssertEqual(layout.steps.map(\.value), [41, 43, 43])
        XCTAssertEqual(layout.steps.first?.x, window.lowerBound)
        XCTAssertEqual(Set(layout.steps.map(\.run)).count, 1, "one joined step")
        XCTAssertEqual(layout.windowed.map(\.value), [43], "only the reading inside the window gets a point")
    }

    // MARK: Days across time zones, one value per day

    /// Points built in Los Angeles and kept while the wearer flies to Honolulu stay on their calendar days.
    func testAPointBuiltInOneZoneKeepsItsDayInAnother() {
        let la = calendar("America/Los_Angeles")
        let honolulu = calendar("Pacific/Honolulu")
        let point = DailyPoint(key: "2026-10-07", value: 62, calendar: la)!
        XCTAssertEqual(point.localDay(in: honolulu), day("2026-10-07", honolulu))
        XCTAssertEqual(point.localDay(in: la), day("2026-10-07", la))
        let bins = DailyBarChart.bin([point], by: .day, aggregation: .mean, calendar: honolulu)
        XCTAssertEqual(bins.map { ChartDay.key(for: $0.day, calendar: honolulu) }, ["2026-10-07"])
        let selected = day("2026-10-07", honolulu).addingTimeInterval(9 * 3600)
        XCTAssertEqual(ChartSelection.point(for: selected, in: [point], calendar: honolulu)?.value, 62)
        let bridged = DailyPoint(TrendPoint(date: point.day, value: 1), calendar: la)
        XCTAssertEqual(bridged.localDay(in: honolulu), day("2026-10-07", honolulu))
    }

    /// Any instant inside the day works, and two readings on one day become one mark.
    func testDaysAreNormalisedAndMerged() {
        let cal = calendar("America/Los_Angeles")
        let wake = day("2026-10-07", cal).addingTimeInterval(7 * 3600)
        let points = [DailyPoint(day: wake, value: 70), DailyPoint(day: wake.addingTimeInterval(9 * 3600), value: 72),
                      DailyPoint(day: day("2026-10-06", cal), value: 68)]
        let days = points.normalisedDays(cal)
        XCTAssertEqual(days.map(\.day), [day("2026-10-06", cal), day("2026-10-07", cal)])
        XCTAssertEqual(days.map(\.value), [68, 71])
        XCTAssertEqual(DailyPoint(day: wake, value: 1), DailyPoint(day: wake, value: 1), "the zone is not identity")
    }

    // MARK: Partial bins

    func testSummedBinsThatAreNotFullyCoveredArePartial() {
        let cal = calendar("America/Los_Angeles")
        let now = day("2026-10-07", cal).addingTimeInterval(15 * 3600)   // a Wednesday
        let window = ChartAxis.window(.quarter, now: now, firstDataDay: nil, calendar: cal)
        // History from Monday Sep 7 to today: every week is covered but the current one, still running.
        let history = (0..<31).map { DailyPoint(day: cal.date(byAdding: .day, value: $0, to: day("2026-09-07", cal))!, value: 20) }
        XCTAssertEqual(DailyBarChart.partialBins(history, by: .weekOfYear, window: window, calendar: cal),
                       [day("2026-10-05", cal)])
        // History that began on a Thursday: that week is partial too.
        let started = Array(history.dropFirst(3))
        XCTAssertEqual(DailyBarChart.partialBins(started, by: .weekOfYear, window: window, calendar: cal),
                       [day("2026-09-07", cal), day("2026-10-05", cal)])
        XCTAssertTrue(DailyBarChart.partialBins(history, by: .day, window: window, calendar: cal).isEmpty)
    }

    // MARK: All bins by its span

    func testAllBinsByTheSpanItCovers() {
        let cal = calendar("UTC")
        let now = day("2026-10-07", cal).addingTimeInterval(12 * 3600)
        func all(_ first: String) -> ClosedRange<Date> {
            ChartAxis.window(.all, now: now, firstDataDay: day(first, cal), calendar: cal)
        }
        XCTAssertEqual(ChartRange.all.totalsBin(for: all("2026-09-18"), calendar: cal), .day)
        XCTAssertEqual(ChartRange.all.totalsBin(for: all("2026-05-10"), calendar: cal), .weekOfYear)
        XCTAssertEqual(ChartRange.all.totalsBin(for: all("2025-01-01"), calendar: cal), .month)
        for range in ChartRange.allCases where range != .all {
            let window = ChartAxis.window(range, now: now, firstDataDay: nil, calendar: cal)
            XCTAssertEqual(range.totalsBin(for: window, calendar: cal), range.totalsBin, "\(range)")
        }
    }

    func testTheEffectiveRangeIsTheShownSegment() {
        let fills90 = { (range: ChartRange) in (range.days ?? 0) <= 90 }
        XCTAssertEqual(RangeControl.effectiveRange(.year, isAvailable: fills90), .quarter)
        XCTAssertEqual(RangeControl.effectiveRange(.month, isAvailable: fills90), .month)
        XCTAssertEqual(RangeControl.effectiveRange(.all, isAvailable: fills90), .all)
        XCTAssertEqual(RangeControl.effectiveRange(.month, isAvailable: { $0 == .week }), .week)
        XCTAssertEqual(RangeControl.effectiveRange(.half, options: [.week], isAvailable: { _ in false }), .half,
                       "nothing to show: the selection itself")
    }

    // MARK: Fitted domains

    func testAFittedAxisDoesNotWasteAThirdOfThePlot() {
        let hr = ChartDomain.fitted(minSpan: 30).resolve([45, 140])
        XCTAssertNotEqual(hr, 0...150)
        XCTAssertGreaterThanOrEqual(hr.lowerBound, 20)
        XCTAssertLessThanOrEqual(hr.upperBound, 160)
        XCTAssertEqual(hr, 25...150)
        let hrv = ChartDomain.fitted(minSpan: 20).resolve([56, 104])
        XCTAssertGreaterThanOrEqual(hrv.lowerBound, 50)
        XCTAssertLessThanOrEqual(hrv.upperBound - hrv.lowerBound, 80)
        let steps = ChartDomain.fitted(minSpan: 2_000, includeZero: true).resolve([4_200, 9_800, 10_000])
        XCTAssertEqual(steps.lowerBound, 0)
        XCTAssertLessThan(steps.upperBound, 15_000, "a 10,000 goal no longer gets a 15,000 axis")
        let layout = ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)).layout(for: [45, 140])
        XCTAssertEqual(layout.ticks.first, layout.domain.lowerBound)
        XCTAssertEqual(layout.ticks.last, layout.domain.upperBound)
        XCTAssertLessThanOrEqual(layout.ticks.count, 6)
    }

    func testTheFittingStepNeverPicksAHalfWayTickUnderTen() {
        // 95.35...101.15 could round to 95...102.5 by 2.5, printing 97.5 as "98".
        XCTAssertEqual(ChartTicks.fittingStep(low: 95.35, high: 101.15, count: 4), 2)
        XCTAssertNil(ChartTicks.fittingStep(low: 1, high: 1, count: 4))
    }

    // MARK: Downsampling by run

    /// A three-minute stretch between two off-wrist gaps on a 1-minute day keeps both its ends.
    func testAShortRunBetweenTwoGapsSurvivesDownsampling() {
        struct Sample { let time: Date; let value: Double; let run: String }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var samples: [Sample] = []
        for minute in 0..<1_440 where !(600..<640).contains(minute) && !(643..<700).contains(minute) {
            let run = minute < 600 ? "a" : (minute < 643 ? "b" : "c")
            samples.append(Sample(time: start.addingTimeInterval(Double(minute) * 60),
                                  value: 60 + 30 * sin(Double(minute) / 7), run: run))
        }
        let drawn = NaraRunDownsample.reduce(samples, run: \.run, date: \.time, value: \.value)
        XCTAssertLessThan(drawn.count, samples.count)
        XCTAssertEqual(drawn.filter { $0.run == "b" }.count, 3)
        for run in ["a", "c"] {
            let original = samples.filter { $0.run == run }
            let kept = drawn.filter { $0.run == run }
            XCTAssertEqual(kept.first?.time, original.first?.time, "run \(run) keeps its first reading")
            XCTAssertEqual(kept.last?.time, original.last?.time, "run \(run) keeps its last reading")
        }
        let short = Array(samples.prefix(100))
        XCTAssertEqual(NaraRunDownsample.reduce(short, run: \.run, date: \.time, value: \.value).count, 100)
    }

    // MARK: Stacked sums

    func testStackedBinsCanSumAndSameDayEntriesAdd() {
        let cal = calendar("America/Los_Angeles")
        let workouts = ["2026-10-05", "2026-10-07", "2026-10-09"].map {
            StackedBarChart.Day(day: day($0, cal), values: ["z4": 20, "z5": 10])
        }
        let summed = StackedBarChart.bin(workouts, by: .weekOfYear, aggregation: .sum, calendar: cal)
        XCTAssertEqual(summed.count, 1)
        XCTAssertEqual(summed.first?.values, ["z4": 60, "z5": 30], "the week's totals")
        let mean = StackedBarChart.bin(workouts, by: .weekOfYear, calendar: cal)
        XCTAssertEqual(mean.first?.values, ["z4": 20, "z5": 10], "the default stays the mean day")
        let twice = [StackedBarChart.Day(day: day("2026-10-05", cal).addingTimeInterval(8 * 3600), values: ["z4": 20]),
                     StackedBarChart.Day(day: day("2026-10-05", cal).addingTimeInterval(18 * 3600), values: ["z4": 15])]
        let daily = StackedBarChart.bin(twice, by: .day, calendar: cal)
        XCTAssertEqual(daily.map(\.day), [day("2026-10-05", cal)])
        XCTAssertEqual(daily.first?.values, ["z4": 35])
    }

    // MARK: Range bars

    func testRangeBarBinsArePublicAndMatchTheReadout() {
        let cal = calendar("America/Los_Angeles")
        func at(_ key: String, _ hour: Int, _ minute: Int = 0) -> Date {
            day(key, cal).addingTimeInterval(Double(hour) * 3600 + Double(minute) * 60)
        }
        let items = [RangeBarChart.Item(day: day("2026-10-06", cal), start: at("2026-10-05", 23), end: at("2026-10-06", 7)),
                     RangeBarChart.Item(day: day("2026-10-07", cal), start: at("2026-10-07", 0, 30), end: at("2026-10-07", 7, 30))]
        let weekly = RangeBarChart.bin(items, by: .weekOfYear, calendar: cal)
        XCTAssertEqual(weekly.count, 1)
        XCTAssertEqual(weekly.first?.start ?? 0, 5.75, accuracy: 1e-9, "the mean of 11 PM and 12:30 AM, across midnight")
        XCTAssertEqual(weekly.first?.end ?? 0, 13.25, accuracy: 1e-9)
        XCTAssertEqual(plain([RangeBarChart.clockLabel(offset: 5.75, calendar: cal)]), ["11:45 PM"])
        let readout = ReadoutContent.range(selection: day("2026-10-06", cal).addingTimeInterval(3600), in: weekly,
                                           bin: .weekOfYear, now: at("2026-10-07", 15), calendar: cal,
                                           locale: Locale(identifier: "en_US"))
        XCTAssertEqual(plain([readout.value ?? ""]), ["11:45 PM – 7:15 AM"])
        XCTAssertNil(readout.unit)
        let latest = ReadoutContent.range(selection: nil, in: RangeBarChart.bin(items, calendar: cal),
                                          now: at("2026-10-07", 15), calendar: cal)
        XCTAssertEqual(plain([latest.value ?? ""]), ["12:30 AM – 7:30 AM"])
    }

    /// A 5:30 PM bedtime is above the 6 PM anchor: the axis widens instead of letting the bar run off.
    func testTheClockAxisWidensAboveTheAnchor() {
        let cal = calendar("America/Los_Angeles")
        let axis = RangeBarChart.clockAxis(earliest: -0.5, latest: 13, anchorHour: 18, calendar: cal)
        XCTAssertGreaterThanOrEqual(axis.domain.upperBound, 0.5, "the negated top is above -(-0.5)")
        XCTAssertEqual(RangeBarChart.clockAxis(earliest: 5, latest: 13, anchorHour: 18, calendar: cal).domain.upperBound, -4,
                       "unchanged for a night after the anchor")
        let evening = day("2026-10-06", cal)
        let usual = RangeBarChart.typicalBand(evening.addingTimeInterval(17.5 * 3600)...evening.addingTimeInterval(18.5 * 3600),
                                              near: 0, anchorHour: 18, calendar: cal)
        XCTAssertEqual(usual.lowerBound, -0.5, accuracy: 1e-9)
        XCTAssertEqual(usual.upperBound, 0.5, accuracy: 1e-9)
    }

    // MARK: Intraday

    func testJitteredSamplesDoNotBreakButASkippedBucketDoes() {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let jittered = [0, 1, 2.6, 3.4, 4.1].map { base.addingTimeInterval($0) }
        let runs = ChartGaps.runs(jittered, series: Array(repeating: "hr", count: jittered.count), cadence: .buckets(seconds: 1))
        XCTAssertEqual(Set(runs).count, 1)
        let skipped = [0, 1, 2, 4, 5].map { base.addingTimeInterval($0) }
        let broken = ChartGaps.runs(skipped, series: Array(repeating: "hr", count: skipped.count), cadence: .buckets(seconds: 1))
        XCTAssertEqual(Set(broken).count, 2)
    }

    func testVoiceOverStepsThroughACoarseSetOfMoments() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let times = (0..<1_440).map { start.addingTimeInterval(Double($0) * 60) }
        let runs = times.indices.map { $0 < 700 ? "a" : "b" }
        let spoken = IntradayChart.spokenTimes(times, runs: runs, window: start...start.addingTimeInterval(86_400))
        XCTAssertLessThan(spoken.count, 60)
        XCTAssertTrue(spoken.contains(times[699]) && spoken.contains(times[700]), "every run's ends")
        XCTAssertEqual(spoken, spoken.sorted())
    }

    func testTheHoursAxisStaysOnRoundTimesThroughAClockChange() {
        let la = calendar("America/Los_Angeles")
        for key in ["2026-03-08", "2026-11-01"] {
            let start = day(key, la)
            let layout = ChartAxis.layout(start...la.dateInterval(of: .day, for: start)!.end, style: .hours, calendar: la)
            XCTAssertEqual(plain(layout.labels), ["12 AM", "6 AM", "12 PM", "6 PM"], key)
        }
        // Spring forward: 2 AM does not exist, so a 1-hour tick there is skipped (four elapsed hours end at 5 AM).
        let night = day("2026-03-08", la)
        let ticks = ChartAxis.wallClockTicks(start: night, end: night.addingTimeInterval(4 * 3600), calendar: la)
        XCTAssertEqual(ticks.map { la.component(.hour, from: $0) }, [0, 1, 3, 4, 5])
    }

    // MARK: Bands as printed

    func testABinnedMeanIsBandedAsPrinted() {
        XCTAssertEqual(DailyBarChart.displayed(33.6, format: ChartValueAxis.integer), 34)
        XCTAssertEqual(DailyBarChart.displayed(34, format: ChartValueAxis.integer), 34)
        XCTAssertEqual(DailyBarChart.displayed(1.26, format: ChartValueAxis.decimals(1)), 1.3, accuracy: 1e-9)
    }
}
#endif
