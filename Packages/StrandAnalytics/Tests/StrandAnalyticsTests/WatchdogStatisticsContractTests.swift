import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Pins every published Watchdog door (`docs/baselines/WATCHDOG.md`) to the live
/// evaluate loop and the published numbers. If a promised rule drifts, this file
/// fails instead of a comment.
final class WatchdogStatisticsContractTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
    private let usual = [58.0, 58.0, 48.0, 33.1, 14.0, 97.0]
    private let scales = [5.0, 5.0, 8.0, 1.0, 3.0, 2.0]

    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Published knobs

    func testPublishedWindowAndDoors() {
        XCTAssertEqual(WatchdogConfig.seqLen, 30)
        XCTAssertEqual(WatchdogConfig.gridSeconds, 60)
        XCTAssertEqual(WatchdogConfig.contextSeconds, 1800)
        XCTAssertEqual(WatchdogConfig.tickSeconds, 20)
        XCTAssertEqual(WatchdogConfig.minCoverage, 0.80, accuracy: 1e-12)
        XCTAssertEqual(WatchdogCalibration.maxEmptyMinutes, 6)
        XCTAssertEqual(WatchdogCalibration.tNote, 1.0, accuracy: 1e-12)
        XCTAssertEqual(WatchdogCalibration.tActive, 1.6, accuracy: 1e-12)
        XCTAssertEqual(WatchdogCalibration.tSevere, 2.4, accuracy: 1e-12)
        XCTAssertEqual(WatchdogCalibration.persistTicks, 2)
        XCTAssertEqual(WatchdogCalibration.forecastHorizon, 5)
        XCTAssertEqual(WatchdogCalibration.escalateDelta, 0.5, accuracy: 1e-12)
        XCTAssertEqual(WatchdogEventLabeler.familyHoldSeconds, 120)
        XCTAssertEqual(WatchdogEventGeometry.persist, 2)
        XCTAssertEqual(LongitudinalBaseline.trustHideThreshold, 35)
        XCTAssertEqual(WatchdogForecastRuntime.earlyTrustFloor, 35)
        XCTAssertEqual(WatchdogScores.severityChannelCap, 1.0, accuracy: 1e-12)
        XCTAssertEqual(WatchdogScores.severityArtifactGain, 0.72, accuracy: 1e-12)
        XCTAssertEqual(WatchdogScores.rhrSeverityIndex, 1)
        XCTAssertEqual(WatchdogPhysiologyAlert.minVitals, 3)
        XCTAssertEqual(WatchdogDirection.channelCount, 6)
        XCTAssertEqual(WatchdogDirection.beta, 1.0, accuracy: 1e-12)
        XCTAssertEqual(WatchdogBand.firstMinutes, 14)
        XCTAssertEqual(WatchdogConfig.tempScale, 1.0, accuracy: 1e-12)
        XCTAssertEqual(WatchdogConfig.tempCenterAlpha, 0.28, accuracy: 1e-12)
        XCTAssertEqual(WatchdogBand.stepMax, 0.02, accuracy: 1e-12)
        XCTAssertEqual(WatchdogBand.shouldCountMinute(nowUnix: 100, lastUnix: 90), false)
        XCTAssertTrue(WatchdogBand.shouldCountMinute(nowUnix: 120, lastUnix: 59))
        // No on-device model: expectations are the person's baselines; no forecast runs on the phone.
        XCTAssertTrue(WatchdogConfig.expectationVersion.hasPrefix("baseline-"))
        XCTAssertEqual(WatchdogForecastRuntime.modelVersion, "none")
    }

    // MARK: - No on-device model: expectation = baselines; forecast = server only

    func testWithoutEstablishedBaselinesNothingIsDrawnOrScored() throws {
        let r = try evaluate(now: 80_000_000, hr: 58, motion: 0)
        XCTAssertEqual(r.modelVersion, WatchdogConfig.expectationVersion)
        XCTAssertEqual(r.reconstructedHR.count, 30)
        XCTAssertTrue(r.reconstructedHR.allSatisfy { !$0.isFinite }, "no baseline yet → no expected line")
        XCTAssertEqual(r.jointEnergy, 0, accuracy: 1e-12)
        XCTAssertEqual(r.fusedEnergy, r.jointEnergy, accuracy: 1e-12)
        XCTAssertEqual(WatchdogScores.fused(recon: 0.4, forecast: 9), 0.4, accuracy: 1e-12)
    }

    func testNoForecastRunsOnThePhoneAndNothingPagesFromOne() throws {
        let r = try evaluate(now: 80_200_000, hr: 58, motion: 0)
        XCTAssertEqual(r.forecastSource, WatchdogForecastSource.none.rawValue)
        XCTAssertFalse(r.carry.forecastStudentOk)
        XCTAssertEqual(r.forecastEnergy, 0, accuracy: 1e-9)
        XCTAssertFalse(r.earlyFlag)
        XCTAssertNotEqual(r.severity, .severe)
        XCTAssertFalse(r.shouldNotify)
        let leaving = WatchdogScores.severity(recon: 0.2, forecast: 8, persistTicks: 4,
                                              safety: false, confounded: false, personalOff: false)
        XCTAssertEqual(leaving, .withinLimits)
    }


    // MARK: - Quality / wrist-off / safety

    func testWristOffIsUnavailableNotRecovered() {
        let r = Watchdog.evaluate(window: .failure(.wristOff), prompt: prompt, nowUnix: 80_400_000)
        XCTAssertEqual(r.severity, .dataUnavailable)
        XCTAssertEqual(r.unavailable, .wristOff)
        XCTAssertEqual(r.eventLabel, WatchdogEventLabel.wristOff.rawValue)
        XCTAssertEqual(r.episodeLine, "Data unavailable (wristOff) · not recovered")
        XCTAssertTrue(r.reconstructedHR.isEmpty)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertFalse(r.sigmaAdaptive)
        XCTAssertEqual(r.jointEnergy, 0, accuracy: 1e-12)
    }

    func testCoverageGateStopsTheModels() {
        var feed = Watchdog.syntheticFeed(now: 80_410_000, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        feed.hr = Array(feed.hr.suffix(180))
        switch WatchdogWindowBuilder.build(feed) {
        case .failure(let reason):
            let r = Watchdog.evaluate(window: .failure(reason), prompt: prompt, nowUnix: 80_410_000)
            XCTAssertEqual(r.severity, .dataUnavailable)
            XCTAssertTrue(r.reconstructedHR.isEmpty)
        case .success(let w):
            XCTAssertTrue(WatchdogQuality.bucketCoverage(w) + 1e-9 < WatchdogConfig.minCoverage
                          || WatchdogQuality.maxEmptyMinutes(w.hr) >= WatchdogCalibration.maxEmptyMinutes)
            let r = Watchdog.evaluate(window: .success(w), prompt: prompt, nowUnix: 80_410_000)
            XCTAssertEqual(r.severity, .dataUnavailable)
            XCTAssertTrue(r.reconstructedHR.isEmpty)
            XCTAssertNotNil(r.unavailable)
        }
    }

    func testStillWristExtremaPageWithoutTheModelDoor() throws {
        // v2: a sustained still extreme pages without any model — but only once on-body / signal quality are
        // verified. With no quality metadata the same window is held (shown as a candidate, never sent).
        var w = try window(now: 80_420_000, hr: 132, motion: 0)
        let unverified = Watchdog.evaluate(window: .success(w), prompt: prompt, nowUnix: w.nowUnix)
        XCTAssertEqual(unverified.severity, .candidate)
        XCTAssertFalse(unverified.shouldNotify)
        w.quality = .synthetic(for: w)
        let r = Watchdog.evaluate(window: .success(w), prompt: prompt, nowUnix: w.nowUnix)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertTrue(r.shouldNotify)
        XCTAssertEqual(r.eventLabel, WatchdogEventLabel.safetyBound.rawValue)
        XCTAssertTrue(WatchdogNotifyPolicy.extremeFamily(.safetyBound))
    }

    func testEffortMinutesDoNotOpenRestSafety() throws {
        let w = try window(now: 80_430_000, hr: 132, motion: 0.55, stepsPerMin: 110)
        XCTAssertFalse(WatchdogLiveTail.resolve(w).stillNow)
        XCTAssertFalse(WatchdogSafety.fired(w), "safety extrema are still-wrist only")
    }

    // MARK: - Direction and severity statistics

    func testSixChannelsShareEqualWeightAndRHRIsNotASecondMetric() {
        var ema = Array(repeating: 0.0, count: 6)
        let dir = WatchdogDirection.compute(
            rawR: [1, 1, 1, 1, 1, 1], rhrAllowed: true, artifact: false, dirEma: &ema)
        XCTAssertEqual(dir.weights.filter { $0 > 0 }.count, 6)
        XCTAssertTrue(dir.weights.allSatisfy { abs($0 - 1.0 / 6.0) < 1e-12 })
        let hr = WatchdogScores.severityJoint(
            absR: [1.2, 0, 0, 0, 0, 0],
            mask: [true, false, false, false, false, false], artifact: false)
        let hrRhr = WatchdogScores.severityJoint(
            absR: [1.2, 1.2, 0, 0, 0, 0],
            mask: [true, true, false, false, false, false], artifact: false)
        XCTAssertEqual(hr, 1.0, accuracy: 1e-12)
        XCTAssertEqual(hrRhr, hr, accuracy: 1e-12)
        XCTAssertLessThan(hr, WatchdogCalibration.tSevere)
        let one = WatchdogPhysiologyAlert.marks(
            absR: [1.2, 0, 0, 0, 0, 0],
            mask: [true, false, false, false, false, false])
        let two = WatchdogPhysiologyAlert.marks(
            absR: [1.2, 0, 1.1, 0, 0, 0],
            mask: [true, false, true, false, false, false])
        XCTAssertFalse(WatchdogPhysiologyAlert.shouldAlert(marks: one, safety: false, personalOff: false))
        XCTAssertFalse(WatchdogPhysiologyAlert.shouldAlert(marks: two, safety: false, personalOff: false))
        XCTAssertTrue(WatchdogPhysiologyAlert.shouldAlert(marks: one, safety: true, personalOff: false))
    }

    func testPersistTwoTicksIsRequiredForModelSevere() {
        let j = WatchdogScores.severityJoint(
            absR: [1, 0, 1, 1, 0, 0],
            mask: [true, false, true, true, false, false], artifact: false)
        XCTAssertEqual(j, 3.0, accuracy: 1e-12)
        XCTAssertEqual(WatchdogScores.severity(recon: j, persistTicks: 1, safety: false,
                                               confounded: false, personalOff: false), .note)
        XCTAssertEqual(WatchdogScores.severity(recon: j, persistTicks: 2, safety: false,
                                               confounded: false, personalOff: false), .severe)
        let art = WatchdogScores.severityJoint(
            absR: [1, 0, 1, 1, 0, 0],
            mask: [true, false, true, true, false, false], artifact: true)
        XCTAssertEqual(art, 3.0 * 0.72, accuracy: 1e-12)
        XCTAssertLessThan(art, WatchdogCalibration.tSevere)
    }

    func testIllnessCapsSeverityAndDoesNotPage() throws {
        var ill = LBDayLog()
        ill.feltIll = true
        XCTAssertTrue(ill.confoundsUsual)
        let r = try evaluate(now: 80_440_000, hr: 132, motion: 0, dayLog: ill)
        if r.severity == .severe {
            XCTAssertTrue(r.shouldNotify, "still-wrist safety may still page")
        } else {
            XCTAssertEqual(r.severity, .candidate)
            XCTAssertFalse(r.shouldNotify)
        }
        let model = WatchdogScores.severity(recon: 3.0, persistTicks: 4, safety: false,
                                            confounded: true, personalOff: false)
        XCTAssertEqual(model, .candidate)
    }

    // MARK: - Events, notify, workout, band

    func testQuietStillIsOneExclusiveNameAndDoesNotNotify() throws {
        let r = try evaluate(now: 80_450_000, hr: 58, motion: 0)
        XCTAssertEqual(r.eventLabel, WatchdogEventLabel.normalStillAwake.rawValue)
        XCTAssertNotEqual(r.severity, .severe)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertFalse(WatchdogNotifyPolicy.extremeFamily(.normalStillAwake))
        XCTAssertFalse(WatchdogNotifyPolicy.extremeFamily(.workoutWalk))
        XCTAssertFalse(WatchdogNotifyPolicy.extremeFamily(.normalSleep))
        XCTAssertEqual(WatchdogEventLabeler.wearerPhrase(.forecastDriftOnly), "Looking ahead")
        XCTAssertFalse(r.headline.lowercased().contains("drug"))
        XCTAssertFalse(r.episodeLine.lowercased().contains("diagnos") && r.episodeLine.contains("is a"))
    }

    func testWorkoutNameNeedsQuietReconstructionAndATwoMinuteHold() {
        XCTAssertEqual(
            WatchdogEventGeometry.what(cls: .walk, reconJ: 0.4, forecastJ: 0,
                                       safety: false, artifact: false, postWorkout: false,
                                       sleep: false, hrHot: false, breadth: 0.1,
                                       familyHeld: false),
            .mixedRejected)
        XCTAssertEqual(
            WatchdogEventGeometry.what(cls: .walk, reconJ: 0.4, forecastJ: 0,
                                       safety: false, artifact: false, postWorkout: false,
                                       sleep: false, hrHot: false, breadth: 0.1,
                                       familyHeld: true),
            .workoutWalk)
        XCTAssertNotEqual(
            WatchdogEventGeometry.what(cls: .walk, reconJ: 1.8, forecastJ: 0,
                                       safety: false, artifact: false, postWorkout: false,
                                       sleep: false, hrHot: true, breadth: 0.6,
                                       familyHeld: true),
            .workoutWalk,
            "hot reconstruction must not name a workout")
    }

    func testWalkBandDoesNotWriteTheStillKey() throws {
        var carry = try evaluate(now: 80_460_000, hr: 58, motion: 0).carry
        let stillKey = carry.lastBandKey
        let stillN = carry.bandByKey[stillKey]?.n ?? carry.bandN
        var last = try evaluate(now: 80_460_060, hr: 88, motion: 0.42, stepsPerMin: 110, previous: carry)
        for i in 1...8 {
            last = try evaluate(now: 80_460_060 + i * 60, hr: 88, motion: 0.42,
                                stepsPerMin: 110, previous: last.carry)
        }
        carry = last.carry
        XCTAssertEqual(carry.bandByKey[stillKey]?.n ?? stillN, stillN)
        if last.eventLabel == WatchdogEventLabel.workoutWalk.rawValue {
            let walkKey = WatchdogPhaseKey(
                phase: WatchdogPhaseUsualStore.phase(nowUnix: last.lastTickUnix, sleepBit: false),
                family: .walk).id
            XCTAssertNotEqual(walkKey, stillKey)
        }
    }

    func testForecastDriftAndSpikesAreNotBandEligible() {
        XCTAssertFalse(WatchdogBand.learnable(.forecastDriftOnly))
        XCTAssertFalse(WatchdogBand.learnable(.artifactSpike))
        XCTAssertFalse(WatchdogBand.learnable(.abnormalStillTachycardia))
        XCTAssertFalse(WatchdogBand.learnable(.safetyBound))
        XCTAssertTrue(WatchdogBand.learnable(.normalStillAwake))
        XCTAssertTrue(WatchdogBand.learnable(.workoutWalk))
        XCTAssertTrue(WatchdogEventLabeler.sidecarEligible(.forecastDriftOnly))
        XCTAssertFalse(WatchdogEventLabeler.sidecarEligible(.workoutWalk))
    }

    func testSigmaAdaptiveIsTheReadyBandNotASecondModel() throws {
        let first = try evaluate(now: 80_470_000, hr: 58, motion: 0)
        XCTAssertEqual(first.sigmaAdaptive, first.carry.bandReady)
        XCTAssertFalse(first.sigmaAdaptive)
    }

    // MARK: - TRUST, Layer 1 prompt, no Layer 1 write

    func testLiveTrustIsFiftyThirtyFiveFifteenWithShownUsualCaps() {
        let shown = Watchdog.predictionTrust(energy: 0, usual: 58, coverage: 1,
                                             usualTrust: 80, persistTicks: 0, hot: false)
        let expectedShown = 50.0 * 0.80 + 35.0 + 15.0
        XCTAssertEqual(shown, Int(expectedShown.rounded()))
        let shortTerm = Watchdog.predictionTrust(energy: 0, usual: nil, coverage: 1,
                                                 usualTrust: 0, persistTicks: 0, hot: false, hat: 62)
        XCTAssertGreaterThanOrEqual(shortTerm, LongitudinalBaseline.trustHideThreshold)
        XCTAssertEqual(shortTerm, Int((50.0 * 0.55 + 35.0 + 15.0).rounded()))
        let none = Watchdog.predictionTrust(energy: 0, usual: nil, coverage: 1,
                                            usualTrust: 0, persistTicks: 0, hot: false)
        XCTAssertLessThanOrEqual(none, 18)
        XCTAssertFalse(WatchdogForecastRuntime.wearerEarly(
            pathJ: 1.4, allowed: true, severity: .withinLimits, trustPct: 20, persistTicks: 2))
    }

    /// Without an established Layer 1 baseline the window is never its own "short-term baseline": the reading
    /// shows, nothing is expected, nothing is scored, nothing pages.
    func testQuietHalfHourWithoutLayer1ShowsTheReadingAndExpectsNothing() throws {
        let r = try evaluate(now: 80_480_000, hr: 58, motion: 0)
        XCTAssertNotEqual(r.severity, .severe)
        XCTAssertFalse(r.shouldNotify)
        let hr = r.signals.first(where: { $0.name == "HR" })
        XCTAssertEqual(hr?.observed ?? 0, 58, accuracy: 1.5)
        XCTAssertNil(hr?.reconstructed)
        XCTAssertEqual(hr?.energy ?? -1, 0, accuracy: 1e-12)
    }

    func testPromptTrustFollowsTheHatSeriesNotTheMaxCopy() {
        var rest = LongitudinalBaseline.emptyEvaluation(asOf: "2026-09-20", series: .awakeRestHR, carry: LBCarry())
        rest.showLong = true
        rest.usualTrustPctLong = 40
        rest.copyLong = LBCopySnapshot(center: 62, spread: 3, centerDisplay: 62,
                                       bandLoDisplay: 56, bandHiDisplay: 68, n: 20,
                                       coverage: 1, lastUpdate: "2026-09-19", version: "t", held: false)
        var allDay = LongitudinalBaseline.emptyEvaluation(asOf: "2026-09-20", series: .continuousHR, carry: LBCarry())
        allDay.showLong = true
        allDay.usualTrustPctLong = 90
        allDay.copyLong = LBCopySnapshot(center: 80, spread: 4, centerDisplay: 80,
                                         bandLoDisplay: 72, bandHiDisplay: 88, n: 20,
                                         coverage: 1, lastUpdate: "2026-09-19", version: "t", held: false)
        XCTAssertEqual(UniTSPrompt.from(evaluations: [rest, allDay]).hr ?? 0, 62, accuracy: 0.01)
        XCTAssertEqual(Watchdog.layer1UsualTrust([rest, allDay], matching: [.awakeRestHR, .continuousHR]), 40)
        XCTAssertNotEqual(Watchdog.layer1UsualTrust([rest, allDay], matching: [.awakeRestHR, .continuousHR]), 90)
    }

    func testEvaluateDoesNotRewriteLayer1Copies() throws {
        var ev = LongitudinalBaseline.emptyEvaluation(asOf: "2026-09-20", series: .sleepRHR, carry: LBCarry())
        ev.showLong = true
        ev.usualTrustPctLong = 80
        ev.copyLong = LBCopySnapshot(center: 58, spread: 2, centerDisplay: 58,
                                     bandLoDisplay: 54, bandHiDisplay: 62, n: 20,
                                     coverage: 1, lastUpdate: "2026-09-19", version: "t", held: false)
        let before = ev.copyLong?.center
        _ = try evaluate(now: 80_490_000, hr: 132, motion: 0, evaluations: [ev])
        XCTAssertEqual(ev.copyLong?.center ?? -1, before ?? -2, accuracy: 1e-12)
    }

    func testSleepRHRPromptIsNotRelabeledAsLiveHR() {
        var sleep = LongitudinalBaseline.emptyEvaluation(asOf: "2026-09-20", series: .sleepRHR, carry: LBCarry())
        sleep.showLong = true
        sleep.usualTrustPctLong = 80
        sleep.copyLong = LBCopySnapshot(center: 58, spread: 2, centerDisplay: 58,
                                        bandLoDisplay: 54, bandHiDisplay: 62, n: 20,
                                        coverage: 1, lastUpdate: "2026-09-19", version: "t", held: false)
        let p = UniTSPrompt.from(evaluations: [sleep])
        XCTAssertEqual(p.rhr ?? 0, 58, accuracy: 0.01)
        XCTAssertNil(p.hr)
    }

    func testSidecarBlendDoesNotAverageTheTwoLayer1Copies() {
        var store = WatchdogPhaseUsualStore.empty
        var entry = WatchdogPhaseEntry()
        entry.center = [70, 58, 48, 33.1, 14, 97]
        entry.nDays = WatchdogPhaseUsualStore.matureDays
        store.entries[WatchdogPhaseKey(phase: .midday, family: .still).id] = entry
        let layer = UniTSPrompt(hr: 62, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
        let blended = store.blendPrompt(layer, key: WatchdogPhaseKey(phase: .midday, family: .still))
        let expected = (1 - WatchdogPhaseUsualStore.blendSidecar) * 62
            + WatchdogPhaseUsualStore.blendSidecar * 70
        XCTAssertEqual(blended.hr ?? 0, expected, accuracy: 1e-9)
        XCTAssertNotEqual(blended.hr ?? 0, (62 + 70) / 2, accuracy: 0.05)
        XCTAssertEqual(blended.rhr ?? 0, 58, accuracy: 1e-12)
    }

    // MARK: - helpers

    private func evaluate(now: Int, hr: Double, motion: Double,
                          stepsPerMin: Int = 0,
                          previous: WatchdogCarry = .empty,
                          dayLog: LBDayLog? = nil,
                          evaluations: [LBEvaluation] = []) throws -> WatchdogResult {
        let w = try window(now: now, hr: hr, motion: motion, stepsPerMin: stepsPerMin)
        return Watchdog.evaluate(window: .success(w), prompt: prompt, evaluations: evaluations,
                                 dayLog: dayLog, nowUnix: now, previous: previous)
    }

    private func window(now: Int, hr: Double, motion: Double,
                        stepsPerMin: Int = 0) throws -> WatchdogWindow {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: hr > 100 ? 16 : 48,
                                          temp: 33.1, resp: hr > 100 ? 22 : 14,
                                          motion: motion, stepsPerMin: stepsPerMin)
        if motion > 0.2 {
            let start = now - WatchdogConfig.contextSeconds
            feed.steps = (start..<now).map { StepSample(ts: $0, counter: 1, activityClass: 1) }
        }
        switch WatchdogWindowBuilder.build(feed) {
        case .success(let w): return w
        case .failure(let e):
            throw NSError(domain: "wd-contract", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(e)"])
        }
    }

    private func onUsualCube() -> [[Double]] {
        (0..<6).map { k in Array(repeating: usual[k], count: 5) }
    }

    private func leavingCube() -> [[Double]] {
        var cube = onUsualCube()
        for t in 0..<5 {
            cube[0][t] = 130
            cube[3][t] = 36.8
            cube[4][t] = 24
        }
        return cube
    }
}
