import XCTest
@testable import StrandAnalytics

/// Synthetic multi-epoch TIMELINE replay tests through the REAL `WearSignalQualityEngine`
/// (spec §13.3 cases). Each test replays a fixed sequence of 30-s epochs — the same evidence a
/// live strap-domain caller or an offline/replay caller would thread through the engine — and
/// asserts state, reasons, and coarseWear at every phase.
///
/// The timelines are SYNTHETIC because no real WHOOP capture corpus is in-repo yet: each epoch
/// is a hand-built `WearSignalEvidence` vector for the scenario (removal/re-don, workout motion,
/// desk stillness, sleep, disconnect/reconnect, stale historical events, and the DETACH shadow
/// plumbing). Determinism is the point: the same (evidence, state) pair always yields the same
/// result, so these replays pin the exact ladder behavior for future callers.
final class WearSignalReplayTests: XCTestCase {

    // MARK: - Helpers

    /// Thread one 30-s epoch through the engine on the 30 s UTC grid.
    private func classify(_ e: WearSignalEvidence, state: inout WearSignalTemporalState,
                          at epoch: Int) -> WearSignalQualityResult {
        WearSignalQualityEngine.classify(e, state: &state, epochStart: epoch * 30)
    }

    /// Worn, quiet, good optical (desk / sleep / steady state).
    private func goodQuiet() -> WearSignalEvidence {
        WearSignalEvidence(hrPresent: true, imuQuiet: true, tempSkinLike: true,
                           waveformCoverageAdequate: true, ppgSqi: 0.8)
    }

    /// Worn, high motion, good optical (exercise the engine must keep as good).
    private func goodActive() -> WearSignalEvidence {
        WearSignalEvidence(hrPresent: true, imuHighMotion: true, tempSkinLike: true,
                           waveformCoverageAdequate: true, ppgSqi: 0.9)
    }

    /// Worn, high motion, degraded optical (exercise the engine must artifact).
    private func degradedActive() -> WearSignalEvidence {
        WearSignalEvidence(hrPresent: true, strapFlagsBad: true, imuHighMotion: true,
                           tempSkinLike: true, waveformCoverageAdequate: true, ppgSqi: 0.2)
    }

    /// Worn, quiet, degraded optical (loose-window feedstock).
    private func degradedQuiet() -> WearSignalEvidence {
        WearSignalEvidence(hrPresent: true, pulseDegraded: true, imuQuiet: true, tempSkinLike: true,
                           waveformCoverageAdequate: true, ppgSqi: 0.3)
    }

    /// A telemetry dropout: strap stream expected but absent under motion (NOT off-wrist).
    private func dropout() -> WearSignalEvidence {
        WearSignalEvidence(imuHighMotion: true, streamsExpectedButAbsent: true)
    }

    // MARK: - 13.3.1 Removal and re-don (durable off, fresh ON, steady good)

    func testRemovalAndRedonTimeline() {
        var state = WearSignalTemporalState()
        // Phase 1 — removal: the durable WRIST_OFF interval is active for five epochs.
        for epoch in 0..<5 {
            let r = classify(WearSignalEvidence(durableOffActive: true), state: &state, at: epoch)
            XCTAssertEqual(r.state, .offWrist, "epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["durable_off_active"])
            XCTAssertEqual(r.confidence, 0.95)
            XCTAssertEqual(r.coarseWear, .offWrist)
        }
        // Phase 2 — re-don: fresh WRIST_ON on top of the stale interval closes it; grace starts.
        let on = classify(WearSignalEvidence(liveWristOnFresh: true, durableOffActive: true,
                                             hrPresent: true, imuQuiet: true, tempSkinLike: true,
                                             waveformCoverageAdequate: true, ppgSqi: 0.8),
                          state: &state, at: 5)
        XCTAssertEqual(on.state, .onWristGood)
        XCTAssertEqual(on.reasons, ["good", "grace_active"])
        XCTAssertEqual(on.confidence, 0.7)
        XCTAssertEqual(on.coarseWear, .onWrist)
        XCTAssertTrue(state.durableOffClosed, "the durable-off interval is closed by fresh ON")
        // Phase 3 — steady good: the 3-epoch grace tails off, then plain good.
        let grace2 = classify(goodQuiet(), state: &state, at: 6)
        XCTAssertEqual(grace2.state, .onWristGood)
        XCTAssertEqual(grace2.reasons, ["good", "grace_active"])
        let grace3 = classify(goodQuiet(), state: &state, at: 7)
        XCTAssertEqual(grace3.state, .onWristGood)
        XCTAssertEqual(grace3.reasons, ["good", "grace_active"])
        for epoch in 8..<12 {
            let r = classify(goodQuiet(), state: &state, at: epoch)
            XCTAssertEqual(r.state, .onWristGood, "epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["good"], "grace exhausted at epoch \(epoch)")
            XCTAssertEqual(r.coarseWear, .onWrist)
        }
    }

    // MARK: - 13.3.2 Workout motion (high motion + degraded -> artifact; coarse on_wrist kept)

    func testWorkoutMotionArtifactTimeline() {
        var state = WearSignalTemporalState()
        // Epoch 0 — first degraded high-motion window: Schmitt pending, abstains to unknown.
        let pending = classify(degradedActive(), state: &state, at: 0)
        XCTAssertEqual(pending.state, .unknown)
        XCTAssertEqual(pending.reasons, ["motion_artifact_pending", "high_motion_optical_degraded"])
        XCTAssertEqual(pending.coarseWear, .unknown)
        // Epoch 1 — second consecutive degraded high-motion window: enters motion_artifact.
        let entered = classify(degradedActive(), state: &state, at: 1)
        XCTAssertEqual(entered.state, .motionArtifact)
        XCTAssertEqual(entered.reasons, ["motion_artifact_entered"])
        XCTAssertEqual(entered.coarseWear, .onWrist, "IMU coarse fold keeps on_wrist during artifact")
        // Epochs 2..6 — sustained: motion_artifact stays active, coarse on_wrist preserved.
        for epoch in 2..<7 {
            let r = classify(degradedActive(), state: &state, at: epoch)
            XCTAssertEqual(r.state, .motionArtifact, "epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["motion_artifact_active"])
            XCTAssertEqual(r.coarseWear, .onWrist)
            XCTAssertTrue(state.artifactActive)
        }
        // Workout ends: a good high-motion epoch does NOT exit artifact on its own (exit needs
        // artifactExitEpochs=2 consecutive clean epochs) — it resets the degraded run, not the exit.
        let clean1 = classify(goodActive(), state: &state, at: 7)
        XCTAssertEqual(clean1.state, .motionArtifact)
        XCTAssertEqual(clean1.reasons, ["motion_artifact_exit_pending"])
        let clean2 = classify(goodActive(), state: &state, at: 8)
        XCTAssertEqual(clean2.state, .onWristGood, "two clean epochs complete the Schmitt exit")
        XCTAssertEqual(clean2.reasons, ["good", "high_motion_optical_ok"])
        XCTAssertFalse(state.artifactActive)
    }

    // MARK: - 13.3.3 Desk stillness (quiet + good -> good)

    func testDeskStillnessTimeline() {
        var state = WearSignalTemporalState()
        for epoch in 0..<10 {
            let r = classify(epoch == 5 ? goodActive() : goodQuiet(), state: &state, at: epoch)
            XCTAssertEqual(r.state, .onWristGood, "epoch \(epoch)")
            XCTAssertEqual(r.coarseWear, .onWrist)
            if epoch == 5 {
                XCTAssertEqual(r.reasons, ["good", "high_motion_optical_ok"],
                               "a reaching/typing spike with good optical stays good")
            } else {
                XCTAssertEqual(r.reasons, ["good"])
            }
        }
    }

    // MARK: - 13.3.4 Sleep night (8 h quiet + HR + skin-like temp -> good, never off)

    func testSleepNightEightHoursNeverOff() {
        var state = WearSignalTemporalState()
        // 8 h = 960 x 30 s epochs of still, worn, good-optical sleep evidence.
        for epoch in 0..<960 {
            let r = classify(goodQuiet(), state: &state, at: epoch)
            XCTAssertEqual(r.state, .onWristGood, "sleep epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["good"], "sleep epoch \(epoch)")
            XCTAssertEqual(r.coarseWear, .onWrist)
            XCTAssertNotEqual(r.state, .offWrist, "quiet sleep must never read as off-wrist")
        }
    }

    // MARK: - 13.3.5 Disconnect / reconnect (dropouts interleaved; loose window pause-not-reset)

    func testDisconnectReconnectLooseWindowPauseNotReset() {
        var state = WearSignalTemporalState()
        // Phase 1 — degraded quiet epochs build the loose window: [T,T,T], not yet full.
        for epoch in 0..<3 {
            let r = classify(degradedQuiet(), state: &state, at: epoch)
            XCTAssertNotEqual(r.state, .onWristLoose, "epoch \(epoch)")
        }
        XCTAssertEqual(state.looseWindow, [true, true, true])
        // Phase 2 — three dropout epochs: sensor_dropout, and the loose window is PAUSED
        // (not appended, not reset) — the pre-dropout degraded flags survive.
        for epoch in 3..<6 {
            let r = classify(dropout(), state: &state, at: epoch)
            XCTAssertEqual(r.state, .sensorDropout, "epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["hr_gap_worn_dropout"])
            XCTAssertEqual(r.coarseWear, .unknown)
            XCTAssertEqual(state.looseWindow, [true, true, true],
                           "dropout epoch \(epoch) must not touch the loose window")
        }
        // Phase 3 — reconnect: degraded epochs resume appending; window fills at epoch 8.
        for epoch in 6..<8 {
            let r = classify(degradedQuiet(), state: &state, at: epoch)
            XCTAssertNotEqual(r.state, .onWristLoose, "epoch \(epoch)")
        }
        XCTAssertEqual(state.looseWindow, [true, true, true, true, true])
        let loose = classify(degradedQuiet(), state: &state, at: 8)
        XCTAssertEqual(loose.state, .onWristLoose, "full window incl. pre-dropout flags fires loose")
        XCTAssertEqual(loose.reasons, ["loose_fraction_met"])
        XCTAssertEqual(loose.coarseWear, .onWrist)
        // Phase 4 — recovery: good epochs roll the window; loose clears and stays good.
        for epoch in 9..<15 {
            let r = classify(goodQuiet(), state: &state, at: epoch)
            XCTAssertEqual(r.state, .onWristGood, "epoch \(epoch)")
            XCTAssertEqual(r.reasons, ["good"])
        }
        XCTAssertEqual(state.looseWindow, [false, false, false, false, false, false],
                       "the loose window fully rolls clean by epoch 14")
    }

    // MARK: - 13.3.6 Stale historical events (hours-old OFF closed by sustained-HR recovery)

    func testStaleHistoricalOffClosedBySustainedHrRecovery() {
        var state = WearSignalTemporalState()
        // Hours-old removal banked on the uncorrected strap RTC: no wall-clock expiry.
        let off0 = classify(WearSignalEvidence(durableOffActive: true), state: &state, at: 0)
        XCTAssertEqual(off0.state, .offWrist)
        XCTAssertEqual(off0.reasons, ["durable_off_active"])
        // 24 h later, still no closure event: the interval is STILL off (interval semantics).
        let off24h = classify(WearSignalEvidence(durableOffActive: true), state: &state, at: 2880)
        XCTAssertEqual(off24h.state, .offWrist)
        XCTAssertEqual(off24h.reasons, ["durable_off_active"])
        XCTAssertEqual(off24h.coarseWear, .offWrist)
        // The strap went quiet with the link up (5.0 never sends WRIST_OFF): sustained-HR
        // recovery + skin-like temp closes the interval and falls through to worn grading.
        let recovery = classify(WearSignalEvidence(durableOffActive: true,
                                                   sustainedHrRecoveryMet: true,
                                                   hrPresent: true, imuQuiet: true,
                                                   tempSkinLike: true,
                                                   waveformCoverageAdequate: true, ppgSqi: 0.8),
                                state: &state, at: 2881)
        XCTAssertEqual(recovery.state, .onWristGood)
        XCTAssertEqual(recovery.reasons, ["good"])
        XCTAssertEqual(recovery.coarseWear, .onWrist)
        XCTAssertTrue(state.durableOffClosed, "recovery latches the durable-off closure")
        // The latch is one-way: the caller's still-stale durableOffActive no longer reads off.
        let after = classify(WearSignalEvidence(durableOffActive: true, sustainedHrRecoveryMet: true,
                                                hrPresent: true, imuQuiet: true, tempSkinLike: true,
                                                waveformCoverageAdequate: true, ppgSqi: 0.8),
                             state: &state, at: 2882)
        XCTAssertEqual(after.state, .onWristGood)
        XCTAssertNotEqual(after.state, .offWrist)
    }

    func testStaleOffNeedsSkinLikeTempWithRecoveryToClose() {
        var state = WearSignalTemporalState()
        let off = classify(WearSignalEvidence(durableOffActive: true), state: &state, at: 0)
        XCTAssertEqual(off.state, .offWrist)
        // Recovery WITHOUT skin-like temp must NOT close the interval (red-team 08: sustained
        // HR alone is not enough — the strap could be running in a bag).
        let noTemp = classify(WearSignalEvidence(durableOffActive: true, sustainedHrRecoveryMet: true),
                              state: &state, at: 1)
        XCTAssertEqual(noTemp.state, .offWrist)
        XCTAssertEqual(noTemp.reasons, ["durable_off_active"])
        XCTAssertFalse(state.durableOffClosed)
    }

    // MARK: - 13.3.7 DETACH shadow plumbing (evidence field present, never authoritative)

    func testDetachShadowEvidenceNeverAuthoritativeForOff() {
        var state = WearSignalTemporalState()
        // Shadow non-wear + quiet + cold-ish corroborators, but NO explicit hardware/HR
        // evidence: the engine must NOT emit off_wrist — the shadow alone never decides.
        let shadowOnly = classify(WearSignalEvidence(imuQuiet: true, tempAmbientOrFalling: true,
                                                     detachShadowNonWear: true),
                                  state: &state, at: 0)
        XCTAssertEqual(shadowOnly.state, .unknown)
        XCTAssertEqual(shadowOnly.reasons, ["not_worn_compatible"])
        XCTAssertNotEqual(shadowOnly.state, .offWrist)
        XCTAssertEqual(shadowOnly.coarseWear, .unknown)
        // Shadow present alongside solid worn evidence: HR present AND-gates it — still good.
        let shadowWithWorn = classify(WearSignalEvidence(hrPresent: true, imuQuiet: true,
                                                         tempSkinLike: true,
                                                         waveformCoverageAdequate: true,
                                                         ppgSqi: 0.8, detachShadowNonWear: true),
                                      state: &state, at: 1)
        XCTAssertEqual(shadowWithWorn.state, .onWristGood)
        XCTAssertEqual(shadowWithWorn.reasons, ["good"])
        XCTAssertEqual(shadowWithWorn.coarseWear, .onWrist)
    }
}
