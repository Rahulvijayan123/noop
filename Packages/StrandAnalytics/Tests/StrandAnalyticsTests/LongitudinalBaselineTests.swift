import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Phase A math tests for LongitudinalBaseline.
/// Spec: Packages/StrandAnalytics/Baseline/FRWHOOP_BASELINE_IMPLEMENTATION.md §4, §8–9
/// Worked numbers: FRWHOOP_BASELINE_CONDENSED_PLAN.md §5
///
/// HOW TO RUN (from the repo, or from this package):
///   cd Packages/StrandAnalytics && swift test --filter LongitudinalBaselineTests
///
/// A failed test prints `evaluation.consoleReport` so you can see both copies, gap, CUSUM, and %.
final class LongitudinalBaselineTests: XCTestCase {

    let asOf = "2026-05-01"

    // MARK: - How to load fixtures

    func fixtureCSV(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/StrandAnalyticsTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // StrandAnalytics
            .appendingPathComponent("Baseline/fixtures/\(name)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func evaluateFixture(_ name: String, series: LBSeries, asOf: String? = nil,
                         replay: Bool = true) -> LBEvaluation {
        let obs = LongitudinalBaseline.observations(fromCSV: fixtureCSV(name))
        XCTAssertFalse(obs.isEmpty, "missing fixture \(name) — expected under Baseline/fixtures/")
        return LongitudinalBaseline.evaluate(asOf: asOf ?? self.asOf, series: series,
                                             observations: obs, replay: replay)
    }

    func ok(_ day: String, _ value: Double, seriesCoverage: Double? = nil) -> LBDailyObservation {
        LBDailyObservation(day: day, value: value, qualityStatus: .ok, coverage: seriesCoverage)
    }

    func iso(_ epoch: Int) -> String { LongitudinalBaseline.isoFromEpochDay(epoch) }

    /// Inclusive fill of quality-OK days.
    func fill(from start: String, through end: String, value: Double) -> [LBDailyObservation] {
        guard let a = LongitudinalBaseline.isoEpochDay(start),
              let b = LongitudinalBaseline.isoEpochDay(end) else { return [] }
        return (a...b).map { ok(iso($0), value) }
    }

    func report(_ ev: LBEvaluation, file: StaticString = #filePath, line: UInt = #line) {
        if ev.copy7 == nil && ev.n7 >= 4 {
            XCTFail("expected a 7-day copy\n\(ev.consoleReport)", file: file, line: line)
        }
    }

    // MARK: - Calendar / weights (implementation map: inclusive 53-day long window)

    func testLongWindowIs53SlotsNot60() {
        XCTAssertEqual(LongitudinalBaseline.longWindowLength(), 53)
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let len = (t - 8) - (t - 60) + 1
        XCTAssertEqual(len, 53, "60-day lookback is the start, not 60 included days")
    }

    func testIsoRoundTrip() {
        for key in ["2026-01-01", "2026-02-28", "2026-03-01", "2026-05-01", "2024-02-29"] {
            let z = LongitudinalBaseline.isoEpochDay(key)!
            XCTAssertEqual(LongitudinalBaseline.isoFromEpochDay(z), key)
        }
    }

    func testFullWeekNormalizedWeights() {
        let w = LongitudinalBaseline.fullWeekNormalizedWeights()
        XCTAssertEqual(w.count, 7)
        let expected = [0.051, 0.069, 0.091, 0.122, 0.162, 0.216, 0.289]
        for i in 0..<7 {
            XCTAssertEqual(w[i], expected[i], accuracy: 0.001, "weight[\(i)]")
        }
        XCTAssertEqual(w.reduce(0, +), 1.0, accuracy: 1e-12)
        XCTAssertEqual(w[6] / w[0], 5.6, accuracy: 0.05, "newest/oldest ≈ 5.6")
    }

    // MARK: - 5.1 sleep RHR ramp (this week EWMA)

    func testSleepRHRWeekRamp() {
        let ev = evaluateFixture("sleep_rhr_week_ramp.csv", series: .sleepRHR, replay: false)
        report(ev)
        let c = try! XCTUnwrap(ev.copy7)
        XCTAssertEqual(c.center, 61.1, accuracy: 0.05, ev.consoleReport)
        XCTAssertEqual(c.spread, 2.85, accuracy: 0.05, ev.consoleReport)
        XCTAssertEqual(c.bandLoDisplay, 55.4, accuracy: 0.15, ev.consoleReport)
        XCTAssertEqual(c.bandHiDisplay, 66.8, accuracy: 0.15, ev.consoleReport)
        XCTAssertEqual(ev.todayNative, 72)
        XCTAssertEqual(c.deltaDisplay ?? 0, 10.9, accuracy: 0.15, ev.consoleReport)
        XCTAssertEqual(ev.z7 ?? 0, 3.8, accuracy: 0.15, ev.consoleReport)
        XCTAssertTrue(ev.show7)
        XCTAssertFalse(ev.alertEligible, "7-day points alone cannot set alert_eligible")
        XCTAssertEqual(ev.n7, 7)
    }

    func testThreeNightsDoNotShow7DayCopy() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let obs = [
            ok(iso(t - 3), 60), ok(iso(t - 2), 60), ok(iso(t - 1), 60), ok(iso(t), 72)
        ]
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: false)
        XCTAssertEqual(ev.n7, 3, ev.consoleReport)
        XCTAssertFalse(ev.show7)
        XCTAssertNil(ev.copy7, ev.consoleReport)
    }

    func testFourNightsShowButNotAlertEligible() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let obs = (1...4).map { ok(iso(t - $0), 60) } + [ok(iso(t), 60)]
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: false)
        XCTAssertEqual(ev.n7, 4, ev.consoleReport)
        XCTAssertTrue(ev.show7)
        XCTAssertEqual(ev.copy7?.center ?? 0, 60, accuracy: 0.05, ev.consoleReport)
        XCTAssertFalse(ev.alertEligible)
        XCTAssertFalse(ev.establishedLong)
    }

    // MARK: - 5.18 / 5.19 Student-t + hold

    func testStudentTLambdaAtWorkedZ() {
        XCTAssertEqual(LongitudinalBaseline.studentTLambda(zLong: 0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(LongitudinalBaseline.studentTLambda(zLong: 2), 0.63, accuracy: 0.01)
        XCTAssertEqual(LongitudinalBaseline.studentTLambda(zLong: 4.2), 0.23, accuracy: 0.01)
        XCTAssertEqual(LongitudinalBaseline.studentTLambda(zLong: 10), 0.05, accuracy: 0.01)
    }

    func testMixedWeekStudentTVersusEstablishedLong() {
        // Condensed 5.18: long usual 60 / 2.85, week 58…62,72,72.
        let values = [58.0, 59, 60, 61, 62, 72, 72]
        let weights = LongitudinalBaseline.fullWeekNormalizedWeights()
        let raw = LongitudinalBaseline.ewmaCenter(values: values, weights: weights)!
        XCTAssertEqual(raw, 66.3, accuracy: 0.1)

        let lambdas = values.map { x -> Double in
            let z = (x - 60.0) / 2.85
            return LongitudinalBaseline.studentTLambda(zLong: z)
        }
        XCTAssertEqual(lambdas[5], 0.23, accuracy: 0.02)
        XCTAssertEqual(lambdas[6], 0.23, accuracy: 0.02)
        let nLearn = lambdas.reduce(0, +)
        XCTAssertEqual(nLearn, 5.46, accuracy: 0.05)

        let learnW = zip(weights, lambdas).map { $0 * $1 }
        let center = LongitudinalBaseline.ewmaCenter(values: values, weights: learnW)!
        XCTAssertEqual(center, 62.7, accuracy: 0.15)
        XCTAssertEqual(raw - 60, 6.3, accuracy: 0.15)
    }

    func testFeverWeekHoldsInjectedLastCenter() {
        // Condensed 5.19: one shot, last published this-week center = 61.1, all seven slots 72.
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = fill(from: iso(t - 60), through: iso(t - 8), value: 60)
        obs += fill(from: iso(t - 7), through: iso(t - 1), value: 72)
        obs.append(ok(iso(t), 72))
        let carry = LBCarry(center7: 61.1, spread7: 2.85, centerLong: 60, spreadLong: 2.85,
                            nLong: 40, establishedLong: true)
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, carry: carry, replay: false)
        XCTAssertLessThan(ev.nLearn, 4, ev.consoleReport)
        XCTAssertEqual(ev.center7Raw ?? 0, 72, accuracy: 0.01, ev.consoleReport)
        XCTAssertEqual(ev.copy7?.center ?? 0, 61.1, accuracy: 0.05,
                       "training center must be held at last published, not 72\n\(ev.consoleReport)")
        XCTAssertTrue(ev.copy7?.held ?? false, ev.consoleReport)
        XCTAssertGreaterThan(ev.gap ?? 0, 10, ev.consoleReport)
    }

    func testOnlineFeverWeekDoesNotWalkCenter7To72() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = fill(from: iso(t - 60), through: iso(t - 8), value: 60)
        obs += fill(from: iso(t - 7), through: iso(t - 1), value: 72)
        obs.append(ok(iso(t), 72))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: true)
        XCTAssertLessThan(ev.nLearn, 4, ev.consoleReport)
        XCTAssertEqual(ev.center7Raw ?? 0, 72, accuracy: 0.01, ev.consoleReport)
        XCTAssertTrue(ev.copy7?.held ?? false, ev.consoleReport)
        XCTAssertLessThan(ev.copy7?.center ?? 72, 66,
                          "held center may have moved a little while n_learn ≥ 4, but must not become 72\n\(ev.consoleReport)")
        XCTAssertGreaterThan(ev.zLong ?? 0, 3, ev.consoleReport)
        XCTAssertTrue(ev.establishedLong)
    }

    func testBorrowedSpreadFourLearnDays() {
        let mix = LongitudinalBaseline.borrowedSpread(spread7Raw: 2.0, spreadLong: 2.85,
                                                      nLearn: 4, establishedLong: true, floor: 2.0)
        XCTAssertEqual(mix.spread, 2.36, accuracy: 0.02)
        XCTAssertTrue(mix.borrowed)
    }

    func testConfidencePins100_40_0() {
        XCTAssertEqual(LongitudinalBaseline.confidencePct7(n7: 7, nLowQuality: 0, nLearn: 7,
                                                           stale: false, establishedLongBorrowed: false), 100)
        XCTAssertEqual(LongitudinalBaseline.confidencePct7(n7: 4, nLowQuality: 0, nLearn: 4,
                                                           stale: false, establishedLongBorrowed: true), 40)
        XCTAssertEqual(LongitudinalBaseline.confidencePct7(n7: 7, nLowQuality: 0, nLearn: 7,
                                                           stale: true, establishedLongBorrowed: false), 0)
    }

    // MARK: - 5.22 CUSUM

    func testCusumFormulaMatchesWorkedSevenAndFourteenDays() {
        // Condensed 5.22 uses spread 2.85 so |z|≈4.2. A flat long tape uses the 2 bpm floor instead.
        var s = 0.0
        for _ in 0..<7 {
            s = LongitudinalBaseline.cusumStep(previousS: s, value: 72, center: 60, spread: 2.85)
        }
        XCTAssertEqual(s, 26, accuracy: 1.0)
        XCTAssertEqual(LongitudinalBaseline.changeProbability(cusumS: s), 0.73, accuracy: 0.02)
        XCTAssertLessThan(LongitudinalBaseline.changeProbability(cusumS: s), 0.90)

        for _ in 0..<7 {
            s = LongitudinalBaseline.cusumStep(previousS: s, value: 72, center: 60, spread: 2.85)
        }
        XCTAssertEqual(s, 52, accuracy: 1.5)
        XCTAssertEqual(LongitudinalBaseline.changeProbability(cusumS: s), 0.93, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(LongitudinalBaseline.changeProbability(cusumS: s), 0.90)
    }

    func testCusumSevenFeverDaysDoesNotShiftRegime() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = fill(from: iso(t - 60), through: iso(t - 15), value: 60)  // 46 nights
        obs += fill(from: iso(t - 14), through: iso(t - 8), value: 72)      // 7 fever into long
        obs += fill(from: iso(t - 7), through: iso(t), value: 60)
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: true)
        XCTAssertEqual(ev.copyLong?.center ?? 0, 60, accuracy: 0.01, ev.consoleReport)
        XCTAssertFalse(ev.regimeShift, "seven fever nights trim; they do not declare a new usual\n\(ev.consoleReport)")
        XCTAssertLessThan(ev.pChange, 0.90, ev.consoleReport)
        XCTAssertGreaterThan(ev.cusumS, 0, ev.consoleReport)
        XCTAssertGreaterThanOrEqual(ev.nLong, 14)
    }

    func testCusumFourteenFeverDaysHoldsWhenWell() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = fill(from: iso(t - 60), through: iso(t - 22), value: 60)  // 39 nights
        obs += fill(from: iso(t - 21), through: iso(t - 8), value: 72)      // 14 fever
        obs += fill(from: iso(t - 7), through: iso(t), value: 72)
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: true)
        XCTAssertGreaterThanOrEqual(ev.pChange, 0.90, ev.consoleReport)
        XCTAssertTrue(ev.regimeShift, ev.consoleReport)
        XCTAssertEqual(ev.copyLong?.center ?? 0, 60, accuracy: 0.5,
                       "must hold when-well at 60, not relabel 72 as usual\n\(ev.consoleReport)")
        XCTAssertTrue(ev.copyLong?.held ?? false, ev.consoleReport)
    }

    func testPersistenceTwoOfThreeIsNotAnAlert() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = fill(from: iso(t - 60), through: iso(t - 8), value: 60)
        obs += fill(from: iso(t - 7), through: iso(t - 4), value: 60)
        obs += fill(from: iso(t - 3), through: iso(t), value: 72)
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: true)
        XCTAssertTrue(ev.twoOfThree, ev.consoleReport)
        XCTAssertGreaterThanOrEqual(ev.runLength, 2, ev.consoleReport)
        XCTAssertFalse(ev.alertEligible && ev.runLength == 0)
        XCTAssertTrue(ev.establishedLong)
        XCTAssertTrue(ev.alertEligible)
        XCTAssertTrue(ev.contextPrompt.shouldAsk, ev.consoleReport)
        XCTAssertFalse(ev.contextPrompt.required)
        XCTAssertTrue(ev.contextPrompt.offLongerUsual)
        // Snapshot stores persistence; this pass does not send a push. The in-app prompt is optional.
    }

    func testInRangeDoesNotAskCaregiverToLabel() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let obs = fill(from: iso(t - 60), through: iso(t), value: 60)
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs)
        XCTAssertFalse(ev.twoOfThree)
        XCTAssertFalse(ev.contextPrompt.shouldAsk, ev.consoleReport)
    }

    func testLoneOffDayAsksForALabelTheNextDay() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = fill(from: iso(t - 60), through: iso(t - 1), value: 60)
        obs.append(ok(iso(t), 90))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: true)
        XCTAssertFalse(ev.twoOfThree, ev.consoleReport)
        XCTAssertTrue(ev.contextPrompt.shouldAsk, ev.consoleReport)
        XCTAssertEqual(ev.contextPrompt.headline, "Last night looked unusual")
    }

    func testConfounderAlreadyLoggedSuppressesContextPrompt() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = fill(from: iso(t - 60), through: iso(t - 4), value: 60)
        obs += fill(from: iso(t - 3), through: iso(t), value: 72)
        let start = LBTreatmentEvent(trialId: "t", type: .start, civilDay: iso(t - 40),
                                     displayName: "Lisinopril")
        let ev = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: obs,
            trial: LBTrialRequest(events: [start], confoundersByDay: [asOf: [.illness]]))
        XCTAssertFalse(ev.contextPrompt.shouldAsk, ev.consoleReport)
        XCTAssertEqual(ev.trial.confoundersToday, [.illness])
    }

    func testMissingNightDoesNotAskWhyMissing() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = fill(from: iso(t - 60), through: iso(t - 1), value: 60)
        obs.append(LBDailyObservation(day: iso(t), value: nil, qualityStatus: .missing,
                                      qualityReason: .unknown))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: obs)
        XCTAssertNil(ev.todayNative)
        XCTAssertFalse(ev.contextPrompt.shouldAsk, ev.consoleReport)
    }

    // MARK: - 5.3 HRV ln → ms

    func testSleepHRVLnConvertsBandToMs() {
        let ev = evaluateFixture("sleep_hrv_ln_ms.csv", series: .sleepHRVLn, replay: false)
        let c = try! XCTUnwrap(ev.copy7)
        XCTAssertEqual(c.center, 3.898, accuracy: 0.08, ev.consoleReport)
        XCTAssertEqual(c.centerDisplay, exp(c.center), accuracy: 0.5, ev.consoleReport)
        XCTAssertLessThan(c.bandLoDisplay, c.centerDisplay)
        XCTAssertGreaterThan(c.bandHiDisplay, c.centerDisplay)
        XCTAssertLessThan(ev.z7 ?? 0, -2.5, ev.consoleReport)
        XCTAssertEqual(ev.todayNative, 32)
    }

    // MARK: - Steps: 0 is real, missing stream is not 0

    func testZeroStepsWithStreamIsRealAndMissingIsNotZero() {
        let ev = evaluateFixture("waking_steps_zero.csv", series: .wakingSteps,
                                 asOf: "2026-05-02", replay: false)
        XCTAssertEqual(ev.todayNative, 0, ev.consoleReport)
        XCTAssertTrue(ev.show7, ev.consoleReport)

        let missing = LongitudinalBaseline.evaluate(
            asOf: "2026-05-03", series: .wakingSteps,
            observations: LongitudinalBaseline.observations(fromCSV: fixtureCSV("waking_steps_zero.csv")),
            replay: false)
        XCTAssertNil(missing.todayNative, missing.consoleReport)
        XCTAssertFalse(missing.lambdas.contains { $0 > 0 && missing.todayNative == 0 })
    }

    func testDailyMetricZeroStepsVersusNilSteps() {
        let withZero = metric(day: "2026-05-02", steps: 0)
        let without = metric(day: "2026-05-03", steps: nil)
        let z = LongitudinalBaseline.observations(from: [withZero], series: .wakingSteps)[0]
        let m = LongitudinalBaseline.observations(from: [without], series: .wakingSteps)[0]
        XCTAssertEqual(z.value, 0)
        XCTAssertEqual(z.qualityStatus, .ok)
        XCTAssertNil(m.value)
        XCTAssertEqual(m.qualityStatus, .missing)
    }

    // MARK: - Range / quality / series isolation

    func test200BpmIsNotTrainable() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = (1...7).map { ok(iso(t - $0), 60) }
        obs.append(LBDailyObservation(day: asOf, value: 200, qualityStatus: .ok))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: obs, replay: false)
        XCTAssertNil(ev.todayNative, ev.consoleReport)
        XCTAssertEqual(ev.n7, 7)
    }

    func testSpO2OutOfRangeAndNadirAreDistinctSeries() {
        let bad50 = metric(day: asOf, spo2: 50)
        let bad101 = metric(day: asOf, spo2: 101)
        let good = metric(day: asOf, spo2: 96)
        XCTAssertEqual(LongitudinalBaseline.observations(from: [bad50], series: .sleepSpO2Mean)[0].qualityReason, .outOfRange)
        XCTAssertEqual(LongitudinalBaseline.observations(from: [bad101], series: .sleepSpO2Mean)[0].qualityReason, .outOfRange)
        XCTAssertEqual(LongitudinalBaseline.observations(from: [good], series: .sleepSpO2Mean)[0].qualityStatus, .ok)
        XCTAssertTrue(LongitudinalBaseline.observations(from: [good], series: .sleepSpO2Nadir).isEmpty,
                      "nadir has no DailyMetric column yet")
    }

    func testSleepAndAwakeRestDoNotShareObservations() {
        let rows = [metric(day: asOf, rhr: 58, hrv: 50)]
        XCTAssertFalse(LongitudinalBaseline.observations(from: rows, series: .sleepRHR).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: rows, series: .awakeRestHR).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: rows, series: .awakeActiveHR).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: rows, series: .continuousHR).isEmpty)
        XCTAssertTrue(LongitudinalBaseline.observations(from: rows, series: .sleepHRVLn)[0].value == 50)
        XCTAssertTrue(LongitudinalBaseline.observations(from: rows, series: .awakeRestHRVLn).isEmpty)
    }

    func testDoesNotReadRecoveryOrSdnn() {
        let row = metric(day: asOf, rhr: 58, hrv: 50, recovery: 88, sdnn: 120)
        let hrv = LongitudinalBaseline.observations(from: [row], series: .sleepHRVLn)[0]
        XCTAssertEqual(hrv.value, 50)
        let points = LongitudinalBaseline.shadowPoints(asOf: asOf, days: [row])
        XCTAssertFalse(points.contains { $0.key == "recovery" || $0.key.contains("recovery") })
        XCTAssertFalse(points.contains { $0.key.contains("sdnn") })
    }

    func testShadowKeysUseLbV1Prefix() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var days: [DailyMetric] = []
        for i in 1...7 {
            days.append(metric(day: iso(t - i), rhr: 60, hrv: 50, spo2: 96, temp: 33, resp: 15, steps: 8000))
        }
        days.append(metric(day: asOf, rhr: 72, hrv: 32, spo2: 94, temp: 33.8, resp: 17.5, steps: 4200))
        let points = LongitudinalBaseline.shadowPoints(asOf: asOf, days: days)
        XCTAssertTrue(points.contains { $0.key == "lb_v1_sleep_rhr_n_7" })
        XCTAssertTrue(points.contains { $0.key == "lb_v1_sleep_rhr_usual_trust_pct_7" })
        XCTAssertTrue(points.contains { $0.key.hasPrefix("lb_v1_sleep_hrv_ln_") })
        XCTAssertTrue(points.contains { $0.key.hasPrefix("lb_v1_waking_steps_") })
        XCTAssertFalse(points.contains { $0.key.hasPrefix("lb_v1_awake_rest") },
                       "stub series must not shadow until a column exists")
    }

    func testQualityMixDoesNotTrainOutOfRangeOrMissing() {
        let ev = evaluateFixture("quality_mix.csv", series: .sleepRHR, replay: false)
        XCTAssertEqual(ev.n7, 5, "200 bpm and missing must not enter n_7\n\(ev.consoleReport)")
        XCTAssertTrue(ev.show7)
    }

    func testLayer1DoesNotBlendSeries() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let rhr = (1...7).map { ok(iso(t - $0), 72) } + [ok(iso(t), 72)]
        let hrv = (1...7).map { ok(iso(t - $0), 50) } + [ok(iso(t), 32)]
        let a = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR, observations: rhr, replay: false)
        let b = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepHRVLn, observations: hrv, replay: false)
        XCTAssertNotEqual(a.copy7?.center, b.copy7?.center)
        XCTAssertNotEqual(a.series, b.series, "layer 1 keeps series separate; there is no blended z")
    }

    func testStubSeriesEvaluateFromFixtureTape() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let obs = (1...7).map { ok(iso(t - $0), 91) } + [ok(iso(t), 88)]
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepSpO2Nadir,
                                               observations: obs, replay: false)
        XCTAssertTrue(ev.show7, ev.consoleReport)
        XCTAssertEqual(ev.copy7?.spread ?? 0, 0.5, accuracy: 1e-9, "SpO₂ floor")
    }

    func testFloorsOnTempAndResp() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let temp = [32.80, 32.85, 32.90, 33.00, 33.10].enumerated().map { i, v in
            ok(iso(t - 5 + i), v)
        } + [ok(iso(t), 33.80)]
        let evT = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepTemp,
                                                observations: temp, replay: false)
        XCTAssertEqual(evT.copy7?.spread ?? 0, 0.3, accuracy: 1e-9, evT.consoleReport)

        let resp = [14.5, 14.6, 14.8, 15.0, 15.2].enumerated().map { i, v in
            ok(iso(t - 5 + i), v)
        } + [ok(iso(t), 17.5)]
        let evR = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepResp,
                                                observations: resp, replay: false)
        XCTAssertEqual(evR.copy7?.spread ?? 0, 0.5, accuracy: 1e-9, evR.consoleReport)
    }

    func testAwakeRestUnder30StillMinutesDoesNotTrain() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = (1...7).map { ok(iso(t - $0), 66, seriesCoverage: 40) }
        obs.append(LBDailyObservation(day: asOf, value: 75, qualityStatus: .ok, coverage: 10))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .awakeRestHR,
                                               observations: obs, replay: false)
        XCTAssertNil(ev.todayNative, ev.consoleReport)
        XCTAssertEqual(ev.n7, 7)
    }

    func testAwakeActiveUnder30MovingMinutesDoesNotTrain() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = (1...7).map { ok(iso(t - $0), 84, seriesCoverage: 40) }
        obs.append(LBDailyObservation(day: asOf, value: 102, qualityStatus: .ok, coverage: 10))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .awakeActiveHR,
                                               observations: obs, replay: false)
        XCTAssertNil(ev.todayNative, ev.consoleReport)
        XCTAssertEqual(ev.n7, 7)
    }

    func testContinuousUnderFourHoursDoesNotTrain() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var obs = (1...7).map { ok(iso(t - $0), 72, seriesCoverage: 300) }
        obs.append(LBDailyObservation(day: asOf, value: 86, qualityStatus: .ok, coverage: 60))
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .continuousHR,
                                               observations: obs, replay: false)
        XCTAssertNil(ev.todayNative, ev.consoleReport)
        XCTAssertEqual(ev.n7, 7)
    }

    func testSpO2SevenSlotsIsMissingNotAMeanOfSeven() {
        let obs = [LBDailyObservation(day: asOf, value: 96, qualityStatus: .ok, coverage: 7)]
        let indexed = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepSpO2Mean,
                                                    observations: obs, replay: false)
        XCTAssertNil(indexed.todayNative, indexed.consoleReport)
        XCTAssertEqual(indexed.n7, 0)
    }

    func testSparseSleepFromDailyMetricDoesNotTrain() {
        let row = metric(day: asOf, rhr: 58, hrOnly: true)
        let obs = LongitudinalBaseline.observations(from: [row], series: .sleepRHR)[0]
        XCTAssertEqual(obs.qualityStatus, .lowQuality)
        XCTAssertEqual(obs.qualityReason, .sparseSleep)
        let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: .sleepRHR,
                                               observations: [obs], replay: false)
        XCTAssertEqual(ev.n7, 0)
    }

    // MARK: - DailyMetric helper

    func metric(day: String, rhr: Int? = nil, hrv: Double? = nil, recovery: Double? = nil,
                spo2: Double? = nil, temp: Double? = nil, resp: Double? = nil,
                steps: Int? = nil, sdnn: Double? = nil, hrOnly: Bool? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                    recovery: recovery, strain: nil, exerciseCount: nil, spo2Pct: spo2,
                    skinTempDevC: nil, respRateBpm: resp, steps: steps, avgSdnn: sdnn,
                    skinTempC: temp, sleepHrOnly: hrOnly)
    }
}
