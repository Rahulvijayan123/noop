import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// Coach context consumers (D6-09, D3-14): per-stretch confidence and the provisional tail, stretches split
/// at sleep/wear changes, the Watchdog's activity label on every signal line, the resting-HR support in the
/// intraday provenance, and the stress index computed only over awake, still beats (or labelled pooled).
final class CoachContextConsumersTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-01 16:00 UTC.
    private let from = 1_790_870_400

    private func interval(_ start: Int, _ end: Int, _ cls: ActivityClass, conf: Double = 0.8,
                          sleep: SleepContextState = .unknown,
                          wear: WearContextState = .onWrist) -> ActivityContextInterval {
        ActivityContextInterval(start: start, end: end, activityClass: cls, confidence: conf,
                                sleep: sleep, wear: wear)
    }

    private func stretchLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("  ") }
    }

    // MARK: Stretch confidence + provisional tail

    func testStretchLinesCarryConfidenceAndMarkTodaysTailProvisional() {
        let items = [
            interval(from, from + 1_200, .sitting, conf: 0.35),
            interval(from + 1_200, from + 1_800, .walking, conf: 0.95),
        ]
        let now = Date(timeIntervalSince1970: TimeInterval(from + 1_860))
        let text = CoachActivityContext.describe(intervals: items, from: from, to: from + 1_860,
                                                 storedThrough: from + 1_800, timeZone: utc, now: now)
        let lines = stretchLines(text)
        XCTAssertEqual(lines.count, 2, text)
        XCTAssertTrue(lines[0].contains("Sitting") && lines[0].contains("confidence 0.35"), lines[0])
        XCTAssertFalse(lines[0].contains("provisional"), "an earlier stretch is settled: \(lines[0])")
        XCTAssertTrue(lines[1].contains("confidence 0.95"), lines[1])
        XCTAssertTrue(lines[1].hasSuffix(", provisional"), "today's newest stretch is undecided: \(lines[1])")
    }

    func testStretchConfidenceIsDurationWeightedAcrossMergedIntervals() {
        let items = [interval(from, from + 300, .sitting, conf: 0.4), interval(from + 300, from + 1_200, .sitting, conf: 0.8)]
        let stretches = CoachActivityContext.stretches(items)
        XCTAssertEqual(stretches.count, 1)
        XCTAssertEqual(stretches[0].meanConfidence, (0.4 * 300 + 0.8 * 900) / 1_200, accuracy: 1e-9)
    }

    func testAPastDayIsNeverProvisional() {
        let items = [interval(from, from + 600, .sitting)]
        let now = Date(timeIntervalSince1970: TimeInterval(from + 3 * 86_400))
        let text = CoachActivityContext.describe(intervals: items, from: from, to: from + 600,
                                                 storedThrough: from + 600, timeZone: utc, now: now)
        XCTAssertFalse(stretchLines(text).joined().contains("provisional"), text)
    }

    func testStretchesSplitAtSleepAndWearChanges() {
        let items = [
            interval(from, from + 600, .lyingDown, sleep: .awake),
            interval(from + 600, from + 1_200, .lyingDown, sleep: .asleep),
            interval(from + 1_200, from + 1_800, .stationary, wear: .onWrist),
            interval(from + 1_800, from + 2_400, .stationary, wear: .unknown),
        ]
        let stretches = CoachActivityContext.stretches(items)
        XCTAssertEqual(stretches.count, 4, "same label, different sleep or wear, is a different situation")
        // Same class, sleep and wear still merge.
        XCTAssertEqual(CoachActivityContext.stretches([interval(from, from + 600, .sitting),
                                                       interval(from + 600, from + 900, .sitting)]).count, 1)
    }

    // MARK: Watchdog activity label

    func testWatchdogSignalLinesCarryTheActivityLabel() {
        let signals = [WatchdogSignalEvidence(name: "Heart rate", observed: 104, usual: 72, reconstructed: nil,
                                              energy: 1, unit: "bpm", trustPct: 80, rangeHalf: 6)]
        let lines = CoachWatchdogText.signalLines(signals, activityLabel: "walk", activityDetail: "Walking")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("Heart rate: 104 bpm vs expected 72.0 ± 6.0 (trust 80%)"), lines[0])
        XCTAssertTrue(lines[0].contains("Walking"), lines[0])
        XCTAssertTrue(lines[0].contains("[walk]"), lines[0])
        // Review fix: the label is the head's LATEST-minute output, not the whole scored window's activity.
        XCTAssertTrue(lines[0].contains("activity in the latest minute: Walking [walk]"), lines[0])
        XCTAssertFalse(lines[0].contains("measured while"), lines[0])

        let unknown = CoachWatchdogText.signalLines(signals, activityLabel: "unknown", activityDetail: "Unknown")
        XCTAssertTrue(unknown[0].contains("activity unknown"), unknown[0])
        // A signal with no observation prints nothing, as before.
        let silent = [WatchdogSignalEvidence(name: "HRV", observed: nil, usual: 40, reconstructed: nil, energy: 0, unit: "ms")]
        XCTAssertTrue(CoachWatchdogText.signalLines(silent, activityLabel: "still", activityDetail: "Still").isEmpty)
    }

    // MARK: Resting-HR provenance

    func testRestingHeartRateProvenanceStatesTheTrailingHourSupport() {
        let text = CoachIntraday.provenance(.restingHeartRate, bucketSeconds: 300)
        XCTAssertTrue(text.contains("LOWEST 5-minute mean heart rate over the 60 minutes"), text)
        XCTAssertFalse(text.contains("each reading covers a 5-minute bucket"),
                       "the display bucket is not the resting-HR support: \(text)")
        // HRV's own bucket IS its support, unchanged.
        XCTAssertTrue(CoachIntraday.provenance(.hrv, bucketSeconds: 300).contains("each reading covers a 5-minute bucket"))
    }

    // MARK: Stress index scope

    /// 60 beats around 800 ms with enough spread for a histogram, one per second from `start`.
    private func beats(from start: Int, count: Int = 60, base: Int = 800) -> [RRInterval] {
        (0..<count).map { RRInterval(ts: start + $0, rrMs: base + ($0 % 7) * 15) }
    }

    func testStressIndexUsesOnlyAwakeStillBeats() throws {
        // 400 still beats (~340 s of R-R): above the 5-min awake-still support floor.
        let still = beats(from: from, count: 400)
        let asleep = beats(from: from + 1_000, base: 1_000)
        let running = beats(from: from + 2_000, base: 400)
        let context = [interval(from, from + 600, .sitting),
                       interval(from + 1_000, from + 1_600, .sleeping, sleep: .asleep),
                       interval(from + 2_000, from + 2_600, .running)]
        let kept = AICoachEngine.stressIndexBeats(rr: still + asleep + running, context: context)
        XCTAssertEqual(kept, still)
        let line = try XCTUnwrap(AICoachEngine.stressIndexLine(rr: still + asleep + running, context: context,
                                                               timeZone: utc))
        let expected = try XCTUnwrap(StressIndex.stressIndex(rr: still))
        XCTAssertTrue(line.hasPrefix("Stress (SI): \(Int(expected.rounded())) "), line)
        // Review fix: the support and the context horizon are stated (from + 2600 = 16:43 UTC).
        XCTAssertTrue(line.contains("over 5 min of today's R-R while awake and still, activity context through 16:43"),
                      line)
    }

    func testTooLittleAwakeStillRRFallsBackToPooled() throws {
        // Review fix: 60 still beats (~50 s) clear the SI's 20-beat histogram floor but are far too little to
        // stand for today's awake stress, so the line falls back to the labelled pooled value.
        let still = beats(from: from)
        let running = beats(from: from + 2_000, base: 400)
        let context = [interval(from, from + 600, .sitting), interval(from + 2_000, from + 2_600, .running)]
        XCTAssertNotNil(StressIndex.stressIndex(rr: AICoachEngine.stressIndexBeats(rr: still + running,
                                                                                   context: context)))
        let line = try XCTUnwrap(AICoachEngine.stressIndexLine(rr: still + running, context: context))
        XCTAssertTrue(line.contains("pooled across sleep, rest and activity"), line)
        XCTAssertFalse(line.contains("while awake and still"), line)
    }

    func testStressIndexWithoutContextIsLabelledPooled() throws {
        let rr = beats(from: from)
        let line = try XCTUnwrap(AICoachEngine.stressIndexLine(rr: rr, context: []))
        XCTAssertTrue(line.contains("pooled across sleep, rest and activity"), line)
        XCTAssertNil(AICoachEngine.stressIndexLine(rr: [], context: []))
    }
}
