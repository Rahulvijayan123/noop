import XCTest
import StrandAnalytics
@testable import Strand

/// Pins the Watchdog card's per-vital calls. `WatchdogLiveSnapshot` decides what the wearer is told for
/// each vital ("In range", "Off", "Live", "No reading") and how its trace is drawn; it was moved out of
/// WatchdogView.swift unchanged, and these tests hold it there while the views around it are restyled.
@MainActor
final class WatchdogLiveSnapshotTests: XCTestCase {

    private let threshold = LongitudinalBaseline.trustHideThreshold

    // MARK: Before the first check

    func testNoResultIsWaitingWithSixEmptyVitals() {
        let store = BaselineStore(defaults: UserDefaults(suiteName: "WatchdogLiveSnapshotTests.\(UUID())")!,
                                  asOf: "2026-10-06", resetCourse: true)
        let snap = WatchdogLiveSnapshot(store: store)
        XCTAssertFalse(snap.isLive)
        XCTAssertEqual(snap.liveLabel, "Waiting")
        XCTAssertNil(snap.updatedAgo)
        XCTAssertEqual(snap.certaintyCaption, "Waiting on this half-hour.")
        XCTAssertEqual(snap.metrics.map(\.id), ["hr", "rhr", "hrv", "temp", "resp", "spo2"])
        XCTAssertEqual(snap.metrics.map(\.name), ["Heart rate", "Resting HR", "HRV", "Temp", "Breathing", "SpO₂"])
        XCTAssertTrue(snap.metrics.allSatisfy { $0.status == "No reading" && $0.now == "–" && $0.expected == "–" })
        XCTAssertTrue(snap.metrics.allSatisfy { !$0.rangeReady && $0.trustPct == 0 })
    }

    func testEmptyTempRowScalesToFahrenheit() {
        let c = WatchdogLiveSnapshot.emptyRow(id: "temp", name: "Temp", caption: "", minSpan: 0.4, whoop5: false)
        let f = WatchdogLiveSnapshot.emptyRow(id: "temp", name: "Temp", caption: "", minSpan: 0.4, whoop5: false,
                                              fahrenheit: true)
        XCTAssertEqual(f.minSpan, c.minSpan * 9 / 5, accuracy: 1e-9)
        XCTAssertEqual(f.rangeHalf, c.rangeHalf * 9 / 5, accuracy: 1e-9)
        XCTAssertEqual(c.decimals, 1)
    }

    // MARK: Pure helpers

    func testLearningBandGainWidensOnlyBelowTheTrustThreshold() {
        XCTAssertEqual(WatchdogLiveSnapshot.learningBandGain(threshold), 1)
        XCTAssertEqual(WatchdogLiveSnapshot.learningBandGain(100), 1)
        XCTAssertEqual(WatchdogLiveSnapshot.learningBandGain(0), 1 + Double(threshold) / 35 * 2.5, accuracy: 1e-9)
        XCTAssertGreaterThan(WatchdogLiveSnapshot.learningBandGain(0), WatchdogLiveSnapshot.learningBandGain(20))
    }

    func testMaskToRecordedDropsMinutesWithoutAReading() {
        let masked = WatchdogLiveSnapshot.maskToRecorded([60, 61, 62], recorded: [70, .nan, 72])
        XCTAssertEqual(masked[0], 60)
        XCTAssertTrue(masked[1].isNaN)
        XCTAssertEqual(masked[2], 62)
    }

    func testPackRecordedKeepsOnlyRecordedMinutes() {
        let packed = WatchdogLiveSnapshot.packRecorded(series: [.nan, 55, .nan, 57],
                                                       reconstructed: [50, 51, 52, 53],
                                                       rangeSeries: [4, 5, 6, 7])
        XCTAssertEqual(packed.series, [55, 57])
        XCTAssertEqual(packed.reconstructed, [51, 53])
        XCTAssertEqual(packed.rangeSeries, [5, 7])
    }

    func testLastAlignedPrefersTheNewestMinuteWithBothValues() {
        let aligned = WatchdogLiveSnapshot.lastAligned(series: [60, 61, .nan], reconstructed: [58, .nan, 59], usual: nil)
        XCTAssertEqual(aligned?.obs, 60)
        XCTAssertEqual(aligned?.hat, 58)
        XCTAssertEqual(aligned?.index, 0)
        let fallback = WatchdogLiveSnapshot.lastAligned(series: [60, 61], reconstructed: [.nan, .nan], usual: 57)
        XCTAssertEqual(fallback?.obs, 61)
        XCTAssertEqual(fallback?.hat, 57)
        XCTAssertNil(WatchdogLiveSnapshot.lastAligned(series: [.nan], reconstructed: [.nan], usual: nil))
    }

    func testFormatAndDecimals() {
        XCTAssertEqual(WatchdogLiveSnapshot.format(nil, decimals: 0, unit: "bpm"), "–")
        XCTAssertEqual(WatchdogLiveSnapshot.format(64.4, decimals: 0, unit: "bpm"), "64 bpm")
        XCTAssertEqual(WatchdogLiveSnapshot.format(33.06, decimals: 1, unit: ""), "33.1")
        XCTAssertEqual(WatchdogLiveSnapshot.decimals(for: "temp"), 1)
        XCTAssertEqual(WatchdogLiveSnapshot.decimals(for: "hr"), 0)
    }

    func testRangeHalfAndReadCadence() {
        XCTAssertEqual(WatchdogLiveSnapshot.rangeHalf(for: "hr"), WatchdogConfig.hrScale * WatchdogConfig.tau)
        XCTAssertEqual(WatchdogLiveSnapshot.whoopReadSeconds(id: "hr", whoop5: false), 1)
        XCTAssertEqual(WatchdogLiveSnapshot.whoopReadSeconds(id: "hrv", whoop5: true), 30)
        XCTAssertEqual(WatchdogLiveSnapshot.whoopReadSeconds(id: "temp", whoop5: false), 0)
    }

    func testAgoBuckets() {
        let now = Int(Date().timeIntervalSince1970)
        XCTAssertEqual(WatchdogLiveSnapshot.ago(now - 10), "Just now")
        XCTAssertEqual(WatchdogLiveSnapshot.ago(now - 90), "1 min ago")
        XCTAssertEqual(WatchdogLiveSnapshot.ago(now - 600), "10 min ago")
        XCTAssertEqual(WatchdogLiveSnapshot.ago(now - 7300), "2 h ago")
    }

    // MARK: The per-vital call

    private func signal(observed: Double?, reconstructed: Double?, rangeHalf: Double = 5) -> WatchdogSignalEvidence {
        WatchdogSignalEvidence(name: "HR", observed: observed, usual: 60, reconstructed: reconstructed,
                               energy: 0, unit: "bpm", trustPct: 80, rangeHalf: rangeHalf)
    }

    func testRowIsInRangeInsideTheBandOnceTrusted() {
        let row = WatchdogLiveSnapshot.row(id: "hr", name: "Heart rate", signal: signal(observed: 62, reconstructed: 60),
                                           series: [61, 62], reconstructed: [60, 60], rangeSeries: [5, 5],
                                           caption: "Last 30 min", minSpan: 8, whoop5: false,
                                           trustPct: 80, bandReady: true)
        XCTAssertEqual(row.status, "In range")
        XCTAssertEqual(row.now, "62 bpm")
        XCTAssertEqual(row.expected, "60 bpm")
        XCTAssertEqual(row.rangeLabel, "Range 55–65 bpm")
        XCTAssertTrue(row.rangeReady)
    }

    func testRowIsOffOutsideTheBand() {
        let row = WatchdogLiveSnapshot.row(id: "hr", name: "Heart rate", signal: signal(observed: 80, reconstructed: 60),
                                           series: [70, 80], reconstructed: [60, 60], rangeSeries: [5, 5],
                                           caption: "", minSpan: 8, whoop5: false, trustPct: 80, bandReady: true)
        XCTAssertEqual(row.status, "Off")
    }

    func testRowIsLiveWithoutACallWhileLearning() {
        let row = WatchdogLiveSnapshot.row(id: "hr", name: "Heart rate", signal: signal(observed: 80, reconstructed: 60),
                                           series: [80], reconstructed: [60], rangeSeries: [5],
                                           caption: "", minSpan: 8, whoop5: false, trustPct: threshold - 1,
                                           bandReady: true)
        XCTAssertEqual(row.status, "Live")
        XCTAssertFalse(row.rangeReady)
        // The learning band is widened for drawing only.
        XCTAssertGreaterThan(row.rangeSeries[0], 5)
    }

    func testRowWithoutAnyMinuteIsNoReading() {
        let row = WatchdogLiveSnapshot.row(id: "hrv", name: "HRV", signal: nil, series: [.nan, .nan],
                                           reconstructed: [40, 40], rangeSeries: [5, 5], caption: "",
                                           minSpan: 18, whoop5: false, trustPct: 0)
        XCTAssertEqual(row.status, "No reading")
        XCTAssertEqual(row.now, "–")
        XCTAssertTrue(row.reconstructed.isEmpty)
    }

    func testSparseVitalsArePackedToTheirRecordedMinutes() {
        let row = WatchdogLiveSnapshot.row(id: "rhr", name: "Resting HR", signal: signal(observed: 56, reconstructed: 55),
                                           series: [.nan, 56, .nan, 57], reconstructed: [55, 55, 55, 55],
                                           rangeSeries: [5, 5, 5, 5], caption: "", minSpan: 8, whoop5: false,
                                           trustPct: 80, bandReady: true)
        XCTAssertEqual(row.series, [56, 57])
        XCTAssertEqual(row.reconstructed, [55, 55])
    }

    func testTempConvertsToFahrenheit() {
        let temp = WatchdogSignalEvidence(name: "Temp", observed: 33, usual: 33, reconstructed: 33, energy: 0,
                                          unit: "°C", trustPct: 80, rangeHalf: 0.3)
        let row = WatchdogLiveSnapshot.row(id: "temp", name: "Temp", signal: temp, series: [33],
                                           reconstructed: [33], rangeSeries: [0.3], caption: "",
                                           minSpan: 0.4, whoop5: false, fahrenheit: true, trustPct: 80,
                                           bandReady: true)
        XCTAssertEqual(row.now, "91.4 °F")
        XCTAssertEqual(row.series[0], 91.4, accuracy: 1e-9)
    }

    // MARK: Captions

    func testCertaintyCaptionOnAnUnavailableResult() {
        let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
        let result = Watchdog.evaluate(window: .failure(.empty), prompt: prompt, nowUnix: 88_100_000)
        XCTAssertNotNil(result.unavailable)
        XCTAssertEqual(WatchdogLiveSnapshot.certaintyCaption(result), "Not enough minutes.")
        XCTAssertEqual(WatchdogLiveSnapshot.waitingLabel(result), "Waiting")
    }

    func testBandCaptionWithoutAResult() {
        XCTAssertEqual(WatchdogLiveSnapshot.bandCaption(nil),
                       "Live line and gray model range can fill as soon as this half-hour has readings. Green personal width waits for 14 good still minutes of that vital.")
        XCTAssertTrue(WatchdogLiveSnapshot.bandCaption(nil, contextNote: "Walking.").hasSuffix(" Walking."))
    }
}
