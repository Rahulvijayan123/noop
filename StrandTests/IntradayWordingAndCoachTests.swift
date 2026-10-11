import StrandAnalytics
import XCTest
@testable import Strand

/// The two places that used to describe HRV as a once-a-night value: the daily-history caption on a metric
/// page, and what the coach is told it can fetch.
final class IntradayWordingAndCoachTests: XCTestCase {

    private let los = TimeZone(identifier: "America/Los_Angeles")!
    private let dayStart = 1_790_838_000      // 2026-10-01 00:00 America/Los_Angeles

    func testDailyHistoryCaptionCountsDaysAndNeverSaysSparse() {
        XCTAssertEqual(DailyHistoryWording.caption(days: 2, rangeName: "30D", widened: false), "2 days · 30D")
        XCTAssertEqual(DailyHistoryWording.caption(days: 1, rangeName: "30D", widened: false), "1 day · 30D")
        let widened = DailyHistoryWording.caption(days: 2, rangeName: "ALL", widened: true)
        XCTAssertEqual(widened, "2 days · showing ALL")
        XCTAssertFalse(widened.lowercased().contains("sparse"))
        XCTAssertFalse(widened.lowercased().contains("reading"))
    }

    @MainActor
    func testCoachAlwaysHasTheIntradayTool() {
        for question in ["plot my hrv", "show my last workout", "what should I eat", "how has my HRV moved today"] {
            let names = Set(CoachToolExecutor.definitions(for: question)
                .compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            XCTAssertTrue(names.contains("get_intraday_series"), question)
        }
        XCTAssertTrue(CoachVisualEvidence.dataTools.contains("get_intraday_series"))
    }

    func testCoachPromptTellsTheModelHrvIsNotOncePerNight() {
        let prompt = CoachPrompt.persona + CoachPrompt.toolHint
        XCTAssertTrue(prompt.contains("get_intraday_series"))
        XCTAssertTrue(prompt.contains("NEVER say the device logs one HRV value per night"))
    }

    func testMetricNamesTheModelMightUse() {
        XCTAssertEqual(CoachIntraday.metric(named: "hrv"), .hrv)
        XCTAssertEqual(CoachIntraday.metric(named: "HRV_RMSSD_MS"), .hrv)
        XCTAssertEqual(CoachIntraday.metric(named: "resting heart rate"), .restingHeartRate)
        XCTAssertEqual(CoachIntraday.metric(named: "respiration"), .respiratoryRate)
        XCTAssertEqual(CoachIntraday.metric(named: "active_calories"), .calories)
        XCTAssertNil(CoachIntraday.metric(named: "spo2"))
    }

    func testHrvDescriptionCarriesEveryReadingAsHourlyMeansAndTheNewestBuckets() {
        let start = dayStart + 6 * 3_600
        let points = (0..<24).map { i in
            IntradaySeriesPoint(start: start + i * 300, value: 40 + Double(i), samples: 80, coverage: 1, motion: 0)
        }
        let window = IntradaySeriesWindow(from: start, to: start + 24 * 300, metrics: [.hrv: points])
        let now = Date(timeIntervalSince1970: TimeInterval(start + 24 * 300 + 60))
        let text = CoachIntraday.describe(window: window, metric: .hrv, timeZone: los, now: now)

        XCTAssertTrue(text.contains("24 readings of 5 minutes each"))
        XCTAssertTrue(text.contains("recomputed about every 5 minutes"))
        XCTAssertTrue(text.contains("Latest 63 ms at 07:55"))
        XCTAssertTrue(text.contains("min 40, mean 52, max 63 ms"))
        XCTAssertTrue(text.contains("Thu Oct 1 06:00: 46 (12)"))
        XCTAssertTrue(text.contains("Thu Oct 1 07:00: 58 (12)"))
        XCTAssertTrue(text.contains("  07:55: 63"))
        XCTAssertFalse(text.lowercased().contains("once"))
    }

    func testAdditiveMetricsReportTotalsNotMeans() {
        let start = dayStart
        let points = [
            IntradaySeriesPoint(start: start, value: 10, samples: 300, coverage: 1, motion: nil),
            IntradaySeriesPoint(start: start + 300, value: 25, samples: 300, coverage: 1, motion: nil),
        ]
        let window = IntradaySeriesWindow(from: start, to: start + 3_600, metrics: [.steps: points])
        let text = CoachIntraday.describe(window: window, metric: .steps, timeZone: los,
                                          now: Date(timeIntervalSince1970: TimeInterval(start + 700)))
        XCTAssertTrue(text.contains("Total in window: 35 steps"))
        XCTAssertTrue(text.contains("By hour (total"))
        XCTAssertTrue(text.contains("Thu Oct 1 00:00: 35 (2)"))
    }

    func testMinuteBucketsAreDescribedAsMinuteBuckets() {
        let points = (0..<30).map { i in
            IntradaySeriesPoint(start: dayStart + i * 60, value: 14 + Double(i % 3), samples: 20, coverage: 0.6, motion: 0)
        }
        let window = IntradaySeriesWindow(from: dayStart, to: dayStart + 3_600, metricBucketSeconds: [.respiratoryRate: 60],
                                          metrics: [.respiratoryRate: points])
        let text = CoachIntraday.describe(window: window, metric: .respiratoryRate, timeZone: los,
                                          now: Date(timeIntervalSince1970: TimeInterval(dayStart + 30 * 60 + 90)))
        XCTAssertTrue(text.contains("30 readings of 1 minute each"))
        XCTAssertTrue(text.contains("each reading covers a 1-minute bucket"))
        XCTAssertTrue(text.contains("(ends just now)"), "the newest bucket ended 30 s ago: \(text)")
    }

    func testAnEmptyWindowSaysNoValidReadingNotOncePerDay() {
        let window = IntradaySeriesWindow(from: dayStart, to: dayStart + 3_600, metrics: [.hrv: []])
        let text = CoachIntraday.describe(window: window, metric: .hrv, timeZone: los,
                                          now: Date(timeIntervalSince1970: TimeInterval(dayStart + 3_600)))
        XCTAssertTrue(text.contains("no readings between"))
        XCTAssertTrue(text.contains("not that the device only records once a day"))
    }

    func testHrvReadingsAreLabelledWithTheSettledStateTheBaselinesUse() {
        func iv(_ start: Int, _ end: Int, _ cls: ActivityClass, sleep: SleepContextState = .awake) -> ActivityContextInterval {
            ActivityContextInterval(start: start, end: end, activityClass: cls, confidence: 0.9, sleep: sleep)
        }
        let day = [iv(0, 600, .walking), iv(600, 1_500, .sitting), iv(1_500, 2_400, .sitting)]

        let seated = CoachIntraday.hrvState(bucketStart: 2_100, width: 300, intervals: day)
        XCTAssertEqual(seated.group, .seated)
        XCTAssertEqual(seated.stillForS, 1_500, "adjacent sitting intervals are one still run")
        XCTAssertEqual(seated.sinceMovementS, 1_500)

        let justSat = CoachIntraday.hrvState(bucketStart: 900, width: 300, intervals: day)
        XCTAssertEqual(justSat.group, .unsettled, "five minutes after walking is under the ten-minute settle rule")

        let night = [iv(0, 3_600, .sleeping, sleep: .asleep)]
        XCTAssertEqual(CoachIntraday.hrvState(bucketStart: 1_200, width: 300, intervals: night).group, .asleep)
        XCTAssertEqual(CoachIntraday.hrvState(bucketStart: 5_000, width: 300, intervals: night).group, .unknown)
    }
}
