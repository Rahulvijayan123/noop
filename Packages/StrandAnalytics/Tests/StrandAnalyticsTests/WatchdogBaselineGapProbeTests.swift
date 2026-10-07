import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Basic Layer 1 + Watchdog probes for apparent implementation gaps.
/// Failures are product gaps — do not “fix” scoring to silence a probe without review.
final class WatchdogBaselineGapProbeTests: XCTestCase {

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

    // MARK: - Layer 1

    func testWeekAndLongShowGatesMatchPublishedCopyRules() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
        func ok(_ e: Int, _ v: Double) -> LBDailyObservation {
            LBDailyObservation(day: iso(e), value: v, qualityStatus: .ok)
        }

        let three = (1...3).map { ok(t - $0, 60) } + [ok(t, 60)]
        let threeEv = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                                    observations: three, replay: false)
        XCTAssertFalse(threeEv.show7, "week copy must stay hidden before 4 nights")
        XCTAssertFalse(threeEv.showLong)

        let fourWeek = (1...4).map { ok(t - $0, 60) } + [ok(t, 60)]
        let fourEv = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                                   observations: fourWeek, replay: false)
        XCTAssertTrue(fourEv.show7)
        XCTAssertFalse(fourEv.establishedLong)
        XCTAssertFalse(fourEv.alertEligible)

        let tenLongOnly = (8...17).map { ok(t - $0, 58) } + [ok(t, 62)]
        let tenEv = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                                  observations: tenLongOnly, replay: false)
        XCTAssertGreaterThanOrEqual(tenEv.nLong, 4)
        XCTAssertLessThan(tenEv.nLong, 14)
        XCTAssertTrue(tenEv.showLong, "code shows the long copy at nLongShow=4")
        XCTAssertFalse(tenEv.establishedLong, "established long is still 14")
    }

    func testSleepReadyDoesNotMakeTempReady() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
        let hr = (1...5).map {
            LBDailyObservation(day: iso(t - $0), value: 60, qualityStatus: .ok)
        } + [LBDailyObservation(day: iso(t), value: 60, qualityStatus: .ok)]
        let temp = [LBDailyObservation(day: iso(t - 1), value: 33.2, qualityStatus: .ok),
                    LBDailyObservation(day: iso(t), value: 33.1, qualityStatus: .ok)]
        let hrEv = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                                 observations: hr, replay: false)
        let tempEv = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepTemp,
                                                   observations: temp, replay: false)
        XCTAssertTrue(hrEv.show7)
        XCTAssertFalse(tempEv.show7)
        XCTAssertFalse(tempEv.showLong)
    }

    func testStepsWeekShowsAtFourEvenThoughLongEstablishIsTwentyOne() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
        let rows = (1...4).map {
            LBDailyObservation(day: iso(t - $0), value: 8_000, qualityStatus: .ok, coverage: 1)
        } + [LBDailyObservation(day: iso(t), value: 8_000, qualityStatus: .ok, coverage: 1)]
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .wakingSteps,
                                               observations: rows, replay: false)
        XCTAssertEqual(LongitudinalBaseline.nLongEstablished(for: .wakingSteps), 21)
        XCTAssertTrue(ev.show7, "week gate is global n7Show=4, including steps")
        XCTAssertFalse(ev.establishedLong)
    }

    func testDailyMetricSpO2MeanDoesNotFillNadir() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let days = (1...8).map { i in
            DailyMetric(day: LongitudinalBaseline.isoFromEpochDay(t - i),
                        totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 58, avgHrv: 50,
                        recovery: nil, strain: nil, exerciseCount: nil, spo2Pct: 96,
                        skinTempDevC: nil, respRateBpm: 14, steps: 8000, avgSdnn: nil,
                        skinTempC: 33.1, sleepHrOnly: nil)
        }
        XCTAssertFalse(LongitudinalBaseline.observations(from: days, series: .sleepSpO2Mean).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: days, series: .sleepSpO2Nadir).isEmpty)
    }

    // MARK: - Watchdog

    func testOneFilledWindowCountsLastMinuteNotThirty() {
        let now = 95_000_000
        let r = still(now: now, previous: .empty)
        XCTAssertGreaterThan(r.signals.contains { $0.observed != nil } ? 1 : 0, 0)
        XCTAssertEqual(r.carry.presentMinutes(channel: 0), 1,
                       "a 30-bin window still credits one civil minute (the last finite)")
        XCTAssertFalse(r.carry.channelBandReady(0))
    }

    func testFeltIllDoesNotAdvanceBandMinutes() {
        var ill = LBDayLog()
        ill.feltIll = true
        XCTAssertTrue(ill.confoundsUsual)
        var carry = WatchdogCarry.empty
        let t0 = 95_100_000
        for i in 0..<14 {
            let r = Watchdog.evaluate(
                window: WatchdogWindowBuilder.build(
                    Watchdog.syntheticFeed(now: t0 + i * 60, hr: 58, hrv: 48,
                                           temp: 33.1, resp: 14, motion: 0)),
                prompt: prompt, dayLog: ill, nowUnix: t0 + i * 60, previous: carry)
            carry = r.carry
        }
        XCTAssertEqual(carry.presentMinutes(channel: 0), 0)
        XCTAssertFalse(carry.channelBandReady(0))
        XCTAssertFalse(Watchdog.shouldTrainUsual(
            result: Watchdog.evaluate(window: .failure(.empty), prompt: prompt,
                                      dayLog: ill, nowUnix: t0 + 900),
            dayLog: ill))
    }

    func testMissingLastBandKeyMustNotBorrowAnotherKeysMinutes() {
        var still = WatchdogBandState.empty
        let hrOnly = [true, false, false, false, false, false]
        for i in 0..<14 {
            let now = 60_000 + i * 60
            _ = WatchdogBand.update(&still, absResidual: [0.2, 0, 0, 0, 0, 0], eligible: true,
                                    nowUnix: now, present: hrOnly,
                                    sampleMinute: [now, 0, 0, 0, 0, 0])
        }
        XCTAssertTrue(WatchdogBand.channelReady(still, 0))

        var carry = WatchdogCarry.empty
        carry.bandByKey["still"] = still
        carry.lastBandKey = "artifact-or-other"
        XCTAssertNil(carry.bandByKey[carry.lastBandKey])
        XCTAssertEqual(carry.presentMinutes(channel: 0), 0,
                       "UI minutes must follow the current key, not max(other keys)")
        XCTAssertFalse(carry.channelBandReady(0))
    }

    func testEmptyLastBandKeyKeepsStoredMinutesOnReopen() {
        var still = WatchdogBandState.empty
        let hrOnly = [true, false, false, false, false, false]
        for i in 0..<14 {
            let now = 70_000 + i * 60
            _ = WatchdogBand.update(&still, absResidual: [0.2, 0, 0, 0, 0, 0], eligible: true,
                                    nowUnix: now, present: hrOnly,
                                    sampleMinute: [now, 0, 0, 0, 0, 0])
        }
        var carry = WatchdogCarry.empty
        carry.bandByKey["still"] = still
        carry.lastBandKey = ""
        XCTAssertEqual(carry.presentMinutes(channel: 0), 14)
        XCTAssertTrue(carry.channelBandReady(0))
    }

    func testLegacyBandNWithoutNPresentIsNotChannelReady() {
        var carry = WatchdogCarry.empty
        carry.bandN = 20
        carry.bandReady = true
        carry.bandByKey = [:]
        carry.lastBandKey = ""
        let key = WatchdogPhaseKey(phase: .midday, family: .still)
        carry.migrateLegacyBandIfNeeded(into: key)
        XCTAssertFalse(carry.bandByKey.isEmpty)
        XCTAssertEqual(carry.presentMinutes(channel: 0), 0,
                       "legacy bandN does not copy nPresent; the live card would stay Live")
        XCTAssertFalse(carry.channelBandReady(0))
    }

    func testEvaluateDoesNotRewriteLayer1Centers() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let rows = (1...20).map {
            LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(t - $0),
                               value: 60, qualityStatus: .ok)
        }
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: rows, replay: false)
        let before7 = ev.copy7?.center
        let beforeLong = ev.copyLong?.center
        let now = 95_200_000
        _ = Watchdog.evaluate(
            window: WatchdogWindowBuilder.build(
                Watchdog.syntheticFeed(now: now, hr: 62, hrv: 44, temp: 33.0, resp: 14, motion: 0)),
            prompt: prompt, evaluations: [ev], nowUnix: now)
        XCTAssertEqual(ev.copy7?.center, before7)
        XCTAssertEqual(ev.copyLong?.center, beforeLong)
    }

    func testWristOffDoesNotResolveOrTrain() {
        var carry = WatchdogCarry.empty
        let t0 = 95_300_000
        for i in 0..<5 {
            let r = still(now: t0 + i * 60, previous: carry)
            carry = r.carry
        }
        let minutes = carry.presentMinutes(channel: 0)
        let off = Watchdog.evaluate(window: .failure(.wristOff), prompt: prompt,
                                    nowUnix: t0 + 400, previous: carry)
        XCTAssertEqual(off.severity, .dataUnavailable)
        XCTAssertNotEqual(off.episodeState, .resolved)
        XCTAssertEqual(off.carry.presentMinutes(channel: 0), minutes)
        XCTAssertFalse(Watchdog.shouldTrainUsual(result: off, dayLog: nil))
    }

    func testQuietStillHasLiveObservationBeforeGreen() {
        let r = still(now: 95_400_000, previous: .empty)
        XCTAssertNotNil(r.reconstructedHR.last)
        XCTAssertFalse(r.carry.channelBandReady(0))
        XCTAssertFalse(r.liveOff)
    }

    private func still(now: Int, previous: WatchdogCarry) -> WatchdogResult {
        Watchdog.evaluate(window: WatchdogWindowBuilder.build(
            Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: 0)),
                          prompt: prompt, nowUnix: now, previous: previous)
    }
}
