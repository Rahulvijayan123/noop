import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class WatchdogV40CloseoutTests: XCTestCase {
    func testDayTapeHRVIsMillisecondsNotLn() throws {
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
        // WP8: one window files every settled minute (30 − 5 settle), not one minute per tick.
        // 25 still minutes clear the 8-minute floor but stay under the 30-minute coverage gate.
        XCTAssertEqual(tape.restHRV.n, 25)
        let obs = try XCTUnwrap(tape.observation(series: .awakeRestHRVLn))
        XCTAssertEqual(obs.qualityReason, .lowCoverage)
    }

    func testOverlappingWindowDoesNotRaiseHRVCount() {
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
    }

    func testSleepMinuteDoesNotEnterAwakeRest() {
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

    func testEscalateRespectsCooldown() {
        let lab = WatchdogEventLabel.abnormalMultiDirection
        let t = 2_000_000
        let (inside, rIn) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 3.2, previousFused: 2.4, recon: 3.2, previousRecon: 2.4,
            eventLabel: lab, episodeId: "wd-1", notifiedSevereEpisodeId: "wd-1",
            lastNotifiedAt: t, nowUnix: t + 40)
        XCTAssertFalse(inside)
        XCTAssertEqual(rIn, "cooldown")
        let (after, rAfter) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 3.2, previousFused: 2.4, recon: 3.2, previousRecon: 2.4,
            eventLabel: lab, episodeId: "wd-1", notifiedSevereEpisodeId: "wd-1",
            lastNotifiedAt: t, nowUnix: t + WatchdogConfig.notifyCooldownSeconds)
        XCTAssertTrue(after)
        XCTAssertEqual(rAfter, "escalate")
    }

    func testRecoveryNeedsTwoValidQuietMinutesNotTicks() {
        var carry = WatchdogCarry.empty
        carry.episodeId = "wd-1"
        carry.priorState = .active
        carry.consecutiveInRangeTicks = 0
        XCTAssertEqual(Watchdog.nextState(severity: .withinLimits, carry: &carry), .recovering)
        carry.priorState = .recovering
        carry.consecutiveInRangeTicks = 1
        XCTAssertEqual(Watchdog.nextState(severity: .withinLimits, carry: &carry), .recovering)
        carry.consecutiveInRangeTicks = 2
        XCTAssertEqual(Watchdog.nextState(severity: .withinLimits, carry: &carry), .resolved)
    }

    func testUnavailablePausesRecoveryWithoutResolving() {
        var carry = WatchdogCarry.empty
        carry.episodeId = "wd-1"
        carry.priorState = .active
        carry.consecutiveInRangeTicks = 1
        carry.notifiedSevereEpisodeId = "wd-1"
        let r = Watchdog.evaluate(window: .failure(.coverage), prompt: UniTSPrompt(),
                                  nowUnix: 98_000_000, previous: carry)
        XCTAssertEqual(r.severity, .dataUnavailable)
        XCTAssertEqual(r.episodeState, .dataUnavailable)
        XCTAssertEqual(r.carry.episodeId, "wd-1")
        XCTAssertEqual(r.carry.consecutiveInRangeTicks, 1)
        XCTAssertFalse(r.shouldNotify)
    }

    func testPersistDoesNotAdvanceOnHeldObservationNewWallMinute() {
        let now = 98_100_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 70, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        let first = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(), nowUnix: now)
        let later = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(),
                                      nowUnix: now + 60, previous: first.carry)
        XCTAssertEqual(later.carry.lastPersistObsMinute, first.carry.lastPersistObsMinute)
        XCTAssertEqual(later.carry.consecutiveMismatchTicks, first.carry.consecutiveMismatchTicks)
        XCTAssertEqual(later.carry.consecutiveInRangeTicks, first.carry.consecutiveInRangeTicks)
    }

    func testStudentForecastIsNotWearerEarly() {
        XCTAssertFalse(WatchdogForecastRuntime.wearerEarly(
            pathJ: 1.4, allowed: true, severity: .withinLimits, trustPct: 80, persistTicks: 2,
            forecastSource: "student"))
        XCTAssertEqual(WatchdogForecastStep.horizonUnix(nowUnix: 1_000).count, 5)
        XCTAssertEqual(WatchdogForecastStep.horizonUnix(nowUnix: 1_000)[0], 1_060)
        XCTAssertEqual(WatchdogForecastStep.horizonUnix(nowUnix: 1_000)[4], 1_300)
        XCTAssertNotEqual(WatchdogForecastSource.student.rawValue, "official")
    }


    func testBackcastMatchesHorizonNotLastPresent() {
        let start = 1_000_000
        var obs = Array(repeating: Optional(60.0), count: 30)
        let nowSlot = 29
        obs[nowSlot] = 90
        let horizons = WatchdogForecastStep.horizonUnix(nowUnix: start + 28 * 60)
        XCTAssertEqual(horizons[0], start + 29 * 60)
        let pred = Array(repeating: 90.0, count: 5)
        let matched = WatchdogForecastRuntime.backcastEnergy(
            obs: obs, pred: pred, scale: Array(repeating: 5.0, count: 30),
            startUnix: start, horizons: horizons)
        XCTAssertEqual(matched, 0, accuracy: 1e-9)
        let lastPresent = Array(obs.compactMap { $0 }.suffix(5))
        var naive = 0.0
        for i in 0..<min(lastPresent.count, pred.count) {
            naive = max(naive, abs(lastPresent[i] - pred[i]) / 5.0)
        }
        XCTAssertGreaterThan(naive, 0)
    }


    func testYesterdayConfounderOnlyWhileSleepOpen() {
        var ill = LBDayLog()
        ill.feltIll = true
        XCTAssertTrue(ill.confoundsUsual)
        XCTAssertNil(Watchdog.liveDayLog(today: nil, yesterday: ill, sleepOpen: false))
        XCTAssertEqual(Watchdog.liveDayLog(today: nil, yesterday: ill, sleepOpen: true)?.feltIll, true)
        var today = LBDayLog()
        XCTAssertEqual(Watchdog.liveDayLog(today: today, yesterday: ill, sleepOpen: false)?.feltIll, false)
        today.feltIll = true
        XCTAssertEqual(Watchdog.liveDayLog(today: today, yesterday: nil, sleepOpen: false)?.feltIll, true)
    }

    func testTapeDoesNotTrainWhenTrainUsualIsFalse() {
        let now = 97_260_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        var tape = LBDayTape(day: "2026-10-01")
        XCTAssertFalse(tape.ingest(window: win, nowUnix: now, trainUsual: false))
        XCTAssertEqual(tape.restHR.n, 0)
        XCTAssertEqual(tape.allHR.n, 0)
    }

    func testShouldTrainUsualStopsOnQualityAndAlert() {
        let quiet = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: 97_270_000)
        XCTAssertFalse(Watchdog.shouldTrainUsual(result: quiet, dayLog: nil))
        var ill = LBDayLog()
        ill.feltIll = true
        let r = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                  nowUnix: 97_270_000, inject: .quiet)
        XCTAssertFalse(Watchdog.shouldTrainUsual(result: r, dayLog: ill))
        XCTAssertTrue(Watchdog.shouldTrainUsual(result: r, dayLog: nil))
    }

    func testSleepIntervalBlocksAwakeRestEvenIfLastRowIsAwake() {
        let now = 97_250_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        win.activityFeatures = (0..<30).map { _ in Array(repeating: 0.0, count: 20) }
        var tape = LBDayTape(day: "2026-10-01")
        let interval = WatchdogSleepInterval(startUnix: now - 3600, endUnix: now + 60)
        _ = tape.ingest(window: win, nowUnix: now, sleepIntervals: [interval])
        XCTAssertEqual(tape.restHR.n, 0)
        XCTAssertGreaterThan(tape.allHR.n, 0)
    }

    func testBandDoesNotMatureTempFromHeldSparseSample() {
        var state = WatchdogBandState.empty
        let present = [true, false, false, true, false, false]
        let residual = [0.2, 0, 0, 0.2, 0, 0]
        for i in 0..<14 {
            let now = 10_000 + i * 60
            let samples = [now, 0, 0, 1_000, 0, 0]
            _ = WatchdogBand.update(&state, absResidual: residual, eligible: true,
                                    nowUnix: now, present: present, sampleMinute: samples)
        }
        XCTAssertGreaterThanOrEqual(state.nPresent[0], WatchdogBand.firstMinutes)
        XCTAssertEqual(state.nPresent[3], 1)
        XCTAssertLessThan(state.nPresent[3], WatchdogBand.firstMinutes)
    }

    func testBandCountsNewChannelInSameWallMinute() {
        var state = WatchdogBandState.empty
        let now = 20_000
        _ = WatchdogBand.update(&state, absResidual: [0.2, 0, 0, 0, 0, 0], eligible: true,
                                nowUnix: now, present: [true, false, false, false, false, false],
                                sampleMinute: [now, 0, 0, 0, 0, 0])
        XCTAssertEqual(state.nPresent[0], 1)
        XCTAssertEqual(state.nPresent[3], 0)
        _ = WatchdogBand.update(&state, absResidual: [0.2, 0, 0, 0.2, 0, 0], eligible: true,
                                nowUnix: now + 20, present: [true, false, false, true, false, false],
                                sampleMinute: [now, 0, 0, now, 0, 0])
        XCTAssertEqual(state.nPresent[0], 1)
        XCTAssertEqual(state.nPresent[3], 1)
    }

    func testBandDoesNotCountSameCivilMinuteTwice() {
        var q = Array(repeating: 0.25, count: 6)
        var anchor = Array(repeating: 1.0, count: 6)
        var n = 0
        var ready = false
        var scale = Array(repeating: 1.0, count: 6)
        var last = 1_000_020
        var nPresent = Array(repeating: 0, count: 6)
        _ = WatchdogBand.update(absResidual: q, eligible: true, q: &q, anchor: &anchor,
                                n: &n, initialized: &ready, scale: &scale,
                                nowUnix: 1_000_050, lastUnix: &last, nPresent: &nPresent)
        XCTAssertEqual(n, 0)
        _ = WatchdogBand.update(absResidual: q, eligible: true, q: &q, anchor: &anchor,
                                n: &n, initialized: &ready, scale: &scale,
                                nowUnix: 1_000_080, lastUnix: &last, nPresent: &nPresent)
        XCTAssertEqual(n, 1)
    }

    func testSparseCoverageIsNotOneFromASinglePair() {
        var series = Array<Double?>(repeating: nil, count: 30)
        series[29] = 33.1
        let c = Watchdog.sparseCoverage(series, startUnix: 1_000_000, nowUnix: 1_001_740,
                                        channel: 3, family: .whoop4)
        XCTAssertLessThan(c, 0.1)
        XCTAssertGreaterThan(c, 0)
        XCTAssertNotEqual(c, 1.0, accuracy: 1e-9)
    }

    func testLiveOffMatchesSeveritySafetyAndPersonalOff() {
        XCTAssertFalse(Watchdog.liveOff(severity: .withinLimits, safety: false, personalOff: false))
        XCTAssertFalse(Watchdog.liveOff(severity: .note, safety: false, personalOff: false))
        XCTAssertTrue(Watchdog.liveOff(severity: .note, safety: false, personalOff: true))
        XCTAssertTrue(Watchdog.liveOff(severity: .candidate, safety: false, personalOff: false))
        XCTAssertTrue(Watchdog.liveOff(severity: .withinLimits, safety: true, personalOff: false))
        XCTAssertEqual(WatchdogCalibration.version, "prior-untuned")
        let quiet = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: 99_000_000, inject: .quiet)
        XCTAssertFalse(quiet.liveOff)
        let cap = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                    nowUnix: 99_000_100, inject: .severe)
        XCTAssertTrue(cap.liveOff)
        XCTAssertTrue(cap.qualityLine.contains("HR fill") || cap.qualityLine.contains("Safety"))
    }

    func testThinWindowRestHR135IsSafetySevere() throws {
        // v2.clinical (audit 2026-10-07): three fresh minutes at 135 in a thin window used to page "severe" from a
        // single-sample extreme. Safety now needs ≥ 10 sustained still minutes AND verified on-body / signal
        // quality; missing metadata holds (shown, never sent).
        let now = 97_300_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 135, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        var full = win
        if win.hr.count > 4 {
            for i in 0..<(win.hr.count - 3) { win.hr[i] = nil }
        }
        win.quality = .synthetic(for: win)
        let thin = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(), nowUnix: now)
        XCTAssertNotEqual(thin.severity, .severe)
        XCTAssertFalse(thin.shouldNotify, "3 minutes is not a sustained extreme")

        full.quality = .synthetic(for: full)
        let sustained = Watchdog.evaluate(window: .success(full), prompt: UniTSPrompt(), nowUnix: now)
        XCTAssertEqual(sustained.severity, .severe)
        XCTAssertTrue(sustained.shouldNotify)
        XCTAssertEqual(sustained.verdicts?.first(where: { $0.decision == .alert })?.candidate.kind, .safetyExtreme)
        let silent = Watchdog.evaluate(window: .success(full), prompt: UniTSPrompt(),
                                       nowUnix: now, liveAlerts: false)
        XCTAssertFalse(silent.shouldNotify)

        full.quality = .empty
        let unverified = Watchdog.evaluate(window: .success(full), prompt: UniTSPrompt(), nowUnix: now)
        XCTAssertEqual(unverified.severity, .candidate, "unknown sensor quality holds the candidate")
        XCTAssertFalse(unverified.shouldNotify)
    }

    func testSafetyHighLowIgnoresLoggedIllFreeze() {
        // v2: a sustained, verified still extreme is absolute: a logged-ill freeze of the personal usual does not
        // change it (and a single fresh minute never pages; see testThinWindowRestHR135IsSafetySevere).
        let now = 97_310_000
        let feed = Watchdog.syntheticFeed(now: now, hr: 135, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        win.quality = .synthetic(for: win)
        let asOf = "2026-06-15"
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 40)...(t - 1) {
            rows.append(LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(e),
                                           value: 60, qualityStatus: .ok))
        }
        var ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: rows, replay: false)
        ev.usualFreeze = LBUsualFreeze(t0CivilDay: asOf, tFreeze: asOf,
                                       reason: LBUsualFreeze.loggedIll, version: 2,
                                       centerLong: 60, spreadLong: 4, center7: 60, spread7: 4)
        let r = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(),
                                  evaluations: [ev], nowUnix: now)
        XCTAssertEqual(r.severity, .severe)
        XCTAssertTrue(r.verdicts?.contains { $0.candidate.kind == .safetyExtreme && $0.decision == .alert } ?? false)
    }

    func testPersonalNativeOffIndependentOfHat() {
        let asOf = "2026-06-15"
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...(t - 1) {
            rows.append(LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(e),
                                           value: 50, qualityStatus: .ok, coverage: 40))
        }
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .awakeRestHRVLn,
                                               observations: rows, replay: false)
        XCTAssertTrue(ev.establishedLong, ev.consoleReport)
        XCTAssertTrue(Watchdog.personalNativeOff(hrvMs: 12, evaluations: [ev]))
        XCTAssertFalse(Watchdog.personalNativeOff(hrvMs: 50, evaluations: [ev]))
    }

    func testPersonalOffUsesFrozenLongNotWalkedWeek() {
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
        ev.usualFreeze = LBUsualFreeze(t0CivilDay: asOf, tFreeze: asOf,
                                       reason: LBUsualFreeze.loggedIll, version: 2,
                                       centerLong: math50, spreadLong: 0.15,
                                       center7: math50, spread7: 0.15)
        XCTAssertTrue(Watchdog.personalNativeOff(hrvMs: 12, evaluations: [ev]))
        XCTAssertFalse(Watchdog.personalNativeOff(hrvMs: 50, evaluations: [ev]))
    }

    func testPersonalNativeOffHRAgainstSleepRHR() {
        let asOf = "2026-06-15"
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...(t - 1) {
            rows.append(LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(e),
                                           value: 60, qualityStatus: .ok))
        }
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: rows, replay: false)
        XCTAssertTrue(ev.establishedLong, ev.consoleReport)
        XCTAssertTrue(Watchdog.personalNativeOff(hrBpm: 90, hrvMs: nil, evaluations: [ev]))
        XCTAssertFalse(Watchdog.personalNativeOff(hrBpm: 60, hrvMs: nil, evaluations: [ev]))
    }

    func testSustainedPersonalOffIsCandidateEvenIfHatIsQuiet() {
        let note = WatchdogScores.severity(recon: 0, persistTicks: 0, safety: false,
                                           confounded: false, personalOff: true)
        XCTAssertEqual(note, .note)
        let sustained = WatchdogScores.severity(recon: 0, persistTicks: WatchdogCalibration.persistTicks,
                                                safety: false, confounded: false, personalOff: true)
        XCTAssertEqual(sustained, .candidate)
    }

    func testBackfillInjectDoesNotNotify() {
        let r = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                  nowUnix: 97_400_000, inject: .severe, liveAlerts: false)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertNotEqual(r.carry.notifyDelivery, "queued")
    }

    func testQueuedNotifyDoesNotDoublePage() {
        let lab = WatchdogEventLabel.abnormalMultiDirection
        let (again, reason) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 2.5, recon: 2.5, previousRecon: 2.5,
            eventLabel: lab, episodeId: "wd-1", notifiedSevereEpisodeId: "",
            notifyDelivery: "queued")
        XCTAssertFalse(again)
        XCTAssertEqual(reason, "in-flight")
    }

    func testDeniedNotifyIsRetryableAfterCooldown() {
        let lab = WatchdogEventLabel.abnormalMultiDirection
        let t = 3_000_000
        let (wait, rWait) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 2.5, recon: 2.5, previousRecon: 2.5,
            eventLabel: lab, episodeId: "wd-1", notifiedSevereEpisodeId: "",
            lastNotifiedAt: t, nowUnix: t + 40, notifyDelivery: "denied")
        XCTAssertFalse(wait)
        XCTAssertEqual(rWait, "retry-wait")
        let (retry, rRetry) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 2.5, recon: 2.5, previousRecon: 2.5,
            eventLabel: lab, episodeId: "wd-1", notifiedSevereEpisodeId: "",
            lastNotifiedAt: t, nowUnix: t + WatchdogConfig.notifyCooldownSeconds,
            notifyDelivery: "denied")
        XCTAssertTrue(retry)
        XCTAssertEqual(rRetry, "retry")
        XCTAssertTrue(WatchdogNotifyPolicy.retryable("failed"))
        XCTAssertFalse(WatchdogNotifyPolicy.retryable("sent"))
    }

    func testEvaluateDoesNotStampNotifiedUntilSent() {
        let r = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                  nowUnix: 97_410_000, inject: .severe)
        XCTAssertTrue(r.shouldNotify)
        XCTAssertEqual(r.carry.notifyDelivery, "queued")
        XCTAssertTrue(r.carry.notifiedSevereEpisodeId.isEmpty)
        var hold = r.carry
        hold.notifyDelivery = "queued"
        let again = Watchdog.evaluate(window: .failure(.empty), prompt: UniTSPrompt(),
                                      nowUnix: 97_410_020, previous: hold, inject: .severe)
        XCTAssertFalse(again.shouldNotify)
        XCTAssertEqual(again.notifyReason, "in-flight")
    }

    func testMigrateLnHRVBucket() {
        var tape = LBDayTape(day: "2026-10-01")
        tape.restHRV = LBMinuteBucket(sum: log(44), n: 1, lastMinuteUnix: 100)
        tape.migrateHrvFromLnIfNeeded()
        XCTAssertEqual(tape.restHRV.mean ?? 0, 44, accuracy: 1e-6)
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
        XCTAssertTrue(state.ready)
        XCTAssertTrue(WatchdogBand.channelReady(state, 0))
        XCTAssertFalse(WatchdogBand.channelReady(state, 3))
        XCTAssertEqual(state.nPresent[3], 0)
        XCTAssertEqual(state.q[3], 0, accuracy: 1e-12)
        XCTAssertEqual(state.scale[3], 1, accuracy: 1e-12)
        XCTAssertEqual(state.anchor[3], 1, accuracy: 1e-12)
    }

    func testTempFirstValueSeedsIndependentlyAfterHRReady() {
        var state = WatchdogBandState.empty
        let hrOnly = [true, false, false, false, false, false]
        for i in 0..<20 {
            let now = 40_000 + i * 60
            _ = WatchdogBand.update(&state, absResidual: [0.25, 0, 0, 0, 0, 0], eligible: true,
                                    nowUnix: now, present: hrOnly,
                                    sampleMinute: [now, 0, 0, 0, 0, 0])
        }
        let hrQ = state.q[0]
        let tempNow = 40_000 + 20 * 60
        _ = WatchdogBand.update(&state, absResidual: [0.25, 0, 0, 0.90, 0, 0], eligible: true,
                                nowUnix: tempNow, present: [true, false, false, true, false, false],
                                sampleMinute: [tempNow, 0, 0, tempNow, 0, 0])
        XCTAssertEqual(state.nPresent[3], 1)
        XCTAssertEqual(state.q[3], 0.90, accuracy: 1e-9)
        XCTAssertEqual(state.q[0], hrQ, accuracy: 1e-6)
        XCTAssertFalse(WatchdogBand.channelReady(state, 3))
        XCTAssertEqual(state.scale[3], 1, accuracy: 1e-12)
        let temp2 = tempNow + 60
        _ = WatchdogBand.update(&state, absResidual: [0.25, 0, 0, 1.20, 0, 0], eligible: true,
                                nowUnix: temp2, present: [true, false, false, true, false, false],
                                sampleMinute: [temp2, 0, 0, temp2, 0, 0])
        let ownAlpha = WatchdogBand.alpha(nElig: 2)
        let expected = (1 - ownAlpha) * 0.90 + ownAlpha * 1.20
        XCTAssertEqual(state.q[3], expected, accuracy: 1e-9)
        XCTAssertNotEqual(state.q[3], (1 - WatchdogBand.alpha(nElig: 22)) * 0.90
                          + WatchdogBand.alpha(nElig: 22) * 1.20, accuracy: 1e-4)
    }

    func testWriteDayFirstHRVDoesNotBlendFromZero() {
        var store = WatchdogPhaseUsualStore.empty
        let key = WatchdogPhaseKey(phase: .sleep, family: .still)
        let presentHR: [Bool] = [true, false, false, true, false, false]
        for i in 1...7 {
            store.writeDay(key: key, dayMedian: [62, 0, 0, 33.2, 0, 0],
                           present: presentHR, civilDay: String(format: "2026-09-%02d", i))
        }
        XCTAssertEqual(store.entries[key.id]?.center[2] ?? -1, 0, accuracy: 1e-9)
        store.writeDay(key: key, dayMedian: [63, 57, 46, 33.3, 14, 97],
                       present: [true, true, true, true, true, true],
                       civilDay: "2026-09-08")
        XCTAssertEqual(store.entries[key.id]?.center[2] ?? 0, 46, accuracy: 1e-9)
        XCTAssertEqual(store.entries[key.id]?.mad[2] ?? -1, 0, accuracy: 1e-9)
    }

    func testHrMinuteMeanDoesNotHideFreshHigh() {
        // v2 (audit 2026-10-07): a 20-second burst above 120 shows in the minute max but is not a sustained
        // extreme; it must not page (v1 paged on the single-sample minute max).
        let now = 97_400_000
        var feed = Watchdog.syntheticFeed(now: now, hr: 70, hrv: 44, temp: 33.0, resp: 14, motion: 0)
        feed.hr = feed.hr.map { sample in
            sample.ts >= now - 20 ? HRSample(ts: sample.ts, bpm: 135) : sample
        }
        guard case .success(var win) = WatchdogWindowBuilder.build(feed) else {
            return XCTFail("window")
        }
        let lastMean = try! XCTUnwrap(win.hr.last ?? nil)
        let lastMax = try! XCTUnwrap(win.hrMax.last ?? nil)
        XCTAssertLessThan(lastMean, WatchdogConfig.restHrHigh)
        XCTAssertGreaterThan(lastMax, WatchdogConfig.restHrHigh)
        win.quality = .synthetic(for: win)
        let r = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(), nowUnix: now)
        XCTAssertNotEqual(r.severity, .severe)
        XCTAssertFalse(r.shouldNotify)
    }

    func testMedian3KeepsSafetyBoundRMSSD() {
        let xs: [Double?] = [40, 6, 40]
        XCTAssertEqual(WatchdogWindowBuilder.median3(xs)[1], 6)
        XCTAssertEqual(WatchdogWindowBuilder.median3([40, 44, 42])[1], 42)
    }

    func testSafetyDurationSurvivesThinWindowTicks() {
        // v2: a thin window (coverage below the model gate) that still holds ≥ 10 sustained, verified still
        // minutes above 120 alerts through the quality-fail path, and the safety clock survives ticks.
        let now = 97_500_000
        func thin(_ t: Int) -> WatchdogWindow? {
            let feed = Watchdog.syntheticFeed(now: t, hr: 135, hrv: 44, temp: 33.0, resp: 14, motion: 0)
            guard case .success(var w) = WatchdogWindowBuilder.build(feed) else { return nil }
            if w.hr.count > 12 {
                for i in 0..<(w.hr.count - 12) { w.hr[i] = nil }
            }
            w.quality = .synthetic(for: w)
            return w
        }
        guard let win = thin(now) else { return XCTFail("window") }
        XCTAssertNotNil(WatchdogQuality.gate(win))
        let first = Watchdog.evaluate(window: .success(win), prompt: UniTSPrompt(), nowUnix: now)
        XCTAssertEqual(first.severity, .severe)
        XCTAssertEqual(first.qualityGate, "safety-during-quality-fail")
        XCTAssertEqual(first.carry.safetyFirstUnix, now)
        XCTAssertEqual(first.carry.safetyChannel, "HR")
        let laterNow = now + 90
        guard let later = thin(laterNow) else { return XCTFail("later window") }
        let second = Watchdog.evaluate(window: .success(later), prompt: UniTSPrompt(),
                                       nowUnix: laterNow, previous: first.carry)
        XCTAssertEqual(second.severity, .severe)
        XCTAssertEqual(second.carry.safetyFirstUnix, now)
        XCTAssertTrue(second.episodeLine.contains("held 90s"))
    }
}
