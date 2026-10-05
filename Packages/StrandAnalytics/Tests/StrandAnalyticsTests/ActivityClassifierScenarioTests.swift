import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The canonical class end to end: synthetic wrist streams → decoder (`hsmm-1.2`) → class.
///
/// What is pinned is *behaviour a person would notice*: a night reads as sleeping, a stroll as walking, a
/// desk as sitting at a desk — and, new in `hsmm-1.2`, that effortful movement with no gait is called
/// higher-intensity activity only when the heart agrees, and that a recovering heart is not mistaken for
/// effort. The numbers behind the model are priors and are free to move; these scenarios are not.
final class ActivityClassifierScenarioTests: XCTestCase {

    // MARK: Helpers

    private func decode(_ sim: ActivitySim) -> [ActivityContextState] {
        var d = ActivityContextDecoder()
        return d.run(sim.observations)
    }

    private func classes(_ states: [ActivityContextState], from: Int, to: Int) -> [ActivityClassification] {
        states.filter { $0.ts >= from && $0.ts < to }.map(ActivityClassifier.classify(state:))
    }

    private func share(_ ks: [ActivityClassification], of wanted: Set<ActivityClass>) -> Double {
        guard !ks.isEmpty else { return 0 }
        return Double(ks.filter { wanted.contains($0.activityClass) }.count) / Double(ks.count)
    }

    private func last(_ states: [ActivityContextState], before ts: Int) -> ActivityClassification? {
        states.last { $0.ts < ts }.map(ActivityClassifier.classify(state:))
    }

    /// Heart rate that climbs linearly from `from` to `to` over `rampS`, holds, then recovers.
    private func effortHR(start: Int, rampS: Int, holdS: Int, recoverS: Int, rest: Int = 62, peak: Int = 150,
                          floorAfter: Int = 96) -> (Int) -> Int? {
        return { ts in
            if ts < start { return rest }
            let e = ts - start
            if e < rampS { return rest + 8 + Int(Double(e) / Double(rampS) * Double(peak - rest - 8)) }
            if e < rampS + holdS { return peak }
            let r = e - rampS - holdS
            return max(floorAfter, peak - Int(Double(r) / Double(recoverS) * Double(peak - floorAfter)))
        }
    }

    // MARK: A day reads as the right classes

    func testAMixedDayReadsAsTheRightClasses() throws {
        var sim = ActivitySim()
        sim.still(40); sim.desk(200)
        let walkStart = sim.ts; sim.walk(120)
        let runStart = sim.ts; sim.run(110)
        sim.walk(40); sim.still(90)
        let sleepStart = sim.ts
        var sleepOpt = ActivitySim.Options(); sleepOpt.sleep = .asleep
        sim.sleeping(420, opt: sleepOpt)
        let offStart = sim.ts; sim.offWrist(40)
        let states = decode(sim)

        let desk = try XCTUnwrap(last(states, before: walkStart))
        XCTAssertTrue([.sittingDesk, .sitting].contains(desk.activityClass), "got \(desk.activityClass)")
        XCTAssertGreaterThan(desk.confidence, 0.5)

        XCTAssertGreaterThan(share(classes(states, from: walkStart + 40, to: runStart), of: [.walking, .briskWalking]), 0.9)
        XCTAssertGreaterThan(share(classes(states, from: runStart + 40, to: runStart + 110), of: [.running]), 0.9)

        let night = classes(states, from: sleepStart + 90, to: offStart)
        XCTAssertGreaterThan(share(night, of: [.sleeping]), 0.95)
        XCTAssertGreaterThan(night.map(\.confidence).min() ?? 0, 0.8)

        let off = classes(states, from: offStart + 15, to: offStart + 40)
        XCTAssertEqual(share(off, of: [.offWrist]), 1)
    }

    func testTheClassFollowsTheEvidenceWithoutTheDisplayLabelsHold() throws {
        // The label holds a wording for 10-30 s; the stored class must not inherit that lag. Ten seconds
        // after the run ends the heads have left running and so has the class.
        var sim = ActivitySim()
        sim.still(30); sim.run(80)
        let stop = sim.ts
        sim.still(60)
        let states = decode(sim)
        let after = classes(states, from: stop + 20, to: stop + 60)
        XCTAssertFalse(after.contains { $0.activityClass == .running && $0.confidence < 0.3 },
                       "a class must never be reported over its own near-zero belief")
        XCTAssertEqual(share(classes(states, from: stop + 30, to: stop + 60), of: [.running]), 0)
    }

    func testNoClassIsEverReportedOverItsOwnZeroBelief() {
        var sim = ActivitySim()
        sim.still(40); sim.desk(120); sim.walk(120); sim.walk(120, brisk: true); sim.run(100); sim.walk(40)
        sim.still(60); sim.postureShift(netDegrees: 80, seconds: 3); sim.fidget(120); sim.still(60)
        var sleepOpt = ActivitySim.Options(); sleepOpt.sleep = .asleep
        sim.sleeping(300, opt: sleepOpt)
        let states = decode(sim)
        for s in states {
            let k = ActivityClassifier.classify(state: s)
            if k.activityClass != .unknown && k.activityClass != .offWrist {
                XCTAssertGreaterThan(k.confidence, 0.15, "\(k.activityClass) at \(s.ts - states[0].ts)s")
            }
            XCTAssertTrue((0...1).contains(k.confidence) && (0...1).contains(k.evidenceQuality))
            XCTAssertTrue((0...1).contains(k.runnerUpConfidence))
            if let r = k.runnerUp { XCTAssertNotEqual(r, k.activityClass) }
        }
    }

    // MARK: Higher-intensity activity needs the heart

    func testVigorousEffortWithoutAGaitIsHigherIntensityWhenTheHeartAgrees() throws {
        var sim = ActivitySim()
        let t0 = sim.ts
        let effortStart = t0 + 120
        var opt = ActivitySim.Options()
        opt.hr = nil
        opt.hrAt = effortHR(start: effortStart, rampS: 240, holdS: 180, recoverS: 180)
        sim.still(120, opt: opt)
        sim.vigorous(420, opt: opt)
        let effortEnd = sim.ts
        sim.still(120, opt: opt)
        let states = decode(sim)

        let during = classes(states, from: effortStart + 90, to: effortEnd)
        XCTAssertGreaterThan(share(during, of: [.vigorousActivity]), 0.85)
        XCTAssertGreaterThan(during.map(\.confidence).sorted()[during.count / 4], 0.6)
    }

    func testTheSameMovementAtARestingHeartIsNotCalledHigherIntensity() {
        var sim = ActivitySim()
        let t0 = sim.ts
        var opt = ActivitySim.Options()
        opt.hr = 68
        sim.still(120, opt: opt)
        let start = sim.ts
        sim.vigorous(300, opt: opt)
        sim.still(120, opt: opt)
        let states = decode(sim)
        XCTAssertEqual(share(classes(states, from: start, to: t0 + 600), of: [.vigorousActivity]), 0,
                       "arm flailing with a resting pulse is not a claim the sensors can back")
    }

    func testARecoveringHeartIsNotMistakenForEffort() {
        var sim = ActivitySim()
        let t0 = sim.ts
        var opt = ActivitySim.Options()
        opt.hr = nil
        opt.hrAt = effortHR(start: t0 + 120, rampS: 240, holdS: 180, recoverS: 180)
        sim.still(120, opt: opt)
        sim.vigorous(420, opt: opt)
        let end = sim.ts
        sim.still(180, opt: opt)
        let states = decode(sim)
        let recovery = classes(states, from: end + 45, to: end + 180)
        XCTAssertEqual(share(recovery, of: [.vigorousActivity, .lightActivity]), 0)
        XCTAssertGreaterThan(share(recovery, of: [.standing, .sitting, .stationary, .sittingDesk, .fidgeting]), 0.85)
    }

    func testOrdinaryWalkingAndBriskWalkingStayWalkingNotEffort() {
        var sim = ActivitySim()
        sim.still(40); sim.walk(180); sim.walk(180, brisk: true)
        let states = decode(sim)
        let walkingPhase = classes(states, from: states[0].ts + 60, to: states[0].ts + 400)
        XCTAssertEqual(share(walkingPhase, of: [.vigorousActivity]), 0)
        XCTAssertGreaterThan(share(walkingPhase, of: [.walking, .briskWalking]), 0.9)
    }

    // MARK: Logged workouts are sport-aware

    private func ride(kind: WorkoutKind) -> [ActivityClassification] {
        var sim = ActivitySim()
        var opt = ActivitySim.Options()
        opt.hr = 128; opt.workout = true; opt.workoutKind = kind
        sim.still(60)
        for _ in 0..<300 {
            sim.emit(dyn: 0.12 + sim.rand() * 0.12, ticks: 0, cls: 0, rotate: sim.noise(0.3), jitter: sim.noise(6), opt: opt)
        }
        let states = decode(sim)
        return classes(states, from: states[0].ts + 150, to: states[0].ts + 360)
    }

    func testALoggedRideCoversCyclingAndALoggedRunDoesNot() {
        XCTAssertGreaterThan(share(ride(kind: .cycling), of: [.cycling]), 0.9)
        XCTAssertEqual(share(ride(kind: .running), of: [.cycling]), 0, "a run is no evidence of cycling")
        XCTAssertEqual(share(ride(kind: .walking), of: [.cycling]), 0)
        XCTAssertEqual(share(ride(kind: .other), of: [.cycling]), 0)
    }

    func testAWorkoutOfUnknownSportKeepsThePermissiveBehaviour() {
        XCTAssertGreaterThan(share(ride(kind: .unspecified), of: [.cycling]), 0.9)
    }

    func testCyclingIsNeverInferredFromHeartRateAlone() {
        var sim = ActivitySim()
        var opt = ActivitySim.Options()
        opt.hr = 128
        sim.still(60)
        for _ in 0..<300 {
            sim.emit(dyn: 0.12 + sim.rand() * 0.12, ticks: 0, cls: 0, rotate: sim.noise(0.3), jitter: sim.noise(6), opt: opt)
        }
        let states = decode(sim)
        XCTAssertEqual(share(classes(states, from: states[0].ts, to: states[0].ts + 360), of: [.cycling]), 0)
    }

    func testSportNamesMapToWorkoutKinds() {
        XCTAssertEqual(WorkoutKind(sport: "Running"), .running)
        XCTAssertEqual(WorkoutKind(sport: "Trail running"), .running)
        XCTAssertEqual(WorkoutKind(sport: "Treadmill"), .running)
        XCTAssertEqual(WorkoutKind(sport: "Cycling"), .cycling)
        XCTAssertEqual(WorkoutKind(sport: "Mountain biking"), .cycling)
        XCTAssertEqual(WorkoutKind(sport: "Spinning"), .cycling)
        XCTAssertEqual(WorkoutKind(sport: "Hiking"), .walking)
        XCTAssertEqual(WorkoutKind(sport: "Walk"), .walking)
        XCTAssertEqual(WorkoutKind(sport: "Strength Trainer"), .other)
        XCTAssertEqual(WorkoutKind(sport: "Rowing"), .other)
        XCTAssertEqual(WorkoutKind(sport: ""), .unspecified)
        XCTAssertEqual(WorkoutKind(sport: nil), .unspecified)
    }

    func testSportNamesAreMatchedByWholeWordNotBySubstring() {
        XCTAssertEqual(WorkoutKind(sport: "Bikram yoga"), .other)
        XCTAssertEqual(WorkoutKind(sport: "Ab crunches"), .other)
        XCTAssertEqual(WorkoutKind(sport: "Spinal mobility"), .other)
        XCTAssertEqual(WorkoutKind(sport: "Motorcycle"), .other)
        XCTAssertEqual(WorkoutKind(sport: "Hot Yoga"), .other)
        XCTAssertEqual(WorkoutKind(sport: "HIIT"), .other)

        XCTAssertEqual(WorkoutKind(sport: "Spin class"), .cycling)
        XCTAssertEqual(WorkoutKind(sport: "E-Bike commute"), .cycling)
        XCTAssertEqual(WorkoutKind(sport: "Stationary bike"), .cycling)
        XCTAssertEqual(WorkoutKind(sport: "Rucking"), .walking)
        XCTAssertEqual(WorkoutKind(sport: "Run/Walk intervals"), .running)
    }

    func testCamelCaseIdentifiersAreSplitIntoWords() {
        XCTAssertEqual(WorkoutKind(sport: "MountainBiking"), .cycling)
        XCTAssertEqual(WorkoutKind(sport: "HandCycling"), .cycling)
        XCTAssertEqual(WorkoutKind(sport: "TrailRunning"), .running)
        XCTAssertEqual(WorkoutKind(sport: "NordicWalking"), .walking)
        XCTAssertEqual(WorkoutKind(sport: "HighIntensityIntervalTraining"), .other)
    }

    func testATreadmillWalkIsAWalkNotARun() {
        XCTAssertEqual(WorkoutKind(sport: "Incline treadmill walk"), .walking)
        XCTAssertEqual(WorkoutKind(sport: "Treadmill run"), .running)
        XCTAssertEqual(WorkoutKind(sport: "Treadmill"), .running)
    }

    func testTheTrackBuilderTagsEachSecondWithTheCoveringWorkoutsKind() throws {
        var sim = ActivitySim()
        sim.still(60); sim.desk(60); sim.still(60)
        let t0 = sim.observations[0].ts
        let input = sim.trackInput(workouts: [DayStateWorkout(start: t0 + 10, end: t0 + 30, sport: "Cycling"),
                                              DayStateWorkout(start: t0 + 70, end: t0 + 90, sport: "Run"),
                                              DayStateWorkout(start: t0 + 130, end: t0 + 150, sport: "")])
        let obs = ActivityContextTrackBuilder.observations(for: input)
        func kind(_ offset: Int) -> (Bool, WorkoutKind)? {
            obs.first { $0.ts == t0 + offset }.map { ($0.loggedWorkout, $0.workoutKind) }
        }
        XCTAssertTrue(try XCTUnwrap(kind(15)) == (true, .cycling))
        XCTAssertTrue(try XCTUnwrap(kind(80)) == (true, .running))
        XCTAssertTrue(try XCTUnwrap(kind(140)) == (true, .unspecified))
        XCTAssertTrue(try XCTUnwrap(kind(100)) == (false, .unspecified))
    }

    // MARK: Heart-rate slope

    private func slope(_ hr: (Int) -> Int?, seconds: Int) -> Double? {
        var w = ActivityFeatureWindow()
        var f: ActivityFeatures?
        let t0 = 1_760_000_000
        for i in 0..<seconds {
            var o = ActivityObservation(ts: t0 + i, dynAccelG: 0.01, wear: .onWrist)
            o.hrBpm = hr(t0 + i)
            f = w.push(o, restingHR: 60, maxHR: 190)
        }
        return f?.hrSlope
    }

    func testHeartRateSlopeReadsTheTrendInBpmPerMinute() throws {
        let t0 = 1_760_000_000
        let rising = try XCTUnwrap(slope({ 70 + ($0 - t0) / 12 }, seconds: 240))   // +5 bpm/min
        XCTAssertEqual(rising, 5, accuracy: 0.8)
        let falling = try XCTUnwrap(slope({ 140 - ($0 - t0) / 10 }, seconds: 240))  // -6 bpm/min
        XCTAssertEqual(falling, -6, accuracy: 0.8)
        let flat = try XCTUnwrap(slope({ _ in 72 }, seconds: 240))
        XCTAssertEqual(flat, 0, accuracy: 0.2)
    }

    func testHeartRateSlopeNeedsEnoughSpreadOutSamplesAndNeverInventsATrend() {
        XCTAssertNil(slope({ _ in 80 }, seconds: 40), "40 s is not a trend")
        let t0 = 1_760_000_000
        XCTAssertNil(slope({ ts in ts - t0 < 60 ? 80 : nil }, seconds: 240), "silence is not a flat line")
        // Sparse HR (every 7th second) still yields too few well-populated buckets.
        XCTAssertNil(slope({ ts in (ts - t0) % 7 == 0 ? 90 : nil }, seconds: 240))
    }

    func testHeartRateSlopeIsClippedToAPlausibleRange() throws {
        let t0 = 1_760_000_000
        let wild = try XCTUnwrap(slope({ 50 + ($0 - t0) }, seconds: 150))   // +60 bpm/min, ends at 200 bpm
        XCTAssertEqual(wild, 20)
    }

    func testExertionRisesWithTheHeartAndFallsOnRecovery() {
        func features(hrRel: Double?, slope: Double?) -> ActivityFeatures {
            ActivityFeatures(ts: 0, m4: nil, m10: nil, m30: nil, mMed30: nil, mBurst10: nil, cv30: nil,
                             gaitPresence: nil, cadenceSpm: nil, runShare6: nil, rhythm: nil, orientPath10: nil,
                             net5: nil, net30: nil, shiftNet: nil, hr: nil, hrRel: hrRel, hrSlope: slope,
                             wear: .onWrist, sleep: .awake, loggedWorkout: false, workoutKind: .unspecified,
                             encoder: nil, encoderAgeS: nil,
                             evidence: ActivityEvidenceSummary(imu: false, encoder: false, dynAccel: false,
                                                               gravity: false, steps: false, heartRate: true,
                                                               sleep: false, coverage: 0),
                             windowFill: 0)
        }
        let exertion = ActivityContextModel.exertion
        XCTAssertEqual(exertion(features(hrRel: nil, slope: nil)), 0)
        XCTAssertEqual(exertion(features(hrRel: 0.10, slope: 0)), 0, accuracy: 1e-9, "resting is not effort")
        XCTAssertEqual(exertion(features(hrRel: 0.30, slope: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(exertion(features(hrRel: 0.45, slope: 0)), 1, accuracy: 1e-9)
        XCTAssertEqual(exertion(features(hrRel: 0.45, slope: 3)), 1, accuracy: 1e-9, "still climbing: full effort")
        XCTAssertLessThan(exertion(features(hrRel: 0.55, slope: -8)), 0.5, "high but falling fast is recovery")
        XCTAssertGreaterThan(exertion(features(hrRel: 0.22, slope: 7)), 0.2, "a steep climb counts before the level does")
        XCTAssertEqual(exertion(features(hrRel: 0.22, slope: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(exertion(features(hrRel: 0.22, slope: -7)), 0, accuracy: 1e-9)
    }

    // MARK: Restart and old snapshots

    func testResumingMidEffortReproducesTheHeartRateTrendExactly() throws {
        var sim = ActivitySim()
        var opt = ActivitySim.Options()
        opt.hr = nil
        opt.hrAt = effortHR(start: sim.ts + 60, rampS: 240, holdS: 120, recoverS: 120)
        sim.still(60, opt: opt); sim.vigorous(360, opt: opt); sim.still(120, opt: opt)
        let obs = sim.observations
        let cut = 200

        var whole = ActivityContextDecoder()
        let reference = whole.run(obs)

        var first = ActivityContextDecoder()
        let head = first.run(Array(obs[..<cut]))
        let data = try JSONEncoder().encode(first.snapshot())
        var second = ActivityContextDecoder(restoring: try JSONDecoder().decode(ActivityDecoderSnapshot.self, from: data))
        XCTAssertEqual(second.restoreOutcome, .resumed)
        let combined = head + second.run(Array(obs[cut...]))

        XCTAssertEqual(combined.map(\.ts), reference.map(\.ts))
        for (a, b) in zip(combined, reference) {
            XCTAssertEqual(ActivityClassifier.classify(state: a).activityClass, ActivityClassifier.classify(state: b).activityClass)
            XCTAssertEqual(a.overallConfidence, b.overallConfidence, accuracy: 1e-9)
            for c in LocomotionClass.allCases { XCTAssertEqual(a.locomotion[c], b.locomotion[c], accuracy: 1e-9) }
        }
    }

    func testASnapshotFromBeforeTheTrendWindowStillDecodesAndIsRejectedOnVersion() throws {
        var sim = ActivitySim()
        sim.desk(120)
        var d = ActivityContextDecoder()
        _ = d.run(sim.observations)
        let data = try JSONEncoder().encode(d.snapshot())

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var window = try XCTUnwrap(json["window"] as? [String: Any])
        window["hrBuckets"] = nil
        window["lastWorkoutKind"] = nil
        json["window"] = window
        var versions = try XCTUnwrap(json["versions"] as? [String: Any])
        versions["decoder"] = "hsmm-1.1"
        json["versions"] = versions

        let legacy = try JSONDecoder().decode(ActivityDecoderSnapshot.self,
                                              from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(ActivityContextDecoder(restoring: legacy).restoreOutcome, .discarded("version_mismatch"))
    }
}
