import XCTest
@testable import StrandAnalytics

/// Heart-rate free posture strata and decoder transition-event summaries (D3-07, D4-09, D4-11, D5-07).
final class PCPostureTransitionsTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias P = PhysiologyContext.PostureEvidence
    typealias F = PCSignalFixtures

    var support: PC.Interval { PC.Interval(F.t0, F.t0 + 300) }

    /// 1 Hz gravity over the support with the forearm axis at `x` (unit vector, rest of gravity on z).
    func gravity(x: (Int) -> Double, from: Int? = nil, count: Int = 300) -> [PC.MotionObservation] {
        let s = from ?? F.t0
        return (0..<count).map { i in
            let gx = x(i)
            return PC.MotionObservation(ts: s + i, dynAccelG: 0.005, x: gx, y: 0, z: (1 - gx * gx).squareRoot())
        }
    }

    func context(_ motion: [PC.MotionObservation], inBed: [PC.ActivityIntervalInput] = [],
                 config: PC.PostureConfig = .init()) -> PC.PostureContext {
        P.context(over: support, motion: motion, inBed: P.inBedTrack(inBed), config: config)
    }

    func testForearmFlatIsRecumbentLikelyAndArmHangingIsUprightNeverSittingOrStanding() {
        let flat = context(gravity(x: { _ in 0.1 }))
        XCTAssertEqual(flat.stratum, .recumbentLikely)
        XCTAssertEqual(flat.basis, [P.basisForearmGravity])
        XCTAssertEqual(flat.forearmFlatShare, 1)
        XCTAssertFalse(flat.heartRateDependent, "gravity is heart-rate free")
        XCTAssertTrue(flat.reasons.contains(P.likelihoodNotConfirmed))

        let hanging = context(gravity(x: { _ in 0.93 }))
        XCTAssertEqual(hanging.stratum, .uprightLikely)
        XCTAssertEqual(Set(hanging.reasons), [P.likelihoodNotConfirmed, P.sittingStandingNotSeparated])
        XCTAssertEqual(PC.PostureStratum.allCases.map(\.rawValue), ["recumbent_likely", "upright_likely", "unknown"],
                       "no sitting / standing stratum exists")
    }

    func testMixedOrSparseGravityStaysUnknown() {
        // Half the support flat, half hanging: neither stratum.
        let mixed = context(gravity(x: { $0 < 150 ? 0.1 : 0.9 }))
        XCTAssertEqual(mixed.stratum, .unknown)
        XCTAssertEqual(mixed.reasons, [P.ambiguous])
        // Only 2 minutes of the 5 observed: not enough orientation evidence.
        let sparse = context(gravity(x: { _ in 0.1 }, count: 120))
        XCTAssertEqual(sparse.stratum, .unknown)
        XCTAssertEqual(sparse.reasons, [P.insufficientGravity])
        // Implausible gravity norms (free fall / impacts) are not orientation evidence.
        let junk = (0..<300).map { PC.MotionObservation(ts: F.t0 + $0, dynAccelG: 0, x: 0.1, y: 0, z: 0.1) }
        XCTAssertEqual(context(junk).stratum, .unknown)
        XCTAssertEqual(context(junk).gravityS, 0)
    }

    func testInBedWindowIsRecumbentAndFlaggedHeartRateDependent() {
        let bed = PC.ActivityIntervalInput(interval: .init(F.t0 - 600, F.t0 + 900), activityClass: "lying_down",
                                           confidence: 0.9, revision: 1, inBed: true)
        let c = context(gravity(x: { _ in 0.6 }), inBed: [bed])
        XCTAssertEqual(c.stratum, .recumbentLikely)
        XCTAssertEqual(c.basis, [P.basisInBedWindow])
        XCTAssertTrue(c.heartRateDependent)
        XCTAssertTrue(c.reasons.contains(P.inBedFromSleepDetector))
        XCTAssertEqual(c.inBedS, 300)
        // Partly in bed with a hanging arm: not upright.
        let partly = PC.ActivityIntervalInput(interval: .init(F.t0 + 200, F.t0 + 900), activityClass: "lying_down",
                                              confidence: 0.9, revision: 1, inBed: true)
        XCTAssertEqual(context(gravity(x: { _ in 0.93 }), inBed: [partly]).stratum, .unknown)
        // The in-bed window can be switched off: gravity alone decides (a raised forearm reads upright).
        var off = PC.PostureConfig()
        off.useInBedWindow = false
        let gravityOnly = context(gravity(x: { _ in 0.6 }), inBed: [bed], config: off)
        XCTAssertEqual(gravityOnly.stratum, .uprightLikely)
        XCTAssertFalse(gravityOnly.heartRateDependent)
        XCTAssertNil(gravityOnly.inBedS)
    }

    func testHeartRateTargetNeverReadsTheHeartRateConfirmedInBedWindow() {
        // In bed by the sleep detector, forearm raised (0.93): a heart-rate measurement's stratum is gravity only,
        // so the window is upright, never recumbent, and heart-rate free.
        let bed = PC.ActivityIntervalInput(interval: .init(F.t0 - 600, F.t0 + 900), activityClass: "lying_down",
                                           confidence: 0.9, revision: 1, inBed: true)
        let hr = P.context(over: support, motion: gravity(x: { _ in 0.93 }), inBed: P.inBedTrack([bed]),
                           config: .init(), heartRateTarget: true)
        XCTAssertEqual(hr.stratum, .uprightLikely)
        XCTAssertFalse(hr.heartRateDependent)
        XCTAssertNil(hr.inBedS)
        XCTAssertEqual(hr.basis, [P.basisForearmGravity])
        XCTAssertTrue(hr.reasons.contains(P.inBedNotUsedForHeartRateTarget))
        XCTAssertFalse(hr.reasons.contains(P.inBedFromSleepDetector))
        // The same window for a non-heart-rate target still reads the in-bed window (flagged).
        let other = P.context(over: support, motion: gravity(x: { _ in 0.93 }), inBed: P.inBedTrack([bed]),
                              config: .init())
        XCTAssertEqual(other.stratum, .recumbentLikely)
        XCTAssertTrue(other.heartRateDependent)
    }

    func testTransitionSummaryCountsEventsByFamilyAndNilMeansUnobserved() {
        let coverage = F.track([(F.t0 - 600, F.t0 + 600, "sitting")], source: .decoderIntervals,
                               heartRateDependent: true)
        let events = PC.TransitionEvents.prepare([
            .init(ts: F.t0 + 10, kind: "sit_to_stand_like", probability: 0.4, revision: 1),
            .init(ts: F.t0 + 10, kind: "sit_to_stand_like", probability: 0.7, revision: 2),  // revised: one event
            .init(ts: F.t0 + 20, kind: "stand_to_sit_like", probability: 0.6, revision: 2),
            .init(ts: F.t0 + 40, kind: "walk_start", probability: 0.9, revision: 2),
            .init(ts: F.t0 + 50, kind: "future_kind", probability: 0.9, revision: 2),
            .init(ts: F.t0 + 400, kind: "walk_stop", probability: 0.9, revision: 2),
        ], causalCutoff: nil)
        let s = PC.TransitionEvents.summary(events, over: support, coverage: coverage)
        XCTAssertEqual(s?.postural, 2)
        XCTAssertEqual(s?.locomotion, 1)
        XCTAssertEqual(s?.other, 1)
        XCTAssertEqual(s?.maxPosturalProbability, 0.7)
        XCTAssertEqual(s?.coveredS, 300)
        XCTAssertTrue(s?.heartRateDependent ?? false)
        // Nothing covers this window and no event falls in it: unobserved, not "no transition".
        XCTAssertNil(PC.TransitionEvents.summary(events, over: .init(F.t0 + 5000, F.t0 + 5300), coverage: coverage))
        // Covered and quiet: an observed zero.
        XCTAssertEqual(PC.TransitionEvents.summary(events, over: .init(F.t0 + 100, F.t0 + 300),
                                                   coverage: coverage)?.total, 0)
        // Last events before an instant.
        let (p, l) = PC.TransitionEvents.last(before: F.t0 + 300, in: events)
        XCTAssertEqual(p?.kind, "stand_to_sit_like")
        XCTAssertEqual(l?.kind, "walk_start")
        // Causal: an event flagged at or after the cutoff, or published after it, is not visible.
        let causal = PC.TransitionEvents.prepare([
            .init(ts: F.t0, kind: "sit_to_stand_like", probability: 0.9, revision: 1, availableAt: F.t0 + 30),
            .init(ts: F.t0 + 5, kind: "sit_to_stand_like", probability: 0.9, revision: 1, availableAt: F.t0 + 900),
        ], causalCutoff: F.t0 + 60)
        XCTAssertEqual(causal.map(\.ts), [F.t0])
    }
}
