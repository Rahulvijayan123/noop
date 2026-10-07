import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Last pass before Rahul handoff. New cases, not copies of V40 / Prime names.
final class WatchdogPreHandoffSweepTests: XCTestCase {

    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)
    private let asOf = "2026-06-15"

    override func setUp() {
        super.setUp()
        WatchdogForecastRuntime.testPredict = .some(nil)
    }

    override func tearDown() {
        WatchdogForecastRuntime.testPredict = nil
        super.tearDown()
    }

    // MARK: - Display helper (G1) + reopen

    func testWalkKeyDoesNotInheritStillGreen() {
        var still = WatchdogBandState.empty
        let hr = [true, false, false, false, false, false]
        for i in 0..<14 {
            let t = 80_000 + i * 60
            _ = WatchdogBand.update(&still, absResidual: [0.2, 0, 0, 0, 0, 0], eligible: true,
                                    nowUnix: t, present: hr, sampleMinute: [t, 0, 0, 0, 0, 0])
        }
        var walk = WatchdogBandState.empty
        for i in 0..<3 {
            let t = 90_000 + i * 60
            _ = WatchdogBand.update(&walk, absResidual: [0.2, 0, 0, 0, 0, 0], eligible: true,
                                    nowUnix: t, present: hr, sampleMinute: [t, 0, 0, 0, 0, 0])
        }
        var carry = WatchdogCarry.empty
        carry.bandByKey["still"] = still
        carry.bandByKey["walk"] = walk
        carry.lastBandKey = "walk"
        XCTAssertEqual(carry.presentMinutes(channel: 0), 3)
        XCTAssertFalse(carry.channelBandReady(0))
        carry.lastBandKey = "missing"
        XCTAssertEqual(carry.presentMinutes(channel: 0), 0)
        carry.lastBandKey = ""
        XCTAssertEqual(carry.presentMinutes(channel: 0), 14)
        XCTAssertTrue(carry.channelBandReady(0))
    }

    func testFourteenSameMinuteTicksDoNotReadyBand() {
        var carry = WatchdogCarry.empty
        let t0 = 81_000_000
        for i in 0..<14 {
            let r = still(now: t0 + i * 20, previous: carry)
            carry = r.carry
        }
        XCTAssertLessThan(carry.presentMinutes(channel: 0), WatchdogBand.firstMinutes)
        XCTAssertFalse(carry.channelBandReady(0))
    }

    // MARK: - Layer 1

    func testWeekFeverDoesNotMoveLongMedian() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
        var rows: [LBDailyObservation] = []
        for e in (t - 40)...(t - 8) {
            rows.append(LBDailyObservation(day: iso(e), value: 60, qualityStatus: .ok))
        }
        for e in (t - 7)...t {
            rows.append(LBDailyObservation(day: iso(e), value: 78, qualityStatus: .ok))
        }
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: rows, replay: false)
        XCTAssertTrue(ev.show7)
        XCTAssertNotNil(ev.copy7)
        XCTAssertNotNil(ev.copyLong)
        let week = ev.copy7!.center
        let long = ev.copyLong!.center
        XCTAssertGreaterThan(week, long + 4, ev.consoleReport)
        XCTAssertNotEqual((week + long) / 2, week, accuracy: 0.5)
        XCTAssertNotEqual(week, long, accuracy: 0.5)
    }

    func testHowOffHiddenUnderTrust35() {
        XCTAssertEqual(LongitudinalBaseline.trustHideThreshold, 35)
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let thin = (1...3).map {
            LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(t - $0),
                               value: 60, qualityStatus: .ok)
        }
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: thin, replay: false)
        XCTAssertFalse(ev.show7)
        XCTAssertLessThan(ev.usualTrustPct7, 35)
    }

    func testSleepColumnDoesNotFillAwakeRestFromDailyMetric() {
        let day = DailyMetric(day: asOf, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                              remMin: nil, lightMin: nil, disturbances: nil, restingHr: 58,
                              avgHrv: 50, recovery: nil, strain: nil, exerciseCount: nil,
                              spo2Pct: 96, skinTempDevC: nil, respRateBpm: 14, steps: 9000,
                              avgSdnn: nil, skinTempC: 33.1, sleepHrOnly: nil)
        XCTAssertFalse(LongitudinalBaseline.observations(from: [day], series: .sleepRHR).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: [day], series: .awakeRestHR).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: [day], series: .sleepSpO2Nadir).isEmpty)
    }

    /// Current code: `personalReference` accepts `showLong` (4-night preview), not only established (14).
    /// Logged as G5 — do not change Off unless Chinmay asks.
    func testPersonalOffCurrentlyFiresOnShowLongPreview() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
        let preview = (8...15).map {
            LBDailyObservation(day: iso(t - $0), value: 60, qualityStatus: .ok)
        }
        var ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: preview, replay: false)
        XCTAssertTrue(ev.showLong, ev.consoleReport)
        XCTAssertFalse(ev.establishedLong, ev.consoleReport)
        XCTAssertTrue(Watchdog.personalNativeOff(hrBpm: 90, hrvMs: nil, evaluations: [ev]),
                      "today personal-off uses showLong; G5 would require establishedLong")

        let mature = (8...30).map {
            LBDailyObservation(day: iso(t - $0), value: 60, qualityStatus: .ok)
        }
        ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                           observations: mature, replay: false)
        XCTAssertTrue(ev.establishedLong, ev.consoleReport)
        XCTAssertTrue(Watchdog.personalNativeOff(hrBpm: 90, hrvMs: nil, evaluations: [ev]))
        XCTAssertFalse(Watchdog.personalNativeOff(hrBpm: 60, hrvMs: nil, evaluations: [ev]))
    }

    func testPersonalOffIgnoresWalkingWeekWhenLongHidden() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
        var rows: [LBDailyObservation] = []
        for e in (t - 7)...t {
            rows.append(LBDailyObservation(day: iso(e), value: 50, qualityStatus: .ok))
        }
        var ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: rows, replay: false)
        XCTAssertTrue(ev.show7)
        ev.showLong = false
        ev.establishedLong = false
        ev.copyLong = nil
        ev.usualFreeze = nil
        XCTAssertFalse(Watchdog.personalNativeOff(hrBpm: 90, hrvMs: nil, evaluations: [ev]))
    }

    // MARK: - Live Watchdog

    func testEvaluateLeavesLayer1CentersAlone() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let rows = (1...20).map {
            LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(t - $0),
                               value: 61, qualityStatus: .ok)
        }
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: rows, replay: false)
        let c7 = ev.copy7?.center
        let cL = ev.copyLong?.center
        let now = 82_000_000
        _ = still(now: now, previous: .empty, evaluations: [ev])
        XCTAssertEqual(ev.copy7?.center, c7)
        XCTAssertEqual(ev.copyLong?.center, cL)
    }

    func testFeltIllStopsBandAndTape() {
        var ill = LBDayLog()
        ill.feltIll = true
        var carry = WatchdogCarry.empty
        let t0 = 82_100_000
        for i in 0..<8 {
            let r = Watchdog.evaluate(
                window: WatchdogWindowBuilder.build(
                    Watchdog.syntheticFeed(now: t0 + i * 60, hr: 58, hrv: 48,
                                           temp: 33.1, resp: 14, motion: 0)),
                prompt: prompt, dayLog: ill, nowUnix: t0 + i * 60, previous: carry)
            carry = r.carry
        }
        XCTAssertEqual(carry.presentMinutes(channel: 0), 0)
        let quiet = Watchdog.evaluate(window: .failure(.empty), prompt: prompt,
                                      dayLog: ill, nowUnix: t0 + 500)
        XCTAssertFalse(Watchdog.shouldTrainUsual(result: quiet, dayLog: ill))
    }

    func testWristOffIsUnavailableAndDoesNotResolve() {
        var carry = WatchdogCarry.empty
        carry.episodeId = "wd-open"
        carry.priorState = .active
        carry.consecutiveInRangeTicks = 1
        let r = Watchdog.evaluate(window: .failure(.wristOff), prompt: prompt,
                                  nowUnix: 82_200_000, previous: carry)
        XCTAssertEqual(r.severity, .dataUnavailable)
        XCTAssertNotEqual(r.episodeState, .resolved)
        XCTAssertFalse(r.shouldNotify)
        XCTAssertFalse(Watchdog.shouldTrainUsual(result: r, dayLog: nil))
    }

    func testLiveOffDoorsAndBackfillSilent() {
        XCTAssertTrue(Watchdog.liveOff(severity: .candidate, safety: false, personalOff: false))
        XCTAssertTrue(Watchdog.liveOff(severity: .withinLimits, safety: true, personalOff: false))
        XCTAssertTrue(Watchdog.liveOff(severity: .note, safety: false, personalOff: true))
        XCTAssertFalse(Watchdog.liveOff(severity: .note, safety: false, personalOff: false))
        let silent = Watchdog.evaluate(window: .failure(.empty), prompt: prompt,
                                       nowUnix: 82_300_000, inject: .severe, liveAlerts: false)
        XCTAssertFalse(silent.shouldNotify)
    }

    func testFirstSeverePagesOnce() {
        let lab = WatchdogEventLabel.abnormalMultiDirection
        let (a, r1) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 1.7, recon: 2.5, previousRecon: 1.7,
            eventLabel: lab, episodeId: "wd-h", notifiedSevereEpisodeId: "")
        XCTAssertTrue(a)
        XCTAssertEqual(r1, "first-severe")
        let (b, r2) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 2.5, previousFused: 2.5, recon: 2.5, previousRecon: 2.5,
            eventLabel: lab, episodeId: "wd-h", notifiedSevereEpisodeId: "wd-h")
        XCTAssertFalse(b)
        XCTAssertEqual(r2, "stable-episode")
    }

    func testStaleTempStillPaintsUntilItLeavesTheWindow() {
        let now = 82_500_000
        let prompt = self.prompt
        guard case .success(let full) = WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)) else {
            return XCTFail("window")
        }
        let first = Watchdog.evaluate(window: .success(full), prompt: prompt, nowUnix: now)
        XCTAssertTrue(first.horizonTemp.contains(where: \.isFinite))
        let firstTrust = first.signals.first(where: { $0.name == "Temp" })?.trustPct ?? 0
        XCTAssertGreaterThan(firstTrust, 0)

        var shown = full
        shown.temp = shown.temp.enumerated().map { i, v in i < 18 ? v : nil }
        var wiped = shown
        wiped.maskStaleChannels()
        XCTAssertFalse(wiped.temp.contains { $0 != nil })
        XCTAssertTrue(shown.temp.contains { $0 != nil })

        let held = Watchdog.evaluate(window: .success(shown), prompt: prompt,
                                     nowUnix: now + 20, previous: first.carry)
        XCTAssertTrue(held.horizonTemp.contains(where: \.isFinite))
        XCTAssertEqual(held.signals.first(where: { $0.name == "Temp" })?.trustPct, firstTrust)
        XCTAssertEqual(held.signals.first(where: { $0.name == "Temp" })?.observed ?? -1, 33.1, accuracy: 0.01)
    }

    func testStudentsAreNotOfficial() {
        XCTAssertFalse(WatchdogConfig.modelVersion.lowercased().contains("official"))
        XCTAssertFalse(WatchdogConfig.forecastModelVersion.lowercased().contains("official"))
        XCTAssertTrue(WatchdogConfig.forecastModelVersion.contains("student"))
    }

    // MARK: - Sidecars

    func testQueuedPageDoesNotOpenSurveyOrLedger() {
        var notes: [WatchdogEpisodeAnnotation] = []
        notes = WatchdogEpisodeAnnotation.pendingIfNeeded(
            existing: notes, episodeId: "wd-q", deviceId: "s",
            eventUnix: 10, delivery: "queued", liveAlerts: true)
        XCTAssertTrue(notes.isEmpty)
        let ev = Watchdog.evaluate(window: .failure(.empty), prompt: prompt,
                                   nowUnix: 82_400_000, inject: .severe, liveAlerts: false)
        let ledger = WatchdogEpisodeLedger.upsert(rows: [], result: ev, deviceId: "s",
                                                  nowUnix: 82_400_000, liveAlerts: false)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testExportKeepsTwoCopiesAndStudentBanner() {
        let week = LBCopySnapshot(center: 61, spread: 3, centerDisplay: 61,
                                  bandLoDisplay: 55, bandHiDisplay: 67, n: 7,
                                  coverage: 40, version: "t", held: false)
        let long = LBCopySnapshot(center: 58, spread: 4, centerDisplay: 58,
                                  bandLoDisplay: 50, bandHiDisplay: 66, n: 40,
                                  coverage: 40, version: "t", held: false)
        var ev = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: [LBDailyObservation(day: asOf, value: 60, qualityStatus: .ok)],
            replay: false)
        ev.series = .sleepRHR
        ev.copy7 = week
        ev.copyLong = long
        ev.show7 = true
        ev.showLong = true
        let pack = WatchdogClinicianExport.build(
            deviceId: "s", startUnix: 0, endUnix: 10, ledger: [],
            evaluations: [ev], dayLogs: [:], annotations: [], recovery: nil)
        XCTAssertTrue(pack.versionLine.contains("student"))
        XCTAssertFalse(pack.versionLine.lowercased().contains("official"))
        XCTAssertTrue(pack.copyLines.contains(where: { $0.contains("week") }))
        XCTAssertTrue(pack.copyLines.contains(where: { $0.contains("long") }))
    }

    func testChairFidgetIsStillAndUnknownRestCountsForTheBand() {
        XCTAssertEqual(WatchdogPhaseUsualStore.bandFamily(label: .normalStillAwake, cls: .unknown,
                                                          tailPeriod: .unknown), .still)
        XCTAssertEqual(WatchdogPhaseUsualStore.bandFamily(label: .normalStillAwake, cls: .unknown,
                                                          tailPeriod: .rest), .still)
        XCTAssertEqual(WatchdogPhaseUsualStore.bandFamily(label: .normalStillAwake, cls: .unknown,
                                                          tailPeriod: .effort), .other)
        XCTAssertEqual(WatchdogPhaseUsualStore.bandFamily(label: .artifactSpike, cls: .unknown,
                                                          tailPeriod: .rest), .other)
        XCTAssertEqual(WatchdogLiveTail.period(cls: .still, motion: 0.20), .rest)
        XCTAssertEqual(WatchdogLiveTail.period(cls: .still, motion: 0.40), .effort)
        let now = 83_000_000
        let start = now - 1800
        let imu = (0..<30).map { i in
            WatchdogIMUSample(ts: start + i * 60 + 10, x: 0.02, y: 0.01, z: 0.99, dynAccel: 0.08)
        }
        let motion = Array(repeating: Optional(0.20), count: 30)
        let hr = Array(repeating: Optional(62.0), count: 30)
        let logits = WatchdogActivityRuntime.embed(motion: motion, hr: hr, steps: [], imu: imu,
                                                   startUnix: start, nowUnix: now)
        let last = WatchdogActivityClass.labels(logits: logits).last
        XCTAssertTrue(last == "still" || last == "stand", last ?? "nil")
    }

    private func still(now: Int, previous: WatchdogCarry,
                       evaluations: [LBEvaluation] = []) -> WatchdogResult {
        Watchdog.evaluate(window: WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)),
                          prompt: prompt, evaluations: evaluations, nowUnix: now, previous: previous)
    }
}
