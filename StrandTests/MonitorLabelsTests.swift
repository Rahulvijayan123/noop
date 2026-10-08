import XCTest
import StrandAnalytics
@testable import Strand

/// The Monitor area's display mappings: units, verdict words, confidence, the wearer's note choices,
/// contexts and the Watchdog stale-time rule.
@MainActor
final class MonitorLabelsTests: XCTestCase {

    func testUnits() {
        XCTAssertEqual(MonitorLabels.unit("/min", fahrenheit: false), "rpm")
        XCTAssertEqual(MonitorLabels.unit("°C", fahrenheit: true), "°F")
        XCTAssertEqual(MonitorLabels.unit("°C", fahrenheit: false), "°C")
        XCTAssertEqual(MonitorLabels.unit("bpm", fahrenheit: true), "bpm")
    }

    func testDisplayValueConvertsOnlyTemperature() {
        XCTAssertEqual(MonitorLabels.displayValue(33, planUnit: "°C", fahrenheit: true), 91.4, accuracy: 1e-9)
        XCTAssertEqual(MonitorLabels.displayValue(33, planUnit: "°C", fahrenheit: false), 33)
        XCTAssertEqual(MonitorLabels.displayValue(60, planUnit: "bpm", fahrenheit: true), 60)
    }

    func testNumbersAndRanges() {
        XCTAssertEqual(MonitorLabels.number(61.6, unit: "bpm"), "62")
        XCTAssertEqual(MonitorLabels.number(14.24, unit: "rpm"), "14.2")
        XCTAssertEqual(MonitorLabels.number(nil, unit: "ms"), "—")
        XCTAssertEqual(MonitorLabels.number(.nan, unit: "ms"), "—")
        XCTAssertEqual(MonitorLabels.range(44.2, 66.8, unit: "bpm"), "44–67 bpm")
    }

    func testSplitValue() {
        XCTAssertEqual(MonitorLabels.splitValue("64 bpm").value, "64")
        XCTAssertEqual(MonitorLabels.splitValue("64 bpm").unit, "bpm")
        XCTAssertEqual(MonitorLabels.splitValue("33.1 °F").unit, "°F")
        XCTAssertNil(MonitorLabels.splitValue("–").value)
        XCTAssertEqual(MonitorLabels.splitValue("97").value, "97")
        XCTAssertNil(MonitorLabels.splitValue("97").unit)
    }

    func testVerdictsAreSentenceCase() {
        XCTAssertEqual(MonitorLabels.verdict("IN RANGE"), "In range")
        XCTAssertEqual(MonitorLabels.verdict("OFF"), "Off usual")
        XCTAssertEqual(MonitorLabels.verdict("WEAK SIGNAL"), "Weak signal")
        XCTAssertEqual(MonitorLabels.verdict("NOT ENOUGH NIGHTS"), "Not enough nights")
        XCTAssertEqual(MonitorLabels.verdict("BUILDING"), "Building")
        XCTAssertEqual(MonitorLabels.verdictTone("IN RANGE"), .positive)
        XCTAssertEqual(MonitorLabels.verdictTone("OFF"), .warning)
        XCTAssertEqual(MonitorLabels.verdictTone("BUILDING"), .neutral)
    }

    func testConfidenceCutoffs() {
        XCTAssertNil(MonitorLabels.confidence(nil))
        XCTAssertNil(MonitorLabels.confidence(0))
        XCTAssertEqual(MonitorLabels.confidence(39), "Low")
        XCTAssertEqual(MonitorLabels.confidence(40), "Medium")
        XCTAssertEqual(MonitorLabels.confidence(70), "High")
    }

    func testWatchdogAndVitalWords() {
        XCTAssertEqual(MonitorLabels.watchdogStatus("Off"), "Off usual")
        XCTAssertEqual(MonitorLabels.watchdogStatus("Live"), "Learning")
        XCTAssertEqual(MonitorLabels.watchdogStatus("In range"), "In range")
        XCTAssertEqual(MonitorLabels.watchdogStatus("No reading"), "No reading")
        XCTAssertEqual(MonitorLabels.vitalState(.off), "Off usual")
        XCTAssertEqual(MonitorLabels.vitalState(.learning), "Learning")
    }

    func testNoteChoicesAreCapitalised() {
        XCTAssertEqual(MonitorLabels.exertion(.rest), "Rest")
        XCTAssertEqual(MonitorLabels.exertion(.hard), "Hard")
        XCTAssertEqual(MonitorLabels.stress(.high), "High")
        XCTAssertEqual(MonitorLabels.sensor(.justOn), "Just on")
        XCTAssertEqual(MonitorLabels.illness(.feltOff), "Felt off")
    }

    func testContextSeriesMatchTheStore() {
        let store = BaselineStore(defaults: UserDefaults(suiteName: "MonitorLabelsTests.\(UUID())")!,
                                  asOf: "2026-10-06", resetCourse: true)
        for context in MonitorLabels.contextOrder {
            store.context = context
            XCTAssertEqual(MonitorLabels.series(in: context), store.displayedSeries, "\(context)")
        }
        XCTAssertEqual(Set(MonitorLabels.contextOrder), Set(BaselineStore.ContextFilter.allCases))
        XCTAssertEqual(MonitorLabels.contextName(.sleep), "Night")
        XCTAssertEqual(MonitorLabels.contextName(.rest), "At rest")
    }

    func testStaleCheckTimeOnlyWhenOverdue() {
        let now = 1_800_000_000
        XCTAssertNil(MonitorLabels.staleCheckTime(lastTickUnix: now - 60, nowUnix: now, intervalMinutes: 5))
        XCTAssertNil(MonitorLabels.staleCheckTime(lastTickUnix: now - 600, nowUnix: now, intervalMinutes: 5))
        XCTAssertNotNil(MonitorLabels.staleCheckTime(lastTickUnix: now - 601, nowUnix: now, intervalMinutes: 5))
        XCTAssertNil(MonitorLabels.staleCheckTime(lastTickUnix: 0, nowUnix: now, intervalMinutes: 5))
    }

    func testWatchdogLineAndNotice() {
        XCTAssertEqual(MonitorLabels.watchdogLine(headline: nil, hasReadings: false), "Waiting for the first check")
        XCTAssertEqual(MonitorLabels.watchdogLine(headline: "Calm.", hasReadings: false), "No readings in the last 30 minutes")
        XCTAssertEqual(MonitorLabels.watchdogLine(headline: "Calm.", hasReadings: true), "Calm.")
        XCTAssertEqual(MonitorLabels.watchdogNotice("Alert not delivered. Will retry."), "Alert not delivered. Will retry.")
        XCTAssertNil(MonitorLabels.watchdogNotice("Not enough minutes."))
        XCTAssertNil(MonitorLabels.watchdogNotice("Strap off. Not recovered."))
        XCTAssertNil(MonitorLabels.watchdogNotice(nil))
    }

    func testAlertBarsSplitAtMidnight() {
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 10, day: 2))!
        let open = day.addingTimeInterval(23.5 * 3600)
        let close = open.addingTimeInterval(60 * 60)
        let row = WatchdogEpisodeLedgerRow(episodeId: "e", deviceId: "d", openedUnix: Int(open.timeIntervalSince1970),
                                           lastUnix: Int(close.timeIntervalSince1970),
                                           closedUnix: Int(close.timeIntervalSince1970), maxSeverity: "active",
                                           safety: false, personalOff: false, notifyDelivery: "", liveAlerts: true)
        let bars = WatchdogAlertTimeline.bars([row], calendar: cal)
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].day, day)
        XCTAssertEqual(bars[0].startHour, 23.5, accuracy: 1e-6)
        XCTAssertEqual(bars[0].endHour, 24, accuracy: 1e-6)
        XCTAssertEqual(bars[1].startHour, 0, accuracy: 1e-6)
        XCTAssertEqual(bars[1].endHour, 0.5, accuracy: 1e-6)
    }

    func testAlertTotals() {
        func row(_ open: Int, _ close: Int?) -> WatchdogEpisodeLedgerRow {
            WatchdogEpisodeLedgerRow(episodeId: "\(open)", deviceId: "d", openedUnix: open, lastUnix: open + 600,
                                     closedUnix: close, maxSeverity: "active", safety: false, personalOff: false,
                                     notifyDelivery: "", liveAlerts: true)
        }
        let totals = MonitorLabels.alertTotals([row(0, 25 * 60), row(10_000, nil)])
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.totalMinutes, 35)
        XCTAssertEqual(totals.longestMinutes, 25)
        XCTAssertEqual(MonitorLabels.minutesText(25), "25 min")
        XCTAssertEqual(MonitorLabels.minutesText(95), "1 h 35 min")
        XCTAssertEqual(MonitorLabels.minutesText(120), "2 h")
    }
}
