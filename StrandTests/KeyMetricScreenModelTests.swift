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
                          validity: PC.ValidityState = .valid, nightly: Bool = false,
                          reasons: [PC.ReasonCode] = [], wear: PC.WearEvidenceState = .worn,
                          decoder: String? = nil) -> PC.MeasurementEnvelope {
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
        let decoded = decoder.map {
            PC.ActivityComposition(interval: support, intervalS: 300, source: .decoderIntervals, heartRateDependent: true,
                                   labels: [PC.LabelShare(label: $0, seconds: 300, share: 1)], unknownS: 0, uncoveredS: 0,
                                   transitions: 0, mixed: false, dominantLabel: $0, resolvedOverlapS: 0, reasons: [])
        }
        let verdicts = stable
            ? [PC.EligibilityVerdict(comparison: .stableAwakeRest, state: .eligible, reasons: [], policyVersion: "t")]
            : []
        return PC.MeasurementEnvelope(
            id: PC.MeasurementEnvelope.makeId(method: method, support: support), metric: metric, method: method,
            source: PC.SourceRef(product: nightly ? .scoringSnapshot : .metricSeries, key: "k@\(start)",
                                 inputRevision: 1, resultRevision: 1),
            value: value, support: support, displayBucket: nil, localTime: PC.localTime(at: start, timezoneId: tz),
            validity: PC.SignalValidity(state: validity, reasons: reasons, coverage: 0.82, observedS: 300),
            regimeKey: "r1", activity: composition, decoderActivity: decoded,
            preceding: PC.PrecedingHistory(lookback: PC.Interval(start - 1800, start), source: .strapMotion,
                                           stillRunS: 600, stillRunEndedBy: nil, secondsSinceSupportedActivity: nil,
                                           lastSupportedActivityLabel: nil, coveredS: 1800, transitions: 0),
            sleepWear: PC.SleepWearContext(sleepState: sleep, sleepEvidence: [], sleepDependsOnHeartSignals: false,
                                           wearState: wear, wearEvidence: [], reasons: []),
            history: PC.HistoryContext(
                wake: PC.WakeReference(secondsSinceWake: nil, wakeAt: nil, referenceEpisodeId: nil, referenceKind: .mainSleep,
                                       reasons: []),
                recentBouts: [], exertion: [], exposures: [], exposureCoverage: []),
            eligibility: verdicts, comparisons: [], finality: .final)
    }

    func testAWindowsContextIsOffWristThenSleepThenWhatTheActivityLabelsSay() {
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, sleep: .asleep, wear: .notWorn)), .offWrist)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, sleep: .asleep, stable: true)), .sleep)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, sleep: .mixed)), .unclear)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "walking")), .moving)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "sitting_desk")), .sitting)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "standing")), .standing)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "lying_down")), .lyingDown)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "fidgeting")), .unclear)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "stationary")), .still)
        // Strap motion that only says "still" takes the decoder's posture; a moving label keeps its own.
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "stationary", decoder: "standing")), .standing)
        XCTAssertEqual(KeyMetricWindowContext.of(envelope(0, label: "walking", decoder: "sitting")), .moving)
        // Stable awake is the server's eligibility, separate from the context, and never while asleep.
        XCTAssertTrue(KeyMetricWindowContext.isStableAwake(envelope(0, stable: true)))
        XCTAssertFalse(KeyMetricWindowContext.isStableAwake(envelope(0, sleep: .asleep, stable: true)))
        XCTAssertTrue(KeyMetricWindowFilter.stableAwake.admits(envelope(0, stable: true, label: "sitting")))
        XCTAssertFalse(KeyMetricWindowFilter.stableAwake.admits(envelope(0, label: "sitting")))
    }

    func testTodayRunsFromLocalMidnightToNowWithNightsAsSpansAndBankedGaps() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let midnight = 1_791_529_200 // 2026-10-09 00:00 PDT
        let now = Date(timeIntervalSince1970: TimeInterval(midnight + 3_600 * 11))
        XCTAssertEqual(KeyMetricWindows.today("2026-10-09", timeZone: zone, now: now),
                       PC.Interval(midnight, midnight + 3_600 * 11))
        let interval = PC.Interval(midnight, midnight + 3_600 * 11)

        // A metric the server measures only per night shows that night across its sleep.
        var night = envelope(midnight + 9_000, nightly: true)
        night.support = PC.Interval(midnight + 9_000, midnight + 36_000)
        let sessions = KeyMetricWindows.sessions([document([night, envelope(midnight, validity: .invalid, nightly: true)])],
                                                 metric: .hrvRmssd, overlapping: interval)
        XCTAssertEqual(sessions.map { [$0.start, $0.end] }, [[midnight + 9_000, midnight + 36_000]])
        XCTAssertTrue(sessions[0].isSpan)

        // Banked readings take the lane's context; a stretch without them is unrecorded, or off the wrist when the
        // lane says so, and blood oxygen's gaps stay inside sleep.
        let lane = [KeyMetricContextSpan(start: midnight, end: midnight + 7_200, context: .sleep),
                    KeyMetricContextSpan(start: midnight + 7_200, end: midnight + 14_400, context: .offWrist),
                    KeyMetricContextSpan(start: midnight + 14_400, end: midnight + 39_600, context: .sitting)]
        let points = [(ts: midnight, value: 34.1), (ts: midnight + 300, value: 34.2), (ts: midnight + 15_000, value: 33.0)]
        let banked = KeyMetricWindows.banked(points, seconds: 300, lane: lane)
        XCTAssertEqual(banked.map(\.context), [.sleep, .sleep, .sitting])
        let gaps = KeyMetricWindows.bankedGaps(banked, interval: interval, lane: lane, now: now)
        XCTAssertEqual(gaps.map { [$0.startS, $0.endS] }, [[midnight + 600, midnight + 15_000],
                                                          [midnight + 15_300, midnight + 39_600]])
        XCTAssertEqual(gaps[0].words, "the strap was off your wrist")
        XCTAssertEqual(gaps[1].cause, KeyMetricGap.Cause.unrecorded)
        let sleepOnly = KeyMetricWindows.bankedGaps(banked, interval: interval, lane: lane, within: [.sleep], now: now)
        XCTAssertEqual(sleepOnly.map { [$0.startS, $0.endS] }, [[midnight + 600, midnight + 7_200]])
    }

    func testARollingWindowSitsAtItsDisplayBucket() {
        var rolling = envelope(1_000, metric: .restingHeartRate)
        rolling.method = PC.MethodRef(id: "series.resting_hr.60min_min5", algorithmVersion: "t",
                                      aggregation: .minimumOfBins, windowS: 3_600, units: "bpm")
        rolling.support = PC.Interval(0, 3_600)
        rolling.displayBucket = PC.Interval(3_300, 3_600)
        let envelopes = KeyMetricWindows.envelopes([document([rolling])], metric: .restingHeartRate,
                                                   in: PC.Interval(0, 86_400))
        XCTAssertEqual(KeyMetricWindows.readings(envelopes).map { [$0.start, $0.end] }, [[3_300, 3_600]])
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
        XCTAssertEqual(lane.map(\.context), [.sleep, .still])
        XCTAssertEqual(lane.last.map { [$0.start, $0.end] }, [1_300, 2_200])
    }

    private func document(_ envelopes: [PC.MeasurementEnvelope]) -> PhysiologyContextDocument {
        PhysiologyContextDocument(
            full: nil, header: nil, status: nil, statusReasons: [], availability: [], regimes: nil, envelopes: envelopes,
            sleep: nil, bouts: [], exertion: [], exposures: nil, dailyValues: [], comparisons: [], episodes: [],
            dependence: [], pulseEpisodes: nil, undecodedElements: 0, undecodedMembers: [])
    }

    func testGapsCarryTheServersReasonAndUnrecordedTimeButNeverAFilteredReading() {
        let interval = PC.Interval(0, 10_000)
        let envelopes = [
            envelope(0),
            envelope(300, validity: .invalid, reasons: ["motion_contaminated"]),
            envelope(600, validity: .invalid, reasons: ["motion_contaminated"]),
            envelope(900, validity: .missing),
            envelope(1_200, sleep: .asleep),                 // filtered out by the stable awake chip: not a gap
            envelope(3_000, sleep: .asleep, validity: .invalid, reasons: ["rr_under_covered"]),
            envelope(3_300),
        ]
        let gaps = KeyMetricWindows.gaps(envelopes, interval: interval, filter: .all,
                                         now: Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(gaps.map { [$0.startS, $0.endS] }, [[300, 900], [900, 1_200], [1_500, 3_000], [3_000, 3_300],
                                                            [3_600, 5_000]])
        XCTAssertEqual(gaps.first?.words, "movement affected the signal", "neighbours with one reason are joined")
        XCTAssertEqual(gaps[1].cause, KeyMetricGap.Cause.noSignal)
        XCTAssertEqual(gaps[2].cause, KeyMetricGap.Cause.unrecorded)
        XCTAssertEqual(gaps.last?.endS, 5_000, "never past now")
        // The stable awake chip leaves out the rejected sleep window but keeps unrecorded time.
        let awake = KeyMetricWindows.gaps(envelopes, interval: interval, filter: .stableAwake,
                                          now: Date(timeIntervalSince1970: 5_000))
        XCTAssertFalse(awake.contains { $0.startS == 3_000 })
        XCTAssertTrue(awake.contains { $0.cause == KeyMetricGap.Cause.unrecorded && $0.startS == 1_500 })

        let note = KeyMetricGap.note(gaps, in: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(note, "Gaps: movement affected the signal (10 min); no signal was recorded (5 min). "
                           + "Nothing was recorded for 48 min.")
        XCTAssertNil(KeyMetricGap.note([], in: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 5_000)))
    }

    func testAMissingNightIsExplainedOnlyWhenTheServerRejectedEveryNightlyValue() {
        let rejected = envelope(0, validity: .invalid, nightly: true, reasons: ["excess_rejected_beats"])
        XCTAssertEqual(KeyMetricWindows.nightlyGapReason([document([rejected])], metric: .hrvRmssd),
                       "too many beats were rejected")
        XCTAssertNil(KeyMetricWindows.nightlyGapReason([document([rejected, envelope(400, nightly: true)])],
                                                       metric: .hrvRmssd), "an accepted night needs no reason")
        XCTAssertNil(KeyMetricWindows.nightlyGapReason([document([envelope(0, validity: .unverified, nightly: true)])],
                                                       metric: .hrvRmssd), "unverified is not a reason for a gap")
        XCTAssertNil(KeyMetricWindows.nightlyGapReason([document([])], metric: .hrvRmssd), "no envelope, no guess")
    }

    func testMissingDaysAreTheDaysInTheRangeWithoutAReading() throws {
        let readings = KeyMetricHistory.measured([("2026-10-01", 50), ("2026-10-03", 52)])
        let start = try XCTUnwrap(PhysiologyContextDates.date("2026-10-01"))
        let end = try XCTUnwrap(PhysiologyContextDates.date("2026-10-04"))
        let gaps = KeyMetricHistory.missingDays(readings, domain: start...end)
        XCTAssertEqual(gaps.map(\.day), ["2026-10-02", "2026-10-04"])
        XCTAssertEqual(gaps.first.map { $0.endS - $0.startS }, 86_400)
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
        }
        for metric in MetricInsightMetric.allCases where metric.usualSeries == nil {
            XCTAssertFalse(KeyMetricScreenCopy.methodSummary([metric]).localizedCaseInsensitiveContains("usual"),
                           metric.rawValue)
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
