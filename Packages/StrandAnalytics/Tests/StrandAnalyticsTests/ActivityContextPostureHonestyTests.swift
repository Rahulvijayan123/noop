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

    func testAQuarterHourOfQuietStandingDoesNotBecomeConfidentSitting() throws {
        // Walk, then stand quietly for 900 s with the arm hanging. The old seated dwell prior (900 s against
        // upright's 100 s) turned this into "Sitting quietly" at seated 0.82 within five minutes.
        var sim = ActivitySim()
        sim.forearm(0.9)
        sim.walk(90)
        let stop = sim.ts
        sim.still(900)
        let states = decode(sim.observations).filter { $0.ts >= stop + 30 }
        XCTAssertFalse(states.isEmpty)
        for (s, k) in zip(states, classes(states)) {
            XCTAssertLessThan(s.posture[.seatedLikely], 0.6, "at \(s.ts - stop) s")
            XCTAssertFalse(k.activityClass == .sitting || k.activityClass == .sittingDesk,
                           "a quiet stand must not read as sitting (at \(s.ts - stop) s: \(k.activityClass))")
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
        var sim = ActivitySim()
        sim.forearm(0.55)
        var awake = ActivitySim.Options(); awake.sleep = .awake
        sim.desk(240, opt: awake)
        let lie = sim.ts
        sim.postureShift(netDegrees: 80, seconds: 4, toForearm: -0.45, opt: awake)
        sim.still(900, opt: awake)
        let states = decode(sim.observations)
        let near = events(states).filter { postural.contains($0.kind) && abs($0.ts - lie) <= 15 }
        XCTAssertTrue(near.contains { $0.kind == .lyingDownLike }, "got \(near.map(\.kind))")
        XCTAssertFalse(near.contains { $0.kind == .sitToStandLike }, "got \(near.map(\.kind))")
        // Minutes later the held orientation has made it lying down (or at least not sitting).
        let end = try XCTUnwrap(states.last)
        let k = ActivityClassifier.classify(state: end)
        XCTAssertTrue([.lyingDown, .stationary].contains(k.activityClass), "got \(k.activityClass)")
        XCTAssertGreaterThan(end.posture[.recumbent], end.posture[.seatedLikely])
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
}
