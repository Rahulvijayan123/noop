import XCTest
@testable import StrandAnalytics

/// The BaselineStandard registry itself: every rule's primitive, one assertion each.
final class BaselineStandardTests: XCTestCase {

    typealias BS = BaselineStandard

    private func key(_ i: Int) -> String { BS.dayKey(BS.epochDay("2026-01-01")! + i) }

    // MARK: rule 5 — floors shared with PhysiologyContext, and every EWMA config at or above them

    func testScaleFloorsAreThePhysiologyContextTable() {
        XCTAssertEqual(BS.scaleFloor(.hrvRmssd), 0.05)
        XCTAssertEqual(BS.scaleFloor(.restingHR), 1.0)
        XCTAssertEqual(BS.scaleFloor(.respiration), 0.3)
        XCTAssertEqual(BS.scaleFloor(.skinTempDeviation), 0.1)
        XCTAssertEqual(BS.scaleFloor(.skinTempAbsolute), 0.1)
        // Read from the server context engine's own config, so the two cannot drift apart.
        let pc = PhysiologyContext.ReferenceConfig().scaleFloors
        XCTAssertEqual(pc.first { $0.seriesPrefix == "hrv_rmssd." }?.floor, BS.scaleFloor(.hrvRmssd))
    }

    func testEveryStandardEWMAConfigImpliesAFloorAtLeastTheStandardOne() {
        for m in BS.Metric.allCases {
            XCTAssertGreaterThanOrEqual(BS.impliedSigmaFloor(BS.cfg(m)), BS.scaleFloor(m),
                                        "\(m): an EWMA fold may keep a larger floor, never a smaller one")
        }
        XCTAssertEqual(BS.cfg(.hrvRmssd), Baselines.readinessHRVLnCfg, "rule 1: HRV folds on ln")
        XCTAssertEqual(BS.cfg(.skinTempDeviation), VitalBands.skinTempDeviationCfg)
    }

    // MARK: rule 1 — ln HRV, SDNN excluded, skin column semantics

    func testHRVIsModelledInLnAndShownInMs() {
        XCTAssertEqual(BS.toModel(54.6, .hrvRmssd)!, log(54.6), accuracy: 1e-12)
        XCTAssertEqual(BS.fromModel(log(54.6), .hrvRmssd), 54.6, accuracy: 1e-9)
        XCTAssertNil(BS.toModel(0, .hrvRmssd))
        XCTAssertEqual(BS.toModel(61, .restingHR), 61)
    }

    func testAbsoluteSkinRowsAreNotDeviations() {
        XCTAssertEqual(BS.skinDeviation(0.4), 0.4)
        XCTAssertEqual(BS.skinDeviation(-1.2), -1.2)
        XCTAssertNil(BS.skinDeviation(33.4), "a WHOOP CSV absolute wrist °C is not a deviation")
        XCTAssertNil(BS.skinDeviation(6.0))
        XCTAssertNil(BS.toModel(33.4, .skinTempDeviation))
    }

    func testSDNNDaysAreExcludedAndNotComparable() {
        let ctx = BS.Context(sdnnDays: [key(3)])
        XCTAssertTrue(ctx.excludedFromReference(key(3), metric: .hrvRmssd))
        XCTAssertFalse(ctx.comparable(key(3), metric: .hrvRmssd))
        XCTAssertFalse(ctx.excludedFromReference(key(3), metric: .restingHR), "SDNN only affects HRV")
    }

    // MARK: rule 3 — confounders reuse Layer 1's nightIsClean

    func testConfounderSemanticsMatchLayer1() {
        let logs = [key(2): LBDayLog(alcohol: true), key(4): LBDayLog(scheduledMed: .taken),
                    key(5): LBDayLog(sleepTypical: false)]
        XCTAssertTrue(BS.isConfounded(key(2), dayLogs: logs))
        XCTAssertFalse(BS.isConfounded(key(4), dayLogs: logs), "a scheduled course does not drop the night")
        XCTAssertTrue(BS.isConfounded(key(5), dayLogs: logs))
        XCTAssertFalse(BS.isConfounded(key(6), dayLogs: logs))
        for d in [key(2), key(4), key(5), key(6)] {
            XCTAssertEqual(BS.isConfounded(d, dayLogs: logs),
                           !LongitudinalBaseline.nightIsClean(BS.epochDay(d)!, dayLogs: logs))
        }
    }

    // MARK: rule 4 — status thresholds

    func testStatusThresholds() {
        XCTAssertEqual(BS.status(n: 3), .calibrating)
        XCTAssertEqual(BS.status(n: 4), .provisional)
        XCTAssertEqual(BS.status(n: 13), .provisional)
        XCTAssertEqual(BS.status(n: 14), .trusted)
    }

    // MARK: rule 6 — regimes

    func testRegimeTagSplitsWhoopFamiliesOnlyWhenTheModelSaysSo() {
        XCTAssertEqual(BS.regimeTag(sourceId: "my-whoop", deviceModel: "WHOOP 4.0"), "whoop4")
        XCTAssertEqual(BS.regimeTag(sourceId: "whoop-abc", deviceModel: "WHOOP 5.0 / MG"), "whoop5")
        XCTAssertEqual(BS.regimeTag(sourceId: "my-whoop", deviceModel: nil), "whoop")
        XCTAssertEqual(BS.regimeTag(sourceId: "my-whoop", deviceModel: "WHOOP"), "whoop",
                       "the legacy label names no generation")
        XCTAssertEqual(BS.regimeTag(sourceId: "whoop-1", deviceModel: "5.0 MG", deviceBrand: "WHOOP"), "whoop5")
        XCTAssertEqual(BS.regimeTag(sourceId: "oura-import", deviceModel: "Oura (import)"), "oura")
    }

    func testResolveRegimesInheritsUnknownsAndKeepsRealChanges() {
        XCTAssertEqual(BS.resolveRegimes(["whoop", nil, "whoop4", "whoop", nil, "whoop5", nil]),
                       ["whoop4", "whoop4", "whoop4", "whoop4", "whoop4", "whoop5", "whoop5"])
        XCTAssertEqual(BS.resolveRegimes(["oura", nil, "whoop", "whoop5"]),
                       ["oura", "oura", "whoop5", "whoop5"])
        XCTAssertEqual(BS.resolveRegimes(["whoop", "whoop"]), ["whoop", "whoop"], "no known family: one era")
    }

    func testReferenceEpochIsTheLaterOfRecalibrationAndDeviceEra() {
        let d = UserDefaults(suiteName: "BaselineStandardTests-\(UUID().uuidString)")!
        XCTAssertEqual(BS.referenceEpoch(metric: .restingHR, defaults: d), 0)
        d.set(1_000.0, forKey: Baselines.recoveryBaselineEpochKey)
        d.set(2_000.0, forKey: Baselines.hrvBaselineEpochKey)
        XCTAssertEqual(BS.referenceEpoch(metric: .restingHR, defaults: d), 1_000)
        XCTAssertEqual(BS.referenceEpoch(metric: .hrvRmssd, defaults: d), 2_000)
        let era = BS.referenceEpoch(metric: .restingHR,
                                    sourceDays: [("2026-01-01", "oura-import"), ("2026-02-01", "my-whoop")],
                                    defaults: d)
        XCTAssertEqual(era, Double(BS.epochDay("2026-02-01")!) * 86_400)
    }

    // MARK: fix J — one recalibration epoch reaches every app context

    func testRecalibrateWritesTheEpochEveryAppContextReads() {
        let d = UserDefaults(suiteName: "BaselineStandardTests-J-\(UUID().uuidString)")!
        let now = Double(BS.epochDay("2026-09-10")!) * 86_400 + 3_600   // 01:00 UTC on the 10th
        Baselines.recalibrateRecoveryBaselines(now: now, defaults: d)
        let ctx = BS.Context.app(dayLogs: [:], defaults: d)
        for m in BS.Metric.allCases {
            XCTAssertEqual(ctx.epoch(m), now, "\(m) must honour the Recalibrate action")
            XCTAssertEqual(BS.referenceEpochs(defaults: d)[m], now)
        }
        // The first day a reference may use: the 10th starts before the epoch, so the 11th.
        XCTAssertEqual(BS.firstDayOnOrAfter(epoch: now), "2026-09-11")
        XCTAssertEqual(BS.firstDayOnOrAfter(epoch: Double(BS.epochDay("2026-09-10")!) * 86_400), "2026-09-10")
        XCTAssertNil(BS.firstDayOnOrAfter(epoch: 0))
        // And a window reference drops the pre-epoch days.
        var series: [String: Double] = [:]
        for i in 0..<20 { series[BS.dayKey(BS.epochDay("2026-09-01")! + i)] = 55 }
        XCTAssertEqual(BS.windowReference(series, metric: .restingHR, asOf: "2026-09-21", context: ctx).n, 10)
    }

    func testVitalBandsCanBandHRVOnLn() {
        let history: [Double?] = (0..<20).map { _ in 60 }
        let lnCfg = Baselines.readinessHRVLnCfg
        // 60 ms every night: on ln the σ floor is 1.253·0.08 ≈ 0.1, so 72 ms (+18 %, ln +0.18) is ~1.8σ: in range;
        // 80 ms (ln +0.29) is out.
        XCTAssertEqual(VitalBands.band(value: 72, history: history, populationRange: 40...120, cfg: lnCfg,
                                       logScale: true).band, .inRange)
        XCTAssertEqual(VitalBands.band(value: 80, history: history, populationRange: 40...120, cfg: lnCfg,
                                       logScale: true).band, .outOfRange)
        XCTAssertEqual(VitalBands.band(value: 80, history: history, populationRange: 40...120, cfg: lnCfg,
                                       logScale: true).basis, .personal)
    }

    // MARK: rule 7 + the robust window reference

    func testWindowReferenceIsCausalCalendarAndFloored() {
        // 40 days at exactly 55 bpm: constant history → MAD 0 → the 1 bpm floor, never ~0.
        var series: [String: Double] = [:]
        for i in 0..<40 { series[key(i)] = 55 }
        let ref = BS.windowReference(series, metric: .restingHR, asOf: key(40))
        XCTAssertEqual(ref.n, 28, "28 CALENDAR days strictly before the day")
        XCTAssertEqual(ref.scale, 1.0)
        XCTAssertTrue(ref.scaleFloored)
        XCTAssertEqual(ref.toDay, key(39))
        XCTAssertEqual(ref.fromDay, key(12))

        // A missing week is missing: the window does not reach further back to refill it.
        for i in 30..<37 { series[key(i)] = nil }
        XCTAssertEqual(BS.windowReference(series, metric: .restingHR, asOf: key(40)).n, 21)

        // Causal: the day itself and later days never enter.
        series[key(40)] = 90; series[key(41)] = 90
        XCTAssertEqual(BS.windowReference(series, metric: .restingHR, asOf: key(40)).center, 55)
    }

    func testWindowReferenceBelowFourDaysGivesNoZ() {
        let series = [key(0): 50.0, key(1): 52, key(2): 51]
        let ref = BS.windowReference(series, metric: .restingHR, asOf: key(3))
        XCTAssertFalse(ref.usable)
        XCTAssertNil(ref.z(60))
        XCTAssertEqual(ref.status, .calibrating)
    }

    func testWindowReferenceHRVIsLnAndStopsAtARegimeChange() {
        var series: [String: Double] = [:]
        var regimes: [String: String] = [:]
        for i in 0..<20 { series[key(i)] = 120; regimes[key(i)] = "oura" }
        for i in 20..<30 { series[key(i)] = 60; regimes[key(i)] = "whoop4" }
        let ctx = BS.Context(regimeByDay: regimes)
        let ref = BS.windowReference(series, metric: .hrvRmssd, asOf: key(30), context: ctx)
        XCTAssertEqual(ref.n, 10, "the Oura era must not enter a WHOOP-era reference")
        XCTAssertEqual(ref.center, log(60), accuracy: 1e-12)
        XCTAssertEqual(ref.centerNative, 60, accuracy: 1e-9)
        XCTAssertEqual(ref.scale, 0.05, "ln floor")
    }

    func testCausalFoldPadsCalendarDaysAndDropsConfoundedNights() {
        var series: [String: Double] = [:]
        for i in 0..<10 { series[key(i)] = 60 }
        series[key(5)] = 20   // logged alcohol night: scored, never folded
        let logs = [key(5): LBDayLog(alcohol: true)]
        let fold = BS.causalFold(series, metric: .hrvRmssd, through: key(12),
                                 context: BS.Context(dayLogs: logs))
        XCTAssertEqual(fold.before.count, 13, "every calendar day through `through` has an as-of state")
        XCTAssertEqual(fold.before[key(6)]!.nValid, 5, "the confounded night did not enter the fold")
        XCTAssertEqual(fold.before[key(6)]!.baseline, log(60), accuracy: 1e-9)
        XCTAssertEqual(fold.before[key(12)]!.nightsSinceUpdate, 2, "missing calendar days are missing")
    }
}
