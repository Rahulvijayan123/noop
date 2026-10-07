import XCTest
@testable import StrandAnalytics

/// Per-biometric pin of the published Layer 1 statistics (docs/baselines/LAYER1.md).
/// Every series gets the same contract: two copies never averaged, T out of both windows,
/// MAD floor, HRV in ln, confounders drop nights, scheduled med does not.
final class LongitudinalBaselineBiometricLogicTests: XCTestCase {

    let asOf = "2026-06-15"

    func iso(_ e: Int) -> String { LongitudinalBaseline.isoFromEpochDay(e) }

    func coverage(_ s: LBSeries) -> Double? {
        switch s {
        case .awakeRestHR, .awakeRestHRVLn, .awakeActiveHR, .awakeActiveHRVLn: return 40
        case .continuousHR, .continuousHRVLn: return 300
        case .sleepSpO2Mean, .sleepSpO2Nadir, .awakeRestSpO2Mean,
             .awakeActiveSpO2Mean, .continuousSpO2Mean: return 16
        case .wakingImuEnergy: return 90
        default: return nil
        }
    }

    func typical(_ s: LBSeries) -> Double {
        switch s {
        case .sleepRHR: return 60
        case .awakeRestHR: return 70
        case .awakeActiveHR: return 100
        case .continuousHR: return 80
        case .sleepHRVLn, .awakeRestHRVLn, .awakeActiveHRVLn, .continuousHRVLn: return 50
        case .sleepResp: return 15
        case .sleepTemp: return 33.0
        case .sleepSpO2Mean, .awakeRestSpO2Mean, .continuousSpO2Mean: return 96.5
        case .sleepSpO2Nadir, .awakeActiveSpO2Mean: return 95.0
        case .wakingSteps: return 8_000
        case .wakingActiveMin: return 45
        case .wakingImuEnergy: return 0.14
        }
    }

    /// Week level, still in-range, far enough from typical that the copies stay distinct.
    func weekNative(_ s: LBSeries) -> Double {
        switch s {
        case .sleepRHR: return 72
        case .awakeRestHR: return 84
        case .awakeActiveHR: return 118
        case .continuousHR: return 96
        case .sleepHRVLn, .awakeRestHRVLn, .awakeActiveHRVLn, .continuousHRVLn: return 32
        case .sleepResp: return 18
        case .sleepTemp: return 34.2
        case .sleepSpO2Mean, .awakeRestSpO2Mean, .continuousSpO2Mean: return 93.5
        case .sleepSpO2Nadir, .awakeActiveSpO2Mean: return 92.0
        case .wakingSteps: return 13_000
        case .wakingActiveMin: return 75
        case .wakingImuEnergy: return 0.32
        }
    }

    func tonightNative(_ s: LBSeries) -> Double {
        switch s {
        case .sleepRHR: return 88
        case .awakeRestHR: return 102
        case .awakeActiveHR: return 150
        case .continuousHR: return 125
        case .sleepHRVLn, .awakeRestHRVLn, .awakeActiveHRVLn, .continuousHRVLn: return 18
        case .sleepResp: return 22
        case .sleepTemp: return 36.0
        case .sleepSpO2Mean, .awakeRestSpO2Mean, .continuousSpO2Mean: return 90.0
        case .sleepSpO2Nadir, .awakeActiveSpO2Mean: return 88.0
        case .wakingSteps: return 2_200
        case .wakingActiveMin: return 12
        case .wakingImuEnergy: return 0.70
        }
    }

    func ok(_ day: String, _ value: Double, series: LBSeries) -> LBDailyObservation {
        LBDailyObservation(day: day, value: value, qualityStatus: .ok, coverage: coverage(series))
    }

    /// Long nights T−60…T−8 at `long`, week T−span…T−1 at `week`, T at `tonight`.
    func splitTape(series: LBSeries, long: Double, week: Double, tonight: Double) -> [LBDailyObservation] {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let span = LongitudinalBaseline.params(for: series).span7
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...(t - 8) {
            let inWeekOverlap = e >= (t - span)
            rows.append(ok(iso(e), inWeekOverlap ? week : long, series: series))
        }
        for e in (t - span)...(t - 1) where e > (t - 8) {
            rows.append(ok(iso(e), week, series: series))
        }
        rows.append(ok(iso(t), tonight, series: series))
        return rows
    }

    func eval(_ series: LBSeries, obs: [LBDailyObservation],
              trial: LBTrialRequest = .none) -> LBEvaluation {
        LongitudinalBaseline.evaluate(asOf: asOf, series: series, observations: obs,
                                      replay: false, trial: trial)
    }

    func testEverySeriesIsAccountedFor() {
        XCTAssertEqual(LBSeries.allCases.count, 18)
        for s in LBSeries.allCases {
            let spec = LongitudinalBaseline.seriesSpec(s)
            XCTAssertGreaterThan(spec.maxVal, spec.minVal, s.rawValue)
            XCTAssertGreaterThan(spec.floor, 0, s.rawValue)
            XCTAssertGreaterThanOrEqual(typical(s), spec.minVal, s.rawValue)
            XCTAssertLessThanOrEqual(typical(s), spec.maxVal, s.rawValue)
            XCTAssertGreaterThanOrEqual(weekNative(s), spec.minVal, s.rawValue)
            XCTAssertLessThanOrEqual(weekNative(s), spec.maxVal, s.rawValue)
            XCTAssertGreaterThanOrEqual(tonightNative(s), spec.minVal, s.rawValue)
            XCTAssertLessThanOrEqual(tonightNative(s), spec.maxVal, s.rawValue)
        }
    }

    func testEveryBiometricTwoCopiesNeverAveragedAndTonightExcluded() {
        for s in LBSeries.allCases {
            let longV = typical(s)
            let weekV = weekNative(s)
            let tonight = tonightNative(s)
            let ev = eval(s, obs: splitTape(series: s, long: longV, week: weekV, tonight: tonight))
            let name = s.planRow.planName

            XCTAssertEqual(ev.todayNative ?? -1, tonight, accuracy: 1e-6, name)
            XCTAssertTrue(ev.show7, "\(name) week must show\n\(ev.consoleReport)")
            XCTAssertTrue(ev.showLong, "\(name) long must show\n\(ev.consoleReport)")
            let span = LongitudinalBaseline.params(for: s).span7
            XCTAssertLessThanOrEqual(ev.nLong, 53, "\(name) cannot exceed 53 long slots")
            if span == 7 {
                XCTAssertEqual(ev.nLong, 53, "\(name) long window is 53 slots\n\(ev.consoleReport)")
            } else {
                // Span-10 HRV week overlaps T−10…T−8. Those three nights are trimmed from the long median.
                XCTAssertEqual(ev.nLong, 50, "\(name) long median trims the 3 overlap nights\n\(ev.consoleReport)")
            }
            XCTAssertEqual(ev.n7, span, "\(name) n7")

            let longMath = LongitudinalBaseline.toMath(longV, series: s)!
            let weekMath = LongitudinalBaseline.toMath(weekV, series: s)!
            let tonightMath = LongitudinalBaseline.toMath(tonight, series: s)!
            XCTAssertEqual(ev.copyLong?.center ?? 0, longMath, accuracy: 0.08,
                           "\(name) long median is T−60…T−8, not this week or tonight\n\(ev.consoleReport)")
            XCTAssertEqual(ev.copy7?.center ?? 0, weekMath, accuracy: 0.12,
                           "\(name) week EWMA is T−span…T−1, not tonight\n\(ev.consoleReport)")
            XCTAssertNotEqual(ev.copy7?.center ?? 0, tonightMath, accuracy: 0.15,
                              "\(name) tonight is scored, not trained")
            let blended = (longMath + weekMath) / 2
            XCTAssertGreaterThan(abs((ev.copy7?.center ?? 0) - blended), 0.04,
                                 "\(name) week copy must not be the average of the two usuals")
            XCTAssertGreaterThan(abs((ev.copyLong?.center ?? 0) - blended), 0.04,
                                 "\(name) long copy must not be the average of the two usuals")
            if let gap = ev.gap {
                XCTAssertEqual(gap, (ev.center7Raw ?? 0) - (ev.expectedLong ?? ev.copyLong!.center),
                               accuracy: 0.08, "\(name) gap is week-raw minus long path")
            }
            XCTAssertGreaterThan(ev.copy7?.spread ?? 0, 0, name)
            XCTAssertGreaterThanOrEqual(ev.copy7?.spread ?? 0, LongitudinalBaseline.seriesSpec(s).floor - 1e-12, name)
            XCTAssertGreaterThanOrEqual(ev.copyLong?.spread ?? 0, LongitudinalBaseline.seriesSpec(s).floor - 1e-12, name)

            let k = ev.kBandUsed
            XCTAssertTrue(LongitudinalBaseline.isOffUsual(z: ev.z7, k: k)
                          || abs(ev.z7 ?? 0) >= k * 0.9,
                          "\(name) tonight should sit off the week usual\n\(ev.consoleReport)")
            XCTAssertEqual(ev.paramSet, "v1.review", name)
            XCTAssertEqual(ev.copy7?.version, LongitudinalBaseline.Params.version7, name)
            XCTAssertEqual(ev.copyLong?.version, LongitudinalBaseline.Params.versionLong, name)
            XCTAssertGreaterThanOrEqual(ev.nLong, LongitudinalBaseline.nLongEstablished(for: s), name)
            XCTAssertTrue(ev.establishedLong, name)

            if s.usesLog {
                XCTAssertEqual(ev.copy7?.centerDisplay ?? 0, exp(ev.copy7!.center), accuracy: 0.2, name)
                XCTAssertEqual(ev.copyLong?.centerDisplay ?? 0, exp(ev.copyLong!.center), accuracy: 0.2, name)
            } else {
                XCTAssertEqual(ev.copy7?.centerDisplay ?? 0, ev.copy7?.center ?? 0, accuracy: 1e-9, name)
            }
        }
    }

    func testEveryBiometricSpreadFloorStopsTinyZ() {
        for s in LBSeries.allCases {
            let t = LongitudinalBaseline.isoEpochDay(asOf)!
            let base = typical(s)
            let wiggle = min(LongitudinalBaseline.seriesSpec(s).floor * 0.05, 0.01)
            var rows: [LBDailyObservation] = []
            for e in (t - 60)...t {
                rows.append(ok(iso(e), e == t ? base + wiggle : base, series: s))
            }
            let ev = eval(s, obs: rows)
            let floor = LongitudinalBaseline.seriesSpec(s).floor
            XCTAssertGreaterThanOrEqual(ev.copy7?.spread ?? 0, floor - 1e-12, s.rawValue)
            XCTAssertGreaterThanOrEqual(ev.copyLong?.spread ?? 0, floor - 1e-12, s.rawValue)
            let mathWiggle = abs((LongitudinalBaseline.toMath(base + wiggle, series: s) ?? 0)
                                 - (LongitudinalBaseline.toMath(base, series: s) ?? 0))
            XCTAssertLessThan(abs(ev.z7 ?? 99), 0.6,
                              "\(s.rawValue) floor must keep a tiny wiggle from looking huge z=\(ev.z7 ?? .nan) Δ=\(mathWiggle)")
        }
    }

    func testEveryBiometricExtraMedDropsNightScheduledDoesNot() {
        for s in LBSeries.allCases {
            let t = LongitudinalBaseline.isoEpochDay(asOf)!
            let v = typical(s)
            var rows: [LBDailyObservation] = []
            for e in (t - 60)...t { rows.append(ok(iso(e), v, series: s)) }
            let dirtyDay = iso(t - 20)
            let extra = eval(s, obs: rows, trial: LBTrialRequest(
                dayLogsByDay: [dirtyDay: LBDayLog(extraMed: true)]))
            XCTAssertEqual(extra.nLong, 52, "\(s.rawValue) extra med drops the long night")
            let taken = eval(s, obs: rows, trial: LBTrialRequest(
                dayLogsByDay: [dirtyDay: LBDayLog(scheduledMed: .taken)]))
            XCTAssertEqual(taken.nLong, 53, "\(s.rawValue) scheduled-taken still trains")
        }
    }

    func testImuDoesNotTrainFromHeartRateTape() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        let rhr = (t - 60...t).map { ok(iso($0), 60, series: .sleepRHR) }
        let imu = eval(.wakingImuEnergy, obs: rhr)
        XCTAssertFalse(imu.show7, imu.consoleReport)
        XCTAssertFalse(imu.establishedLong)
        XCTAssertNil(imu.todayNative)
    }

    func testIllnessNightDoesNotRefreshLastQualityOK() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 60)...(t - 20) {
            rows.append(ok(iso(e), 60, series: .sleepRHR))
        }
        rows.append(ok(iso(t - 1), 88, series: .sleepRHR))
        var ill = LBDayLog()
        ill.feltIll = true
        let ev = eval(.sleepRHR, obs: rows, trial: LBTrialRequest(dayLogsByDay: [iso(t - 1): ill]))
        XCTAssertEqual(ev.carry.lastQualityOKEpoch, t - 20)
        XCTAssertTrue(ev.stale, ev.consoleReport)
    }

    func testHabitMatchedStaleUsesLastMatchingNightNotOtherHabit() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        var logs: [String: LBDayLog] = [:]
        for e in (t - 60)...(t - 21) {
            rows.append(ok(iso(e), 60, series: .sleepRHR))
            logs[iso(e)] = LBDayLog(workout: .none)
        }
        for e in (t - 20)...(t - 1) {
            rows.append(ok(iso(e), 66, series: .sleepRHR))
            logs[iso(e)] = LBDayLog(workout: .hard)
        }
        logs[iso(t)] = LBDayLog(workout: .none)
        let ev = eval(.sleepRHR, obs: rows, trial: LBTrialRequest(dayLogsByDay: logs))
        XCTAssertTrue(ev.habitMatched, ev.consoleReport)
        XCTAssertEqual(ev.habitClass, .rest)
        XCTAssertEqual(ev.carry.lastQualityOKEpoch, t - 21)
        XCTAssertTrue(ev.stale, ev.consoleReport)
    }

    func testWeekLastUpdateSkipsIllnessNight() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        var logs: [String: LBDayLog] = [:]
        for e in (t - 60)...(t - 1) {
            rows.append(ok(iso(e), 60, series: .sleepRHR))
        }
        logs[iso(t - 1)] = {
            var ill = LBDayLog()
            ill.feltIll = true
            return ill
        }()
        let ev = eval(.sleepRHR, obs: rows, trial: LBTrialRequest(dayLogsByDay: logs))
        XCTAssertEqual(ev.copy7?.lastUpdate, iso(t - 2), ev.consoleReport)
        XCTAssertNotEqual(ev.copy7?.lastUpdate, iso(t - 1))
    }

    func testFeltIllFreezesPreIllnessUsualWithoutResettingLong() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        var logs: [String: LBDayLog] = [:]
        for e in (t - 40)...(t - 1) {
            rows.append(ok(iso(e), 60, series: .sleepRHR))
        }
        rows.append(ok(iso(t), 88, series: .sleepRHR))
        logs[iso(t)] = {
            var ill = LBDayLog()
            ill.feltIll = true
            return ill
        }()
        let ev = eval(.sleepRHR, obs: rows, trial: LBTrialRequest(dayLogsByDay: logs))
        let freeze = try! XCTUnwrap(ev.usualFreeze, ev.consoleReport)
        XCTAssertEqual(freeze.reason, LBUsualFreeze.loggedIll)
        XCTAssertEqual(freeze.t0CivilDay, asOf)
        XCTAssertEqual(freeze.centerLong, 60, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(ev.nLong, 14, ev.consoleReport)
        XCTAssertTrue(ev.establishedLong, ev.consoleReport)
    }

    func testWeekShiftDoesNotFreezeWithoutLoggedIll() {
        let t = LongitudinalBaseline.isoEpochDay(asOf)!
        var rows: [LBDailyObservation] = []
        for e in (t - 40)...(t - 12) {
            rows.append(ok(iso(e), 60, series: .sleepRHR))
        }
        for e in (t - 11)...t {
            rows.append(ok(iso(e), 88, series: .sleepRHR))
        }
        let ev = eval(.sleepRHR, obs: rows)
        XCTAssertNil(ev.usualFreeze, ev.consoleReport)
        XCTAssertTrue(ev.establishedLong, ev.consoleReport)
    }

    func testHowOffHiddenWhenTrustUnder35IsThePublishedRule() {
        XCTAssertEqual(LongitudinalBaseline.trustHideThreshold, 35)
        for s in LBSeries.allCases {
            let t = LongitudinalBaseline.isoEpochDay(asOf)!
            let v = typical(s)
            let thin = (0...3).map { ok(iso(t - $0), v, series: s) }
            let ev = eval(s, obs: thin)
            XCTAssertFalse(ev.show7, s.rawValue)
            XCTAssertLessThan(ev.usualTrustPct7, 35, s.rawValue)
        }
    }
}
