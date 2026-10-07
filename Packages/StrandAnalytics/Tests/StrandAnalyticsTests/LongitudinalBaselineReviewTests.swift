import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Acceptance pack for FRWHOOP_BASELINE_REVIEW_CHANGES.md (all eight, equal gate).
final class LongitudinalBaselineReviewTests: XCTestCase {

    let asOf = "2026-06-01"
    func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
    func ok(_ day: String, _ v: Double) -> LBDailyObservation {
        LBDailyObservation(day: day, value: v, qualityStatus: .ok)
    }

    func tape(values: [(offset: Int, value: Double)], t: String) -> [LBDailyObservation] {
        let te = LongitudinalBaseline.isoEpochDay(t)!
        return values.map { ok(iso(te + $0.offset), $0.value) }
    }

    func quiet(_ n: Int, value: Double, t: String) -> [LBDailyObservation] {
        let te = LongitudinalBaseline.isoEpochDay(t)!
        return (1...n).map { ok(iso(te - $0), value) } + [ok(t, value)]
    }

    func testParamsDifferBySeries() {
        let rhr = LongitudinalBaseline.params(for: .sleepRHR)
        let hrv = LongitudinalBaseline.params(for: .sleepHRVLn)
        let resp = LongitudinalBaseline.params(for: .sleepResp)
        XCTAssertNotEqual(rhr.kBand, hrv.kBand)
        XCTAssertNotEqual(rhr.span7, hrv.span7)
        XCTAssertLessThan(resp.kBand, rhr.kBand)
        XCTAssertEqual(LongitudinalBaseline.params(for: .wakingSteps).nLongEstablished, 21)
        XCTAssertEqual(LongitudinalBaseline.params(for: .sleepHRVLn).worse, .lower)
    }

    func testSameWiggleRespInRangeHRVNotUsingRHRK() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var resp = (1...40).map { ok(iso(t - $0), 16.0) }
        resp.append(ok(asOf, 16.32)) // 2%
        let evR = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepResp, observations: resp)
        XCTAssertFalse(LongitudinalBaseline.isOffUsual(z: evR.zLong,
                                                       k: LongitudinalBaseline.params(for: .sleepResp).kBand),
                       evR.consoleReport)

        var hrv = (1...40).map { ok(iso(t - $0), 50.0) }
        let lnFloor = 0.08
        let mathShift = 2.1 * lnFloor
        hrv.append(ok(asOf, exp(log(50.0) + mathShift)))
        let evH = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepHRVLn, observations: hrv)
        let kHRV = LongitudinalBaseline.params(for: .sleepHRVLn).kBand
        let kRHR = LongitudinalBaseline.params(for: .sleepRHR).kBand
        XCTAssertFalse(LongitudinalBaseline.isOffUsual(z: evH.zLong, k: kHRV),
                       "HRV k=2.6 should keep this wiggle in band\n\(evH.consoleReport)")
        XCTAssertTrue(LongitudinalBaseline.isOffUsual(z: evH.zLong, k: kRHR),
                      "RHR k=2 would have called it OFF — that is why k is per series")
    }

    func testSpikeTwoNightsOffLongerWeekNotFever() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = (3...80).map { ok(iso(t - $0), 60.0) }
        obs += [ok(iso(t - 2), 72), ok(iso(t - 1), 72), ok(asOf, 72)]
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs)
        XCTAssertTrue(LongitudinalBaseline.isOffUsual(z: ev.zLong,
                                                      k: LongitudinalBaseline.params(for: .sleepRHR).kBand),
                      "spike must be OFF longer usual\n\(ev.consoleReport)")
        XCTAssertLessThan(ev.copy7?.center ?? 99, 68,
                          "this week's training usual must not become 72\n\(ev.consoleReport)")
    }

    func testSlowShiftNotStuckOffFlatSixty() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs: [LBDailyObservation] = []
        for e in (t - 70)...t {
            let ageFromStart = e - (t - 70)
            let v: Double
            if ageFromStart < 20 {
                v = 68
            } else {
                v = 68 - 0.25 * Double(ageFromStart - 20)
            }
            obs.append(ok(iso(e), v))
        }
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs)
        XCTAssertTrue(ev.slopeUsable,
                      "three-week ramp must produce a usable slope\n\(ev.consoleReport)")
        XCTAssertFalse(LongitudinalBaseline.isOffUsual(z: ev.zLong,
                                                       k: LongitudinalBaseline.params(for: .sleepRHR).kBand),
                       "off is vs the moving path, not flat 68\n\(ev.consoleReport)")
        XCTAssertLessThan(ev.pChange, 0.90, ev.consoleReport)
    }

    func testTrustMovesAndHowOffHiddenWhenLow() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let thin = [ok(iso(t - 3), 72), ok(iso(t - 2), 72), ok(iso(t - 1), 72), ok(asOf, 72)]
        let thinEv = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: thin)
        XCTAssertLessThan(thinEv.usualTrustPct7, LongitudinalBaseline.trustHideThreshold)

        var full = (1...40).map { ok(iso(t - $0), 60.0) }
        full.append(ok(asOf, 60))
        let inBand = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: full)
        XCTAssertGreaterThan(inBand.usualTrustPctLong, 40)
        XCTAssertLessThan(inBand.howUnusualPctLong ?? 100, 50)

        var fever = (8...40).map { ok(iso(t - $0), 60.0) }
        fever += (1...7).map { ok(iso(t - $0), 72.0) }
        fever.append(ok(asOf, 72))
        let off = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: fever)
        XCTAssertGreaterThan(off.howUnusualPctLong ?? 0, inBand.howUnusualPctLong ?? 0)

        var hrv = (1...40).map { i in
            ok(iso(t - i), 50.0 + 8 * sin(Double(i) / 2.0))
        }
        hrv.append(ok(asOf, 50))
        let h = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepHRVLn, observations: hrv)
        XCTAssertLessThan(h.nEffLong, inBand.nEffLong + 0.01)
        XCTAssertNotEqual(LongitudinalBaseline.params(for: .sleepHRVLn).kBand,
                          LongitudinalBaseline.params(for: .sleepRHR).kBand)
    }

    func testPreexistingRecoveryPathNotFlat() {
        let t0 = "2026-05-01"
        let asOf = "2026-05-20"
        let t0e = LongitudinalBaseline.isoEpochDay(t0)!
        var obs: [LBDailyObservation] = []
        for e in (t0e - 50)...LongitudinalBaseline.isoEpochDay(asOf)! {
            let daysBefore = t0e - e
            let v = 68.0 - 0.2 * Double(max(0, 40 - daysBefore))
            obs.append(ok(iso(e), v))
        }
        let start = LBTreatmentEvent(trialId: "t1", type: .start, civilDay: t0,
                                     displayName: "Lisinopril", primarySeries: [.sleepRHR])
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs,
                                               trial: LBTrialRequest(events: [start]))
        XCTAssertTrue(ev.trial.trialFreezeOk, ev.consoleReport)
        XCTAssertEqual(ev.trial.card.freezeTitle, "Expected without treatment")
        XCTAssertTrue(ev.trial.disclaimer.contains("not proof the treatment caused"))
        if ev.trial.freeze?.slopeUsable == true {
            XCTAssertNotEqual(ev.trial.expectedT ?? 0, ev.trial.freeze?.centerLong ?? 0, accuracy: 0.05)
            XCTAssertNotEqual(ev.trial.zTrialTraj ?? 0, ev.trial.zTrialLevel ?? 0, accuracy: 0.02)
        }
    }

    func testConfoundedDayIneligibleAndDietChip() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let obs = (0...50).map { ok(iso(t - $0), 60.0) }
        let start = LBTreatmentEvent(trialId: "t1", type: .start, civilDay: iso(t - 10),
                                     displayName: "Med", primarySeries: [.sleepRHR])
        let diet = LBTrialRequest(events: [start], confoundersByDay: [asOf: [.dietChange]])
        let evDiet = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs, trial: diet)
        XCTAssertTrue(evDiet.trial.primaryContrastEligible,
                      "diet is a habit, not an acute skip")
        XCTAssertEqual(evDiet.trial.confoundersToday, [])

        let ill = LBTrialRequest(events: [start],
                                 dayLogsByDay: [asOf: LBDayLog(feltIll: true)])
        let evIll = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs, trial: ill)
        XCTAssertFalse(evIll.trial.primaryContrastEligible)
        XCTAssertEqual(evIll.trial.confoundersToday, [.illness])
        XCTAssertFalse(evIll.trial.judgingResponse)
    }

    func testWashoutClocksDoNotBiasExpected() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let obs = (0...50).map { ok(iso(t - $0), 61.0) }
        let start3 = LBTreatmentEvent(trialId: "a", type: .start, civilDay: iso(t - 20),
                                      displayName: "Med", onsetDays: 7, washoutDays: 3,
                                      primarySeries: [.sleepRHR])
        let stop3 = LBTreatmentEvent(trialId: "a", type: .stop, civilDay: iso(t - 5),
                                     displayName: "Med", washoutDays: 3)
        let start14 = LBTreatmentEvent(trialId: "b", type: .start, civilDay: iso(t - 20),
                                       displayName: "Med", onsetDays: 7, washoutDays: 14,
                                       primarySeries: [.sleepRHR])
        let stop14 = LBTreatmentEvent(trialId: "b", type: .stop, civilDay: iso(t - 5),
                                      displayName: "Med", washoutDays: 14)
        let a = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs,
                                              trial: LBTrialRequest(events: [start3, stop3]))
        let b = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs,
                                              trial: LBTrialRequest(events: [start14, stop14]))
        XCTAssertEqual(a.trial.phase, .ended)
        XCTAssertEqual(b.trial.phase, .washingOut)
        if let ea = a.trial.expectedT, let eb = b.trial.expectedT {
            XCTAssertEqual(ea, eb, accuracy: 1e-6)
        }
        let clear = LBTreatmentEvent(trialId: "b", type: .stop, civilDay: iso(t - 5),
                                     displayName: "Med", washoutDays: 14, patientSaysClear: true)
        let c = LongitudinalBaseline.evaluate(asOf: iso(t - 3), series: .sleepRHR, observations: obs,
                                              trial: LBTrialRequest(events: [start14, clear]))
        XCTAssertEqual(c.trial.phase, .ended)
    }

    func testPrimaryOnlyWritesSummary() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let obs = (0...50).map { ok(iso(t - $0), 60.0) }
        let start = LBTreatmentEvent(trialId: "t1", type: .start, civilDay: iso(t - 20),
                                     displayName: "Med", onsetDays: 1, primarySeries: [.sleepRHR])
        let rhr = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs,
                                                trial: LBTrialRequest(events: [start]))
        let steps = LongitudinalBaseline.evaluate(asOf: asOf, series: .wakingSteps,
                                                  observations: (0...50).map { ok(iso(t - $0), 8000) },
                                                  trial: LBTrialRequest(events: [start], freeze: rhr.trial.freeze))
        XCTAssertTrue(rhr.trial.isPrimarySeries)
        XCTAssertFalse(steps.trial.isPrimarySeries)
        XCTAssertFalse(steps.trial.judgingResponse)
        let none = LBTreatmentEvent(trialId: "t2", type: .start, civilDay: iso(t - 20),
                                    displayName: "Med", onsetDays: 1, primarySeries: [])
        let empty = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs,
                                                  trial: LBTrialRequest(events: [none]))
        XCTAssertEqual(empty.trial.summarySentence,
                       "No primary series chosen — not judging a treatment response.")
    }

    func testStableFPRTableHasPerSeriesRowsAndEmptyReal() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        func flat(_ v: Double) -> [LBDailyObservation] {
            (0...50).map { ok(iso(t - $0), v) }
        }
        let rows = LongitudinalBaseline.stableFalsePositiveTable(tapes: [
            (.sleepRHR, flat(60), asOf),
            (.sleepHRVLn, flat(50), asOf),
            (.sleepResp, flat(16), asOf),
        ], realWhoopRun: false)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { !$0.realWhoopRun })
        let printed = LongitudinalBaseline.printStableFPRTable(rows)
        print(printed)
        XCTAssertTrue(printed.contains("not run yet"))
        XCTAssertNotEqual(LongitudinalBaseline.params(for: .sleepHRVLn).kBand,
                          LongitudinalBaseline.params(for: .sleepRHR).kBand)
    }

    func testStableWindowIsOvernightForSleepHRV() {
        XCTAssertEqual(LongitudinalBaseline.stableWindow(for: .sleepHRVLn), .overnightSleep)
        XCTAssertEqual(LongitudinalBaseline.stableWindow(for: .awakeRestHR), .stillWaking)
        XCTAssertEqual(LongitudinalBaseline.stableWindow(for: .wakingSteps), .wakingLoad)
        XCTAssertEqual(LongitudinalBaseline.stableWindow(for: .wakingImuEnergy), .wakingLoad)
    }

    func testKWidensWhenOvernightResidualsAreNoisy() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let quiet = (0...40).map { ok(iso(t - $0), 60.0) }
        let evQ = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: quiet)
        var noisy: [LBDailyObservation] = []
        for i in 0...40 {
            let v = i % 5 == 0 ? 67.0 : 60.0
            noisy.append(ok(iso(t - i), v))
        }
        let evN = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: noisy)
        XCTAssertEqual(evQ.kBandTable, 2.0, accuracy: 0.01)
        XCTAssertGreaterThan(evN.kBandUsed, evQ.kBandUsed - 0.01, evN.consoleReport)
        XCTAssertLessThanOrEqual(evN.kBandUsed, evN.kBandTable * 1.40 + 1e-9)
        XCTAssertEqual(evQ.stableWindow, .overnightSleep)
    }

    func testTrainedDayUsesTrainedUsualNotRestUsual() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs: [LBDailyObservation] = []
        var logs: [String: LBDayLog] = [:]
        for i in 1...50 {
            let day = iso(t - i)
            let trained = i >= 10 && i <= 28
            obs.append(ok(day, trained ? 66 : 60))
            logs[day] = LBDayLog(workout: trained ? .hard : .none)
        }
        obs.append(ok(asOf, 66))
        logs[asOf] = LBDayLog(workout: .hard)
        let mixed = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs)
        let trained = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: obs,
            trial: LBTrialRequest(dayLogsByDay: logs))
        XCTAssertTrue(trained.habitMatched, trained.consoleReport)
        XCTAssertEqual(trained.habitClass, .trained)
        XCTAssertLessThan(abs(trained.zLong ?? 99), abs(mixed.zLong ?? 0),
                          "hard day should sit closer to other hard days\n\(trained.consoleReport)\n\(mixed.consoleReport)")
    }

    func testConfoundedNightsDoNotBuildUsualOrK() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs: [LBDailyObservation] = []
        var logs: [String: LBDayLog] = [:]
        // 63.9 stays inside k_learn (so mixed trim cannot drop it) but lifts mixed k_used.
        for i in 1...50 {
            let day = iso(t - i)
            let sick = i % 2 == 0
            obs.append(ok(day, sick ? 63.9 : 60))
            logs[day] = LBDayLog(alcohol: sick, feltIll: sick)
        }
        obs.append(ok(asOf, 60))
        let mixed = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs)
        let clean = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: obs,
            trial: LBTrialRequest(dayLogsByDay: logs))
        XCTAssertLessThan(clean.nCleanLong, mixed.nLong, clean.consoleReport)
        XCTAssertEqual(clean.copyLong?.center ?? -1, 60, accuracy: 0.8, clean.consoleReport)
        XCTAssertLessThan(clean.kBandUsed, mixed.kBandUsed, mixed.consoleReport + "\n" + clean.consoleReport)
        XCTAssertGreaterThanOrEqual(clean.nCleanLong, 14)
    }

    func testQuietestRealColumnIgnoresFakeRestStandIn() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let quiet = (0...40).map { ok(iso(t - $0), 60.0) }
        var noisy: [LBDailyObservation] = []
        for i in 0...40 {
            noisy.append(ok(iso(t - i), i % 3 == 0 ? 80 : 60))
        }
        let winner = LongitudinalBaseline.quietestRealColumn(
            asOf: asOf,
            tapes: [(.awakeRestHR, noisy), (.sleepRHR, quiet)])
        XCTAssertEqual(winner, .sleepRHR)
        XCTAssertFalse(LBSeries.awakeRestHR.hasDailyMetricColumn)
    }
}
