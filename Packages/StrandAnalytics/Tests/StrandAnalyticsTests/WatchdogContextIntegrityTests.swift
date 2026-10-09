import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// WP8: Watchdog / Layer-1 awake-rest usuals must not invent context the sensors did not measure.
final class WatchdogContextIntegrityTests: XCTestCase {
    private let base = 97_000_000 - 97_000_000 % 60

    private func stillImu(from: Int, to: Int) -> [WatchdogIMUSample] {
        (from..<to).map { WatchdogIMUSample(ts: $0, x: 0, y: 0, z: 1, dynAccel: 0.01) }
    }

    // MARK: HR-only Auto Workout relabel (D6-08)

    func testHROnlyWorkoutBoutDoesNotTiltStillMinutesTowardWalk() throws {
        let now = base
        var feed = Watchdog.syntheticFeed(now: now, hr: 120, hrv: 44, temp: 33.0, resp: 14, motion: 0.02)
        feed.imu = stillImu(from: now - WatchdogConfig.contextSeconds, to: now)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else { return XCTFail("window") }
        XCTAssertEqual(win.autoWorkoutOverlap.last, 1, "HR alone still fires the Auto Workout bit")
        let walk = WatchdogActivityClass.walk.index
        for row in win.activityLogits {
            XCTAssertEqual(row[walk], 0, "sustained HR 120 on a still wrist must not add walk mass")
        }
        XCTAssertEqual(WatchdogActivityClass.labels(logits: win.activityLogits).last, "still")
    }

    func testHROnlyWorkoutBoutLeavesNoImuMinutesUnknown() {
        let now = base
        var feed = Watchdog.syntheticFeed(now: now, hr: 120, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        feed.motion = []
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else { return XCTFail("window") }
        let unknown = WatchdogActivityClass.unknown.index
        for row in win.activityLogits {
            XCTAssertEqual(row[unknown], 1, "no motion evidence stays unknown, never HR-inferred walk")
        }
    }

    func testAutoWorkoutOverlapStillRelabelsWhenMotionCorroborates() {
        var tie = Array(repeating: 0.0, count: WatchdogActivityClass.count)
        tie[WatchdogActivityClass.still.index] = 0.5
        tie[WatchdogActivityClass.resistance.index] = 0.5
        let uncorroborated = WatchdogActivityRuntime.applyAutoWorkoutOverlap([tie], overlap: [1],
                                                                            corroborated: [false])
        XCTAssertEqual(uncorroborated, [tie], "a blended quiet row must not flip to walk on HR alone")
        XCTAssertEqual(WatchdogActivityRuntime.applyAutoWorkoutOverlap([tie], overlap: [1]), [tie])
        let corroborated = WatchdogActivityRuntime.applyAutoWorkoutOverlap([tie], overlap: [1],
                                                                          corroborated: [true])
        XCTAssertEqual(WatchdogActivityClass.labels(logits: corroborated), ["walk"])
    }

    func testMotionCorroborationNeedsLocomotionStepsOrWalkFloorMotion() {
        let start = base - 180
        let moving = WatchdogActivityRuntime.motionCorroboratesLocomotion(
            motion: [0.02, 0.25, nil],
            steps: [StepSample(ts: start + 130, counter: 1, activityClass: 1),
                    StepSample(ts: start + 10, counter: 2, activityClass: 0)],
            startUnix: start, nowUnix: base)
        XCTAssertEqual(moving, [false, true, true])
    }
}
