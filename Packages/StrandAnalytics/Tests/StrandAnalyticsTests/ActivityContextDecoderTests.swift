import XCTest
@testable import StrandAnalytics

/// ActivityContext v2 decoder: scenario tests on deterministic synthetic wrist streams.
///
/// The simulator uses this strap's measured magnitudes (see `ActivityContextSim.swift`). These tests pin
/// *behaviour* (what the heads say, what is flagged, how quickly, how confidently) rather than exact
/// probabilities, so retuning the parameter tables does not require rewriting them — but a change that
/// breaks a scenario here is a change in what the product tells the user.
final class ActivityContextDecoderTests: XCTestCase {

    // MARK: Helpers

    private func decode(_ sim: ActivitySim, config: ActivityDecoderConfig = ActivityDecoderConfig())
        -> (decoder: ActivityContextDecoder, states: [ActivityContextState]) {
        var d = ActivityContextDecoder(config: config)
        let states = d.run(sim.observations)
        return (d, states)
    }

    private func states(in states: [ActivityContextState], from: Int, to: Int) -> [ActivityContextState] {
        states.filter { $0.ts >= from && $0.ts <= to }
    }

    private func labelChanges(_ states: [ActivityContextState]) -> Int {
        var n = 0
        var prev: String?? = .none
        for s in states {
            if let p = prev, p != s.displayContext { n += 1 }
            prev = .some(s.displayContext)
        }
        return n
    }

    private func events(_ s: ActivityContextState, _ kind: ActivityTransitionKind) -> [ActivityTransitionEvent] {
        s.history.recentEvents.filter { $0.kind == kind }
    }

    private func anyEvent(_ states: [ActivityContextState], _ kind: ActivityTransitionKind) -> Bool {
        states.contains { $0.transition?.kind == kind || !events($0, kind).isEmpty }
    }

    private func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    // MARK: Learned transition-expert helpers

    private func decode(_ observations: [ActivityObservation],
                        config: ActivityDecoderConfig = ActivityDecoderConfig())
        -> (decoder: ActivityContextDecoder, states: [ActivityContextState]) {
        var d = ActivityContextDecoder(config: config)
        let states = d.run(observations)
        return (d, states)
    }

    private func transitionEvidence(none: Double = 0.05, sitToStand: Double = 0.0, standToSit: Double = 0.0,
                                    lieDown: Double = 0.0, getUp: Double = 0.0,
                                    abstained: Bool = false) -> TransitionEncoderEvidence {
        TransitionEncoderEvidence(none: none, sitToStand: sitToStand, standToSit: standToSit,
                                  lieDown: lieDown, getUp: getUp,
                                  confidence: [none, sitToStand, standToSit, lieDown, getUp].max() ?? 0,
                                  modelVersion: "transition-test-1",
                                  preprocessingVersion: "transition-feat-1",
                                  abstained: abstained)
    }

    /// Attach learned transition evidence to the seconds of `obs` for which `when` is true.
    private func withTransition(_ obs: [ActivityObservation], when: (Int) -> Bool,
                                none: Double = 0.05, sitToStand: Double = 0.0, standToSit: Double = 0.0,
                                lieDown: Double = 0.0, getUp: Double = 0.0,
                                abstained: Bool = false) -> [ActivityObservation] {
        var out = obs
        for i in out.indices where when(out[i].ts) {
            out[i].transition = transitionEvidence(none: none, sitToStand: sitToStand, standToSit: standToSit,
                                                   lieDown: lieDown, getUp: getUp, abstained: abstained)
        }
        return out
    }

    private func peakPostural(_ states: [ActivityContextState], from: Int, to: Int) -> Double {
        self.states(in: states, from: from, to: to).map { $0.posture[PostureClass.posturalTransition] }.max() ?? 0
    }

    // MARK: Versions and wire format

    func testVersionStampsArePinned() {
        // Bump these deliberately (and migrate stored states) whenever the vocabulary, the decoder
        // tables or the feature layout change behaviour.
        XCTAssertEqual(ActivityContextVersions.schema, 2)
        XCTAssertEqual(ActivityContextVersions.ontology, "v2.0")
        XCTAssertEqual(ActivityContextVersions.decoder, "hsmm-1.5")
        XCTAssertEqual(ActivityContextVersions.featureSchema, "imu-feat-2")  // bumped by I4 (true gyro RMS, per-second jerk)
    }

    func testOntologyMatchesTheSpecifiedVocabularies() {
        XCTAssertEqual(Set(PostureClass.allCases.map(\.rawValue)),
                       ["recumbent", "seated_likely", "upright_stationary", "postural_transition", "unknown"])
        XCTAssertEqual(Set(LocomotionClass.allCases.map(\.rawValue)),
                       ["stationary", "walking", "brisk_walking", "running", "stairs", "cycling",
                        "vehicle_motion", "other", "unknown"])
        XCTAssertEqual(Set(ArmBehaviorClass.allCases.map(\.rawValue)),
                       ["quiet", "desk_like", "fidgeting", "repetitive_hand_motion", "active_gesturing",
                        "exercise_motion", "other", "unknown"])
        XCTAssertEqual(Set(ActivityTransitionKind.allCases.map(\.rawValue)),
                       ["sit_to_stand_like", "stand_to_sit_like", "lying_down_like", "getting_up_like",
                        "walk_start", "walk_stop", "run_start", "run_stop"])
    }

    func testPublishedStateHasTheDocumentedJSONShape() throws {
        var sim = ActivitySim()
        sim.walk(40)
        let (_, published) = decode(sim)
        let state = try XCTUnwrap(published.last)

        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["posture", "locomotion", "arm_behavior", "intensity", "transition", "overall_confidence",
                    "display_context", "sleep", "wear", "history", "evidence", "versions", "head_confidence",
                    "overall_uncertainty", "ts"] {
            XCTAssertNotNil(json[key], "missing key \(key)")
        }
        let posture = try XCTUnwrap(json["posture"] as? [String: Double])
        XCTAssertTrue(Set(posture.keys).isSubset(of: Set(PostureClass.allCases.map(\.rawValue))))
        let loco = try XCTUnwrap(json["locomotion"] as? [String: Double])
        XCTAssertTrue(Set(loco.keys).isSubset(of: Set(LocomotionClass.allCases.map(\.rawValue))))
        XCTAssertGreaterThan(try XCTUnwrap(loco["walking"]), 0.5)
        let versions = try XCTUnwrap(json["versions"] as? [String: Any])
        XCTAssertEqual(versions["ontology"] as? String, "v2.0")
        XCTAssertEqual(versions["decoder"] as? String, "hsmm-1.5")
        XCTAssertEqual(versions["feature_schema"] as? String, "imu-feat-2")  // I4 bumped the feature contract
        XCTAssertEqual(versions["schema"] as? Int, 2)
        let intensity = try XCTUnwrap(json["intensity"] as? Double)
        XCTAssertTrue((0...1).contains(intensity))

        // Decoding what we encoded and encoding again is a fixed point (values are rounded once).
        let again = try JSONDecoder().decode(ActivityContextState.self, from: data)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(again)) as? NSDictionary
        XCTAssertEqual(reencoded, json as NSDictionary)
    }

    func testStatesWithNullsKeepAStableKeySet() throws {
        var sim = ActivitySim()
        sim.offWrist(20)
        let (_, published) = decode(sim)
        let state = try XCTUnwrap(published.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        XCTAssertTrue(json["intensity"] is NSNull)
        XCTAssertTrue(json["transition"] is NSNull)
        XCTAssertNotNil(json["display_context"])
    }

    func testHeadsAreValidDistributionsThroughoutAMixedDay() {
        var sim = ActivitySim()
        sim.still(40); sim.desk(120); sim.postureShift(netDegrees: -80, seconds: 3); sim.walk(60)
        sim.run(40); sim.walk(30); sim.still(30); sim.sleeping(200); sim.offWrist(30); sim.fidget(60)
        let (_, published) = decode(sim)
        XCTAssertFalse(published.isEmpty)
        for s in published {
            for total in [s.posture.total, s.locomotion.total, s.armBehavior.total] {
                XCTAssertEqual(total, 1, accuracy: 0.02, "head must be a distribution at \(s.ts)")
            }
            for p in Array(s.posture.values.values) + Array(s.locomotion.values.values) + Array(s.armBehavior.values.values) {
                XCTAssertTrue(p >= 0 && p <= 1)
            }
            XCTAssertTrue((0...1).contains(s.overallConfidence))
            XCTAssertTrue((0...1).contains(s.overallUncertainty))
            if let i = s.intensity { XCTAssertTrue((0...1).contains(i)) }
        }
    }

    func testStatesArePublishedOnAFiveSecondGrid() {
        var sim = ActivitySim(start: 1_760_000_003)
        sim.desk(120)
        let (_, published) = decode(sim)
        XCTAssertFalse(published.isEmpty)
        XCTAssertTrue(published.allSatisfy { $0.ts % 5 == 0 })
        let gaps = zip(published.dropFirst(), published).map { $0.ts - $1.ts }
        XCTAssertTrue(gaps.allSatisfy { $0 == 5 }, "continuous input publishes every 5 s")
        XCTAssertEqual(published.count, 120 / 5, accuracy: 1)
    }

    func testOutOfOrderAndDuplicateObservationsAreIgnored() {
        var sim = ActivitySim()
        sim.desk(60)
        var d = ActivityContextDecoder()
        let reference = d.run(sim.observations)
        var noisy = ActivityContextDecoder()
        var out: [ActivityContextState] = []
        for (i, o) in sim.observations.enumerated() {
            if let s = noisy.ingest(o) { out.append(s) }
            if i % 7 == 0 { XCTAssertNil(noisy.ingest(o)) }
            if i > 3 { XCTAssertNil(noisy.ingest(sim.observations[i - 3])) }
        }
        XCTAssertEqual(reference.map(\.ts), out.map(\.ts))
        XCTAssertEqual(reference.last?.posture, out.last?.posture)
    }

    // MARK: Walking and running

    func testWalkingIsDetectedPromptlyAndFlaggedOnce() throws {
        var sim = ActivitySim()
        let start = sim.ts
        sim.still(30)
        let walkStart = sim.ts
        sim.walk(60)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)

        XCTAssertEqual(end.locomotion.top?.0, .walking)
        XCTAssertGreaterThan(end.locomotion[.walking] + end.locomotion[.briskWalking], 0.85)
        XCTAssertEqual(end.displayContext, "Walking")
        XCTAssertGreaterThan(end.overallConfidence, 0.6)
        XCTAssertGreaterThan(end.intensity ?? 0, 0.4)
        // A walker's posture is not claimed from the wrist.
        XCTAssertLessThan(end.posture[.seatedLikely] + end.posture[.uprightStationary], 0.2)
        XCTAssertGreaterThan(end.posture[.unknown], 0.7)
        let starts = events(end, .walkStart)
        XCTAssertEqual(starts.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(starts.first).ts - walkStart, 15)
        XCTAssertGreaterThan(walkStart, start)
    }

    func testRunningIsSeparatedFromWalking() throws {
        var sim = ActivitySim()
        sim.still(20); sim.walk(40)
        let runStart = sim.ts
        sim.run(60)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertEqual(end.locomotion.top?.0, .running)
        XCTAssertGreaterThan(end.locomotion[.running], 0.85)
        XCTAssertEqual(end.displayContext, "Running")
        XCTAssertEqual(end.armBehavior.top?.0, .exerciseMotion)
        let starts = events(end, .runStart)
        XCTAssertEqual(starts.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(starts.first).ts - runStart, 20)
        // While walking, running never got more than a sliver.
        let walkingPhase = states(in: published, from: sim.observations[30].ts, to: runStart - 1)
        XCTAssertLessThan(walkingPhase.map { $0.locomotion[.running] }.max() ?? 0, 0.2)
    }

    func testStairsCyclingAndVehicleNeedTheEncoderToNameThem() throws {
        // Without an encoder label the strap streams alone must not claim a specialist activity.
        var sim = ActivitySim()
        sim.still(30); sim.walk(120); sim.still(60); sim.desk(60)
        let (_, published) = decode(sim)
        for s in published {
            XCTAssertLessThan(s.locomotion[.stairs], 0.12)
            XCTAssertLessThan(s.locomotion[.cycling], 0.12)
            XCTAssertLessThan(s.locomotion[.vehicleMotion], 0.12)
        }

        // When the encoder names stairs while the wearer is walking, the head follows it.
        var withEncoder = ActivitySim()
        var opt = ActivitySim.Options()
        opt.encoder = SimEncoder.coarse("stairs")
        withEncoder.still(20); withEncoder.walk(120, opt: opt)
        let (_, encoded) = decode(withEncoder)
        let end = try XCTUnwrap(encoded.last)
        XCTAssertGreaterThan(end.locomotion[.stairs], 0.25)
    }

    func testAnUnspecifiedWorkoutCoversOnlyGenericExerciseNotSpecialists() throws {
        // WS-06-F03: an unrecognised sport names only generic exercise. A logged workout of unknown
        // sport with a quiet wrist must not promote cycling, stairs or a vehicle — the promotion gate
        // requires the encoder to name the mode or a compatible workout kind to cover it.
        var sim = ActivitySim()
        var opt = ActivitySim.Options()
        opt.hr = 128; opt.workout = true; opt.workoutKind = .unspecified
        sim.still(60)
        for _ in 0..<300 {
            sim.emit(dyn: 0.12 + sim.rand() * 0.12, ticks: 0, cls: 0, rotate: sim.noise(0.3), jitter: sim.noise(6), opt: opt)
        }
        let (_, published) = decode(sim)
        let steady = states(in: published, from: published[0].ts + 150, to: published.last!.ts)
        XCTAssertFalse(steady.isEmpty)
        for s in steady {
            XCTAssertLessThan(s.locomotion[.cycling], 0.12, "unknown-sport workout is no evidence of cycling")
            XCTAssertLessThan(s.locomotion[.stairs], 0.12, "unknown-sport workout is no evidence of stairs")
            XCTAssertLessThan(s.locomotion[.vehicleMotion], 0.12, "unknown-sport workout is no evidence of a vehicle")
        }
    }

    // MARK: Walking ↔ stationary

    func testWalkingToStationaryFlagsAStopAndReturnsToStationary() throws {
        var sim = ActivitySim()
        sim.still(20); sim.walk(60)
        let stopTs = sim.ts
        sim.still(60)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)

        XCTAssertEqual(end.locomotion.top?.0, .stationary)
        XCTAssertGreaterThan(end.locomotion[.stationary], 0.85)
        XCTAssertNotEqual(end.displayContext, "Walking")
        let stops = events(end, .walkStop)
        XCTAssertEqual(stops.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(stops.first).ts - stopTs, 20)
        // Stationary within ~20 s of stopping.
        let soon = states(in: published, from: stopTs + 20, to: stopTs + 25)
        XCTAssertTrue(soon.allSatisfy { $0.locomotion[.stationary] > 0.6 })
    }

    func testStationaryToWalkingFlagsAStartAndKeepsContext() throws {
        var sim = ActivitySim()
        sim.desk(180)
        let walkStart = sim.ts
        sim.walk(45)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertEqual(end.locomotion.top?.0, .walking)
        XCTAssertEqual(events(end, .walkStart).count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(events(end, .walkStart).first).ts - walkStart, 15)
        // The pre-walk state was a settled desk state.
        let before = try XCTUnwrap(states(in: published, from: walkStart - 10, to: walkStart - 1).last)
        XCTAssertGreaterThan(before.posture[.seatedLikely], 0.8)
    }

    func testAShortBurstOfWalkLikeMotionDoesNotBecomeWalking() {
        var sim = ActivitySim()
        sim.desk(150); sim.walk(4); sim.desk(80)
        let (_, published) = decode(sim)
        XCTAssertLessThan(published.map { $0.locomotion[.walking] + $0.locomotion[.briskWalking] }.max() ?? 0, 0.5)
        XCTAssertFalse(published.contains { $0.displayContext == "Walking" })
        XCTAssertFalse(anyEvent(published, .walkStart))
    }

    // MARK: Sit / stand-like transitions and the seated-vs-upright question

    func testWalkStopSitLikeThenLongDeskPeriodRaisesSeatedLikely() throws {
        var sim = ActivitySim()
        sim.still(10); sim.walk(60)
        sim.still(8)
        let sitMoment = sim.ts
        sim.postureShift(netDegrees: 70, seconds: 3)
        sim.desk(400)
        let (_, published) = decode(sim)

        // Right after walking, a stop is upright or unknown, not confidently seated.
        let justStopped = try XCTUnwrap(states(in: published, from: sitMoment - 5, to: sitMoment).last)
        XCTAssertLessThan(justStopped.posture[.seatedLikely], 0.6)

        // The sit-like movement signature is flagged as an event, not as a certainty.
        let flagged = published.compactMap { $0.transition }.filter { $0.kind == .standToSitLike }
        XCTAssertFalse(flagged.isEmpty, "stand-to-sit-like should be flagged")
        XCTAssertLessThan(flagged.map(\.probability).max() ?? 1, 0.95)

        // After minutes of desk-like stillness, seated_likely dominates and the label says so. (The head
        // tops out around 0.84 by design: even a certain "seated" mode leaves room for upright/unknown.)
        let end = try XCTUnwrap(published.last)
        XCTAssertGreaterThan(end.posture[.seatedLikely], 0.80)
        XCTAssertGreaterThan(end.armBehavior[.deskLike], 0.7)
        XCTAssertEqual(end.displayContext, "Desk sitting")
        XCTAssertGreaterThan(end.history.stationaryForS, 300)
        XCTAssertGreaterThan(end.history.sinceLocomotionS ?? 0, 300)

        // Seated belief grows with dwell time; it is not a step function.
        let early = try XCTUnwrap(states(in: published, from: sitMoment + 10, to: sitMoment + 20).last)
        let mid = try XCTUnwrap(states(in: published, from: sitMoment + 100, to: sitMoment + 110).last)
        XCTAssertLessThan(early.posture[.seatedLikely], mid.posture[.seatedLikely] + 0.001)
        XCTAssertLessThan(mid.posture[.seatedLikely], end.posture[.seatedLikely] + 0.001)
    }

    func testSitToStandLikeShiftIsFlaggedBeforeWalking() throws {
        var sim = ActivitySim()
        sim.desk(300)
        let shiftTs = sim.ts
        sim.postureShift(netDegrees: -75, seconds: 3)
        sim.walk(40)
        let (_, published) = decode(sim)
        let flagged = published.compactMap { $0.transition }.filter { $0.kind == .sitToStandLike }
        XCTAssertFalse(flagged.isEmpty, "sit-to-stand-like should be flagged")
        XCTAssertLessThanOrEqual(try XCTUnwrap(flagged.first).ts - shiftTs, 15)
        XCTAssertEqual(try XCTUnwrap(published.last).locomotion.top?.0, .walking)
    }

    func testReachingAndReturningIsNotAPostureChange() {
        var sim = ActivitySim()
        sim.desk(200)
        sim.postureShift(netDegrees: 70, seconds: 3)
        sim.desk(2)
        sim.postureShift(netDegrees: -70, seconds: 3)
        sim.desk(120)
        let (_, published) = decode(sim)
        for kind in [ActivityTransitionKind.standToSitLike, .sitToStandLike, .lyingDownLike, .gettingUpLike] {
            XCTAssertFalse(anyEvent(published, kind), "\(kind) should not fire for a reach-and-return")
        }
        XCTAssertGreaterThan(published.last?.posture[.seatedLikely] ?? 0, 0.8)
    }

    func testSeatedVersusUprightStaysAmbiguousWithoutContext() throws {
        var sim = ActivitySim()
        sim.still(150)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        // A wrist cannot tell a quiet sitter from a quiet stander: both stay on the table.
        XCTAssertGreaterThan(end.posture[.seatedLikely], 0.15)
        XCTAssertGreaterThan(end.posture[.uprightStationary], 0.15)
        XCTAssertLessThan(end.posture[.seatedLikely], 0.8)
        XCTAssertLessThan(end.posture[.uprightStationary], 0.8)
        XCTAssertLessThan(end.overallConfidence, 0.75)
        XCTAssertEqual(end.locomotion.top?.0, .stationary)
        // The label hedges rather than asserting a posture.
        let label = try XCTUnwrap(end.displayContext)
        XCTAssertFalse(["Desk sitting", "Standing quietly"].contains(label), "got \(label)")
    }

    func testAStopAfterWalkingFavoursUprightOverSeated() throws {
        var sim = ActivitySim()
        sim.walk(60); sim.still(15)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertGreaterThan(end.posture[.uprightStationary], end.posture[.seatedLikely])
    }

    // MARK: Recumbent, sleep, getting up

    func testSleepIsRecumbentAndSaysAsleep() throws {
        var sim = ActivitySim()
        sim.sleeping(400)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertGreaterThan(end.posture[.recumbent], 0.85)
        XCTAssertEqual(end.locomotion.top?.0, .stationary)
        XCTAssertEqual(end.armBehavior.top?.0, .quiet)
        XCTAssertEqual(end.sleep.state, .asleep)
        XCTAssertEqual(end.displayContext, "Asleep")
        XCTAssertGreaterThan(end.overallConfidence, 0.7)
    }

    func testAQuietWristWithoutSleepEvidenceIsNotCalledRecumbent() throws {
        var sim = ActivitySim()
        sim.still(900)
        let (_, published) = decode(sim)
        for s in published.suffix(60) {
            XCTAssertLessThan(s.posture[.recumbent], 0.25, "at \(s.ts)")
        }
        XCTAssertNotEqual(published.last?.displayContext, "Asleep")
        XCTAssertNotEqual(published.last?.displayContext, "Lying down")
    }

    func testWakingAndGettingUpIsFlaggedAndLeavesRecumbent() throws {
        var sim = ActivitySim()
        sim.sleeping(500)
        var awake = ActivitySim.Options(); awake.sleep = .awake
        sim.still(30, opt: awake)
        let getUp = sim.ts
        sim.postureShift(netDegrees: 80, seconds: 4, opt: awake)
        sim.still(60, opt: awake)
        sim.walk(40, opt: awake)
        let (_, published) = decode(sim)

        let flagged = published.compactMap { $0.transition }.filter { $0.kind == .gettingUpLike }
        XCTAssertFalse(flagged.isEmpty)
        XCTAssertLessThanOrEqual(try XCTUnwrap(flagged.first).ts - getUp, 15)
        let before = try XCTUnwrap(states(in: published, from: getUp - 10, to: getUp - 1).last)
        XCTAssertGreaterThan(before.posture[.recumbent], 0.8)
        let later = try XCTUnwrap(states(in: published, from: getUp + 40, to: getUp + 70).last)
        XCTAssertLessThan(later.posture[.recumbent], 0.3)
        XCTAssertEqual(try XCTUnwrap(published.last).locomotion.top?.0, .walking)
    }

    func testSleepRecordsContradictedByWalkingAreNotTrusted() throws {
        var sim = ActivitySim()
        var asleep = ActivitySim.Options(); asleep.sleep = .asleep
        sim.sleeping(120)
        sim.walk(90, opt: asleep)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertNotEqual(end.displayContext, "Asleep")
        XCTAssertLessThan(end.posture[.recumbent], 0.3)
        XCTAssertGreaterThan(end.locomotion[.walking] + end.locomotion[.briskWalking] + end.locomotion[.unknown], 0.7)
    }

    // MARK: Arm behaviour

    func testDeskLikeMotionIsNotCalledTyping() throws {
        var sim = ActivitySim()
        sim.still(30); sim.desk(300)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertGreaterThan(end.armBehavior[.deskLike], 0.7)
        XCTAssertGreaterThan(end.posture[.seatedLikely], end.posture[.uprightStationary])
        XCTAssertEqual(end.displayContext, "Desk sitting")
        XCTAssertLessThan(end.intensity ?? 1, 0.55)
        XCTAssertFalse((end.displayContext ?? "").lowercased().contains("typing"))
        // No ontology class claims typing.
        XCTAssertFalse(ArmBehaviorClass.allCases.map(\.rawValue).contains { $0.contains("typ") })
    }

    func testFidgetingIsSeparatedFromDeskLikeMotion() throws {
        var fidget = ActivitySim()
        fidget.still(20); fidget.fidget(150)
        let (_, fPublished) = decode(fidget)
        let fWindow = states(in: fPublished, from: fidget.observations[40].ts, to: fidget.observations.last!.ts)
        let fidgetShare = Double(fWindow.filter { $0.armBehavior.top?.0 == .fidgeting }.count) / Double(fWindow.count)
        XCTAssertGreaterThan(fidgetShare, 0.5)

        var desk = ActivitySim()
        desk.still(20); desk.desk(150)
        let (_, dPublished) = decode(desk)
        let dWindow = states(in: dPublished, from: desk.observations[40].ts, to: desk.observations.last!.ts)
        let deskFidget = Double(dWindow.filter { $0.armBehavior.top?.0 == .fidgeting }.count) / Double(dWindow.count)
        XCTAssertLessThan(deskFidget, 0.1)
        XCTAssertGreaterThan(Double(dWindow.filter { $0.armBehavior.top?.0 == .deskLike }.count) / Double(dWindow.count), 0.8)
    }

    func testFidgetingDoesNotChangeThePostureHypothesis() throws {
        var sim = ActivitySim()
        sim.desk(200); sim.fidget(120)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertGreaterThan(end.posture[.seatedLikely], 0.75)
        XCTAssertFalse(anyEvent(published, .standToSitLike))
        XCTAssertFalse(anyEvent(published, .sitToStandLike))
    }

    // MARK: Wear

    func testOffWristSuspendsInferenceAndClaimsNothing() throws {
        var sim = ActivitySim()
        sim.walk(60)
        let offAt = sim.ts
        sim.offWrist(90)
        let (_, published) = decode(sim)
        let during = states(in: published, from: offAt + 5, to: sim.ts)
        XCTAssertFalse(during.isEmpty)
        for s in during {
            XCTAssertEqual(s.wear.state, .offWrist)
            XCTAssertEqual(s.displayContext, "Off wrist")
            XCTAssertEqual(s.overallConfidence, 0, accuracy: 1e-9)
            XCTAssertEqual(s.posture[.unknown], 1, accuracy: 1e-9)
            XCTAssertEqual(s.locomotion[.unknown], 1, accuracy: 1e-9)
            XCTAssertNil(s.intensity)
        }
    }

    func testReturningToTheWristStartsFromScratchNotFromTheOldActivity() throws {
        var sim = ActivitySim()
        sim.walk(90)
        sim.offWrist(60)
        sim.still(40)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertEqual(end.wear.state, .onWrist)
        XCTAssertLessThan(end.locomotion[.walking] + end.locomotion[.briskWalking], 0.1)
        XCTAssertEqual(end.locomotion.top?.0, .stationary)
        XCTAssertNotEqual(end.displayContext, "Off wrist")
        // And it did not carry a "stationary since" clock across the gap.
        XCTAssertLessThan(end.history.stationaryForS, 60)
    }

    func testAQuietImuIsNeverTakenAsOffWristEvidence() {
        var sim = ActivitySim()
        sim.still(900)
        let (_, published) = decode(sim)
        XCTAssertTrue(published.allSatisfy { $0.wear.state != .offWrist })
        XCTAssertNotEqual(published.last?.displayContext, "Off wrist")
    }

    // MARK: Conflicting, noisy and missing inputs

    func testAnEncoderThatContradictsAQuietWristDoesNotWinButLowersConfidence() throws {
        var control = ActivitySim()
        control.still(120)
        let (_, controlStates) = decode(control)

        var conflict = ActivitySim()
        var opt = ActivitySim.Options(); opt.encoder = SimEncoder.coarse("running")
        conflict.still(120, opt: opt)
        let (_, conflictStates) = decode(conflict)

        let c = try XCTUnwrap(conflictStates.last), k = try XCTUnwrap(controlStates.last)
        XCTAssertLessThan(c.locomotion[.running], 0.2)
        XCTAssertEqual(c.locomotion.top?.0, .stationary)
        XCTAssertLessThan(c.overallConfidence, k.overallConfidence - 0.05)
        XCTAssertGreaterThan(c.overallUncertainty, k.overallUncertainty)
        let label = try XCTUnwrap(c.displayContext)
        XCTAssertFalse(["Desk sitting", "Standing quietly", "Running"].contains(label))
    }

    func testAnAbstainingEncoderHasLittleInfluence() throws {
        var sim = ActivitySim()
        var abstained = ActivitySim.Options()
        abstained.encoder = { ts in
            guard ts % 2 == 0 else { return nil }
            return MotionEncoderOutput(encoderId: "hart", encoderVersion: "t", startTs: ts - 4, endTs: ts,
                                       classProbs: ["running": 0.4, "walking": 0.3, "stationary": 0.2, "other_movement": 0.1],
                                       calibrated: true, abstained: true)
        }
        sim.still(120, opt: abstained)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertEqual(end.locomotion.top?.0, .stationary)
        XCTAssertLessThan(end.locomotion[.running], 0.1)
    }

    func testWalkingEvidenceStillWinsWhenTheEncoderHasNoOpinion() throws {
        var sim = ActivitySim()
        sim.still(20); sim.walk(60)
        let (_, published) = decode(sim)
        XCTAssertEqual(published.last?.locomotion.top?.0, .walking)
        XCTAssertEqual(published.last?.evidence.encoder, false)
    }

    func testIsolatedSensorSpikesDoNotMakeTheWearerWalk() throws {
        var sim = ActivitySim(seed: 23)
        for _ in 0..<300 {
            if sim.rand() < 0.12 {
                sim.emit(dyn: 0.3 + sim.rand() * 0.5, ticks: 0, cls: 0, rotate: sim.noise(3), opt: ActivitySim.Options())
            } else {
                sim.still(1)
            }
        }
        let (_, published) = decode(sim)
        XCTAssertLessThan(published.map { $0.locomotion[.walking] + $0.locomotion[.briskWalking] + $0.locomotion[.running] }.max() ?? 0, 0.3)
        XCTAssertFalse(anyEvent(published, .walkStart))
        XCTAssertEqual(published.last?.locomotion.top?.0, .stationary)
    }

    func testStepsWithAQuietWristAreNotForcedIntoACleanWalkingClaim() throws {
        // A hand on a treadmill rail or a stroller: the step counter ticks but the wrist hardly moves.
        // The channels disagree, so the decoder may lean on the step counter but must say it is less sure.
        var normal = ActivitySim()
        normal.still(20); normal.walk(90)
        var rail = ActivitySim()
        rail.still(20)
        for i in 0..<90 {
            rail.emit(dyn: 0.02, ticks: i % 2 == 0 ? 2 : 1, cls: 1, rotate: 0, jitter: 1, opt: ActivitySim.Options())
        }
        let (_, n) = decode(normal), (_, r) = decode(rail)
        let walking = try XCTUnwrap(n.last), railing = try XCTUnwrap(r.last)
        XCTAssertLessThan(railing.overallConfidence, walking.overallConfidence - 0.1)
        XCTAssertGreaterThan(railing.overallUncertainty, walking.overallUncertainty)
    }

    func testHeartRateAloneSaysUnknownNotAGuess() throws {
        var sim = ActivitySim()
        var o = ActivitySim.Options(); o.dyn = false; o.gravity = false; o.steps = false; o.hr = 72
        sim.still(120, opt: o)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertLessThan(end.overallConfidence, 0.1)
        XCTAssertNil(end.displayContext)
        XCTAssertGreaterThan(end.posture[.unknown] + end.locomotion[.unknown], 1.0)
        XCTAssertFalse(end.evidence.dynAccel)
        XCTAssertTrue(end.evidence.heartRate)
    }

    func testMissingGravityStepsAndHeartRateStillDecodeADeskButWithLessConfidence() throws {
        var full = ActivitySim()
        full.desk(180)
        let (_, fullStates) = decode(full)

        var sparse = ActivitySim()
        var o = ActivitySim.Options(); o.gravity = false; o.steps = false; o.hr = nil
        sparse.desk(180, opt: o)
        let (_, sparseStates) = decode(sparse)

        let f = try XCTUnwrap(fullStates.last), s = try XCTUnwrap(sparseStates.last)
        XCTAssertGreaterThan(s.posture[.seatedLikely], 0.8)
        XCTAssertEqual(s.armBehavior.top?.0, .deskLike)
        XCTAssertLessThan(s.overallConfidence, f.overallConfidence)
        XCTAssertLessThan(s.evidence.coverage, f.evidence.coverage)
        XCTAssertFalse(s.evidence.gravity)
        XCTAssertFalse(s.evidence.steps)
    }

    func testIntermittentSensorDropoutsDoNotBreakWalkingDetection() throws {
        var sim = ActivitySim()
        sim.still(20)
        for i in 0..<90 {
            var o = ActivitySim.Options()
            o.dyn = i % 3 != 0
            o.steps = i % 4 != 0
            o.gravity = i % 5 != 0
            sim.walk(1, opt: o)
        }
        let (_, published) = decode(sim)
        XCTAssertEqual(published.last?.locomotion.top?.0, .walking)
    }

    func testWithoutAnyMotionChannelNothingIsClaimed() throws {
        var sim = ActivitySim()
        var o = ActivitySim.Options(); o.dyn = false; o.gravity = false; o.steps = false
        o.encoder = SimEncoder.coarse("walking")
        sim.still(120, opt: o)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertLessThan(end.overallConfidence, 0.5)
        XCTAssertFalse(end.evidence.dynAccel)
        XCTAssertTrue(end.evidence.encoder)
    }

    func testADataGapAboveTheResetThresholdForgetsTheOldContext() throws {
        var sim = ActivitySim()
        sim.walk(60)
        sim.gap(600)
        sim.still(40)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertLessThan(end.locomotion[.walking] + end.locomotion[.briskWalking], 0.1)
    }

    func testADataGapClearsTheDisplayLabelAndHysteresisCandidate() throws {
        // WS-05-F03: after a >120 s gap the decoder must not carry the pre-gap display label or its
        // hysteresis candidate into the new context. A session that ended walking, then a gap, then a
        // quiet wrist must not keep reading "Walking" for the first post-gap seconds.
        var sim = ActivitySim()
        sim.walk(90)
        let gapStart = sim.ts
        sim.gap(600)
        sim.still(40)
        let (_, published) = decode(sim)
        let afterGap = states(in: published, from: gapStart, to: published.last!.ts)
        XCTAssertFalse(afterGap.isEmpty)
        let first = try XCTUnwrap(afterGap.first)
        XCTAssertLessThan(first.locomotion[.walking] + first.locomotion[.briskWalking], 0.1,
                          "the post-gap heads must not read walking")
        XCTAssertNotEqual(first.displayContext, "Walking",
                          "the stale pre-gap label must not survive the gap")
        let end = try XCTUnwrap(published.last)
        XCTAssertEqual(end.locomotion.top?.0, .stationary)
    }

    func testAShortGapKeepsTheContext() throws {
        var sim = ActivitySim()
        sim.desk(240)
        sim.gap(30)
        sim.desk(30)
        let (_, published) = decode(sim)
        let end = try XCTUnwrap(published.last)
        XCTAssertGreaterThan(end.posture[.seatedLikely], 0.8)
        XCTAssertEqual(end.displayContext, "Desk sitting")
    }

    // MARK: Stability

    func testRapidAlternationDoesNotFlipTheLabelEveryCycle() throws {
        var sim = ActivitySim()
        sim.desk(120)
        for _ in 0..<12 { sim.walk(6); sim.desk(6) }
        let (_, published) = decode(sim)
        let window = states(in: published, from: sim.observations[120].ts, to: sim.observations.last!.ts)
        // 24 raw alternations; the published label must change far less often.
        XCTAssertLessThanOrEqual(labelChanges(window), 6)
    }

    func testLabelDoesNotFlickerOnSteadyStreams() {
        var sim = ActivitySim()
        sim.still(40); sim.desk(240); sim.walk(120); sim.desk(240)
        let (_, published) = decode(sim)
        // desk → walk → desk is at most a handful of label changes (initial settling included).
        XCTAssertLessThanOrEqual(labelChanges(published), 7)
    }

    func testTheTopLocomotionClassIsStableDuringSteadyWalking() throws {
        var sim = ActivitySim()
        sim.still(20); sim.walk(180)
        let (_, published) = decode(sim)
        let steady = states(in: published, from: sim.observations[50].ts, to: sim.observations.last!.ts)
        let tops = steady.compactMap { $0.locomotion.top?.0 }
        XCTAssertEqual(Set(tops).count, 1)
    }

    // MARK: Restart and restoration

    func testRestoringFromASnapshotContinuesExactly() throws {
        var sim = ActivitySim()
        sim.desk(200); sim.walk(60); sim.still(40); sim.postureShift(netDegrees: 70, seconds: 3); sim.desk(100)
        let obs = sim.observations
        let cut = 330

        var whole = ActivityContextDecoder()
        let reference = whole.run(obs)

        var first = ActivityContextDecoder()
        let head = first.run(Array(obs[..<cut]))
        let data = try JSONEncoder().encode(first.snapshot())
        let restoredSnapshot = try JSONDecoder().decode(ActivityDecoderSnapshot.self, from: data)
        var second = ActivityContextDecoder(restoring: restoredSnapshot)
        XCTAssertEqual(second.restoreOutcome, .resumed)
        let tail = second.run(Array(obs[cut...]))

        let combined = head + tail
        XCTAssertEqual(combined.map(\.ts), reference.map(\.ts))
        for (a, b) in zip(combined, reference) {
            XCTAssertEqual(a.displayContext, b.displayContext)
            XCTAssertEqual(a.overallConfidence, b.overallConfidence, accuracy: 1e-9)
            for c in PostureClass.allCases { XCTAssertEqual(a.posture[c], b.posture[c], accuracy: 1e-9) }
            for c in LocomotionClass.allCases { XCTAssertEqual(a.locomotion[c], b.locomotion[c], accuracy: 1e-9) }
            for c in ArmBehaviorClass.allCases { XCTAssertEqual(a.armBehavior[c], b.armBehavior[c], accuracy: 1e-9) }
            XCTAssertEqual(a.history.recentEvents, b.history.recentEvents)
        }
    }

    func testRestoredDecoderKeepsItsEventHistoryAndHysteresis() throws {
        var sim = ActivitySim()
        sim.still(20); sim.walk(60)
        var first = ActivityContextDecoder()
        let head = first.run(sim.observations)
        let label = try XCTUnwrap(head.last?.displayContext)
        var second = ActivityContextDecoder(restoring: first.snapshot())
        var more = ActivitySim(start: sim.ts)
        more.walk(10)
        let tail = second.run(more.observations)
        XCTAssertEqual(tail.first?.displayContext, label)
        XCTAssertEqual(tail.last?.history.recentEvents.filter { $0.kind == .walkStart }.count, 1)
    }

    func testASnapshotFromAnotherDecoderOrOntologyIsDiscardedNotMixed() throws {
        var sim = ActivitySim()
        sim.desk(120)
        var d = ActivityContextDecoder()
        _ = d.run(sim.observations)

        var wrongDecoder = d.snapshot()
        wrongDecoder.versions.decoder = "hsmm-0.9"
        XCTAssertEqual(ActivityContextDecoder(restoring: wrongDecoder).restoreOutcome, .discarded("version_mismatch"))

        var wrongOntology = d.snapshot()
        wrongOntology.versions.ontology = "v1"
        XCTAssertEqual(ActivityContextDecoder(restoring: wrongOntology).restoreOutcome, .discarded("version_mismatch"))

        var wrongFeatures = d.snapshot()
        wrongFeatures.versions.featureSchema = "imu-feat-0"
        XCTAssertEqual(ActivityContextDecoder(restoring: wrongFeatures).restoreOutcome, .discarded("version_mismatch"))

        var corrupt = d.snapshot()
        corrupt.body = [1, 2, 3]
        XCTAssertEqual(ActivityContextDecoder(restoring: corrupt).restoreOutcome, .discarded("layout_mismatch"))

        var fresh = ActivityContextDecoder(restoring: wrongDecoder)
        XCTAssertNil(fresh.lastObservationTs)
        XCTAssertEqual(ActivityContextDecoder(restoring: nil).restoreOutcome, .fresh)
        XCTAssertEqual(ActivityContextDecoder(restoring: d.snapshot()).restoreOutcome, .resumed)
        // A discarded snapshot behaves exactly like a fresh decoder.
        var plain = ActivityContextDecoder()
        let a = fresh.run(sim.observations), b = plain.run(sim.observations)
        XCTAssertEqual(a.last?.posture, b.last?.posture)
    }

    func testRestoringAfterALongDowntimeStartsOverButKeepsRecentHistory() throws {
        var sim = ActivitySim()
        sim.still(20); sim.walk(60)
        var first = ActivityContextDecoder()
        _ = first.run(sim.observations)
        var second = ActivityContextDecoder(restoring: first.snapshot())
        var later = ActivitySim(start: sim.ts + 1800)
        later.still(60)
        let tail = second.run(later.observations)
        let end = try XCTUnwrap(tail.last)
        XCTAssertLessThan(end.locomotion[.walking] + end.locomotion[.briskWalking], 0.1)
        // The walk is older than the 15-minute history window, so it is gone from the history too.
        XCTAssertTrue(end.history.recentEvents.filter { $0.kind == .walkStart }.isEmpty)
    }

    // MARK: Encoder independence

    func testDecoderIsEncoderAgnosticAndRecordsWhichEncoderSpoke() throws {
        func run(_ id: String) throws -> ActivityContextState {
            var sim = ActivitySim()
            var o = ActivitySim.Options()
            let base = SimEncoder.coarse("walking")
            o.encoder = { ts in
                guard let e = base(ts) else { return nil }
                return MotionEncoderOutput(encoderId: id, encoderVersion: "x-9", startTs: e.startTs, endTs: e.endTs,
                                           classProbs: e.classProbs, calibrated: true, abstained: false)
            }
            sim.still(20); sim.walk(60, opt: o)
            let (_, published) = decode(sim)
            return try XCTUnwrap(published.last)
        }
        let hart = try run("hart-tspulse"), other = try run("inertia-1")
        XCTAssertEqual(hart.versions.encoderId, "hart-tspulse")
        XCTAssertEqual(other.versions.encoderId, "inertia-1")
        XCTAssertEqual(hart.versions.encoderVersion, "x-9")
        XCTAssertEqual(hart.locomotion, other.locomotion)
        XCTAssertEqual(hart.posture, other.posture)
    }

    func testEncoderEvidenceAddsConfidenceWhenItAgrees() throws {
        var plain = ActivitySim()
        plain.still(20); plain.walk(25)
        var supported = ActivitySim()
        var o = ActivitySim.Options(); o.encoder = SimEncoder.coarse("walking")
        supported.still(20, opt: o); supported.walk(25, opt: o)
        let (_, p) = decode(plain), (_, s) = decode(supported)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(s.last).overallConfidence, try XCTUnwrap(p.last).overallConfidence - 0.001)
        XCTAssertTrue(try XCTUnwrap(s.last).evidence.encoder)
    }

    func testAnUncalibratedBaselineEncoderCarriesLessWeightThanACalibratedOne() throws {
        func final(_ baseline: Bool) throws -> ActivityContextState {
            var sim = ActivitySim()
            var o = ActivitySim.Options(); o.encoder = SimEncoder.coarse("walking", baseline: baseline)
            sim.walk(8, opt: o)
            var d = ActivityContextDecoder()
            _ = d.run(sim.observations)
            return try XCTUnwrap(d.currentState())
        }
        let hart = try final(false), baseline = try final(true)
        XCTAssertGreaterThanOrEqual(hart.locomotion[.walking] + hart.locomotion[.briskWalking],
                                    baseline.locomotion[.walking] + baseline.locomotion[.briskWalking] - 1e-9)
    }

    // MARK: Learned raw-IMU transition expert

    private func eventProbability(_ states: [ActivityContextState], _ kind: ActivityTransitionKind) -> Double {
        states.flatMap { $0.history.recentEvents }.filter { $0.kind == kind }.map { $0.probability }.max() ?? 0
    }

    func testSitToStandTransitionEvidenceRaisesTheSitToStandPosterior() throws {
        // A sit-to-stand shift (desk → burst that leaves the wrist elsewhere → walk). The learned expert
        // naming sit-to-stand must lift the sit-to-stand mass (the posture head's postural-transition
        // share and the sit-to-stand-like event probability) above the same stream without it.
        var sim = ActivitySim()
        sim.desk(300)
        let shiftStart = sim.ts
        sim.postureShift(netDegrees: -75, seconds: 3)
        sim.walk(40)
        let plain = sim.observations
        let expert = withTransition(plain, when: { $0 >= shiftStart - 1 && $0 < shiftStart + 8 },
                                    none: 0.06, sitToStand: 0.85)

        let (_, plainStates) = decode(plain)
        let (_, expertStates) = decode(expert)

        let withPeak = peakPostural(expertStates, from: shiftStart, to: shiftStart + 10)
        let withoutPeak = peakPostural(plainStates, from: shiftStart, to: shiftStart + 10)
        XCTAssertGreaterThan(withPeak, withoutPeak + 0.05,
                             "the expert's sit-to-stand claim must raise the transition mass")
        // The sit-to-stand-like event fires in both streams; the expert raises its probability (the
        // sitToStand posterior at flag time).
        let plainProb = eventProbability(plainStates, .sitToStandLike)
        let expertProb = eventProbability(expertStates, .sitToStandLike)
        XCTAssertGreaterThan(expertProb, 0.5)
        XCTAssertGreaterThan(expertProb, plainProb + 0.1)
    }

    func testStandToSitTransitionEvidenceRaisesTheStandToSitPosterior() throws {
        // The same claim for stand-to-sit, the transition that ends standing (walk → stop → shift that
        // leaves the wrist lower → desk). The expert naming stand-to-sit must raise the stand-to-sit
        // mass and the stand-to-sit-like event probability over the same stream without it.
        var sim = ActivitySim()
        sim.walk(60); sim.still(8)
        let shiftStart = sim.ts
        sim.postureShift(netDegrees: 70, seconds: 3)
        sim.desk(60)
        let plain = sim.observations
        let expert = withTransition(plain, when: { $0 >= shiftStart - 1 && $0 < shiftStart + 8 },
                                    none: 0.06, standToSit: 0.85)

        let (_, plainStates) = decode(plain)
        let (_, expertStates) = decode(expert)
        let withPeak = peakPostural(expertStates, from: shiftStart, to: shiftStart + 10)
        let withoutPeak = peakPostural(plainStates, from: shiftStart, to: shiftStart + 10)
        XCTAssertGreaterThan(withPeak, withoutPeak + 0.05)
        let plainProb = eventProbability(plainStates, .standToSitLike)
        let expertProb = eventProbability(expertStates, .standToSitLike)
        XCTAssertGreaterThan(expertProb, 0.4)
        XCTAssertGreaterThan(expertProb, plainProb + 0.1)
    }

    func testGettingUpAndLyingDownEvidenceRaiseTheirModes() throws {
        // Getting up: waking in bed, a shift that leaves the wrist up, then walking. The expert naming
        // get-up raises the getting-up-like event probability over the same stream without it.
        var sim = ActivitySim()
        sim.sleeping(400)
        var awake = ActivitySim.Options(); awake.sleep = .awake
        sim.still(20, opt: awake)
        let upShift = sim.ts
        sim.postureShift(netDegrees: 80, seconds: 4, opt: awake)
        sim.walk(40, opt: awake)
        let plain = sim.observations
        let expert = withTransition(plain, when: { $0 >= upShift - 1 && $0 < upShift + 8 },
                                    none: 0.06, getUp: 0.85)
        let (_, plainStates) = decode(plain)
        let (_, expertStates) = decode(expert)
        let plainProb = eventProbability(plainStates, .gettingUpLike)
        let expertProb = eventProbability(expertStates, .gettingUpLike)
        XCTAssertGreaterThan(expertProb, 0.5)
        XCTAssertGreaterThan(expertProb, plainProb + 0.1)

        // Lying down: desk → a shift that leaves the wrist recumbent → sleep. The shift alone leaves the
        // transition direction ambiguous (no lying-down-like event without the expert); the expert
        // naming lie-down disambiguates it and flags the event.
        var bed = ActivitySim()
        bed.desk(200)
        let lieShift = bed.ts
        bed.postureShift(netDegrees: -70, seconds: 3)
        bed.sleeping(60)
        let bedPlain = bed.observations
        let bedExpert = withTransition(bedPlain, when: { $0 >= lieShift - 1 && $0 < lieShift + 8 },
                                       none: 0.06, lieDown: 0.85)
        let (_, bedPlainStates) = decode(bedPlain)
        let (_, bedExpertStates) = decode(bedExpert)
        XCTAssertFalse(anyEvent(bedPlainStates, .lyingDownLike),
                       "the shift alone must not name lying-down")
        XCTAssertTrue(anyEvent(bedExpertStates, .lyingDownLike),
                      "the expert naming lie-down must disambiguate the shift")
        XCTAssertGreaterThan(eventProbability(bedExpertStates, .lyingDownLike), 0.6)
    }

    func testNoneDominantEvidenceSuppressesUnsupportedTransitionMass() throws {
        // A posture-shift stream (channel 3b supports the transition modes). The expert saying "none"
        // must pull the transition mass back down compared with the same stream without it.
        var sim = ActivitySim()
        sim.desk(150)
        let shiftStart = sim.ts
        sim.postureShift(netDegrees: 70, seconds: 3)
        sim.desk(90)
        let plain = sim.observations
        let noneDominant = withTransition(plain, when: { $0 >= shiftStart - 1 && $0 < shiftStart + 8 },
                                          none: 0.94, sitToStand: 0.02, standToSit: 0.02,
                                          lieDown: 0.01, getUp: 0.01)

        let (_, a) = decode(plain)
        let (_, b) = decode(noneDominant)
        let peakA = peakPostural(a, from: shiftStart, to: shiftStart + 10)
        let peakB = peakPostural(b, from: shiftStart, to: shiftStart + 10)
        XCTAssertGreaterThan(peakA, peakB + 0.1,
                             "a confident 'none' must suppress the transition mass the shift alone would raise")
        // The expert's "none" must never itself raise a transition mode above the fallback's level.
        XCTAssertLessThan(peakB, 0.20)
        for kind in [ActivityTransitionKind.standToSitLike, .sitToStandLike, .lyingDownLike, .gettingUpLike] {
            XCTAssertFalse(anyEvent(b, kind), "\(kind) must not fire under a dominant 'none'")
        }
    }

    func testNoneEvidenceLeavesLocomotionMassUnchanged() throws {
        // "None" is "no posture change", which walking and running satisfy too: a confident none on
        // every second must not drain locomotion mass toward the stationary modes.
        var sim = ActivitySim()
        sim.still(60); sim.walk(180); sim.walk(120, brisk: true)
        let plain = sim.observations
        let none = withTransition(plain, when: { _ in true }, none: 0.94, sitToStand: 0.02,
                                  standToSit: 0.02, lieDown: 0.01, getUp: 0.01)
        let (_, a) = decode(plain)
        let (_, b) = decode(none)
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            let moveA = x.locomotion[.walking] + x.locomotion[.briskWalking] + x.locomotion[.running]
            let moveB = y.locomotion[.walking] + y.locomotion[.briskWalking] + y.locomotion[.running]
            XCTAssertEqual(moveA, moveB, accuracy: 0.02, "at \(x.ts)")
        }
    }

    func testAbsentOrAbstainedTransitionEvidenceIsExactlyTodaySBehavior() throws {
        // The channel is skipped when the expert is absent or abstains: the published states and events
        // must be bit-for-bit what they were before the expert existed.
        var sim = ActivitySim()
        sim.desk(120); sim.postureShift(netDegrees: 70, seconds: 3); sim.walk(60); sim.still(60)
        let plain = sim.observations
        let abstained = withTransition(plain, when: { $0 % 7 == 0 }, none: 0.06, sitToStand: 0.85,
                                       abstained: true)

        let (_, a) = decode(plain)
        let (_, b) = decode(abstained)
        XCTAssertEqual(a.map { $0.ts }, b.map { $0.ts })
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.posture, y.posture, "at \(x.ts)")
            XCTAssertEqual(x.locomotion, y.locomotion, "at \(x.ts)")
            XCTAssertEqual(x.armBehavior, y.armBehavior, "at \(x.ts)")
            XCTAssertEqual(x.displayContext, y.displayContext, "at \(x.ts)")
            XCTAssertEqual(x.overallConfidence, y.overallConfidence, accuracy: 1e-12, "at \(x.ts)")
            XCTAssertEqual(x.overallUncertainty, y.overallUncertainty, accuracy: 1e-12, "at \(x.ts)")
            XCTAssertEqual(x.transition, y.transition)
            XCTAssertEqual(x.history.recentEvents, y.history.recentEvents, "at \(x.ts)")
        }
    }

    func testTransitionEvidenceAgesOutAndDecaysWithWindowAge() throws {
        // A single second of expert evidence on a quiet desk stream: it lifts the transition mass while
        // it is young (full weight up to 2 s, then decaying), and once it is older than the 6 s hold it
        // is dropped, so the stream converges back to the one with no expert.
        var sim = ActivitySim()
        sim.desk(180)
        let evStart = sim.ts
        sim.desk(20)
        let plain = sim.observations
        let oneShot = withTransition(plain, when: { $0 == evStart }, none: 0.06, sitToStand: 0.85)

        let (_, plainStates) = decode(plain)
        let (_, oneStates) = decode(oneShot)

        func postural(at ts: Int, _ states: [ActivityContextState]) -> Double {
            states.first { $0.ts == ts }?.posture[PostureClass.posturalTransition] ?? 0
        }
        // Fresh evidence (age 0–2 s, full weight) lifts the sit-to-stand mass above the plain stream.
        let fresh = postural(at: evStart, oneStates) - postural(at: evStart, plainStates)
        XCTAssertGreaterThan(fresh, 1e-6, "young evidence must be felt")
        // 5 s later the weight has decayed to 0.5× (and the posterior relaxes): the lift is smaller.
        let aged = postural(at: evStart + 5, oneStates) - postural(at: evStart + 5, plainStates)
        XCTAssertLessThan(aged, fresh, "the evidence's effect must decay as it ages")
        XCTAssertGreaterThan(aged, 0, "the decayed evidence is still (weakly) present at age 5")
        // Past the 6 s hold the evidence is dropped: the difference collapses to ~0.
        XCTAssertEqual(postural(at: evStart + 10, oneStates), postural(at: evStart + 10, plainStates),
                       accuracy: 1e-6, "evidence older than the hold is ignored")
        XCTAssertEqual(postural(at: evStart + 15, oneStates), postural(at: evStart + 15, plainStates),
                       accuracy: 1e-8, "the posterior converges back to the no-expert stream")
    }

    func testTransitionEncoderEvidenceCodableRoundTripUsesSnakeCaseKeys() throws {
        let evidence = TransitionEncoderEvidence(none: 0.10, sitToStand: 0.60, standToSit: 0.10,
                                                 lieDown: 0.05, getUp: 0.15, confidence: 0.72,
                                                 modelVersion: "transition-test-1",
                                                 preprocessingVersion: "transition-feat-1",
                                                 abstained: false)
        let data = try JSONEncoder().encode(evidence)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys),
                       Set(["none", "sit_to_stand", "stand_to_sit", "lie_down", "get_up",
                            "confidence", "model_version", "preprocessing_version", "abstained"]))
        XCTAssertEqual(json["sit_to_stand"] as? Double, 0.60)
        XCTAssertEqual(json["model_version"] as? String, "transition-test-1")
        XCTAssertEqual(json["preprocessing_version"] as? String, "transition-feat-1")

        let back = try JSONDecoder().decode(TransitionEncoderEvidence.self, from: data)
        XCTAssertEqual(back, evidence)
        // Re-encoding the decoded value is a fixed point.
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(back)) as? NSDictionary
        XCTAssertEqual(again, json as NSDictionary)
    }

    func testLearnedNoneEvidenceDoesNotFirePosturalEventsInNegativeScenarios() throws {
        // Reach-and-return, fidgeting and walking arm-swing are not posture changes. A learned expert
        // that says "none" throughout must keep the no-model fallback from firing postural events.
        func noneThrough(_ obs: [ActivityObservation]) -> [ActivityObservation] {
            withTransition(obs, when: { _ in true }, none: 0.94, sitToStand: 0.02, standToSit: 0.02,
                           lieDown: 0.01, getUp: 0.01)
        }
        var reach = ActivitySim()
        reach.desk(200); reach.postureShift(netDegrees: 70, seconds: 3); reach.desk(2)
        reach.postureShift(netDegrees: -70, seconds: 3); reach.desk(120)
        let (_, reachStates) = decode(noneThrough(reach.observations))
        for kind in [ActivityTransitionKind.standToSitLike, .sitToStandLike, .lyingDownLike, .gettingUpLike] {
            XCTAssertFalse(anyEvent(reachStates, kind), "\(kind) must not fire for a reach-and-return")
        }

        var fidget = ActivitySim()
        fidget.still(20); fidget.fidget(150)
        let (_, fidgetStates) = decode(noneThrough(fidget.observations))
        for kind in [ActivityTransitionKind.standToSitLike, .sitToStandLike, .lyingDownLike, .gettingUpLike] {
            XCTAssertFalse(anyEvent(fidgetStates, kind), "\(kind) must not fire for fidgeting")
        }

        var swing = ActivitySim()
        swing.still(20); swing.walk(90)
        let (_, swingStates) = decode(noneThrough(swing.observations))
        for kind in [ActivityTransitionKind.standToSitLike, .sitToStandLike, .lyingDownLike, .gettingUpLike] {
            XCTAssertFalse(anyEvent(swingStates, kind), "\(kind) must not fire for walking arm-swing")
        }
    }
}
