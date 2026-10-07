import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Prime handover pins for live Watchdog leftovers (`docs/baselines/PRIME_HANDOVER.md` §2).
final class WatchdogPrimeHandoverLiveTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    override func setUp() {
        super.setUp()
        WatchdogForecastRuntime.testPredict = .some(nil)
    }

    override func tearDown() {
        WatchdogForecastRuntime.testPredict = nil
        super.tearDown()
    }

    func testDayTapeHRVIsMilliseconds() throws {
        let now = 97_000_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        var tape = LBDayTape(day: "2026-10-01")
        XCTAssertTrue(tape.ingest(window: win, nowUnix: now))
        XCTAssertGreaterThan(tape.restHRV.n, 0)
        let mean = try XCTUnwrap(tape.restHRV.mean)
        XCTAssertGreaterThan(mean, 8)
        XCTAssertLessThan(mean, 250)
        let math = try XCTUnwrap(LongitudinalBaseline.toMath(mean, series: .awakeRestHRVLn))
        XCTAssertEqual(math, log(mean), accuracy: 1e-9)
        XCTAssertNotEqual(math, log(log(mean)), accuracy: 1e-6)
    }

    func testOverlappingIngestDoesNotRaiseN() {
        let now = 97_100_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        var tape = LBDayTape(day: "2026-10-01")
        XCTAssertTrue(tape.ingest(window: win, nowUnix: now))
        let n = tape.restHRV.n
        XCTAssertFalse(tape.ingest(window: win, nowUnix: now + 20))
        XCTAssertEqual(tape.restHRV.n, n)

        var state = WatchdogBandState.empty
        let present = [true, false, false, false, false, false]
        _ = WatchdogBand.update(&state, absResidual: [0.2, 0, 0, 0, 0, 0], eligible: true,
                                nowUnix: now, present: present, sampleMinute: [now, 0, 0, 0, 0, 0])
        XCTAssertEqual(state.nPresent[0], 1)
        _ = WatchdogBand.update(&state, absResidual: [0.2, 0, 0, 0, 0, 0], eligible: true,
                                nowUnix: now + 20, present: present, sampleMinute: [now, 0, 0, 0, 0, 0])
        XCTAssertEqual(state.nPresent[0], 1)
    }

    func testSleepMinutesNeverTrainAwakeRestTape() {
        let now = 97_200_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        win.activityFeatures = (0..<30).map { _ in
            var row = Array(repeating: 0.0, count: 20)
            row[19] = 1
            return row
        }
        var tape = LBDayTape(day: "2026-10-01")
        _ = tape.ingest(window: win, nowUnix: now)
        XCTAssertEqual(tape.restHR.n, 0)
        XCTAssertGreaterThan(tape.allHR.n, 0)
        XCTAssertFalse(tape.ingest(window: win, nowUnix: now + 60, trainUsual: false))
        XCTAssertEqual(tape.restHR.n, 0)
    }

    func testMissingTempDoesNotInheritHRBandReady() {
        var state = WatchdogBandState.empty
        let hrOnly = [true, false, false, false, false, false]
        for i in 0..<14 {
            let now = 30_000 + i * 60
            _ = WatchdogBand.update(&state, absResidual: [0.30, 0, 0, 0, 0, 0], eligible: true,
                                    nowUnix: now, present: hrOnly,
                                    sampleMinute: [now, 0, 0, 0, 0, 0])
        }
        XCTAssertTrue(WatchdogBand.channelReady(state, 0))
        XCTAssertFalse(WatchdogBand.channelReady(state, 3))
        XCTAssertEqual(state.nPresent[3], 0)
        var carry = WatchdogCarry.empty
        carry.lastBandKey = "still"
        carry.bandByKey["still"] = state
        XCTAssertTrue(carry.channelBandReady(0))
        XCTAssertFalse(carry.channelBandReady(3))
        XCTAssertEqual(carry.presentMinutes(channel: 0), state.nPresent[0])
        XCTAssertEqual(carry.presentMinutes(channel: 3), 0)
    }

    func testIllnessDoesNotRefreshLayer1LastOKFromWatchdog() {
        let asOf = "2026-06-15"
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...(t - 20) {
            rows.append(LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(e),
                                           value: 60, qualityStatus: .ok))
        }
        rows.append(LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(t - 1),
                                       value: 88, qualityStatus: .ok))
        var ill = LBDayLog()
        ill.feltIll = true
        let before = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: rows, replay: false,
            trial: LBTrialRequest(dayLogsByDay: [LongitudinalBaseline.isoFromEpochDay(t - 1): ill]))
        XCTAssertEqual(before.carry.lastQualityOKEpoch, t - 20)
        let now = 97_210_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        _ = Watchdog.evaluate(window: WatchdogWindowBuilder.build(feed), prompt: prompt,
                              evaluations: [before], nowUnix: now)
        let after = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: rows, replay: false,
            trial: LBTrialRequest(dayLogsByDay: [LongitudinalBaseline.isoFromEpochDay(t - 1): ill]))
        XCTAssertEqual(after.carry.lastQualityOKEpoch, before.carry.lastQualityOKEpoch)
        XCTAssertEqual(after.carry.lastQualityOKEpoch, t - 20)
    }

    func testPersonalOffUsesFreezeOrSixtyDayNotWeek() throws {
        let asOf = "2026-06-15"
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...(t - 1) {
            rows.append(LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(e),
                                           value: 50, qualityStatus: .ok, coverage: 40))
        }
        var ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .awakeRestHRVLn,
                                               observations: rows, replay: false)
        let math50 = LongitudinalBaseline.toMath(50, series: .awakeRestHRVLn)!
        ev.establishedLong = false
        ev.showLong = false
        ev.copyLong = nil
        ev.copy7 = LBCopySnapshot(center: math50 + 1.0, spread: 0.15, centerDisplay: 80,
                                  bandLoDisplay: 70, bandHiDisplay: 90, n: 7,
                                  coverage: 40, version: "t", held: false)
        ev.usualFreeze = LBUsualFreeze(t0CivilDay: asOf, tFreeze: asOf,
                                       reason: LBUsualFreeze.loggedIll, version: 2,
                                       centerLong: math50, spreadLong: 0.15,
                                       center7: math50 + 1.0, spread7: 0.15)
        XCTAssertTrue(Watchdog.personalNativeOff(hrvMs: 12, evaluations: [ev]))
        XCTAssertFalse(Watchdog.personalNativeOff(hrvMs: 50, evaluations: [ev]))
        let ref = try XCTUnwrap(Watchdog.personalReference(ev))
        XCTAssertEqual(ref.center, math50, accuracy: 1e-9)
        XCTAssertNotEqual(ref.center, ev.copy7?.center ?? 0, accuracy: 1e-6)
    }

    func testSustainedPersonalOffIsCandidateIfHatQuiet() {
        let note = WatchdogScores.severity(recon: 0, persistTicks: 0, safety: false,
                                           confounded: false, personalOff: true)
        XCTAssertEqual(note, .note)
        let sustained = WatchdogScores.severity(recon: 0, persistTicks: WatchdogCalibration.persistTicks,
                                                safety: false, confounded: false, personalOff: true)
        XCTAssertEqual(sustained, .candidate)
        XCTAssertTrue(Watchdog.liveOff(severity: .candidate, safety: false, personalOff: true))
        XCTAssertFalse(Watchdog.liveOff(severity: .withinLimits, safety: false, personalOff: false))
    }

    func testThinWindowHR135IsSafetySevere() {
        let now = 97_300_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 135, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        if win.hr.count > 4 {
            for i in 0..<(win.hr.count - 3) { win.hr[i] = nil }
        }
        XCTAssertTrue(Watchdog.safetyCap(window: win))
        let r = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(), nowUnix: now)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertEqual(r.qualityGate, "safety-during-quality-fail")
        XCTAssertTrue(r.shouldNotify)
        let silent = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(),
                                       nowUnix: now, liveAlerts: false)
        XCTAssertFalse(silent.shouldNotify)
    }

    func testWristOffIsUnavailableNotRecovered() {
        let r = Watchdog.evaluate(window: .failure(.wristOff), prompt: prompt, nowUnix: 80_400_000)
        XCTAssertEqual(r.severity, .dataUnavailable)
        XCTAssertEqual(r.unavailable, .wristOff)
        XCTAssertEqual(r.eventLabel, WatchdogEventLabel.wristOff.rawValue)
        XCTAssertEqual(r.episodeLine, "Data unavailable (wristOff) · not recovered")
        XCTAssertFalse(r.shouldNotify)
        XCTAssertNotEqual(r.episodeState, .resolved)
        XCTAssertNotEqual(r.episodeState, .recovering)
    }

    func testFirstSevereNotifiesOnce() {
        let lab = WatchdogEventLabel.abnormalMultiDirection
        let (first, r1) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 1.7, recon: 2.5, previousRecon: 1.7,
            eventLabel: lab, episodeId: "wd-1", notifiedSevereEpisodeId: "")
        XCTAssertTrue(first)
        XCTAssertEqual(r1, "first-severe")
        let (second, r2) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 2.5, recon: 2.5, previousRecon: 2.5,
            eventLabel: lab, episodeId: "wd-1", notifiedSevereEpisodeId: "wd-1")
        XCTAssertFalse(second)
        XCTAssertEqual(r2, "stable-episode")
    }

    func testLiveAlertsFalseDoesNotNotify() {
        let r = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                  nowUnix: 97_400_000, inject: .severe, liveAlerts: false)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertNotEqual(r.carry.notifyDelivery, "queued")
    }

    func testChannelBandReadyFalseAt13TrueAt14CivilMinutes() {
        XCTAssertEqual(WatchdogBand.firstMinutes, 14)
        var carry = WatchdogCarry.empty
        let t0 = 94_000_000
        var last = still(now: t0, previous: carry)
        carry = last.carry
        for i in 1..<13 {
            last = still(now: t0 + i * 60, previous: carry)
            carry = last.carry
        }
        XCTAssertEqual(carry.presentMinutes(channel: 0), 13)
        XCTAssertFalse(carry.channelBandReady(0))
        XCTAssertLessThan(carry.presentMinutes(channel: 0), WatchdogBand.firstMinutes)
        last = still(now: t0 + 13 * 60, previous: carry)
        carry = last.carry
        XCTAssertGreaterThanOrEqual(carry.presentMinutes(channel: 0), WatchdogBand.firstMinutes)
        XCTAssertTrue(carry.channelBandReady(0))
    }

    func testChannelBandReadyIsPerVital() {
        var state = WatchdogBandState.empty
        let hrOnly = [true, false, false, false, false, false]
        for i in 0..<13 {
            let now = 50_000 + i * 60
            _ = WatchdogBand.update(&state, absResidual: [0.25, 0, 0, 0, 0, 0], eligible: true,
                                    nowUnix: now, present: hrOnly,
                                    sampleMinute: [now, 0, 0, 0, 0, 0])
        }
        var carry = WatchdogCarry.empty
        carry.lastBandKey = "k"
        carry.bandByKey["k"] = state
        XCTAssertEqual(carry.presentMinutes(channel: 0), 13)
        XCTAssertFalse(carry.channelBandReady(0))
        let m14 = 50_000 + 13 * 60
        _ = WatchdogBand.update(&state, absResidual: [0.25, 0, 0, 0, 0, 0], eligible: true,
                                nowUnix: m14, present: hrOnly,
                                sampleMinute: [m14, 0, 0, 0, 0, 0])
        carry.bandByKey["k"] = state
        XCTAssertTrue(carry.channelBandReady(0))
        XCTAssertFalse(carry.channelBandReady(3))
        let tempNow = m14 + 60
        _ = WatchdogBand.update(&state, absResidual: [0.25, 0, 0, 0.4, 0, 0], eligible: true,
                                nowUnix: tempNow,
                                present: [true, false, false, true, false, false],
                                sampleMinute: [tempNow, 0, 0, tempNow, 0, 0])
        carry.bandByKey["k"] = state
        XCTAssertEqual(carry.presentMinutes(channel: 3), 1)
        XCTAssertFalse(carry.channelBandReady(3))
        XCTAssertTrue(carry.channelBandReady(0))
    }

    func testLiveLineExistsBeforeBandReady() {
        let now = 94_100_000
        let r = still(now: now, previous: .empty)
        let hr = r.signals.first { $0.name.lowercased().contains("heart") || $0.unit == "bpm" }
            ?? r.signals.first
        XCTAssertNotNil(hr?.observed)
        XCTAssertFalse(r.carry.channelBandReady(0))
        XCTAssertLessThan(r.carry.presentMinutes(channel: 0), WatchdogBand.firstMinutes)
        if let hat = r.reconstructedHR.last {
            XCTAssertTrue(hat.isFinite)
        }
    }

    func testStudentVersionStringsAreNotOfficial() {
        XCTAssertTrue(WatchdogConfig.modelVersion.contains("student")
                      || WatchdogConfig.modelVersion == "units-ad-coreml-v3")
        XCTAssertTrue(WatchdogConfig.forecastModelVersion.contains("student"))
        XCTAssertTrue(WatchdogConfig.modelVersion.contains("units-ad-coreml-v3"))
        XCTAssertTrue(WatchdogConfig.forecastModelVersion.contains("timesfm3-student-v3"))
        XCTAssertFalse(WatchdogConfig.modelVersion.lowercased().contains("official"))
        XCTAssertFalse(WatchdogConfig.forecastModelVersion.lowercased().contains("official"))
        XCTAssertNotEqual(WatchdogForecastSource.student.rawValue, "official")
    }

    func testShouldTrainUsualFalseIsTapeNoOp() {
        let quiet = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: 97_270_000)
        XCTAssertFalse(Watchdog.shouldTrainUsual(result: quiet, dayLog: nil))
        let now = 97_260_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        var tape = LBDayTape(day: "2026-10-01")
        XCTAssertFalse(tape.ingest(window: win, nowUnix: now, trainUsual: false))
        XCTAssertEqual(tape.restHR.n, 0)
    }

    private func still(now: Int, previous: WatchdogCarry) -> WatchdogResult {
        Watchdog.evaluate(window: WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)),
                          prompt: prompt, nowUnix: now, previous: previous)
    }
}
