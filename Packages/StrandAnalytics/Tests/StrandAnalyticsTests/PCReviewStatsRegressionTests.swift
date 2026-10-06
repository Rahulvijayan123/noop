import Foundation
import XCTest
@testable import StrandAnalytics

/// Regression tests from the independent statistics review (notes/review-statistics.md), kept so the repaired
/// defects stay repaired (repairs: notes/review-statistics-repairs.md). Each test asserts the behaviour the spec
/// asks for. The two `testReviewPrint*` cases print re-check numbers and gate nothing; they run only with
/// `REVIEW_PRINT=1` (the 2000-replicate re-check takes about 11 minutes in a debug build).
final class PCReviewStatsRegressionTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias Ref = PhysiologyContext.ContextReferences
    typealias CD = PhysiologyContext.ChangeDetection
    typealias Ev = PhysiologyContext.Evaluation

    static let day = "2026-03-10"

    static func dv(_ day: String, _ v: Double, series: String, regime: String = "r1",
                   mode: PC.ProcessingMode = .retrospective, units: String = "per_h") -> PC.DailyValue {
        PC.DailyValue(day: day, seriesKey: series, regimeKey: regime, metric: nil, value: v, units: units,
                      supportCount: 1, supportUnit: "day", supportS: 36_000, mode: mode, finality: .final)
    }

    static func history(_ n: Int, before end: String = day, series: String, mode: PC.ProcessingMode = .retrospective,
                        _ f: (Int) -> Double) -> [PC.DailyValue] {
        let e = Ref.dayNumber(end)!
        return (0..<n).map { i in dv(Ref.dayKey(e - n + i), f(i), series: series, mode: mode) }
    }

    static func rollingComparison(series: String, z: Double, day: String = day) -> PC.ReferenceComparison {
        PC.ReferenceComparison(day: day, seriesKey: series, regimeKey: "r1", view: .rolling, referenceId: nil,
                               status: .ready, supportDays: 28, fromDay: nil, toDay: nil, value: 1, center: 0,
                               scale: 1, scaleFloored: false, signedDifference: 1, transformedDifference: nil,
                               robustZ: z, centerUncertainty: nil, transform: "identity", pooledContribution: 0,
                               reasons: [])
    }

    // MARK: R-F1 — zero-centred identity series get a 1e-6 floor (zero MAD -> near-infinite certainty)

    func testReviewZeroCenteredFunctionalSeriesMustNotGetMicroscopicScaleFloor() {
        let series = PC.Functional.seriesBoutsPerWornHour   // identity transform, no listed floor
        // 20 worn days without a single bout, then one bout in ~4 worn hours.
        let hist = Self.history(20, series: series) { _ in 0 }
        let today = Self.dv(Self.day, 0.25, series: series)
        let out = Ref.compare([today], history: hist, frozen: [], day: Self.day, policyFingerprint: "r",
                              config: .init())
        let rolling = out.comparisons.first { $0.view == .rolling && $0.seriesKey == series }!
        print("REVIEW R-F1 rolling status=\(rolling.status) scale=\(rolling.scale ?? -1) z=\(rolling.robustZ ?? .nan) reasons=\(rolling.reasons.map(\.rawValue))")
        XCTAssertNotNil(rolling.robustZ)
        XCTAssertLessThan(abs(rolling.robustZ ?? 0), 100,
                          "zero MAD with zero centre floors the scale at minimumScale=1e-6: one bout reads as z ≈ 2.5e5")
    }

    // MARK: R-F2 — production 90-day history load cold-starts every document's episode window

    func testReviewNinetyDayHistoryLoadInflatesFalseEpisodesVersusEvaluatedPath() {
        let reps = Int(ProcessInfo.processInfo.environment["REVIEW_REPS"] ?? "") ?? 300
        let phi = Double(ProcessInfo.processInfo.environment["REVIEW_PHI"] ?? "") ?? 0.3
        var s = Ev.Scenario(); s.days = 300; s.phi = phi
        var docsProd = 0, docsFull = 0, epsProd = 0, epsFull = 0, coldStartEps = 0
        var unadjustedScored = 0, scoredProd = 0
        for r in 0..<reps {
            let xs = Ev.generate(s, seed: Ev.streamSeed(4_242_001, "review-cold|\(phi)", r))
            let values = Ev.dailyValues(xs, spec: .rmssd)
            let today = values.last!
            let t = Ref.dayNumber(today.day)!
            let hist90 = values.filter { let n = Ref.dayNumber($0.day)!; return n >= t - 90 && n < t }
            let full = Array(values.dropLast())
            func run(_ h: [PC.DailyValue]) -> [PC.ChangeEpisode] {
                CD.episodes(today: [today], history: h, frozen: [], boundaries: [], day: today.day,
                            mode: .retrospective, finality: .final, policyFingerprint: "r", change: .init(),
                            reference: .init())
            }
            let p = run(hist90).filter { $0.state == .persistentShift && $0.detector == "cusum" }
            let f = run(full).filter { $0.state == .persistentShift && $0.detector == "cusum" }
            epsProd += p.count; epsFull += f.count
            if !p.isEmpty { docsProd += 1 }
            if !f.isEmpty { docsFull += 1 }
            coldStartEps += p.filter { Ref.dayNumber($0.startDay)! < t - 56 }.count
            // How many scored days of the production window run without the autocorrelation adjustment.
            let pts = hist90.map { Ref.RefPoint(dayNum: Ref.dayNumber($0.day)!, day: $0.day, value: $0.value, x: log($0.value)) }
                + [Ref.RefPoint(dayNum: t, day: today.day, value: today.value, x: log(today.value))]
            let sc = CD.score(points: pts, windowStart: t - 90, todayNum: t, frozen: nil, boundaryDays: [],
                              seriesKey: PC.Evaluation.SeriesSpec.rmssd.seriesKey, change: .init(), reference: .init())
            scoredProd += sc.filter { $0.rollingZ != nil }.count
            unadjustedScored += sc.filter { $0.rollingZ != nil && $0.phi == nil }.count
        }
        let shareProd = Double(docsProd) / Double(reps), shareFull = Double(docsFull) / Double(reps)
        print(String(format: "REVIEW R-F2 phi=%.1f reps=%d docs with >=1 CUSUM persistent episode: production(90d load)=%.3f full-lookback=%.3f; episodes/doc %.3f vs %.3f; production episodes starting before D-56 (cold start)=%d; scored days without phi-hat=%d of %d",
                     phi, reps, shareProd, shareFull, Double(epsProd) / Double(reps), Double(epsFull) / Double(reps),
                     coldStartEps, unadjustedScored, scoredProd))
        XCTAssertLessThanOrEqual(shareProd, shareFull + 0.05,
                                 "the worker's 90-day history truncates rolling/phi-hat lookback for the first ~34 days of every document's episode window")
    }

    // MARK: R-F3 — HR-derived recovery series is not mapped to any dependence group

    func testReviewRecoverySeriesSharesHeartRateWithStableAwakeHeartRate() {
        let deps = PC.Engine.dependenceNotes(sleep: PC.SleepRhythmSummary.unavailable([]))
        let cs = [Self.rollingComparison(series: "heart_rate.stable_awake_5min", z: 3.1),
                  Self.rollingComparison(series: PC.ExertionBouts.recoverySeriesKey(kind: "walk", config: .init()), z: -3.0)]
        let m = CD.multiSignal(comparisons: cs, dependence: deps, day: Self.day, config: .init())
        print("REVIEW R-F3 members=\(CD.dependenceMembers(cs[1].seriesKey)) groups=\(m.first?.dependenceGroups ?? []) count=\(m.first?.independentGroupCount ?? -1) reasons=\(m.first?.reasons.map(\.rawValue) ?? [])")
        XCTAssertEqual(m.first?.independentGroupCount, 1,
                       "hr_recovery_60s.* is derived from heart rate and bouts but falls to an 'undeclared:' group")
    }

    // MARK: R-F4 — functional per-worn-waking-hour series depend on the HR-confirmed sleep detector

    func testReviewFunctionalRatesShareTheSleepDetectorWithNightlySeries() {
        let deps = PC.Engine.dependenceNotes(sleep: PC.SleepRhythmSummary.unavailable([]))
        let cs = [Self.rollingComparison(series: "hrv_rmssd.sleep_night", z: -3.0),
                  Self.rollingComparison(series: PC.Functional.seriesLocomotionPerWornHour, z: -3.0)]
        let m = CD.multiSignal(comparisons: cs, dependence: deps, day: Self.day, config: .init())
        print("REVIEW R-F4 count=\(m.first?.independentGroupCount ?? -1) components=\(m.first?.components.map(\.series) ?? [])")
        XCTAssertEqual(m.first?.independentGroupCount, 1,
                       "the worn-waking-hour denominator subtracts sleep episodes (gravity stillness + HR confirmation)")
    }

    // MARK: R-F5 — 5-minute HR windows silently drop contract-valid samples below 30 / above 220 bpm

    func testReviewHeartRateWindowsKeepContractValidBradycardia() {
        let dayWindow = PC.Engine.dayInterval(Self.day, timezoneId: "UTC")
        let t0 = dayWindow.start + 3 * 3600
        let low = (0..<300).map { PC.HeartRateObservation(ts: t0 + $0, bpm: 28) }
        let mixed = (300..<600).map { PC.HeartRateObservation(ts: t0 + $0, bpm: $0 % 2 == 0 ? 25 : 35) }
        let w = PC.Engine.heartRateWindows(low + mixed, dayWindow: dayWindow)
        print("REVIEW R-F5 windows=\(w.map { ($0.support.start - t0, $0.value ?? -1, $0.sampleCount ?? -1) })")
        XCTAssertEqual(w.count, 2, "28 bpm passes the 20-250 input contract but produces no measurement")
        XCTAssertEqual(w.last?.value ?? 0, 30, accuracy: 0.01, "a 25/35 bpm window is reported as 35 bpm")
    }

    // MARK: R-F6 — package-level causal compare accepts a frozen reference created for a later day

    func testReviewCausalCompareRejectsFrozenReferenceCreatedAfterTheDay() {
        let series = "hrv_rmssd.sleep_night"
        let t = Ref.dayNumber(Self.day)!
        let hist = Self.history(20, series: series, mode: .causalLive) { 45 + Double($0 % 3) }
        let today = Self.dv(Self.day, 30, series: series, mode: .causalLive, units: "ms")
        let later = PC.FrozenReference(id: "frz_later", seriesKey: series, regimeKey: "r1", version: 1,
                                       fromDay: Ref.dayKey(t - 40), toDay: Ref.dayKey(t - 27), supportDays: 14,
                                       center: log(45), scale: 0.1, transform: "ln", selectionRule: "x",
                                       createdForDay: Ref.dayKey(t + 30), policyFingerprint: "p")
        let out = Ref.compare([today], history: hist, frozen: [later], day: Self.day, policyFingerprint: "p",
                              config: .init())
        let f = out.comparisons.first { $0.view == .frozen }!
        print("REVIEW R-F6 frozen status=\(f.status) ref=\(f.referenceId ?? "nil") z=\(f.robustZ ?? .nan)")
        XCTAssertNotEqual(f.status, .ready,
                          "causal mode trusts any frozen reference with toDay < day; registration time is only enforced in worker SQL")
    }

    // MARK: R-F7 — backfilled days register their own 'version 1' frozen reference

    func testReviewBackfilledDayUsesTheSameFrozenReferenceAsLaterDays() {
        let series = "hrv_rmssd.sleep_night"
        let y = Ref.dayNumber(Self.day)!
        let all = (0..<200).map { i in Self.dv(Ref.dayKey(y - 200 + i), 40 + Double((i * 7) % 11), series: series, units: "ms") }
        func doc(_ d: Int) -> (PC.ReferenceComparison, [PC.FrozenReference]) {
            let h = all.filter { let n = Ref.dayNumber($0.day)!; return n >= d - 90 && n < d }
            let today = Self.dv(Ref.dayKey(d), 44, series: series, units: "ms")
            let out = Ref.compare([today], history: h, frozen: [], day: Ref.dayKey(d), policyFingerprint: "p",
                                  config: .init())
            return (out.comparisons.first { $0.view == .frozen }!, out.newFrozen)
        }
        let (cy, fy) = doc(y)                      // newest day runs first (claim order: day desc)
        let x = y - 85                             // a backfilled day inside the stored reference's selection
        let stored = fy
        let usable = stored.filter { Ref.dayNumber($0.toDay)! < x }
        let h = all.filter { let n = Ref.dayNumber($0.day)!; return n >= x - 90 && n < x }
        let out = Ref.compare([Self.dv(Ref.dayKey(x), 44, series: series, units: "ms")], history: h, frozen: stored,
                              day: Ref.dayKey(x), policyFingerprint: "p", config: .init())
        let cx = out.comparisons.first { $0.view == .frozen }!
        print("REVIEW R-F7 day Y ref=\(cy.referenceId ?? "nil") (\(fy.first?.fromDay ?? "")..\(fy.first?.toDay ?? "")); backfill day X ref=\(cx.referenceId ?? "nil") new=\(out.newFrozen.map { "\($0.id) \($0.fromDay)..\($0.toDay)" }) usableStored=\(usable.count)")
        XCTAssertTrue(out.newFrozen.isEmpty || out.newFrozen.first?.id == fy.first?.id,
                      "the backfilled day's document registers (and is scored against) a second 'version 1' reference that the insert-only table will reject")
    }

    // MARK: R-F8 — selection accounting counts windows System F then drops

    func testReviewRepresentedShareReflectsWhatEntersReferences() {
        let identity = PCReferenceTests.identity
        // Two eligible-but-degraded 5-min HR windows (System F needs >= 3 valid ones): eligible in System B,
        // zero contribution to System F.
        let envs = [PCReferenceTests.window(.heartRate, method: "context.heart_rate.5min_mean", at: 10, value: 70,
                                            validity: .degraded),
                    PCReferenceTests.window(.heartRate, method: "context.heart_rate.5min_mean", at: 11, value: 72,
                                            validity: .degraded)]
        let s0 = identity.dayWindow.start
        let hr = [10.0, 11.0].flatMap { h in (0..<300).map { PC.HeartRateObservation(ts: s0 + Int(h * 3600) + $0, bpm: 70) } }
        let sel = PC.Eligibility.selection(envelopes: envs, observations: PC.SanitizedObservations(heartRate: hr),
                                           dayWindow: identity.dayWindow)
        let values = Ref.dailyValues(envelopes: envs, identity: identity, mode: .retrospective, finality: .final,
                                     config: .init())
        let share = sel.first { $0.comparison == .stableAwakeRest }?.representedShare
        print("REVIEW R-F8 representedShare=\(share ?? -1) dailyValues=\(values.count)")
        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(share ?? 0, 0, accuracy: 1e-9,
                       "representedShare reports 100 % of observed HR time while nothing reaches a reference")
    }

    // MARK: Numeric demonstrations (not assertions of defects)

    func testReviewPrintSparseAndFallbackRates() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REVIEW_PRINT"] == "1", "set REVIEW_PRINT=1 to print")
        let reps = Int(ProcessInfo.processInfo.environment["REVIEW_REPS"] ?? "") ?? 200
        for (phi, miss) in [(0.5, 0.0), (0.5, 0.5), (0.3, 0.5)] {
            let r = Ev.evaluateNull(phi: phi, replicates: reps, missingRate: miss, resamples: 200, seed: 99_173)
            print(String(format: "REVIEW null phi=%.1f missing=%.1f cusum/wk=%.3f (%.3f-%.3f) persistence/wk=%.3f frozen/wk=%.3f",
                         phi, miss, r.primary.perWeek, r.primary.ciLow, r.primary.ciHigh, r.alternative.perWeek,
                         r.frozen.perWeek))
        }
    }
}

extension PCReviewStatsRegressionTests {
    /// Larger-replicate re-checks of cells that moved between seeds (prints only).
    func testReviewPrintHighReplicateRechecks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REVIEW_PRINT"] == "1", "set REVIEW_PRINT=1 to print")
        let reps = Int(ProcessInfo.processInfo.environment["REVIEW_BIG_REPS"] ?? "") ?? 2000
        for seed: UInt64 in [20_261_005, 31_337] {
            for (phi, m) in [(0.5, -2.0), (0.5, -1.0), (0.3, -2.0)] {
                let r = Ev.evaluateStep(phi: phi, magnitudeSigma: m, replicates: reps, resamples: 200, seed: seed)
                print(String(format: "REVIEW step seed=%llu phi=%.1f step=%.0f reps=%d cusum missed=%.3f (%.3f-%.3f) median delay=%.1f persistence missed=%.3f",
                             seed, phi, m, reps, r.primary.missedShare, r.primary.missedShareCI?.lo ?? -1,
                             r.primary.missedShareCI?.hi ?? -1, r.primary.medianDelay ?? -1, r.alternative.missedShare))
            }
            for phi in [0.0, 0.3] {
                let a = Ev.evaluateArtifact(phi: phi, magnitudeSigma: 8, replicates: reps, seed: seed)
                print(String(format: "REVIEW artifact seed=%llu phi=%.1f reps=%d transient=%.3f cusum<=14d with=%.3f without=%.3f",
                             seed, phi, reps, a.transientShare, a.persistentShare, a.persistentShareWithoutArtifact))
            }
        }
    }
}

extension PCReviewStatsRegressionTests {
    /// R-F1b — `hr_recovery_60s.*` (integer-bpm declines) has no listed floor: 2 % of a 20 bpm centre = 0.4 bpm,
    /// below the 1 bpm resolution the HR floors use, so a 1 bpm difference crosses the 2.5 deviation threshold.
    func testReviewRecoverySeriesGetsTheIntegerBpmFloor() {
        let series = PC.ExertionBouts.recoverySeriesKey(kind: "walk", config: .init())
        let hist = Self.history(20, series: series) { i in i % 5 == 0 ? 19 : 20 }
        let out = Ref.compare([Self.dv(Self.day, 21, series: series, units: "bpm")], history: hist, frozen: [],
                              day: Self.day, policyFingerprint: "r", config: .init())
        let rolling = out.comparisons.first { $0.view == .rolling }!
        print("REVIEW R-F1b series=\(series) scale=\(rolling.scale ?? -1) z=\(rolling.robustZ ?? .nan)")
        XCTAssertGreaterThanOrEqual(rolling.scale ?? 0, 1.0, "HR-derived recovery decline should get the 1 bpm floor")
    }
}

extension PCReviewStatsRegressionTests {
    /// R-L3 — causal parent stable-awake value at 09:30 is the median of morning windows only, compared with earlier
    /// days' causal values that the worker last published at day end (whole-day medians). Nothing in the comparison
    /// records or conditions on the partial-day coverage.
    func testReviewCausalPartialDayStableAwakeValueIsComparedLikeForLike() {
        let series = "heart_rate.stable_awake_5min"
        // Earlier causal days: last publish of the day = median over 3 morning (58 bpm) + 5 afternoon (70 bpm) windows.
        let hist = Self.history(20, series: series, mode: .causalLive) { i in [69.0, 70, 71][i % 3] }
        // Today at 09:30: only the three morning windows exist before the cutoff.
        let envs = [6.5, 7.5, 8.5].map {
            PCReferenceTests.window(.heartRate, method: "context.heart_rate.5min_mean", at: $0, value: 58)
        }
        let today = Ref.dailyValues(envelopes: envs, identity: PCReferenceTests.identity, mode: .causalLive,
                                    finality: .provisional, config: .init())
        let out = Ref.compare(today, history: hist, frozen: [], day: PCReferenceTests.day, policyFingerprint: "p",
                              config: .init())
        let rolling = out.comparisons.first { $0.view == .rolling && $0.seriesKey == series }!
        print("REVIEW R-L3 today=\(today.map { "\($0.seriesKey)=\($0.value)" }) rolling z=\(rolling.robustZ ?? .nan) status=\(rolling.status) reasons=\(rolling.reasons.map(\.rawValue))")
        XCTAssertLessThan(abs(rolling.robustZ ?? 0), 2.5,
                          "a time-of-day composition difference alone produces a 'deviating' causal parent comparison")
    }
}
