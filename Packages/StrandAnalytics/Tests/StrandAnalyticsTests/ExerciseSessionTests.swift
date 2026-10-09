import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Rule `exercise-session-1`: the Swift implementation must reproduce the shared parity fixture exactly
/// (contracts/reference/exercise-session-1.json, written by contracts/reference/exercise_session_1.py).
final class ExerciseSessionTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Session: Decodable, Equatable {
                var start: Int
                var end: Int
                var recovery_end: Int
                var pre_reference: Double
            }
            var name: String
            var t0: Int
            var rest_reference: Double
            var hr: [Double?]
            var strong: [Int]
            var weak: [Int]
            var sessions: [Session]
        }
        var rule: String
        var cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/reference/exercise-session-1.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testParityWithSharedFixture() throws {
        let fx = try fixture()
        XCTAssertEqual(fx.rule, ExerciseSessionRule.rule)
        XCTAssertFalse(fx.cases.isEmpty)
        for c in fx.cases {
            let minutes = c.hr.indices.map { i in
                ExerciseSessionMinute(minuteUnix: c.t0 + i * 60, hr: c.hr[i],
                                      strong: c.strong[i] == 1, weak: c.weak[i] == 1)
            }
            let got = ExerciseSessionRule.sessions(minutes: minutes, restReference: c.rest_reference)
            XCTAssertEqual(got.count, c.sessions.count, c.name)
            for (g, e) in zip(got, c.sessions) {
                XCTAssertEqual(g.startUnix, e.start, c.name)
                XCTAssertEqual(g.endUnix, e.end, c.name)
                XCTAssertEqual(g.recoveryEndUnix, e.recovery_end, c.name)
                XCTAssertEqual(g.preReference, e.pre_reference, accuracy: 1e-6, c.name)
                XCTAssertFalse(g.open, c.name)
            }
        }
    }

    func testOpenSessionCountsBeforeTwelveMinutesAndHasNoRecoveryEnd() {
        let t0 = 1_790_000_040 - 1_790_000_040 % 60
        var minutes: [ExerciseSessionMinute] = (0..<40).map {
            ExerciseSessionMinute(minuteUnix: t0 + $0 * 60, hr: 72, strong: false, weak: false)
        }
        for i in 30..<40 { minutes[i] = ExerciseSessionMinute(minuteUnix: t0 + i * 60, hr: 120, strong: true, weak: false) }
        let now = t0 + 40 * 60
        let live = ExerciseSessionRule.sessions(minutes: minutes, restReference: 72, nowUnix: now)
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(live[0].open)
        XCTAssertNil(live[0].recoveryEndUnix)
        XCTAssertEqual(ExerciseSessionRule.phases(live, fromUnix: now - 300, toUnix: now), Array(repeating: .session, count: 5))
        // The same ten minutes, finished long ago, are too short to be a session.
        XCTAssertTrue(ExerciseSessionRule.sessions(minutes: minutes, restReference: 72).isEmpty)
    }

    func testStillHighHeartRateNeverOpensASession() {
        let t0 = 1_790_000_040 - 1_790_000_040 % 60
        let minutes = (0..<90).map { ExerciseSessionMinute(minuteUnix: t0 + $0 * 60, hr: 135, strong: false, weak: false) }
        XCTAssertTrue(ExerciseSessionRule.sessions(minutes: minutes, restReference: 70, nowUnix: t0 + 90 * 60).isEmpty)
    }

    func testRecoveryPhasesFollowTheSession() throws {
        let fx = try fixture()
        let c = try XCTUnwrap(fx.cases.first { $0.name == "gym_sets_with_leg_work" })
        let minutes = c.hr.indices.map { i in
            ExerciseSessionMinute(minuteUnix: c.t0 + i * 60, hr: c.hr[i], strong: c.strong[i] == 1, weak: c.weak[i] == 1)
        }
        let spans = ExerciseSessionRule.sessions(minutes: minutes, restReference: c.rest_reference)
        let phases = ExerciseSessionRule.phases(spans, fromUnix: c.t0, toUnix: c.t0 + c.hr.count * 60)
        XCTAssertEqual(phases[49], .none)
        XCTAssertEqual(phases[50], .session)
        XCTAssertEqual(phases[112], .session, "still leg work inside the session stays session")
        XCTAssertEqual(phases[117], .recovery)
        XCTAssertEqual(phases[147], .recovery)
        XCTAssertEqual(phases[148], .none)
    }

    func testIntervalEvidence() {
        func row(_ cls: String, loco: String? = nil, arm: String? = nil, intensity: Double? = nil,
                 sleep: String = "awake", wear: String = "on_wrist") -> ActivityContextIntervalRow {
            var r = ActivityContextIntervalRow(startTs: 0, endTs: 60, activityClass: cls, confidence: 0.8,
                                               evidenceQuality: 0.8, sleepState: sleep, wearState: wear)
            r.locomotion = loco; r.armBehavior = arm; r.intensity = intensity
            return r
        }
        XCTAssertTrue(ExerciseSessionRule.evidence(of: row("brisk_walking")).strong)
        XCTAssertTrue(ExerciseSessionRule.evidence(of: row("stationary", loco: "running")).strong)
        XCTAssertTrue(ExerciseSessionRule.evidence(of: row("standing", arm: "exercise_motion")).strong)
        XCTAssertTrue(ExerciseSessionRule.evidence(of: row("fidgeting", intensity: 0.5)).strong)
        XCTAssertTrue(ExerciseSessionRule.evidence(of: row("light_activity")).weak)
        XCTAssertFalse(ExerciseSessionRule.evidence(of: row("sitting", intensity: 0.3)).weak)
        XCTAssertFalse(ExerciseSessionRule.evidence(of: row("walking", loco: "walking", wear: "off_wrist")).strong)
        XCTAssertFalse(ExerciseSessionRule.evidence(of: row("running", sleep: "asleep")).strong)
    }

    func testRoutineGroupsWeekdayEveningsAndNeverWithoutSessions() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Mon 2026-10-05 … Thu 10-08, sessions at ~21:50 local.
        let days = ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08"]
        let spans: [ExerciseSessionSpan] = days.enumerated().map { i, d in
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
            let start = Int(f.date(from: "\(d) 21:\(45 + i)")!.timeIntervalSince1970)
            return ExerciseSessionSpan(startUnix: start, endUnix: start + 80 * 60, recoveryEndUnix: start + 110 * 60,
                                       preReference: 77, open: false, hrP50: 108, hrP90: 132, hrPeak: 148, load: 2000)
        }
        let now = spans.last!.endUnix + 3600
        let routine = ExerciseRoutine.build(spans, nowUnix: now, calendar: cal)
        XCTAssertEqual(routine.clusters.count, 1)
        let c = routine.clusters[0]
        XCTAssertEqual(c.dayType, "weekday")
        XCTAssertEqual(c.sessions, 4)
        XCTAssertTrue(c.active)
        XCTAssertNotNil(routine.match(startUnix: spans[0].startUnix + 7 * 86_400, calendar: cal))
        XCTAssertTrue(ExerciseRoutine.build([], nowUnix: now, calendar: cal).clusters.isEmpty)
    }
}
