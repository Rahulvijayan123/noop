import Foundation
import XCTest
@testable import StrandAnalytics

/// System F references: daily values from envelopes, the four reference views, support states, floors, frozen
/// registration, leakage guards and reproducibility (V10, V12, C05). Expected values are computed independently in
/// the tests (plain sorting / arithmetic), not by calling the estimator under test.
final class PCReferenceTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias Ref = PhysiologyContext.ContextReferences

    static let tz = "UTC"
    static let day = "2026-03-10"
    static var identity: PC.DayIdentity {
        PC.DayIdentity(deviceScope: "dev-1", day: day, timezoneId: tz, dayWindow: PC.Engine.dayInterval(day, timezoneId: tz))
    }

    // MARK: Fixtures

    static func envelope(_ metric: PC.MetricKind, method: String, aggregation: PC.Aggregation = .window,
                         windowS: Int = 300, units: String = "ms", value: Double?, support: PC.Interval,
                         regime: String = "r1", validity: PC.ValidityState = .valid,
                         verdicts: [(PC.ComparisonKind, PC.EligibilityState)]) -> PC.MeasurementEnvelope {
        let m = PC.MethodRef(id: method, algorithmVersion: "test-1", aggregation: aggregation, windowS: windowS, units: units)
        let dayN = Int((Double(support.start) / 86_400).rounded(.down))
        let local = PC.LocalTimeRef(timezoneId: tz, utcOffsetS: 0, localDay: Ref.dayKey(dayN),
                                    secondsOfDay: support.start - dayN * 86_400)
        let activity = PC.ActivityComposition(interval: support, intervalS: support.duration, source: .none,
                                              heartRateDependent: false, labels: [], unknownS: 0,
                                              uncoveredS: Double(support.duration), transitions: 0, mixed: false,
                                              dominantLabel: nil, resolvedOverlapS: 0, reasons: [])
        let preceding = PC.PrecedingHistory(lookback: .init(support.start - 1800, support.start), source: .none,
                                            stillRunS: 0, stillRunEndedBy: nil, secondsSinceSupportedActivity: nil,
                                            lastSupportedActivityLabel: nil, coveredS: 0, transitions: 0)
        let history = PC.HistoryContext(wake: .unknown([]), recentBouts: [], exertion: [], exposures: [],
                                        exposureCoverage: [])
        return PC.MeasurementEnvelope(
            id: PC.MeasurementEnvelope.makeId(method: m, support: support), metric: metric, method: m,
            source: .init(product: .scoringSnapshot, key: method), value: value, support: support,
            displayBucket: nil, localTime: local, validity: PC.SignalValidity(state: validity, reasons: []),
            regimeKey: regime, activity: activity, decoderActivity: nil, preceding: preceding, sleepWear: .unknown,
            history: history,
            eligibility: verdicts.map { PC.EligibilityVerdict(comparison: $0.0, state: $0.1, reasons: [], policyVersion: "t") },
            comparisons: [], finality: .final)
    }

    static func night(_ metric: PC.MetricKind, _ method: String, value: Double?, units: String = "ms",
                      aggregation: PC.Aggregation = .session, validity: PC.ValidityState = .valid,
                      sleep: PC.EligibilityState = .eligible, endOffsetH: Int = 7) -> PC.MeasurementEnvelope {
        let start = identity.dayWindow.start
        return envelope(metric, method: method, aggregation: aggregation, windowS: 28_800, units: units, value: value,
                        support: .init(start - 3600, start + endOffsetH * 3600), validity: validity,
                        verdicts: [(.sleepMeasurement, sleep)])
    }

    static func window(_ metric: PC.MetricKind = .hrvRmssd, method: String = "series.hrv_rmssd.5min",
                       at hour: Double, value: Double, regime: String = "r1", validity: PC.ValidityState = .valid,
                       awake: PC.EligibilityState = .eligible) -> PC.MeasurementEnvelope {
        let s = identity.dayWindow.start + Int(hour * 3600)
        return envelope(metric, method: method, value: value, support: .init(s, s + 300), regime: regime,
                        validity: validity, verdicts: [(.stableAwakeRest, awake)])
    }

    static func value(_ day: String, _ v: Double, series: String = "hrv_rmssd.sleep_night", regime: String = "r1",
                      mode: PC.ProcessingMode = .retrospective, support: Int = 1) -> PC.DailyValue {
        PC.DailyValue(day: day, seriesKey: series, regimeKey: regime, metric: nil, value: v, units: "ms",
                      supportCount: support, supportUnit: "night", supportS: 28_800, mode: mode, finality: .final)
    }

    /// `n` consecutive days ending the day before `end`, with values from `f(i)` (i = 0 oldest).
    static func history(_ n: Int, endingBefore end: String = day, series: String = "hrv_rmssd.sleep_night",
                        regime: String = "r1", mode: PC.ProcessingMode = .retrospective,
                        _ f: (Int) -> Double) -> [PC.DailyValue] {
        let e = Ref.dayNumber(end)!
        return (0..<n).map { i in value(Ref.dayKey(e - n + i), f(i), series: series, regime: regime, mode: mode) }
    }

    static func view(_ cs: [PC.ReferenceComparison], _ v: PC.ReferenceView,
                     series: String = "hrv_rmssd.sleep_night") -> PC.ReferenceComparison? {
        cs.first { $0.view == v && $0.seriesKey == series }
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func compare(_ today: [PC.DailyValue], _ hist: [PC.DailyValue], frozen: [PC.FrozenReference] = [],
                        config: PC.ReferenceConfig = .init()) -> (comparisons: [PC.ReferenceComparison], newFrozen: [PC.FrozenReference]) {
        Ref.compare(today, history: hist, frozen: frozen, day: day, policyFingerprint: "fp", config: config)
    }

    // MARK: Daily values

    func testNightlySnapshotsBecomeSleepNightValuesOnlyWhenEligibleAndValidOrDegraded() {
        let envs = [
            Self.night(.hrvRmssd, "snapshot.hrv_rmssd.night", value: 48),
            Self.night(.restingHeartRate, "snapshot.resting_hr.night", value: 52, units: "bpm", validity: .degraded),
            Self.night(.respiratoryRate, "snapshot.resp_rate.night", value: 14, units: "breaths_per_min", validity: .invalid),
            Self.night(.skinTemperature, "snapshot.skin_temp.night", value: 33.1, units: "degC"),
            Self.night(.spo2Candidate, "snapshot.spo2.night", value: 96, units: "percent"),
            Self.night(.hrvSdnn, "snapshot.hrv_sdnn.night", value: 70),
            Self.night(.hrvSdnn, "snapshot.hrv_sdnn_index.night", value: 60, aggregation: .meanOverWindows),
            Self.night(.heartRate, "snapshot.heart_rate.night", value: 58, units: "bpm", sleep: .unknown),
            Self.night(.heartRate, "snapshot.heart_rate.night2", value: nil, units: "bpm"),
        ]
        let out = Ref.dailyValues(envelopes: envs, identity: Self.identity, mode: .retrospective, finality: .final,
                                  config: .init())
        XCTAssertEqual(out.map(\.seriesKey), ["hrv_rmssd.sleep_night", "hrv_sdnn_index.sleep_night",
                                              "resting_hr.sleep_night", "skin_temp.sleep_night"])
        let rmssd = out[0]
        XCTAssertEqual(rmssd.value, 48)
        XCTAssertEqual(rmssd.supportCount, 1)
        XCTAssertEqual(rmssd.supportUnit, "night")
        XCTAssertEqual(rmssd.sourceIds, [envs[0].id])
        XCTAssertEqual(rmssd.day, Self.day)
        XCTAssertTrue(out[2].reasons.contains(Ref.degradedValidityIncluded))
        XCTAssertTrue(out[3].reasons.contains(Ref.relativeUseOnly))
        XCTAssertTrue(out.allSatisfy { $0.mode == .retrospective && $0.finality == .final })
    }

    func testANightBelongsToTheDayContainingItsEnd() {
        // A session that ended before today's local midnight belongs to the previous day.
        let early = Self.night(.hrvRmssd, "snapshot.hrv_rmssd.night", value: 48, endOffsetH: -1)
        let out = Ref.dailyValues(envelopes: [early], identity: Self.identity, mode: .retrospective, finality: .final,
                                  config: .init())
        XCTAssertTrue(out.isEmpty)
    }

    func testStableAwakeValueIsTheMedianOfEnoughIndependentEligibleWindowsAndNeverZeroFilled() {
        // Two eligible windows: below the minimum of three → no value at all (not zero, not one window).
        let two = [Self.window(at: 9, value: 40), Self.window(at: 9.5, value: 44)]
        XCTAssertTrue(Ref.dailyValues(envelopes: two, identity: Self.identity, mode: .retrospective, finality: .final,
                                      config: .init()).isEmpty)
        // Three eligible + ineligible / unknown / degraded / out-of-day windows that must not count.
        let s = Self.identity.dayWindow.start
        var envs = two + [Self.window(at: 10, value: 60)]
        envs.append(Self.window(at: 10.5, value: 5, awake: .ineligible))
        envs.append(Self.window(at: 11, value: 6, awake: .unknown))
        envs.append(Self.window(at: 11.5, value: 7, validity: .degraded))
        envs.append(Self.envelope(.hrvRmssd, method: "series.hrv_rmssd.5min", value: 8,
                                  support: .init(s - 900, s - 600), verdicts: [(.stableAwakeRest, .eligible)]))
        let out = Ref.dailyValues(envelopes: envs, identity: Self.identity, mode: .causalLive, finality: .provisional,
                                  config: .init())
        let parent = out.first { $0.seriesKey == "hrv_rmssd.stable_awake_5min" }
        XCTAssertEqual(parent?.value, 44)                 // median of 40, 44, 60
        XCTAssertEqual(parent?.supportCount, 3)
        XCTAssertEqual(parent?.supportUnit, "window")
        XCTAssertEqual(parent?.supportS, 900)
        XCTAssertEqual(parent?.sourceIds.count, 3)
        XCTAssertEqual(parent?.mode, .causalLive)
    }

    func testRegimesMethodsAndHrvDefinitionsStaySeparate() {
        var envs: [PC.MeasurementEnvelope] = []
        for (i, h) in [8.0, 8.5, 9.0].enumerated() {
            envs.append(Self.window(at: h, value: 40 + Double(i), regime: "wrist"))
            envs.append(Self.window(at: h + 3, value: 60 + Double(i), regime: "bicep"))
            envs.append(Self.window(.hrvSdnn, method: "series.hrv_sdnn.5min", at: h, value: 80 + Double(i), regime: "wrist"))
            envs.append(Self.window(.heartRate, method: "context.heart_rate.5min_mean", at: h, value: 62, regime: "wrist"))
        }
        let out = Ref.dailyValues(envelopes: envs, identity: Self.identity, mode: .retrospective, finality: .final,
                                  config: .init()).filter { !Ref.isStratum($0.seriesKey) }
        let keys = out.map { "\($0.seriesKey)|\($0.regimeKey)|\($0.value)" }
        XCTAssertEqual(keys, ["heart_rate.stable_awake_5min|wrist|62.0", "hrv_rmssd.stable_awake_5min|bicep|61.0",
                              "hrv_rmssd.stable_awake_5min|wrist|41.0", "hrv_sdnn.stable_awake_5min|wrist|81.0"])
    }

    func testTimeBandStrataNeedTheirOwnMinimumAndOverlapsAreNotIndependent() {
        var envs = [7.0, 7.5, 8.0, 19.0, 19.5].map { Self.window(at: $0, value: $0 * 2) }
        // A window overlapping the 07:00 window adds a value but not an independent support unit.
        let s = Self.identity.dayWindow.start + 7 * 3600 + 120
        envs.append(Self.envelope(.hrvRmssd, method: "series.hrv_rmssd.5min", value: 15,
                                  support: .init(s, s + 300), verdicts: [(.stableAwakeRest, .eligible)]))
        let out = Ref.dailyValues(envelopes: envs, identity: Self.identity, mode: .retrospective, finality: .final,
                                  config: .init())
        XCTAssertEqual(out.map(\.seriesKey), ["hrv_rmssd.stable_awake_5min", "hrv_rmssd.stable_awake_5min.band_06_12"])
        XCTAssertEqual(out[0].supportCount, 5)
        XCTAssertEqual(out[0].sourceIds.count, 6)
        XCTAssertTrue(out[0].reasons.contains(Ref.overlappingWindowsNotCounted))
        XCTAssertEqual(out[1].supportCount, 3)
        XCTAssertTrue(out[1].reasons.contains(Ref.timeBandStratum))
        XCTAssertEqual(Ref.parentSeries(of: out[1].seriesKey), "hrv_rmssd.stable_awake_5min")
        XCTAssertEqual(Ref.timeBand(secondsOfDay: 23 * 3600, config: .init()), "band_18_24")
    }

    // MARK: Views and support states

    func testRollingCenterAndScaleComeOnlyFromStrictlyEarlierDays() throws {
        let hist = Self.history(20) { 40 + Double(($0 * 7) % 11) }
        let today = Self.value(Self.day, 400)
        let a = Self.compare([today], hist)
        let rolling = try XCTUnwrap(Self.view(a.comparisons, .rolling))
        let lnHist = hist.map { log($0.value) }
        let center = Self.median(lnHist)
        let mad = Self.median(lnHist.map { abs($0 - center) })
        let expectedScale = 1.4826 * mad * (20.0 / 19.2)
        XCTAssertEqual(rolling.status, .ready)
        XCTAssertEqual(rolling.supportDays, 20)
        XCTAssertEqual(try XCTUnwrap(rolling.transformedCenter), center, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(rolling.center), exp(center), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rolling.scale), expectedScale, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(rolling.robustZ), (log(400) - center) / expectedScale, accuracy: 1e-9)
        XCTAssertEqual(rolling.toDay, Ref.dayKey(Ref.dayNumber(Self.day)! - 1))
        // Passing today's own value (or a later day) as history changes nothing: it is never incorporated.
        let leaked = hist + [today, Self.value(Ref.dayKey(Ref.dayNumber(Self.day)! + 1), 1)]
        let b = Self.compare([today], leaked)
        let rb = try XCTUnwrap(Self.view(b.comparisons, .rolling))
        XCTAssertEqual(rb.robustZ, rolling.robustZ)
        XCTAssertEqual(rb.center, rolling.center)
        XCTAssertTrue(rb.reasons.contains(Ref.futureHistoryIgnored))
    }

    func testSupportStatesAreExplicitAndSparseHistoriesNeverScore() throws {
        let today = Self.value(Self.day, 50)
        for (n, status) in [(0, PC.ReferenceStatus.insufficient), (2, .insufficient), (6, .insufficient),
                            (7, .provisional), (13, .provisional), (14, .ready)] {
            let cs = Self.compare([today], Self.history(n) { 45 + Double($0 % 3) }).comparisons
            let r = try XCTUnwrap(Self.view(cs, .rolling))
            XCTAssertEqual(r.status, status, "n=\(n)")
            XCTAssertEqual(r.supportDays, n)
            if status == .insufficient {
                XCTAssertNil(r.robustZ, "n=\(n)")
                XCTAssertNil(r.scale)
                XCTAssertNil(r.signedDifference)
                XCTAssertTrue(r.reasons.contains(n == 0 ? Ref.noHistory : Ref.insufficientHistory))
            } else {
                XCTAssertNotNil(r.robustZ)
            }
            XCTAssertNoThrow(try PC.encoder().encode(cs))
        }
    }

    func testOtherRegimeHistoryIsNeverPooled() throws {
        let today = Self.value(Self.day, 50, regime: "bicep")
        let wrist = Self.history(20, regime: "wrist") { 40 + Double($0 % 4) }
        let only = Self.compare([today], wrist).comparisons
        XCTAssertEqual(Self.view(only, .rolling)?.status, .regimeMismatch)
        XCTAssertEqual(Self.view(only, .recent)?.status, .regimeMismatch)
        XCTAssertEqual(Self.view(only, .frozen)?.status, .regimeMismatch)
        XCTAssertTrue(only.allSatisfy { $0.robustZ == nil })
        let bicep = Self.history(8, regime: "bicep") { 60 + Double($0 % 2) }
        let both = Self.compare([today], wrist + bicep).comparisons
        let r = try XCTUnwrap(Self.view(both, .rolling))
        XCTAssertEqual(r.supportDays, 8)
        XCTAssertTrue(r.reasons.contains(Ref.otherRegimeHistoryNotPooled))
        XCTAssertEqual(try XCTUnwrap(r.center), exp((log(60.0) + log(61.0)) / 2), accuracy: 1e-9)
    }

    func testConstantHistoryGetsTheFloorNotInfiniteCertainty() throws {
        let hist = Self.history(20, series: "resting_hr.sleep_night") { _ in 52 }
        let today = Self.value(Self.day, 54, series: "resting_hr.sleep_night")
        let cs = Self.compare([today], hist).comparisons
        let r = try XCTUnwrap(Self.view(cs, .rolling, series: "resting_hr.sleep_night"))
        XCTAssertEqual(r.scale, 1.0)                     // resting HR floor, bpm
        XCTAssertTrue(r.scaleFloored)
        XCTAssertEqual(r.robustZ, 2.0)
        XCTAssertNil(r.transformedDifference)            // identity transform
        XCTAssertEqual(r.signedDifference, 2.0)
        XCTAssertTrue(r.reasons.contains(Ref.scaleFloored))
        XCTAssertTrue(r.reasons.contains(Ref.constantHistory))
        XCTAssertNoThrow(try PC.encoder().encode(cs))
        // An identical value has distance 0, not NaN.
        let same = Self.compare([Self.value(Self.day, 52, series: "resting_hr.sleep_night")], hist).comparisons
        XCTAssertEqual(Self.view(same, .rolling, series: "resting_hr.sleep_night")?.robustZ, 0)
    }

    func testRmssdIsComparedOnTheLnScaleWithOriginalUnitsPreserved() throws {
        let hist = Self.history(14) { [40.0, 50.0][$0 % 2] }
        let cs = Self.compare([Self.value(Self.day, 30)], hist).comparisons
        let r = try XCTUnwrap(Self.view(cs, .rolling))
        let c = (log(40.0) + log(50.0)) / 2          // even-n median on the ln scale
        XCTAssertEqual(r.transform, "ln")
        XCTAssertEqual(try XCTUnwrap(r.center), exp(c), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.transformedDifference), log(30) - c, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(r.signedDifference), 30 - exp(c), accuracy: 1e-9)
        XCTAssertTrue(r.reasons.contains(Ref.logTransform))
        // Center uncertainty: 1.2533 * scale / sqrt(n) on the ln scale, mapped to ms by the delta method.
        let se = 1.2533 * r.scale! / sqrt(14)
        XCTAssertEqual(try XCTUnwrap(r.centerUncertainty), exp(c) * se, accuracy: 1e-9)
        XCTAssertEqual(r.centerUncertaintyMethod, "median_se_iid_normal_approx")
        // A non-positive value cannot be log-transformed: explicit state, no z.
        let bad = Self.compare([Self.value(Self.day, 0)], hist).comparisons
        XCTAssertTrue(bad.allSatisfy { $0.robustZ == nil })
        XCTAssertTrue(Self.view(bad, .rolling)!.reasons.contains(Ref.nonPositiveValueForLog))
    }

    func testRecentViewDescribesTheTrajectoryWithTheRollingScale() throws {
        let hist = Self.history(20) { $0 < 13 ? 40 : 60 }   // last 7 days at 60
        let cs = Self.compare([Self.value(Self.day, 60)], hist).comparisons
        let recent = try XCTUnwrap(Self.view(cs, .recent))
        let rolling = try XCTUnwrap(Self.view(cs, .rolling))
        XCTAssertEqual(recent.supportDays, 7)
        XCTAssertEqual(try XCTUnwrap(recent.center), 60, accuracy: 1e-9)
        XCTAssertEqual(recent.scale, rolling.scale)
        XCTAssertEqual(try XCTUnwrap(recent.robustZ), 0, accuracy: 1e-12)
        XCTAssertTrue(recent.reasons.contains(Ref.scaleFromRollingView))
        // With fewer than the rolling minimum, the recent view uses its own scale and stays provisional.
        let short = Self.compare([Self.value(Self.day, 60)], Self.history(4) { 50 + Double($0) }).comparisons
        let r2 = try XCTUnwrap(Self.view(short, .recent))
        XCTAssertEqual(r2.status, .provisional)
        XCTAssertTrue(r2.reasons.contains(Ref.scaleFromRecentWindow))
    }

    func testFrozenReferenceIsRegisteredOnceVersionedAndNeverReplaced() throws {
        let hist = Self.history(30) { 40 + Double($0) }       // values drift upward: frozen keeps the first 14
        let today = Self.value(Self.day, 41)
        let first = Self.compare([today], hist)
        let f = try XCTUnwrap(first.newFrozen.first)
        XCTAssertEqual(first.newFrozen.count, 1)
        let firstDay = Ref.dayKey(Ref.dayNumber(Self.day)! - 30)
        XCTAssertEqual(f.fromDay, firstDay)
        XCTAssertEqual(f.toDay, Ref.dayKey(Ref.dayNumber(firstDay)! + 13))
        XCTAssertEqual(f.supportDays, 14)
        XCTAssertEqual(f.version, 1)
        XCTAssertEqual(f.transform, "ln")
        XCTAssertEqual(f.center, Self.median((0..<14).map { log(40 + Double($0)) }), accuracy: 1e-12)
        XCTAssertEqual(f.id, "frz_" + PC.fnv1a("hrv_rmssd.sleep_night|r1|1|\(firstDay)"))
        XCTAssertEqual(f.selectionRule, "first_14_supported_days_within_42_calendar_days_of_loaded_regime_history")
        XCTAssertEqual(f.createdForDay, Self.day)
        let fv = try XCTUnwrap(Self.view(first.comparisons, .frozen))
        XCTAssertEqual(fv.referenceId, f.id)
        XCTAssertEqual(fv.status, .ready)
        XCTAssertTrue(fv.reasons.contains(Ref.frozenRegisteredThisRun))
        XCTAssertTrue(fv.reasons.contains(Ref.frozenHistoricalNotHealthy))
        // Later run with the stored reference and much more (shifted) history: reused, never re-registered.
        let more = Self.history(60) { 80 + Double($0 % 5) }
        let second = Self.compare([today], more, frozen: [f])
        XCTAssertTrue(second.newFrozen.isEmpty)
        XCTAssertEqual(Self.view(second.comparisons, .frozen)?.referenceId, f.id)
        XCTAssertEqual(try XCTUnwrap(Self.view(second.comparisons, .frozen)?.transformedCenter), f.center, accuracy: 0)
        // A new regime gets its own reference.
        let other = Self.compare([Self.value(Self.day, 41, regime: "r2")], Self.history(20, regime: "r2") { 30 + Double($0 % 3) },
                                 frozen: [f])
        XCTAssertEqual(other.newFrozen.first?.regimeKey, "r2")
        XCTAssertNotEqual(other.newFrozen.first?.id, f.id)
    }

    func testFrozenNeedsDenseEnoughHistoryAndRegistersOnlyInTheConfiguredMode() {
        // 14 supported days spread over 4 per week (> 42 calendar days end to end): not registered yet.
        let e = Ref.dayNumber(Self.day)!
        let sparse = (0..<14).map { Self.value(Ref.dayKey(e - 60 + $0 * 4), 45) }
        let a = Self.compare([Self.value(Self.day, 45)], sparse)
        XCTAssertTrue(a.newFrozen.isEmpty)
        XCTAssertEqual(Self.view(a.comparisons, .frozen)?.status, .insufficient)
        // Causal mode reads but never registers (frozen references are not keyed by mode in storage).
        let live = Self.compare([Self.value(Self.day, 45, mode: .causalLive)],
                                Self.history(20, mode: .causalLive) { 45 + Double($0 % 3) })
        XCTAssertTrue(live.newFrozen.isEmpty)
        XCTAssertTrue(Self.view(live.comparisons, .frozen)!.reasons.contains(Ref.frozenRegistersInOtherMode))
        // Modes never pool: retrospective history is invisible to a causal value.
        let mixed = Self.compare([Self.value(Self.day, 45, mode: .causalLive)], Self.history(20) { _ in 45 })
        XCTAssertEqual(Self.view(mixed.comparisons, .rolling)?.supportDays, 0)
    }

    func testConditionedBandShrinksTowardTheAllDayParentWithReportedContribution() throws {
        let parentKey = "hrv_rmssd.stable_awake_5min", band = parentKey + ".band_06_12"
        let parent = Self.history(20, series: parentKey) { 50 + Double($0 % 3) }      // ln median ln(51)
        let child = Self.history(3, series: band) { [40.0, 42.0, 44.0][$0] }
        let today = Self.value(Self.day, 41, series: band)
        let cs = Self.compare([today], parent + child).comparisons
        let c = try XCTUnwrap(Self.view(cs, .conditioned, series: band))
        let w = 3.0 / (3.0 + 7.0)
        let parentCenter = Self.median(parent.map { log($0.value) })
        let childCenter = log(42.0)
        XCTAssertEqual(c.pooledContribution, 1 - w, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(c.transformedCenter), w * childCenter + (1 - w) * parentCenter, accuracy: 1e-12)
        XCTAssertEqual(c.supportDays, 3)
        XCTAssertEqual(c.parentSupportDays, 20)
        XCTAssertEqual(c.status, .provisional)
        XCTAssertTrue(c.reasons.contains(Ref.pooledTowardParent))
        XCTAssertTrue(c.reasons.contains(Ref.noPopulationPrior))
        XCTAssertNil(Self.view(cs, .rolling, series: band))          // strata get the conditioned view only
        // No band history: parent only, contribution 1, provisional.
        let none = Self.compare([today], parent).comparisons
        let n = try XCTUnwrap(Self.view(none, .conditioned, series: band))
        XCTAssertEqual(n.pooledContribution, 1)
        XCTAssertTrue(n.reasons.contains(Ref.contextUnsupportedParentOnly))
        // No parent and too little band history: insufficient, no distance.
        let bare = Self.compare([today], child).comparisons
        XCTAssertEqual(Self.view(bare, .conditioned, series: band)?.status, .insufficient)
        XCTAssertNil(Self.view(bare, .conditioned, series: band)?.robustZ)
    }

    // MARK: Leakage and reproducibility

    func testAppendingLaterDaysNeverChangesAnEarlierDaysComparisons() throws {
        // V10: the comparisons of day D are a function of days < D only.
        let all = Self.history(40, endingBefore: Ref.dayKey(Ref.dayNumber(Self.day)! + 20)) { 40 + Double(($0 * 5) % 9) }
        let past = all.filter { $0.day < Self.day }
        let today = Self.value(Self.day, 47)
        let a = Self.compare([today], past)
        let b = Self.compare([today], all)
        XCTAssertEqual(a.newFrozen, b.newFrozen)
        XCTAssertEqual(a.comparisons.map { $0.robustZ }, b.comparisons.map { $0.robustZ })
        XCTAssertEqual(a.comparisons.map { $0.center }, b.comparisons.map { $0.center })
        XCTAssertEqual(a.comparisons.map { $0.supportDays }, b.comparisons.map { $0.supportDays })
    }

    func testReferencesAreReproducibleAndOrderIndependent() throws {
        // C05: same inputs → byte-identical output, whatever the input order (duplicates resolved by a rule).
        var hist = Self.history(30) { 40 + Double(($0 * 7) % 13) }
        hist += Self.history(10, series: "resting_hr.sleep_night") { 50 + Double($0 % 4) }
        hist.append(Self.value(hist[3].day, 999, support: 0))          // duplicate day, lower support → ignored
        let today = [Self.value(Self.day, 44), Self.value(Self.day, 53, series: "resting_hr.sleep_night")]
        let a = Self.compare(today, hist)
        var g = PC.Evaluation.SeededGenerator(seed: 7)
        let shuffled = hist.shuffled(using: &g)
        let b = Self.compare(today.reversed(), shuffled)
        XCTAssertEqual(try PC.encoder().encode(a.comparisons), try PC.encoder().encode(b.comparisons))
        XCTAssertEqual(a.newFrozen, b.newFrozen)
        XCTAssertTrue(Self.view(a.comparisons, .rolling)!.reasons.contains(Ref.duplicateHistoryDayResolved))
        XCTAssertEqual(Self.view(a.comparisons, .rolling)?.supportDays, 28)
        // Round trip through the document JSON.
        let data = try PC.encoder().encode(a.comparisons)
        XCTAssertEqual(try PC.decoder().decode([PC.ReferenceComparison].self, from: data), a.comparisons)
    }

    func testExcludedSeriesAreNotCompared() {
        let v = PC.DailyValue(day: Self.day, seriesKey: "coverage.motion_observed_s", regimeKey: "coverage", metric: nil,
                              value: 3600, units: "s", supportCount: 1, supportUnit: "day", supportS: 3600,
                              mode: .retrospective, finality: .final)
        XCTAssertTrue(Self.compare([v], []).comparisons.isEmpty)
    }

    // MARK: Primitives

    func testRobustPrimitivesAndCalendarArithmetic() {
        XCTAssertEqual(PC.RobustStats.madSmallSampleFactor(10), 10 / 9.2, accuracy: 1e-12)
        XCTAssertEqual(PC.RobustStats.madSmallSampleFactor(1), 1)
        XCTAssertEqual(PC.RobustStats.madScale([1, 2, 3, 4, 100], center: 3, smallSampleCorrection: false)!, 1.4826, accuracy: 1e-12)
        XCTAssertNil(PC.RobustStats.madScale([.nan], center: 0, smallSampleCorrection: true))
        XCTAssertEqual(PC.RobustStats.theilSenSlope(x: [0, 1, 2, 3, 4], y: [0, 2, 4, 6, 100])!, 2, accuracy: 1e-12)
        XCTAssertEqual(PC.RobustStats.winsorizedNormalVariance(k: 2.5), 0.97756, accuracy: 1e-4)
        XCTAssertEqual(Ref.dayNumber("1970-01-01"), 0)
        XCTAssertEqual(Ref.dayNumber("2024-03-01")! - Ref.dayNumber("2024-02-28")!, 2)   // leap year
        XCTAssertEqual(Ref.dayNumber("2026-03-01")! - Ref.dayNumber("2026-02-28")!, 1)
        XCTAssertNil(Ref.dayNumber("2026-02-30"))
        XCTAssertNil(Ref.dayNumber("2026-3-01"))
        for n in [-1, 0, 20_000, 20_513, 30_000] { XCTAssertEqual(Ref.dayNumber(Ref.dayKey(n)), n) }
    }
}
