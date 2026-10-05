import XCTest
@testable import StrandAnalytics

/// Strap motion evidence: both magnitude bases, gaps, step-counter locomotion, uncovered seconds.
final class PCMotionEvidenceTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias F = PCSignalFixtures
    typealias M = PhysiologyContext.MotionEvidence

    var window: PC.Interval { PC.Interval(F.t0 - 3600, F.t0 + 3600) }

    func evidence(_ motion: [PC.MotionObservation], steps: [PC.StepObservation] = [],
                  config: PC.MotionEvidenceConfig = .init()) -> PC.StrapMotionEvidence {
        M.strapEvidence(motion: motion, steps: steps, window: window, config: config)
    }

    func composition(_ track: PC.ResolvedTrack, _ start: Int, _ end: Int) -> PC.ActivityComposition {
        PC.IntervalAlgebra.composition(over: .init(start, end), track: track)
    }

    func testDynamicAccelerationBasisLabelsWithTrailingSmoothing() {
        let t = F.t0
        // 60 s at 0.002 g, 60 s at 0.05 g, 60 s at 0.5 g.
        let motion = (0..<180).map { i in
            PC.MotionObservation(ts: t + i, dynAccelG: i < 60 ? 0.002 : (i < 120 ? 0.05 : 0.5))
        }
        let e = evidence(motion)
        let c = composition(e.track, t, t + 180)
        // At t+60 the trailing 5 s mean is (4 × 0.002 + 0.05) / 5 = 0.0116 > 0.01; at t+120 it is
        // (4 × 0.05 + 0.5) / 5 = 0.14 > 0.10. The rising edges are therefore exact.
        XCTAssertEqual(c.seconds(of: "still"), 60)
        XCTAssertEqual(c.seconds(of: "low_movement"), 60)
        XCTAssertEqual(c.seconds(of: "other_movement"), 60)
        XCTAssertEqual(e.track.source, .strapMotion)
        XCTAssertFalse(e.track.heartRateDependent)
        XCTAssertEqual(e.reasons, [M.basisDynamicAcceleration])
        XCTAssertEqual(e.count("seconds.dynamic_acceleration"), 180)
        XCTAssertTrue(PC.IntervalAlgebra.reconciles(c))
    }

    func testSmoothingLagsTheFallingEdgeAndNeverLooksAhead() {
        let t = F.t0
        let motion = (0..<20).map { i in PC.MotionObservation(ts: t + i, dynAccelG: i < 10 ? 0.5 : 0.002) }
        let c = composition(evidence(motion).track, t, t + 20)
        // Trailing means after the drop at t+10: t+10 (0.4004), t+11 (0.3008), t+12 (0.2012), t+13 (0.1016) are
        // still other_movement; t+14 holds only quiet samples. Labels never depend on later seconds.
        XCTAssertEqual(c.seconds(of: "other_movement"), 14)
        XCTAssertEqual(c.seconds(of: "still"), 6)
    }

    func testGravityDeltaFallbackWhenDynamicAccelerationIsAbsent() {
        let t = F.t0
        var motion: [PC.MotionObservation] = []
        for i in 0..<60 { motion.append(.init(ts: t + i, dynAccelG: nil, x: 0, y: 0, z: 1)) }
        // Then the wrist rotates back and forth every second: |Δg| = √(0.2² + 0.02²) ≈ 0.201 g.
        for i in 60..<120 {
            motion.append(i % 2 == 0 ? .init(ts: t + i, dynAccelG: nil, x: 0, y: 0, z: 1)
                                     : .init(ts: t + i, dynAccelG: nil, x: 0, y: 0.2, z: 0.98))
        }
        let e = evidence(motion)
        let c = composition(e.track, t, t + 120)
        XCTAssertEqual(c.unknownS, 1, "the first sample has no predecessor, so no delta")
        // t+60 repeats (0,0,1), so its delta is 0. t+61 is the first moving delta: trailing mean over t+57…t+61 =
        // 0.201 / 5 = 0.040 → low_movement; t+62: 0.080 → low; t+63: 0.121 → other; from then on other_movement.
        XCTAssertEqual(c.seconds(of: "still"), 60)
        XCTAssertEqual(c.seconds(of: "low_movement"), 2)
        XCTAssertEqual(c.seconds(of: "other_movement"), 57)
        XCTAssertEqual(e.reasons, [M.basisGravityDelta, M.magnitudeUnavailable])
        XCTAssertEqual(e.count("seconds.gravity_delta"), 119)
        XCTAssertEqual(e.count("seconds.unknown_magnitude"), 1)
    }

    func testNoGravityDeltaIsComputedAcrossAGap() {
        let t = F.t0
        var motion: [PC.MotionObservation] = []
        for i in 0..<10 { motion.append(.init(ts: t + i, dynAccelG: nil, x: 0, y: 0, z: 1)) }
        // 10 s without samples, then a different but steady orientation: the 1.41 g jump across the gap is not
        // movement — it is not computed at all.
        for i in 20..<30 { motion.append(.init(ts: t + i, dynAccelG: nil, x: 1, y: 0, z: 0)) }
        let c = composition(evidence(motion).track, t, t + 30)
        XCTAssertEqual(c.seconds(of: "still"), 18)
        XCTAssertEqual(c.unknownS, 2)          // t and t+20
        XCTAssertEqual(c.uncoveredS, 10)       // t+10…t+19: no sample, never still
        XCTAssertEqual(c.seconds(of: "other_movement"), 0)
        XCTAssertTrue(PC.IntervalAlgebra.reconciles(c))
    }

    func testDynamicAccelerationIsPreferredAndBasesAreSmoothedSeparately() {
        let t = F.t0
        // Vector says "rotating" (would be movement) but the strap's own dynAccel says still: dynAccel wins.
        let motion = (0..<30).map { i in
            PC.MotionObservation(ts: t + i, dynAccelG: i < 15 ? 0.003 : nil,
                                 x: 0, y: i % 2 == 0 ? 0 : 0.3, z: 1)
        }
        let e = evidence(motion)
        let c = composition(e.track, t, t + 30)
        XCTAssertEqual(c.seconds(of: "still"), 15)
        XCTAssertEqual(c.seconds(of: "other_movement"), 15)   // gravity-delta seconds t+15…t+29 (0.3 g each)
        XCTAssertEqual(e.reasons, [M.basisDynamicAcceleration, M.basisGravityDelta])
    }

    func testStepCounterIncrementsLabelSteppingAndWrapAt65536() {
        let t = F.t0
        let motion = (0..<40).map { PC.MotionObservation(ts: t + $0, dynAccelG: 0.002) }
        // Counter 65534, 0, 2, … : +2 per second through the u16 wrap, labelled walk (class 1).
        let steps = (0...20).map { i in
            PC.StepObservation(ts: t + 10 + i, counter: (65534 + 2 * i) & 0xFFFF, activityClass: 1)
        }
        let e = evidence(motion, steps: steps)
        let c = composition(e.track, t, t + 40)
        XCTAssertEqual(c.seconds(of: "stepping"), 20)   // (t+10, t+30]
        XCTAssertEqual(c.seconds(of: "still"), 20)
        XCTAssertTrue(e.reasons.contains(M.stepCounterStepping))
        XCTAssertEqual(PC.IntervalAlgebra.precedingHistory(before: t + 40, track: e.track, lookbackS: 1800)
            .secondsSinceSupportedActivity, 9)
    }

    func testStillClassIncrementsAndLongGapsAreNotStepping() {
        let t = F.t0
        let motion = (0..<40).map { PC.MotionObservation(ts: t + $0, dynAccelG: 0.002) }
        let still = (0...10).map { PC.StepObservation(ts: t + $0, counter: 100 + $0, activityClass: 0) }
        let gap = [PC.StepObservation(ts: t + 20, counter: 200, activityClass: 1),
                   PC.StepObservation(ts: t + 30, counter: 230, activityClass: 1)]   // 10 s apart: unattributable
        let c = composition(evidence(motion, steps: still + gap).track, t, t + 40)
        XCTAssertEqual(c.seconds(of: "stepping"), 0)
        XCTAssertEqual(c.seconds(of: "still"), 40)
    }

    func testSteppingWithoutAMotionSampleIsStillLocomotionEvidence() {
        let t = F.t0
        let steps = (0...5).map { PC.StepObservation(ts: t + $0, counter: 3 * $0, activityClass: 2) }
        let e = evidence([], steps: steps)
        let c = composition(e.track, t, t + 10)
        XCTAssertEqual(c.seconds(of: "stepping"), 5)
        XCTAssertEqual(c.uncoveredS, 5)
        XCTAssertEqual(e.count("seconds.stepping_without_motion_sample"), 5)
    }

    func testNoMotionMeansUncoveredNeverStill() {
        let e = evidence([])
        XCTAssertTrue(e.track.spans.isEmpty)
        XCTAssertEqual(e.reasons, [M.noMotionSamples])
        let c = composition(e.track, F.t0, F.t0 + 300)
        XCTAssertEqual(c.uncoveredS, 300)
        XCTAssertEqual(c.labels, [])
    }

    func testTrackIsDeterministicAndIndependentOfInputOrder() {
        let t = F.t0
        let motion = (0..<200).map { i in PC.MotionObservation(ts: t + i, dynAccelG: Double((i * 37) % 11) / 40) }
        let a = M.strapTrack(motion: motion, steps: [], window: window, config: .init())
        let b = M.strapTrack(motion: motion.reversed(), steps: [], window: window, config: .init())
        XCTAssertEqual(a, b)
    }

    func testThresholdsAreConfigurableAndChangeThePolicyFingerprint() {
        var policy = PC.Policy()
        let before = policy.fingerprint
        policy.eligibility.motion.dynStillMaxG = 0.02
        XCTAssertNotEqual(before, policy.fingerprint)
        var config = PC.MotionEvidenceConfig()
        config.dynStillMaxG = 0.06
        let motion = (0..<10).map { PC.MotionObservation(ts: F.t0 + $0, dynAccelG: 0.05) }
        let c = composition(evidence(motion, config: config).track, F.t0, F.t0 + 10)
        XCTAssertEqual(c.seconds(of: "still"), 10)
    }
}
