import XCTest
@testable import StrandAnalytics

/// hsmm-2.0: placement-aware posture, still-stretch priors, measured stand-ups / sit-downs and the personal
/// heart-rate-by-posture model. The scenario that motivated them: the owner wears the strap on the BICEP and sat
/// still for ~90 minutes (2026-10-09 16:45–18:30) with the upper arm hanging; the decoder read "Standing quietly".
final class ActivityBicepPostureTests: XCTestCase {

    private let postureClaims: Set<ActivityClass> = [.sitting, .sittingDesk, .standing, .fidgeting]

    /// HART's fine distribution every 2 s, leaning to `activity`.
    private func hart(_ activity: String) -> (Int) -> MotionEncoderOutput? {
        { ts in
            guard ts % 2 == 0 else { return nil }
            var fine: [String: Double] = ["sitting": 0.04, "standing": 0.04, "typing": 0.04, "walking": 0.02]
            fine[activity] = 0.86
            return MotionEncoderOutput(encoderId: "hart", encoderVersion: "t", startTs: ts - 4, endTs: ts,
                                       classProbs: ["stationary": 0.9, "other_movement": 0.08, "walking": 0.02],
                                       calibrated: true, abstained: false, fineProbs: fine)
        }
    }

    private func bicep(from: Int = 0) -> ActivityDecoderConfig {
        var c = ActivityDecoderConfig()
        c.placements = [ActivityPlacementSpan(start: from, end: nil, placement: .bicep)]
        return c
    }

    /// A walk, then `stillS` seconds still with the arm hanging (forearm axis 0.9) and HART naming standing: every
    /// cue a wrist reads as standing, which an upper arm shows while seated.
    private func walkThenHangingStill(_ stillS: Int, seed: UInt64 = 7) -> (obs: [ActivityObservation], stillStart: Int) {
        var sim = ActivitySim(seed: seed)
        var opt = ActivitySim.Options()
        opt.encoder = hart("standing")
        sim.forearm(0.9)
        sim.walk(300, opt: opt)
        let start = sim.ts
        sim.still(stillS, opt: opt)
        return (sim.observations, start)
    }

    private func classes(_ track: ActivityContextTrack, from: Int, to: Int = .max) -> [ActivityClassification] {
        track.states.filter { $0.ts >= from && $0.ts < to }.map(ActivityClassifier.classify(state:))
    }

    // MARK: 1. Placement

    func testWristRulesStillReadAHangingArmAsStandingOnAWrist() {
        // The pre-hsmm-2.0 behaviour on a wrist, for its first minutes (before the duration prior has grown).
        let (obs, start) = walkThenHangingStill(600)
        let track = ActivityContextTrackBuilder.decode(obs, config: ActivityDecoderConfig())
        let early = classes(track, from: start + 60, to: start + 300)
        XCTAssertTrue(early.contains { $0.activityClass == .standing },
                      "on a wrist, hanging arm + HART standing still commit standing early on")
    }

    func testOnTheBicepAHangingArmIsNeverReadAsStanding() {
        let (obs, start) = walkThenHangingStill(5_400)
        let track = ActivityContextTrackBuilder.decode(obs, config: bicep())
        let still = classes(track, from: start + 30)
        XCTAssertFalse(still.contains { $0.activityClass == .standing },
                       "an upper arm hangs whether seated or standing: no wrist rule may claim standing")
        // Early on it is honestly unresolved; after a long stillness the duration prior leans to sitting.
        let first = classes(track, from: start + 30, to: start + 240)
        XCTAssertTrue(first.allSatisfy { !postureClaims.contains($0.activityClass) },
                      "the first minutes stay 'still, sitting or standing'")
        let late = classes(track, from: start + 1_800)
        let sitting = late.filter { $0.activityClass == .sitting || $0.activityClass == .sittingDesk }
        XCTAssertGreaterThan(Double(sitting.count) / Double(max(1, late.count)), 0.9,
                             "after 30 still minutes the stretch reads as sitting")
        for k in sitting {
            XCTAssertLessThanOrEqual(k.confidence, ActivityClassifier.wristOnlyPostureConfidenceCap + 1e-12)
        }
    }

    func testPlacementOnlyAppliesInsideItsSpan() {
        let (obs, start) = walkThenHangingStill(600)
        // Bicep declared only from long after this stretch: the stretch decodes as a wrist.
        let late = bicep(from: start + 100_000)
        let a = ActivityContextTrackBuilder.decode(obs, config: late)
        let b = ActivityContextTrackBuilder.decode(obs, config: ActivityDecoderConfig())
        XCTAssertEqual(a.states, b.states)
    }

    func testDecodingPlacementsKeepOnlyNonWristStretches() {
        let spans = [ActivityPlacementSpan(start: 0, end: 1_000, placement: .wrist),
                     ActivityPlacementSpan(start: 1_000, end: 5_000, placement: .bicep),
                     ActivityPlacementSpan(start: 3_000, end: nil, placement: .wrist)]
        let d = ActivityDecoderConfig.decodingPlacements(spans, from: 0, to: 10_000)
        XCTAssertEqual(d, [ActivityPlacementSpan(start: 1_000, end: 3_000, placement: .bicep)],
                       "the later wrist declaration overrides the bicep one where they overlap")
        XCTAssertNil(ActivityDecoderConfig.decodingPlacements([ActivityPlacementSpan(start: 0, end: nil, placement: .wrist)],
                                                              from: 0, to: 10))
        XCTAssertNil(ActivityDecoderConfig.decodingPlacements([], from: 0, to: 10))
        var c = ActivityDecoderConfig()
        let plain = c.cacheTag
        c.placements = ActivityDecoderConfig.decodingPlacements(
            [ActivityPlacementSpan(start: 0, end: nil, placement: .wrist)], from: 0, to: 10)
        XCTAssertEqual(c.cacheTag, plain, "a wrist-only day keeps its tag")
        c.placements = [ActivityPlacementSpan(start: 0, end: nil, placement: .bicep)]
        XCTAssertNotEqual(c.cacheTag, plain)
        XCTAssertTrue(c.cacheTag.contains("-pl"))
        XCTAssertEqual(c.placement(at: 5), .bicep)
        XCTAssertEqual(ActivityWearPlacement(declared: "BICEP"), .bicep)
        XCTAssertEqual(ActivityWearPlacement(declared: "ankle"), .unknown)
    }

    func testConfigWithoutTheNewFieldsDecodes() throws {
        let json = #"{"restingHeartRate":60,"maxHeartRate":190,"publishIntervalS":5,"evidenceTemperature":0.35,"armTemperature":0.5,"gapResetS":120,"displayHoldS":10,"displayRefineHoldS":30,"armDisplaySmoothS":45,"eventHoldS":15,"historyWindowS":900}"#
        let c = try JSONDecoder().decode(ActivityDecoderConfig.self, from: Data(json.utf8))
        XCTAssertNil(c.placements)
        XCTAssertNil(c.postureHeartRate)
    }

    // MARK: 2. Duration prior

    func testDurationLeanGrowsWithStillnessAndIsBounded() {
        XCTAssertEqual(ActivityStillPosture.durationLean(stillForS: 0), 0)
        XCTAssertEqual(ActivityStillPosture.durationLean(stillForS: 60), 0)
        var last = 0.0
        for s in stride(from: 61, through: 20_000, by: 37) {
            let l = ActivityStillPosture.durationLean(stillForS: s)
            XCTAssertGreaterThanOrEqual(l, last - 1e-12, "monotone at \(s)")
            XCTAssertLessThanOrEqual(l, ActivityStillPosture.maxDurationLean + 1e-12)
            last = l
        }
        XCTAssertGreaterThan(ActivityStillPosture.durationLean(stillForS: 3_600), log(1.9),
                             "an hour still clears the sitting commit bar")
        XCTAssertLessThan(ActivityStillPosture.durationLean(stillForS: 240), log(1.9),
                          "four minutes still does not commit sitting on its own")
    }

    func testWalkingEndsTheStillStretch() {
        var sim = ActivitySim(seed: 11)
        sim.forearm(0.9)
        sim.walk(120)
        sim.still(2_400)
        let walkBack = sim.ts
        sim.walk(120)
        let restart = sim.ts
        sim.still(240)
        let track = ActivityContextTrackBuilder.decode(sim.observations, config: bicep())
        let afterWalk = classes(track, from: restart + 30, to: restart + 200)
        XCTAssertTrue(afterWalk.allSatisfy { !postureClaims.contains($0.activityClass) },
                      "a walk resets the duration prior: the next minutes are unresolved again")
        XCTAssertTrue(classes(track, from: walkBack - 600, to: walkBack - 10).contains { $0.activityClass == .sitting })
    }

    // MARK: 4. Measured change of height

    private func withShift(_ obs: [ActivityObservation], at ts: Int, displacement: Double) -> [ActivityObservation] {
        obs.map { o in
            guard o.ts == ts else { return o }
            var o = o
            o.verticalShift = ActivityVerticalShiftEvidence(ts: ts, startTs: ts - 3, displacementM: displacement,
                                                            quality: 0.9)
            return o
        }
    }

    func testARiseAnchorsStandingAndADropAnchorsSitting() {
        var sim = ActivitySim(seed: 21)
        sim.forearm(0.9)
        sim.walk(120)
        sim.still(600)
        let shiftTs = sim.ts
        sim.postureShift(netDegrees: 10, seconds: 3)
        sim.still(900)
        let base = sim.observations
        let rise = ActivityContextTrackBuilder.decode(withShift(base, at: shiftTs + 2, displacement: 0.42), config: bicep())
        let drop = ActivityContextTrackBuilder.decode(withShift(base, at: shiftTs + 2, displacement: -0.40), config: bicep())
        let riseAfter = classes(rise, from: shiftTs + 30, to: shiftTs + 150)
        let dropAfter = classes(drop, from: shiftTs + 60, to: shiftTs + 300)
        XCTAssertGreaterThan(riseAfter.filter { $0.activityClass == .standing }.count, riseAfter.count / 2,
                             "a measured rise of the shoulder anchors standing")
        XCTAssertGreaterThan(dropAfter.filter { $0.activityClass == .sitting }.count, dropAfter.count / 2,
                             "a measured drop anchors sitting")
        XCTAssertFalse(dropAfter.contains { $0.activityClass == .standing })
        // Standing still for long is rare (Capture-24: 5 % of standing bouts pass 10 min): the stand claim fades.
        let riseLate = classes(rise, from: shiftTs + 900, to: shiftTs + 905)
        XCTAssertFalse(riseLate.contains { $0.activityClass == .standing }, "fifteen still minutes after a stand-up")
    }

    func testASmallOrPoorShiftAnchorsNothing() {
        XCTAssertNil(ActivityStillPosture.anchorLean(ActivityVerticalShiftEvidence(ts: 0, startTs: 0, displacementM: 0.05, quality: 1)))
        XCTAssertNil(ActivityStillPosture.anchorLean(ActivityVerticalShiftEvidence(ts: 0, startTs: 0, displacementM: 0.4, quality: 0.2)))
        XCTAssertNil(ActivityStillPosture.anchorLean(ActivityVerticalShiftEvidence(ts: 0, startTs: 0, displacementM: .nan, quality: 1)))
        XCTAssertGreaterThan(ActivityStillPosture.anchorLean(ActivityVerticalShiftEvidence(ts: 0, startTs: 0, displacementM: -0.4, quality: 1))!, 0)
        XCTAssertLessThan(ActivityStillPosture.anchorLean(ActivityVerticalShiftEvidence(ts: 0, startTs: 0, displacementM: 0.4, quality: 1))!, 0)
    }

    // MARK: 3. Heart rate by posture

    private let model = ActivityPostureHeartRateModel(seatedOffsetBpm: 8, uprightOffsetBpm: 18, sdBpm: 4,
                                                      seatedSeconds: 600, uprightSeconds: 600, runs: 3,
                                                      heldOutAUC: 0.9)

    func testHeartRateLeanOnlyWhenSettledAndBounded() {
        typealias G = ActivityPostureHeartRateGate
        let seatedHR = 60 + 8.0, standingHR = 60 + 18.0
        XCTAssertGreaterThan(G.lean(model: model, averageBpm: seatedHR, restingBpm: 60, stillForS: 600,
                                    sinceExertionS: nil, slope: 0), 0)
        XCTAssertLessThan(G.lean(model: model, averageBpm: standingHR, restingBpm: 60, stillForS: 600,
                                 sinceExertionS: nil, slope: 0), 0)
        for hr in stride(from: 40.0, through: 120, by: 1) {
            let l = G.lean(model: model, averageBpm: hr, restingBpm: 60, stillForS: 600, sinceExertionS: nil, slope: 0)
            XCTAssertLessThanOrEqual(abs(l), G.maxLean + 1e-12)
        }
        XCTAssertEqual(G.lean(model: model, averageBpm: standingHR, restingBpm: 60, stillForS: 60,
                              sinceExertionS: nil, slope: 0), 0, "not settled yet")
        XCTAssertEqual(G.lean(model: model, averageBpm: standingHR, restingBpm: 60, stillForS: 600,
                              sinceExertionS: 300, slope: 0), 0, "recovering from exertion")
        XCTAssertEqual(G.lean(model: model, averageBpm: standingHR, restingBpm: 60, stillForS: 600,
                              sinceExertionS: nil, slope: -3), 0, "still falling")
        XCTAssertEqual(G.lean(model: model, averageBpm: standingHR, restingBpm: 60, stillForS: 600,
                              sinceExertionS: nil, slope: nil), 0, "no trend, no claim")
        XCTAssertEqual(G.lean(model: model, averageBpm: 60 + 30, restingBpm: 60, stillForS: 600,
                              sinceExertionS: nil, slope: 0), 0, "well above standing is effort, not standing")
        XCTAssertLessThan(G.maxLean, log(1.9), "heart rate alone never reaches a sitting / standing commit")
    }

    private func labelsAndHR(gap: Double, runs: Int, seed: UInt64 = 3) -> ([ActivityPostureHeartRateLabel], [(ts: Int, bpm: Double)]) {
        var rng = BicepSplitMix(seed)
        var labels: [ActivityPostureHeartRateLabel] = []
        var hr: [(ts: Int, bpm: Double)] = []
        var t = 1_000
        for r in 0..<runs {
            let runShift = (rng.next() - 0.5) * 4
            for seated in [true, false, true, false] {
                labels.append(ActivityPostureHeartRateLabel(start: t, end: t + 75, seated: seated, run: "r\(r)"))
                for s in t..<(t + 75) {
                    hr.append((s, 65 + runShift + (seated ? 0 : gap) + (rng.next() - 0.5) * 4))
                }
                t += 100
            }
            t += 10_000
        }
        return (labels, hr)
    }

    func testFitterAdoptsOnlyAHeldOutGapLargeEnough() {
        let (l1, h1) = labelsAndHR(gap: 12, runs: 3)
        let adopted = ActivityPostureHeartRateFitter.fit(labels: l1, hr: h1, defaultRestingBpm: 60)
        XCTAssertEqual(adopted.status, .adopted, adopted.reason)
        XCTAssertNotNil(adopted.model)
        XCTAssertEqual(adopted.model!.gapBpm, 12, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(adopted.model!.sdBpm, ActivityPostureHeartRateFitter.minSdBpm)

        let (l2, h2) = labelsAndHR(gap: 6, runs: 3)
        let small = ActivityPostureHeartRateFitter.fit(labels: l2, hr: h2, defaultRestingBpm: 60)
        XCTAssertEqual(small.status, .notSeparable, "6 bpm (the owner's calibration) is under the 8 bpm floor")
        XCTAssertNil(small.model)

        let (l3, h3) = labelsAndHR(gap: 12, runs: 1)
        XCTAssertEqual(ActivityPostureHeartRateFitter.fit(labels: l3, hr: h3).status, .needsMoreData)
    }

    func testHeartRateModelChangesTheCacheTagOnlyWhenSet() {
        var c = ActivityDecoderConfig()
        let plain = c.cacheTag
        c.postureHeartRate = model
        XCTAssertTrue(c.cacheTag.hasPrefix(plain + "-ph"))
    }

    // MARK: 5. Calibration protocol

    func testCalibrationV5TeachesTheHangingArmAndSettlesHeartRate() {
        let p = ActivityCalibrationProtocols.current
        XCTAssertEqual(p.version, "calibration-v5")
        let holds = p.activities.first { $0.id == "sit-stand" }!.tasks.filter { !$0.isMove }
        XCTAssertEqual(holds.count, 4)
        XCTAssertTrue(holds.allSatisfy { $0.durationSeconds == ActivityCalibrationProtocols.v5HoldSeconds })
        XCTAssertGreaterThanOrEqual(ActivityCalibrationProtocols.v5HoldSeconds,
                                    ActivityPostureHeartRateFitter.settleIntoLabelS + ActivityPostureHeartRateFitter.blockS)
        XCTAssertTrue(holds.contains { $0.posture == PostureClass.seatedLikely.rawValue && $0.instructions.contains("hanging") },
                      "one seated hold with the arms hanging: the pose an upper-arm strap confuses with standing")
        XCTAssertEqual(ActivityCalibrationProtocols.model(forVersion: "calibration-v4"), ActivityCalibrationProtocols.v4,
                       "older runs still read back")
    }
}

/// Tiny deterministic generator for the synthetic heart-rate runs.
private struct BicepSplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
