import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The live exercise-session evidence cache (`WatchdogExerciseEvidence`): it re-reads only the trailing 15 minutes on
/// each tick, so a decoder interval a re-decode rewrote further back (HART-fused intervals land 5–80 minutes late)
/// must reach it through `intervalsRewritten`.
@MainActor
final class WatchdogExerciseEvidenceTests: XCTestCase {

    private func row(_ start: Int, _ end: Int, _ cls: String, intensity: Double) -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(startTs: start, endTs: end, activityClass: cls, confidence: 0.9, evidenceQuality: 0.9,
                                   sleepState: "awake", wearState: "on_wrist", intensity: intensity)
    }

    private final class Rows {
        var value: [ActivityContextIntervalRow] = []
    }

    private func read(_ evidence: WatchdogExerciseEvidence, store: WhoopStore, rows: Rows,
                      at now: Int) async -> [Int: ExerciseSessionMinute] {
        let snapshot = rows.value
        let out = await evidence.history(store: store, readIds: ["ev-test"], key: "ev-test", now: now) { from, to in
            snapshot.filter { $0.endTs > from - 600 && $0.startTs < to }
        }
        return Dictionary(out.map { ($0.minuteUnix, $0) }, uniquingKeysWith: { _, b in b })
    }

    func testADecoderIntervalRewrittenFortyMinutesBackChangesThatMinutesEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let now = 1_790_000_000 - 1_790_000_000 % 60
        let target = now - 40 * 60
        let rows = Rows()
        rows.value = [row(now - 5 * 3600, now + 3600, "sitting", intensity: 0.05)]
        let evidence = WatchdogExerciseEvidence()

        let first = await read(evidence, store: store, rows: rows, at: now)
        XCTAssertEqual(first[target]?.strong, false)
        XCTAssertEqual(first[target]?.weak, false)

        // A re-decode rewrites the minute 40 minutes back as vigorous activity.
        rows.value = [row(now - 5 * 3600, target, "sitting", intensity: 0.05),
                      row(target, target + 60, "vigorous_activity", intensity: 0.6),
                      row(target + 60, now + 3600, "sitting", intensity: 0.05)]
        let stale = await read(evidence, store: store, rows: rows, at: now + 60)
        XCTAssertEqual(stale[target]?.strong, false, "the trailing re-read alone never reaches 40 minutes back")

        evidence.intervalsRewritten(from: target)
        XCTAssertEqual(evidence.rewrittenFrom, target)
        let fresh = await read(evidence, store: store, rows: rows, at: now + 120)
        XCTAssertEqual(fresh[target]?.strong, true, "the rewritten interval reaches the live session evidence")
        XCTAssertEqual(fresh[target - 60]?.strong, false)
        XCTAssertNil(evidence.rewrittenFrom, "consumed by the refresh")

        // The earliest of several rewrites wins; nil ("not known where") re-reads the whole history.
        evidence.intervalsRewritten(from: now - 600)
        evidence.intervalsRewritten(from: nil)
        rows.value = [row(now - 5 * 3600, now + 3600, "light_activity", intensity: 0.42)]
        let all = await read(evidence, store: store, rows: rows, at: now + 180)
        XCTAssertEqual(all[now - 3 * 3600]?.weak, true)
        XCTAssertEqual(all[target]?.strong, false, "a minute whose evidence went away does not keep it")
    }
}
