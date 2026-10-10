import XCTest
import WhoopStore
@testable import Strand

/// The activity-context intervals the phone sends for the server's Layer 1 baselines (POST scores/context-intervals):
/// grouped by UTC day of their start, shaped as the route accepts them, fingerprinted stably.
final class WatchdogContextIntervalSyncTests: XCTestCase {
    private let day = 1_789_948_800

    private func row(_ start: Int, _ end: Int, cls: String = "sitting", posture: String? = "seated_likely",
                     hrMean: Double? = 70.5, detail: String? = nil) -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(startTs: start, endTs: end, activityClass: cls, confidence: 0.9,
                                   evidenceQuality: 0.8, posture: posture, locomotion: "stationary",
                                   armBehavior: "exercise_motion", sleepState: "awake", wearState: "on_wrist",
                                   intensity: 0.1, hrSamples: 590, hrMean: hrMean, rmssd: 40, rrBeats: 700,
                                   rrDiffSqSumMs2: 1_120_000, rrDiffCount: 700, detail: detail)
    }

    func testRowsAreGroupedByUTCDayAndShapedForTheRoute() {
        let rows = [
            row(day - 600, day),                                  // before the range
            row(day + 60, day + 120, detail: "in_vehicle"),
            row(day + 60, day + 180, cls: "walking"),             // same start: the later row wins
            row(day + 300, day + 200),                            // ends before it starts
            row(day + 400, day + 400 + 2 * 86_400),               // longer than a day
            row(day + 86_400 + 5, day + 86_400 + 65, posture: "drop table;", hrMean: .nan),
        ]
        let days = WatchdogServerSync.contextDays(rows: rows, from: day, through: day + 86_400)
        XCTAssertEqual(Set(days.keys), [day, day + 86_400])
        XCTAssertEqual(days[day]?.map(\.start_ts), [day + 60])
        XCTAssertEqual(days[day]?.first?.activity_class, "walking")
        XCTAssertEqual(days[day]?.first?.arm_behavior, "exercise_motion")
        let next = days[day + 86_400]?.first
        XCTAssertNil(next?.posture, "a label the route would refuse is sent as absent")
        XCTAssertNil(next?.hr_mean, "a non-finite number is sent as absent")
        XCTAssertEqual(next?.detail, nil)
    }

    func testTheFingerprintIsStableAndFollowsContentAndVersion() {
        let a = WatchdogServerSync.contextDays(rows: [row(day, day + 60)], from: day, through: day)[day] ?? []
        let b = WatchdogServerSync.contextDays(rows: [row(day, day + 60, hrMean: 71)], from: day, through: day)[day] ?? []
        let f = WatchdogServerSync.fingerprint(a, version: "lb-context-3")
        XCTAssertEqual(f, WatchdogServerSync.fingerprint(a, version: "lb-context-3"))
        XCTAssertEqual(f.count, 64)
        XCTAssertNotEqual(f, WatchdogServerSync.fingerprint(b, version: "lb-context-3"))
        XCTAssertNotEqual(f, WatchdogServerSync.fingerprint(a, version: "lb-context-4"))
    }
}
