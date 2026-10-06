import XCTest
@testable import StrandAnalytics

/// Tests for `WearSignalQualityEngine` (spec `feat/wear-signal-quality`, V1).
///
/// These tests assert the SPEC-CORRECT ladder behavior of the current source:
/// - Motion artifact: Schmitt enter after `artifactEnterEpochs` consecutive degraded high-motion
///   epochs (pending/unknown before entry), symmetric Schmitt exit over `artifactExitEpochs`
///   consecutive optically-clean epochs (exit_pending before exit; re-degradation resets the
///   clean run and stays motion_artifact/active).
/// - Loose: the sliding window appends every gradable low-motion epoch and fires `on_wrist_loose`
///   only over a FULL window with degraded-fraction >= 0.6, pulse present, and this epoch
///   degraded. Artifact/dropout epochs return before L9 — that early return IS the pause-not-reset.
final class WearSignalQualityTests: XCTestCase {

    // MARK: - Helpers

    /// Thread one 30-s epoch through the engine.
    private func classify(_ e: WearSignalEvidence, state: inout WearSignalTemporalState,
                          at epoch: Int) -> WearSignalQualityResult {
        WearSignalQualityEngine.classify(e, state: &state, epochStart: epoch * 30)
    }

    /// Otherwise-perfect worn evidence, quiet low-motion.
    private func goodQuiet(sqi: Double = 0.8) -> WearSignalEvidence {
        WearSignalEvidence(hrPresent: true, imuQuiet: true, tempSkinLike: true,
                           waveformCoverageAdequate: true, ppgSqi: sqi)
    }

    /// Degraded optical on a worn, quiet strap (bad PPG window / flicker).
    private func degradedQuiet(sqi: Double = 0.3) -> WearSignalEvidence {
        WearSignalEvidence(hrPresent: true, pulseDegraded: true, imuQuiet: true, tempSkinLike: true,
                           waveformCoverageAdequate: true, ppgSqi: sqi)
    }

    /// Degraded optical under high motion on a worn strap.
    private func degradedHighMotion(sqi: Double = 0.2) -> WearSignalEvidence {
        WearSignalEvidence(hrPresent: true, strapFlagsBad: true, imuHighMotion: true, tempSkinLike: true,
                           waveformCoverageAdequate: true, ppgSqi: sqi)
    }

    // MARK: - L1 explicit hardware evidence

    func testLiveWristOffFreshDominatesPerfectWornEvidence() {
        var state = WearSignalTemporalState()
        let r = classify(WearSignalEvidence(liveWristOffFresh: true, hrPresent: true, imuQuiet: true,
                                            tempSkinLike: true, waveformCoverageAdequate: true, ppgSqi: 0.9),
                         state: &state, at: 0)
        XCTAssertEqual(r.state, .offWrist)
        XCTAssertEqual(r.reasons, ["explicit_wrist_off"])
        XCTAssertEqual(r.confidence, 1.0)
        XCTAssertEqual(r.coarseWear, .offWrist)
    }

    func testTempSkinLikeCannotOverrideExplicitOff() {
        var state = WearSignalTemporalState()
        let r = classify(WearSignalEvidence(liveWristOffFresh: true, hrPresent: true, tempSkinLike: true,
                                            ppgSqi: 0.9),
                         state: &state, at: 0)
        XCTAssertEqual(r.state, .offWrist)
        XCTAssertEqual(r.reasons, ["explicit_wrist_off"])
    }

    // MARK: - Grace after fresh WRIST_ON

    func testFreshWristOnGoodEpochsGraceThenSteadyGood() {
        var state = WearSignalTemporalState()
        let freshOn = WearSignalEvidence(liveWristOnFresh: true, hrPresent: true, imuQuiet: true,
                                         tempSkinLike: true, waveformCoverageAdequate: true, ppgSqi: 0.8)
        // Fresh ON epoch + two following epochs sit inside grace (3 grace epochs total).
        let r0 = classify(freshOn, state: &state, at: 0)
        XCTAssertEqual(r0.state, .onWristGood)
        XCTAssertEqual(r0.reasons, ["good", "grace_active"])
        XCTAssertEqual(r0.confidence, 0.7)
        let r1 = classify(goodQuiet(), state: &state, at: 1)
        XCTAssertEqual(r1.state, .onWristGood)
        XCTAssertEqual(r1.reasons, ["good", "grace_active"])
        let r2 = classify(goodQuiet(), state: &state, at: 2)
        XCTAssertEqual(r2.state, .onWristGood)
        XCTAssertEqual(r2.reasons, ["good", "grace_active"])
        // Grace exhausted at epoch 3: plain good, no grace reason.
        let r3 = classify(goodQuiet(), state: &state, at: 3)
        XCTAssertEqual(r3.state, .onWristGood)
        XCTAssertEqual(r3.reasons, ["good"])
        XCTAssertEqual(r3.confidence, 0.8)
        XCTAssertEqual(state.graceEpochsRemaining, 0)
    }

    func testGraceBlocksLooseAndArtifactAfterFreshOn() {
        var state = WearSignalTemporalState()
        let freshOnDegraded = WearSignalEvidence(liveWristOnFresh: true, hrPresent: true, strapFlagsBad: true,
                                                 imuHighMotion: true, tempSkinLike: true,
                                                 waveformCoverageAdequate: true, ppgSqi: 0.2)
        let degraded = degradedHighMotion()
        // Epoch 0 (fresh ON) through epoch 2 sit inside grace: degraded high-motion must NOT be
        // loose or artifact (grace_active). Epochs 1..2 no longer re-arm grace (fresh ON is one-shot).
        let r0 = classify(freshOnDegraded, state: &state, at: 0)
        XCTAssertEqual(r0.state, .unknown)
        XCTAssertEqual(r0.reasons, ["grace_active"])
        for epoch in 1..<3 {
            let r = classify(degraded, state: &state, at: epoch)
            XCTAssertEqual(r.state, .unknown, "epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["grace_active"])
            XCTAssertNotEqual(r.state, .onWristLoose)
            XCTAssertNotEqual(r.state, .motionArtifact)
        }
        // Grace exhausted at epoch 3: degraded high-motion is artifact-pending (run 1 < enter 2).
        let r3 = classify(degraded, state: &state, at: 3)
        XCTAssertEqual(r3.state, .unknown)
        XCTAssertEqual(r3.reasons, ["motion_artifact_pending", "high_motion_optical_degraded"])
    }

    // MARK: - IMU / dropout / unknown abstention

    func testQuietImuAloneIsUnknownNotOnWrist() {
        var state = WearSignalTemporalState()
        let r = classify(WearSignalEvidence(imuQuiet: true), state: &state, at: 0)
        XCTAssertEqual(r.state, .unknown)
        XCTAssertEqual(r.reasons, ["not_worn_compatible"])
        XCTAssertEqual(r.coarseWear, .unknown)
    }

    func testHrAbsentWithoutCorroborationIsUnknownNotOff() {
        var state = WearSignalTemporalState()
        let r = classify(WearSignalEvidence(hrPresent: false), state: &state, at: 0)
        XCTAssertEqual(r.state, .unknown)
        XCTAssertEqual(r.reasons, ["hr_gap_uncorroborated"])
        XCTAssertNotEqual(r.state, .offWrist)
        XCTAssertEqual(r.coarseWear, .unknown)
    }

    func testStreamsAbsentWithHighMotionIsSensorDropoutNotOff() {
        var state = WearSignalTemporalState()
        let r = classify(WearSignalEvidence(imuHighMotion: true, streamsExpectedButAbsent: true),
                         state: &state, at: 0)
        XCTAssertEqual(r.state, .sensorDropout)
        XCTAssertEqual(r.reasons, ["hr_gap_worn_dropout"])
        XCTAssertEqual(r.confidence, 0.7)
        XCTAssertNotEqual(r.state, .offWrist)
        XCTAssertEqual(r.coarseWear, .unknown)
    }

    func testAllNilEvidenceIsUnknown() {
        var state = WearSignalTemporalState()
        let r = classify(WearSignalEvidence(), state: &state, at: 0)
        XCTAssertEqual(r.state, .unknown)
        XCTAssertEqual(r.reasons, ["not_worn_compatible"])
        XCTAssertEqual(r.coarseWear, .unknown)
    }

    // MARK: - Motion artifact Schmitt enter

    func testMotionArtifactEntersAfterEnterEpochs() {
        var state = WearSignalTemporalState()
        // First degraded high-motion epoch: pending/unknown (Schmitt run 1 < enter 2).
        let e0 = classify(degradedHighMotion(), state: &state, at: 0)
        XCTAssertEqual(e0.state, .unknown)
        XCTAssertEqual(e0.reasons, ["motion_artifact_pending", "high_motion_optical_degraded"])
        XCTAssertEqual(state.artifactDegradedRun, 1)
        XCTAssertFalse(state.artifactActive)
        // Second consecutive degraded high-motion epoch: enters motionArtifact.
        let e1 = classify(degradedHighMotion(), state: &state, at: 1)
        XCTAssertEqual(e1.state, .motionArtifact)
        XCTAssertEqual(e1.reasons, ["motion_artifact_entered"])
        XCTAssertEqual(state.artifactDegradedRun, 2)
        XCTAssertTrue(state.artifactActive)
        // Further degraded high-motion epochs: stays motionArtifact (active).
        for epoch in 2..<5 {
            let r = classify(degradedHighMotion(), state: &state, at: epoch)
            XCTAssertEqual(r.state, .motionArtifact, "epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["motion_artifact_active"])
        }
        XCTAssertTrue(state.artifactActive)

        // A good high-motion epoch between two degraded ones resets the Schmitt run.
        var state2 = WearSignalTemporalState()
        let pending = classify(degradedHighMotion(), state: &state2, at: 0)
        XCTAssertEqual(pending.state, .unknown)
        XCTAssertEqual(state2.artifactDegradedRun, 1)
        let good = WearSignalEvidence(hrPresent: true, imuHighMotion: true, tempSkinLike: true,
                                      waveformCoverageAdequate: true, ppgSqi: 0.9)
        let goodResult = classify(good, state: &state2, at: 1)
        XCTAssertEqual(goodResult.state, .onWristGood)
        XCTAssertEqual(goodResult.reasons, ["good", "high_motion_optical_ok"])
        XCTAssertEqual(state2.artifactDegradedRun, 0, "high-motion + optical good resets the run")
        let again = classify(degradedHighMotion(), state: &state2, at: 2)
        XCTAssertEqual(again.state, .unknown, "run was reset; a single degraded epoch is not enough")
        XCTAssertEqual(state2.artifactDegradedRun, 1)
    }

    func testHighMotionWithGoodOpticalIsOnWristGoodNeverArtifact() {
        var state = WearSignalTemporalState()
        let e = WearSignalEvidence(hrPresent: true, imuHighMotion: true, tempSkinLike: true,
                                   waveformCoverageAdequate: true, ppgSqi: 0.9)
        for epoch in 0..<6 {
            let r = classify(e, state: &state, at: epoch)
            XCTAssertEqual(r.state, .onWristGood, "epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["good", "high_motion_optical_ok"])
            XCTAssertEqual(r.confidence, 0.8)
            XCTAssertNotEqual(r.state, .motionArtifact)
        }
        XCTAssertFalse(state.artifactActive)
        XCTAssertEqual(state.artifactDegradedRun, 0)
    }

    // MARK: - Motion artifact Schmitt exit

    func testSchmittExitRequiresCleanRunAndRedegradeResets() {
        var state = WearSignalTemporalState()
        // Enter artifact: pending on the first degraded high-motion epoch, entered on the second.
        let e0 = classify(degradedHighMotion(), state: &state, at: 0)
        XCTAssertEqual(e0.state, .unknown)
        XCTAssertEqual(e0.reasons, ["motion_artifact_pending", "high_motion_optical_degraded"])
        let e1 = classify(degradedHighMotion(), state: &state, at: 1)
        XCTAssertEqual(e1.state, .motionArtifact)
        XCTAssertEqual(e1.reasons, ["motion_artifact_entered"])
        XCTAssertTrue(state.artifactActive)
        // Clean epoch 1 while active: stays motionArtifact, exit pending (clean run 1 < exit 2).
        let e2 = classify(goodQuiet(sqi: 0.9), state: &state, at: 2)
        XCTAssertEqual(e2.state, .motionArtifact)
        XCTAssertEqual(e2.reasons, ["motion_artifact_exit_pending"])
        XCTAssertEqual(state.artifactCleanRun, 1)
        // Re-degraded before exit: stays motionArtifact (active), resets the clean run.
        let e3 = classify(degradedHighMotion(), state: &state, at: 3)
        XCTAssertEqual(e3.state, .motionArtifact)
        XCTAssertEqual(e3.reasons, ["motion_artifact_active"])
        XCTAssertEqual(state.artifactCleanRun, 0)
        // Clean epoch 1 again: exit pending (clean run restarted from 0).
        let e4 = classify(goodQuiet(sqi: 0.9), state: &state, at: 4)
        XCTAssertEqual(e4.state, .motionArtifact)
        XCTAssertEqual(e4.reasons, ["motion_artifact_exit_pending"])
        // Clean epoch 2: exits artifact; this epoch grades normally as onWristGood.
        let e5 = classify(goodQuiet(sqi: 0.9), state: &state, at: 5)
        XCTAssertEqual(e5.state, .onWristGood)
        XCTAssertEqual(e5.reasons, ["good"])
        XCTAssertFalse(state.artifactActive)
        XCTAssertEqual(state.artifactCleanRun, 0)
        XCTAssertEqual(state.artifactDegradedRun, 0)
    }

    // MARK: - Loose ladder

    func testSingleDegradedLowMotionEpochIsNotLoose() {
        var state = WearSignalTemporalState()
        let r = classify(degradedQuiet(sqi: 0.3), state: &state, at: 0)
        XCTAssertNotEqual(r.state, .onWristLoose)
        XCTAssertEqual(r.state, .unknown)
        XCTAssertEqual(r.reasons, ["insufficient_evidence"])
    }

    func testLooseWindowFullFractionFiresLoose() {
        // 6 all-degraded low-motion epochs: window fills by the 6th; fraction 1.0 >= 0.6 -> loose.
        var state = WearSignalTemporalState()
        for epoch in 0..<5 {
            let r = classify(degradedQuiet(sqi: 0.3), state: &state, at: epoch)
            XCTAssertNotEqual(r.state, .onWristLoose, "epoch \(epoch)")
            XCTAssertEqual(r.state, .unknown)
        }
        let r5 = classify(degradedQuiet(sqi: 0.3), state: &state, at: 5)
        XCTAssertEqual(r5.state, .onWristLoose)
        XCTAssertEqual(r5.reasons, ["loose_fraction_met"])
        XCTAssertEqual(r5.coarseWear, .onWrist)
        XCTAssertEqual(state.looseWindow, Array(repeating: true, count: 6))

        // 4-of-6 degraded (6th epoch degraded): fraction 4/6 = 0.667 >= 0.6 -> fires on the 6th.
        var state2 = WearSignalTemporalState()
        let clean = goodQuiet(sqi: 0.8)
        let pattern4of6: [WearSignalEvidence] = [degradedQuiet(), clean, degradedQuiet(), degradedQuiet(), clean, degradedQuiet()]
        var firedAt: Int? = nil
        for (i, e) in pattern4of6.enumerated() {
            if classify(e, state: &state2, at: i).state == .onWristLoose { firedAt = i }
        }
        XCTAssertEqual(firedAt, 5)
        XCTAssertEqual(state2.looseWindow, [true, false, true, true, false, true])

        // 3-of-6 degraded (6th epoch degraded): fraction 0.5 < 0.6 -> never fires.
        var state3 = WearSignalTemporalState()
        let pattern3of6: [WearSignalEvidence] = [degradedQuiet(), clean, degradedQuiet(), clean, clean, degradedQuiet()]
        var fired = false
        for (i, e) in pattern3of6.enumerated() {
            if classify(e, state: &state3, at: i).state == .onWristLoose { fired = true }
        }
        XCTAssertFalse(fired)
        XCTAssertEqual(state3.looseWindow, [true, false, true, false, false, true])
    }

    func testPauseNotResetWindowRetainsPredropoutDegraded() {
        var state = WearSignalTemporalState()
        let dropout = WearSignalEvidence(imuHighMotion: true, streamsExpectedButAbsent: true)
        // Epoch 0: degraded low-motion -> window gains the flag.
        let r0 = classify(degradedQuiet(sqi: 0.3), state: &state, at: 0)
        XCTAssertEqual(r0.state, .unknown)
        XCTAssertEqual(state.looseWindow, [true])
        // Epoch 1: dropout -> sensorDropout; the loose window is NOT appended (pause, not reset).
        let r1 = classify(dropout, state: &state, at: 1)
        XCTAssertEqual(r1.state, .sensorDropout)
        XCTAssertEqual(r1.reasons, ["hr_gap_worn_dropout"])
        XCTAssertEqual(state.looseWindow, [true], "dropout epoch must not touch the loose window")
        // Epochs 2..5: degraded low-motion grows the window; not yet full.
        for epoch in 2..<6 {
            let r = classify(degradedQuiet(sqi: 0.3), state: &state, at: epoch)
            XCTAssertNotEqual(r.state, .onWristLoose, "epoch \(epoch)")
        }
        // Epoch 6: window = pre-dropout flag + 5 post-dropout flags = 6, fraction 1.0 -> loose.
        let r6 = classify(degradedQuiet(sqi: 0.3), state: &state, at: 6)
        XCTAssertEqual(r6.state, .onWristLoose)
        XCTAssertEqual(r6.reasons, ["loose_fraction_met"])
        XCTAssertEqual(state.looseWindow, Array(repeating: true, count: 6))
    }

    // MARK: - Durable off / interval closure

    func testDurableOffClosedByFreshWristOn() {
        var state = WearSignalTemporalState()
        // Stale hours-old OFF: durable off interval active, no fresh ON -> offWrist.
        let r0 = classify(WearSignalEvidence(durableOffActive: true), state: &state, at: 0)
        XCTAssertEqual(r0.state, .offWrist)
        XCTAssertEqual(r0.reasons, ["durable_off_active"])
        XCTAssertEqual(r0.confidence, 0.95)
        // Fresh WRIST_ON on top of the stale interval: fresh wins, interval closes, NOT offWrist.
        let r1 = classify(WearSignalEvidence(liveWristOnFresh: true, durableOffActive: true),
                          state: &state, at: 1)
        XCTAssertNotEqual(r1.state, .offWrist)
        XCTAssertEqual(r1.state, .unknown)
        XCTAssertEqual(r1.reasons, ["grace_active"])
        XCTAssertTrue(state.durableOffClosed)
        // Later epochs in the same (now closed) interval grade normally.
        let r2 = classify(WearSignalEvidence(durableOffActive: true, hrPresent: true, imuQuiet: true,
                                             tempSkinLike: true, waveformCoverageAdequate: true, ppgSqi: 0.8),
                          state: &state, at: 2)
        XCTAssertEqual(r2.state, .onWristGood)
        XCTAssertEqual(r2.reasons, ["good", "grace_active"])
    }

    /// A closure belongs to the interval it closed: a later durable-off interval in the same stream
    /// is off-wrist again once the stream has left the first one.
    func testLaterDurableOffIntervalIsOffAfterAnEarlierOneClosed() {
        var state = WearSignalTemporalState()
        _ = classify(WearSignalEvidence(liveWristOnFresh: true, durableOffActive: true), state: &state, at: 0)
        XCTAssertTrue(state.durableOffClosed)
        _ = classify(WearSignalEvidence(durableOffActive: false, hrPresent: true), state: &state, at: 1)
        XCTAssertFalse(state.durableOffClosed)
        let later = classify(WearSignalEvidence(durableOffActive: true), state: &state, at: 2)
        XCTAssertEqual(later.state, .offWrist)
        XCTAssertEqual(later.reasons, ["durable_off_active"])
    }

    // MARK: - Stable states

    func testGoodBadGoodEpochsDoNotFlapPersistently() {
        var state = WearSignalTemporalState()
        let r0 = classify(goodQuiet(), state: &state, at: 0)
        XCTAssertEqual(r0.state, .onWristGood)
        // One bad (degraded optical, low motion) epoch: abstains to unknown, does not mislabel.
        let r1 = classify(degradedQuiet(sqi: 0.2), state: &state, at: 1)
        XCTAssertEqual(r1.state, .unknown)
        XCTAssertEqual(r1.reasons, ["insufficient_evidence"])
        // Next good epoch recovers cleanly to onWristGood (no sticky artifact/loose state).
        let r2 = classify(goodQuiet(), state: &state, at: 2)
        XCTAssertEqual(r2.state, .onWristGood)
        XCTAssertEqual(r2.reasons, ["good"])
    }

    func testSleepLikeEvidenceIsOnWristGoodNeverOff() {
        var state = WearSignalTemporalState()
        let sleepEpoch = WearSignalEvidence(hrPresent: true, imuQuiet: true, tempSkinLike: true,
                                            waveformCoverageAdequate: true, ppgSqi: 0.8)
        for epoch in 0..<6 {
            let r = classify(sleepEpoch, state: &state, at: epoch)
            XCTAssertEqual(r.state, .onWristGood, "epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["good"])
            XCTAssertNotEqual(r.state, .offWrist)
        }
    }

    func testStableThroughActivityTransitions() {
        var state = WearSignalTemporalState()
        let active = WearSignalEvidence(hrPresent: true, imuHighMotion: true, tempSkinLike: true,
                                        waveformCoverageAdequate: true, ppgSqi: 0.9)
        let results = [classify(goodQuiet(), state: &state, at: 0),
                       classify(goodQuiet(), state: &state, at: 1),
                       classify(active, state: &state, at: 2),
                       classify(active, state: &state, at: 3),
                       classify(goodQuiet(), state: &state, at: 4),
                       classify(goodQuiet(), state: &state, at: 5)]
        for (i, r) in results.enumerated() {
            XCTAssertEqual(r.state, .onWristGood, "epoch \(i)")
        }
        XCTAssertEqual(results[2].reasons, ["good", "high_motion_optical_ok"])
    }

    func testSqiNilWithBadStrapFlagsIsNotOnWristGood() {
        var state = WearSignalTemporalState()
        let e = WearSignalEvidence(hrPresent: true, strapFlagsBad: true, tempSkinLike: true)
        // Single epoch: bad strap flags (sqi missing) are not onWristGood -> unknown.
        let r = classify(e, state: &state, at: 0)
        XCTAssertNotEqual(r.state, .onWristGood)
        XCTAssertEqual(r.state, .unknown)
        XCTAssertEqual(r.reasons, ["insufficient_evidence"])
        // Sustained bad strap flags with a pulse present: after a full 6-epoch window -> loose.
        for epoch in 1..<5 {
            let rn = classify(e, state: &state, at: epoch)
            XCTAssertNotEqual(rn.state, .onWristLoose, "epoch \(epoch)")
        }
        let r5 = classify(e, state: &state, at: 5)
        XCTAssertEqual(r5.state, .onWristLoose)
        XCTAssertEqual(r5.reasons, ["loose_fraction_met"])
    }

    // MARK: - Coarse fold

    func testCoarseWearMappingForAllSixStates() {
        XCTAssertEqual(WearSignalState.onWristGood.coarseWear, .onWrist)
        XCTAssertEqual(WearSignalState.onWristLoose.coarseWear, .onWrist)
        XCTAssertEqual(WearSignalState.motionArtifact.coarseWear, .onWrist)
        XCTAssertEqual(WearSignalState.offWrist.coarseWear, .offWrist)
        XCTAssertEqual(WearSignalState.sensorDropout.coarseWear, .unknown)
        XCTAssertEqual(WearSignalState.unknown.coarseWear, .unknown)
    }
}
