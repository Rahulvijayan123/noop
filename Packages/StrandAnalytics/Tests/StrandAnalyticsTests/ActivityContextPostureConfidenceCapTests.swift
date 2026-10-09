import XCTest
@testable import StrandAnalytics

/// D9-08: posterior mass is not a calibrated probability. A sitting / standing claim the wrist alone backs is
/// published at no more than `ActivityClassifier.wristOnlyPostureConfidenceCap`, in states, runs and intervals.
final class ActivityContextPostureConfidenceCapTests: XCTestCase {

    private let cap = ActivityClassifier.wristOnlyPostureConfidenceCap

    /// The strongest wrist-only seated case the simulator has: a walk, a sit-down whose direction the forearm shows,
    /// then desk-like hands with a resting forearm, then a long quiet stretch.
    private func sitDownAtADesk() -> [ActivityObservation] {
        var sim = ActivitySim(seed: 33)
        sim.forearm(0.9)
        sim.walk(90)
        sim.still(8)
        sim.postureShift(netDegrees: 45, toForearm: 0.2)
        sim.desk(900)
        sim.still(900)
        return sim.observations
    }

    func testNoWristOnlyPostureClaimExceedsTheCapInStatesRunsOrIntervals() throws {
        let track = ActivityContextTrackBuilder.decode(sitDownAtADesk(), config: ActivityDecoderConfig())
        let classes = track.states.map(ActivityClassifier.classify(state:))
        let seated = classes.filter { [.sitting, .sittingDesk].contains($0.activityClass) }
        XCTAssertGreaterThan(seated.count, 100, "the scenario does commit sitting")
        // With an agreeing learned source (the softer cap) the heads put more than the wrist-only cap on sitting
        // here (the scenario is meaningful).
        let uncapped = track.states.map { s in
            ActivityClassifier.classify(posture: s.posture, locomotion: s.locomotion, armBehavior: s.armBehavior,
                                        sleep: s.sleep.state, inBed: s.sleep.inBed, wear: s.wear.state,
                                        evidenceQuality: s.overallConfidence, learnedPosture: .seatedLikely)
        }
        XCTAssertGreaterThan(uncapped.map(\.confidence).max() ?? 0, cap + 0.02)

        for k in classes where [.sitting, .sittingDesk, .standing, .fidgeting].contains(k.activityClass) {
            XCTAssertLessThanOrEqual(k.confidence, cap + 1e-12)
        }
        for r in ActivityContextRuns.coalesce(track.states) {
            let k = ActivityClassifier.classify(run: r)
            if [.sitting, .sittingDesk, .standing, .fidgeting].contains(k.activityClass) {
                XCTAssertLessThanOrEqual(k.confidence, cap + 1e-12)
            }
        }
        let intervals = ActivityContextIntervalBuilder.build(runs: ActivityContextRuns.coalesce(track.states))
        XCTAssertTrue(intervals.contains { $0.activityClass == .sitting || $0.activityClass == .sittingDesk })
        for iv in intervals where [.sitting, .sittingDesk, .standing, .fidgeting].contains(iv.activityClass) {
            XCTAssertLessThanOrEqual(iv.confidence, cap + 1e-9)
        }
    }

    func testTheCapLeavesClassesAndLabelsAlone() {
        let track = ActivityContextTrackBuilder.decode(sitDownAtADesk(), config: ActivityDecoderConfig())
        for s in track.states {
            let capped = ActivityClassifier.classify(state: s)
            let free = ActivityClassifier.classify(posture: s.posture, locomotion: s.locomotion, armBehavior: s.armBehavior,
                                                   sleep: s.sleep.state, inBed: s.sleep.inBed, wear: s.wear.state,
                                                   evidenceQuality: s.overallConfidence, learnedPosture: .seatedLikely)
            XCTAssertEqual(capped.activityClass, free.activityClass)
            XCTAssertEqual(capped.posture, free.posture)
            XCTAssertLessThanOrEqual(capped.confidence, free.confidence + 1e-12)
        }
    }
}
