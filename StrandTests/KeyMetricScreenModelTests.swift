import XCTest
import StrandAnalytics
@testable import Strand

/// The key-metric screen's period control, shaded ranges, 24-hour windows, words and the context it hands Sana
/// (`KeyMetricScreenModel.swift`, `KeyMetricHandoff.swift`).
final class KeyMetricScreenModelTests: XCTestCase {

    typealias PC = PhysiologyContext
    private let tz = "America/Los_Angeles"

    private func reading(_ day: String, _ value: Double) -> KeyMetricHistory.Reading {
        KeyMetricHistory.Reading(day: day, date: PhysiologyContextDates.date(day)!, value: value)
    }

    /// `count` consecutive nights ending on `last`, valued by `value(index)`.
    private func nights(_ count: Int, through last: String = "2026-10-07",
                        value: (Int) -> Double = { 50 + Double($0 % 10) }) -> [KeyMetricHistory.Reading] {
        (0..<count).map { i in
            let day = PhysiologyContextDates.key(last, minusDays: count - 1 - i)!
            return reading(day, value(i))
        }
    }

    // MARK: - Periods

    func testHRVAndStableAwakeHeartRateOfferTheTwentyFourHourView() {
        XCTAssertEqual(KeyMetricPeriods.periods(for: .hrvRmssd), [.hours24, .range(.week), .range(.month), .range(.year)])
        XCTAssertEqual(KeyMetricPeriods.periods(for: .hrvSdnn).first, .hours24)
        // The context history serves 120 days, so stable awake heart rate stops at 90.
        XCTAssertEqual(KeyMetricPeriods.periods(for: .heartRate),
                       [.hours24, .range(.week), .range(.month), .range(.quarter)])
    }

    func testNightlyAndDailyValuesKeepToRanges() {
        for metric in [MetricInsightMetric.restingHeartRate, .skinTemp, .respRate, .spo2, .steps, .calories] {
            XCTAssertEqual(KeyMetricPeriods.periods(for: metric),
                           [.range(.week), .range(.month), .range(.quarter), .range(.year)], "\(metric)")
            XCTAssertNil(metric.windowMetric)
        }
    }

    func testPeriodLabelsSpeakOfNightsOrDays() {
        XCTAssertEqual(KeyMetricPeriods.label(.hours24, .night), "24 hours")
        XCTAssertEqual(KeyMetricPeriods.label(.range(.week), .night), "7 nights")
        XCTAssertEqual(KeyMetricPeriods.label(.range(.month), .day), "30 days")
        XCTAssertEqual(KeyMetricPeriods.label(.range(.year), .night), "1 year")
    }

    func testALockedLongerRangeShowsTheLongestUnlockedOneBelowIt() {
        let periods = KeyMetricPeriods.periods(for: .restingHeartRate)
        // 40 days of history: 90 nights unlocks (more than 30), a year does not (needs more than 180).
        let unlocked: (KeyMetricPeriod) -> Bool = { KeyMetricPeriods.isUnlocked($0, spanDays: 40, hasHistory: true) }
        XCTAssertTrue(unlocked(.range(.quarter)))
        XCTAssertFalse(unlocked(.range(.year)))
        XCTAssertEqual(KeyMetricPeriods.coerced(.range(.year), among: periods, isUnlocked: unlocked), .range(.quarter))
        XCTAssertEqual(KeyMetricPeriods.coerced(.range(.month), among: periods, isUnlocked: unlocked), .range(.month))
        XCTAssertTrue(KeyMetricPeriods.isUnlocked(.hours24, spanDays: 0, hasHistory: false))
    }

    // MARK: - Shaded ranges

    func testTheMiddle80IsThe10thTo90thPercentileAndNeedsSevenValues() throws {
        XCTAssertNil(KeyMetricBands.middle80([1, 2, 3, 4, 5, 6]))
        let r = try XCTUnwrap(KeyMetricBands.middle80((1...11).map(Double.init)))
        XCTAssertEqual(r.low, 2, accuracy: 1e-9)
        XCTAssertEqual(r.high, 10, accuracy: 1e-9)
    }

    func testTheRecentRangeUsesThePrevious30PeriodsNeverTheLatest() throws {
        // 40 nights at 50, then one outlier at 90: the range must not move for the outlier itself.
        var all = nights(40, through: "2026-10-06", value: { _ in 50 })
        all.append(reading("2026-10-07", 90))
        let window = Array(all.suffix(7))
        let band = try XCTUnwrap(KeyMetricBands.recent(all, window: window))
        XCTAssertEqual(band.kind, .recent)
        XCTAssertEqual(band.latest?.low, 50)
        XCTAssertEqual(band.latest?.high, 50)
        // Drawn flat from the window's first to its last reading.
        XCTAssertEqual(band.spans.map(\.day), ["2026-10-01", "2026-10-07"])
        XCTAssertEqual(KeyMetricBands.placement(90, day: "2026-10-07", band: band, verdicts: [:]), .above)
    }

    func testNoRecentRangeWithoutSevenEarlierPeriods() {
        let all = nights(7)
        XCTAssertNil(KeyMetricBands.recent(all, window: all), "six earlier nights are not enough")
    }

    private func verdict(_ state: LBVitalVerdict.State, _ lo: Double?, _ hi: Double?, value: Double? = 50) -> LBVitalVerdict {
        LBVitalVerdict(state: state, value: value, bandLo: lo, bandHi: hi, fromWeek: false)
    }

    func testTheUsualBandFollowsEachDaysVerdictAndSkipsLearningDays() throws {
        let verdicts: [String: LBVitalVerdict] = [
            "2026-10-05": verdict(.learning, nil, nil),
            "2026-10-06": verdict(.inRange, 44, 60),
            "2026-10-07": verdict(.off, 46, 61, value: 70),
        ]
        let band = try XCTUnwrap(KeyMetricBands.usual(verdicts))
        XCTAssertEqual(band.kind, .usual)
        XCTAssertEqual(band.spans.map(\.day), ["2026-10-06", "2026-10-07"])
        XCTAssertEqual(KeyMetricBands.placement(70, day: "2026-10-07", band: band, verdicts: verdicts), .above)
        XCTAssertEqual(KeyMetricBands.placement(40, day: "2026-10-06", band: band, verdicts: verdicts), .below)
        XCTAssertEqual(KeyMetricBands.placement(50, day: "2026-10-05", band: band, verdicts: verdicts), .learning)
        XCTAssertEqual(KeyMetricBands.placement(50, day: "2026-09-01", band: band, verdicts: verdicts), .none)
        XCTAssertNil(KeyMetricBands.usual(["2026-10-05": verdict(.learning, nil, nil)]))
        // A band reaching below zero (thin step history) is drawn from zero.
        let steps = try XCTUnwrap(KeyMetricBands.usual(["2026-10-07": verdict(.inRange, -3_345, 25_189, value: 8_000)]))
        XCTAssertEqual(steps.latest?.low, 0)
        XCTAssertEqual(steps.latest?.high, 25_189)
    }

    func testAxisNumbersFitTheirLabel() {
        XCTAssertEqual(KeyMetricDotChart.axisNumber(40_000), "40k")
        XCTAssertEqual(KeyMetricDotChart.axisNumber(2_500), "2.5k")
        XCTAssertEqual(KeyMetricDotChart.axisNumber(75), "75")
        XCTAssertEqual(KeyMetricDotChart.axisNumber(94.6), "94.6")
    }

    func testOnlyTheMetricsWithAUsualGetALayer1Band() {
        XCTAssertEqual(MetricInsightMetric.restingHeartRate.usualSeries, .sleepRHR)
        XCTAssertEqual(MetricInsightMetric.hrvRmssd.usualSeries, .sleepHRVLn)
        XCTAssertEqual(MetricInsightMetric.skinTemp.usualSeries, .sleepTemp)
        XCTAssertEqual(MetricInsightMetric.respRate.usualSeries, .sleepResp)
        XCTAssertEqual(MetricInsightMetric.steps.usualSeries, .wakingSteps)
        // docs/METRIC_INSIGHTS.md: no usual in the app for these; they compare with recent periods.
        for metric in [MetricInsightMetric.hrvSdnn, .spo2, .heartRate, .calories] { XCTAssertNil(metric.usualSeries) }
    }

    func testALongWindowComputesAboutFortyFiveUsualsIncludingTheLatest() {
        let year = nights(365)
        let days = KeyMetricBands.usualDays(year)
        XCTAssertLessThanOrEqual(days.count, KeyMetricBands.maxEvaluations + 1)
        XCTAssertGreaterThanOrEqual(days.count, KeyMetricBands.maxEvaluations - 5)
        XCTAssertEqual(days.last, year.last?.day)
        XCTAssertEqual(days, days.sorted())
        XCTAssertEqual(KeyMetricBands.usualDays(nights(30)).count, 30)
    }

    func testTheMedianOfAnEvenCountIsTheMiddleTwosMean() {
        XCTAssertEqual(KeyMetricSummary.median([3, 1, 2]), 2)
        XCTAssertEqual(KeyMetricSummary.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(KeyMetricSummary.median([]))
    }

    // MARK: - 24-hour windows

    private func envelope(_ start: Int, value: Double? = 60, metric: PC.MetricKind = .hrvRmssd,
                          sleep: PC.SleepWakeState = .awake, stable: Bool = false, label: String = "still",
                          validity: PC.ValidityState = .valid, nightly: Bool = false) -> PC.MeasurementEnvelope {
        let support = PC.Interval(start, start + 300)
        let method = nightly
            ? PC.MethodRef(id: "snapshot.\(metric.rawValue).night", algorithmVersion: "t", aggregation: .session,
                           windowS: 300, units: "ms")
            : PC.MethodRef(id: "series.\(metric.rawValue).5min", algorithmVersion: "t", aggregation: .window,
                           windowS: 300, units: "ms")
        let composition = PC.ActivityComposition(
            interval: support, intervalS: 300, source: .strapMotion, heartRateDependent: false,
            labels: [PC.LabelShare(label: label, seconds: 300, share: 1)], unknownS: 0, uncoveredS: 0, transitions: 0,
            mixed: false, dominantLabel: label, resolvedOverlapS: 0, reasons: [])
        let verdicts = stable
            ? [PC.EligibilityVerdict(comparison: .stableAwakeRest, state: .eligible, reasons: [], policyVersion: "t")]
            : []
        return PC.MeasurementEnvelope(
            id: PC.MeasurementEnvelope.makeId(method: method, support: support), metric: metric, method: method,
            source: PC.SourceRef(product: nightly ? .scoringSnapshot : .metricSeries, key: "k@\(start)",
                                 inputRevision: 1, resultRevision: 1),
            value: value, support: support, displayBucket: nil, localTime: PC.localTime(at: start, timezoneId: tz),
            validity: PC.SignalValidity(state: validity, reasons: [], coverage: 0.82, observedS: 300),
            regimeKey: "r1", activity: composition, decoderActivity: nil,
            preceding: PC.PrecedingHistory(lookback: PC.Interval(start - 1800, start), source: .strapMotion,
                                           stillRunS: 600, stillRunEndedBy: nil, secondsSinceSupportedActivity: nil,
                                           lastSupportedActivityLabel: nil, coveredS: 1800, transitions: 0),
            sleepWear: PC.SleepWearContext(sleepState: sleep, sleepEvidence: [], sleepDependsOnHeartSignals: false,
                                           wearState: .worn, wearEvidence: [], reasons: []),
            history: PC.HistoryContext(
                wake: PC.WakeReference(secondsSinceWake: nil, wakeAt: nil, referenceEpisodeId: nil, referenceKind: .mainSleep,
                                       reasons: []),
                recentBouts: [], exertion: [], exposures: [], exposureCoverage: []),
            eligibility: verdicts, comparisons: [], finality: .final)
    }

    func testAWindowsContextIsSleepThenStableAwakeThenMovement() {
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, sleep: .asleep, stable: true)), .sleep)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, stable: true)), .stableAwake)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "walking")), .moving)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "sitting")), .awake)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, sleep: .mixed)), .mixed)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, sleep: .unknown)), .unknown)
    }

    func testOnlyAcceptedWindowEstimatesInsideTheSpanAreReadings() {
        let interval = PC.Interval(1_000, 10_000)
        let doc = [
            envelope(1_000, sleep: .asleep),
            envelope(1_300, value: nil),                    // no estimate: a gap
            envelope(1_600, validity: .invalid),            // failed the quality checks: a gap
            envelope(1_900, validity: .degraded),           // usable with limits: kept
            envelope(2_200, metric: .heartRate),            // another metric
            envelope(2_500, nightly: true),                 // a nightly value, not a window
            envelope(20_000),                               // outside the span
        ]
        let document = PhysiologyContextDocument(
            full: nil, header: nil, status: nil, statusReasons: [], availability: [], regimes: nil, envelopes: doc,
            sleep: nil, bouts: [], exertion: [], exposures: nil, dailyValues: [], comparisons: [], episodes: [],
            dependence: [], pulseEpisodes: nil, undecodedElements: 0, undecodedMembers: [])
        let envelopes = KeyMetricWindows.envelopes([document, document], metric: .hrvRmssd, in: interval)
        XCTAssertEqual(envelopes.map(\.support.start), [1_000, 1_300, 1_600, 1_900], "one per window, in order")
        let readings = KeyMetricWindows.readings(envelopes)
        XCTAssertEqual(readings.map(\.start), [1_000, 1_900])
        XCTAssertEqual(readings.first?.context, .sleep)
        XCTAssertEqual(readings.first?.coverage, 0.82)
        // The lane keeps every window's context (rejected ones too) and joins neighbours that share one.
        let lane = KeyMetricWindows.lane(envelopes)
        XCTAssertEqual(lane.map(\.context), [.sleep, .awake])
        XCTAssertEqual(lane.last.map { [$0.start, $0.end] }, [1_300, 2_200])
    }

    func testANightsTwentyFourHoursRunNoonToNoonInTheDocumentsZone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: tz))
        let span = try XCTUnwrap(KeyMetricWindows.span(day: "2026-10-07", period: .night, timeZone: zone))
        XCTAssertEqual(span.days, ["2026-10-06", "2026-10-07"])
        // Noon PDT (UTC-7) on Oct 6 to noon on Oct 7.
        XCTAssertEqual(span.interval.start, 1_791_313_200)
        XCTAssertEqual(span.interval.end - span.interval.start, 86_400)
        let day = try XCTUnwrap(KeyMetricWindows.span(day: "2026-10-07", period: .day, timeZone: zone))
        XCTAssertEqual(day.days, ["2026-10-07"])
        XCTAssertEqual(day.interval.start, 1_791_356_400, "local midnight")
    }

    func testTheSleepChipZoomsToTheSleepWindows() {
        let interval = PC.Interval(0, 86_400)
        let readings = KeyMetricWindows.readings([envelope(40_000, sleep: .asleep), envelope(60_000, sleep: .asleep),
                                                  envelope(70_000)])
        let sleep = KeyMetricWindows.domain(interval: interval, readings: readings, filter: .sleep)
        XCTAssertEqual(sleep.lowerBound.timeIntervalSince1970, 38_200)
        XCTAssertEqual(sleep.upperBound.timeIntervalSince1970, 62_100)
        let all = KeyMetricWindows.domain(interval: interval, readings: readings, filter: .all)
        XCTAssertEqual(all.upperBound.timeIntervalSince1970, 86_400)
    }

    // MARK: - Words

    func testTheScreensOwnCopyPassesBothWordingGuards() {
        for text in KeyMetricScreenCopy.allFixedText + [KeyMetricHandoff.prompt(metricName: "Resting heart rate"),
                                                        KeyMetricHandoff.memory(metricName: "heart rate variability (HRV)")] {
            XCTAssertNil(PhysiologyContextWording.containsForbiddenTerm(text), text)
            XCTAssertNil(MetricInsightWordingGuard.violation(in: text), text)
            XCTAssertFalse(text.isEmpty)
        }
        // Metrics without a usual never speak of one.
        for period in MetricInsightPeriod.allCases {
            XCTAssertFalse(KeyMetricScreenCopy.recentRange("1–2", period).localizedCaseInsensitiveContains("usual"))
            XCTAssertFalse(KeyMetricScreenCopy.shadedRecent(period).localizedCaseInsensitiveContains("usual"))
        }
        XCTAssertFalse(KeyMetricScreenCopy.placement(.above, kind: .recent)!.localizedCaseInsensitiveContains("usual"))
    }

    // MARK: - Sana

    func testTheHandoffIsAPlainQuestionAMemoryWithoutReadingsAndTheScreensContext() {
        XCTAssertEqual(KeyMetricHandoff.prompt(metricName: "Resting heart rate"),
                       "Help me understand my resting heart rate.")
        XCTAssertEqual(KeyMetricHandoff.prompt(metricName: "HRV"), "Help me understand my HRV.")
        let memory = KeyMetricHandoff.memory(metricName: "heart rate variability (HRV)")
        XCTAssertTrue(memory.contains("heart rate variability"))
        XCTAssertNil(memory.rangeOfCharacter(from: .decimalDigits), "a memory holds the interest, never a reading")

        var screen = KeyMetricHandoff.Screen(metricName: "Heart rate variability (RMSSD)", periodLabel: "30 nights")
        screen.headline = "52 ms"
        screen.headlineMeaning = "Median of 26 measured nights"
        screen.rangeLine = "Your usual range: 45–62 ms"
        screen.selection = "48 ms · Tue, Oct 6"
        screen.selectionMeaning = "Within your usual range"
        screen.recent = [("Oct 5", "55 ms"), ("Oct 6", "48 ms")]
        screen.explanationHeadline = "Your HRV sat in its usual range."
        screen.explanationSentences = ["Most nights were within your usual range."]
        let context = KeyMetricHandoff.context(screen)
        for needle in ["Heart rate variability (RMSSD) page, showing 30 nights", "Shown value: 52 ms (Median of 26",
                       "Your usual range: 45–62 ms.", "Selected reading: 48 ms · Tue, Oct 6 — Within your usual range.",
                       "Recent readings: Oct 5 55 ms; Oct 6 48 ms.", "Your HRV sat in its usual range.",
                       "not a safety range"] {
            XCTAssertTrue(context.contains(needle), "\(needle) in\n\(context)")
        }
    }

    func testTheHandoffContextIsCapped() {
        var screen = KeyMetricHandoff.Screen(metricName: "Steps", periodLabel: "1 year")
        screen.explanationHeadline = "Headline"
        screen.explanationSentences = Array(repeating: String(repeating: "word ", count: 60), count: 20)
        let context = KeyMetricHandoff.context(screen)
        XCTAssertLessThanOrEqual(context.count, KeyMetricHandoff.contextCap)
        XCTAssertTrue(context.hasPrefix("Screen: the Steps page, showing 1 year."))
        XCTAssertTrue(context.hasSuffix("…"))
    }
}
