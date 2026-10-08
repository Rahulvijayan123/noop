import XCTest
@testable import StrandAnalytics

/// The fitter's wrong-claim guard holds per validated class, not only pooled (personal-profile-3): a profile must
/// not buy one mode's recall by mis-claiming another mode's seconds, however small that mode's share is.
final class ActivityPersonalProfileClassGuardTests: XCTestCase {

    private typealias Fitter = ActivityPersonalProfileFitter

    private static let features = ActivityFeatures(
        ts: 0, m4: 0.05, m10: 0.05, m30: 0.05, mMed30: 0.05, mBurst10: 0.06, cv30: 0.5,
        gaitPresence: 0, cadenceSpm: nil, runShare6: nil, rhythm: nil, orientPath10: 0.2,
        net5: 1, net30: 1, shiftNet: nil, hr: nil, hrRel: nil, hrSlope: nil,
        wear: .onWrist, sleep: .awake, loggedWorkout: false, workoutKind: .other,
        encoder: nil, encoderAgeS: 0,
        evidence: ActivityEvidenceSummary(imu: false, encoder: false, dynAccel: true, gravity: true, steps: true,
                                          heartRate: false, sleep: true, coverage: 1),
        windowFill: 10)

    /// `n` labelled seconds of `truth`, published as `predicted`.
    private func seconds(_ n: Int, _ truth: BodyMode, as predicted: BodyMode) -> [Fitter.Sample] {
        Array(repeating: Fitter.Sample(truth: truth, predicted: predicted, features: Self.features), count: n)
    }

    private func replay(_ parts: [[Fitter.Sample]]) -> [Fitter.Replay] {
        [Fitter.Replay(samples: parts.flatMap { $0 }, transitions: 0, transitionHits: 0)]
    }

    func testAMinorityClassWhollyMisClaimedIsRefusedThoughThePooledGuardPasses() throws {
        // 1200 s of sitting, 30 s of standing. The profile resolves sitting (half of it was hedged before) and
        // calls every standing second sitting: 2.4 pp of the pooled seconds, inside the pooled 3 pp guard.
        let baseline = replay([seconds(600, .seated, as: .seated), seconds(600, .seated, as: .unknown),
                               seconds(30, .upright, as: .unknown)])
        let personal = replay([seconds(1200, .seated, as: .seated), seconds(30, .upright, as: .seated)])
        let v = Fitter.score(baseline: baseline, personal: personal)
        XCTAssertGreaterThan(v.gain, Fitter.minGain, "the profile looks like a win on balanced accuracy")
        XCTAssertLessThanOrEqual(v.wrongClaimRise, Fitter.maxWrongClaimRise, "the pooled guard alone would pass")
        XCTAssertLessThanOrEqual(v.worstRecallDrop, Fitter.maxRecallDrop, "standing recall was already 0")
        let standing = try XCTUnwrap(v.classes["upright"])
        XCTAssertEqual(standing.seconds, 30)
        XCTAssertEqual(standing.baselineWrongClaims, 0)
        XCTAssertEqual(standing.personalWrongClaims, 1)
        XCTAssertEqual(v.worstClassWrongClaimRise, 1, accuracy: 1e-9)
        XCTAssertFalse(Fitter.guardsHold(v), "the minority class's own wrong claims rose from 0 to 100 %")
    }

    func testTheGuardAllowsASmallRiseAndRefusesALargerOne() {
        func validation(misClaimed: Int) -> ActivityPersonalValidation {
            // 400 s standing; the profile mis-claims `misClaimed` of them as sitting while resolving the rest.
            let baseline = replay([seconds(400, .seated, as: .unknown), seconds(400, .upright, as: .unknown)])
            let personal = replay([seconds(400, .seated, as: .seated),
                                   seconds(400 - misClaimed, .upright, as: .upright),
                                   seconds(misClaimed, .upright, as: .seated)])
            return Fitter.score(baseline: baseline, personal: personal)
        }
        let small = validation(misClaimed: 16)   // 4 % of standing, 2 % pooled
        XCTAssertEqual(small.worstClassWrongClaimRise, 0.04, accuracy: 1e-9)
        XCTAssertTrue(Fitter.guardsHold(small))
        let large = validation(misClaimed: 24)   // 6 % of standing, 3 % pooled
        XCTAssertEqual(large.worstClassWrongClaimRise, 0.06, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(large.wrongClaimRise, Fitter.maxWrongClaimRise + 1e-9)
        XCTAssertFalse(Fitter.guardsHold(large))
    }

    /// Conflicting evidence: a profile that lowers one class's wrong claims and raises another's is judged on the
    /// rise alone; the fall does not pay for it.
    func testAFallInOneClassDoesNotPayForARiseInAnother() {
        let baseline = replay([seconds(300, .seated, as: .upright), seconds(300, .seated, as: .seated),
                               seconds(270, .upright, as: .upright), seconds(30, .upright, as: .unknown)])
        let personal = replay([seconds(600, .seated, as: .seated),
                               seconds(270, .upright, as: .upright), seconds(30, .upright, as: .seated)])
        let v = Fitter.score(baseline: baseline, personal: personal)
        XCTAssertEqual(v.worstRecallDrop, 0, "no class lost recall: only the per-class guard can refuse this")
        XCTAssertLessThan(v.personalWrongClaims ?? 1, v.baselineWrongClaims ?? 0, "pooled, wrong claims fell")
        XCTAssertEqual(v.classes["seated"]?.wrongClaimRise, 0)
        XCTAssertEqual(v.classes["upright"]?.wrongClaimRise ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertFalse(Fitter.guardsHold(v))
    }

    /// Insufficient history: a class below `minClassSeconds` has no per-class score (its own share is noise), so
    /// only the pooled guard sees it. Nine wholly mis-claimed seconds in 1209 pass; the same mis-claim at the class
    /// minimum does not.
    func testAClassBelowTheMinimumIsLeftToThePooledGuard() {
        func validation(standing n: Int) -> ActivityPersonalValidation {
            let baseline = replay([seconds(600, .seated, as: .seated), seconds(600, .seated, as: .unknown),
                                   seconds(n, .upright, as: .unknown)])
            let personal = replay([seconds(1200, .seated, as: .seated), seconds(n, .upright, as: .seated)])
            return Fitter.score(baseline: baseline, personal: personal)
        }
        let thin = validation(standing: Fitter.minClassSeconds - 1)
        XCTAssertNil(thin.classes["upright"])
        XCTAssertEqual(thin.worstClassWrongClaimRise, 0)
        XCTAssertTrue(Fitter.guardsHold(thin))
        let enough = validation(standing: Fitter.minClassSeconds)
        XCTAssertNotNil(enough.classes["upright"])
        XCTAssertFalse(Fitter.guardsHold(enough))
    }

    /// Insufficient history for a sibling posture: a profile that adapts a stationary posture is kept only when
    /// lying, sitting and standing were all validated, because narrowing one moves where the others' seconds land
    /// and an unlabelled posture's wrong claims cannot be measured. Walking-only profiles are unaffected.
    func testStationaryAdaptationsNeedEveryStationaryPostureValidated() {
        let baseline = replay([seconds(300, .seated, as: .unknown), seconds(300, .upright, as: .unknown),
                               seconds(Fitter.minClassSeconds - 1, .bedRest, as: .unknown)])
        let personal = replay([seconds(300, .seated, as: .seated), seconds(300, .upright, as: .upright),
                               seconds(Fitter.minClassSeconds - 1, .bedRest, as: .unknown)])
        let v = Fitter.score(baseline: baseline, personal: personal)
        XCTAssertTrue(Fitter.guardsHold(v), "nothing measured got worse")
        XCTAssertNil(v.classes["bedRest"])
        XCTAssertFalse(Fitter.validatesEveryStationaryPosture(v, adapting: ["seated"]))
        XCTAssertFalse(Fitter.validatesEveryStationaryPosture(v, adapting: ["upright", "walk"]))
        XCTAssertTrue(Fitter.validatesEveryStationaryPosture(v, adapting: ["walk", "briskWalk"]))
        let full = Fitter.score(
            baseline: replay([seconds(300, .seated, as: .unknown), seconds(300, .upright, as: .unknown),
                              seconds(60, .bedRest, as: .unknown)]),
            personal: replay([seconds(300, .seated, as: .seated), seconds(300, .upright, as: .upright),
                              seconds(60, .bedRest, as: .unknown)]))
        XCTAssertTrue(Fitter.validatesEveryStationaryPosture(full, adapting: ["seated", "upright"]))
    }

    /// Missing data: a validation stored before per-class scoring decodes, carries no per-class rise, and so is
    /// judged by the guards it was scored under; nothing labelled at all is no rise either.
    func testOlderValidationsAndEmptyRunsDecodeWithoutAPerClassRise() throws {
        let old = """
        {"runs":2,"labelledSeconds":600,"baselineBalancedAccuracy":0.4,"personalBalancedAccuracy":0.6,
         "classes":{"seated":{"seconds":300,"baselineRecall":0.4,"personalRecall":0.8},
                    "upright":{"seconds":300,"baselineRecall":0.4,"personalRecall":0.4}},
         "transitions":0,"baselineTransitionHits":0,"personalTransitionHits":0}
        """
        let v = try JSONDecoder().decode(ActivityPersonalValidation.self, from: Data(old.utf8))
        XCTAssertNil(v.classes["seated"]?.baselineWrongClaims)
        XCTAssertEqual(v.worstClassWrongClaimRise, 0)

        let empty = Fitter.score(baseline: [Fitter.Replay()], personal: [Fitter.Replay()])
        XCTAssertTrue(empty.classes.isEmpty)
        XCTAssertEqual(empty.worstClassWrongClaimRise, 0)
        XCTAssertTrue(Fitter.guardsHold(empty))
    }

    func testTheProfileVersionIsBumpedSoAdoptedProfilesAreRevalidated() {
        // The app's refit fingerprint carries this version (not the decoder's), so the bump is what makes a profile
        // adopted under the pooled-only guard be refit and re-validated under the per-class one.
        XCTAssertEqual(ActivityPersonalProfile.currentVersion, "personal-profile-3")
        XCTAssertEqual(ActivityPersonalProfile(fittedAt: 0, sessionIds: [], modes: [:]).version, "personal-profile-3")
    }
}
