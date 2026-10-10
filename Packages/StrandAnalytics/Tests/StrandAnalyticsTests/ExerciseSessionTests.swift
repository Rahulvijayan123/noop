import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Rule `exercise-session-2`: the Swift implementation must reproduce the shared parity fixture exactly
/// (contracts/reference/exercise-session-2.json, written by contracts/reference/exercise_session_2.py).
final class ExerciseSessionTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Session: Decodable, Equatable {
                var start: Int
                var end: Int
                var recovery_end: Int
                var pre_reference: Double
                var confirmed: Bool
                var confirmed_at: Int?
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
            .appendingPathComponent("contracts/reference/exercise-session-2.json")
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
                XCTAssertEqual(g.confirmed, e.confirmed, c.name)
                XCTAssertEqual(g.confirmedAtUnix, e.confirmed_at, c.name)
                XCTAssertFalse(g.open, c.name)
            }
        }
        // The fixture exercises every -2 path: unconfirmed, confirmed at the 15th strong minute, inherited, expired.
        XCTAssertTrue(fx.cases.contains { $0.sessions.contains { !$0.confirmed } })
        XCTAssertTrue(fx.cases.contains { c in c.sessions.contains { $0.confirmed && $0.confirmed_at == $0.start } })
    }

    private func minutes(_ c: Fixture.Case) -> [ExerciseSessionMinute] {
        c.hr.indices.map { i in
            ExerciseSessionMinute(minuteUnix: c.t0 + i * 60, hr: c.hr[i], strong: c.strong[i] == 1, weak: c.weak[i] == 1)
        }
    }

    /// An unconfirmed session (4 strong minutes over 25) is `active` once it has ended: no recovery follows it.
    func testUnconfirmedSessionIsActiveWithNoRecovery() throws {
        let fx = try fixture()
        let c = try XCTUnwrap(fx.cases.first { $0.name == "late_night_low_movement_4_strong" })
        let spans = ExerciseSessionRule.sessions(minutes: minutes(c), restReference: c.rest_reference)
        XCTAssertEqual(spans.count, 1)
        XCTAssertFalse(spans[0].confirmed)
        XCTAssertNil(spans[0].confirmedAtUnix)
        let phases = ExerciseSessionRule.phases(spans, fromUnix: c.t0, toUnix: c.t0 + c.hr.count * 60)
        XCTAssertEqual(phases[39], .none)
        XCTAssertTrue(phases[40...64].allSatisfy { $0 == .active })
        XCTAssertTrue(phases[65...].allSatisfy { $0 == .none }, "no recovery after an unconfirmed session")
        XCTAssertFalse(phases.contains(.session))
        XCTAssertFalse(phases.contains(.recovery))
    }

    /// Live opening is unchanged: the same period is `session` while it is open (confirmed or not), and `active` once
    /// it has closed unconfirmed.
    func testOpenSessionIsSessionUntilItEndsUnconfirmed() throws {
        let fx = try fixture()
        let c = try XCTUnwrap(fx.cases.first { $0.name == "late_night_low_movement_4_strong" })
        let all = minutes(c)
        // Minute 60: the period's last strong minute is 56, so it is still open.
        let liveNow = c.t0 + 60 * 60
        let live = ExerciseSessionRule.sessions(minutes: Array(all.prefix(60)), restReference: c.rest_reference,
                                                nowUnix: liveNow)
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(live[0].open)
        XCTAssertFalse(live[0].confirmed)
        XCTAssertEqual(ExerciseSessionRule.phases(live, fromUnix: c.t0 + 40 * 60, toUnix: liveNow),
                       Array(repeating: .session, count: 20))
        // Minute 76: the last evidence minute (64) is more than 10 minutes old: closed, unconfirmed.
        let laterNow = c.t0 + 76 * 60
        let closed = ExerciseSessionRule.sessions(minutes: Array(all.prefix(76)), restReference: c.rest_reference,
                                                  nowUnix: laterNow)
        XCTAssertEqual(closed.count, 1)
        XCTAssertFalse(closed[0].open)
        XCTAssertEqual(closed[0].recoveryEndUnix, c.t0 + 65 * 60)
        let phases = ExerciseSessionRule.phases(closed, fromUnix: c.t0 + 40 * 60, toUnix: laterNow)
        XCTAssertTrue(phases.prefix(25).allSatisfy { $0 == .active })
        XCTAssertTrue(phases.dropFirst(25).allSatisfy { $0 == .none })
    }

    /// An open session is confirmed live at its 15th strong minute.
    func testOpenSessionConfirmsAtTheFifteenthStrongMinute() {
        let t0 = 1_790_000_040 - 1_790_000_040 % 60
        var all: [ExerciseSessionMinute] = (0..<80).map {
            ExerciseSessionMinute(minuteUnix: t0 + $0 * 60, hr: 72, strong: false, weak: false)
        }
        for i in 30..<80 { all[i] = ExerciseSessionMinute(minuteUnix: t0 + i * 60, hr: 125, strong: i % 2 == 0, weak: i % 2 == 1) }
        // Strong minutes 30, 32, …: the 15th is minute 58.
        let before = ExerciseSessionRule.sessions(minutes: Array(all.prefix(58)), restReference: 72, nowUnix: t0 + 58 * 60)
        XCTAssertEqual(before.count, 1)
        XCTAssertTrue(before[0].open)
        XCTAssertFalse(before[0].confirmed)
        let at = ExerciseSessionRule.sessions(minutes: Array(all.prefix(59)), restReference: 72, nowUnix: t0 + 59 * 60)
        XCTAssertTrue(at[0].confirmed)
        XCTAssertEqual(at[0].confirmedAtUnix, t0 + 58 * 60)
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
        let spans = ExerciseSessionRule.sessions(minutes: minutes(c), restReference: c.rest_reference)
        XCTAssertTrue(spans[0].confirmed)
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
        // Rule exercise-session-2: unconfirmed sessions never form a routine (nor the in-session ceiling).
        let unconfirmed = spans.map { s -> ExerciseSessionSpan in
            var u = s; u.confirmed = false; u.confirmedAtUnix = nil; return u
        }
        let none = ExerciseRoutine.build(unconfirmed, nowUnix: now, calendar: cal)
        XCTAssertTrue(none.clusters.isEmpty)
        XCTAssertEqual(none.sessionCount, 0)
        XCTAssertEqual(ExerciseRoutine.build(spans + unconfirmed, nowUnix: now, calendar: cal).sessionCount, 4)
    }

    /// A span stored before -2 (no `confirmed`) decodes as confirmed: every -1 session had a recovery.
    func testSpanDecodesLeniently() throws {
        let old = #"{"startUnix":60,"endUnix":600,"recoveryEndUnix":900,"preReference":70,"open":false,"load":10}"#
        let span = try JSONDecoder().decode(ExerciseSessionSpan.self, from: Data(old.utf8))
        XCTAssertTrue(span.confirmed)
        XCTAssertNil(span.confirmedAtUnix)
        var now = span
        now.confirmed = false
        let round = try JSONDecoder().decode(ExerciseSessionSpan.self, from: JSONEncoder().encode(now))
        XCTAssertEqual(round, now)
    }

    /// The earliest second a re-decode changed the interval evidence of (the live evidence cache re-reads from it).
    func testEarliestEvidenceChange() {
        func row(_ s: Int, _ e: Int, _ cls: String, intensity: Double = 0.05) -> ActivityContextIntervalRow {
            ActivityContextIntervalRow(startTs: s, endTs: e, activityClass: cls, confidence: 0.8, evidenceQuality: 0.8,
                                       sleepState: "awake", wearState: "on_wrist", intensity: intensity)
        }
        let old = [row(0, 600, "sitting"), row(600, 1200, "sitting"), row(1200, 1800, "sitting")]
        XCTAssertNil(ExerciseSessionRule.earliestEvidenceChange(old: old, new: old))
        // A confidence change alone does not change evidence.
        var tweak = old
        tweak[1].confidence = 0.5
        XCTAssertNil(ExerciseSessionRule.earliestEvidenceChange(old: old, new: tweak))
        // A class rewrite in the middle.
        var rewritten = old
        rewritten[1].activityClass = "vigorous_activity"
        XCTAssertEqual(ExerciseSessionRule.earliestEvidenceChange(old: old, new: rewritten), 600)
        // New rows appended after the old ones.
        XCTAssertEqual(ExerciseSessionRule.earliestEvidenceChange(old: old, new: old + [row(1800, 2400, "walking")]), 1800)
        // A boundary moved.
        let moved = [row(0, 600, "sitting"), row(600, 1000, "sitting"), row(1000, 1800, "light_activity")]
        XCTAssertEqual(ExerciseSessionRule.earliestEvidenceChange(old: old, new: moved), 600)
        // Nothing stored before.
        XCTAssertEqual(ExerciseSessionRule.earliestEvidenceChange(old: [], new: old), 0)
    }
}
