import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Swift twin of the Android `RecoveryDriversUiTest` wiring cases.
///
/// This suite could not exist before: the derivation lived as a private method inside `TodayView` (and a
/// byte-identical copy inside `CoupledView`), reachable only by rendering the view, so the iOS end of the
/// "What shaped it" path had no test at all while Android's did. `ChargeBreakdownWiring.breakdown` is that
/// derivation lifted out unchanged.
///
/// Case mapping against the Kotlin suite, stated so the gap is legible rather than implied:
///   * `rhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable` - twinned below.
///   * `coldStartHistoryProducesNoRows` - twinned below.
///   * `scoredDayProducesDriverRows` - twinned below, and it carries the confidence assertion too, since
///     this API returns the tier in the same tuple where Kotlin has a separate `chargeConfidenceTier`.
///   * `nullDayProducesNoRows` - deliberately NOT twinned. This API takes a non-optional row, so the
///     nil-row guard stays in the view where it belongs; there is nothing here to assert.
final class ChargeBreakdownWiringTests: XCTestCase {

    private func day(_ d: String, hrv: Double? = 55, rhr: Int? = 55, recovery: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 450, efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: nil,
                    exerciseCount: nil)
    }

    /// A history with no banked resting HR folds to `foldHistory`'s synthetic midpoint (about 75 bpm),
    /// which is nobody's resting HR, so the row must be absent. The HRV row still stands, since that
    /// baseline is real. The display day itself carries a reading, so this pins the BASELINE being
    /// unusable rather than the reading being missing.
    ///
    /// The gate is not in this file: `RecoveryScorer.chargeDrivers` applies it (#1990). This pins the end
    /// of the path, the surface a user actually sees.
    func testRhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable() {
        let history = (1...6).map { day(String(format: "2026-01-%02d", $0), rhr: nil) }
        let today = day("2026-01-07", rhr: 55)
        let out = ChargeBreakdownWiring.breakdown(days: history + [today], row: today, sleepPerfPercent: 85)
        let labels = (out?.drivers ?? []).map(\.label)
        XCTAssertTrue(labels.contains("Heart rate variability"),
                      "the HRV baseline is real, so its row must still be there: \(labels)")
        XCTAssertFalse(labels.contains("Resting heart rate"),
                       "no usable resting-HR baseline, so no RHR row: \(labels)")
    }

    /// Two nights only: the HRV baseline is not usable yet, so there are no honest drivers and the sheet
    /// hides rather than showing fabricated rows.
    func testColdStartHistoryProducesNoBreakdown() {
        let days = [day("2026-01-01"), day("2026-01-02")]
        XCTAssertNil(ChargeBreakdownWiring.breakdown(days: days, row: days[1], sleepPerfPercent: 85))
    }

    /// The usable-baseline half of the pair: a real history banks both baselines, so both rows appear and
    /// the surfaced tier is past calibrating.
    func testAScoredDayProducesDriverRowsAndATier() {
        let past = (1...10).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let today = day("2026-01-20", hrv: 62, rhr: 51, recovery: 64)
        let out = ChargeBreakdownWiring.breakdown(days: past + [today], row: today, sleepPerfPercent: 85)
        XCTAssertNotNil(out)
        let labels = (out?.drivers ?? []).map(\.label)
        XCTAssertTrue(labels.contains("Heart rate variability"), "\(labels)")
        XCTAssertTrue(labels.contains("Resting heart rate"), "\(labels)")
        XCTAssertNotEqual(out?.confidence, .calibrating)
    }

    /// Epoch for a `yyyy-MM-dd` key at UTC midnight, matching what Recalibrate writes.
    private func epochOf(_ day: String) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let date = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
        return date.timeIntervalSince1970
    }

    func testDriverBaselineHonoursTheRecalibrationEpoch() {
        // The reported shape: low-HRV history, Recalibrate, then higher nights. Folding the WHOLE history
        // gives one baseline and folding from the epoch gives another, and the headline uses the second.
        // These rows have to agree with the headline rather than with history.
        //
        // Asserted on `baselineText` because that is what a Swift ChargeDriver carries: it pre-formats for
        // display where the Kotlin twin keeps a numeric `baseline`. Different text is the observable proof
        // that a different history was folded.
        let old = (1...10).map { day(String(format: "2026-01-%02d", $0), hrv: 40) }
        let since = (11...20).map { day(String(format: "2026-01-%02d", $0), hrv: 70) }
        let today = day("2026-01-21", hrv: 72, recovery: 70)
        let days = old + since + [today]

        let whole = ChargeBreakdownWiring.breakdown(days: days, row: today, sleepPerfPercent: 85,
                                                    hrvBaselineEpoch: 0)
        let fromEpoch = ChargeBreakdownWiring.breakdown(days: days, row: today, sleepPerfPercent: 85,
                                                        hrvBaselineEpoch: epochOf("2026-01-11"))
        let hrvRow: ((drivers: [ChargeDriver], confidence: ScoreConfidence)?) -> ChargeDriver? = { out in
            out?.drivers.first(where: { $0.label == "Heart rate variability" })
        }
        guard let w = hrvRow(whole), let r = hrvRow(fromEpoch) else {
            return XCTFail("both folds must produce an HRV row")
        }
        XCTAssertNotEqual(w.baselineText, r.baselineText,
                          "the epoch fold must discard the pre-recalibration nights, so the baseline it "
                          + "reports differs from the whole-history one (whole=\(w.baselineText), "
                          + "fromEpoch=\(r.baselineText))")
    }

    func testAnAbsentEpochLeavesTheBaselineExactlyAsItWas() {
        // The common case: nobody who never recalibrated may see any change from this.
        let past = (1...10).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let today = day("2026-01-20", hrv: 62, rhr: 51, recovery: 64)
        let implicit = ChargeBreakdownWiring.breakdown(days: past + [today], row: today, sleepPerfPercent: 85)
        let explicitZero = ChargeBreakdownWiring.breakdown(days: past + [today], row: today,
                                                          sleepPerfPercent: 85, hrvBaselineEpoch: 0)
        XCTAssertEqual(implicit?.drivers.map(\.label), explicitZero?.drivers.map(\.label))
        XCTAssertEqual(implicit?.drivers.map(\.baselineText), explicitZero?.drivers.map(\.baselineText))
        XCTAssertEqual(implicit?.drivers.map(\.deltaPoints), explicitZero?.drivers.map(\.deltaPoints))
    }

    /// D4-02: a past day opened from the day picker is explained against the days BEFORE it only. Ten
    /// later days at a very different HRV / resting HR must not move its rows or its tier.
    func testLaterDaysDoNotMoveAPastDaysBreakdown() {
        let past = (1...20).map { day(String(format: "2026-01-%02d", $0), hrv: 60 + Double($0 % 3), rhr: 50) }
        let shown = day("2026-01-21", hrv: 45, rhr: 58, recovery: 30)
        let later = (22...31).map { day(String(format: "2026-01-%02d", $0), hrv: 30, rhr: 70) }
        let alone = ChargeBreakdownWiring.breakdown(days: past + [shown], row: shown, sleepPerfPercent: 85)
        let withLater = ChargeBreakdownWiring.breakdown(days: past + [shown] + later, row: shown,
                                                        sleepPerfPercent: 85)
        XCTAssertNotNil(alone)
        XCTAssertEqual(alone?.drivers.map(\.baselineText), withLater?.drivers.map(\.baselineText))
        XCTAssertEqual(alone?.drivers.map(\.deltaPoints), withLater?.drivers.map(\.deltaPoints))
        XCTAssertEqual(alone?.confidence, withLater?.confidence)
    }

    /// D4-02: the shown night itself is not part of its own baseline (no self-inclusion).
    func testTheShownNightIsNotInItsOwnBaseline() {
        let past = (1...20).map { day(String(format: "2026-01-%02d", $0), hrv: 60) }
        let a = ChargeBreakdownWiring.breakdown(days: past + [day("2026-01-21", hrv: 40)],
                                                row: day("2026-01-21", hrv: 40), sleepPerfPercent: 85)
        let b = ChargeBreakdownWiring.breakdown(days: past + [day("2026-01-21", hrv: 90)],
                                                row: day("2026-01-21", hrv: 40), sleepPerfPercent: 85)
        let hrvText: ((drivers: [ChargeDriver], confidence: ScoreConfidence)?) -> String? = {
            $0?.drivers.first(where: { $0.label == "Heart rate variability" })?.baselineText
        }
        XCTAssertNotNil(hrvText(a))
        XCTAssertEqual(hrvText(a), hrvText(b))
    }

    /// D4-02: resting HR honours the Charge-wide recalibration epoch, as the engine's headline does.
    func testRestingHrBaselineHonoursTheRecoveryEpoch() {
        let old = (1...10).map { day(String(format: "2026-01-%02d", $0), rhr: 70) }
        let since = (11...20).map { day(String(format: "2026-01-%02d", $0), rhr: 50) }
        let today = day("2026-01-21", rhr: 51, recovery: 70)
        let rhrRow: ((drivers: [ChargeDriver], confidence: ScoreConfidence)?) -> ChargeDriver? = {
            $0?.drivers.first(where: { $0.label == "Resting heart rate" })
        }
        let whole = rhrRow(ChargeBreakdownWiring.breakdown(days: old + since + [today], row: today,
                                                           sleepPerfPercent: 85))
        let fromEpoch = rhrRow(ChargeBreakdownWiring.breakdown(days: old + since + [today], row: today,
                                                               sleepPerfPercent: 85,
                                                               recoveryBaselineEpoch: epochOf("2026-01-11")))
        XCTAssertNotNil(whole); XCTAssertNotNil(fromEpoch)
        XCTAssertNotEqual(whole?.baselineText, fromEpoch?.baselineText)
    }

    // MARK: Engine-first (D4-02 / D4-V02 review)

    private func computed(_ d: String, recovery: Double?, drivers: [ChargeDriver],
                          confidence: ScoreConfidence) -> IntelligenceEngine.Computed {
        IntelligenceEngine.Computed(day: d, recovery: recovery, strain: nil, sleepMin: nil, hrv: 60, rhr: 52,
                                    confidence: confidence, drivers: drivers)
    }

    private let engineDriver = ChargeDriver(label: "Heart rate variability", deltaPoints: 7, valueText: "60 ms",
                                            baselineText: "53 ms baseline", verdict: "engine row")

    /// When the engine scored the very number the row shows, the sheet renders the engine's own era- and
    /// method-scoped drivers and tier verbatim, never a re-derivation from merged `repo.days`.
    func testEngineScoredNightIsRenderedVerbatim() {
        let past = (1...10).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let row = day("2026-01-20", hrv: 62, rhr: 51, recovery: 64)
        let engine = [computed("2026-01-20", recovery: 64, drivers: [engineDriver], confidence: .building)]
        let out = ChargeBreakdownWiring.breakdown(days: past + [row], row: row, sleepPerfPercent: 85, engine: engine)
        XCTAssertEqual(out?.drivers, [engineDriver])
        XCTAssertEqual(out?.confidence, .building)
        XCTAssertEqual(ChargeBreakdownWiring.chargeConfidence(days: past + [row], row: row, hrvBaselineEpoch: 0,
                                                              engine: engine), .building)
    }

    /// A different Charge on the row (a vendor import won the merge) is NOT explained by the engine's NOOP
    /// drivers: the causal fallback runs instead.
    func testEngineNightWithADifferentScoreFallsBackToTheCausalFold() {
        let past = (1...10).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let row = day("2026-01-20", hrv: 62, rhr: 51, recovery: 71)
        let engine = [computed("2026-01-20", recovery: 64, drivers: [engineDriver], confidence: .solid)]
        let out = ChargeBreakdownWiring.breakdown(days: past + [row], row: row, sleepPerfPercent: 85, engine: engine)
        XCTAssertNotNil(out)
        XCTAssertNotEqual(out?.drivers, [engineDriver])
        XCTAssertEqual(out?.drivers, ChargeBreakdownWiring.breakdown(days: past + [row], row: row,
                                                                      sleepPerfPercent: 85)?.drivers)
    }

    /// D4-V02 on Today's watch chip: a past day scored on a thin (provisional) baseline keeps its "building"
    /// tier after weeks of later nights arrive. The old end-of-history fold re-stamped it "solid".
    func testPastDayConfidenceIsCausalAndStableUnderAppend() {
        let past = (1...6).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let row = day("2026-01-07", hrv: 55, rhr: 52, recovery: 60)
        let later = (8...31).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let before = ChargeBreakdownWiring.chargeConfidence(days: past + [row], row: row, hrvBaselineEpoch: 0)
        let after = ChargeBreakdownWiring.chargeConfidence(days: past + [row] + later, row: row, hrvBaselineEpoch: 0)
        XCTAssertEqual(before, .building)
        XCTAssertEqual(after, before, "later nights must not re-stamp a past day's tier")
        let oldWholeHistory = ScoreConfidence.charge(
            recovery: row.recovery,
            hrvBaseline: Baselines.foldHistory((past + [row] + later).map(\.avgHrv), cfg: Baselines.hrvCfg))
        XCTAssertEqual(oldWholeHistory, .solid, "the defect: the end-of-history fold reads solid")
    }
}
