import XCTest
@testable import StrandAnalytics

/// BaselineStandard fix A: the phone's Charge re-score judges each night only against the nights before it
/// (`ChargeBaselines.asOf`), on ln HRV, over the whole stored history, with confounded nights out of the fold.
///
/// `testMeasuredChargeShiftOnA90NightTape` measures what the change does to Charge values on a realistic
/// synthetic tape and prints the distribution (it is the number quoted in the hand-off report).
final class ChargeBaselinesTests: XCTestCase {

    typealias BS = BaselineStandard

    private func key(_ i: Int) -> String { BS.dayKey(BS.epochDay("2026-03-01")! + i) }

    // MARK: - A deterministic, realistic tape

    struct Night {
        var day: String
        var hrv: Double?
        var rhr: Double?
        var resp: Double?
        var skinAbs: Double?
        var sleepPerf: Double
    }

    /// 90 nights: ln-HRV AR(1) around 55 ms (σ_ln ≈ 0.14), resting HR AR(1) around 54 bpm (σ ≈ 2), respiration
    /// 15.2 ± 0.35, absolute skin 33.6 ± 0.22 °C, Rest 0.84 ± 0.07, a 5-night illness dip (HRV −25 %, RHR +4,
    /// resp +1, skin +0.5) from night 55, four logged alcohol nights (HRV −15 %, RHR +3) and six missing nights.
    static func tape(count: Int = 90, seed: UInt64 = 2026_10_07) -> (nights: [Night], alcohol: Set<Int>) {
        var s = seed
        func uniform() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
        func gauss() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let alcohol: Set<Int> = [12, 33, 47, 71]
        let missing: Set<Int> = [8, 9, 26, 40, 63, 64]
        var eH = 0.0, eR = 0.0
        var out: [Night] = []
        for i in 0..<count {
            eH = 0.4 * eH + 0.14 * (1 - 0.16).squareRoot() * gauss()
            eR = 0.5 * eR + 2.0 * (1 - 0.25).squareRoot() * gauss()
            let ill = (55..<60).contains(i)
            var lnH = log(55) + eH + (ill ? log(0.75) : 0) + (alcohol.contains(i) ? log(0.85) : 0)
            lnH = min(max(lnH, log(10)), log(200))
            let rhr = 54 + eR + (ill ? 4 : 0) + (alcohol.contains(i) ? 3 : 0)
            let resp = 15.2 + 0.35 * gauss() + (ill ? 1 : 0)
            let skin = 33.6 + 0.22 * gauss() + (ill ? 0.5 : 0)
            let sp = min(max(0.84 + 0.07 * gauss(), 0.4), 1.0)
            let d = BS.dayKey(BS.epochDay("2026-03-01")! + i)
            if missing.contains(i) {
                out.append(Night(day: d, hrv: nil, rhr: nil, resp: nil, skinAbs: nil, sleepPerf: sp))
            } else {
                out.append(Night(day: d, hrv: exp(lnH), rhr: rhr.rounded(), resp: resp, skinAbs: skin, sleepPerf: sp))
            }
        }
        return (out, alcohol)
    }

    private func inputs(_ nights: [Night], logs: [String: LBDayLog] = [:]) -> ChargeBaselines.Inputs {
        func m(_ pick: (Night) -> Double?) -> [String: Double] { BS.series(nights, day: \.day, value: pick) }
        return ChargeBaselines.Inputs(hrvMerged: m(\.hrv), rhrMerged: m(\.rhr), respMerged: m(\.resp),
                                      skinAbsolute: m(\.skinAbs), context: BS.Context(dayLogs: logs))
    }

    /// Charge for one night against a ProfileBaselines, exactly as IntelligenceEngine.recomputeRecoveryDaily.
    static func charge(_ n: Night, _ b: AnalyticsEngine.ProfileBaselines) -> Double? {
        guard let hrv = n.hrv, let rhr = n.rhr, let hb = b.hrv else { return nil }
        let dev: Double? = n.skinAbs.flatMap { v in
            b.skinTemp.flatMap { s in s.usable ? (Baselines.deviation(v, state: s).delta * 100).rounded() / 100 : nil }
        }
        return RecoveryScorer.recovery(hrv: hrv, rhr: rhr, resp: n.resp, hrvBaseline: hb, rhrBaseline: b.restingHR,
                                       respBaseline: b.resp, sleepPerf: n.sleepPerf, skinTempDev: dev,
                                       hrvScale: b.hrvScale)
    }

    /// The OLD phone path: one end-of-window fold per metric (raw ms HRV), every night scored against it.
    static func legacyEndState(_ nights: [Night]) -> AnalyticsEngine.ProfileBaselines {
        let resp = Baselines.foldHistory(nights.map(\.resp), cfg: Baselines.respCfg)
        let skin = Baselines.foldHistory(nights.map(\.skinAbs), cfg: Baselines.metricCfg["skin_temp"]!)
        return AnalyticsEngine.ProfileBaselines(
            hrv: Baselines.foldHistory(nights.map(\.hrv), cfg: Baselines.hrvCfg),
            restingHR: Baselines.foldHistory(nights.map(\.rhr), cfg: Baselines.restingHRCfg),
            resp: resp.usable ? resp : nil, skinTemp: skin.usable ? skin : nil)
    }

    // MARK: - Rule 2: no look-ahead, no self-inclusion

    func testAppendingLaterNightsNeverChangesAPastNightsCharge() {
        let (nights, _) = Self.tape()
        let first60 = Array(nights.prefix(60))
        let short = ChargeBaselines.asOf(inputs(first60))
        let long = ChargeBaselines.asOf(inputs(nights))
        for n in first60 {
            XCTAssertEqual(Self.charge(n, short.baselines(for: n.day)), Self.charge(n, long.baselines(for: n.day)),
                           "night \(n.day) must not see later nights")
        }
        // The old end-state path does move a past night when nights are appended (the defect).
        let night30 = nights[30]
        XCTAssertNotEqual(Self.charge(night30, Self.legacyEndState(first60))!,
                          Self.charge(night30, Self.legacyEndState(nights))!, accuracy: 1e-9)
    }

    func testANightIsNeverPartOfItsOwnBaseline() {
        let (nights, _) = Self.tape()
        let r = ChargeBaselines.asOf(inputs(nights))
        let night = nights[40]
        let lnPrior: [Double?] = nights.prefix(40).map { n in n.hrv.map { Foundation.log($0) } }
        let expected = Baselines.foldHistory(
            BS.calendarDays(from: nights[0].day, through: nights[39].day).enumerated().map { lnPrior[$0.offset] },
            cfg: Baselines.readinessHRVLnCfg)
        XCTAssertEqual(r.baselines(for: night.day).hrv, expected)
        XCTAssertEqual(r.baselines(for: night.day).hrvScale, .ln)
    }

    func testFirstFourNightsHaveNoCharge() {
        let (nights, _) = Self.tape()
        let r = ChargeBaselines.asOf(inputs(nights))
        for n in nights.prefix(4) { XCTAssertNil(Self.charge(n, r.baselines(for: n.day)), "rule 4: n < 4 → no Charge") }
        XCTAssertNotNil(Self.charge(nights[4], r.baselines(for: nights[4].day)))
    }

    // MARK: - Skin over the full history, not the scan window

    func testSkinBaselineSeesTheWholeStoredHistory() {
        let (nights, _) = Self.tape()
        // The engine's skin input is the stored computed history PLUS this pass: a night at index 80 is judged
        // against every earlier skin night, not only the ones inside a 21-day scan window.
        let r = ChargeBaselines.asOf(inputs(nights))
        let s = r.baselines(for: nights[80].day).skinTemp
        let valid = nights.prefix(80).compactMap(\.skinAbs).count
        XCTAssertEqual(s?.nValid, valid)
        XCTAssertGreaterThan(valid, 21)
    }

    // MARK: - Rule 3: confounders

    func testAConfoundedNightIsScoredButNeverFolded() {
        let (nights, _) = Self.tape()
        let a = 33
        let logs = [key(a): LBDayLog(alcohol: true)]
        let with = ChargeBaselines.asOf(inputs(nights, logs: logs))
        let without = ChargeBaselines.asOf(inputs(nights))
        // Scored: the alcohol night itself still gets a Charge, against the same before-state either way.
        XCTAssertEqual(with.baselines(for: key(a)).hrv, without.baselines(for: key(a)).hrv)
        XCTAssertNotNil(Self.charge(nights[a], with.baselines(for: key(a))))
        // Not folded: the next night's baseline holds one valid night fewer.
        XCTAssertEqual(with.baselines(for: key(a + 1)).hrv!.nValid + 1, without.baselines(for: key(a + 1)).hrv!.nValid)
    }

    // MARK: - Rule 6: method fallback and regime reset

    func testAMethodSwitchShrinksTowardTheParentInsteadOfRecalibrating() {
        // 40 imported nights, then NOOP's own computed nights from night 40.
        let (nights, _) = Self.tape(count: 50)
        var merged: [String: Double] = [:], computed: [String: Double] = [:]
        for (i, n) in nights.enumerated() {
            guard let h = n.hrv else { continue }
            merged[n.day] = h
            if i >= 40 { computed[n.day] = h * 1.05 }
        }
        let r = ChargeBaselines.asOf(ChargeBaselines.Inputs(hrvMerged: merged, hrvComputed: computed,
                                                            rhrMerged: [:], respMerged: [:]))
        let first = r.baselines(for: key(41)).hrv!
        XCTAssertTrue(first.usable, "the first NOOP nights still score (parent fallback), never calibrating")
        XCTAssertTrue(r.hrvFallbackDays.contains(key(41)))
        XCTAssertNotEqual(first.status, .trusted, "a fallback baseline never claims trusted")
    }

    func testARegimeChangeRestartsTheFold() {
        let (nights, _) = Self.tape(count: 40)
        var regimes: [String: String] = [:]
        for (i, n) in nights.enumerated() { regimes[n.day] = i < 30 ? "oura" : "whoop5" }
        var input = inputs(nights)
        input.context = BS.Context(regimeByDay: regimes)
        let r = ChargeBaselines.asOf(input)
        XCTAssertEqual(r.baselines(for: key(30)).hrv?.nValid, 0, "a new device era starts from nothing")
        XCTAssertNil(Self.charge(nights[30], r.baselines(for: key(30))))
    }

    // MARK: - The measured shift (documented in the hand-off report)

    func testMeasuredChargeShiftOnA90NightTape() {
        let (nights, alcohol) = Self.tape()
        let logs = Dictionary(uniqueKeysWithValues: alcohol.map { (key($0), LBDayLog(alcohol: true)) })
        let legacy = Self.legacyEndState(nights)
        let causal = ChargeBaselines.asOf(inputs(nights, logs: logs))

        var deltas: [Double] = []
        var newlyNil = 0, bothNil = 0
        var illnessBefore: [Double] = [], illnessAfter: [Double] = []
        for (i, n) in nights.enumerated() {
            let before = Self.charge(n, legacy)
            let after = Self.charge(n, causal.baselines(for: n.day))
            switch (before, after) {
            case let (b?, a?):
                deltas.append(a - b)
                if (55..<60).contains(i) { illnessBefore.append(b); illnessAfter.append(a) }
            case (_?, nil): newlyNil += 1
            case (nil, nil): bothNil += 1
            default: XCTFail("the causal path never scores a night the end-state path could not")
            }
        }
        let absD = deltas.map(abs).sorted()
        func q(_ p: Double) -> Double { absD[min(absD.count - 1, Int((Double(absD.count - 1) * p).rounded()))] }
        let meanSigned = deltas.reduce(0, +) / Double(deltas.count)
        let illMeanBefore = illnessBefore.reduce(0, +) / Double(max(1, illnessBefore.count))
        let illMeanAfter = illnessAfter.reduce(0, +) / Double(max(1, illnessAfter.count))
        print(String(format: "CHARGE-SHIFT n=%d |Δ| median=%.1f p75=%.1f p90=%.1f max=%.1f meanSigned=%+.2f "
                     + "newlyNil=%d (first nights, n<4) missingBoth=%d illnessMeanBefore=%.1f after=%.1f",
                     deltas.count, q(0.5), q(0.75), q(0.9), absD.last ?? 0, meanSigned, newlyNil, bothNil,
                     illMeanBefore, illMeanAfter))
        // Attribution: the same causal baselines but with the raw-ms HRV fold (no ln), so the print separates
        // "causal + full history + confounders" from "ln instead of ms".
        let hrvMs = Baselines.foldHistoryAsOf(nights.map(\.hrv).enumerated().map { i, v in
                                                  alcohol.contains(i) ? nil : v },
                                              dayKeys: nights.map(\.day), cfg: Baselines.hrvCfg, baselineEpoch: 0)
        var lnOnly: [Double] = []
        for n in nights {
            let b = causal.baselines(for: n.day)
            let msB = AnalyticsEngine.ProfileBaselines(hrv: hrvMs[n.day], restingHR: b.restingHR, resp: b.resp,
                                                       skinTemp: b.skinTemp, hrvScale: .ms)
            if let a = Self.charge(n, b), let m = Self.charge(n, msB) { lnOnly.append(abs(a - m)) }
        }
        lnOnly.sort()
        print(String(format: "CHARGE-SHIFT ln-vs-ms (both causal) |Δ| median=%.1f p90=%.1f max=%.1f",
                     lnOnly[lnOnly.count / 2], lnOnly[Int(Double(lnOnly.count - 1) * 0.9)], lnOnly.last ?? 0))
        // Guard rails on the documented shift: the weighting and the logistic are unchanged, so the bulk of
        // nights move by a few points; only the earliest nights (thin causal baseline) move a lot.
        XCTAssertEqual(newlyNil, 4, "only the first four nights lose their (look-ahead) Charge")
        XCTAssertLessThan(q(0.5), 10)
        XCTAssertLessThan(illMeanAfter, 50, "the illness dip still reads low")
    }
}
