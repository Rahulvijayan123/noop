/** WearSignalPhysiologyGatingTests.swift — spec §10 minimum V1 physiology gating.

Additive gate on `HRVWindowBuilder.isEligibleForBaseline`: when a window carries a six-state
wear-signal context (`HRVWindow.wearSignal`, feat/wear-signal-quality V1), the four states whose
`opticalMeasurementQuality` is non-nil — `.onWristLoose`, `.motionArtifact`, `.offWrist`,
`.sensorDropout` — must never feed a resting HRV/RHR baseline. nil, `.onWristGood` and `.unknown`
keep the pre-existing eligibility rules exactly.

No metric redesign: every existing gate (rmssd present, steady state, artifact fraction,
signal trustworthiness, `.offWrist` activity class, motion/gyro ceilings) is untouched; this
suite only proves the new seam is additive and that the engine → window hand-off works end to end.
*/

import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class WearSignalPhysiologyGatingTests: XCTestCase {
    private let t0 = 1_760_000_000

    /// Beats at a constant interval, timestamped beat-accurately so the trust gates pass.
    private func beats(constantMs: Double, from: Int, seconds: Int) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(from)
        let end = Double(from + seconds)
        while t < end {
            out.append(RRInterval(ts: Int(t), rrMs: Int(constantMs)))
            t += constantMs / 1000.0
        }
        return out
    }

    /// An otherwise-clean, baseline-eligible window (same shape as `HRVWindowTests`'s helper),
    /// optionally carrying a wear signal.
    private func baseEligibleWindow(wearSignal: WearSignalState? = nil,
                                    activityContext: ActivityClass? = .sitting,
                                    phase: ActivityPhysiologyPhase = .steadyState) -> HRVWindow {
        HRVWindow(kind: .canonical5m, start: t0, end: t0 + 300, rmssd: 30, sdnn: 40, meanNN: 800,
                 medianNN: 800, rrDiffSqSumMs2: 1_000, rrDiffCount: 100, nnM2: 2_000, validRRCount: 300,
                 artifactFraction: 0.05,
                 signalQuality: HRVSignalQuality(coverageVerdict: .plausible, beatAccurateFraction: 0.99,
                                                 trustworthy: true),
                 motionRmsG: 0.01, gyroRmsDps: nil, activityContext: activityContext,
                 activityConfidence: 0.9, secondsSinceTransition: 300, secondsSinceLocomotion: nil,
                 secondsSinceExercise: nil, phase: phase, eligibleForBaseline: false,
                 wearSignal: wearSignal)
    }

    // MARK: - Existing behavior preserved (nil / good / unknown)

    func testNilWearSignalKeepsExistingEligibility() {
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: nil)))
    }

    func testOnWristGoodKeepsExistingEligibility() {
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: .onWristGood)))
    }

    func testUnknownNeverUpgradesOrDowngradesEligibility() {
        // `unknown` preserves the per-metric rules exactly: an otherwise-clean window stays eligible,
        // and an otherwise-ineligible window stays ineligible — unknown is never a downgrade.
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: .unknown)))
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(wearSignal: .unknown, phase: .transition)))
    }

    // MARK: - The four gated wear-signal states

    func testOffWristWearSignalNeverEligible() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: .offWrist)))
    }

    func testSensorDropoutNeverEligible() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: .sensorDropout)))
    }

    func testOnWristLooseNeverEligible() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: .onWristLoose)))
    }

    func testMotionArtifactNeverEligible() {
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: .motionArtifact)))
    }

    func testWearSignalGateIsAdditiveToEveryExistingGate() {
        // A window already refused by an existing gate stays refused with a wear signal attached…
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(wearSignal: .onWristGood, phase: .recovery)))
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(wearSignal: .onWristGood, activityContext: .offWrist)))
        // …and the new gate refuses a window that would otherwise pass every existing gate.
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(
            baseEligibleWindow(wearSignal: .onWristLoose, activityContext: .sleeping)))
    }

    // MARK: - build() threads the wear signal through

    /// A decoded, awake, on-wrist context with no transitions: since D3-03/D6-03 `build` refuses
    /// baseline eligibility without decoded context (no event data → phase unknown; no lookup → sleep
    /// and wear unknown), so the build-level wear tests below supply it explicitly.
    private var awake: ActivityContextLookup {
        ActivityContextLookup(intervals: [ActivityContextInterval(start: t0 - 600, end: t0 + 600,
                                                                  activityClass: .sitting, confidence: 0.9,
                                                                  sleep: .unknown, wear: .onWrist)])
    }

    func testBuildWithoutWearSignalKeepsNilAndEligibility() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                     activity: awake, transitionEvents: []).first)
        XCTAssertNil(w.wearSignal)
        XCTAssertTrue(w.eligibleForBaseline)
    }

    func testBuildWithOffWristWearSignalIsNotEligible() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                     activity: awake, transitionEvents: [],
                                                     wearSignal: .offWrist).first)
        XCTAssertEqual(w.wearSignal, .offWrist)
        XCTAssertFalse(w.eligibleForBaseline)
    }

    func testBuildWithOnWristGoodWearSignalStaysEligible() throws {
        let rr = beats(constantMs: 800, from: t0, seconds: 300)
        let w = try XCTUnwrap(HRVWindowBuilder.build(kind: .canonical5m, dayStart: t0, dayEnd: t0 + 300, rr: rr,
                                                     activity: awake, transitionEvents: [],
                                                     wearSignal: .onWristGood).first)
        XCTAssertEqual(w.wearSignal, .onWristGood)
        XCTAssertTrue(w.eligibleForBaseline)
    }

    // MARK: - Engine → window hand-off, end to end

    func testCorruptedOrMissingPpgThroughEngineGatesTheWindow() throws {
        // Missing PPG (`ppgSqi` nil) with the strap's own bad flags and a pulse present: the engine
        // is not fooled into `onWristGood` — over a full loose window it lands on `onWristLoose`,
        // and that state must gate the window's baseline eligibility.
        var state = WearSignalTemporalState()
        let corrupted = WearSignalEvidence(hrPresent: true, strapFlagsBad: true, tempSkinLike: true,
                                           waveformCoverageAdequate: true) // ppgSqi == nil
        var final: WearSignalQualityResult?
        for epoch in 0..<6 {
            final = WearSignalQualityEngine.classify(corrupted, state: &state, epochStart: epoch * 30)
        }
        let verdict = try XCTUnwrap(final)
        XCTAssertEqual(verdict.state, .onWristLoose)
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: verdict.state)))

        // Sanity: clean PPG with the same worn evidence is `onWristGood` and stays eligible.
        var stateGood = WearSignalTemporalState()
        let clean = WearSignalEvidence(hrPresent: true, imuQuiet: true, tempSkinLike: true,
                                       waveformCoverageAdequate: true, ppgSqi: 0.8)
        let good = WearSignalQualityEngine.classify(clean, state: &stateGood, epochStart: 0)
        XCTAssertEqual(good.state, .onWristGood)
        XCTAssertTrue(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: good.state)))
    }

    func testExplicitOffWristThroughEngineGatesTheWindow() {
        var state = WearSignalTemporalState()
        let off = WearSignalQualityEngine.classify(WearSignalEvidence(liveWristOffFresh: true),
                                                   state: &state, epochStart: 0)
        XCTAssertEqual(off.state, .offWrist)
        XCTAssertFalse(HRVWindowBuilder.isEligibleForBaseline(baseEligibleWindow(wearSignal: off.state)))
    }
}
