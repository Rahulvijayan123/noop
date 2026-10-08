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
