import XCTest
import WhoopStore
@testable import StrandAnalytics

/// BaselineStandard fix K: ONE synthetic 120-night history, fed through every feature baseline entry point the
/// consistency pass touched, and checked against each rule of the standard.
///
/// The tape carries every hazard the 2026-10-07 audit found the features mishandling:
///   • an SDNN night (an Apple Watch reading on the shared `avgHrv` column, tagged in `Context.sdnnDays`),
///   • an imported ABSOLUTE skin-temperature row on the deviation column,
///   • three logged confounder nights (alcohol),
///   • a device-family change (WHOOP 4.0 → 5.0) with a different HRV scale after it,
///   • a missing week.
///
/// Entry points: `ChargeBaselines.asOf` (phone Charge), `RecoveryScorer` (server Charge gate),
/// `IllnessBaselines.evaluate`, `CyclePhaseEngine.nights(from:context:)`, `DailyStressBaseline`,
/// `ReadinessEngine.evaluate`, `HRVReadiness.evaluate`, `PersonalUsual` (Today insight, Coach),
/// `VitalBands.band(logScale:)` and the `DaytimeStress` day-relative floors.
final class BaselineStandardConsistencyTests: XCTestCase {

    typealias BS = BaselineStandard

    static let count = 120
    static let sdnnNight = 70
    static let absoluteSkinNight = 80
    static let confounded: Set<Int> = [30, 45, 90]
    static let eraChange = 60
    static let missingWeek = 100..<107

    static func key(_ i: Int) -> String { BS.dayKey(BS.epochDay("2026-01-05")! + i) }

    /// The tape, optionally truncated (`upTo` nights) or with some nights emptied (`dropping`).
    static func tape(upTo n: Int = count, dropping: Set<Int> = []) -> [DailyMetric] {
        var s: UInt64 = 20_261_007
        func uniform() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
        func gauss() -> Double {
            (-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * .pi * uniform())
        }
        var out: [DailyMetric] = []
        for i in 0..<count {
            // Draw every night's noise even when it is dropped, so all variants share the same values.
            let gH = gauss(), gR = gauss(), gP = gauss(), gS = gauss(), gA = gauss()
            guard i < n else { break }
            let empty = missingWeek.contains(i) || dropping.contains(i)
            let whoop5 = i >= eraChange
            let conf = confounded.contains(i)
            var hrv = 55 * exp(0.10 * gH) * (whoop5 ? 1.15 : 1) * (conf ? 0.8 : 1)
            if i == sdnnNight { hrv = 160 }                      // SDNN, not RMSSD
            let rhr = Int((54 + 1.5 * gR + (conf ? 3 : 0)).rounded())
            let resp = 15.2 + 0.3 * gP
            let skinDev = i == absoluteSkinNight ? 33.5 : 0.12 * gS   // imported absolute °C on night 80
            let skinAbs = 33.6 + 0.2 * gA + (whoop5 ? 0.4 : 0)
            out.append(DailyMetric(day: key(i), totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                                   lightMin: nil, disturbances: nil, restingHr: empty ? nil : rhr,
                                   avgHrv: empty ? nil : hrv, recovery: nil, strain: nil, exerciseCount: nil,
                                   skinTempDevC: empty ? nil : skinDev, respRateBpm: empty ? nil : resp,
                                   skinTempC: empty ? nil : skinAbs))
        }
        return out
    }

    static func context(confounded c: Set<Int> = confounded, sdnn: Bool = true) -> BS.Context {
        var regimes: [String: String] = [:]
        for i in 0..<count { regimes[key(i)] = i < eraChange ? "whoop4" : "whoop5" }
        return BS.Context(dayLogs: Dictionary(uniqueKeysWithValues: c.map { (key($0), LBDayLog(alcohol: true)) }),
                          sdnnDays: sdnn ? [key(sdnnNight)] : [], regimeByDay: regimes)
    }

    // MARK: - Every feature's output for one day

    /// A snapshot of every feature's reading for `day`, built from `days` under `ctx`. Equatable so "the same
    /// past" can be asserted across all features at once.
    struct Snapshot: Equatable {
        var chargeHRV: BaselineState?
        var chargeRHR: BaselineState?
        var chargeResp: BaselineState?
        var chargeSkin: BaselineState?
        var cycle: CyclePhaseEngine.Night?
        var stress: DailyStressBaseline.DayScore?
        var stressRef: DailyStressBaseline.Reference
        var usualHRV: BS.Reference
        var usualRHR: BS.Reference
        var usualSkin: BS.Reference
        var illness: IllnessBaselines.Result
        var readiness: ReadinessEngine.Readiness
    }

    /// Every entry point gets the WHOLE `days` it is handed (later nights included), so a feature that looked
    /// ahead would show up as a difference between a short and a long tape.
    static func snapshot(_ days: [DailyMetric], _ day: String, _ ctx: BS.Context) -> Snapshot {
        func m(_ pick: (DailyMetric) -> Double?) -> [String: Double] { BS.series(days, day: \.day, value: pick) }
        let charge = ChargeBaselines.asOf(ChargeBaselines.Inputs(
            hrvMerged: m(\.avgHrv), rhrMerged: m { $0.restingHr.map(Double.init) }, respMerged: m(\.respRateBpm),
            skinAbsolute: m(\.skinTempC), context: ctx)).baselines(for: day)
        return Snapshot(
            chargeHRV: charge.hrv, chargeRHR: charge.restingHR, chargeResp: charge.resp, chargeSkin: charge.skinTemp,
            cycle: CyclePhaseEngine.nights(from: days, context: ctx).nights.first { $0.day == day },
            stress: DailyStressBaseline.trend(days: days, context: ctx)[day],
            stressRef: DailyStressBaseline.reference(days: days, asOf: day, context: ctx),
            usualHRV: PersonalUsual.usual(days: days, metric: .hrvRmssd, asOf: day, context: ctx),
            usualRHR: PersonalUsual.usual(days: days, metric: .restingHR, asOf: day, context: ctx),
            usualSkin: PersonalUsual.usual(days: days, metric: .skinTempDeviation, asOf: day, context: ctx),
            illness: IllnessBaselines.evaluate(days: days, context: ctx, today: day),
            readiness: ReadinessEngine.evaluate(days: days, today: day, context: ctx))
    }

    // MARK: - Rule 2: no look-ahead

    func testAppendingFutureNightsChangesNoPastReading() {
        let ctx = Self.context()
        let full = Self.tape()
        let short = Self.tape(upTo: 96)
        for i in stride(from: 5, through: 95, by: 5) {
            let d = Self.key(i)
            XCTAssertEqual(Self.snapshot(short, d, ctx), Self.snapshot(full, d, ctx), "day \(i) saw the future")
        }
    }

    // MARK: - Rule 1: ln HRV, SDNN excluded

    func testHRVIsModelledOnLnEverywhere() {
        let ctx = Self.context()
        let days = Self.tape()
        let s = Self.snapshot(days, Self.key(50), ctx)
        // Every HRV reference is centred in ln units (ln 55 ≈ 4.0), never in ms.
        XCTAssertEqual(s.chargeHRV!.baseline, log(55), accuracy: 0.15)
        XCTAssertEqual(s.usualHRV.center, log(55), accuracy: 0.15)
        XCTAssertEqual(s.stressRef.hrv.center, log(55), accuracy: 0.15)
        XCTAssertEqual(s.usualHRV.centerNative, 55, accuracy: 8, "shown in ms via exp")
        // The z of the night itself is the ln z, for every per-night consumer.
        let v = days[50].avgHrv!
        XCTAssertEqual(s.cycle!.hrvZ!, Baselines.deviation(log(v), state: BS.causalFold(
            BS.series(days, day: \.day, value: \.avgHrv), metric: .hrvRmssd, through: Self.key(50), context: ctx)
            .before[Self.key(50)]!).z, accuracy: 1e-12)
        XCTAssertEqual(s.stress!.raw, (s.stressRef.restingHR.z(Double(days[50].restingHr!)) ?? 0)
                       - (s.stressRef.hrv.z(v) ?? 0), accuracy: 1e-12)
        XCTAssertEqual(s.illness.hrv.recent!, exp((log(days[49].avgHrv!) + log(days[50].avgHrv!)) / 2), accuracy: 1e-9,
                       "the recent HRV is a geometric mean")
    }

    func testTheSDNNNightNeverEntersAnRMSSDReferenceAndIsNeverScoredOnOne() {
        let tagged = Self.tape()
        let withoutIt = Self.tape(dropping: [Self.sdnnNight])
        let after = Self.key(Self.sdnnNight + 3)
        let a = Self.snapshot(tagged, after, Self.context())
        let b = Self.snapshot(withoutIt, after, Self.context(sdnn: false))
        XCTAssertEqual(a.chargeHRV, b.chargeHRV)
        XCTAssertEqual(a.usualHRV, b.usualHRV)
        XCTAssertEqual(a.stressRef.hrv, b.stressRef.hrv)
        XCTAssertEqual(a.cycle?.hrvZ, b.cycle?.hrvZ)
        XCTAssertEqual(a.illness.hrv, b.illness.hrv)
        XCTAssertEqual(a.readiness.signals.first { $0.key == "hrv" }, b.readiness.signals.first { $0.key == "hrv" })
        // The SDNN night itself is not compared with RMSSD anywhere.
        let ctx = Self.context()
        let d = Self.key(Self.sdnnNight)
        let s = Self.snapshot(tagged, d, ctx)
        XCTAssertNil(s.cycle!.hrvZ)
        XCTAssertNil(s.stress?.hrvDeltaMs)
        XCTAssertNil(PersonalUsual.hrvDeltaPercent(todayMs: 160, day: d, days: tagged, context: ctx))
        XCTAssertNil(s.readiness.signals.first { $0.key == "hrv" })
    }

    // MARK: - Rule 3: confounded nights out of every fold, still scored

    func testConfoundedNightsAreScoredButNeverFolded() {
        let n = 45
        let logged = Self.tape()
        let emptied = Self.tape(dropping: [n])
        for i in (n + 1)...(n + 4) {
            let d = Self.key(i)
            let a = Self.snapshot(logged, d, Self.context())
            let b = Self.snapshot(emptied, d, Self.context(confounded: Self.confounded.subtracting([n])))
            XCTAssertEqual(a.chargeHRV, b.chargeHRV, "Charge folded the alcohol night")
            XCTAssertEqual(a.chargeRHR, b.chargeRHR)
            XCTAssertEqual(a.usualHRV, b.usualHRV, "PersonalUsual folded it")
            XCTAssertEqual(a.stressRef, b.stressRef, "the stress reference folded it")
            XCTAssertEqual(a.cycle, b.cycle, "the cycle folds folded it")
            XCTAssertEqual(a.readiness, b.readiness, "readiness folded it")
        }
        // ...while the confounded night itself still gets a reading.
        let s = Self.snapshot(logged, Self.key(n), Self.context())
        XCTAssertNotNil(s.cycle?.hrvZ)
        XCTAssertNotNil(s.stress)
        XCTAssertNotNil(PersonalUsual.hrvDeltaPercent(todayMs: logged[n].avgHrv!, day: Self.key(n), days: logged,
                                                      context: Self.context()))
        XCTAssertTrue(s.chargeHRV!.usable)
    }

    // MARK: - Rule 4: no z below four days

    func testNoComparisonBelowFourDays() {
        let ctx = Self.context()
        let days = Self.tape()
        for i in 0..<4 {
            let s = Self.snapshot(days, Self.key(i), ctx)
            XCTAssertFalse(s.chargeHRV?.usable ?? false, "Charge on night \(i)")
            XCTAssertNil(s.cycle?.tempZ); XCTAssertNil(s.cycle?.hrvZ); XCTAssertNil(s.cycle?.rhrZ)
            XCTAssertNil(s.stress, "stress on night \(i)")
            XCTAssertFalse(s.usualHRV.usable)
            XCTAssertNil(s.illness.restingHR.zIllnessward)
            XCTAssertNil(s.illness.hrv.zIllnessward)
            XCTAssertEqual(s.readiness.signals.filter { ["hrv", "rhr", "respRate"].contains($0.key) }, [])
        }
        XCTAssertTrue(Self.snapshot(days, Self.key(4), ctx).chargeHRV!.usable)
        XCTAssertNil(HRVReadiness.evaluate(avgHrv: days.prefix(13).map(\.avgHrv)), "HRV readiness needs 14")
    }

    // MARK: - Rule 5: floors

    func testEveryScaleRespectsTheSharedFloors() {
        let ctx = Self.context()
        let days = Self.tape()
        for i in stride(from: 10, through: 119, by: 7) {
            let s = Self.snapshot(days, Self.key(i), ctx)
            if let h = s.chargeHRV, h.nValid > 0 {
                XCTAssertGreaterThanOrEqual(Baselines.sigma(h), BS.scaleFloor(.hrvRmssd))
            }
            if let r = s.chargeRHR, r.nValid > 0 {
                XCTAssertGreaterThanOrEqual(Baselines.sigma(r), BS.scaleFloor(.restingHR))
            }
            if let p = s.chargeResp { XCTAssertGreaterThanOrEqual(Baselines.sigma(p), BS.scaleFloor(.respiration)) }
            if let k = s.chargeSkin { XCTAssertGreaterThanOrEqual(Baselines.sigma(k), BS.scaleFloor(.skinTempAbsolute)) }
            for ref in [s.usualHRV, s.usualRHR, s.usualSkin, s.stressRef.hrv, s.stressRef.restingHR] where ref.n > 0 {
                XCTAssertGreaterThanOrEqual(ref.scale, BS.scaleFloor(ref.metric), "\(ref.metric) on day \(i)")
            }
        }
        // And the features with their own floors keep them at or above the standard ones.
        XCTAssertGreaterThanOrEqual(HRVReadiness.longSDFloor, BS.scaleFloor(.hrvRmssd))
        XCTAssertGreaterThanOrEqual(DaytimeStress.dayRelativeHRSDFloor, BS.scaleFloor(.restingHR))
        XCTAssertGreaterThanOrEqual(CyclePhaseEngine.fusedSpreadFloor, 0.1 / (1.253 * 0.3) - 1e-12)
        for m in BS.Metric.allCases {
            XCTAssertGreaterThanOrEqual(BS.impliedSigmaFloor(BS.cfg(m)), BS.scaleFloor(m))
        }
    }

    // MARK: - Rule 6: a device-family change resets every fold

    func testTheDeviceEraChangeResetsEveryReference() {
        let ctx = Self.context()
        let days = Self.tape()
        let first5 = Self.snapshot(days, Self.key(Self.eraChange), ctx)
        XCTAssertEqual(first5.chargeHRV?.nValid, 0, "Charge must not judge a 5.0 night on 4.0 nights")
        XCTAssertEqual(first5.chargeSkin, nil)
        XCTAssertEqual(first5.usualHRV.n, 0)
        XCTAssertEqual(first5.stressRef.hrv.n, 0)
        XCTAssertNil(first5.cycle?.hrvZ)
        XCTAssertNil(first5.readiness.signals.first { $0.key == "hrv" })
        let illness = Self.snapshot(days, Self.key(Self.eraChange + 1), ctx).illness
        XCTAssertFalse(illness.hrv.usable, "the illness base (all 4.0 nights) must not judge the 5.0 nights")
        // Four 5.0 nights later every reference is back, built from 5.0 nights only.
        let back = Self.snapshot(days, Self.key(Self.eraChange + 4), ctx)
        XCTAssertTrue(back.chargeHRV!.usable)
        XCTAssertEqual(back.usualHRV.n, 4)
        XCTAssertEqual(back.usualHRV.centerNative, 55 * 1.15, accuracy: 10)
    }

    // MARK: - The skin column's absolute imported row

    func testTheImportedAbsoluteSkinRowIsNeverADeviation() {
        let ctx = Self.context()
        let days = Self.tape()
        let d = Self.key(Self.absoluteSkinNight)
        XCTAssertNil(Self.snapshot(days, d, ctx).cycle?.tempZ)
        let after = Self.snapshot(days, Self.key(Self.absoluteSkinNight + 2), ctx)
        XCTAssertLessThan(abs(after.usualSkin.centerNative), 0.5, "33.5 °C never entered the deviation usual")
        let illness = Self.snapshot(days, Self.key(Self.absoluteSkinNight + 1), ctx).illness
        XCTAssertLessThan(abs(illness.skinTemp.zIllnessward ?? 0), 4, "was z ≈ 110 on an absolute row")
    }

    // MARK: - Rule 7: calendar days, the missing week is missing

    func testTheMissingWeekIsMissingNotSkipped() {
        let ctx = Self.context()
        let days = Self.tape()
        let s = Self.snapshot(days, Self.key(107), ctx)
        // 28 calendar days 79…106: 7 missing, 1 confounded (90) → 20, never reaching back past day 79.
        XCTAssertEqual(s.usualHRV.n, 20)
        XCTAssertEqual(s.usualHRV.fromDay, Self.key(79))
        // 30 calendar days 77…106 for the stress reference: 7 missing, 1 confounded → 22.
        XCTAssertEqual(s.stressRef.hrv.n, 22)
        // The EWMA folds see the gap as seven missing nights.
        XCTAssertEqual(s.chargeHRV?.nightsSinceUpdate, 7)
        // The illness base (days 77…104; guard 105; recent 106/107) holds 28 − 5 missing − 1 confounded.
        XCTAssertEqual(s.illness.restingHR.n, 22)
    }

    // MARK: - Server Charge and the vital tiles on the same tape

    func testServerChargeGateAndVitalTilesFollowTheStandard() {
        let days = Self.tape()
        let hrv = Baselines.foldHistory(days.prefix(50).map(\.avgHrv), cfg: Baselines.hrvCfg)
        let rhr = Baselines.foldHistory(days.prefix(50).map { $0.restingHr.map(Double.init) },
                                        cfg: Baselines.restingHRCfg)
        let seedResp = Baselines.foldHistory([], cfg: Baselines.respCfg)
        let n = days[50]
        XCTAssertEqual(
            RecoveryScorer.recovery(hrv: n.avgHrv!, rhr: Double(n.restingHr!), resp: n.respRateBpm, hrvBaseline: hrv,
                                    rhrBaseline: rhr, respBaseline: seedResp, sleepPerf: 0.85)!,
            RecoveryScorer.recovery(hrv: n.avgHrv!, rhr: Double(n.restingHr!), resp: n.respRateBpm, hrvBaseline: hrv,
                                    rhrBaseline: rhr, respBaseline: nil, sleepPerf: 0.85)!, accuracy: 1e-12,
            "an n = 0 respiration seed never scores")
        // The HRV vital tile bands on ln (the same value banded in ms and in ln differs only through the scale).
        let history = days.prefix(50).map(\.avgHrv)
        let lnBand = VitalBands.band(value: 55, history: Array(history), populationRange: 40...120,
                                     cfg: Baselines.readinessHRVLnCfg, logScale: true)
        XCTAssertEqual(lnBand.basis, .personal)
        XCTAssertEqual(lnBand.band, .inRange)
    }
}
