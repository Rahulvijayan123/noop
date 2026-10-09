import XCTest
@testable import StrandAnalytics

/// D4-01 / D4-V02 / D4-04 / run1 D4-14: causal as-of folds, regime resets, hierarchical method fallback,
/// and `rejectHardOutliers` on the day-keyed overload.
final class BaselinesAsOfTests: XCTestCase {

    private func key(_ i: Int) -> String {
        // 2026-01-01 + i days, UTC.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let d = cal.date(byAdding: .day, value: i,
                         to: cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!)!
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func epoch(_ i: Int) -> Double {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key(i))!.timeIntervalSince1970
    }

    // MARK: D4-01 - the brief's acceptance test

    /// Night 31 at 40 ms after 30 nights at 60 is z-scored only against nights 1-30, and its baseline does
    /// not change when nights 32-40 are appended.
    func testNight31IsScoredOnlyAgainstNights1To30AndIsStableUnderAppend() {
        let cfg = Baselines.hrvCfg
        let first30: [Double?] = Array(repeating: 60, count: 30)
        let keys31 = (0..<31).map(key)
        let asOf31 = Baselines.foldHistoryAsOf(first30 + [40], dayKeys: keys31, cfg: cfg, baselineEpoch: 0)
        let causal = Baselines.foldHistory(first30, cfg: cfg)
        XCTAssertEqual(asOf31[key(30)], causal, "night 31 must see exactly nights 1-30")

        let keys40 = (0..<40).map(key)
        let values40: [Double?] = first30 + Array(repeating: 40, count: 10)
        let asOf40 = Baselines.foldHistoryAsOf(values40, dayKeys: keys40, cfg: cfg, baselineEpoch: 0)
        XCTAssertEqual(asOf40[key(30)], causal, "appending nights 32-40 must not move night 31's baseline")
        XCTAssertEqual(Baselines.deviation(40, state: asOf40[key(30)]!).z,
                       Baselines.deviation(40, state: causal).z)

        // The old behaviour (one end-of-history fold) visibly differs, which is the leak being fixed.
        let whole = Baselines.foldHistory(values40, cfg: cfg)
        XCTAssertNotEqual(whole, causal)
    }

    /// Run the leak.py scenario through the real fold and report the per-night z drift between the old
    /// end-of-history scoring and the causal as-of scoring (D4-01 measurement).
    func testMeasuredZDriftOldVersusAsOf() {
        // Deterministic LCG + Box-Muller so the series is reproducible without Foundation randomness.
        var seed: UInt64 = 7
        func uniform() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
        func gauss(_ mu: Double, _ sd: Double) -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return mu + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let n = 120
        var vals: [Double?] = (0..<(n - 10)).map { _ in gauss(60, 5) }
        vals += (0..<10).map { _ in gauss(45, 3) }
        let keys = (0..<n).map(key)
        let cfg = Baselines.hrvCfg
        let whole = Baselines.foldHistory(vals, cfg: cfg)
        let asOf = Baselines.foldHistoryAsOf(vals, dayKeys: keys, cfg: cfg, baselineEpoch: 0)
        var oldDz: [Double] = []
        var newDz: [Double] = []
        for d in (n - 21)..<n {
            let causal = Baselines.foldHistory(Array(vals[..<d]), cfg: cfg)
            let zc = Baselines.deviation(vals[d]!, state: causal).z
            oldDz.append(abs(Baselines.deviation(vals[d]!, state: whole).z - zc))
            newDz.append(abs(Baselines.deviation(vals[d]!, state: asOf[keys[d]]!).z - zc))
        }
        let oldMean = oldDz.reduce(0, +) / Double(oldDz.count)
        let newMean = newDz.reduce(0, +) / Double(newDz.count)
        print("D4-01 measurement: mean|dz| old=\(oldMean) max=\(oldDz.max()!) new=\(newMean) max=\(newDz.max()!)")
        XCTAssertGreaterThan(oldMean, 0.2, "the old whole-history fold leaks materially on this series")
        XCTAssertEqual(newMean, 0, accuracy: 1e-12)
    }

    // MARK: D4-V02 - confidence provenance

    /// Night 5's baseline is the 4-night (provisional) fold, and stays so after nights 6-30 are added.
    func testNight5KeepsItsProvisionalTierAfterLaterNightsArrive() {
        let cfg = Baselines.hrvCfg
        let v: [Double?] = (0..<30).map { 55 + Double($0 % 3) }
        let a = Baselines.foldHistoryAsOf(Array(v[..<5]), dayKeys: (0..<5).map(key), cfg: cfg, baselineEpoch: 0)
        let b = Baselines.foldHistoryAsOf(v, dayKeys: (0..<30).map(key), cfg: cfg, baselineEpoch: 0)
        XCTAssertEqual(a[key(4)]?.status, .provisional)
        XCTAssertEqual(a[key(4)]?.nValid, 4)
        XCTAssertEqual(b[key(4)], a[key(4)])
        XCTAssertEqual(ScoreConfidence.charge(recovery: 50, hrvBaseline: b[key(4)]), .building)
        XCTAssertEqual(ScoreConfidence.charge(recovery: 50, hrvBaseline: Baselines.foldHistory(v, cfg: cfg)), .solid,
                       "the old end-of-history state re-labels night 5 as solid")
    }

    // MARK: Epoch / regime semantics

    func testEndStateMatchesTheEpochAwareFold() {
        let cfg = Baselines.hrvCfg
        let v: [Double?] = (0..<25).map { $0 < 10 ? 40 : 70 + Double($0 % 2) }
        let keys = (0..<25).map(key)
        for e in [0, epoch(10), epoch(24), epoch(30)] {
            let d = Baselines.foldHistoryAsOfDetailed(v, dayKeys: keys, cfg: cfg, baselineEpoch: e)
            XCTAssertEqual(d.end, Baselines.foldHistory(v, dayKeys: keys, cfg: cfg, baselineEpoch: e), "epoch \(e)")
        }
    }

    func testDaysBeforeTheEpochAreJudgedAgainstTheirOwnPastAndDaysAfterRestart() {
        let cfg = Baselines.hrvCfg
        let v: [Double?] = (0..<20).map { $0 < 10 ? 40 : 70 }
        let keys = (0..<20).map(key)
        let asOf = Baselines.foldHistoryAsOf(v, dayKeys: keys, cfg: cfg, baselineEpoch: epoch(10))
        XCTAssertEqual(asOf[key(9)], Baselines.foldHistory(Array(v[..<9]), cfg: cfg))
        XCTAssertEqual(asOf[key(10)]?.nValid, 0, "the first post-epoch night starts a fresh build-up")
        XCTAssertEqual(asOf[key(14)], Baselines.foldHistory(Array(v[10..<14]), cfg: cfg))
    }

    func testRegimeChangeRestartsTheFoldAtEveryBoundary() {
        let cfg = Baselines.hrvCfg
        let v: [Double?] = (0..<30).map { $0 < 20 ? 130 : 80 }
        let keys = (0..<30).map(key)
        let regimes = (0..<30).map { $0 < 20 ? "oura" : "whoop" }
        let asOf = Baselines.foldHistoryAsOfDetailed(v, dayKeys: keys, cfg: cfg, baselineEpoch: 0, regimes: regimes)
        XCTAssertEqual(asOf.before[key(25)], Baselines.foldHistory(Array(v[20..<25]), cfg: cfg))
        XCTAssertEqual(asOf.before[key(15)], Baselines.foldHistory(Array(v[..<15]), cfg: cfg))
        let era = Baselines.deviceEraEpoch(keys.enumerated().map { (day: $0.element, sourceId: $0.offset < 20 ? "oura-import" : "my-whoop") })
        XCTAssertEqual(asOf.end, Baselines.foldHistory(v, dayKeys: keys, cfg: cfg, baselineEpoch: era),
                       "the end state equals the deviceEraEpoch-scoped fold")
    }

    // MARK: D4-04 - brand era + method fallback

    /// 60 Oura nights at 40, then 10 WHOOP nights at 60: the WHOOP baseline is ~60, never Oura-dominated.
    func testBrandSwitchScopesTheBaselineToTheCurrentEra() {
        var merged: [String: Double?] = [:]
        var src: [String: String] = [:]
        for i in 0..<70 {
            merged[key(i)] = i < 60 ? 40 : 60
            src[key(i)] = i < 60 ? "oura-import" : "my-whoop"
        }
        let r = Baselines.regimeScopedAsOf(merged: merged, computed: nil, sourceByDay: src,
                                           defaultSource: "my-whoop", cfg: Baselines.hrvCfg, baselineEpoch: 0)
        XCTAssertEqual(r.end.state.baseline, 60, accuracy: 0.5)
        XCTAssertEqual(r.end.state.nValid, 10)
        XCTAssertFalse(r.end.fallbackUsed)
    }

    /// A long vendor-import history then NOOP nights: the first NOOP nights are scored against the vendor
    /// parent with an explicit fallback (not a reset to calibrating, not a silent pool), and the child takes
    /// over completely once trusted.
    func testMethodSwitchShrinksTowardTheParentWithExplicitFallback() {
        var merged: [String: Double?] = [:]
        var computed: [String: Double?] = [:]
        for i in 0..<60 { merged[key(i)] = 70 }                    // vendor nights
        for i in 60..<80 { merged[key(i)] = 60; computed[key(i)] = 60 }   // NOOP nights
        let r = Baselines.regimeScopedAsOf(merged: merged, computed: computed, sourceByDay: [:],
                                           defaultSource: "my-whoop", cfg: Baselines.hrvCfg, baselineEpoch: 0)
        let first = r.byDay[key(60)]!
        XCTAssertTrue(first.fallbackUsed)
        XCTAssertEqual(first.childWeight, 0)
        XCTAssertEqual(first.state.baseline, Baselines.foldHistory(Array(repeating: 70, count: 60), cfg: Baselines.hrvCfg).baseline)
        XCTAssertTrue(first.state.usable, "a method switch must not reset Charge to calibrating")
        XCTAssertEqual(first.state.status, .provisional, "a fallback never claims trusted")

        let mid = r.byDay[key(67)]!
        XCTAssertTrue(mid.fallbackUsed)
        XCTAssertEqual(mid.childWeight, 0.5, accuracy: 1e-12)

        let late = r.byDay[key(75)]!
        XCTAssertFalse(late.fallbackUsed, "15 NOOP nights: the method-consistent child alone")
        XCTAssertEqual(late.state, Baselines.foldHistory(Array(repeating: 60, count: 15), cfg: Baselines.hrvCfg))
        XCTAssertEqual(late.asOfDay, key(74))
    }

    func testSingleMethodHistoryNeverReportsFallback() {
        var m: [String: Double?] = [:]
        for i in 0..<10 { m[key(i)] = 55 }
        let r = Baselines.regimeScopedAsOf(merged: m, computed: m, sourceByDay: [:], defaultSource: "my-whoop",
                                           cfg: Baselines.hrvCfg, baselineEpoch: 0)
        XCTAssertFalse(r.byDay.values.contains { $0.fallbackUsed })
        XCTAssertEqual(r.end.state, Baselines.foldHistory(Array(repeating: 55, count: 10), cfg: Baselines.hrvCfg))
    }

    // MARK: run1 D4-14 - rejectHardOutliers on the day-keyed overload

    func testDayKeyedFoldThreadsRejectHardOutliers() {
        let cfg = Baselines.hrvCfg
        // 20 settled nights at 50, then a sustained shift to 90 (> 5x the floor spread away).
        let v: [Double?] = Array(repeating: 50, count: 20) + Array(repeating: 90, count: 10)
        let keys = (0..<30).map(key)
        let e = epoch(2)
        let suffix = Array(v[2...])
        XCTAssertEqual(Baselines.foldHistory(v, dayKeys: keys, cfg: cfg, baselineEpoch: e, rejectHardOutliers: false),
                       Baselines.foldHistory(suffix, cfg: cfg, rejectHardOutliers: false))
        XCTAssertEqual(Baselines.foldHistory(v, dayKeys: keys, cfg: cfg, baselineEpoch: e),
                       Baselines.foldHistory(suffix, cfg: cfg))
        XCTAssertNotEqual(Baselines.foldHistory(v, dayKeys: keys, cfg: cfg, baselineEpoch: e, rejectHardOutliers: false),
                          Baselines.foldHistory(v, dayKeys: keys, cfg: cfg, baselineEpoch: e),
                          "the flag must actually reach update()")
        // And with no epoch it delegates with the flag too.
        XCTAssertEqual(Baselines.foldHistory(v, dayKeys: keys, cfg: cfg, baselineEpoch: 0, rejectHardOutliers: false),
                       Baselines.foldHistory(v, cfg: cfg, rejectHardOutliers: false))
    }

    /// The D4-04 measurement on a series where the two folds can actually differ for a regime reason: 60
    /// nights of an Oura ring (RMSSD ~120 ms) then 40 WHOOP nights (~70 ms). The old Charge HRV fold pooled
    /// both brands over the whole history; the reference is an INDEPENDENT plain `foldHistory` over only the
    /// earlier same-era nights. Reported: the old pooled fold's |dz| against that reference on the newest 21
    /// nights, and the as-of (regime-scoped) fold's.
    func testMeasuredZDriftOnABrandSwitch() {
        var seed: UInt64 = 11
        func uniform() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
        func gauss(_ mu: Double, _ sd: Double) -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return mu + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let n = 100, switchAt = 60
        let vals: [Double?] = (0..<n).map { $0 < switchAt ? gauss(120, 9) : gauss(70, 6) }
        let keys = (0..<n).map(key)
        var source: [String: String] = [:]
        for i in 0..<n { source[keys[i]] = i < switchAt ? "oura-import" : "my-whoop" }
        var map: [String: Double?] = [:]
        for i in 0..<n { map[keys[i]] = vals[i] }
        let cfg = Baselines.hrvCfg
        let whole = Baselines.foldHistory(vals, cfg: cfg)
        let asOf = Baselines.regimeScopedAsOf(merged: map, computed: nil, sourceByDay: source,
                                              defaultSource: "my-whoop", cfg: cfg, baselineEpoch: 0).byDay
        var oldDz: [Double] = [], newDz: [Double] = []
        for d in (n - 21)..<n {
            let reference = Baselines.foldHistory(Array(vals[switchAt..<d]), cfg: cfg)
            let zr = Baselines.deviation(vals[d]!, state: reference).z
            oldDz.append(abs(Baselines.deviation(vals[d]!, state: whole).z - zr))
            newDz.append(abs(Baselines.deviation(vals[d]!, state: asOf[keys[d]]!.state).z - zr))
        }
        let oldMean = oldDz.reduce(0, +) / Double(oldDz.count)
        let newMean = newDz.reduce(0, +) / Double(newDz.count)
        print("D4-04 measurement (brand switch): old pooled fold mean|dz|=\(oldMean) max=\(oldDz.max()!); "
              + "as-of regime-scoped mean|dz|=\(newMean) max=\(newDz.max()!)")
        XCTAssertGreaterThan(oldMean, 0.2)
        XCTAssertLessThan(newMean, 1e-9)
    }

    /// A NOOP history that went quiet through a long vendor-import-only stretch is STALE (not usable):
    /// scoring against it alone would blank a Charge the parent can still score, so it falls back fully.
    func testStaleChildFallsBackToTheParent() {
        var merged: [String: Double?] = [:]
        var computed: [String: Double?] = [:]
        for i in 0..<20 { merged[key(i)] = 60; computed[key(i)] = 60 }       // NOOP nights
        for i in 20..<40 { merged[key(i)] = 70; computed[key(i)] = .some(nil) } // vendor-only stretch
        merged[key(40)] = 62; computed[key(40)] = 62
        let r = Baselines.regimeScopedAsOf(merged: merged, computed: computed, sourceByDay: [:],
                                           defaultSource: "my-whoop", cfg: Baselines.hrvCfg, baselineEpoch: 0)
        let d = r.byDay[key(40)]!
        XCTAssertTrue(d.fallbackUsed)
        XCTAssertEqual(d.childWeight, 0)
        XCTAssertTrue(d.state.usable, "the parent still scores the night")
    }
}
