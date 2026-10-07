import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Gate: every condensed-plan statistical method is either witnessed in Phase A
/// or explicitly deferred (Phase B / later / Charge).
///
/// HOW TO RUN (prints the method table):
///   cd Packages/StrandAnalytics && swift test --filter LongitudinalBaselineMethodsTests
final class LongitudinalBaselineMethodsTests: XCTestCase {

    let asOf = "2026-05-01"

    func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
    func ok(_ day: String, _ v: Double) -> LBDailyObservation {
        LBDailyObservation(day: day, value: v, qualityStatus: .ok)
    }
    func missing(_ day: String) -> LBDailyObservation {
        LBDailyObservation(day: day, value: nil, qualityStatus: .missing, qualityReason: .unknown)
    }

    func testRegistrySplitsPhaseAFromPhaseB() {
        let methods = LongitudinalBaseline.statisticalMethods
        let ids = methods.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate method id")
        let phaseA = methods.filter { $0.phase == .phaseA || $0.phase == .diagnostic }
        let phaseB = methods.filter { $0.phase == .phaseB }
        XCTAssertGreaterThanOrEqual(phaseA.count, 20)
        XCTAssertEqual(Set(phaseB.map(\.id)),
                       Set(["trial_freeze", "theil_sen_slope", "sigma_meas_mdc", "sigma_bio",
                            "lag1_r1", "r1_live", "frozen_center_7_deltas", "missingness_counts"]))
        XCTAssertTrue(methods.contains { $0.id == "state_space" && $0.phase == .later })
        XCTAssertTrue(methods.contains { $0.id == "bounded_long_ewma" && $0.phase == .later })
        XCTAssertTrue(methods.contains { $0.id == "layer2_combo" && $0.phase == .later })
        XCTAssertTrue(methods.contains { $0.id == "charge_isolated" && $0.phase == .notThisEngine })

        var table = "\nid                      §       phase              symbol\n"
        for m in methods {
            table += "\(pad(m.id, 24))\(pad(m.planSection, 8))\(pad(m.phase.rawValue, 18))\(m.symbol)\n"
        }
        print(table)
        for m in phaseA {
            XCTAssertFalse(m.symbol.isEmpty, m.id)
        }
    }

    func testAsOfWindowsExcludeTodayAndGadaletaGap() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = Array((t - 60)...(t - 8)).map { ok(iso($0), 60) }
        obs += Array((t - 7)...(t - 1)).map { ok(iso($0), 99) }
        obs.append(ok(iso(t), 40))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: false)
        XCTAssertEqual(ev.copyLong?.center ?? 0, 60, accuracy: 0.01,
                       "Gadaleta gap: this week 99s must not vote on when-well\n\(ev.consoleReport)")
        XCTAssertEqual(ev.n7, 7)
        XCTAssertGreaterThan(ev.copy7?.center ?? 0, 90)
        XCTAssertEqual(ev.todayNative, 40)
        XCTAssertNotEqual(ev.copy7?.center, 40, "T is scored, not trained")
        XCTAssertEqual(LongitudinalBaseline.longWindowLength(), 53)
    }

    func testFiniteEWMANotSevenDayMedian() {
        let values = [57.0, 58, 59, 60, 61, 62, 63]
        let w = LongitudinalBaseline.fullWeekNormalizedWeights()
        let ewma = LongitudinalBaseline.ewmaCenter(values: values, weights: w)!
        let med = LongitudinalBaseline.median(values)!
        XCTAssertEqual(med, 60, accuracy: 1e-12)
        XCTAssertEqual(ewma, 61.1, accuracy: 0.05)
        XCTAssertNotEqual(ewma, med, accuracy: 0.5)
        XCTAssertEqual(LongitudinalBaseline.ewmaHalfLifeDays(), 2.41, accuracy: 0.02)
        XCTAssertEqual(LongitudinalBaseline.Params.alpha, 0.25, accuracy: 1e-12)
        XCTAssertGreaterThan(LongitudinalBaseline.rawEwmaWeight(age: 6), 0)
        XCTAssertEqual(w.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(w.count, 7)
    }

    func testRenormalizeDoesNotDumpMassOnlyOntoLastNight() {
        // T−5 missing: remaining nights keep relative recency (condensed §1.1).
        var w = (0...6).reversed().map { LongitudinalBaseline.rawEwmaWeight(age: $0) }
        w[2] = 0   // T−5 is index 2 when oldest→newest
        let values = [58.0, 60, 0, 61, 59, 72, 72]
        let usedV = zip(values, w).compactMap { $1 > 0 ? $0 : nil }
        let usedW = w.filter { $0 > 0 }
        let c = LongitudinalBaseline.ewmaCenter(values: usedV, weights: usedW)!
        XCTAssertEqual(c, 66.5, accuracy: 0.15)
        XCTAssertNotEqual(c, 72, accuracy: 1, "missing night must not dump remaining mass onto T−1 alone")
    }

    func testLongMedianNotMeanOnFeverMinority() {
        let s = Array(repeating: 60.0, count: 46) + Array(repeating: 72.0, count: 7)
        let mean = s.reduce(0, +) / Double(s.count)
        XCTAssertEqual(mean, 61.6, accuracy: 0.05)
        XCTAssertEqual(LongitudinalBaseline.median(s)!, 60, accuracy: 1e-12)
        XCTAssertEqual(LongitudinalBaseline.longWindowLength(), 53)
    }

    func testStudentTIsV1DefaultHuberExistsButIsNotUsedForCenter() {
        XCTAssertEqual(LongitudinalBaseline.studentTLambda(zLong: 4.2), 0.23, accuracy: 0.01)
        XCTAssertEqual(LongitudinalBaseline.huberLambda(zLong: 4.2), 2.0 / 4.2, accuracy: 1e-9)
        XCTAssertNotEqual(LongitudinalBaseline.studentTLambda(zLong: 4.2),
                          LongitudinalBaseline.huberLambda(zLong: 4.2), accuracy: 0.05)

        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = Array((t - 60)...(t - 8)).map { ok(iso($0), 60) }
        obs += [58, 59, 60, 61, 62, 72, 72].enumerated().map { i, v in ok(iso(t - 7 + i), v) }
        obs.append(ok(iso(t), 72))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: false)
        XCTAssertEqual(ev.lambdas.count, 7, ev.consoleReport)
        let spread = try! XCTUnwrap(ev.copyLong?.spread)
        let center = try! XCTUnwrap(ev.copyLong?.center)
        let z72 = (72 - center) / spread
        XCTAssertEqual(ev.lambdas[5], LongitudinalBaseline.studentTLambda(zLong: z72), accuracy: 1e-9,
                       "evaluate must use Student-t, not Huber\n\(ev.consoleReport)")
        XCTAssertEqual(ev.lambdas[6], LongitudinalBaseline.studentTLambda(zLong: z72), accuracy: 1e-9)
        XCTAssertNotEqual(ev.lambdas[5], LongitudinalBaseline.huberLambda(zLong: z72), accuracy: 0.01)
    }

    func testHoldAndCenter7RawAndGap() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = Array((t - 60)...(t - 8)).map { ok(iso($0), 60) }
        obs += Array((t - 7)...(t - 1)).map { ok(iso($0), 72) }
        obs.append(ok(iso(t), 72))
        let carry = LBCarry(center7: 61.1, spread7: 2.85, centerLong: 60, spreadLong: 2.85,
                            nLong: 40, establishedLong: true)
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, carry: carry, replay: false)
        XCTAssertLessThan(ev.nLearn, 4)
        XCTAssertEqual(ev.copy7?.center ?? 0, 61.1, accuracy: 0.05)
        XCTAssertEqual(ev.center7Raw ?? 0, 72, accuracy: 0.01)
        XCTAssertEqual(ev.gap ?? 0, 12, accuracy: 0.2)
        XCTAssertNotNil(ev.gapZ)
        XCTAssertTrue(ev.copy7?.held ?? false)
    }

    func testBorrowedSpreadAndMADScaleAndFloor() {
        let mix = LongitudinalBaseline.borrowedSpread(spread7Raw: 2, spreadLong: 2.85,
                                                      nLearn: 4, establishedLong: true, floor: 2)
        XCTAssertEqual(mix.spread, 2.36, accuracy: 0.02)
        let values = [57.0, 58, 59, 60, 61, 62, 63]
        let center = 61.1
        let spread = LongitudinalBaseline.robustSpread(values: values, center: center, floor: 2)
        XCTAssertEqual(spread, 2.85, accuracy: 0.05)
        XCTAssertEqual(LongitudinalBaseline.Params.madScale, 1.4826, accuracy: 1e-6)
        XCTAssertEqual(LongitudinalBaseline.seriesSpec(.sleepRHR).floor, 2)
        let flat = LongitudinalBaseline.robustSpread(values: Array(repeating: 60.0, count: 7),
                                                     center: 60, floor: 2)
        XCTAssertEqual(flat, 2, accuracy: 1e-12)
        let aroundMedian = LongitudinalBaseline.robustSpread(values: values, center: 60, floor: 2)
        XCTAssertNotEqual(spread, aroundMedian, accuracy: 0.01,
                          "7-day MAD is around the EWMA center, not the 7-day median")
    }

    func testTrimAndTwoBlockAreDiagnosticNotTheRegimeCall() {
        let well = Array(repeating: 60.0, count: 46) + Array(repeating: 72.0, count: 7)
        let trim = LongitudinalBaseline.trimLongList(well, floor: 2)
        XCTAssertTrue(trim.absorbed)
        XCTAssertEqual(trim.keptFrac, 46.0 / 53.0, accuracy: 0.001)
        XCTAssertEqual(LongitudinalBaseline.median(trim.kept)!, 60, accuracy: 1e-12)

        let shifted = Array(repeating: 60.0, count: 39) + Array(repeating: 72.0, count: 14)
        XCTAssertEqual(LongitudinalBaseline.twoBlockMedianShift(shifted) ?? 0, 12, accuracy: 1e-12)

        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = Array((t - 60)...(t - 22)).map { ok(iso($0), 60) }
        obs += Array((t - 21)...(t - 8)).map { ok(iso($0), 72) }
        obs += Array((t - 7)...t).map { ok(iso($0), 72) }
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: true)
        XCTAssertEqual(ev.twoBlockShift ?? 0, 12, accuracy: 0.01, ev.consoleReport)
        XCTAssertTrue(ev.regimeShift, "CUSUM is the decision, two-block is only logged")
        XCTAssertEqual(ev.copyLong?.center ?? 0, 60, accuracy: 0.5)
        XCTAssertNotNil(ev.trimKeptFrac)
        XCTAssertLessThan(ev.trimKeptFrac ?? 1, 1.0 - LongitudinalBaseline.Params.pRegime + 0.2)
    }

    func testCUSUMMissingDayNeitherIncrementsNorResets() {
        var s = 0.0
        for _ in 0..<7 {
            s = LongitudinalBaseline.cusumStep(previousS: s, value: 72, center: 60, spread: 2.85)
        }
        XCTAssertEqual(s, 26, accuracy: 1.0)
        XCTAssertEqual(LongitudinalBaseline.changeProbability(cusumS: s), 0.73, accuracy: 0.02)
        for _ in 0..<7 {
            s = LongitudinalBaseline.cusumStep(previousS: s, value: 72, center: 60, spread: 2.85)
        }
        XCTAssertEqual(LongitudinalBaseline.changeProbability(cusumS: 52), 0.93, accuracy: 0.02)

        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = Array((t - 60)...(t - 9)).map { ok(iso($0), 60) }
        obs.append(missing(iso(t - 8)))
        obs += Array((t - 7)...t).map { ok(iso($0), 60) }
        let before = LongitudinalBaseline.evaluate(asOf: iso(t - 1), series: .sleepRHR,
                                                   observations: obs, replay: true)
        let after = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                                  observations: obs, replay: true)
        XCTAssertEqual(after.cusumS, before.cusumS, accuracy: 1e-9,
                       "missing T−8 must skip CUSUM (no increment, no reset)\n\(after.consoleReport)")
    }

    func testConfidencePersistenceZBandLnMissingQualityLayer() {
        XCTAssertEqual(LongitudinalBaseline.confidencePct7(n7: 7, nLowQuality: 0, nLearn: 7,
                                                           stale: false, establishedLongBorrowed: false), 100)
        XCTAssertEqual(LongitudinalBaseline.confidencePct7(n7: 4, nLowQuality: 0, nLearn: 4,
                                                           stale: false, establishedLongBorrowed: true), 40)
        XCTAssertEqual(LongitudinalBaseline.confidencePct7(n7: 7, nLowQuality: 0, nLearn: 7,
                                                           stale: true, establishedLongBorrowed: false), 0)
        XCTAssertEqual(log(50.0), LongitudinalBaseline.toMath(50, series: .sleepHRVLn)!, accuracy: 1e-12)
        XCTAssertEqual(LongitudinalBaseline.toDisplay(log(50), series: .sleepHRVLn), 50, accuracy: 1e-9)
        XCTAssertEqual(LongitudinalBaseline.toMath(50, series: .sleepHRVLn)!
                       - LongitudinalBaseline.toMath(25, series: .sleepHRVLn)!,
                       log(2), accuracy: 1e-9)

        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var persist = Array((t - 60)...(t - 8)).map { ok(iso($0), 60) }
        persist += Array((t - 7)...(t - 4)).map { ok(iso($0), 60) }
        persist += Array((t - 3)...t).map { ok(iso($0), 72) }
        let persistEv = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                                      observations: persist, replay: true)
        XCTAssertTrue(persistEv.twoOfThree, persistEv.consoleReport)
        XCTAssertGreaterThanOrEqual(persistEv.runLength, 2)
        XCTAssertEqual(LongitudinalBaseline.Params.kBand, 2)

        let hospitalToday = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                                          observations: [
                                                            ok(iso(t - 2), 60),
                                                            missing(iso(t - 1)),
                                                            LBDailyObservation(day: asOf, value: nil,
                                                                               qualityStatus: .missing,
                                                                               qualityReason: .hospital),
                                                          ], replay: false)
        XCTAssertNil(hospitalToday.todayNative)
        XCTAssertEqual(hospitalToday.n7, 1)

        let zeroRow = LongitudinalBaseline.observation(day: asOf, native: 0, streamPresent: true,
                                                       sleepHrOnly: false, series: .sleepRHR)
        XCTAssertEqual(zeroRow.qualityStatus, .lowQuality)
        XCTAssertEqual(zeroRow.qualityReason, .outOfRange)
        XCTAssertNil(LongitudinalBaseline.trainableNative(zeroRow, series: .sleepRHR))

        XCTAssertFalse(LongitudinalBaseline.statisticalMethods.contains {
            $0.id == "layer2_combo" && $0.phase == .phaseA
        })
        XCTAssertEqual(hospitalToday.series, .sleepRHR)
        XCTAssertEqual(hospitalToday.phaseAStatisticLedger.first { $0.planName == "layer" }?.value, "1")
    }

    func testChargeWinsorizedEWMAIsADifferentEngine() {
        let nights = [57.0, 58, 59, 60, 61, 62, 63]
        let charge = Baselines.foldHistory(nights.map { Optional($0) }, cfg: Baselines.restingHRCfg)
        let w = LongitudinalBaseline.fullWeekNormalizedWeights()
        let week = LongitudinalBaseline.ewmaCenter(values: nights, weights: w)!
        XCTAssertEqual(week, 61.1, accuracy: 0.05)
        XCTAssertNotEqual(charge.baseline, week, accuracy: 0.01,
                          "Charge Winsorized EWMA must not be this finite span-7 EWMA")
    }

    func testNoWeekdaySplitOnSteps() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        // asOf 2026-05-01 is Friday, so T−6/T−5 are Saturday/Sunday.
        let week = [8000.0, 9200, 7500, 11000, 8800, 6400, 9100]
        var obs: [LBDailyObservation] = []
        for i in 0..<7 { obs.append(ok(iso(t - 7 + i), week[i])) }
        obs.append(ok(iso(t), 4200))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .wakingSteps,
                                               observations: obs, replay: false)
        let w = LongitudinalBaseline.fullWeekNormalizedWeights()
        let allDays = LongitudinalBaseline.ewmaCenter(values: week, weights: w)!
        var dropped = week
        dropped[1] = 0
        dropped[2] = 0
        let weekendDroppedWeights = zip(w, dropped).map { $1 == 0 ? 0.0 : $0 }
        let weekdayOnly = LongitudinalBaseline.ewmaCenter(values: week, weights: weekendDroppedWeights)!
        XCTAssertEqual(ev.copy7?.center ?? 0, allDays, accuracy: 0.5)
        XCTAssertNotEqual(ev.copy7?.center ?? 0, weekdayOnly, accuracy: 1,
                          "v1 must not drop weekend civil days")
    }

    func testStillMovingGateAndContinuousAreSeparateContexts() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let rest = ok(iso(t - 1), 64)
        let moving = LBDailyObservation(day: iso(t - 1), value: 88, qualityStatus: .ok, coverage: 40)
        let thinMoving = LBDailyObservation(day: iso(t - 1), value: 88, qualityStatus: .ok, coverage: 10)
        let thinCont = LBDailyObservation(day: iso(t - 1), value: 72, qualityStatus: .ok, coverage: 60)
        let fullCont = LBDailyObservation(day: iso(t - 1), value: 72, qualityStatus: .ok, coverage: 300)

        XCTAssertEqual(LBSeries.awakeRestHR.context, .awakeRest)
        XCTAssertEqual(LBSeries.awakeActiveHR.context, .awakeActive)
        XCTAssertEqual(LBSeries.continuousHR.context, .continuous)
        XCTAssertNotEqual(rest.value, moving.value)

        let thinActive = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .awakeActiveHR,
            observations: [thinMoving, ok(iso(t), 90)], replay: false)
        XCTAssertEqual(thinActive.n7, 0, "10 moving minutes must not train awake-active\n\(thinActive.consoleReport)")

        let okActive = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .awakeActiveHR,
            observations: [moving, ok(iso(t), 90)], replay: false)
        XCTAssertEqual(okActive.n7, 1, okActive.consoleReport)

        let thinC = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .continuousHR,
            observations: [thinCont, ok(iso(t), 80)], replay: false)
        XCTAssertEqual(thinC.n7, 0, "under 240 continuous minutes must not train\n\(thinC.consoleReport)")

        let okC = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .continuousHR,
            observations: [fullCont, ok(iso(t), 80)], replay: false)
        XCTAssertEqual(okC.n7, 1, okC.consoleReport)

        let sleepRow = [metricish(rhr: 58)]
        XCTAssertFalse(LongitudinalBaseline.observations(from: sleepRow, series: .sleepRHR).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: sleepRow, series: .awakeActiveHR).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: sleepRow, series: .continuousHR).isEmpty)
    }

    func metricish(rhr: Double) -> DailyMetric {
        DailyMetric(day: asOf, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: Int(rhr), avgHrv: nil,
                    recovery: nil, strain: nil, exerciseCount: nil, spo2Pct: nil,
                    skinTempDevC: nil, respRateBpm: nil, steps: nil, avgSdnn: nil,
                    skinTempC: nil, sleepHrOnly: nil)
    }

    func testPhaseBMethodsAreNamedAndAbsentFromEvaluate() {
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: [
            ok(asOf, 60)
        ], replay: false)
        let keys = Set(ev.phaseAStatisticLedger.map(\.planName))
        XCTAssertFalse(keys.contains("center_long_frozen"))
        XCTAssertFalse(keys.contains("z_trial_traj"))
        XCTAssertFalse(keys.contains("mdc_95"))
        XCTAssertTrue(keys.contains("slope_long"))
        XCTAssertFalse(keys.contains("r1"))
    }

    func testEveryPhaseAMethodIdHasAWitnessInThisFile() {
        // If you add a Phase A/diagnostic method to the registry, add a test above or this fails.
        let witnessed = Set([
            "as_of_windows", "finite_ewma", "ewma_renormalize", "gapped_long_median",
            "inclusive_53", "night_lifecycle", "student_t_lambda", "huber_lambda",
            "hold_n_learn", "center_7_raw_gap", "borrowed_spread", "mad_14826",
            "mad_around_ewma", "spread_floor", "trim_k_learn", "cusum_p_change",
            "cusum_missing_hold", "two_block_median", "trim_kept_frac",
            "confidence_pct", "persistence", "z_and_band", "ln_rmssd",
            "missing_not_zero", "quality_reasons", "layer1_no_blend", "no_weekday_split",
            "still_moving_gate", "context_continuous", "never_average_contexts",
        ])
        let required = Set(LongitudinalBaseline.statisticalMethods
            .filter { $0.phase == .phaseA || $0.phase == .diagnostic }
            .map(\.id))
        XCTAssertEqual(required, witnessed,
                       "unwitnessed: \(required.subtracting(witnessed)) extra: \(witnessed.subtracting(required))")
    }

    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
}
