import XCTest
@testable import StrandAnalytics

/// Audit 2026-10-07, server Charge (fix B): `DayScoring.loadBaselines` hands RecoveryScorer its respiration fold
/// UNGATED. With no respiration nights the fold is the n = 0 seed (midpoint 22 bpm, spread at the 0.5 floor), so
/// a perfectly ordinary 15 bpm night read z ≈ +11 and pushed Charge up. The gate now lives in RecoveryScorer's
/// `BaselineState` overload (phone and server both pass through it), and in the driver rows and the trace, for
/// respiration and Effort exactly as #1988 did for resting HR.
final class RecoveryUnusableBaselineGateTests: XCTestCase {

    private let hrvBase = BaselineState(baseline: 55, spread: 9, nValid: 30, nightsSinceUpdate: 0, status: .trusted)
    private let rhrBase = BaselineState(baseline: 52, spread: 2, nValid: 30, nightsSinceUpdate: 0, status: .trusted)
    /// What `Baselines.foldHistory([], cfg: respCfg)` returns: never banked.
    private var seedResp: BaselineState { Baselines.foldHistory([], cfg: Baselines.respCfg) }

    func testSeedRespirationFoldIsTheAuditCase() {
        XCTAssertEqual(seedResp.nValid, 0)
        XCTAssertEqual(seedResp.baseline, 22)
        // The z the ungated term used to add (lower resp is better → (μ − x)/σ).
        let z = RecoveryScorer.zScore(seedResp.baseline, mean: 15, spread: seedResp.spread)
        XCTAssertGreaterThan(z, 10)
    }

    func testUnusableRespirationBaselineDropsTheTerm() {
        let gated = RecoveryScorer.recovery(hrv: 55, rhr: 52, resp: 15, hrvBaseline: hrvBase,
                                            rhrBaseline: rhrBase, respBaseline: seedResp, sleepPerf: 0.85)
        let absent = RecoveryScorer.recovery(hrv: 55, rhr: 52, resp: 15, hrvBaseline: hrvBase,
                                             rhrBaseline: rhrBase, respBaseline: nil, sleepPerf: 0.85)
        XCTAssertEqual(gated!, absent!, accuracy: 1e-12)
        // And a usable respiration baseline still contributes (the gate is not a blanket off).
        let usable = BaselineState(baseline: 16, spread: 0.5, nValid: 10, nightsSinceUpdate: 0, status: .provisional)
        let scored = RecoveryScorer.recovery(hrv: 55, rhr: 52, resp: 15, hrvBaseline: hrvBase,
                                             rhrBaseline: rhrBase, respBaseline: usable, sleepPerf: 0.85)
        XCTAssertNotEqual(scored!, absent!, accuracy: 1e-6)
    }

    func testUnusableEffortBaselineDropsTheTerm() {
        let seedEffort = Baselines.foldHistory([], cfg: Baselines.strainCfg)
        let gated = RecoveryScorer.recovery(hrv: 55, rhr: 52, resp: nil, hrvBaseline: hrvBase,
                                            rhrBaseline: rhrBase, respBaseline: nil, sleepPerf: 0.85,
                                            effortBaseline: seedEffort, priorDayEffort: 10)
        let absent = RecoveryScorer.recovery(hrv: 55, rhr: 52, resp: nil, hrvBaseline: hrvBase,
                                             rhrBaseline: rhrBase, respBaseline: nil, sleepPerf: 0.85)
        XCTAssertEqual(gated!, absent!, accuracy: 1e-12)
    }

    func testDriverRowsAndTraceGateRespirationLikeTheScore() {
        let rows = RecoveryScorer.chargeDrivers(hrv: 55, rhr: 52, resp: 15, hrvBaseline: hrvBase,
                                                rhrBaseline: rhrBase, respBaseline: seedResp, sleepPerf: 0.85)
        XCTAssertFalse(rows.map(\.label).contains("Respiratory rate"))
        let (score, lines) = RecoveryScorer.recoveryTrace(hrv: 55, rhr: 52, resp: 15, hrvBaseline: hrvBase,
                                                          rhrBaseline: rhrBase, respBaseline: seedResp,
                                                          sleepPerf: 0.85)
        XCTAssertFalse(lines.contains { $0.hasPrefix("charge baseline resp") })
        XCTAssertTrue(lines.contains { $0.contains("dropped=[") && $0.contains("resp") })
        XCTAssertEqual(score!, RecoveryScorer.recovery(hrv: 55, rhr: 52, resp: 15, hrvBaseline: hrvBase,
                                                       rhrBaseline: rhrBase, respBaseline: nil,
                                                       sleepPerf: 0.85)!, accuracy: 1e-12)
    }

    // MARK: the ln HRV scale (rule 1) keeps rows and trace in ms

    func testLnScaleScoresOnLnAndDisplaysInMs() {
        let lnBase = BaselineState(baseline: log(55), spread: 0.12, nValid: 30, nightsSinceUpdate: 0,
                                   status: .trusted)
        let score = RecoveryScorer.recovery(hrv: 44, rhr: 52, resp: nil, hrvBaseline: lnBase,
                                            rhrBaseline: rhrBase, respBaseline: nil, sleepPerf: 0.85,
                                            hrvScale: .ln)!
        // The same composite by hand: HRV z on ln.
        let zH = (log(44) - log(55)) / (1.253 * 0.12)
        let zR = (52.0 - 52.0) / (1.253 * 2)
        let zS = (0.85 - RecoveryScorer.sleepPerfCenter) / RecoveryScorer.sleepPerfScale
        let w = RecoveryScorer.wHRV + RecoveryScorer.wRHR + RecoveryScorer.wSleep
        let expected = RecoveryScorer.logisticScore(
            compositeZ: (zH * RecoveryScorer.wHRV + zR * RecoveryScorer.wRHR + zS * RecoveryScorer.wSleep) / w)
        XCTAssertEqual(score, expected, accuracy: 1e-9)

        let rows = RecoveryScorer.chargeDrivers(hrv: 44, rhr: 52, resp: nil, hrvBaseline: lnBase,
                                                rhrBaseline: rhrBase, respBaseline: nil, sleepPerf: 0.85,
                                                hrvScale: .ln)
        let hrvRow = rows.first { $0.label == "Heart rate variability" }!
        XCTAssertEqual(hrvRow.valueText, "44 ms")
        XCTAssertEqual(hrvRow.baselineText, "55 ms baseline")
        XCTAssertLessThan(hrvRow.deltaPoints, 0)

        let (traceScore, lines) = RecoveryScorer.recoveryTrace(hrv: 44, rhr: 52, resp: nil, hrvBaseline: lnBase,
                                                               rhrBaseline: rhrBase, respBaseline: nil,
                                                               sleepPerf: 0.85, hrvScale: .ln)
        XCTAssertEqual(traceScore!, score, accuracy: 1e-12)
        XCTAssertTrue(lines.contains { $0.contains("scale=ln meanMs=55") })
    }
}
