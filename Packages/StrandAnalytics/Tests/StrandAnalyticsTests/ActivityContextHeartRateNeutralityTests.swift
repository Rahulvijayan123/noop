import XCTest
@testable import StrandAnalytics

/// D9-02: the posture context a heart-rate sample is joined to must not depend on that heart rate. The HR channel
/// separates stationary from active / exertion modes only; among bed rest, seated and upright it is neutral, and a
/// personal profile cannot make it per posture again.
final class ActivityContextHeartRateNeutralityTests: XCTestCase {

    private func decode(_ observations: [ActivityObservation], config: ActivityDecoderConfig = ActivityDecoderConfig())
        -> [ActivityContextState] {
        var d = ActivityContextDecoder(config: config)
        return d.run(observations)
    }

    /// Twenty minutes of a quiet wrist, the forearm held flat, at a fixed heart rate. Same seed: the two streams
    /// differ only in the rate.
    private func still(hr: Int, sitDownFirst: Bool = false) -> [ActivityObservation] {
        var sim = ActivitySim(seed: 21)
        var opt = ActivitySim.Options()
        opt.hr = hr
        if sitDownFirst {
            sim.forearm(0.9)
            sim.walk(60, opt: opt)
            sim.still(10, opt: opt)
            sim.postureShift(netDegrees: 45, toForearm: 0.45, opt: opt)
        }
        sim.still(1200, opt: opt)
        return sim.observations
    }

    private func assertPostureIgnoresHeartRate(_ low: [ActivityContextState], _ high: [ActivityContextState],
                                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(low.count, high.count, file: file, line: line)
        var worstSplit = 0.0, worstStationary = 0.0
        // Skip the first minute (warm-up, the HR channel's own window filling).
        for (a, b) in zip(low, high).dropFirst(60) {
            for p in [PostureClass.seatedLikely, .uprightStationary, .recumbent, .unknown] {
                worstSplit = max(worstSplit, abs(a.posture[p] - b.posture[p]))
            }
            worstStationary = max(worstStationary, abs(a.locomotion[.stationary] - b.locomotion[.stationary]))
        }
        XCTAssertLessThan(worstSplit, 0.02, "posture split moved with the heart rate", file: file, line: line)
        XCTAssertLessThan(worstStationary, 0.01, "stationary mass moved with a resting-range heart rate",
                          file: file, line: line)
        let ka = ActivityClassifier.classify(state: low.last!), kb = ActivityClassifier.classify(state: high.last!)
        XCTAssertEqual(ka.activityClass, kb.activityClass, file: file, line: line)
    }

    func testTheSameStillnessAtSixtyAndEightyBeatsGetsTheSamePostureSplit() {
        // Default reference: rest 60, max 190, so 60 vs 80 bpm is hrRel 0.0 vs 0.15.
        let low = decode(still(hr: 60)), high = decode(still(hr: 80))
        assertPostureIgnoresHeartRate(low, high)
        XCTAssertGreaterThan(low.last!.locomotion[.stationary], 0.9)
    }

    func testAResolvedSitDownIsNotTippedTowardStandingByAnElevatedRate() {
        // With posture evidence (a sit-down whose direction the forearm shows), the evidence decides the split
        // and the rate still does not move it.
        let low = decode(still(hr: 60, sitDownFirst: true)), high = decode(still(hr: 80, sitDownFirst: true))
        assertPostureIgnoresHeartRate(low, high)
    }

    /// Sitting at a desk, then a shift that lays the forearm flat (a lie-down onto a sofa, or a sit-back the wrist
    /// cannot tell from one), a quiet stretch, then the reverse shift (getting up) and the desk again. The rate
    /// during and after each shift is `hr`; same seed, so the streams differ only in the rate.
    private func lieDownAndGetUp(hr: Int) -> (obs: [ActivityObservation], down: Int, up: Int) {
        var sim = ActivitySim(seed: 23)
        var base = ActivitySim.Options()
        base.hr = 66
        var opt = ActivitySim.Options()
        opt.hr = hr
        sim.forearm(0.55)
        sim.desk(300, opt: base)
        let down = sim.ts
        sim.postureShift(netDegrees: -60, seconds: 4, toForearm: 0.05, opt: opt)
        sim.still(600, dyn: 0.006, opt: opt)
        let up = sim.ts
        sim.postureShift(netDegrees: 60, seconds: 4, toForearm: 0.55, opt: opt)
        sim.desk(300, opt: opt)
        return (sim.observations, down, up)
    }

    /// hsmm-1.9: the four postural-transition modes expect one heart-rate level (lying down was 0.15 against 0.20),
    /// so a low or a high rate at a lie-down or a getting-up cannot pick the path into one posture over another.
    func testLyingDownAndGettingUpReadTheSamePostureAtAnyHeartRate() {
        let levels = Set([BodyMode.sitToStand, .standToSit, .lyingDown, .gettingUp].map {
            ActivityContextModel.profiles[$0.rawValue].hrRel
        })
        XCTAssertEqual(levels, [ActivityContextModel.transitionHrRel])

        let runs = [52, 66, 90].map { hr -> (hr: Int, states: [ActivityContextState], down: Int, up: Int) in
            let s = lieDownAndGetUp(hr: hr)
            return (hr, decode(s.obs), s.down, s.up)
        }
        let reference = runs[1]
        for other in [runs[0], runs[2]] {
            XCTAssertEqual(other.states.count, reference.states.count)
            // Posture choice: the posture a state CLAIMS (a sitting / standing / lying class). A rate may move the
            // overall confidence across the commit bar (an elevated rate agrees less with stillness, so the class
            // hedges to "stationary"), but it must never make one run claim a posture the other contradicts, and
            // never create or remove a lying claim.
            func claim(_ k: ActivityClassification) -> String? {
                switch k.activityClass {
                case .sitting, .sittingDesk: return "seated"
                case .standing: return "upright"
                case .fidgeting: return k.posture?.rawValue
                case .lyingDown, .sleeping: return "lying"
                default: return nil
                }
            }
            var conflicts = 0, lyingDiffs = 0, hedges = 0, worst = 0.0
            for (a, b) in zip(reference.states, other.states) {
                let ca = claim(ActivityClassifier.classify(state: a)), cb = claim(ActivityClassifier.classify(state: b))
                if let ca, let cb, ca != cb { conflicts += 1 }
                if (ca == "lying") != (cb == "lying") { lyingDiffs += 1 }
                if (ca == nil) != (cb == nil) { hedges += 1 }
                for p in [PostureClass.seatedLikely, .uprightStationary, .recumbent] {
                    worst = max(worst, abs(a.posture[p] - b.posture[p]))
                }
            }
            XCTAssertEqual(conflicts, 0, "hr \(other.hr): a contradicting posture claim moved with the heart rate")
            XCTAssertEqual(lyingDiffs, 0, "hr \(other.hr): the heart rate made or unmade a lying claim")
            XCTAssertLessThanOrEqual(hedges, 2, "hr \(other.hr): commits / hedges differ in \(hedges) states")
            XCTAssertLessThan(worst, 0.05, "hr \(other.hr): the posture split moved with the heart rate")
            let kinds = { (states: [ActivityContextState]) in
                states.flatMap { $0.history.recentEvents }.map { "\($0.kind)@\($0.ts)" }
            }
            XCTAssertEqual(Set(kinds(other.states)), Set(kinds(reference.states)),
                           "hr \(other.hr): the events (kind and time) moved with the heart rate")
        }
    }

    func testTheStationaryModesShareOneHeartRateLevel() {
        let table = ActivityContextModel.profiles
        let levels = Set([BodyMode.bedRest, .seated, .upright].map { table[$0.rawValue].hrRel })
        XCTAssertEqual(levels, [ActivityContextModel.stationaryHrRel])
        // ... and the HR channel still tells resting from working.
        for mode in [BodyMode.walk, .briskWalk, .run, .otherExercise] {
            XCTAssertGreaterThan(table[mode.rawValue].hrRel, ActivityContextModel.stationaryHrRel + 0.2, "\(mode)")
        }
    }

    func testAPersonalProfileCannotReintroduceAPerPostureHeartRate() {
        // A profile stored by an older fitter with per-posture levels: decoded, kept (its tag is unchanged), but
        // never applied to a stationary mode. A walking level still applies.
        let profile = ActivityPersonalProfile(fittedAt: 0, sessionIds: [], modes: [
            "bedRest": ActivityPersonalModeAdjustment(seconds: 300, hrRel: -0.1),
            "seated": ActivityPersonalModeAdjustment(seconds: 300, hrRel: 0.0),
            "upright": ActivityPersonalModeAdjustment(seconds: 300, hrRel: 0.25),
            "walk": ActivityPersonalModeAdjustment(seconds: 300, hrRel: 0.42),
        ])
        let table = ActivityContextModel.profiles(for: profile)
        for mode in [BodyMode.bedRest, .seated, .upright] {
            XCTAssertEqual(table[mode.rawValue].hrRel, ActivityContextModel.stationaryHrRel, "\(mode)")
        }
        XCTAssertEqual(table[BodyMode.walk.rawValue].hrRel, 0.42)

        var config = ActivityDecoderConfig()
        config.personalProfile = profile
        assertPostureIgnoresHeartRate(decode(still(hr: 60), config: config), decode(still(hr: 80), config: config))
    }
}
