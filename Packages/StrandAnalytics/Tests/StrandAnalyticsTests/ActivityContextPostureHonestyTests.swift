import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// hsmm-1.8 posture honesty, absolute forearm orientation, lying awake, wear, gaps and transition entry
/// (WP1 of the activity-context audit). Scenario tests on the deterministic simulator: they pin what the
/// decoder may and may not claim when the wrist has, or lacks, the evidence for it.
final class ActivityContextPostureHonestyTests: XCTestCase {

    private func decode(_ observations: [ActivityObservation], config: ActivityDecoderConfig = ActivityDecoderConfig())
        -> [ActivityContextState] {
        var d = ActivityContextDecoder(config: config)
        return d.run(observations)
    }

    private func classes(_ states: [ActivityContextState]) -> [ActivityClassification] {
        states.map(ActivityClassifier.classify(state:))
    }

    private func events(_ states: [ActivityContextState]) -> [ActivityTransitionEvent] {
        var seen: [String: ActivityTransitionEvent] = [:]
        for s in states { for e in s.history.recentEvents { seen["\(e.kind.rawValue)@\(e.ts)"] = e } }
        return seen.values.sorted { $0.ts < $1.ts }
    }

    private let postural: Set<ActivityTransitionKind> = [.sitToStandLike, .standToSitLike, .lyingDownLike, .gettingUpLike]

    // MARK: Posture honesty (D2-07, D1V-01)

    func testAQuarterHourOfQuietStandingStaysUnresolvedEarlyAndOnlyThenLeansSitting() throws {
        // Walk, then stand quietly for 900 s with the arm hanging. The old seated dwell prior (900 s against
        // upright's 100 s) turned this into "Sitting quietly" at seated 0.82 within five minutes; hsmm-1.8 made it
        // stay unresolved for good. hsmm-2.0 measures what elapsed stillness says (Capture-24, 151 people: P(sitting)
        // within still stretches rises from 0.78 in the first minute to 0.92 at 5–7.5 min and 0.97 at 10–15 min;
        // 5 % of standing bouts pass 10 min), so the first minutes stay unresolved and only a long stillness leans
        // sitting, capped like every wrist-only posture claim. A real long stand is this decoder's known error mode;
        // a measured stand-up (`ActivityVerticalShift`) or a verified personal head counters it.
        var sim = ActivitySim()
        sim.forearm(0.9)
        sim.walk(90)
        let stop = sim.ts
        sim.still(900)
        let states = decode(sim.observations).filter { $0.ts >= stop + 30 }
        XCTAssertFalse(states.isEmpty)
        for (s, k) in zip(states, classes(states)) {
            if s.ts - stop < 180 {
                XCTAssertFalse(k.activityClass == .sitting || k.activityClass == .sittingDesk,
                               "the first minutes of a quiet stand stay unresolved (at \(s.ts - stop) s: \(k.activityClass))")
            }
            XCTAssertLessThan(s.posture[.seatedLikely], 0.7, "at \(s.ts - stop) s")
            if [.sitting, .sittingDesk, .standing].contains(k.activityClass) {
                XCTAssertLessThanOrEqual(k.confidence, ActivityClassifier.wristOnlyPostureConfidenceCap + 1e-12)
            }
        }
        let end = try XCTUnwrap(states.last)
        XCTAssertEqual(end.locomotion.top?.0, .stationary)
    }

    func testThreeHoursOfQuietStillnessWithUnknownSleepNeverDriftsToRecumbentOrUnknown() throws {
        // D1V-01: on sleep = unknown seconds (every live day) the bed-rest dwell (1800 s) used to pull a quiet,
        // inclined wrist toward recumbent and the class to unknown@0 after ~36 min. No orientation evidence
        // for lying here (forearm inclined), so it must stay stationary-awake throughout.
        var sim = ActivitySim()
        sim.forearm(0.55)
        sim.still(3 * 3600)
        let states = decode(sim.observations).filter { $0.ts >= sim.observations[0].ts + 60 }
        for (s, k) in zip(states, classes(states)) {
            XCTAssertLessThan(s.posture[.recumbent], s.posture[.seatedLikely] + s.posture[.uprightStationary],
                              "at \(s.ts)")
            XCTAssertNotEqual(k.activityClass, .unknown, "stationary >= 0.9 must never publish unknown (at \(s.ts))")
            XCTAssertNotEqual(k.activityClass, .lyingDown, "at \(s.ts)")
        }
    }

    // MARK: Absolute forearm orientation (D1-03, D2-06)

    func testThirtyMinutesOfAFlatForearmAwakeIsNotConfidentSitting() throws {
        // D1-03 probe E1: 30 min awake stillness with the forearm flat read "Sitting quietly" at 0.78, identical
        // to an arm hanging or on the lap. A held flat forearm is (weak, slow) recumbent evidence: the class may
        // become lying down or stay stationary, but never confident sitting.
        var sim = ActivitySim()
        sim.forearm(0.05)
        var awake = ActivitySim.Options(); awake.sleep = .awake
        sim.still(1800, opt: awake)
        let states = decode(sim.observations)
        let ks = classes(states)
        for (s, k) in zip(states, ks) where s.ts >= sim.observations[0].ts + 60 {
            XCTAssertFalse((k.activityClass == .sitting || k.activityClass == .sittingDesk) && k.confidence >= 0.6,
                           "at \(s.ts): \(k.activityClass) \(k.confidence)")
        }
        let end = try XCTUnwrap(states.last), k = try XCTUnwrap(ks.last)
        XCTAssertTrue([.lyingDown, .stationary].contains(k.activityClass), "got \(k.activityClass)")
        let early = try XCTUnwrap(states.first { $0.ts >= sim.observations[0].ts + 120 })
        XCTAssertGreaterThan(end.posture[.recumbent], early.posture[.recumbent], "recumbent grows with the held flat forearm")
    }

    func testTheSameStillnessWithoutGravityStaysUnresolved() throws {
        // The orientation channel needs a held gravity direction: with no gravity stream nothing about lying
        // or standing can be said, and the posture stays unresolved.
        var sim = ActivitySim()
        var o = ActivitySim.Options(); o.gravity = false; o.sleep = .awake
        sim.still(1800, opt: o)
        let states = decode(sim.observations)
        let end = try XCTUnwrap(states.last)
        XCTAssertLessThan(end.posture[.recumbent], 0.25)
        XCTAssertLessThan(abs(end.posture[.seatedLikely] - end.posture[.uprightStationary]), 0.2)
        XCTAssertEqual(ActivityClassifier.classify(state: end).activityClass, .stationary)
    }

    func testALieDownIsLyingDownLikeNotSitToStandLike() throws {
        // D2-06: sit, then lie down on a sofa (the forearm goes from inclined on the knee to flat with the hand
        // raised toward the chest), awake. The four transition modes shared one observation profile, so the
        // event kind came from where the mass was and a lie-down from sitting was stamped sit_to_stand_like.
        // The walk there (arm hanging) calibrates the strap's forearm sign: without it a raised hand cannot be
        // told from a hanging arm, and the lie-down's direction would rest on the flat forearm alone.
        var sim = ActivitySim()
        var awake = ActivitySim.Options(); awake.sleep = .awake
        sim.forearm(0.9)
        sim.walk(90, opt: awake)
        sim.forearm(0.55)
        sim.desk(240, opt: awake)
        let lie = sim.ts
        sim.postureShift(netDegrees: 80, seconds: 4, toForearm: -0.45, opt: awake)
        sim.still(900, opt: awake)
        let states = decode(sim.observations)
        let near = events(states).filter { postural.contains($0.kind) && abs($0.ts - lie) <= 15 }
        XCTAssertTrue(near.contains { $0.kind == .lyingDownLike }, "got \(near.map(\.kind))")
        XCTAssertFalse(near.contains { $0.kind == .sitToStandLike }, "got \(near.map(\.kind))")
        // Minutes later the lie-down's direction and the held orientation have made it possibly lying, never
        // sitting: from the wrist alone (no night, no in-bed window) the posture stays unresolved, because a
        // seated wearer raising a phone looks the same (`testTwentyMinutesSeatedHoldingAPhoneUpIsNeverLying`).
        let end = try XCTUnwrap(states.last)
        let k = ActivityClassifier.classify(state: end)
        XCTAssertTrue([.lyingDown, .stationary].contains(k.activityClass), "got \(k.activityClass)")
        XCTAssertLessThan(end.posture[.seatedLikely] - end.posture[.uprightStationary], 0.2)
        // In the minutes after it the lie-down's direction lifts recumbent above what the held orientation alone
        // may (~0.23), and then fades back toward unresolved as the direction memory ages.
        let before = try XCTUnwrap(states.last { $0.ts < lie })
        let peak = states.filter { $0.ts >= lie && $0.ts <= lie + 400 }.map { $0.posture[.recumbent] }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.3)
        XCTAssertGreaterThan(peak, before.posture[.recumbent] + 0.25)
    }

    func testDirectionComesFromTheForearmNotFromWhereTheMassWas() throws {
        // D7: transition direction was right 15 of 35 times. A stand-up lets the arm hang, a sit-down brings it
        // back to the lap: the event kinds follow the forearm axis.
        var sim = ActivitySim()
        sim.forearm(0.3)
        sim.desk(240)
        let up = sim.ts
        sim.postureShift(netDegrees: -60, seconds: 3, toForearm: 0.92)
        sim.still(60)
        let down = sim.ts
        sim.postureShift(netDegrees: 60, seconds: 3, toForearm: 0.3)
        sim.desk(120)
        let ev = events(decode(sim.observations)).filter { postural.contains($0.kind) }
        XCTAssertEqual(ev.first { abs($0.ts - up) <= 10 }?.kind, .sitToStandLike, "got \(ev)")
        XCTAssertEqual(ev.first { abs($0.ts - down) <= 10 }?.kind, .standToSitLike, "got \(ev)")
    }

    // MARK: In bed awake (D1-04)

    func testLyingAwakeInBedIsRecumbentInThePostureHeadNotOnlyInTheClass() throws {
        // D1-04 probe E2: 20 min awake in the night's in-bed window: the class said lying_down@0.97 while the
        // posture posterior said seated 0.81 / recumbent 0.001 (channel 7 penalised bed rest on awake seconds).
        var sim = ActivitySim()
        var bed = ActivitySim.Options(); bed.sleep = .awake
        sim.still(1200, opt: bed)
        let obs = sim.observations.map { o -> ActivityObservation in var o = o; o.inBed = true; return o }
        let states = decode(obs)
        let end = try XCTUnwrap(states.last)
        XCTAssertGreaterThanOrEqual(end.posture[.recumbent], 0.6)
        XCTAssertEqual(end.displayContext, "Resting in bed")
        XCTAssertEqual(ActivityClassifier.classify(state: end).activityClass, .lyingDown)
    }

    func testGettingOutOfBedIsGettingUpAndAsleepLetsGoAtTheStagedWake() throws {
        // D2-17: asleep, staged awake in bed, then out of bed and walking. The burst at the in-bed edge is getting
        // up (not sit_to_stand_like), and "Asleep" is released as soon as the stager says awake.
        var sim = ActivitySim()
        sim.sleeping(600)
        let wake = sim.ts
        var awake = ActivitySim.Options(); awake.sleep = .awake
        sim.still(60, opt: awake)
        let out = sim.ts
        sim.postureShift(netDegrees: 80, seconds: 4, toForearm: 0.9, opt: awake)
        sim.walk(90, opt: awake)
        let obs = sim.observations.map { o -> ActivityObservation in
            var o = o; o.inBed = o.ts < out; return o
        }
        let states = decode(obs)
        let afterWake = states.filter { $0.ts >= wake + 5 && $0.ts < out }
        XCTAssertFalse(afterWake.isEmpty)
        XCTAssertTrue(afterWake.allSatisfy { $0.displayContext != "Asleep" }, "Asleep must not be held past the staged wake")
        let ev = events(states).filter { postural.contains($0.kind) && abs($0.ts - out) <= 15 }
        XCTAssertTrue(ev.contains { $0.kind == .gettingUpLike }, "got \(ev.map(\.kind))")
        XCTAssertFalse(ev.contains { $0.kind == .sitToStandLike }, "got \(ev.map(\.kind))")
    }

    // MARK: Stationary fallback (D1-11)

    func testAClearlyStationarySecondNeverPublishesUnknown() throws {
        // A long, quiet, flat-forearm stillness drifts toward recumbent; on the way the posture is split between
        // lying and sitting. That second must publish `stationary` (the coarse fact), not unknown@0.
        var sim = ActivitySim()
        sim.forearm(0.05)
        sim.still(3600)
        let states = decode(sim.observations)
        for (s, k) in zip(states, classes(states)) where s.locomotion[.stationary] >= 0.9 && s.overallConfidence >= 0.3 {
            XCTAssertNotEqual(k.activityClass, .unknown, "at \(s.ts)")
            XCTAssertGreaterThan(k.confidence, 0.3, "at \(s.ts): \(k.activityClass)")
        }
    }

    // MARK: Wear (D1-05, D1V-03)

    func testATableStillStrapWithoutAPulseIsNotSittingQuietly() throws {
        // D1-05 probe E12: a strap motionless on a table (gravity present, no HR, no WRIST_OFF event) read
        // "Sitting quietly", sitting@0.57, wear on_wrist. With wear decided by a recent pulse, it is unknown, and
        // a pulseless strap stiller than any resting wrist reads unknown, not a seated person.
        let t0 = 1_760_000_000
        let gravity = (0..<1200).map { GravitySample(ts: t0 + $0, x: 0.0, y: 0.0, z: 1.0, dynAccel: 0.001) }
        let input = ActivityContextTrackInput(dayStart: t0, dayEnd: t0 + 1200, gravity: gravity)
        let obs = ActivityContextTrackBuilder.observations(for: input)
        XCTAssertTrue(obs.allSatisfy { $0.wear == .unknown }, "no pulse, no wear evidence")
        let track = ActivityContextTrackBuilder.build(input)
        let late = track.states.filter { $0.ts >= t0 + 300 }
        XCTAssertFalse(late.isEmpty)
        for s in late {
            XCTAssertEqual(s.wear.state, .unknown)
            let k = ActivityClassifier.classify(state: s)
            XCTAssertFalse([.sitting, .sittingDesk, .standing, .lyingDown].contains(k.activityClass) && k.confidence > 0.3,
                           "at \(s.ts - t0): \(k.activityClass) \(k.confidence)")
        }
        XCTAssertEqual(ActivityClassifier.classify(state: try XCTUnwrap(late.last)).activityClass, .unknown)
    }

    func testWearIsOnWristOnlyWithARecentPulse() {
        let t0 = 1_760_000_000
        let gravity = (0..<300).map { GravitySample(ts: t0 + $0, x: 0.5, y: 0.6, z: 0.6, dynAccel: 0.008) }
        // Pulse for the first 100 s, then none.
        let hr = (0..<100).map { HRSample(ts: t0 + $0, bpm: 64) }
        let off = [DayStateSpan(start: t0 + 250, end: t0 + 280)]
        let input = ActivityContextTrackInput(dayStart: t0, dayEnd: t0 + 300, hr: hr, gravity: gravity, offWrist: off)
        let obs = Dictionary(uniqueKeysWithValues: ActivityContextTrackBuilder.observations(for: input).map { ($0.ts, $0) })
        XCTAssertEqual(obs[t0 + 50]?.wear, .onWrist)
        XCTAssertEqual(obs[t0 + 150]?.wear, .onWrist, "a pulse within the last 60 s")
        XCTAssertEqual(obs[t0 + 170]?.wear, .unknown, "no pulse for more than 60 s")
        XCTAssertEqual(obs[t0 + 260]?.wear, .offWrist, "an explicit off-wrist span still wins")
        XCTAssertEqual(obs[t0 + 290]?.wear, .unknown)
    }

    func testAWornStrapWithAPulseIsUnaffected() throws {
        // The wear rule must not change days where the pulse is present: same states as an explicit on-wrist.
        var sim = ActivitySim()
        sim.desk(300); sim.walk(120); sim.still(200)
        let input = sim.trackInput()
        let obs = ActivityContextTrackBuilder.observations(for: input)
        XCTAssertTrue(obs.allSatisfy { $0.wear == .onWrist })
    }

    // MARK: Gaps (D2-13)

    func testANinetySecondGapDoesNotCarryAConfidentPosture() throws {
        // Seated after a direction-resolved sit-down and desk work, then a 90 s BLE gap, then quiet data. The
        // pre-gap seated belief must not be carried with confidence: the person may have stood up and walked
        // to another room during the gap.
        var sim = ActivitySim()
        sim.forearm(0.9)
        sim.walk(60)
        sim.postureShift(netDegrees: 70, seconds: 3, toForearm: 0.3)
        sim.desk(600)
        let before = sim.ts
        sim.gap(90)
        let after = sim.ts
        sim.still(60)
        let states = decode(sim.observations)
        let pre = try XCTUnwrap(states.last { $0.ts < before })
        XCTAssertGreaterThan(pre.posture[.seatedLikely] - pre.posture[.uprightStationary], 0.2, "committed before the gap")
        let first = try XCTUnwrap(states.first { $0.ts >= after })
        XCTAssertLessThan(first.overallConfidence, 0.6)
        XCTAssertLessThan(first.posture[.seatedLikely] - first.posture[.uprightStationary], 0.2,
                          "no confident carried posture right after the gap")
    }

    // MARK: Transition entry (D2-02, D2V-01, D2-12)

    func testAShortStandThenSitBackFlagsBothChanges() throws {
        // D2-02: sit 120 s, stand ~10 s (burst, arm hangs), sit back down. The fixed 14-32 s look-back compared
        // the return with the PRE-stand sitting orientation, so the sit-down scored ~0 and was never flagged.
        var sim = ActivitySim()
        sim.forearm(0.3)
        sim.desk(120)
        let up = sim.ts
        sim.postureShift(netDegrees: -60, seconds: 3, toForearm: 0.92)
        sim.still(10)
        let down = sim.ts
        sim.postureShift(netDegrees: 60, seconds: 3, toForearm: 0.3)
        sim.desk(150)
        let ev = events(decode(sim.observations)).filter { postural.contains($0.kind) }
        XCTAssertTrue(ev.contains { $0.kind == .sitToStandLike && abs($0.ts - up) <= 10 }, "got \(ev)")
        XCTAssertTrue(ev.contains { $0.kind == .standToSitLike && abs($0.ts - down) <= 10 }, "got \(ev)")
    }

    func testAConfidentExpertFlagsABobUpTheGravityHeuristicCannotSee() throws {
        // D2V-01 / D2-12: sit, a 3 s burst that returns to the same orientation (stand up and straight back
        // down), with the learned expert naming stand-to-sit at 0.80. The quiet gravity heuristic vetoed the
        // expert at full weight and transition entry was driven by the heuristic alone: no event.
        var sim = ActivitySim()
        sim.desk(120)
        let burst = sim.ts
        for _ in 0..<3 { sim.emit(dyn: 0.25, ticks: 0, cls: 0, rotate: 0, jitter: 25, opt: ActivitySim.Options()) }
        sim.desk(60)
        var obs = sim.observations
        for i in obs.indices where obs[i].ts >= burst && obs[i].ts < burst + 4 {
            obs[i].transition = TransitionEncoderEvidence(none: 0.12, sitToStand: 0.04, standToSit: 0.80, lieDown: 0.02,
                                                          getUp: 0.02, confidence: 0.80, modelVersion: "t", preprocessingVersion: "t")
        }
        let withExpert = events(decode(obs)).filter { postural.contains($0.kind) }
        XCTAssertTrue(withExpert.contains { $0.kind == .standToSitLike && $0.ts - burst <= 6 && $0.probability >= 0.4 },
                      "got \(withExpert)")
        // Without the expert the same stream flags nothing (and decodes as before the expert existed).
        let plain = events(decode(sim.observations)).filter { postural.contains($0.kind) }
        XCTAssertTrue(plain.isEmpty, "got \(plain)")
    }

    // MARK: Encoder hygiene (D1V-02, D1-08) and one logged workout (D1-12)

    private func features(m10: Double, encoder: MotionEncoderOutput?, hrRel: Double? = nil,
                          workout: Bool = false) -> ActivityFeatures {
        ActivityFeatures(ts: 0, m4: m10, m10: m10, m30: m10, mMed30: m10, mBurst10: m10, cv30: 0.5,
                         gaitPresence: 0, cadenceSpm: nil, runShare6: nil, rhythm: nil, orientPath10: 0.5,
                         net5: 2, net30: 2, shiftNet: nil, hr: nil, hrRel: hrRel, hrSlope: nil,
                         wear: .onWrist, sleep: .awake, loggedWorkout: workout, workoutKind: .other,
                         encoder: encoder, encoderAgeS: 0,
                         evidence: ActivityEvidenceSummary(imu: false, encoder: encoder != nil, dynAccel: true,
                                                           gravity: true, steps: true, heartRate: hrRel != nil,
                                                           sleep: true, coverage: 1),
                         windowFill: 10)
    }

    private func folded(other: Double, abstained: Bool) -> MotionEncoderOutput {
        MotionEncoderOutput(encoderId: "hart", encoderVersion: "hart-wisdm-v0", startTs: -4, endTs: 0,
                            classProbs: ["stationary": 1 - other, "other_movement": other, "walking": 0, "running": 0],
                            calibrated: false, abstained: abstained)
    }

    func testAnAbstainedWindowNeverOpensTheExerciseGate() {
        // D1V-02: an abstained window kept its full probabilities in the specialist gate (other_movement 0.35
        // opened generic exercise 25×) while channel 4 discounted the same window to 0.24×.
        let f = features(m10: 0.8, encoder: folded(other: 0.35, abstained: true))
        XCTAssertEqual(ActivityContextModel.encoderNames("other_movement", mode: .otherExercise, f, effort: 0), 0)
    }

    func testFoldedOtherMovementOpensExerciseOnlyWithMovementOrEffort() {
        // D1-08: the folded head files eating, drinking and brushing teeth under other_movement.
        let meal = features(m10: 0.30, encoder: folded(other: 0.6, abstained: false))
        XCTAssertLessThan(ActivityContextModel.encoderNames("other_movement", mode: .otherExercise, meal, effort: 0), 0.15,
                          "a seated meal does not open the gate")
        let vigorous = features(m10: 0.75, encoder: folded(other: 0.6, abstained: false))
        XCTAssertGreaterThan(ActivityContextModel.encoderNames("other_movement", mode: .otherExercise, vigorous, effort: 0),
                             0.15)
        XCTAssertGreaterThan(ActivityContextModel.encoderNames("other_movement", mode: .otherExercise, meal, effort: 1),
                             0.15, "a working heart corroborates")
        // Other specialists are unchanged.
        XCTAssertEqual(ActivityContextModel.encoderNames("other_movement", mode: .stairs, meal, effort: 0), 0.6)
    }

    func testALoggedWorkoutCountsOnceOnTheBodyChain() {
        // D1-12: the logged workout entered the arm-pattern channel (exercise ≥ 0.7) AND the channel-7 gate. On the
        // body chain only the gate may speak: between seated and upright the score differs by that one factor.
        let base = features(m10: 0.3, encoder: nil)
        let logged = features(m10: 0.3, encoder: nil, workout: true)
        let t = 0.35
        let a = ActivityContextModel.score(base, temperature: t), b = ActivityContextModel.score(logged, temperature: t)
        let seat = BodyMode.seated.rawValue, up = BodyMode.upright.rawValue
        let gate = ActivityContextModel.profiles[seat].workout / ActivityContextModel.profiles[up].workout
        let moved = (b.logL[seat] - b.logL[up]) - (a.logL[seat] - a.logL[up])
        XCTAssertEqual(moved, t * ActivityContextModel.wGate * log(gate), accuracy: 1e-9)
        // The arm chain still sees the workout (its exercise reading).
        XCTAssertGreaterThan(ActivityContextModel.armPattern(logged)[ArmState.exercise],
                             ActivityContextModel.armPattern(logged, includeWorkout: false)[ArmState.exercise])
    }

    // MARK: Held orientation alone never commits lying; the forearm sign is calibrated (hsmm-1.8 review)

    private func walkCalibrating(_ sim: inout ActivitySim, hanging x: Double = 0.9,
                                 opt: ActivitySim.Options = ActivitySim.Options()) {
        let held = sim.forearmX
        sim.forearm(x)
        sim.walk(90, opt: opt)
        sim.forearm(held)
    }

    private func assertNeverLying(_ states: [ActivityContextState], from t0: Int, _ what: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let late = states.filter { $0.ts >= t0 + 60 }
        XCTAssertFalse(late.isEmpty, file: file, line: line)
        for (s, k) in zip(late, classes(late)) {
            XCTAssertNotEqual(k.activityClass, .lyingDown, "\(what) at \(s.ts - t0) s", file: file, line: line)
            XCTAssertNotEqual(k.activityClass, .unknown, "\(what) at \(s.ts - t0) s", file: file, line: line)
            XCTAssertLessThan(s.posture[.recumbent], 0.5, "\(what) at \(s.ts - t0) s", file: file, line: line)
            XCTAssertFalse(["Lying down", "Resting in bed"].contains(s.displayContext ?? ""),
                           "\(what) at \(s.ts - t0) s: \(s.displayContext ?? "nil")", file: file, line: line)
        }
    }

    func testFortyMinutesOfQuietSittingWithAFlatForearmIsNeverLying() {
        // Review probe P1: walk, sit down, then 40 min quiet with the forearm flat on an armrest or the lap (TV,
        // a meeting), sleep unknown. The held orientation alone used to commit lying_down in 363 of 479 states.
        for calibrated in [false, true] {
            var sim = ActivitySim()
            sim.forearm(0.1)
            if calibrated { walkCalibrating(&sim) }
            sim.walk(60)
            sim.postureShift(netDegrees: 70, seconds: 3, toForearm: 0.1)
            let t0 = sim.ts
            sim.still(2400)
            assertNeverLying(decode(sim.observations), from: t0, calibrated ? "calibrated" : "sign unknown")
        }
    }

    func testTwentyMinutesSeatedHoldingAPhoneUpIsNeverLying() {
        // Review probe P2: desk work, then the hand raised above the elbow to read a phone, quiet for 20 min.
        // A raised hand is the strongest recumbent cue the forearm has, and still only a hedge on its own.
        for calibrated in [false, true] {
            var sim = ActivitySim()
            sim.forearm(0.5)
            if calibrated { walkCalibrating(&sim) }
            sim.desk(120)
            sim.postureShift(netDegrees: 40, seconds: 3, toForearm: -0.45)
            let t0 = sim.ts
            sim.still(1200)
            assertNeverLying(decode(sim.observations), from: t0, calibrated ? "calibrated" : "sign unknown")
        }
    }

    func testTheOriginalQuietWristNeverReachesLying() {
        // Review probe P5 at its full length: the simulator's default (flat) forearm, quiet, no sleep evidence.
        var sim = ActivitySim()
        let t0 = sim.ts
        sim.still(2400)
        let states = decode(sim.observations)
        assertNeverLying(states, from: t0, "default forearm")
        for s in states.filter({ $0.ts >= t0 + 60 }) { XCTAssertLessThan(s.posture[.recumbent], 0.3, "at \(s.ts - t0)") }
    }

    func testQuietDeskReadingThroughTheTrackIsNotRestingInBed() {
        // Review probe P6: desk work, then 30 min quiet reading with the forearm flat on the desk, through the
        // track builder (wear from the pulse, sleep known awake outside sessions). It became lying_down at 0.61
        // and "Resting in bed".
        var sim = ActivitySim()
        sim.forearm(0.05)
        sim.desk(300)
        let t0 = sim.ts
        sim.still(1800)
        let obs = ActivityContextTrackBuilder.observations(for: sim.trackInput())
        assertNeverLying(decode(obs), from: t0, "track path")
    }

    /// The same stream with the strap's x axis mirrored (worn the other way round).
    private func mirrored(_ obs: [ActivityObservation]) -> [ActivityObservation] {
        obs.map { o in
            var o = o
            if let g = o.gravity, g.count == 3 { o.gravity = [-g[0], g[1], g[2]] }
            return o
        }
    }

    func testAStrapWornTheOtherWayRoundDecodesTheSame() throws {
        // Review probes P3 / P4: nothing on the strap says which way its +x points. Read with a fixed sign, a
        // hanging arm on a flipped strap was "hand above the elbow" (lying_down from 240 s of quiet standing)
        // and every stand-up / sit-down came out inverted. Calibrated from gait (or read as |x| until then),
        // a mirrored stream decodes to exactly the same states.
        var sim = ActivitySim()
        walkCalibrating(&sim)
        sim.forearm(0.3)
        sim.desk(240)
        let up = sim.ts
        sim.postureShift(netDegrees: -60, seconds: 3, toForearm: 0.92)
        sim.still(120)
        let down = sim.ts
        sim.postureShift(netDegrees: 60, seconds: 3, toForearm: 0.3)
        sim.desk(300)
        let normal = decode(sim.observations), flipped = decode(mirrored(sim.observations))
        XCTAssertEqual(normal.count, flipped.count)
        for (a, b) in zip(normal, flipped) {
            XCTAssertEqual(ActivityClassifier.classify(state: a).activityClass, ActivityClassifier.classify(state: b).activityClass,
                           "at \(a.ts)")
            XCTAssertEqual(a.posture[.recumbent], b.posture[.recumbent], accuracy: 1e-9, "at \(a.ts)")
            XCTAssertEqual(a.posture[.seatedLikely], b.posture[.seatedLikely], accuracy: 1e-9, "at \(a.ts)")
        }
        let ev = events(flipped).filter { postural.contains($0.kind) }
        XCTAssertEqual(ev.first { abs($0.ts - up) <= 10 }?.kind, .sitToStandLike, "got \(ev)")
        XCTAssertEqual(ev.first { abs($0.ts - down) <= 10 }?.kind, .standToSitLike, "got \(ev)")
        XCTAssertFalse(ev.contains { $0.kind == .lyingDownLike }, "got \(ev)")

        // Standing still after a walk on the flipped strap (P3): never lying.
        var stand = ActivitySim()
        stand.forearm(0.9)
        stand.walk(90)
        let t0 = stand.ts
        stand.still(900)
        assertNeverLying(decode(mirrored(stand.observations)), from: t0, "flipped, standing")
        // And before any walk has calibrated the sign, the mirrored strap reads the same as the normal one.
        var cold = ActivitySim()
        cold.forearm(0.9)
        cold.still(900)
        let c1 = decode(cold.observations), c2 = decode(mirrored(cold.observations))
        for (a, b) in zip(c1, c2) { XCTAssertEqual(a.posture[.recumbent], b.posture[.recumbent], accuracy: 1e-9) }
    }

    func testTheForearmSignIsCalibratedFromGaitAndForgottenOffWrist() throws {
        var sim = ActivitySim()
        sim.forearm(-0.9)
        sim.walk(90)
        var d = ActivityContextDecoder(config: ActivityDecoderConfig())
        _ = d.run(sim.observations)
        let t = d.snapshot().tracking
        let votes = try XCTUnwrap(t.forearmSignVotes), weight = try XCTUnwrap(t.forearmSignWeight)
        XCTAssertGreaterThanOrEqual(weight, ActivityContextModel.forearmSignMinGaitS)
        XCTAssertLessThan(votes / weight, -ActivityContextModel.forearmSignMinMean, "a flipped strap's arm hangs toward −x")
        // A walk with the arm held up (a phone, a carried bag) leaves it unknown rather than wrong.
        var phone = ActivitySim()
        phone.walk(300)
        var d2 = ActivityContextDecoder(config: ActivityDecoderConfig())
        _ = d2.run(phone.observations)
        let t2 = d2.snapshot().tracking
        XCTAssertLessThan(abs((t2.forearmSignVotes ?? 0) / max(1, t2.forearmSignWeight ?? 1)),
                          ActivityContextModel.forearmSignMinMean)
        // Off the wrist it may go back on the other way round.
        sim.offWrist(30)
        var d3 = ActivityContextDecoder(config: ActivityDecoderConfig())
        _ = d3.run(sim.observations)
        XCTAssertNil(d3.snapshot().tracking.forearmSignVotes)
    }

    func testAnEventIsPublishedUnderOneKindOnly() {
        // Review: an unshown postural event may still change kind, and it was already in every state's
        // recent_events, so persisted states showed one event as lying_down_like and stand_to_sit_like.
        var scenarios: [[ActivityObservation]] = []
        var a = ActivitySim()
        a.forearm(0.5)
        a.desk(120)
        a.postureShift(netDegrees: 40, seconds: 3, toForearm: -0.45)
        a.still(600)
        scenarios.append(a.observations)
        var b = ActivitySim()
        b.forearm(0.3)
        b.desk(240)
        b.postureShift(netDegrees: -60, seconds: 3, toForearm: 0.92)
        b.still(120)
        b.postureShift(netDegrees: 60, seconds: 3, toForearm: 0.3)
        b.desk(300)
        scenarios.append(b.observations)
        scenarios.append(mirrored(b.observations))
        for (i, obs) in scenarios.enumerated() {
            var kinds: [Int: Set<ActivityTransitionKind>] = [:]
            for s in decode(obs) {
                for e in s.history.recentEvents { kinds[e.ts, default: []].insert(e.kind) }
                if let e = s.transition { kinds[e.ts, default: []].insert(e.kind) }
            }
            for (ts, k) in kinds { XCTAssertEqual(k.count, 1, "scenario \(i), event at \(ts): \(k)") }
        }
    }

    func testAVeryStillSleeperWithoutAPulseStaysAsleep() {
        // Review probe P7: staged asleep, wear unknown, the HR stream missing, a very still wrist. The pulseless
        // "strap on a table" rule made it unknown@0 from 300 s while the display still said "Asleep".
        var sim = ActivitySim()
        var o = ActivitySim.Options(); o.hr = nil; o.sleep = .asleep; o.wear = .unknown
        let t0 = sim.ts
        sim.still(1200, dyn: 0.004, opt: o)
        let late = decode(sim.observations).filter { $0.ts >= t0 + 200 }
        XCTAssertFalse(late.isEmpty)
        for (s, k) in zip(late, classes(late)) {
            XCTAssertEqual(k.activityClass, .sleeping, "at \(s.ts - t0)")
        }
    }
}
