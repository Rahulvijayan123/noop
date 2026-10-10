import XCTest
import StrandAnalytics
@testable import frwhoop_worker

/// Workout mode's typed log in the activity lane (docs/context-watchdog/WORKOUTS.md): merged into the session records,
/// and recorded on the ElderNet gait row as context for its windows.
final class LoggedWorkoutsTests: XCTestCase {
    let t0 = 1_790_305_200

    func testMergeReplacesTheSameWorkoutsRecordAndCarriesTheTypesSportName() {
        let sessions = [(start: t0 + 30, end: t0 + 2700, sport: "Other"),        // the live tracker's row
                        (start: t0 + 7200, end: t0 + 9000, sport: "Running")]
        let logged = [LoggedWorkout(start: t0, end: t0 + 2700, typeId: "indoor_walk", ref: "a"),
                      LoggedWorkout(start: t0 + 10_000, end: t0 + 11_000, typeId: "no_such_type", ref: "b")]
        let merged = LoggedWorkouts.merge(sessions: sessions, logged: logged)
        XCTAssertEqual(merged.map(\.start), [t0, t0 + 7200])
        XCTAssertEqual(merged.map(\.sport), ["Treadmill walk", "Running"])
        XCTAssertEqual(WorkoutKind(sport: merged[0].sport), .walking, "the decoder reads the type's kind")
        XCTAssertEqual(LoggedWorkouts.merge(sessions: sessions, logged: []).map(\.sport), ["Other", "Running"],
                       "no logged workouts: the session records as before")
    }

    func testGaitContextLabelsTheWindowsInsideEachWorkout() throws {
        func window(_ s: Int, gait: Bool) -> GaitQualityWindow {
            GaitQualityWindow(startTs: s, endTs: s + 10, gaitProb: gait ? 0.9 : 0.1, isGait: gait, prefiltered: false)
        }
        let windows = [window(t0 - 20, gait: true), window(t0, gait: true), window(t0 + 10, gait: false),
                       window(t0 + 600, gait: true), window(t0 + 1200, gait: true)]
        let workouts = [LoggedWorkout(start: t0, end: t0 + 900, typeId: "indoor_cycling", ref: "a"),
                        LoggedWorkout(start: t0 + 1000, end: t0 + 1800, typeId: "indoor_walk", ref: "b")]
        let ctx = LoggedWorkouts.gaitContext(workouts: workouts, windows: windows)
        XCTAssertEqual(ctx.map(\.nWindows), [3, 1])
        XCTAssertEqual(ctx.map(\.nGait), [2, 1])
        XCTAssertEqual(ctx.map(\.gaitLabel), ["unexpected_gait", "expected_gait"],
                       "gait during a ride is flagged; during an indoor walk it is expected")
        XCTAssertEqual(ctx[0].environment, "indoor")
        XCTAssertEqual(ctx[0].armMotion, "fixed")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ctx[0])) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["start", "end", "type", "environment", "locomotion", "effort", "gait_expected",
                                        "arm_motion", "steps_expected", "n_windows", "n_gait", "gait_label"])
    }
}
