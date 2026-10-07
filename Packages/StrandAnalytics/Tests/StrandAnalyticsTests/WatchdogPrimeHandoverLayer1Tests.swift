import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Prime handover pins for Layer 1 (`docs/baselines/PRIME_HANDOVER.md` §1).
/// Readiness is `LongitudinalBaseline.evaluate` show7 / showLong / n7 / nLong — not BaselineStore.
final class WatchdogPrimeHandoverLayer1Tests: XCTestCase {

    let asOf = "2026-06-15"

    func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }

    func ok(_ day: String, _ value: Double, series: LBSeries = .sleepRHR) -> LBDailyObservation {
        let coverage: Double?
        switch series {
        case .awakeRestHR, .awakeRestHRVLn: coverage = 40
        default: coverage = nil
        }
        return LBDailyObservation(day: day, value: value, qualityStatus: .ok, coverage: coverage)
    }

    func eval(_ series: LBSeries, obs: [LBDailyObservation],
              trial: LBTrialRequest = .none) -> LBEvaluation {
        LongitudinalBaseline.evaluate(asOf: asOf, series: series, observations: obs,
                                      replay: false, trial: trial)
    }

    func testWeekAndLongCentersStayDistinctOnFeverTape() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...(t - 8) {
            rows.append(ok(iso(e), 60))
        }
        for e in (t - 7)...(t - 1) {
            rows.append(ok(iso(e), 72))
        }
        rows.append(ok(iso(t), 72))
        let ev = eval(.sleepRHR, obs: rows)
        XCTAssertTrue(ev.show7, ev.consoleReport)
        XCTAssertTrue(ev.showLong, ev.consoleReport)
        let week = try! XCTUnwrap(ev.copy7?.center)
        let long = try! XCTUnwrap(ev.copyLong?.center)
        XCTAssertEqual(long, 60, accuracy: 0.5, ev.consoleReport)
        XCTAssertGreaterThan(week, 65, ev.consoleReport)
        XCTAssertNotEqual(week, long, accuracy: 0.2)
        let blended = (week + long) / 2
        XCTAssertGreaterThan(abs(week - blended), 0.04)
        XCTAssertGreaterThan(abs(long - blended), 0.04)
        XCTAssertEqual(ev.todayNative ?? -1, 72, accuracy: 1e-6)
    }

    func testThreeNightsHideWeekFourShowNotAlertEligible() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let three = [
            ok(iso(t - 3), 60), ok(iso(t - 2), 60), ok(iso(t - 1), 60), ok(iso(t), 72)
        ]
        let hidden = eval(.sleepRHR, obs: three)
        XCTAssertEqual(hidden.n7, 3, hidden.consoleReport)
        XCTAssertFalse(hidden.show7)
        XCTAssertNil(hidden.copy7)
        XCTAssertFalse(hidden.alertEligible)

        let four = (1...4).map { ok(iso(t - $0), 60) } + [ok(iso(t), 60)]
        let shown = eval(.sleepRHR, obs: four)
        XCTAssertEqual(shown.n7, 4, shown.consoleReport)
        XCTAssertTrue(shown.show7)
        XCTAssertFalse(shown.alertEligible)
        XCTAssertFalse(shown.establishedLong)
        XCTAssertFalse(shown.showLong)
    }

    func testIllnessNightDoesNotRefreshLastOK() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...(t - 20) {
            rows.append(ok(iso(e), 60))
        }
        rows.append(ok(iso(t - 1), 88))
        var ill = LBDayLog()
        ill.feltIll = true
        let ev = eval(.sleepRHR, obs: rows, trial: LBTrialRequest(dayLogsByDay: [iso(t - 1): ill]))
        XCTAssertEqual(ev.carry.lastQualityOKEpoch, t - 20)
        XCTAssertTrue(ev.stale, ev.consoleReport)
        XCTAssertNotEqual(ev.copy7?.lastUpdate, iso(t - 1))
    }

    func testExtraMedDropsNightScheduledTakenDoesNot() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let v = 60.0
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...t { rows.append(ok(iso(e), v)) }
        let dirtyDay = iso(t - 20)
        let extra = eval(.sleepRHR, obs: rows, trial: LBTrialRequest(
            dayLogsByDay: [dirtyDay: LBDayLog(extraMed: true)]))
        XCTAssertEqual(extra.nLong, 52, extra.consoleReport)
        XCTAssertTrue(LBDayLog(extraMed: true).confoundsUsual)
        let taken = eval(.sleepRHR, obs: rows, trial: LBTrialRequest(
            dayLogsByDay: [dirtyDay: LBDayLog(scheduledMed: .taken)]))
        XCTAssertEqual(taken.nLong, 53, taken.consoleReport)
        XCTAssertFalse(LBDayLog(scheduledMed: .taken).confoundsUsual)
    }

    func testSleepRHRObservationsNeverEnterAwakeRest() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let days: [DailyMetric] = (0..<8).map { i in
            DailyMetric(day: iso(t - i),
                        totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 58, avgHrv: 50,
                        recovery: nil, strain: nil, exerciseCount: nil, spo2Pct: 97,
                        skinTempDevC: nil, respRateBpm: 14, steps: 8_000, avgSdnn: nil,
                        skinTempC: 33.2, sleepHrOnly: nil)
        }
        let sleep = LongitudinalBaseline.observations(from: days, series: .sleepRHR)
        let rest = LongitudinalBaseline.observations(from: days, series: .awakeRestHR)
        XCTAssertFalse(sleep.isEmpty)
        XCTAssertTrue(rest.isEmpty)
        let sleepEv = eval(.sleepRHR, obs: sleep)
        let restEv = eval(.awakeRestHR, obs: rest)
        XCTAssertGreaterThan(sleepEv.n7, 0, sleepEv.consoleReport)
        XCTAssertEqual(restEv.n7, 0, restEv.consoleReport)
        XCTAssertFalse(restEv.show7)
        XCTAssertNil(restEv.todayNative)
    }

    func testZeroAndNilStepsAreNotTrainedAsOk() {
        let missing = LongitudinalBaseline.observation(
            day: asOf, native: nil, streamPresent: true, sleepHrOnly: false, series: .wakingSteps)
        XCTAssertEqual(missing.qualityStatus, .missing)
        XCTAssertNotEqual(missing.qualityStatus, .ok)
        XCTAssertNil(missing.value)
        XCTAssertNil(LongitudinalBaseline.trainableNative(missing, series: .wakingSteps))

        let absent = LongitudinalBaseline.observation(
            day: asOf, native: nil, streamPresent: false, sleepHrOnly: false, series: .wakingSteps)
        XCTAssertEqual(absent.qualityStatus, .missing)
        XCTAssertNil(LongitudinalBaseline.trainableNative(absent, series: .wakingSteps))

        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 4)...(t - 1) {
            rows.append(missing)
            rows[rows.count - 1] = LongitudinalBaseline.observation(
                day: iso(e), native: nil, streamPresent: true, sleepHrOnly: false, series: .wakingSteps)
        }
        rows.append(ok(iso(t), 8_000, series: .wakingSteps))
        let ev = eval(.wakingSteps, obs: rows)
        XCTAssertEqual(ev.n7, 0, ev.consoleReport)
        XCTAssertFalse(ev.show7)
        XCTAssertNil(LongitudinalBaseline.trainableNative(
            LBDailyObservation(day: asOf, value: 0, qualityStatus: .missing), series: .wakingSteps))
    }

    func testFeltIllFreezesWithoutResettingLong() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        var logs: [String: LBDayLog] = [:]
        for e in (t - 40)...(t - 1) {
            rows.append(ok(iso(e), 60))
        }
        rows.append(ok(iso(t), 88))
        logs[iso(t)] = {
            var ill = LBDayLog()
            ill.feltIll = true
            return ill
        }()
        let ev = eval(.sleepRHR, obs: rows, trial: LBTrialRequest(dayLogsByDay: logs))
        let freeze = try! XCTUnwrap(ev.usualFreeze, ev.consoleReport)
        XCTAssertEqual(freeze.reason, LBUsualFreeze.loggedIll)
        XCTAssertEqual(freeze.centerLong, 60, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(ev.nLong, 14, ev.consoleReport)
        XCTAssertTrue(ev.establishedLong, ev.consoleReport)
    }

    func testWeekVsLongSplitWithoutLogDoesNotFreeze() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 40)...(t - 12) {
            rows.append(ok(iso(e), 60))
        }
        for e in (t - 11)...t {
            rows.append(ok(iso(e), 88))
        }
        let ev = eval(.sleepRHR, obs: rows)
        XCTAssertNil(ev.usualFreeze, ev.consoleReport)
        XCTAssertTrue(ev.establishedLong, ev.consoleReport)
        XCTAssertNotEqual(ev.copy7?.center ?? 0, ev.copyLong?.center ?? 0, accuracy: 0.5)
    }

    func testReadinessMapDoesNotHideReadySeries() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let rhr = (1...4).map { ok(iso(t - $0), 60) } + [ok(iso(t), 62)]
        let temp = [ok(iso(t - 1), 33.2, series: .sleepTemp), ok(iso(t), 33.4, series: .sleepTemp)]
        let hrEv = eval(.sleepRHR, obs: rhr)
        let tempEv = eval(.sleepTemp, obs: temp)
        XCTAssertEqual(hrEv.asOf, tempEv.asOf)
        XCTAssertTrue(hrEv.show7, hrEv.consoleReport)
        XCTAssertGreaterThanOrEqual(hrEv.n7, 4)
        XCTAssertFalse(tempEv.show7, tempEv.consoleReport)
        XCTAssertEqual(tempEv.n7, 1)
        let map: [(LBSeries, Bool)] = [
            (hrEv.series, hrEv.show7 || hrEv.showLong),
            (tempEv.series, tempEv.show7 || tempEv.showLong)
        ]
        XCTAssertTrue(map.contains { $0.0 == .sleepRHR && $0.1 })
        XCTAssertTrue(map.contains { $0.0 == .sleepTemp && !$0.1 })
    }

    func testPreferReadyDoesNotOverrideSelectSeries() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let rhr = (1...4).map { ok(iso(t - $0), 60) } + [ok(iso(t), 62)]
        let temp = [ok(iso(t - 1), 33.2, series: .sleepTemp), ok(iso(t), 33.4, series: .sleepTemp)]
        let hrEv = eval(.sleepRHR, obs: rhr)
        let tempEv = eval(.sleepTemp, obs: temp)
        let auto = [hrEv, tempEv].first { $0.show7 || $0.showLong }
        XCTAssertEqual(auto?.series, .sleepRHR)
        let selected = tempEv
        XCTAssertEqual(selected.series, .sleepTemp)
        XCTAssertFalse(selected.show7, "wearer tap keeps the unreadied series")
        XCTAssertTrue(hrEv.show7)
    }
}
