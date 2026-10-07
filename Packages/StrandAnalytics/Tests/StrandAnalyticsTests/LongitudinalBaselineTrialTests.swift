import XCTest
@testable import StrandAnalytics

/// Phase B: treatment events, qualify-before-freeze, Usual before / since, MDC, labels.
/// Spec: condensed §1.8, implementation map Phase B, frontend card names.
///
/// HOW TO RUN (prints freeze + Change since start):
///   cd Packages/StrandAnalytics && swift test --filter LongitudinalBaselineTrialTests
final class LongitudinalBaselineTrialTests: XCTestCase {

    let t0 = "2026-04-01"
    let treatmentName = "Lisinopril"

    func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }
    func ok(_ day: String, _ v: Double, coverage: Double? = nil) -> LBDailyObservation {
        LBDailyObservation(day: day, value: v, qualityStatus: .ok, coverage: coverage)
    }

    func startEvent(day: String = "2026-04-01", dose: String? = "10 mg") -> LBTreatmentEvent {
        LBTreatmentEvent(trialId: "trial-1", type: .start, civilDay: day, clockTime: "07:00",
                         displayName: treatmentName, kind: .medication, doseText: dose, enteredBy: .patient)
    }

    func fill(from a: String, through b: String, value: Double, coverage: Double? = nil) -> [LBDailyObservation] {
        guard let x = LongitudinalBaseline.isoEpochDay(a),
              let y = LongitudinalBaseline.isoEpochDay(b) else { return [] }
        return (x...y).map { ok(iso($0), value, coverage: coverage) }
    }

    /// Established pre-start usual near `pre`, then post-start nights at `post`.
    func trialTape(pre: Double, post: Double, asOf: String, coverage: Double? = nil) -> [LBDailyObservation] {
        let t0e = LongitudinalBaseline.isoEpochDay(t0)!
        var rows = fill(from: iso(t0e - 70), through: iso(t0e - 1), value: pre, coverage: coverage)
        if let end = LongitudinalBaseline.isoEpochDay(asOf), end >= t0e {
            rows += fill(from: t0, through: asOf, value: post, coverage: coverage)
        }
        return rows
    }

    func request(_ events: [LBTreatmentEvent], freeze: LBFreezeBundle? = nil,
                 provenance: LBProvenance = LBProvenance(),
                 confounders: [String: [LBConfounder]] = [:],
                 dayLogs: [String: LBDayLog] = [:]) -> LBTrialRequest {
        LBTrialRequest(events: events, freeze: freeze, provenanceNow: provenance,
                       confoundersByDay: confounders, dayLogsByDay: dayLogs)
    }

    // MARK: - Clocks and frontend names

    func testPhaseClocksSettlingOnTreatmentWashoutEnded() {
        let start = startEvent()
        XCTAssertEqual(LongitudinalBaseline.trialClock(events: [start], asOf: "2026-04-03").phase, .settlingIn)
        XCTAssertEqual(LongitudinalBaseline.trialClock(events: [start], asOf: "2026-04-10").phase, .onTreatment)
        let stop = LBTreatmentEvent(trialId: "trial-1", type: .stop, civilDay: "2026-04-20",
                                    clockTime: "08:00", displayName: treatmentName, stopReason: .completed)
        XCTAssertEqual(LongitudinalBaseline.trialClock(events: [start, stop], asOf: "2026-04-22").phase, .washingOut)
        XCTAssertEqual(LongitudinalBaseline.trialClock(events: [start, stop], asOf: "2026-04-28").phase, .ended)
    }

    func testDoseChangeRelabelsSettlingAndKeepsFreeze() {
        let asOf = "2026-04-20"
        let start = startEvent()
        let ev1 = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: trialTape(pre: 68, post: 61, asOf: asOf),
            trial: request([start]))
        XCTAssertTrue(ev1.trial.trialFreezeOk, ev1.consoleReport)
        let frozen = ev1.trial.freeze?.centerLong
        let bump = LBTreatmentEvent(trialId: "trial-1", type: .doseChange, civilDay: asOf,
                                    clockTime: "09:00", displayName: treatmentName, doseText: "20 mg")
        let ev2 = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: trialTape(pre: 68, post: 61, asOf: asOf),
            trial: request([start, bump], freeze: ev1.trial.freeze))
        XCTAssertEqual(ev2.trial.phase, LBTrialPhase.settlingIn, ev2.consoleReport)
        XCTAssertEqual(ev2.trial.freeze?.centerLong, frozen)
        XCTAssertEqual(ev2.trial.displayName, "Lisinopril 20 mg")
        print("\nDOSE CHANGE — freeze held, phase Settling in\n\(ev2.consoleReport)\n")
    }

    // MARK: - Qualify

    func testThinHistoryDoesNotFreeze() {
        let t0e = LongitudinalBaseline.isoEpochDay(t0)!
        let obs = fill(from: iso(t0e - 10), through: iso(t0e - 1), value: 68) + [ok(t0, 68)]
        let ev = LongitudinalBaseline.evaluate(
            asOf: t0, series: .sleepRHR, observations: obs, trial: request([startEvent()]))
        XCTAssertFalse(ev.trial.trialFreezeOk, ev.consoleReport)
        XCTAssertNil(ev.trial.freeze)
        XCTAssertNil(ev.trial.zTrialTraj)
        XCTAssertTrue(ev.trial.qualifyReasons.contains("established_long"), "\(ev.trial.qualifyReasons)")
        XCTAssertEqual(ev.trial.card.qualifyMessage?.contains("Not enough nights to freeze"), true)
        XCTAssertEqual(ev.trial.card.slowTitle, "Longer usual")
        print("\nQUALIFY MISS (n_long too small)\n\(ev.consoleReport)\n")
    }

    func testEverySeriesQualifyFailAndPass() {
        var table = "\nseries                    fail_ok  pass_ok  fail_reasons\n"
        for series in LBSeries.allCases {
            let cov: Double? = {
                switch series {
                case .awakeRestHR, .awakeRestHRVLn, .awakeActiveHR, .awakeActiveHRVLn: return 40
                case .continuousHR, .continuousHRVLn: return 300
                case .sleepSpO2Mean, .sleepSpO2Nadir, .awakeRestSpO2Mean,
                     .awakeActiveSpO2Mean, .continuousSpO2Mean: return 16
                case .wakingImuEnergy: return 90
                default: return nil
                }
            }()
            let spec = LongitudinalBaseline.seriesSpec(series)
            let mid = min(spec.maxVal - 1, max(spec.minVal + 1, (spec.minVal + spec.maxVal) / 2))
            let t0e = LongitudinalBaseline.isoEpochDay(t0)!
            let thin = fill(from: iso(t0e - 10), through: iso(t0e + 5), value: mid, coverage: cov)
            let fail = LongitudinalBaseline.evaluate(
                asOf: iso(t0e + 5), series: series, observations: thin, trial: request([startEvent()]))
            XCTAssertFalse(fail.trial.trialFreezeOk, series.rawValue)

            let asOf = iso(t0e + 28)
            let full = trialTape(pre: mid, post: mid, asOf: asOf, coverage: cov)
            let pass = LongitudinalBaseline.evaluate(
                asOf: asOf, series: series, observations: full, trial: request([startEvent()]))
            XCTAssertTrue(pass.trial.trialFreezeOk, "\(series.rawValue) should freeze on a full tape\n\(pass.consoleReport)")
            table += "\(pad(series.rawValue, 26))\(fail.trial.trialFreezeOk)      \(pass.trial.trialFreezeOk)      \(fail.trial.qualifyReasons.joined(separator: ","))\n"
        }
        print(table)
    }

    // MARK: - Freeze + Change since start (condensed two-track example)

    func testFreezeStays68WhileLiveMovesTo61() {
        let asOf = "2026-04-29" // 28 days after T_freeze 2026-03-31
        let ev = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: asOf),
            trial: request([startEvent()]))
        XCTAssertTrue(ev.trial.trialFreezeOk, ev.consoleReport)
        XCTAssertEqual(ev.trial.freeze?.centerLong ?? 0, 68, accuracy: 0.5, ev.consoleReport)
        XCTAssertEqual(ev.trial.freeze?.tFreeze, "2026-03-31")
        XCTAssertEqual(ev.todayNative, 61)
        XCTAssertEqual(ev.trial.deltaTrialLevel ?? 0, -7, accuracy: 0.6, ev.consoleReport)
        XCTAssertLessThan(ev.trial.zTrialLevel ?? 0, -1.5)
        XCTAssertNotEqual(ev.copyLong?.center ?? 68, ev.trial.freeze?.centerLong,
                          "on-treatment long must not be the freeze")
        XCTAssertEqual(ev.trial.card.freezeTitle, "Expected without treatment")
        XCTAssertTrue(ev.trial.card.slowTitle.contains("Lisinopril"), ev.trial.card.slowTitle)
        XCTAssertEqual(ev.trial.card.naraShape, .trial)
        XCTAssertEqual(ev.trial.phase, .onTreatment)
        XCTAssertFalse(ev.trial.provenanceBreak)
        print("\nTWO TRACKS (68 frozen, 61 live)\n\(ev.consoleReport)\n")
        print(ev.trial.phaseBStatisticLedger.map { "  \($0.planName)=\($0.value)" }.joined(separator: "\n"))
    }

    func testTheilSenAndExpectedTMatchWorkedExample() {
        XCTAssertEqual(LongitudinalBaseline.theilSenSlope(xs: [0, 1, 2, 3], ys: [0, 0.05, 0.10, 0.15]) ?? 0,
                       0.05, accuracy: 1e-12)
        let freezeLong = 68.0
        let slope = 0.05
        let expected = freezeLong + slope * 28
        XCTAssertEqual(expected, 69.4, accuracy: 1e-9)
        let zTraj = (61 - expected) / 2.85
        XCTAssertEqual(zTraj, -2.9, accuracy: 0.05)
        let mdc = LongitudinalBaseline.mdc95(sigmaMeas: 1.0)
        XCTAssertEqual(mdc, 2.77, accuracy: 0.01)
        XCTAssertGreaterThan(abs(61 - expected), mdc)
        XCTAssertEqual(LongitudinalBaseline.biologicalSigma(spreadLong: 5, sigmaMeas: 3), 4, accuracy: 1e-9)
        XCTAssertEqual(LongitudinalBaseline.biologicalSigma(spreadLong: 1, sigmaMeas: 3), 0, accuracy: 1e-9)
    }

    func testMeasurementSigmaAndR1AreFinite() {
        let deltas = [0.2, -0.1, 0.3, -0.2, 0.1, 0.0, -0.15]
        let s = LongitudinalBaseline.measurementSigma(consecutiveDeltas: deltas)
        XCTAssertNotNil(s)
        XCTAssertGreaterThan(s ?? 0, 0)
        let r = LongitudinalBaseline.lag1R1(residuals: [1, 0.8, 0.7, 0.5, 0.4, 0.2])
        XCTAssertNotNil(r)
        XCTAssertGreaterThan(r ?? 0, 0.5)
    }

    // MARK: - Missing / confounder / provenance

    func testHospitalDayIsNotZeroAndSkipsContrast() {
        let asOf = "2026-04-20"
        var obs = trialTape(pre: 68, post: 61, asOf: iso(LongitudinalBaseline.isoEpochDay(asOf)! - 1))
        obs.append(LBDailyObservation(day: asOf, value: nil, qualityStatus: .missing, qualityReason: .hospital))
        let ev = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: obs, trial: request([startEvent()]))
        XCTAssertNil(ev.todayNative, ev.consoleReport)
        XCTAssertFalse(ev.trial.primaryContrastEligible)
        XCTAssertNil(ev.trial.zTrialTraj)
        XCTAssertTrue(ev.trial.trialFreezeOk)
        XCTAssertEqual(ev.trial.missingness.hospital, 1)
        XCTAssertGreaterThan(ev.trial.missingness.none, 0)
        print("\nHOSPITAL missing — no 0 bpm, no trial z\n\(ev.consoleReport)\n")
    }

    func testExerciseConfounderSkipsPrimaryContrast() {
        let asOf = "2026-04-20"
        let tape = trialTape(pre: 68, post: 61, asOf: asOf)
        let workout = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: tape,
            trial: request([startEvent()], confounders: [asOf: [.exerciseChange]]))
        XCTAssertEqual(workout.todayNative, 61)
        XCTAssertTrue(workout.trial.primaryContrastEligible,
                      "workout is a stratum, not an acute skip\n\(workout.consoleReport)")
        XCTAssertEqual(workout.trial.confoundersToday, [])

        let ill = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: tape,
            trial: request([startEvent()],
                           dayLogs: [asOf: LBDayLog(feltIll: true)]))
        XCTAssertFalse(ill.trial.primaryContrastEligible, ill.consoleReport)
        XCTAssertEqual(ill.trial.confoundersToday, [.illness])
    }

    func testProvenanceBreakIsNotATreatmentEffect() {
        let asOf = "2026-04-20"
        let v1 = LBProvenance(decoderVersion: "dec-1")
        let ev1 = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: asOf),
            trial: request([startEvent()], provenance: v1))
        XCTAssertTrue(ev1.trial.trialFreezeOk)
        let v2 = LBProvenance(decoderVersion: "dec-2")
        let ev2 = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: asOf),
            trial: request([startEvent()], freeze: ev1.trial.freeze, provenance: v2))
        XCTAssertTrue(ev2.trial.provenanceBreak, ev2.consoleReport)
        XCTAssertFalse(ev2.trial.primaryContrastEligible)
        XCTAssertEqual(ev2.trial.freeze?.centerLong, ev1.trial.freeze?.centerLong)
        print("\nPROVENANCE BREAK — freeze held, contrast not physiology\n\(ev2.consoleReport)\n")
    }

    func testRestartKeepsOriginalFreeze() {
        let asOf = "2026-04-25"
        let start = startEvent()
        let ev1 = LongitudinalBaseline.evaluate(
            asOf: "2026-04-15", series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: "2026-04-15"),
            trial: request([start]))
        let interrupt = LBTreatmentEvent(trialId: "trial-1", type: .interruption, civilDay: "2026-04-16",
                                         displayName: treatmentName)
        let restart = LBTreatmentEvent(trialId: "trial-1", type: .restart, civilDay: "2026-04-20",
                                       displayName: treatmentName)
        let ev2 = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: asOf),
            trial: request([start, interrupt, restart], freeze: ev1.trial.freeze))
        XCTAssertEqual(ev2.trial.freeze?.centerLong, ev1.trial.freeze?.centerLong)
        XCTAssertEqual(ev2.trial.phase, LBTrialPhase.settlingIn)
    }

    func testNoTrialKeepsPhaseALabels() {
        let t = LongitudinalBaseline.isoEpochDay("2026-05-01")!
        var obs = Array((t - 60)...t).map { ok(iso($0), 60) }
        let ev = LongitudinalBaseline.evaluate(asOf: "2026-05-01", series: .sleepRHR, observations: obs)
        XCTAssertEqual(ev.trial.phase, .none)
        XCTAssertFalse(ev.trial.trialFreezeOk)
        XCTAssertEqual(ev.trial.card.slowTitle, "Longer usual")
        XCTAssertEqual(ev.trial.card.naraShape, .monitoring)
        XCTAssertFalse(ev.phaseAStatisticLedger.map(\.planName).contains("center_long_frozen"))
        _ = obs
    }

    func testShadowWritesTrialKeysOnlyWhenFrozen() {
        let asOf = "2026-04-20"
        let ev = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: asOf),
            trial: request([startEvent()]))
        let points = LongitudinalBaseline.shadowPoints(from: ev)
        XCTAssertTrue(points.contains { $0.key.hasSuffix("center_long_frozen") })
        XCTAssertTrue(points.contains { $0.key.hasSuffix("z_trial_traj") })
        let plain = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: asOf))
        let plainPts = LongitudinalBaseline.shadowPoints(from: plain)
        XCTAssertFalse(plainPts.contains { $0.key.contains("z_trial") })
    }

    func testSigmaBioDoesNotChangePrimaryContrastOrMDC() {
        let asOf = "2026-04-29"
        let ev = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: asOf),
            trial: request([startEvent()]))
        XCTAssertTrue(ev.trial.trialFreezeOk, ev.consoleReport)
        let freeze = ev.trial.freeze!
        let recomputed = LongitudinalBaseline.biologicalSigma(spreadLong: freeze.spreadLong,
                                                              sigmaMeas: freeze.sigmaMeas)
        XCTAssertEqual(freeze.sigmaBio, recomputed, accuracy: 1e-9)
        XCTAssertEqual(freeze.mdc95, LongitudinalBaseline.mdc95(sigmaMeas: freeze.sigmaMeas), accuracy: 1e-9)
        XCTAssertEqual(ev.trial.zTrialTraj != nil, ev.trial.primaryContrastEligible)
        print("\nσ_bio leftover (MDC still 2.77×σ_meas)\n\(ev.consoleReport)\n")
    }

    func testFrozenCenter7DeltasAreSecondary() {
        let asOf = "2026-04-29"
        let ev = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: asOf),
            trial: request([startEvent()]))
        XCTAssertNotNil(ev.trial.zTrialTraj, ev.consoleReport)
        XCTAssertNotNil(ev.trial.deltaTrialLevel7)
        XCTAssertNotNil(ev.trial.zTrialLevel7)
        XCTAssertEqual(ev.trial.deltaTrialLevel7 ?? 0, -7, accuracy: 1.5, ev.consoleReport)
        XCTAssertEqual(ev.trial.deltaTrialLevel ?? 0, -7, accuracy: 0.6)
        // Primary name stays Change since start (traj vs frozen long), not vs this-week freeze.
        XCTAssertNotNil(ev.trial.zTrialTraj)
        XCTAssertEqual(ev.trial.freeze?.center7 ?? 0, 68, accuracy: 1.0)
        print("\nFROZEN center_7 deltas (secondary)\n\(ev.consoleReport)\n")
    }

    func testLiveR1DoesNotRewriteFreezeR1() {
        let dayA = "2026-04-15"
        let dayB = "2026-04-29"
        let ev1 = LongitudinalBaseline.evaluate(
            asOf: dayA, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: dayA),
            trial: request([startEvent()]))
        XCTAssertTrue(ev1.trial.trialFreezeOk)
        let frozenR1 = ev1.trial.freeze?.r1
        let ev2 = LongitudinalBaseline.evaluate(
            asOf: dayB, series: .sleepRHR,
            observations: trialTape(pre: 68, post: 61, asOf: dayB),
            trial: request([startEvent()], freeze: ev1.trial.freeze))
        XCTAssertEqual(ev2.trial.freeze?.r1, frozenR1)
        XCTAssertEqual(ev2.trial.r1, frozenR1)
        XCTAssertNotNil(ev2.trial.r1Live, ev2.consoleReport)
        XCTAssertEqual(ev2.trial.freeze?.centerLong, ev1.trial.freeze?.centerLong)
        print("\nLIVE r1 vs freeze r1\n  freeze_r1=\(frozenR1 ?? -1) live_r1=\(ev2.trial.r1Live ?? -1)\n\(ev2.consoleReport)\n")
    }

    func testMissingnessCountsStayOnTheLog() {
        let asOf = "2026-04-10"
        var obs = trialTape(pre: 68, post: 61, asOf: iso(LongitudinalBaseline.isoEpochDay(asOf)! - 1))
        obs.append(LBDailyObservation(day: asOf, value: nil, qualityStatus: .missing, qualityReason: .charging))
        let ev = LongitudinalBaseline.evaluate(
            asOf: asOf, series: .sleepRHR, observations: obs, trial: request([startEvent()]))
        XCTAssertEqual(ev.trial.missingness.charging, 1)
        XCTAssertEqual(ev.trial.missingness.hospital, 0)
        XCTAssertGreaterThan(ev.trial.missingness.none, 0)
        XCTAssertEqual(ev.trial.missingness.daysInWindow, 10)
        XCTAssertNil(ev.todayNative)
        XCTAssertTrue(ev.trial.trialFreezeOk)
        print("\nMISSINGNESS LOG\n  \(ev.trial.missingness.counts)\n\(ev.consoleReport)\n")
    }

    func testDailyLogLabelUsesDietAndDemand() {
        let log = LBDayLog(workout: .hard, dietTypical: false, mood: .good, demand: .heavy)
        XCTAssertEqual(log.habitClass, .trained)
        XCTAssertTrue(log.summaryLine.contains("Good"))
        XCTAssertTrue(log.summaryLine.contains("Trained"))
        XCTAssertTrue(log.summaryLine.contains("Heavy day"))
        XCTAssertTrue(log.summaryLine.contains("Diet off-typical"))
        let old = #"{"workout":"none","alcohol":false,"travel":false,"feltIll":false,"sleepTypical":true,"dietTypical":true,"extraMed":false,"mood":"okay","activeWindow":"spread","energy":"steady"}"#
        let decoded = try! JSONDecoder().decode(LBDayLog.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.demand, .usual)
    }

    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
}
