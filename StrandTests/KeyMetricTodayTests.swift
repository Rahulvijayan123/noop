import XCTest
import WhoopStore
@testable import Strand

/// The key-metric screen's Today view: which reading is "today", which baselines are honest, and the Monitor
/// and charging fallbacks that were showing a bare dash.
final class KeyMetricTodayTests: XCTestCase {

    private func reading(_ day: String, _ value: Double) -> KeyMetricHistory.Reading {
        KeyMetricHistory.Reading(day: day, date: PhysiologyContextDates.date(day)!, value: value)
    }

    /// Thirty consecutive days ending 2026-10-08, value 50 on every day except the last.
    private var nights: [KeyMetricHistory.Reading] {
        (0..<30).map { offset in
            let day = PhysiologyContextDates.key("2026-10-08", minusDays: offset)!
            return reading(day, offset == 0 ? 56 : 50)
        }.reversed()
    }

    func testANightKeyedToTodayIsTodaysReadingAndComparesWithTheDaysBefore() {
        let today = KeyMetricToday.make(readings: nights, todayValue: nil, today: "2026-10-08")
        XCTAssertEqual(today.value, 56)
        XCTAssertEqual(today.freshness, .today)
        XCTAssertEqual(today.baselines.map(\.days), [7, 30, 90])
        // Today's own value is left out of the median it is compared with.
        XCTAssertEqual(today.baselines[0].median, 50)
        XCTAssertEqual(today.baselines[0].count, 7)
        XCTAssertEqual(today.baselines[0].delta, 6)
    }

    func testWithoutTodaysNightTheNewestEarlierOneIsShownAsEarlier() {
        let earlier = nights.dropLast()
        let today = KeyMetricToday.make(readings: Array(earlier), todayValue: nil, today: "2026-10-08")
        XCTAssertEqual(today.freshness, .earlier("2026-10-07"))
        XCTAssertEqual(today.value, 50)
    }

    func testADayMetricsValueSoFarTodayBeatsTheLastFullDay() {
        let days = nights.dropLast()
        let today = KeyMetricToday.make(readings: Array(days), todayValue: 3_200, today: "2026-10-08")
        XCTAssertEqual(today.value, 3_200)
        XCTAssertEqual(today.freshness, .today)
        XCTAssertEqual(today.day, "2026-10-08")
        XCTAssertEqual(today.baselines.first?.median, 50)
    }

    func testABaselineNeedsThreeReadings() {
        let few = [reading("2026-10-06", 50), reading("2026-10-07", 52), reading("2026-10-08", 51)]
        let today = KeyMetricToday.make(readings: few, todayValue: nil, today: "2026-10-08")
        XCTAssertTrue(today.baselines.isEmpty, "two earlier readings are not a baseline")
    }

    func testNothingMeasuredIsNone() {
        let today = KeyMetricToday.make(readings: [], todayValue: nil, today: "2026-10-08")
        XCTAssertNil(today.value)
        XCTAssertEqual(today.freshness, .none)
    }

    // MARK: Watchdog fallback

    @MainActor
    private func day(_ key: String, rhr: Int? = nil, spo2: Double? = nil, temp: Double? = nil) -> DailyMetric {
        BaselineStore.daily(day: key, rhr: rhr, temp: temp, spo2: spo2)
    }

    @MainActor
    func testTheWatchdogCellFallsBackToLastNightsValue() {
        let rows = [day("2026-10-06", rhr: 55), day("2026-10-08", rhr: 52, spo2: 96)]
        let rhr = WatchdogFallback.make(id: "rhr", days: rows, todayKey: "2026-10-08", fahrenheit: false)
        XCTAssertEqual(rhr?.value, "52 bpm")
        XCTAssertEqual(rhr?.caption, "Last night")
        let spo2 = WatchdogFallback.make(id: "spo2", days: rows, todayKey: "2026-10-08", fahrenheit: false)
        XCTAssertEqual(spo2?.value, "96 %")
    }

    @MainActor
    func testAnOlderRowIsStampedWithItsDateAndLiveHeartRateHasNoFallback() {
        let rows = [day("2026-10-06", rhr: 55)]
        let rhr = WatchdogFallback.make(id: "rhr", days: rows, todayKey: "2026-10-08", fahrenheit: false)
        XCTAssertEqual(rhr?.value, "55 bpm")
        XCTAssertNotEqual(rhr?.caption, "Last night")
        XCTAssertNil(WatchdogFallback.make(id: "hr", days: rows, todayKey: "2026-10-08", fahrenheit: false))
        XCTAssertNil(WatchdogFallback.make(id: "spo2", days: rows, todayKey: "2026-10-08", fahrenheit: false),
                     "no SpO2 recorded, so no number is invented")
    }

    func testNoReadingReasonNamesTheCharger() {
        XCTAssertNotNil(MonitorLabels.noReadingReason(charging: true, connected: true, activeIsWhoop: true, wristOff: false))
        XCTAssertTrue(MonitorLabels.noReadingReason(charging: true, connected: true, activeIsWhoop: true, wristOff: false)!
            .contains("charging"))
        XCTAssertNotNil(MonitorLabels.noReadingReason(charging: false, connected: false, activeIsWhoop: true, wristOff: false))
        XCTAssertNotNil(MonitorLabels.noReadingReason(charging: false, connected: true, activeIsWhoop: true, wristOff: true))
        XCTAssertNil(MonitorLabels.noReadingReason(charging: false, connected: true, activeIsWhoop: true, wristOff: false))
        XCTAssertNil(MonitorLabels.noReadingReason(charging: true, connected: true, activeIsWhoop: false, wristOff: false))
    }

    // MARK: Charging

    func testARisingChargeReadsAsChargingUntilTheStrapSaysOtherwise() {
        let now = 10_000
        XCTAssertTrue(ChargingEvidence.rising(samples: [(now - 900, 40), (now - 60, 43)], now: now))
        XCTAssertFalse(ChargingEvidence.rising(samples: [(now - 900, 43), (now - 60, 43)], now: now), "flat is not charging")
        XCTAssertFalse(ChargingEvidence.rising(samples: [(now - 900, 43), (now - 60, 42)], now: now), "falling is discharge")
        XCTAssertFalse(ChargingEvidence.rising(samples: [(now - 9_000, 40), (now - 8_900, 45)], now: now), "too old to say")
        XCTAssertFalse(ChargingEvidence.rising(samples: [(now - 60, 45)], now: now), "one reading has no trend")
    }

    @MainActor
    func testTheStrapsOwnFlagOutranksTheTrend() {
        let live = LiveState()
        live.bankBatterySample(40, now: Int(Date().timeIntervalSince1970) - 600)
        live.bankBatterySample(44, now: Int(Date().timeIntervalSince1970) - 30)
        XCTAssertTrue(live.isChargingNow, "rising with no flag yet")
        live.charging = false
        XCTAssertFalse(live.isChargingNow, "the gauge's own word wins")
        live.charging = true
        XCTAssertTrue(live.isChargingNow)
    }
}
