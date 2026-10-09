import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Deterministic generator for cue jitter in tests (SplitMix64).
struct SitStandSplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class ActivitySitStandTests: XCTestCase {
    let t0 = 1_760_000_000

    // MARK: Synthetic streams

    /// Sitting: forearm near flat; standing: arm hanging. Small per-second wobble from a seeded generator.
    static let sitDir = [0.2, 0.9, 0.35], standDir = [0.9, 0.5, 0.2]

    struct Stream {
        var ts: Int
        var rng = SitStandSplitMix64(seed: 11)
        var seconds: [ActivitySitStandSecond] = []

        mutating func u() -> Double { Double(rng.next() >> 11) / Double(1 << 53) }

        mutating func hold(_ n: Int, _ dir: [Double], dyn: Double = 0.01, wobble: Double = 0.05,
                           offWrist: Bool = false, asleep: Bool = false) {
            for _ in 0..<n {
                let g = dir.map { $0 + (u() - 0.5) * 2 * wobble }
                seconds.append(ActivitySitStandSecond(ts: ts, gravity: g, dynG: dyn + u() * 0.005,
                                                      offWrist: offWrist, asleep: asleep))
                ts += 1
            }
        }

        mutating func walk(_ n: Int) { hold(n, [0.5, 0.7, 0.3], dyn: 0.35, wobble: 0.3) }
        /// A walk as this strap reads it: dynamic acceleration under the 0.2 g segment bar, steps ticking.
        mutating func strapWalk(_ n: Int) {
            for _ in 0..<n {
                seconds.append(ActivitySitStandSecond(ts: ts, gravity: [0.5, 0.7, 0.3], dynG: 0.135, moving: true))
                ts += 1
            }
        }
        mutating func gap(_ n: Int) { ts += n }
    }

    func guided(_ posture: PostureClass, _ start: Int, _ end: Int, session: String = "s1",
                unsure: Bool = false) -> ActivityGroundTruthLabel {
        ActivityGroundTruthLabel(source: .guided, sessionId: session, startTs: start, endTs: end,
                                 protocolVersion: "calibration-v4", posture: posture.rawValue, userUnsure: unsure)
    }

    /// One calibration-like stretch per posture of `n` labelled seconds, separated by a walk.
    func calibration(sitSeconds n: Int, standSeconds m: Int, wobble: Double = 0.05)
        -> (labels: [ActivityGroundTruthLabel], seconds: [ActivitySitStandSecond]) {
        var s = Stream(ts: t0)
        let a = s.ts
        s.hold(n + 4, Self.sitDir, wobble: wobble)
        let sit = guided(.seatedLikely, a, s.ts)
        s.walk(20)
        let b = s.ts
        s.hold(m + 4, Self.standDir, wobble: wobble)
        let stand = guided(.uprightStationary, b, s.ts)
        return ([sit, stand], s.seconds)
    }

    // MARK: Model

    func testLogOddsNormalisesTheVectorAndIsZeroWithoutADirection() {
        let m = ActivitySitStandModel(weights: [0.5, 2, -1, 0])
        XCTAssertEqual(m.logOdds(gravity: 1, y: 0, z: 0), 2.5, accuracy: 1e-12)
        XCTAssertEqual(m.logOdds(gravity: 3, y: 0, z: 0), 2.5, accuracy: 1e-12, "only the direction counts")
        XCTAssertEqual(m.logOdds(gravity: 0, y: 0, z: 0), 0)
        XCTAssertEqual(m.logOdds(gravity: .nan, y: 0, z: 1), 0)
        XCTAssertEqual(ActivitySitStandModel.version, "sitstand-orient-1")
        XCTAssertEqual(m.modelVersion, ActivitySitStandModel.version)
    }

    func testTheModelRoundTripsThroughJSONAndItsTagFollowsTheWeights() throws {
        let m = ActivitySitStandModel(weights: [0.5, 2, -1, 0], sittingSeconds: 70, standingSeconds: 80)
        let back = try JSONDecoder().decode(ActivitySitStandModel.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.tag, m.tag)
        XCTAssertEqual(m.tag.count, 8)
        XCTAssertNotEqual(ActivitySitStandModel(weights: [0.5, 2, -1, 1e-9]).tag, m.tag)
    }

    // MARK: Fitter

    func testSeparableOrientationsFitTheRightSign() {
        let (labels, seconds) = calibration(sitSeconds: 80, standSeconds: 80)
        let r = ActivitySitStandFitter.fit(labels: labels, seconds: seconds)
        XCTAssertEqual(r.status, .fitted)
        let m = try! XCTUnwrap(r.model)
        XCTAssertGreaterThan(m.logOdds(gravity: Self.sitDir[0], y: Self.sitDir[1], z: Self.sitDir[2]), 1)
        XCTAssertLessThan(m.logOdds(gravity: Self.standDir[0], y: Self.standDir[1], z: Self.standDir[2]), -1)
        // Trimmed like the HSMM fitter: settle 3 s at the start and 1 s at the end of each hold.
        XCTAssertEqual(r.sittingSeconds, 80)
        XCTAssertEqual(r.standingSeconds, 80)
        XCTAssertEqual(m.sittingSeconds, 80)
        XCTAssertEqual(m.sessionIds, ["s1"])
        XCTAssertEqual(m.lambda, ActivitySitStandFitConfig.defaultLambda)
    }

    func testTheGravitySampleOverloadMatchesTheSecondsOne() {
        let (labels, seconds) = calibration(sitSeconds: 70, standSeconds: 70)
        let samples = seconds.map { GravitySample(ts: $0.ts, x: $0.gravity![0], y: $0.gravity![1], z: $0.gravity![2],
                                                  dynAccel: $0.dynG) }
        XCTAssertEqual(ActivitySitStandFitter.fit(labels: labels, gravity: samples),
                       ActivitySitStandFitter.fit(labels: labels, seconds: seconds))
    }

    func testEitherPostureUnderSixtyStillSecondsNeedsMoreData() {
        let (labels, seconds) = calibration(sitSeconds: 80, standSeconds: 59)
        let r = ActivitySitStandFitter.fit(labels: labels, seconds: seconds)
        XCTAssertEqual(r.status, .needsMoreData)
        XCTAssertNil(r.model)
        XCTAssertEqual(r.sittingSeconds, 80)
        XCTAssertEqual(r.standingSeconds, 59)
        XCTAssertEqual(r.standingSecondsNeeded, 1)
        XCTAssertEqual(r.sittingSecondsNeeded, 0)
    }

    func testOnlyStillSecondsCount() {
        var s = Stream(ts: t0)
        let a = s.ts
        s.hold(40, Self.sitDir)                    // still
        s.hold(40, Self.sitDir, dyn: 0.08)         // hands busy: not still, but not an active segment either
        let sit = guided(.seatedLikely, a, s.ts)
        let r = ActivitySitStandFitter.fit(labels: [sit], seconds: s.seconds)
        XCTAssertEqual(r.sittingSeconds, 40 - 3, "the busy seconds carry no posture; the 1-s end trim falls on them")
    }

    func testShrinkageBoundsTheStandardisedWeights() {
        let (labels, seconds) = calibration(sitSeconds: 80, standSeconds: 80, wobble: 0.01)
        for lambda in [0.05, 0.3, 3.0] {
            var cfg = ActivitySitStandFitConfig()
            cfg.lambda = lambda
            let m = try! XCTUnwrap(ActivitySitStandFitter.fit(labels: labels, seconds: seconds, config: cfg).model)
            let theta = (1...3).map { m.weights[$0] * m.scale[$0 - 1] }
            let norm = theta.reduce(0) { $0 + $1 * $1 }.squareRoot()
            XCTAssertLessThanOrEqual(norm, (2 * log(2) / lambda).squareRoot() + 1e-6, "λ = \(lambda)")
        }
        var strong = ActivitySitStandFitConfig()
        strong.lambda = 3
        let weak = ActivitySitStandFitter.fit(labels: labels, seconds: seconds).model!
        let shrunk = ActivitySitStandFitter.fit(labels: labels, seconds: seconds, config: strong).model!
        let d = Self.sitDir
        XCTAssertLessThan(abs(shrunk.logOdds(gravity: d[0], y: d[1], z: d[2])), abs(weak.logOdds(gravity: d[0], y: d[1], z: d[2])))
        XCTAssertGreaterThan(shrunk.logOdds(gravity: d[0], y: d[1], z: d[2]), 0, "shrinking never flips the sign here")
    }

    func testTheFitIsDeterministicAndOrderFree() {
        let (labels, seconds) = calibration(sitSeconds: 75, standSeconds: 90)
        let a = ActivitySitStandFitter.fit(labels: labels, seconds: seconds)
        let b = ActivitySitStandFitter.fit(labels: labels.reversed(), seconds: seconds.reversed())
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.model?.tag, b.model?.tag)
    }

    func testIgnoredLabelsAndConflicts() {
        let (labels, seconds) = calibration(sitSeconds: 80, standSeconds: 80)
        var others: [ActivityGroundTruthLabel] = []
        // Unsure guided, stretch feedback, imported and a transition label over the standing hold: all ignored.
        let stand = labels[1]
        others.append(guided(.seatedLikely, stand.startTs, stand.endTs, unsure: true))
        for source in [ActivityGroundTruthSource.stretchFeedback, .imported] {
            others.append(ActivityGroundTruthLabel(source: source, stretchKey: "x", startTs: stand.startTs,
                                                   endTs: stand.endTs, posture: PostureClass.seatedLikely.rawValue))
        }
        others.append(ActivityGroundTruthLabel(source: .guided, sessionId: "s1", startTs: stand.startTs,
                                               endTs: stand.endTs, posture: PostureClass.seatedLikely.rawValue,
                                               transitionKind: "stand_to_sit", transitionTs: stand.startTs))
        XCTAssertEqual(ActivitySitStandFitter.fit(labels: labels + others, seconds: seconds),
                       ActivitySitStandFitter.fit(labels: labels, seconds: seconds))
        // A confident guided label that disagrees drops the seconds both claim.
        let clash = guided(.seatedLikely, stand.startTs, stand.startTs + 30, session: "s2")
        let r = ActivitySitStandFitter.fit(labels: labels + [clash], seconds: seconds)
        XCTAssertEqual(r.standingSeconds, 80 - 26, "the clash's trimmed 26 s conflict")
        XCTAssertEqual(r.sittingSeconds, 80)
    }

    func testConfirmationsFitOnTheStillSegmentAtTheAnswer() {
        // Stood still, walked to a chair, sat: a "sitting" answer labels only the sitting segment.
        var s = Stream(ts: t0)
        s.hold(15, Self.standDir)
        s.walk(12)
        s.hold(25, Self.sitDir)
        let answerTs = s.ts - 2
        s.hold(10, Self.sitDir)
        let label = ActivitySitStandConfirmations.label(answer: .sitting, ts: answerTs)
        XCTAssertEqual(label.source, .confirmation)
        XCTAssertEqual(label.startTs, answerTs - 30)
        XCTAssertEqual(label.endTs, answerTs + 5)
        XCTAssertEqual(ActivitySitStandConfirmations.answerTs(of: label), answerTs)
        XCTAssertNotNil(label.validated())
        XCTAssertFalse(label.isStrong)
        var cfg = ActivitySitStandFitConfig()
        cfg.minClassSeconds = 1
        let rows = ActivitySitStandFitter.labelledStillSeconds(labels: [label], seconds: s.seconds, config: cfg)
        XCTAssertEqual(rows.confirmations, 1)
        XCTAssertFalse(rows.rows.isEmpty)
        XCTAssertTrue(rows.rows.allSatisfy(\.sitting))
        let standing = rows.rows.filter { $0.u.0 > 0.6 }
        XCTAssertTrue(standing.isEmpty, "the standing before the walk is never labelled sitting")
        // Disabled: confirmations add nothing.
        cfg.useConfirmations = false
        XCTAssertTrue(ActivitySitStandFitter.labelledStillSeconds(labels: [label], seconds: s.seconds, config: cfg).rows.isEmpty)
        // A "neither" answer is stored as posture `unknown` (the server's confirmation shape) and never fits.
        let neither = ActivitySitStandConfirmations.label(answer: .neither, ts: answerTs)
        XCTAssertEqual(neither.posture, PostureClass.unknown.rawValue)
        XCTAssertFalse(neither.userUnsure)
        XCTAssertNotNil(neither.validated())
        cfg.useConfirmations = true
        XCTAssertTrue(ActivitySitStandFitter.labelledStillSeconds(labels: [neither], seconds: s.seconds, config: cfg).rows.isEmpty)
    }

    func testConfirmationsAloneCanFitAModel() {
        var s = Stream(ts: t0)
        var labels: [ActivityGroundTruthLabel] = []
        for i in 0..<6 {
            let dir = i % 2 == 0 ? Self.sitDir : Self.standDir
            s.hold(40, dir)
            labels.append(ActivitySitStandConfirmations.label(answer: i % 2 == 0 ? .sitting : .standing, ts: s.ts - 6))
            s.walk(15)
        }
        let r = ActivitySitStandFitter.fit(labels: labels, seconds: s.seconds)
        XCTAssertEqual(r.status, .fitted)
        XCTAssertEqual(r.model?.confirmations, 6)
        XCTAssertGreaterThanOrEqual(r.sittingSeconds, 60)
        let d = Self.standDir
        XCTAssertLessThan(r.model!.logOdds(gravity: d[0], y: d[1], z: d[2]), 0)
    }

    func testTheHSMMProfileFitterIgnoresConfirmations() {
        let label = ActivitySitStandConfirmations.label(answer: .sitting, ts: t0)
        XCTAssertNil(ActivityPersonalProfileFitter.staticMode(of: label))
        XCTAssertTrue(ActivityPersonalProfileFitter.truthBySecond([label]).isEmpty)
    }

    // MARK: Smoothing

    func testSegmentsSplitOnActivityAndAverageTheirStillSeconds() {
        var s = Stream(ts: t0)
        s.hold(60, Self.sitDir)
        s.hold(15, Self.sitDir, dyn: 0.5)              // a burst: the 10-s mean goes over 0.2 g
        s.hold(60, Self.standDir)
        let model = ActivitySitStandModel(weights: [4, -10, 0, 0])
        let out = ActivitySitStandSmoothing.smooth(s.seconds, model: model)
        XCTAssertEqual(out.count, 135)
        let first = out.prefix(55), last = out.suffix(55)
        let s1 = Set(first.compactMap(\.segment)), s2 = Set(last.compactMap(\.segment))
        XCTAssertEqual(s1.count, 1)
        XCTAssertEqual(s2.count, 1)
        XCTAssertNotEqual(s1, s2)
        let mean1 = first.compactMap(\.logOdds).reduce(0, +) / Double(first.count)
        XCTAssertGreaterThan(first.first!.smoothedLogOdds!, 0)
        XCTAssertLessThan(last.last!.smoothedLogOdds!, 0)
        XCTAssertTrue(first.allSatisfy { $0.smoothedLogOdds == first.first!.smoothedLogOdds }, "one value per segment")
        XCTAssertEqual(first.first!.smoothedLogOdds!, mean1, accuracy: 0.05)
        // The burst's middle makes no claim.
        XCTAssertNil(out[67].smoothedLogOdds)
        XCTAssertNil(out[67].segment)
    }

    func testBusySecondsInsideASegmentMakeNoClaimAndDoNotSplitIt() {
        var s = Stream(ts: t0)
        s.hold(30, Self.sitDir)
        s.hold(3, Self.standDir, dyn: 0.1)             // busy but below the active bar on a 10-s mean
        s.hold(30, Self.sitDir)
        let out = ActivitySitStandSmoothing.smooth(s.seconds, model: ActivitySitStandModel(weights: [4, -10, 0, 0]))
        XCTAssertEqual(Set(out.compactMap(\.segment)).count, 1)
        XCTAssertNil(out[31].smoothedLogOdds)
        XCTAssertNil(out[31].logOdds)
        XCTAssertEqual(out[0].smoothedLogOdds, out[62].smoothedLogOdds)
    }

    func testGapsOffWristAndSleepSplitSegmentsAndClaimNothing() {
        var s = Stream(ts: t0)
        s.hold(30, Self.sitDir)
        s.gap(11)
        s.hold(30, Self.sitDir)
        s.hold(5, Self.sitDir, offWrist: true)
        s.hold(30, Self.sitDir)
        s.hold(20, Self.sitDir, asleep: true)
        s.hold(30, Self.sitDir)
        let out = ActivitySitStandSmoothing.smooth(s.seconds, model: ActivitySitStandModel(weights: [1, 0, 0, 0]))
        XCTAssertEqual(Set(out.compactMap(\.segment)).count, 4)
        let excluded = Set(s.seconds.filter { $0.offWrist || $0.asleep }.map(\.ts))
        XCTAssertEqual(excluded.count, 25)
        XCTAssertTrue(out.filter { excluded.contains($0.ts) }.allSatisfy { $0.smoothedLogOdds == nil && $0.segment == nil })
        // A short gap (≤ 10 s) does not split.
        var t = Stream(ts: t0)
        t.hold(30, Self.sitDir); t.gap(8); t.hold(30, Self.sitDir)
        XCTAssertEqual(Set(ActivitySitStandSmoothing.smooth(t.seconds, model: ActivitySitStandModel(weights: [1, 0, 0, 0]))
            .compactMap(\.segment)).count, 1)
    }

    func testLocomotionSplitsSegmentsEvenUnderTheDynamicAccelerationBar() {
        var s = Stream(ts: t0)
        s.hold(40, Self.sitDir)
        s.strapWalk(30)
        s.hold(40, Self.standDir)
        let out = ActivitySitStandSmoothing.smooth(s.seconds, model: ActivitySitStandModel(weights: [4, -10, 0, 0]))
        XCTAssertEqual(Set(out.compactMap(\.segment)).count, 2)
        XCTAssertGreaterThan(out[0].smoothedLogOdds!, 0)
        XCTAssertLessThan(out.last!.smoothedLogOdds!, 0)
        // The same walk without the locomotion flag would join the two (the 0.2 g bar is not reached).
        let unflagged = s.seconds.map { ActivitySitStandSecond(ts: $0.ts, gravity: $0.gravity, dynG: $0.dynG) }
        XCTAssertEqual(Set(ActivitySitStandSmoothing.smooth(unflagged, model: ActivitySitStandModel(weights: [1, 0, 0, 0]))
            .compactMap(\.segment)).count, 1)
        // From store rows: step ticks / the strap's walk class mark locomotion.
        let gravity = s.seconds.map { GravitySample(ts: $0.ts, x: $0.gravity![0], y: $0.gravity![1], z: $0.gravity![2],
                                                    dynAccel: $0.dynG) }
        var counter = 100
        let steps: [StepSample] = s.seconds.map { sec in
            if sec.moving { counter += 2 }
            return StepSample(ts: sec.ts, counter: counter, activityClass: sec.moving ? 1 : 0)
        }
        let rebuilt = ActivitySitStandSecond.seconds(gravity: gravity, steps: steps)
        XCTAssertEqual(rebuilt.map(\.moving), s.seconds.map(\.moving))
        XCTAssertEqual(ActivitySitStandSecond.seconds(gravity: gravity).filter(\.moving).count, 0)
    }

    func testNoGravityOrNoDynamicAccelerationClaimsNothing() {
        let seconds = [ActivitySitStandSecond(ts: t0, gravity: nil, dynG: 0.01),
                       ActivitySitStandSecond(ts: t0 + 1, gravity: [0, 0, 1], dynG: nil),
                       ActivitySitStandSecond(ts: t0 + 2, gravity: [0, 0, 1], dynG: 0.01)]
        let out = ActivitySitStandSmoothing.smooth(seconds, model: ActivitySitStandModel(weights: [1, 0, 0, 0]))
        XCTAssertNil(out[0].smoothedLogOdds)
        XCTAssertNil(out[1].smoothedLogOdds)
        XCTAssertEqual(out[2].smoothedLogOdds, 1)
    }

    // MARK: Gate

    func score(_ answer: ActivitySitStandAnswer, _ prediction: ActivitySitStandPrediction, at i: Int) -> ActivitySitStandConfirmationScore {
        ActivitySitStandConfirmationScore(ts: t0 + 100 * i, answer: answer, prediction: prediction,
                                          logOdds: prediction == .unscorable ? nil : 1)
    }

    let model = ActivitySitStandModel(weights: [4, -10, 0, 0])

    func testNoModelNeedsCalibration() {
        let d = ActivitySitStandGate.evaluate(model: nil, confirmations: [score(.sitting, .sitting, at: 0)])
        XCTAssertEqual(d.state, .needsCalibration)
        XCTAssertEqual(d.gateVersion, "sitstand-gate-1")
        XCTAssertEqual(ActivitySitStandGate.evaluate(model: ActivitySitStandModel(weights: [1, 2]), confirmations: []).state,
                       .needsCalibration, "an unusable model is no model")
    }

    func testEnabledNeedsSixRightAndThreeOfEachPosture() {
        let six = (0..<3).map { score(.sitting, .sitting, at: $0) } + (3..<6).map { score(.standing, .standing, at: $0) }
        let d = ActivitySitStandGate.evaluate(model: model, confirmations: six)
        XCTAssertEqual(d.state, .enabled)
        XCTAssertTrue(d.isEnabled)
        XCTAssertEqual(d.scorable, 6); XCTAssertEqual(d.correct, 6)
        XCTAssertEqual(d.modelVersion, "sitstand-orient-1")
        XCTAssertEqual(d.modelTag, model.tag)
        // Five right: still verifying.
        let five = Array(six.prefix(5))
        XCTAssertEqual(ActivitySitStandGate.evaluate(model: model, confirmations: five).state,
                       .verifying(scorable: 5, correct: 5, needSitting: 0, needStanding: 1))
        // Eight, all right, but only one standing answer: the class minimum is missing.
        let lopsided = (0..<7).map { score(.sitting, .sitting, at: $0) } + [score(.standing, .standing, at: 7)]
        XCTAssertEqual(ActivitySitStandGate.evaluate(model: model, confirmations: lopsided).state,
                       .verifying(scorable: 8, correct: 8, needSitting: 0, needStanding: 2))
        XCTAssertEqual(ActivitySitStandGate.evaluate(model: model, confirmations: []).state,
                       .verifying(scorable: 0, correct: 0, needSitting: 3, needStanding: 3))
    }

    func testEightScorableWithFewerThanSixRightIsNotReliable() {
        let c = (0..<4).map { score(.sitting, .sitting, at: $0) } + [score(.standing, .standing, at: 4)]
            + (5..<8).map { score(.standing, .sitting, at: $0) }
        let d = ActivitySitStandGate.evaluate(model: model, confirmations: c)
        XCTAssertEqual(d.state, .notReliable)
        XCTAssertEqual(d.correct, 5)
        // Seven scorable with five right is still verifying: the window is not full.
        XCTAssertEqual(ActivitySitStandGate.evaluate(model: model, confirmations: Array(c.prefix(7))).state,
                       .verifying(scorable: 7, correct: 5, needSitting: 0, needStanding: 0))
    }

    func testTheGateRollsAndAnEnabledWearerDropsBack() {
        var c = (0..<4).map { score(.sitting, .sitting, at: $0) } + (4..<8).map { score(.standing, .standing, at: $0) }
        XCTAssertEqual(ActivitySitStandGate.evaluate(model: model, confirmations: c).state, .enabled)
        c += (8..<10).map { score(.sitting, .standing, at: $0) }
        XCTAssertEqual(ActivitySitStandGate.evaluate(model: model, confirmations: c).state, .enabled, "6 of the last 8")
        c.append(score(.sitting, .standing, at: 10))
        let d = ActivitySitStandGate.evaluate(model: model, confirmations: c)
        XCTAssertEqual(d.state, .notReliable, "5 of the last 8")
        XCTAssertEqual(d.scorable, 8)
        // And recovers when the latest answers are right again.
        c += (11..<17).map { score($0 % 2 == 0 ? .sitting : .standing, $0 % 2 == 0 ? .sitting : .standing, at: $0) }
        XCTAssertEqual(ActivitySitStandGate.evaluate(model: model, confirmations: c.shuffled()).state, .enabled,
                       "order of the input does not matter: the latest by ts are used")
    }

    func testUnscorableIsExcludedButUnresolvedCountsWrong() {
        var c = (0..<3).map { score(.sitting, .sitting, at: $0) } + (3..<6).map { score(.standing, .standing, at: $0) }
        c += [score(.neither, .sitting, at: 6), score(.sitting, .unscorable, at: 7), score(.standing, .unscorable, at: 8)]
        let d = ActivitySitStandGate.evaluate(model: model, confirmations: c)
        XCTAssertEqual(d.state, .enabled)
        XCTAssertEqual(d.scorable, 6)
        XCTAssertEqual(d.excluded, 3)
        // Unresolved answers fill the window and count as wrong.
        let u = c + (9..<12).map { score(.sitting, .unresolved, at: $0) }
        let du = ActivitySitStandGate.evaluate(model: model, confirmations: u)
        XCTAssertEqual(du.scorable, 8)
        XCTAssertEqual(du.correct, 5)
        XCTAssertEqual(du.state, .notReliable)
        XCTAssertFalse(score(.sitting, .unresolved, at: 0).isCorrect)
        XCTAssertTrue(score(.sitting, .unresolved, at: 0).isScorable)
    }

    func testScoringAConfirmation() {
        var s = Stream(ts: t0)
        s.walk(20)
        s.hold(120, Self.sitDir)
        let sitTs = s.ts - 10
        s.walk(60)
        let walkTs = s.ts - 20
        s.hold(60, Self.standDir)
        let standTs = s.ts - 10
        let sit = ActivitySitStandGate.score(answer: .sitting, ts: sitTs, seconds: s.seconds, model: model)
        XCTAssertEqual(sit.prediction, .sitting)
        XCTAssertTrue(sit.isCorrect)
        XCTAssertEqual(sit.modelTag, model.tag)
        let stand = ActivitySitStandGate.score(answer: .sitting, ts: standTs, seconds: s.seconds, model: model)
        XCTAssertEqual(stand.prediction, .standing)
        XCTAssertFalse(stand.isCorrect)
        XCTAssertTrue(stand.isScorable)
        let walking = ActivitySitStandGate.score(answer: .standing, ts: walkTs, seconds: s.seconds, model: model)
        XCTAssertEqual(walking.prediction, .unscorable)
        XCTAssertEqual(walking.reason, "not_still")
        XCTAssertEqual(ActivitySitStandGate.score(answer: .neither, ts: sitTs, seconds: s.seconds, model: model).reason, "neither")
        XCTAssertEqual(ActivitySitStandGate.score(answer: .sitting, ts: sitTs, seconds: s.seconds, model: nil).reason, "no_model")
        XCTAssertEqual(ActivitySitStandGate.score(answer: .sitting, ts: t0 - 1000, seconds: s.seconds, model: model).reason, "no_data")
        // An undecided head abstains: unresolved, scorable, wrong.
        let flat = ActivitySitStandGate.score(answer: .sitting, ts: sitTs, seconds: s.seconds,
                                              model: ActivitySitStandModel(weights: [0.05, 0, 0, 0]))
        XCTAssertEqual(flat.prediction, .unresolved)
        // Off the wrist or asleep at the answer: excluded.
        var o = Stream(ts: t0)
        o.hold(60, Self.sitDir, offWrist: true)
        XCTAssertEqual(ActivitySitStandGate.score(answer: .sitting, ts: t0 + 40, seconds: o.seconds, model: model).reason, "off_wrist")
        var z = Stream(ts: t0)
        z.hold(60, Self.sitDir, asleep: true)
        XCTAssertEqual(ActivitySitStandGate.score(answer: .sitting, ts: t0 + 40, seconds: z.seconds, model: model).reason, "asleep")
    }

    func testScoresRoundTripThroughJSON() throws {
        let d = ActivitySitStandGate.evaluate(model: model, confirmations: [score(.sitting, .sitting, at: 0)])
        XCTAssertEqual(try JSONDecoder().decode(ActivitySitStandGateDecision.self, from: JSONEncoder().encode(d)), d)
        let sc = score(.standing, .unresolved, at: 1)
        XCTAssertEqual(try JSONDecoder().decode(ActivitySitStandConfirmationScore.self, from: JSONEncoder().encode(sc)), sc)
    }

    // MARK: Protocol v4

    func testCalibrationV4Shape() {
        let p = ActivityCalibrationProtocols.v4
        XCTAssertEqual(p.version, "calibration-v4")
        XCTAssertEqual(ActivityCalibrationProtocols.current.version, "calibration-v4")
        XCTAssertEqual(p.activities.map(\.id), ["sit-stand", "lie-down"])
        let sitStand = p.activities[0]
        XCTAssertEqual(sitStand.tasks.map(\.id), [
            "sit-stand.sit-1", "sit-stand.stand-up-1", "sit-stand.stand-1", "sit-stand.sit-down-1",
            "sit-stand.sit-2", "sit-stand.stand-up-2", "sit-stand.stand-2", "sit-stand.sit-down-2",
        ])
        XCTAssertEqual(sitStand.tasks.map(\.repetition), [1, 1, 1, 1, 2, 2, 2, 2])
        for task in sitStand.tasks {
            if task.isMove {
                XCTAssertEqual(task.cueSecondsRange, 2...5, task.id)
                XCTAssertEqual(task.cueSeconds, 2, "\(task.id): the nominal cue is the range's start")
                XCTAssertEqual(task.durationSeconds, 12)
            } else {
                XCTAssertEqual(task.durationSeconds, 30)
                XCTAssertNil(task.cueSecondsRange)
                XCTAssertTrue(task.instructions.contains("No need to hold still"), "\(task.id): natural, hands busy")
            }
        }
        XCTAssertEqual(sitStand.tasks.filter { $0.posture == PostureClass.seatedLikely.rawValue }.count, 2)
        XCTAssertEqual(sitStand.tasks.filter { $0.posture == PostureClass.uprightStationary.rawValue }.count, 2)
        // The lie-down activity is v3's, unchanged, with its fixed cue.
        XCTAssertEqual(p.activities[1], ActivityCalibrationProtocols.v3.activities[1])
        XCTAssertTrue(p.activities[1].tasks.filter(\.isMove).allSatisfy { $0.cueSeconds == 3 && $0.cueSecondsRange == nil })
        // v3 stays readable.
        XCTAssertEqual(ActivityCalibrationProtocols.v3.version, "calibration-v3")
        XCTAssertEqual(ActivityCalibrationProtocols.model(forVersion: "calibration-v3"), ActivityCalibrationProtocols.v3)
        XCTAssertEqual(ActivityCalibrationProtocols.model(forVersion: "calibration-v4"), p)
        XCTAssertNil(ActivityCalibrationProtocols.model(forVersion: "calibration-v1"))
    }

    func testCueJitterIsDeterministicWithASeededGenerator() {
        let move = ActivityCalibrationProtocols.v4.tasks.first(where: \.isMove)!
        var a = SitStandSplitMix64(seed: 42), b = SitStandSplitMix64(seed: 42), c = SitStandSplitMix64(seed: 43)
        let xs = (0..<50).map { _ in move.resolvedCueSeconds(using: &a)! }
        let ys = (0..<50).map { _ in move.resolvedCueSeconds(using: &b)! }
        let zs = (0..<50).map { _ in move.resolvedCueSeconds(using: &c)! }
        XCTAssertEqual(xs, ys)
        XCTAssertNotEqual(xs, zs)
        XCTAssertTrue(xs.allSatisfy { (2...5).contains($0) })
        XCTAssertEqual(Set(xs), [2, 3, 4, 5], "every offset in the range is reachable")
        // Fixed cues and holds are unaffected by the generator.
        let fixed = ActivityCalibrationProtocols.v3.tasks.first(where: \.isMove)!
        XCTAssertEqual(fixed.resolvedCueSeconds(using: &a), 3)
        let hold = ActivityCalibrationProtocols.v4.tasks.first { !$0.isMove }!
        XCTAssertNil(hold.resolvedCueSeconds(using: &a))
        XCTAssertNotNil(move.resolvedCueSeconds())
    }

    func testV4LabelsDecodeAlongsideV3Ones() throws {
        for version in ["calibration-v3", "calibration-v4"] {
            let label = ActivityGroundTruthLabel(source: .guided, sessionId: "s", startTs: t0, endTs: t0 + 26,
                                                 repetition: 2, protocolVersion: version,
                                                 posture: PostureClass.seatedLikely.rawValue)
            let back = try JSONDecoder().decode(ActivityGroundTruthLabel.self, from: JSONEncoder().encode(label))
            XCTAssertEqual(back.protocolVersion, version)
            XCTAssertEqual(back.repetition, 2)
        }
        let conf = ActivitySitStandConfirmations.label(answer: .standing, ts: t0)
        let back = try JSONDecoder().decode(ActivityGroundTruthLabel.self, from: JSONEncoder().encode(conf))
        XCTAssertEqual(back.source, .confirmation)
        XCTAssertEqual(back.labelKey, "confirmation:sitstand:\(t0 - 30)")
    }
}

// MARK: - Decoder hookup

final class ActivitySitStandDecoderTests: XCTestCase {
    /// A head that reads the sim's arm-hanging forearm (+x ≈ 0.9) as standing and the flat forearm (0.2) as
    /// sitting.
    let head = ActivitySitStandModel(weights: [4, -10, 0, 0])

    func config(_ head: ActivitySitStandModel?) -> ActivityDecoderConfig {
        var c = ActivityDecoderConfig()
        c.sitStandHead = head
        return c
    }

    /// Walk, stop, stand still with the arm hanging.
    func standingScenario() -> [ActivityObservation] {
        var sim = ActivitySim(seed: 5)
        sim.forearm(0.2)
        sim.still(120)
        sim.walk(90)
        sim.forearm(0.9)
        sim.still(240)
        return sim.observations
    }

    func testWithoutAHeadNothingChanges() throws {
        let obs = standingScenario()
        var a = ActivityContextDecoder(), b = ActivityContextDecoder(config: config(nil))
        let sa = a.run(obs), sb = b.run(obs)
        XCTAssertEqual(sa, sb)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try enc.encode(a.snapshot()), try enc.encode(b.snapshot()))
        XCTAssertFalse(String(decoding: try enc.encode(ActivityDecoderConfig()), as: UTF8.self).contains("sitStand"))
        XCTAssertFalse(String(decoding: try enc.encode(a.snapshot()), as: UTF8.self).contains("sitStand"))
        XCTAssertFalse(sa.contains { $0.evidence.personalSitStand != nil })
        XCTAssertEqual(ActivityDecoderConfig().cacheTag, config(nil).cacheTag)
        // An unusable head is no head.
        XCTAssertEqual(config(ActivitySitStandModel(weights: [1])).cacheTag, ActivityDecoderConfig().cacheTag)
        var c = ActivityContextDecoder(config: config(ActivitySitStandModel(weights: [1])))
        XCTAssertEqual(c.run(obs), sa)
    }

    func testTheWristAloneNeverCommitsStanding() {
        var d = ActivityContextDecoder()
        let states = d.run(standingScenario())
        let tail = states.suffix(20)
        XCTAssertFalse(tail.contains { ActivityClassifier.classify(state: $0).activityClass == .standing
                && $0.evidence.learnedPosture == nil && ActivityClassifier.classify(state: $0).confidence > 0.75 })
        XCTAssertFalse(tail.contains { $0.displayContext == ActivityDisplay.likelyStanding })
    }

    func testAHeadCommitsLikelyStandingInAStillUprightStretch() {
        var d = ActivityContextDecoder(config: config(head))
        let states = d.run(standingScenario())
        let tail = Array(states.suffix(12))
        for s in tail {
            let k = ActivityClassifier.classify(state: s)
            XCTAssertEqual(k.activityClass, .standing, "\(s.ts): \(s.displayContext ?? "nil")")
            XCTAssertLessThanOrEqual(k.confidence, ActivityClassifier.learnedPostureConfidenceCap + 1e-12)
            XCTAssertEqual(s.displayContext, ActivityDisplay.likelyStanding)
            XCTAssertEqual(s.evidence.learnedPosture, .uprightStationary)
            XCTAssertTrue(s.evidence.experts.contains("personal_sitstand"))
        }
        // Walking states carry no personal posture claim.
        let walking = states.filter { $0.displayContext == "Walking" }
        XCTAssertFalse(walking.isEmpty)
        XCTAssertTrue(walking.allSatisfy { $0.evidence.personalSitStand == nil })
    }

    func testAHeadSaysLikelySittingForAStillSeatedStretch() {
        var sim = ActivitySim(seed: 9)
        sim.forearm(0.2)
        sim.still(300)
        var d = ActivityContextDecoder(config: config(head))
        let tail = d.run(sim.observations).suffix(10)
        for s in tail {
            XCTAssertEqual(s.displayContext, ActivityDisplay.likelySitting)
            XCTAssertEqual(ActivityClassifier.classify(state: s).activityClass, .sitting)
            XCTAssertLessThanOrEqual(ActivityClassifier.classify(state: s).confidence, 0.85 + 1e-12)
        }
    }

    func testNoClaimWhileWalkingOrAsleepOrOffWrist() {
        var sim = ActivitySim(seed: 3)
        sim.forearm(0.9)
        sim.walk(200)
        sim.sleeping(400)
        sim.offWrist(60)
        var d = ActivityContextDecoder(config: config(head))
        let states = d.run(sim.observations)
        XCTAssertTrue(states.allSatisfy { $0.evidence.personalSitStand == nil })
        XCTAssertFalse(states.contains { $0.displayContext == ActivityDisplay.likelyStanding
            || $0.displayContext == ActivityDisplay.likelySitting })
        XCTAssertTrue(states.suffix(70).prefix(5).allSatisfy { $0.displayContext == "Asleep" || $0.displayContext == ActivityDisplay.offWrist })
    }

    func testTheCacheTagChangesWithTheHead() {
        let base = ActivityDecoderConfig().cacheTag
        let a = config(head).cacheTag, b = config(ActivitySitStandModel(weights: [4, -9, 0, 0])).cacheTag
        XCTAssertNotEqual(a, base)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix(base + "-ss"))
        XCTAssertTrue(a.contains("sitstandorient1"))
        XCTAssertTrue(a.hasSuffix(head.tag))
    }

    func testASnapshotNeverContinuesAcrossHeads() {
        var d = ActivityContextDecoder(config: config(head))
        _ = d.run(standingScenario())
        let snap = d.snapshot()
        XCTAssertEqual(ActivityContextDecoder(config: config(head), restoring: snap).restoreOutcome, .resumed)
        XCTAssertEqual(ActivityContextDecoder(config: config(nil), restoring: snap).restoreOutcome,
                       .discarded("sit_stand_mismatch"))
        XCTAssertEqual(ActivityContextDecoder(config: config(ActivitySitStandModel(weights: [3, -9, 0, 0])), restoring: snap)
            .restoreOutcome, .discarded("sit_stand_mismatch"))
        var plain = ActivityContextDecoder()
        _ = plain.run(standingScenario())
        XCTAssertEqual(ActivityContextDecoder(config: config(head), restoring: plain.snapshot()).restoreOutcome,
                       .discarded("sit_stand_mismatch"))
    }

    func testTheNewLabelsAreKnownToTheDisplayAndClassifier() {
        XCTAssertTrue(ActivityDisplay.allLabels.contains(ActivityDisplay.likelySitting))
        XCTAssertTrue(ActivityDisplay.allLabels.contains(ActivityDisplay.likelyStanding))
        XCTAssertEqual(ActivityClassifier.activityClass(forDisplayLabel: ActivityDisplay.likelySitting), .sitting)
        XCTAssertEqual(ActivityClassifier.activityClass(forDisplayLabel: ActivityDisplay.likelyStanding), .standing)
        XCTAssertEqual(ActivityDisplay.group(ActivityDisplay.likelySitting), "seated")
        XCTAssertEqual(ActivityDisplay.group(ActivityDisplay.likelyStanding), "upright")
        var e = ActivityEvidenceSummary(imu: false, encoder: false, dynAccel: true, gravity: true, steps: false,
                                        heartRate: true, sleep: false, coverage: 0.5)
        XCTAssertFalse(e.experts.contains("personal_sitstand"))
        e.personalSitStand = true
        XCTAssertEqual(e.experts, ["personal_sitstand"])
    }
}
