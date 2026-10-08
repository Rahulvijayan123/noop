import XCTest
import StrandAnalytics
@testable import Strand

/// The plain-language copy for Watchdog's alert list and alert sheet: titles, reasons, durations, the
/// context labels and the wearer's note. The list rows and the sheet must say the same thing.
final class WatchdogEventCopyTests: XCTestCase {

    private func row(opened: Int = 1_000_000, last: Int = 1_000_000 + 25 * 60, closed: Int? = 1_000_000 + 25 * 60,
                     contributing: [String]? = nil, signals: [WatchdogSignalEvidence]? = nil,
                     safety: Bool = false, personalOff: Bool = false, headline: String? = nil) -> WatchdogEpisodeLedgerRow {
        WatchdogEpisodeLedgerRow(episodeId: "e1", deviceId: "d", openedUnix: opened, lastUnix: last,
                                 closedUnix: closed, maxSeverity: "active", safety: safety,
                                 personalOff: personalOff, notifyDelivery: "sent", liveAlerts: true,
                                 headline: headline, contributing: contributing, signals: signals)
    }

    func testSeverityTitles() {
        XCTAssertEqual(WatchdogEventCopy.severityTitle("severe"), "Strong alert")
        XCTAssertEqual(WatchdogEventCopy.severityTitle("active"), "Alert")
        XCTAssertEqual(WatchdogEventCopy.severityTitle("candidate"), "Watching")
    }

    func testVitalNames() {
        XCTAssertEqual(WatchdogEventCopy.vitalName("HR"), "Heart rate")
        XCTAssertEqual(WatchdogEventCopy.vitalName("Resp"), "Breathing")
        XCTAssertEqual(WatchdogEventCopy.vitalName("SpO2"), "SpO₂")
        XCTAssertEqual(WatchdogEventCopy.vitalName("Other"), "Other")
    }

    func testValuesAndExpectedLine() {
        let hr = WatchdogSignalEvidence(name: "HR", observed: 70, usual: 60, reconstructed: 62, energy: 1, unit: "bpm")
        XCTAssertEqual(WatchdogEventCopy.value(70, signal: hr, fahrenheit: false), "70 bpm")
        XCTAssertEqual(WatchdogEventCopy.expectedLine(hr, fahrenheit: false), "Expected 62 bpm (+8)")
        let temp = WatchdogSignalEvidence(name: "Temp", observed: 34, usual: 33, reconstructed: nil, energy: 1, unit: "°C")
        XCTAssertEqual(WatchdogEventCopy.value(34, signal: temp, fahrenheit: true), "93.2 °F")
        XCTAssertEqual(WatchdogEventCopy.expectedLine(temp, fahrenheit: true), "Expected 91.4 °F (+1.8)")
        XCTAssertEqual(WatchdogEventCopy.value(nil, signal: hr, fahrenheit: false), "–")
    }

    func testReasonLineNamesTheStrongestDriver() {
        let hr = WatchdogSignalEvidence(name: "HR", observed: 90, usual: 60, reconstructed: 62, energy: 3, unit: "bpm")
        let hrv = WatchdogSignalEvidence(name: "HRV", observed: 30, usual: 48, reconstructed: 46, energy: 1, unit: "ms")
        let line = WatchdogEventCopy.reasonLine(row(contributing: ["HR", "HRV"], signals: [hr, hrv]), fahrenheit: false)
        XCTAssertEqual(line, "Heart rate 90 bpm, expected 62 bpm, plus 1 more")
        XCTAssertEqual(WatchdogEventCopy.reasonLine(row(safety: true), fahrenheit: false), "Past a safety limit.")
        XCTAssertEqual(WatchdogEventCopy.reasonLine(row(), fahrenheit: false), "Recorded before reasons were saved.")
    }

    func testDurationLine() {
        XCTAssertEqual(WatchdogEventCopy.durationLine(row()), "25 min")
        let long = row(last: 1_000_000 + 95 * 60, closed: 1_000_000 + 95 * 60)
        XCTAssertEqual(WatchdogEventCopy.durationLine(long), "1 h 35 min")
        let open = row(last: 1_000_000 + 10 * 60, closed: nil)
        XCTAssertEqual(WatchdogEventCopy.durationLine(open, now: 1_000_000 + 12 * 60), "10 min so far")
    }

    func testContextLabels() {
        XCTAssertEqual(WatchdogEventCopy.activity("walk"), "Walking")
        XCTAssertNil(WatchdogEventCopy.activity(nil))
        XCTAssertEqual(WatchdogEventCopy.eventLabel(WatchdogEventLabel.normalSleep.rawValue), "Asleep")
        XCTAssertNil(WatchdogEventCopy.eventLabel("not-a-label"))
        XCTAssertEqual(WatchdogEventCopy.delivery("sent"), "Sent")
        XCTAssertEqual(WatchdogEventCopy.delivery("denied"), "Blocked, notifications are off")
        XCTAssertEqual(WatchdogEventCopy.delivery(""), "Not sent")
    }

    /// The note's choices are stored as lowercase raw values; the sheet shows them capitalised.
    func testNoteLinesCapitaliseTheChoices() {
        let note = WatchdogEpisodeAnnotation(episodeId: "e1", deviceId: "d", eventUnix: 0, status: .entered,
                                             symptoms: "Headache", exertion: .rest, stress: .high,
                                             illness: .feltOff, sensor: .justOn)
        XCTAssertEqual(WatchdogEventCopy.noteLines(note),
                       ["Symptoms: Headache", "Exertion: Rest", "Stress: High", "Felt off", "Strap had just gone on"])
    }
}
