import XCTest
import WhoopStore
import WhoopProtocol
@testable import StrandAnalytics

/// The catalogue `workout-types-1` must equal contracts/workout-types-1.json (the edge and SQL copies are pinned to the
/// same file by their own tests), and each type must map onto the decoder's existing sport reading.
final class WorkoutTypeCatalogTests: XCTestCase {
    private func contract() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/workout-types-1.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testTableEqualsContract() throws {
        let c = try contract()
        XCTAssertEqual(c["version"] as? String, WorkoutTypeCatalog.version)
        XCTAssertEqual(c["environments"] as? [String], WorkoutEnvironment.allCases.map(\.rawValue))
        XCTAssertEqual(c["locomotions"] as? [String], WorkoutLocomotion.allCases.map(\.rawValue))
        XCTAssertEqual(c["efforts"] as? [String], WorkoutEffort.allCases.map(\.rawValue))
        XCTAssertEqual(c["arm_motions"] as? [String], WorkoutArmMotion.allCases.map(\.rawValue))
        let types = try XCTUnwrap(c["types"] as? [[String: Any]])
        XCTAssertEqual(types.map { $0["id"] as? String }, WorkoutTypeCatalog.all.map(\.id), "same ids, same order")
        for (j, s) in zip(types, WorkoutTypeCatalog.all) {
            XCTAssertEqual(j["name"] as? String, s.name, s.id)
            XCTAssertEqual(j["sport_name"] as? String, s.sportName, s.id)
            XCTAssertEqual(j["decoder_kind"] as? String, s.decoderKind.rawValue, s.id)
            XCTAssertEqual(j["environment"] as? String, s.environment.rawValue, s.id)
            XCTAssertEqual(j["locomotion"] as? String, s.locomotion.rawValue, s.id)
            XCTAssertEqual(j["effort"] as? String, s.effort.rawValue, s.id)
            XCTAssertEqual(j["gait_expected"] as? Bool, s.gaitExpected, s.id)
            XCTAssertEqual(j["arm_motion"] as? String, s.armMotion.rawValue, s.id)
            XCTAssertEqual(j["steps_expected"] as? Bool, s.stepsExpected, s.id)
            XCTAssertEqual(j["sport_aliases"] as? [String], s.sportAliases, s.id)
        }
    }

    /// The catalogue maps onto the decoder's existing sport reading instead of a parallel one: the decoder reads a
    /// logged workout's kind from its stored sport name, and that is the kind the catalogue says.
    func testDecoderReadsEachTypesKindFromItsSportName() {
        for t in WorkoutTypeCatalog.all {
            XCTAssertEqual(WorkoutKind(sport: t.sportName), t.decoderKind, t.id)
        }
        XCTAssertEqual(WorkoutTypeCatalog.entry(id: "indoor_walk")?.decoderKind, .walking)
        XCTAssertEqual(WorkoutTypeCatalog.entry(id: "indoor_cycling")?.decoderKind, .cycling)
        XCTAssertEqual(WorkoutTypeCatalog.entry(id: "strength")?.effort, .resistance)
    }

    func testEverySportNameAndAliasResolvesToOneType() {
        var seen: [String: String] = [:]
        for t in WorkoutTypeCatalog.all {
            for name in [t.sportName] + t.sportAliases {
                XCTAssertNil(seen[name.lowercased()], "\(name) belongs to \(seen[name.lowercased()] ?? "") and \(t.id)")
                seen[name.lowercased()] = t.id
                XCTAssertEqual(WorkoutTypeCatalog.resolve(sport: name)?.id, t.id, name)
            }
        }
        XCTAssertEqual(WorkoutTypeCatalog.resolve(sport: "  treadmill WALK ")?.id, "indoor_walk")
        XCTAssertNil(WorkoutTypeCatalog.resolve(sport: "Golf"), "free text is not guessed into a type")
        XCTAssertNil(WorkoutTypeCatalog.resolve(sport: ""))
    }

    func testGaitLabels() {
        XCTAssertEqual(WorkoutTypeCatalog.entry(id: "indoor_walk")?.gaitLabel, "expected_gait")
        XCTAssertEqual(WorkoutTypeCatalog.entry(id: "indoor_cycling")?.gaitLabel, "unexpected_gait")
        XCTAssertEqual(WorkoutTypeCatalog.entry(id: "strength")?.gaitLabel, "unexpected_gait")
        XCTAssertEqual(WorkoutTypeCatalog.entry(id: "hiit")?.gaitLabel, "unlabelled")
    }
}

/// Workout mode's log: one workout at a time, change type, stop, the 4-hour cap, past workouts, deletes, the sync
/// bookkeeping and persistence (the log is what the app stores, so a running workout survives a relaunch).
final class WorkoutModeLogTests: XCTestCase {
    let t0 = 1_790_000_000

    func testStartChangeStop() throws {
        var log = WorkoutModeLog.empty
        let a = try log.start(typeId: "strength", now: t0, id: "a")
        XCTAssertEqual(log.active?.id, "a")
        XCTAssertTrue(a.needsSync)
        XCTAssertThrowsError(try log.start(typeId: "yoga", now: t0 + 60)) {
            XCTAssertEqual($0 as? WorkoutModeError, .alreadyRunning, "one workout at a time")
        }
        XCTAssertThrowsError(try log.start(typeId: "no_such_type", now: t0)) {
            XCTAssertEqual($0 as? WorkoutModeError, .unknownType)
        }
        try log.changeType("hiit", now: t0 + 600)
        XCTAssertEqual(log.active?.typeId, "hiit")
        XCTAssertEqual(log.active?.updatedUnix, t0 + 600)
        let stopped = try log.stop(now: t0 + 3600)
        XCTAssertEqual(stopped.endUnix, t0 + 3600)
        XCTAssertEqual(stopped.source, .manual)
        XCTAssertFalse(stopped.deleted)
        XCTAssertNil(log.active)
        XCTAssertThrowsError(try log.stop(now: t0 + 3700)) { XCTAssertEqual($0 as? WorkoutModeError, .notRunning) }
    }

    func testEditsInTheSameSecondStillMoveTheClock() throws {
        var log = WorkoutModeLog.empty
        try log.start(typeId: "strength", now: t0, id: "a")
        try log.changeType("hiit", now: t0)
        try log.changeType("yoga", now: t0)
        XCTAssertEqual(log.active?.updatedUnix, t0 + 2, "client_updated_at moves forward on every edit")
    }

    func testAccidentalStartIsDeleted() throws {
        var log = WorkoutModeLog.empty
        try log.start(typeId: "strength", now: t0, id: "a")
        let e = try log.stop(now: t0 + 30)
        XCTAssertTrue(e.deleted)
        XCTAssertTrue(log.spans(from: t0 - 60, to: t0 + 600, now: t0 + 600).isEmpty)
        XCTAssertEqual(log.pendingSync.map(\.id), ["a"], "the deletion is still sent (the start may have been)")
    }

    func testForgottenWorkoutEndsAtTheCap() throws {
        var log = WorkoutModeLog.empty
        try log.start(typeId: "outdoor_walk", now: t0, id: "a")
        XCTAssertNil(log.autoEndIfOverdue(now: t0 + 3 * 3600), "not yet")
        // While it runs, the pipelines see it up to now, never past the cap.
        XCTAssertEqual(log.spans(from: t0, to: t0 + 86_400, now: t0 + 5 * 3600).first?.endUnix,
                       t0 + WorkoutModeLog.maxOpenSeconds)
        let ended = try XCTUnwrap(log.autoEndIfOverdue(now: t0 + 5 * 3600))
        XCTAssertEqual(ended.endUnix, t0 + WorkoutModeLog.maxOpenSeconds)
        XCTAssertEqual(ended.source, .autoEnded)
        XCTAssertNil(log.active)
        // A new start closes a forgotten one first.
        var other = WorkoutModeLog.empty
        try other.start(typeId: "strength", now: t0, id: "x")
        try other.start(typeId: "yoga", now: t0 + 6 * 3600, id: "y")
        XCTAssertEqual(other.entries.first { $0.id == "x" }?.source, .autoEnded)
        XCTAssertEqual(other.active?.id, "y")
        // A late Stop of a forgotten one ends at the cap too.
        var late = WorkoutModeLog.empty
        try late.start(typeId: "strength", now: t0, id: "z")
        let s = try late.stop(now: t0 + 9 * 3600)
        XCTAssertEqual(s.endUnix, t0 + WorkoutModeLog.maxOpenSeconds)
        XCTAssertEqual(s.source, .autoEnded)
    }

    func testPastWorkoutsAndDeletes() throws {
        var log = WorkoutModeLog.empty
        try log.logPast(typeId: "indoor_cycling", startUnix: t0, endUnix: t0 + 2700, now: t0 + 9000, id: "p")
        XCTAssertThrowsError(try log.logPast(typeId: "yoga", startUnix: t0 + 600, endUnix: t0 + 1200, now: t0 + 9000)) {
            XCTAssertEqual($0 as? WorkoutModeError, .overlapsAnother)
        }
        XCTAssertThrowsError(try log.logPast(typeId: "yoga", startUnix: t0 + 9000, endUnix: t0 + 9600, now: t0 + 9000)) {
            XCTAssertEqual($0 as? WorkoutModeError, .invalidInterval, "never in the future")
        }
        XCTAssertThrowsError(try log.logPast(typeId: "yoga", startUnix: t0 - 13 * 3600, endUnix: t0 - 1, now: t0)) {
            XCTAssertEqual($0 as? WorkoutModeError, .invalidInterval, "at most 12 h")
        }
        try log.delete(id: "p", now: t0 + 9100)
        XCTAssertTrue(log.spans(from: t0, to: t0 + 9000, now: t0 + 9100).isEmpty)
        XCTAssertThrowsError(try log.delete(id: "p", now: t0 + 9200)) { XCTAssertEqual($0 as? WorkoutModeError, .notFound) }
    }

    func testSyncBookkeepingAndPrune() throws {
        var log = WorkoutModeLog.empty
        try log.start(typeId: "strength", now: t0, id: "a")
        let sent = Dictionary(log.pendingSync.map { ($0.id, $0.updatedUnix) }, uniquingKeysWith: { _, b in b })
        try log.stop(now: t0 + 3600)                     // edited while the upload was in flight
        log.markSynced(sent)
        XCTAssertEqual(log.pendingSync.map(\.id), ["a"], "a newer local edit stays pending")
        log.markSynced(["a": log.entries[0].updatedUnix])
        XCTAssertTrue(log.pendingSync.isEmpty)
        log.prune(now: t0 + 3600 + WorkoutModeLog.retentionSeconds + 1)
        XCTAssertTrue(log.entries.isEmpty, "synced and past retention: the server keeps it")
    }

    /// The app persists the log as JSON: a running workout comes back running after a relaunch.
    func testRunningWorkoutSurvivesARelaunch() throws {
        var log = WorkoutModeLog.empty
        try log.start(typeId: "indoor_walk", now: t0, id: "a")
        let data = try JSONEncoder().encode(log)
        let back = try JSONDecoder().decode(WorkoutModeLog.self, from: data)
        XCTAssertEqual(back, log)
        XCTAssertEqual(back.active?.typeId, "indoor_walk")
        XCTAssertEqual(back.spans(from: t0, to: t0 + 3600, now: t0 + 1800),
                       [LoggedWorkoutSpan(startUnix: t0, endUnix: t0 + 1800, typeId: "indoor_walk", open: true)])
    }

    func testServerBody() throws {
        var log = WorkoutModeLog.empty
        try log.start(typeId: "strength", now: t0, id: "a")
        var body = WorkoutModeLog.serverBody(log.entries, deviceId: "whoop-MG1", localDeviceId: "my-whoop")
        XCTAssertEqual(body["device_id"] as? String, "whoop-MG1")
        XCTAssertEqual(body["local_device_id"] as? String, "my-whoop")
        XCTAssertEqual(body["catalogue_version"] as? String, "workout-types-1")
        var w = try XCTUnwrap((body["workouts"] as? [[String: Any]])?.first)
        XCTAssertEqual(w["client_id"] as? String, "a")
        XCTAssertEqual(w["type"] as? String, "strength")
        XCTAssertEqual(w["started_at"] as? Int, t0)
        XCTAssertTrue(w["ended_at"] is NSNull, "open")
        XCTAssertEqual(w["source"] as? String, "manual")
        XCTAssertEqual(w["deleted"] as? Bool, false)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
        _ = log.autoEndIfOverdue(now: t0 + 5 * 3600)
        body = WorkoutModeLog.serverBody(log.entries, deviceId: "whoop-MG1", localDeviceId: nil)
        w = try XCTUnwrap((body["workouts"] as? [[String: Any]])?.first)
        XCTAssertEqual(w["ended_at"] as? Int, t0 + 4 * 3600)
        XCTAssertEqual(w["source"] as? String, "auto_ended")
        XCTAssertNil(body["local_device_id"])
    }
}

/// What a logged workout does to the session rule, the decoder input and the Watchdog.
final class LoggedWorkoutContextTests: XCTestCase {
    let t0 = 1_790_000_000 - 1_790_000_000 % 60

    /// A still arm at gym heart rate is no movement evidence, so the rule alone never opens a session. Logged, every
    /// minute is strong evidence: the rule finds a confirmed session, and the window minutes are `session` at once.
    func testLoggedStrengthWithAStillArmIsAConfirmedSession() {
        let minutes = (0..<90).map { i in
            ExerciseSessionMinute(minuteUnix: t0 + i * 60, hr: i < 30 ? 68 : 112, strong: false, weak: false)
        }
        let now = t0 + 90 * 60
        let plain = WatchdogExerciseContext.build(minutes: minutes, windowStart: now - 60 * 60, seqLen: 60,
                                                  nowUnix: now, evaluations: [])
        XCTAssertTrue(plain.spans.isEmpty)
        XCTAssertTrue(plain.phases.allSatisfy { $0 == .none })

        let logged = [LoggedWorkoutSpan(startUnix: t0 + 30 * 60, endUnix: now, typeId: "strength", open: true)]
        let ex = WatchdogExerciseContext.build(minutes: minutes, windowStart: now - 60 * 60, seqLen: 60,
                                               nowUnix: now, evaluations: [], logged: logged)
        XCTAssertEqual(ex.spans.count, 1)
        XCTAssertEqual(ex.spans.first?.startUnix, t0 + 30 * 60)
        XCTAssertEqual(ex.spans.first?.confirmed, true, "every logged minute is strong: confirmed at its 15th")
        XCTAssertTrue(ex.phases.allSatisfy { $0 == .session })
        let snap = WatchdogExerciseSnapshot.make(ex, evaluations: [], nowUnix: now - 1)
        XCTAssertEqual(snap.phase, "session")
        XCTAssertEqual(snap.basis, "logged")
        XCTAssertEqual(snap.workoutType, "strength")
        XCTAssertEqual(snap.confirmed, true)
        XCTAssertEqual(snap.sessionStartUnix, t0 + 30 * 60)
    }

    /// Logged minutes are a session from the first minute, before the load check could open one, and a light logged
    /// workout (no load) is still a session while it runs; the minutes after it are judged as before.
    func testLoggedMinutesAreASessionFromTheFirstMinute() {
        let minutes = (0..<40).map { ExerciseSessionMinute(minuteUnix: t0 + $0 * 60, hr: 72, strong: false, weak: false) }
        let now = t0 + 40 * 60
        let logged = [LoggedWorkoutSpan(startUnix: t0 + 30 * 60, endUnix: t0 + 35 * 60, typeId: "yoga")]
        let ex = WatchdogExerciseContext.build(minutes: minutes, windowStart: t0 + 20 * 60, seqLen: 20, nowUnix: now,
                                               evaluations: [], logged: logged)
        XCTAssertTrue(ex.spans.isEmpty, "no load: the rule finds no session")
        XCTAssertEqual(ex.phases[10..<15].allSatisfy { $0 == .session }, true)
        XCTAssertEqual(ex.phases[15], ExerciseSessionPhase.none)
        XCTAssertEqual(ex.phases[9], ExerciseSessionPhase.none)
        let inferred = WatchdogExerciseSnapshot.make(ex, evaluations: [], nowUnix: now)
        XCTAssertEqual(inferred.phase, "none")
        XCTAssertNil(inferred.basis)
    }

    /// The decoder reads a logged workout through its existing path: the type's stored sport name gives the kind.
    func testDecoderSeesTheLoggedTypesKind() {
        let start = t0, end = t0 + 120
        for (id, kind) in [("indoor_cycling", WorkoutKind.cycling), ("indoor_walk", .walking), ("strength", .other)] {
            let type = WorkoutTypeCatalog.entry(id: id)!
            let input = ActivityContextTrackInput(
                dayStart: start - 60, dayEnd: end + 60,
                hr: (start - 60..<end + 60).map { HRSample(ts: $0, bpm: 110) },
                workouts: [DayStateWorkout(start: start, end: end, sport: type.sportName)])
            let obs = ActivityContextTrackBuilder.observations(for: input)
            let inside = obs.filter { $0.ts >= start && $0.ts < end }
            XCTAssertFalse(inside.isEmpty)
            XCTAssertTrue(inside.allSatisfy { $0.loggedWorkout && $0.workoutKind == kind }, id)
            XCTAssertTrue(obs.filter { $0.ts < start - 5 }.allSatisfy { !$0.loggedWorkout }, id)
        }
    }

    /// Through the real Watchdog: a logged strength workout with a still arm at 115 bpm is compared with the exercise
    /// reference (never awake rest) and stays silent; the same minutes unlogged are judged against rest. A heart rate
    /// above the in-session ceiling inside the same logged workout is still a verified safety alert.
    func testWatchdogJudgesALoggedStillStrengthWorkoutAsExerciseAndStillFlagsTheCeiling() throws {
        typealias S = WatchdogV2ScenarioTests
        let refs = S.references()
        let base = S.t0
        let gym = S.Scenario(name: "logged_still_strength", minutes: 130,
                             segments: [S.Segment(fromMin: 0, toMin: 40, state: .seated, hr: 68),
                                        S.Segment(fromMin: 40, toMin: 100, state: .liftRest, hr: 115, rmssd: 20),
                                        S.Segment(fromMin: 100, toMin: 130, state: .seated, hr: 72)],
                             seed: 41)
        let logged = [LoggedWorkoutSpan(startUnix: base + 40 * 60, endUnix: base + 100 * 60, typeId: "strength")]
        var kinds: [Int: WatchdogMinuteContextKind] = [:]
        var snaps: [Int: WatchdogExerciseSnapshot] = [:]
        var restJudged = 0
        let withLog = S.run(gym, refs: refs, logged: logged) { minute, w, carry, r in
            let q = WatchdogSignalQuality.assess(window: w)
            let ctx = WatchdogContextResolver.resolve(window: w, quality: q, carryLastWorkoutEndUnix: carry.lastWorkoutEndUnix)
            kinds[minute] = ctx.last?.kind
            snaps[minute] = r.exercise
            if (r.verdicts ?? []).contains(where: { $0.candidate.reference == LBSeries.awakeRestHR.rawValue }),
               minute >= 41, minute < 100 { restJudged += 1 }
        }
        for minute in 41..<100 {
            XCTAssertEqual(kinds[minute], .exerciseSession, "minute \(minute)")
            XCTAssertEqual(snaps[minute]?.basis, "logged", "minute \(minute)")
            XCTAssertEqual(snaps[minute]?.workoutType, "strength")
        }
        XCTAssertEqual(restJudged, 0, "never compared with awake rest while logged")
        XCTAssertEqual(withLog.filter(\.notify).count, 0, "a logged gym session at 115 bpm is silent")

        // The same still minutes unlogged: no movement evidence, so they are awake-still minutes judged against rest.
        var unloggedStill = 0
        _ = S.run(gym, refs: refs) { minute, w, carry, _ in
            let q = WatchdogSignalQuality.assess(window: w)
            let ctx = WatchdogContextResolver.resolve(window: w, quality: q, carryLastWorkoutEndUnix: carry.lastWorkoutEndUnix)
            if minute >= 50, minute < 100, ctx.last?.kind == .awakeStill { unloggedStill += 1 }
        }
        XCTAssertGreaterThan(unloggedStill, 40, "without the log the rule sees no session")

        // Safety bounds still apply inside a logged workout: 212 bpm for 10 minutes is above the ceiling (195 + 5).
        let breach = S.Scenario(name: "logged_strength_ceiling", minutes: 130,
                                segments: [S.Segment(fromMin: 0, toMin: 40, state: .seated, hr: 68),
                                           S.Segment(fromMin: 40, toMin: 80, state: .liftRest, hr: 115, rmssd: 20),
                                           S.Segment(fromMin: 80, toMin: 90, state: .liftRest, hr: 212, rmssd: 10),
                                           S.Segment(fromMin: 90, toMin: 130, state: .liftRest, hr: 115, rmssd: 20)],
                                seed: 42)
        var ceilingAlert = false
        let ticks = S.run(breach, refs: refs, logged: [LoggedWorkoutSpan(startUnix: base + 40 * 60,
                                                                         endUnix: base + 130 * 60, typeId: "strength")]) {
            _, _, _, r in
            if (r.verdicts ?? []).contains(where: { $0.candidate.id.hasPrefix("sx-exercise-ceiling")
                                                    && $0.decision == .alert }) { ceilingAlert = true }
        }
        XCTAssertTrue(ceilingAlert, "the in-session ceiling still judges logged minutes")
        XCTAssertTrue(ticks.contains { $0.minute >= 80 && $0.minute < 100 && $0.severity == .severe })
    }
}
