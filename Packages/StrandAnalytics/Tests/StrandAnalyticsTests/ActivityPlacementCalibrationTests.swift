import XCTest
@testable import StrandAnalytics

/// hsmm-2.0: calibration is per placement. A profile (and heart-rate model) fitted on one placement shapes only the
/// seconds worn there, so switching placement switches calibration.
final class ActivityPlacementCalibrationTests: XCTestCase {

    /// A profile that changes what the decoder says (the wearer's busy stand, as in ActivityPersonalProfileTests).
    private func profile() -> ActivityPersonalProfile {
        let runs = ActivityPersonalProfileTests.runs(ActivityPersonalProfileTests.Wearer(), count: 3)
        let base = ActivityPersonalProfileTests.noDurationPrior
        let samples = runs.flatMap { ActivityPersonalProfileFitter.replay($0, config: base).samples }
        return ActivityPersonalProfile(fittedAt: 0, sessionIds: runs.map(\.sessionId),
                                       modes: ActivityPersonalProfileFitter.fitModes(samples))
    }

    private func config(_ placement: ActivityWearPlacement) -> ActivityDecoderConfig {
        var c = ActivityDecoderConfig()
        c.stillDurationPrior = false
        c.placements = [ActivityPlacementSpan(start: 0, end: nil, placement: placement)]
        return c
    }

    private var stream: [ActivityObservation] {
        ActivityPersonalProfileTests.run(ActivityPersonalProfileTests.Wearer(), session: "fresh", seed: 99,
                                         start: 1_761_000_000).observations
    }

    func testABicepProfileShapesBicepSecondsOnly() {
        let p = profile()
        XCTAssertFalse(p.modes.isEmpty)
        // Worn on the bicep: the bicep profile applies exactly as a single profile would.
        var keyed = config(.bicep); keyed.placementProfiles = ["bicep": p]
        var single = config(.bicep); single.personalProfile = p
        let plain = config(.bicep)
        let a = ActivityContextTrackBuilder.decode(stream, config: keyed).states
        XCTAssertEqual(a, ActivityContextTrackBuilder.decode(stream, config: single).states)
        XCTAssertNotEqual(a, ActivityContextTrackBuilder.decode(stream, config: plain).states, "the profile matters")
        // Worn on the wrist: the bicep's profile is not used.
        var wristKeyed = config(.wrist); wristKeyed.placementProfiles = ["bicep": p]
        XCTAssertEqual(ActivityContextTrackBuilder.decode(stream, config: wristKeyed).states,
                       ActivityContextTrackBuilder.decode(stream, config: config(.wrist)).states)
    }

    func testSwitchingPlacementMidStreamSwitchesCalibration() {
        let p = profile()
        let obs = stream
        let mid = obs[obs.count / 2].ts
        var c = ActivityDecoderConfig()
        c.stillDurationPrior = false
        c.placements = [ActivityPlacementSpan(start: 0, end: mid, placement: .wrist),
                        ActivityPlacementSpan(start: mid, end: nil, placement: .bicep)]
        c.placementProfiles = ["wrist": p]
        var noProfile = c; noProfile.placementProfiles = nil
        let with = ActivityContextTrackBuilder.decode(obs, config: c).states
        let without = ActivityContextTrackBuilder.decode(obs, config: noProfile).states
        // Before the switch the wrist profile shapes the decode; long after it (beliefs re-converged) it does not.
        let early = zip(with, without).filter { $0.0.ts < mid }
        XCTAssertTrue(early.contains { $0.0 != $0.1 }, "the wrist profile applies while worn on the wrist")
        XCTAssertNotEqual(c.cacheTag, noProfile.cacheTag)
        XCTAssertEqual(c.personalProfile(forCalibration: "bicep"), nil)
        XCTAssertEqual(c.personalProfile(forCalibration: "wrist"), p)
    }

    func testUndeclaredPlacementUsesTheWristCalibration() {
        XCTAssertEqual(ActivityWearPlacement.unknown.calibrationKey, "wrist")
        XCTAssertEqual(ActivityWearPlacement.wrist.calibrationKey, "wrist")
        XCTAssertEqual(ActivityWearPlacement.bicep.calibrationKey, "bicep")
        let hr = ActivityPostureHeartRateModel(seatedOffsetBpm: 5, uprightOffsetBpm: 15, sdBpm: 4, seatedSeconds: 300,
                                               uprightSeconds: 300, runs: 2, heldOutAUC: 0.9)
        var c = ActivityDecoderConfig()
        c.placementPostureHeartRate = ["bicep": hr]
        XCTAssertEqual(c.postureHeartRate(forCalibration: "bicep"), hr)
        XCTAssertNil(c.postureHeartRate(forCalibration: "wrist"))
        XCTAssertTrue(c.cacheTag.contains("-phb"))
    }
}
