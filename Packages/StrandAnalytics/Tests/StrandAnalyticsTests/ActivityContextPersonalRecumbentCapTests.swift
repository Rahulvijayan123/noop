import XCTest
@testable import StrandAnalytics

/// A wearer whose adopted profile carries their own lying-forearm row may let the held orientation hedge further
/// toward recumbent (`ActivityContextModel.recumbentOrientationCapPersonal`, ln 6 against the population ln 2.5),
/// but the wrist alone must still never claim lying: that keeps needing the night, the in-bed window or a
/// lie-down's direction.
final class ActivityContextPersonalRecumbentCapTests: XCTestCase {

    /// This wearer lies with the forearm flat and sits / stands with it inclined or hanging: the strongest
    /// recumbent likelihood ratio a fitted row can carry for a flat forearm.
    private let lyingRowProfile = ActivityPersonalProfile(fittedAt: 0, sessionIds: [], modes: [
        "bedRest": ActivityPersonalModeAdjustment(seconds: 600, orientation: [0.01, 0.97, 0.01, 0.01],
                                                  orientationUnsigned: [0, 0.97, 0.01, 0.02]),
        "seated": ActivityPersonalModeAdjustment(seconds: 600, orientation: [0.01, 0.01, 0.90, 0.08],
                                                 orientationUnsigned: [0, 0.01, 0.90, 0.09]),
        "upright": ActivityPersonalModeAdjustment(seconds: 600, orientation: [0.01, 0.01, 0.18, 0.80],
                                                  orientationUnsigned: [0, 0.01, 0.18, 0.81]),
    ])

    private let index = ActivityContextModel.PostureEvidence.recumbentOrientationIndex

    func testTheCapRisesOnlyWithAFittedLyingRow() {
        XCTAssertEqual(ActivityContextDecoder(config: ActivityDecoderConfig()).postureEvidenceCaps[index], log(2.5),
                       accuracy: 1e-12, "population cap")
        var personal = ActivityDecoderConfig()
        personal.personalProfile = lyingRowProfile
        XCTAssertEqual(ActivityContextDecoder(config: personal).postureEvidenceCaps[index],
                       ActivityContextModel.recumbentOrientationCapPersonal, accuracy: 1e-12)
        // A profile that adapts lying without an orientation row (a profile fit before the rows existed, or one
        // whose lying seconds were too few for a row) keeps the population cap.
        var noRow = ActivityDecoderConfig()
        noRow.personalProfile = ActivityPersonalProfile(fittedAt: 0, sessionIds: [], modes: [
            "bedRest": ActivityPersonalModeAdjustment(seconds: 600, move: ActivityPersonalRange(lo: 0.0, hi: 0.2)),
        ])
        XCTAssertEqual(ActivityContextDecoder(config: noRow).postureEvidenceCaps[index], log(2.5), accuracy: 1e-12)
        // The other sources' caps are the population's either way.
        let population = ActivityContextModel.PostureEvidence.caps
        for (i, cap) in ActivityContextDecoder(config: personal).postureEvidenceCaps.enumerated() where i != index {
            XCTAssertEqual(cap, population[i], "\(i)")
        }
    }

    /// Thirty minutes awake, quiet, the forearm flat, outside any in-bed window: the wearer's own lying posture as
    /// far as the wrist can see, with nothing else to say it is lying.
    private func awakeFlatStillness(signCalibrated: Bool) -> [ActivityObservation] {
        var sim = ActivitySim(seed: 41)
        var opt = ActivitySim.Options()
        opt.sleep = .awake
        if signCalibrated {
            // A walk calibrates the forearm sign (so the signed rows are read), then a stop without a lie-down.
            sim.forearm(0.9)
            sim.walk(240, opt: opt)
            sim.still(10, opt: opt)
        }
        sim.forearm(0.0)
        sim.still(1800, dyn: 0.006, opt: opt)
        return sim.observations
    }

    func testTheWearersLyingRowNeverProducesALyingClaimFromTheWristAlone() {
        var personal = ActivityDecoderConfig()
        personal.personalProfile = lyingRowProfile
        for signed in [false, true] {
            let track = ActivityContextTrackBuilder.decode(awakeFlatStillness(signCalibrated: signed), config: personal)
            let still = track.states.suffix(1800 / max(1, personal.publishIntervalS))
            XCTAssertFalse(still.isEmpty)
            var maxRecumbent = 0.0
            for s in still {
                maxRecumbent = max(maxRecumbent, s.posture[.recumbent])
                let k = ActivityClassifier.classify(state: s)
                XCTAssertFalse([.lyingDown, .sleeping].contains(k.activityClass), "signed \(signed) at \(s.ts)")
                XCTAssertNotEqual(s.displayContext, "Lying down", "signed \(signed) at \(s.ts)")
            }
            XCTAssertLessThan(maxRecumbent, 0.5, "signed \(signed)")
            for r in ActivityContextRuns.coalesce(Array(still)) {
                XCTAssertFalse([.lyingDown, .sleeping].contains(ActivityClassifier.classify(run: r).activityClass))
            }
        }
    }
}
