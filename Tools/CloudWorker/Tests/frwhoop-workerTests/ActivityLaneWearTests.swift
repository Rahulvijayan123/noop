import XCTest
import CZstd
import StrandAnalytics
@testable import frwhoop_worker

/// G3/G7 wear wiring for the activity fold: WRIST_ON/OFF-derived `WearInterval`s feed the shared
/// `ActivityContextPolicy` so epochs carry an EVIDENCED wear_state (unknown where no event covers).
/// Pure, deterministic, no DB/B2/Python.
final class ActivityLaneWearTests: XCTestCase {

    /// A Unix base on the 30-s epoch grid so epoch boundaries land exactly on base + 30k.
    private let base = 1_758_000_000

    // MARK: - Interval reconstruction

    func testWearIntervalsSimpleFlip() {
        let intervals = ActivityLane.wearIntervals(fromEvents: [
            (ts: base + 60, kind: "WRIST_OFF(10)"),
            (ts: base + 120, kind: "WRIST_ON(9)"),
        ], from: base, to: base + 300)
        XCTAssertEqual(intervals, [
            WearInterval(start: base + 60, end: base + 120, wear: .offWrist),
            WearInterval(start: base + 120, end: base + 300, wear: .onWrist),
        ])
    }

    func testWearIntervalsCoalesceAndSort() {
        let intervals = ActivityLane.wearIntervals(fromEvents: [
            (ts: base + 120, kind: "WRIST_OFF(10)"),
            (ts: base + 60, kind: "WRIST_OFF(10)"),   // duplicate OFF while off
            (ts: base + 30, kind: "WRIST_ON(9)"),
            (ts: base + 240, kind: "WRIST_ON(9)"),    // duplicate ON while on
        ], from: base, to: base + 300)
        XCTAssertEqual(intervals, [
            WearInterval(start: base + 30, end: base + 60, wear: .onWrist),
            WearInterval(start: base + 60, end: base + 240, wear: .offWrist),
            WearInterval(start: base + 240, end: base + 300, wear: .onWrist),
        ])
    }

    func testWearIntervalsUnknownGapsAndOpenTail() {
        // No events: no intervals at all (policy → unknown; quiet IMU is never on-wrist evidence).
        XCTAssertTrue(ActivityLane.wearIntervals(fromEvents: [], from: base, to: base + 300).isEmpty)
        // Open off-body tail extends to `to` (evidence-backed).
        XCTAssertEqual(ActivityLane.wearIntervals(fromEvents: [
            (ts: base + 90, kind: "WRIST_OFF(10)"),
        ], from: base, to: base + 300), [WearInterval(start: base + 90, end: base + 300, wear: .offWrist)])
        // Events outside the day are ignored (a stale pre-day OFF never paints the day start).
        XCTAssertEqual(ActivityLane.wearIntervals(fromEvents: [
            (ts: base - 100, kind: "WRIST_OFF(10)"),
            (ts: base + 200, kind: "WRIST_ON(9)"),
        ], from: base, to: base + 300), [WearInterval(start: base + 200, end: base + 300, wear: .onWrist)])
    }

    // MARK: - Fold wiring

    private func window(_ label: MotionLabel, from: Int, prob: Double = 0.95) -> ActivityPythonService.WindowPrediction {
        ActivityPythonService.WindowPrediction(
            start: Double(from), end: Double(from + 4),
            label: label.rawValue, probs: [label.rawValue: prob, "unknown": 1 - prob], baseline: false)
    }

    /// A full day of confident walking windows so the fold produces epochs regardless of wear input.
    private func dayWindows(dayStart: Int) -> [ActivityPythonService.WindowPrediction] {
        var out: [ActivityPythonService.WindowPrediction] = []
        var t = dayStart
        while t + 4 <= dayStart + 600 {
            out.append(window(.walking, from: t))
            t += 4
        }
        return out
    }

    func testActivityDocumentEpochsCarryEvidencedWearState() throws {
        let dayStart = base
        let dayEnd = dayStart + 600
        let events = [
            (ts: dayStart + 60, kind: "WRIST_OFF(10)"),
            (ts: dayStart + 240, kind: "WRIST_ON(9)"),
        ]
        let wear = ActivityLane.wearIntervals(fromEvents: events, from: dayStart, to: dayEnd)

        let doc = try ActivityLane.activityDocument(
            windows: dayWindows(dayStart: dayStart),
            sleepIntervals: [], exerciseIntervals: [],
            dayStart: dayStart, dayEnd: dayEnd,
            inputRevision: 1, modelVersion: "hart-activity-v1",
            preprocessingVersion: "hart-activity-preprocess-v1",
            dataThrough: dayEnd,
            wearIntervals: wear)
        let epochs = (doc["epochs"] as? [[String: Any]]) ?? []
        XCTAssertFalse(epochs.isEmpty)

        // C10 epoch JSON keys: s = start_ts, w = wear_state.
        let offEpoch = try XCTUnwrap(epochs.first(where: { ($0["s"] as? Int ?? 0) >= dayStart + 60
            && ($0["s"] as? Int ?? 0) < dayStart + 240 }))
        XCTAssertEqual(offEpoch["w"] as? String, "off_wrist")
        // On-wrist epoch.
        let onEpoch = try XCTUnwrap(epochs.first(where: { ($0["s"] as? Int ?? 0) >= dayStart + 240 }))
        XCTAssertEqual(onEpoch["w"] as? String, "on_wrist")
        // Epoch before the first event: no evidence → unknown, never a guessed state.
        let unknownEpoch = try XCTUnwrap(epochs.first(where: { ($0["s"] as? Int ?? 0) < dayStart + 60 }))
        XCTAssertEqual(unknownEpoch["w"] as? String, "unknown")
    }

    func testActivityDocumentWithoutWearKeepsAllUnknown() throws {
        let dayStart = base
        let dayEnd = dayStart + 600
        let doc = try ActivityLane.activityDocument(
            windows: dayWindows(dayStart: dayStart),
            sleepIntervals: [], exerciseIntervals: [],
            dayStart: dayStart, dayEnd: dayEnd,
            inputRevision: 1, modelVersion: "hart-activity-v1",
            preprocessingVersion: "hart-activity-preprocess-v1",
            dataThrough: dayEnd)
        let epochs = (doc["epochs"] as? [[String: Any]]) ?? []
        XCTAssertFalse(epochs.isEmpty)
        XCTAssertTrue(epochs.allSatisfy { ($0["w"] as? String) == "unknown" },
                      "absence of wear evidence must keep every epoch unknown")
    }
}
