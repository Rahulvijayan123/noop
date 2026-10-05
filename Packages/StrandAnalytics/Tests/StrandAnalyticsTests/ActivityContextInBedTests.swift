import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The activity context and the sleep page describe one night the same way: asleep on the staged night's
/// sleep epochs, in bed (lying awake) on its wake epochs. Reported night: in bed at 01:47, asleep at 02:54;
/// the context said "Sitting quietly" at 2 a.m. while the sleep page said asleep.
final class ActivityContextInBedTests: XCTestCase {

    // MARK: Sleep epochs from the staged segments

    func testAsleepSpansAreTheNonWakeSegmentsJoinedWhereTheyTouch() {
        let json = """
        [{"start":100,"end":200,"stage":"wake"},{"start":200,"end":300,"stage":"light"},
         {"start":300,"end":400,"stage":"deep"},{"start":400,"end":450,"stage":"wake"},
         {"start":450,"end":600,"stage":"rem"}]
        """
        XCTAssertEqual(DayStateSpan.asleep(stagesJSON: json, start: 100, end: 600),
                       [DayStateSpan(start: 200, end: 400), DayStateSpan(start: 450, end: 600)])
    }

    func testAsleepSpansAreClippedToTheNightWindow() {
        let json = #"[{"start":0,"end":500,"stage":"light"}]"#
        XCTAssertEqual(DayStateSpan.asleep(stagesJSON: json, start: 100, end: 300), [DayStateSpan(start: 100, end: 300)])
    }

    func testANightWithoutATimelineIsAsleepForItsWholeWindow() {
        let imported = #"{"light":200,"deep":60,"rem":90,"awake":20}"#
        XCTAssertEqual(DayStateSpan.asleep(stagesJSON: imported, start: 10, end: 20), [DayStateSpan(start: 10, end: 20)])
        XCTAssertEqual(DayStateSpan.asleep(stagesJSON: nil, start: 10, end: 20), [DayStateSpan(start: 10, end: 20)])
    }

    func testAnAllWakeNightHasNoSleep() {
        let json = #"[{"start":0,"end":500,"stage":"wake"}]"#
        XCTAssertEqual(DayStateSpan.asleep(stagesJSON: json, start: 0, end: 500), [])
    }

    // MARK: Through the decoder

    /// Twenty minutes at a desk, forty lying awake in bed with the phone (a wrist that reads desk-like and
    /// seated), then an hour asleep.
    func testLyingAwakeInBedIsRestingInBedAndTheSleepEpochsAreAsleep() {
        var sim = ActivitySim()
        sim.desk(20 * 60)
        let bed = sim.ts
        sim.desk(40 * 60)
        let asleepAt = sim.ts
        sim.still(60 * 60, dyn: 0.006)
        let end = sim.ts
        var input = sim.trackInput(sleep: [DayStateSpan(start: asleepAt, end: end)])
        input.inBed = [DayStateSpan(start: bed, end: end)]
        let track = ActivityContextTrackBuilder.build(input)

        // Skip the first minute after each boundary: the label holds its wording for up to 30 s.
        func states(_ lo: Int, _ hi: Int) -> [ActivityContextState] {
            track.states.filter { $0.ts >= lo + 60 && $0.ts < hi }
        }
        let awakeInBed = states(bed, asleepAt)
        XCTAssertFalse(awakeInBed.isEmpty)
        XCTAssertTrue(awakeInBed.allSatisfy { $0.sleep.state == .awake && $0.sleep.inBed })
        XCTAssertEqual(Set(awakeInBed.compactMap(\.displayContext)).subtracting(["Changing position"]),
                       ["Resting in bed"])
        XCTAssertEqual(ActivityClassifier.classify(state: awakeInBed[awakeInBed.count / 2]).activityClass, .lyingDown)

        let asleep = states(asleepAt, end)
        XCTAssertTrue(asleep.allSatisfy { $0.sleep.state == .asleep && $0.sleep.inBed })
        XCTAssertEqual(Set(asleep.compactMap(\.displayContext)), ["Asleep"])

        let beforeBed = states(track.states.first?.ts ?? bed, bed)
        XCTAssertFalse(beforeBed.contains { $0.sleep.inBed || $0.displayContext == "Resting in bed" },
                       "the desk before bed is not in bed")

        let runs = ActivityContextRuns.coalesce(track.states)
        XCTAssertTrue(runs.contains { $0.inBed && $0.sleep == .awake && $0.displayContext == "Resting in bed" })
    }

    func testInBedSurvivesTheRunJSONAndOldRunsReadAsNotInBed() throws {
        var sim = ActivitySim()
        sim.desk(10 * 60)
        var input = sim.trackInput()
        input.inBed = [DayStateSpan(start: input.dayStart, end: input.dayEnd)]
        let runs = ActivityContextRuns.coalesce(ActivityContextTrackBuilder.build(input).states)
        let run = try XCTUnwrap(runs.last { $0.inBed })
        let back = try JSONDecoder().decode(ActivityContextRun.self, from: JSONEncoder().encode(run))
        XCTAssertTrue(back.inBed)

        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        old.removeValue(forKey: "in_bed")
        let legacy = try JSONDecoder().decode(ActivityContextRun.self,
                                              from: JSONSerialization.data(withJSONObject: old))
        XCTAssertFalse(legacy.inBed)
    }

    func testChangingTheInBedWindowRedecodesTheDay() {
        var sim = ActivitySim()
        sim.desk(10 * 60)
        let input = sim.trackInput()
        var moved = input
        moved.inBed = [DayStateSpan(start: input.dayStart + 60, end: input.dayEnd)]
        XCTAssertNotEqual(ActivityContextDayBuilder.fingerprint(input, through: input.dayEnd),
                          ActivityContextDayBuilder.fingerprint(moved, through: input.dayEnd))
    }
}
