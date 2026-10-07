import XCTest
import WhoopStore
@testable import StrandAnalytics

/// BaselineStandard fix D: the cycle-phase nightly z-scores (`CyclePhaseEngine.nights(from:context:)`) and the
/// fused-index MAD floor.
final class CyclePhaseBaselineStandardTests: XCTestCase {

    typealias BS = BaselineStandard

    private func key(_ i: Int) -> String { BS.dayKey(BS.epochDay("2026-02-01")! + i) }

    /// A 28-day biphasic skin deviation (+0.35 °C luteal half), with RHR / HRV following it.
    private func days(_ n: Int, absoluteFrom: Int? = nil) -> [DailyMetric] {
        (0..<n).map { i in
            let luteal = (i % 28) >= 14
            let wiggle = 0.05 * Double((i * 7) % 5 - 2)
            var skin = (luteal ? 0.35 : 0.0) + wiggle
            if let a = absoluteFrom, i >= a { skin = 33.5 + wiggle }
            return DailyMetric(day: key(i), totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                               lightMin: nil, disturbances: nil, restingHr: luteal ? 56 : 53,
                               avgHrv: luteal ? 52 : 60, recovery: nil, strain: nil, exerciseCount: nil,
                               skinTempDevC: skin)
        }
    }

    func testDeviationRowsMakeTheSkinBaselineUsable() {
        let d = days(60)
        // The defect: the absolute skin_temp config (min 20 °C) rejects every deviation.
        XCTAssertFalse(Baselines.foldHistory(d.map(\.skinTempDevC), cfg: Baselines.metricCfg["skin_temp"]!).usable)
        let built = CyclePhaseEngine.nights(from: d)
        XCTAssertTrue(built.skinBaselineUsable)
        XCTAssertNotEqual(CyclePhaseEngine.classify(built.nights, baselineUsable: built.skinBaselineUsable).phase,
                          .learning, "60 nights of deviations must leave the permanent learning state")
    }

    func testEachNightIsScoredOnlyAgainstEarlierNights() {
        let short = CyclePhaseEngine.nights(from: days(45)).nights
        let long = CyclePhaseEngine.nights(from: days(80)).nights
        for (a, b) in zip(short, long.prefix(45)) {
            XCTAssertEqual(a, b, "appending later nights changed \(a.day)")
        }
        XCTAssertTrue(short.prefix(4).allSatisfy { $0.tempZ == nil && $0.hrvZ == nil }, "no z below 4 nights")
        XCTAssertNotNil(short[4].tempZ)
    }

    func testHRVIsZScoredOnLn() {
        let d = days(40)
        let built = CyclePhaseEngine.nights(from: d).nights
        let fold = BS.causalFold(BS.series(d, day: \.day, value: \.avgHrv), metric: .hrvRmssd, through: key(39))
        XCTAssertEqual(built[30].hrvZ!, Baselines.deviation(log(d[30].avgHrv!), state: fold.before[key(30)]!).z,
                       accuracy: 1e-12)
    }

    func testAbsoluteImportedRowsAreNotDeviations() {
        let built = CyclePhaseEngine.nights(from: days(50, absoluteFrom: 40)).nights
        XCTAssertTrue(built[40...].allSatisfy { $0.tempZ == nil }, "an absolute °C row is never a deviation z")
        XCTAssertNotNil(built[39].tempZ)
    }

    func testConfoundedNightsAreScoredButNotFolded() {
        let d = days(40)
        let logs = [key(20): LBDayLog(feltIll: true)]
        let with = CyclePhaseEngine.nights(from: d, context: BS.Context(dayLogs: logs)).nights
        let without = CyclePhaseEngine.nights(from: d).nights
        XCTAssertEqual(with[20], without[20], "the confounded night itself is still scored, against the same past")
        XCTAssertNotEqual(with[21].tempZ, without[21].tempZ, "but it never enters the fold")
    }

    func testFlatFusedSeriesNeedsMoreThanARoundingRiseToFlag() {
        XCTAssertEqual(CyclePhaseEngine.fusedSpreadFloor, 0.1 / (1.253 * 0.3), accuracy: 1e-12)
        // 50 flat nights then a 0.05-z rise: with the old 1e-9 floor this was an "onset".
        var nights = (0..<50).map { CyclePhaseEngine.Night(day: key($0), tempZ: 0, rhrZ: nil, hrvZ: nil) }
        nights.append(CyclePhaseEngine.Night(day: key(50), tempZ: 0.05, rhrZ: nil, hrvZ: nil))
        let r = CyclePhaseEngine.classify(nights, baselineUsable: true)
        XCTAssertTrue(r.shiftMarkers.isEmpty, "a 0.05 z wiggle on a flat series is not a temperature shift")
    }
}
