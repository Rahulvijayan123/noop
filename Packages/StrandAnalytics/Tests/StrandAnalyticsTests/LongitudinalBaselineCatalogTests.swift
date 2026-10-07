import XCTest
@testable import StrandAnalytics

/// Catalog of every biometric and every Phase A statistic in the condensed plan.
///
/// HOW TO RUN (prints the series table + one ledger per biometric):
///   cd Packages/StrandAnalytics && swift test --filter LongitudinalBaselineCatalogTests
///
/// This is the “is everything accounted for?” gate. If a plan series, v1 constant, floor,
/// or §2 snapshot field is missing, this file fails — not a later UI screen.
final class LongitudinalBaselineCatalogTests: XCTestCase {

    let asOf = "2026-05-01"

    struct WorkedWeek {
        let series: LBSeries
        let weekOldestToNewest: [Double]
        let today: Double
        let center7: Double
        let centerDisplay: Double
        let spread: Double
        let z7: Double
        let bandLo: Double
        let bandHi: Double
        let coverage: Double?
        let centerTol: Double
        let spreadTol: Double
        let zTol: Double
        let bandTol: Double
    }

    /// Condensed plan §5.1–5.17. Still/moving is a minute gate, not a week of its own.
    func workedWeeks() -> [WorkedWeek] {
        [
            WorkedWeek(series: .sleepRHR,
                       weekOldestToNewest: [57, 58, 59, 60, 61, 62, 63], today: 72,
                       center7: 61.1, centerDisplay: 61.1, spread: 2.85, z7: 3.8,
                       bandLo: 55.4, bandHi: 66.8, coverage: nil,
                       centerTol: 0.08, spreadTol: 0.08, zTol: 0.15, bandTol: 0.2),
            WorkedWeek(series: .awakeRestHR,
                       weekOldestToNewest: [64, 65, 66, 67, 68, 69, 70], today: 75,
                       center7: 68.1, centerDisplay: 68.1, spread: 3.0, z7: 2.3,
                       bandLo: 62.1, bandHi: 74.1, coverage: 40,
                       centerTol: 0.08, spreadTol: 0.02, zTol: 0.15, bandTol: 0.2),
            WorkedWeek(series: .awakeActiveHR,
                       weekOldestToNewest: [78, 80, 82, 84, 86, 88, 90], today: 102,
                       center7: 86.16, centerDisplay: 86.16, spread: 5.70, z7: 2.8,
                       bandLo: 74.8, bandHi: 97.6, coverage: 40,
                       centerTol: 0.08, spreadTol: 0.08, zTol: 0.15, bandTol: 0.3),
            WorkedWeek(series: .continuousHR,
                       weekOldestToNewest: [70, 71, 72, 73, 74, 75, 76], today: 86,
                       center7: 74.08, centerDisplay: 74.08, spread: 5.0, z7: 2.4,
                       bandLo: 64.1, bandHi: 84.1, coverage: 300,
                       centerTol: 0.08, spreadTol: 0.02, zTol: 0.15, bandTol: 0.2),
            WorkedWeek(series: .sleepHRVLn,
                       weekOldestToNewest: [40, 45, 48, 50, 55], today: 32,
                       center7: 3.898, centerDisplay: 49.3, spread: 0.135, z7: -3.2,
                       bandLo: 37.6, bandHi: 64.6, coverage: nil,
                       centerTol: 0.02, spreadTol: 0.02, zTol: 0.25, bandTol: 1.5),
            WorkedWeek(series: .awakeRestHRVLn,
                       weekOldestToNewest: [28, 30, 32, 31, 29], today: 22,
                       center7: 3.403, centerDisplay: 30.1, spread: 0.08, z7: -3.9,
                       bandLo: 25.6, bandHi: 35.3, coverage: 40,
                       centerTol: 0.02, spreadTol: 0.002, zTol: 0.25, bandTol: 1.5),
            WorkedWeek(series: .awakeActiveHRVLn,
                       weekOldestToNewest: [22, 24, 25, 26, 24], today: 16,
                       center7: 3.196, centerDisplay: 24.4, spread: 0.08, z7: -5.3,
                       bandLo: 20.8, bandHi: 28.7, coverage: 40,
                       centerTol: 0.02, spreadTol: 0.002, zTol: 0.25, bandTol: 1.5),
            WorkedWeek(series: .continuousHRVLn,
                       weekOldestToNewest: [35, 38, 40, 42, 39], today: 28,
                       center7: 3.672, centerDisplay: 39.3, spread: 0.08, z7: -4.2,
                       bandLo: 33.5, bandHi: 46.1, coverage: 300,
                       centerTol: 0.02, spreadTol: 0.002, zTol: 0.25, bandTol: 1.5),
            WorkedWeek(series: .sleepResp,
                       weekOldestToNewest: [14.5, 14.6, 14.8, 15.0, 15.2], today: 17.5,
                       center7: 14.92, centerDisplay: 14.92, spread: 0.50, z7: 5.2,
                       bandLo: 13.92, bandHi: 15.92, coverage: nil,
                       centerTol: 0.03, spreadTol: 0.002, zTol: 0.2, bandTol: 0.05),
            WorkedWeek(series: .sleepTemp,
                       weekOldestToNewest: [32.80, 32.85, 32.90, 33.00, 33.10], today: 33.80,
                       center7: 32.97, centerDisplay: 32.97, spread: 0.30, z7: 2.8,
                       bandLo: 32.37, bandHi: 33.57, coverage: nil,
                       centerTol: 0.03, spreadTol: 0.002, zTol: 0.2, bandTol: 0.05),
            WorkedWeek(series: .sleepSpO2Mean,
                       weekOldestToNewest: [96.0, 96.2, 96.5, 96.8, 97.0, 96.4, 96.1], today: 94.0,
                       center7: 96.43, centerDisplay: 96.43, spread: 0.50, z7: -4.9,
                       bandLo: 95.43, bandHi: 97.43, coverage: 16,
                       centerTol: 0.05, spreadTol: 0.02, zTol: 0.25, bandTol: 0.1),
            WorkedWeek(series: .sleepSpO2Nadir,
                       weekOldestToNewest: [95, 94, 95, 96, 95, 94, 95], today: 91,
                       center7: 94.84, centerDisplay: 94.84, spread: 0.50, z7: -7.7,
                       bandLo: 93.84, bandHi: 95.84, coverage: 16,
                       centerTol: 0.08, spreadTol: 0.02, zTol: 0.4, bandTol: 0.15),
            WorkedWeek(series: .awakeRestSpO2Mean,
                       weekOldestToNewest: [96.0, 96.2, 96.5, 96.8, 97.0, 96.4, 96.1], today: 94.0,
                       center7: 96.43, centerDisplay: 96.43, spread: 0.50, z7: -4.9,
                       bandLo: 95.43, bandHi: 97.43, coverage: 16,
                       centerTol: 0.05, spreadTol: 0.02, zTol: 0.25, bandTol: 0.1),
            WorkedWeek(series: .awakeActiveSpO2Mean,
                       weekOldestToNewest: [95.0, 95.2, 95.5, 95.8, 96.0, 95.4, 95.1], today: 93.0,
                       center7: 95.43, centerDisplay: 95.43, spread: 0.50, z7: -4.9,
                       bandLo: 94.43, bandHi: 96.43, coverage: 16,
                       centerTol: 0.05, spreadTol: 0.02, zTol: 0.25, bandTol: 0.1),
            WorkedWeek(series: .continuousSpO2Mean,
                       weekOldestToNewest: [96.0, 96.2, 96.5, 96.8, 97.0, 96.4, 96.1], today: 94.0,
                       center7: 96.43, centerDisplay: 96.43, spread: 0.50, z7: -4.9,
                       bandLo: 95.43, bandHi: 97.43, coverage: 16,
                       centerTol: 0.05, spreadTol: 0.02, zTol: 0.25, bandTol: 0.1),
            WorkedWeek(series: .wakingSteps,
                       weekOldestToNewest: [8000, 9200, 7500, 11000, 8800, 6400, 9100], today: 4200,
                       center7: 8503, centerDisplay: 8503, spread: 1034, z7: -4.2,
                       bandLo: 6435, bandHi: 10571, coverage: nil,
                       centerTol: 8, spreadTol: 15, zTol: 0.2, bandTol: 40),
            WorkedWeek(series: .wakingActiveMin,
                       weekOldestToNewest: [42, 55, 38, 70, 50, 28, 48], today: 18,
                       center7: 45.9, centerDisplay: 45.9, spread: 11.8, z7: -2.4,
                       bandLo: 22.3, bandHi: 69.5, coverage: nil,
                       centerTol: 0.15, spreadTol: 0.3, zTol: 0.2, bandTol: 0.8),
            WorkedWeek(series: .wakingImuEnergy,
                       weekOldestToNewest: [0.12, 0.13, 0.14, 0.15, 0.16, 0.14, 0.13], today: 0.28,
                       center7: 0.140, centerDisplay: 0.140, spread: 0.020, z7: 7.0,
                       bandLo: 0.10, bandHi: 0.18, coverage: 90,
                       centerTol: 0.01, spreadTol: 0.01, zTol: 1.5, bandTol: 0.05),
        ]
    }

    func iso(_ epoch: Int) -> String { LongitudinalBaseline.isoFromEpochDay(epoch) }

    func ok(_ day: String, _ value: Double, coverage: Double?) -> LBDailyObservation {
        LBDailyObservation(day: day, value: value, qualityStatus: .ok, coverage: coverage)
    }

    /// Week values sit against T−1; missing older slots stay empty (not zero).
    func weekTape(_ w: WorkedWeek, asOf: String) -> [LBDailyObservation] {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        let startAge = w.weekOldestToNewest.count - 1
        for (i, value) in w.weekOldestToNewest.enumerated() {
            let age = startAge - i
            rows.append(ok(iso(t - 1 - age), value, coverage: w.coverage))
        }
        rows.append(ok(iso(t), w.today, coverage: w.coverage))
        return rows
    }

    /// Same week plus a full when-well tape so both copies exist.
    func bothCopiesTape(_ w: WorkedWeek, asOf: String) -> [LBDailyObservation] {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let typical = w.weekOldestToNewest[w.weekOldestToNewest.count / 2]
        var rows = Array((t - 60)...(t - 8))
            .map { ok(iso($0), typical, coverage: w.coverage) }
        rows.append(contentsOf: weekTape(w, asOf: asOf))
        return rows
    }

    // MARK: - Every biometric is a series

    func testPlanListsExactlySeventeenBiometrics() {
        XCTAssertEqual(LBSeries.allCases.count, 18, LongitudinalBaseline.planCatalogText())
        let ids = LBSeries.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, 18)
        let expected = [
            "sleep_rhr", "sleep_hrv_ln", "sleep_temp", "sleep_resp",
            "sleep_spo2_mean", "sleep_spo2_nadir",
            "awake_rest_hr", "awake_rest_hrv_ln", "awake_rest_spo2_mean",
            "awake_active_hr", "awake_active_hrv_ln", "awake_active_spo2_mean",
            "continuous_hr", "continuous_hrv_ln", "continuous_spo2_mean",
            "waking_steps", "waking_active_min", "waking_imu_energy",
        ]
        XCTAssertEqual(ids, expected, LongitudinalBaseline.planCatalogText())
    }

    func testWorkedWeeksCoverEverySeriesOnce() {
        let covered = Set(workedWeeks().map(\.series))
        let missing = LBSeries.allCases.filter { !covered.contains($0) }
        XCTAssertTrue(missing.isEmpty, "no condensed §5 tape for \(missing.map(\.rawValue))")
    }

    func testChargeAndStillMovingAreNotSeries() {
        XCTAssertFalse(LBSeries.allCases.map(\.rawValue).contains("recovery"))
        XCTAssertFalse(LBSeries.allCases.map(\.rawValue).contains("charge"))
        XCTAssertFalse(LBSeries.allCases.map(\.rawValue).contains("still"))
        XCTAssertFalse(LBSeries.allCases.map(\.rawValue).contains("sdnn"))
    }

    func testContextsNeverMix() {
        XCTAssertEqual(LBSeries.sleepRHR.context, .sleep)
        XCTAssertEqual(LBSeries.awakeRestHR.context, .awakeRest)
        XCTAssertEqual(LBSeries.awakeActiveHR.context, .awakeActive)
        XCTAssertEqual(LBSeries.continuousHR.context, .continuous)
        XCTAssertEqual(LBSeries.wakingSteps.context, .wakingLoad)
        XCTAssertNotEqual(LBSeries.awakeRestHR, LBSeries.awakeActiveHR)
        XCTAssertNotEqual(LBSeries.awakeRestHR, LBSeries.continuousHR)
        XCTAssertNotEqual(LBSeries.sleepSpO2Mean, LBSeries.sleepSpO2Nadir)
        XCTAssertNotEqual(LBSeries.wakingSteps, LBSeries.wakingActiveMin)
        XCTAssertNotEqual(LBSeries.wakingImuEnergy.biometricFamily, "motion")
        XCTAssertTrue(LBSeries.wakingImuEnergy.usesWakingEstablishedN)
        XCTAssertTrue(LBSeries.sleepHRVLn.usesLog)
        XCTAssertTrue(LBSeries.awakeActiveHRVLn.usesLog)
        XCTAssertTrue(LBSeries.continuousHRVLn.usesLog)
        XCTAssertFalse(LBSeries.sleepRHR.usesLog)
        XCTAssertFalse(LBSeries.sleepTemp.usesWakingEstablishedN)
        XCTAssertTrue(LBSeries.awakeActiveHR.usesWakingEstablishedN)
        XCTAssertTrue(LBSeries.continuousHR.usesWakingEstablishedN)
    }

    // MARK: - v1 statistics from condensed §1.7 / §2

    func testV1ParametersMatchCondensedPlan() {
        let p = LongitudinalBaseline.Params.self
        XCTAssertEqual(p.paramSet, "v1.review")
        XCTAssertEqual(p.version7, "ewma-span7-mad-k2-7-t4")
        XCTAssertEqual(p.versionLong, "gap7-med-mad-k2-60-cp1")
        XCTAssertEqual(p.span7, 7)
        XCTAssertEqual(p.alpha, 0.25, accuracy: 1e-12)
        XCTAssertEqual(p.lookbackLong, 60)
        XCTAssertEqual(p.gapDays, 7)
        XCTAssertEqual(p.longSlots, 53)
        XCTAssertEqual(p.kBand, 2)
        XCTAssertEqual(p.kLearn, 2)
        XCTAssertEqual(p.nu, 4)
        XCTAssertEqual(p.kCusum, 0.5, accuracy: 1e-12)
        XCTAssertEqual(p.hCusum, 20)
        XCTAssertEqual(p.pThr, 0.90, accuracy: 1e-12)
        XCTAssertEqual(p.n7Show, 4)
        XCTAssertEqual(p.nLongShow, 4)
        XCTAssertEqual(p.nLongEstablished, 14)
        XCTAssertEqual(p.nLongWaking, 21)
        XCTAssertEqual(p.nBorrow, 7)
        XCTAssertEqual(p.pRegime, 0.35, accuracy: 1e-12)
        XCTAssertEqual(p.staleDays, 14)
        XCTAssertEqual(p.madScale, 1.4826, accuracy: 1e-6)
        XCTAssertEqual(p.persistWindow, 3)
        XCTAssertEqual(p.persistHits, 2)
        XCTAssertEqual(p.washInDays, 7)
        XCTAssertEqual(p.washoutDays, 7)

        let names = Set(LongitudinalBaseline.v1ParameterLedger.map(\.planName))
        for required in ["alpha", "k_band", "nu", "k_cusum", "mad_scale", "n_long_waking",
                         "awake_rest_min_still", "awake_active_min_moving", "continuous_min_minutes"] {
            XCTAssertTrue(names.contains(required), "ledger missing \(required)")
        }
    }

    func testFloorsMatchCondensedPlanSection2() {
        let p = LongitudinalBaseline.self
        XCTAssertEqual(p.seriesSpec(.sleepRHR).floor, 2)
        XCTAssertEqual(p.seriesSpec(.awakeRestHR).floor, 3)
        XCTAssertEqual(p.seriesSpec(.awakeActiveHR).floor, 4)
        XCTAssertEqual(p.seriesSpec(.continuousHR).floor, 5)
        XCTAssertEqual(p.seriesSpec(.sleepHRVLn).floor, 0.08)
        XCTAssertEqual(p.seriesSpec(.awakeRestHRVLn).floor, 0.08)
        XCTAssertEqual(p.seriesSpec(.awakeActiveHRVLn).floor, 0.08)
        XCTAssertEqual(p.seriesSpec(.continuousHRVLn).floor, 0.08)
        XCTAssertEqual(p.seriesSpec(.sleepResp).floor, 0.5)
        XCTAssertEqual(p.seriesSpec(.sleepTemp).floor, 0.3)
        XCTAssertEqual(p.seriesSpec(.sleepSpO2Mean).floor, 0.5)
        XCTAssertEqual(p.seriesSpec(.sleepSpO2Nadir).floor, 0.5)
        XCTAssertEqual(p.seriesSpec(.awakeRestSpO2Mean).floor, 0.5)
        XCTAssertEqual(p.seriesSpec(.awakeActiveSpO2Mean).floor, 0.5)
        XCTAssertEqual(p.seriesSpec(.continuousSpO2Mean).floor, 0.5)
        XCTAssertEqual(p.seriesSpec(.wakingSteps).floor, 500)
        XCTAssertEqual(p.seriesSpec(.wakingActiveMin).floor, 10)
        XCTAssertEqual(p.seriesSpec(.wakingImuEnergy).floor, 0.02)
        XCTAssertEqual(p.nLongEstablished(for: .sleepRHR), 14)
        XCTAssertEqual(p.nLongEstablished(for: .awakeRestHR), 14)
        XCTAssertEqual(p.nLongEstablished(for: .awakeActiveHR), 14)
        XCTAssertEqual(p.nLongEstablished(for: .continuousHR), 14)
        XCTAssertEqual(p.nLongEstablished(for: .wakingSteps), 21)
        XCTAssertEqual(p.nLongEstablished(for: .wakingImuEnergy), 21)
        XCTAssertEqual(p.nLongEstablished(for: .wakingActiveMin), 21)
    }

    func testQualityReasonVocabulary() {
        let reasons: [LBQualityReason] = [
            .poorSignal, .lowCoverage, .outOfRange, .sparseSleep,
            .charging, .deviceOff, .appFail, .hospital, .unknown,
        ]
        XCTAssertEqual(reasons.count, 9)
        XCTAssertEqual(Set(reasons.map(\.rawValue)).count, 9)
    }

    // MARK: - Every biometric: week numbers + both copies + statistic ledger

    func testEveryBiometricWorkedWeekFromCondensedPlan() {
        var catalog = ["\n" + LongitudinalBaseline.planCatalogText(), ""]
        for w in workedWeeks() {
            let ev = LongitudinalBaseline.evaluate(
                asOf: asOf, series: w.series,
                observations: weekTape(w, asOf: asOf), replay: false)
            let row = w.series.planRow
            catalog.append("—— \(row.planName)  (\(row.condensedSection), \(row.unit)) ——")
            catalog.append(ev.consoleReport)
            catalog.append(ev.phaseAStatisticLedger.map { "    \($0.planName)=\($0.value)" }.joined(separator: "\n"))
            catalog.append("")

            let c = ev.copy7
            XCTAssertNotNil(c, "\(row.planName) missing this-week copy\n\(ev.consoleReport)")
            guard let c else { continue }
            let sp = LongitudinalBaseline.params(for: w.series)
            if sp.span7 == 7 {
                XCTAssertEqual(c.center, w.center7, accuracy: w.centerTol,
                               "\(row.planName) center_7\n\(ev.consoleReport)")
                XCTAssertEqual(c.spread, w.spread, accuracy: w.spreadTol,
                               "\(row.planName) spread_7\n\(ev.consoleReport)")
                XCTAssertEqual(ev.z7 ?? 0, w.z7, accuracy: w.zTol,
                               "\(row.planName) z_7\n\(ev.consoleReport)")
            }
            XCTAssertGreaterThan(c.bandHiDisplay, c.bandLoDisplay)
            XCTAssertEqual(ev.paramSet, "v1.review")
            XCTAssertEqual(c.version, LongitudinalBaseline.Params.version7)
            XCTAssertFalse(ev.alertEligible, "\(row.planName): week-only tape is not alert_eligible")
        }
        print(catalog.joined(separator: "\n"))
    }

    func testEveryBiometricReturnsBothCopiesOnAFullTape() {
        for w in workedWeeks() {
            let ev = LongitudinalBaseline.evaluate(
                asOf: asOf, series: w.series,
                observations: bothCopiesTape(w, asOf: asOf), replay: true)
            let name = w.series.planRow.planName
            XCTAssertTrue(ev.show7, "\(name) this week should show\n\(ev.consoleReport)")
            XCTAssertNotNil(ev.copy7, name)
            XCTAssertTrue(ev.showLong, "\(name) when-well should show on a 53-day tape\n\(ev.consoleReport)")
            XCTAssertNotNil(ev.copyLong, name)
            XCTAssertEqual(ev.copy7?.version, LongitudinalBaseline.Params.version7)
            XCTAssertEqual(ev.copyLong?.version, LongitudinalBaseline.Params.versionLong)
            XCTAssertNotNil(ev.gap, "\(name) gap")
            XCTAssertGreaterThan(ev.nLong, 13, "\(name) n_long=\(ev.nLong)")
            if w.series.usesWakingEstablishedN {
                XCTAssertGreaterThanOrEqual(ev.nLong, 21, "\(name) activity-mix series needs 21 to establish")
                XCTAssertTrue(ev.establishedLong, name)
            } else {
                XCTAssertTrue(ev.establishedLong, name)
            }
            assertPhaseALedgerComplete(ev, name: name)
        }
    }

    func testEveryBiometricHonestBuildingWhenTooFewNights() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        for series in LBSeries.allCases {
            let spec = LongitudinalBaseline.seriesSpec(series)
            let mid = (spec.minVal + spec.maxVal) / 2
            let coverage: Double? = {
                switch series {
                case .awakeRestHR, .awakeRestHRVLn, .awakeActiveHR, .awakeActiveHRVLn: return 40
                case .continuousHR, .continuousHRVLn: return 300
                case .sleepSpO2Mean, .sleepSpO2Nadir, .awakeRestSpO2Mean,
                     .awakeActiveSpO2Mean, .continuousSpO2Mean: return 16
                case .wakingImuEnergy: return 90
                default: return nil
                }
            }()
            let obs = [
                ok(iso(t - 3), mid, coverage: coverage),
                ok(iso(t - 2), mid, coverage: coverage),
                ok(iso(t - 1), mid, coverage: coverage),
                ok(iso(t), mid, coverage: coverage),
            ]
            let ev = LongitudinalBaseline.evaluate(asOf: asOf, series: series,
                                                   observations: obs, replay: false)
            XCTAssertFalse(ev.show7, "\(series.rawValue) 3 nights must not show this week\n\(ev.consoleReport)")
            XCTAssertNil(ev.copy7)
            XCTAssertFalse(ev.showLong)
            XCTAssertFalse(ev.establishedLong)
            XCTAssertFalse(ev.alertEligible)
        }
    }

    func testCatalogTextNamesEverySeries() {
        let text = LongitudinalBaseline.planCatalogText()
        for series in LBSeries.allCases {
            XCTAssertTrue(text.contains(series.rawValue), "catalog missing \(series.rawValue)\n\(text)")
            XCTAssertTrue(text.contains(series.planRow.condensedSection), series.rawValue)
        }
        XCTAssertFalse(text.lowercased().contains("charge"))
        print("\n" + text + "\n")
        print("v1 parameters:")
        for row in LongitudinalBaseline.v1ParameterLedger {
            print("  \(row.planName) = \(row.value)")
        }
    }

    func assertPhaseALedgerComplete(_ ev: LBEvaluation, name: String) {
        let ledger = ev.phaseAStatisticLedger
        let keys = Set(ledger.map(\.planName))
        let required = [
            "today", "center_7", "spread_7", "band_7_lo", "band_7_hi", "delta_7", "z_7",
            "center_7_raw", "n_7", "n_learn", "coverage_7", "last_update_7", "version_7",
            "center_long", "spread_long", "band_long_lo", "band_long_hi", "delta_long", "z_long",
            "n_long", "coverage_long", "last_update_long", "version_long",
            "gap", "gap_z", "show_7", "show_long", "established_long", "conf_spread",
            "alert_eligible", "stale", "confidence_pct_7", "confidence_pct_long",
            "p_change", "cusum_s", "regime_shift",
            "two_block_shift", "trim_kept_frac",
            "run_length", "hits_3", "two_of_three", "worse", "param_set", "layer",
        ]
        let missing = required.filter { !keys.contains($0) }
        XCTAssertTrue(missing.isEmpty, "\(name) ledger missing \(missing)")
        for field in ["center_7", "center_long", "spread_7", "spread_long", "z_7", "z_long",
                      "gap", "confidence_pct_7", "confidence_pct_long", "p_change"] {
            let value = ledger.first { $0.planName == field }?.value
            XCTAssertNotEqual(value, "—", "\(name) \(field) should be populated on a full tape")
        }
        XCTAssertEqual(ledger.first { $0.planName == "layer" }?.value, "1")
        XCTAssertFalse(keys.contains("center_long_frozen"), "Phase A must not invent a trial freeze")
    }
}
