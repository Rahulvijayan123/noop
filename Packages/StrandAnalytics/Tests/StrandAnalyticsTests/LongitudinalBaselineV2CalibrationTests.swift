import XCTest
@testable import StrandAnalytics

/// Operating characteristics of Layer 1 v2.clinical on synthetic nightly series (audit 2026-10-07).
///
/// These are SYNTHETIC checks of the statistics (Gaussian AR(1) nightly noise with the spreads seen on WHOOP
/// nightly series). They calibrate and pin the false-flag / detection behaviour; they are not clinical
/// validation. Printed tables are copied into docs/BASELINE_WATCHDOG_V2.md §Results.
final class LongitudinalBaselineV2CalibrationTests: XCTestCase {

    struct RNG {
        var s: UInt64
        mutating func u() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double((s >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
        mutating func n() -> Double {
            let a = max(u(), 1e-12), b = u()
            return (-2 * log(a)).squareRoot() * cos(2 * .pi * b)
        }
    }

    static let t0 = LongitudinalBaseline.isoEpochDay("2025-01-01")!
    static func iso(_ i: Int) -> String { LongitudinalBaseline.isoFromEpochDay(t0 + i) }

    struct SeriesModel {
        var series: LBSeries
        var mean: Double     // math space (ln for HRV)
        var sd: Double       // marginal SD in math space
    }

    static let models: [SeriesModel] = [
        SeriesModel(series: .sleepRHR, mean: 55, sd: 2.5),
        SeriesModel(series: .sleepHRVLn, mean: 4.0, sd: 0.15),
        SeriesModel(series: .sleepTemp, mean: 33.8, sd: 0.30),
        SeriesModel(series: .sleepResp, mean: 14.5, sd: 0.55),
    ]

    /// AR(1) Gaussian tape in math space with `missingRate` random missing nights and an additive `shift(day)`.
    static func tape(_ m: SeriesModel, days: Int, seed: UInt64, phi: Double, missingRate: Double = 0.08,
                     shift: (Int) -> Double = { _ in 0 }) -> [LBDailyObservation] {
        var r = RNG(s: seed &* 2654435761 &+ 97)
        var e = r.n() * m.sd
        let innov = m.sd * (1 - phi * phi).squareRoot()
        var out: [LBDailyObservation] = []
        for i in 0..<days {
            e = phi * e + innov * r.n()
            if r.u() < missingRate { continue }
            let x = m.mean + e + shift(i)
            let native = m.series.usesLog ? exp(x) : x
            out.append(LBDailyObservation(day: iso(i), value: native, qualityStatus: .ok))
        }
        return out
    }

    struct NullStats {
        var eligible = 0, off = 0, twoOfThree = 0, episodes = 0, seriesDays = 0
        var fullDays = 0, driftSig = 0, trend28Sig = 0, trend90Sig = 0
    }

    func nullRun(_ m: SeriesModel, phi: Double, seeds: Int, days: Int) -> NullStats {
        var st = NullStats()
        let full = Set(stride(from: 120, to: days, by: 7).map(Self.iso))
        for seed in 1...seeds {
            let obs = Self.tape(m, days: days, seed: UInt64(seed * 7919) ^ UInt64(phi * 1000), phi: phi)
            let evs = LongitudinalBaseline.replayDaily(series: m.series, observations: obs,
                                                       through: Self.iso(days - 1), fullDays: full)
            var wasOpen = false
            for ev in evs {
                guard let d = LongitudinalBaseline.isoEpochDay(ev.asOf), d - Self.t0 >= 60 else { continue }
                st.seriesDays += 1
                if ev.change.open && !wasOpen { st.episodes += 1 }
                wasOpen = ev.change.open
                guard ev.alertEligible, let p = ev.pLong else { continue }
                st.eligible += 1
                if p < LongitudinalBaseline.V2.bandAlpha { st.off += 1 }
                if ev.twoOfThree { st.twoOfThree += 1 }
                if full.contains(ev.asOf) {
                    st.fullDays += 1
                    if ev.drift?.significant == true { st.driftSig += 1 }
                    if ev.trend28?.significant == true { st.trend28Sig += 1 }
                    if ev.trend90?.significant == true { st.trend90Sig += 1 }
                }
            }
        }
        return st
    }

    func testNullOperatingCharacteristics() {
        var lines = ["series            phi   daily_off  2of3   episodes/yr  drift_sig  trend28  trend90  (n_days)"]
        for m in Self.models {
            for phi in [0.0, 0.3, 0.5] {
                let st = nullRun(m, phi: phi, seeds: 6, days: 420)
                let off = Double(st.off) / Double(max(st.eligible, 1))
                let two = Double(st.twoOfThree) / Double(max(st.eligible, 1))
                let epYr = Double(st.episodes) / (Double(st.seriesDays) / 365)
                let drift = Double(st.driftSig) / Double(max(st.fullDays, 1))
                let t28 = Double(st.trend28Sig) / Double(max(st.fullDays, 1))
                let t90 = Double(st.trend90Sig) / Double(max(st.fullDays, 1))
                lines.append(String(format: "%-16@  %.1f   %.3f      %.3f  %.2f         %.3f      %.3f    %.3f    (%d)",
                                    m.series.rawValue as NSString, phi, off, two, epYr, drift, t28, t90, st.eligible))
                // Nominal 5 % two-sided per series-day. Predictive t bands + AR(1) n_eff + OOS factor keep the
                // realised rate near nominal (v1: 8.5–10.5 %).
                XCTAssertLessThan(off, phi >= 0.5 ? 0.075 : 0.065, "\(m.series) φ=\(phi) daily off-rate \(off)")
                XCTAssertGreaterThan(off, 0.015, "\(m.series) φ=\(phi) band too conservative \(off)")
                XCTAssertLessThan(epYr, 2.0, "\(m.series) φ=\(phi) false change episodes per year \(epYr)")
                XCTAssertLessThan(drift, 0.02, "\(m.series) φ=\(phi) false drift \(drift)")
                XCTAssertLessThan(t28, 0.05, "\(m.series) φ=\(phi) false 28-day trend \(t28)")
                XCTAssertLessThan(t90, 0.05, "\(m.series) φ=\(phi) false 90-day trend \(t90)")
            }
        }
        print("LAYER1-V2-NULL\n" + lines.joined(separator: "\n"))
    }

    func testStepShiftDetectionAndNoSilentAbsorption() {
        var lines = ["series            shift_sd  alarm_delay_med  detected  flagged_28d  drift_visible_at_+60"]
        for m in Self.models {
            for k in [1.0, 1.5, 2.0] {
                var delays: [Int] = []
                var detected = 0, flagged = 0, flaggedDen = 0, driftVisible = 0
                let seeds = 8
                for seed in 1...seeds {
                    let shiftDay = 200
                    let obs = Self.tape(m, days: 300, seed: UInt64(seed * 104729), phi: 0.3,
                                        shift: { $0 >= shiftDay ? k * m.sd : 0 })
                    let probe = Self.iso(shiftDay + 60)
                    let evs = LongitudinalBaseline.replayDaily(series: m.series, observations: obs,
                                                               through: Self.iso(299), fullDays: [probe])
                    var first: Int?
                    for ev in evs {
                        guard let d = LongitudinalBaseline.isoEpochDay(ev.asOf) else { continue }
                        let i = d - Self.t0
                        guard i >= shiftDay else { continue }
                        if first == nil, ev.change.open, ev.change.direction == 1 { first = i - shiftDay }
                        if i < shiftDay + 28, let p = ev.pLong { flaggedDen += 1; if p < 0.05 { flagged += 1 } }
                        if ev.asOf == probe, ev.drift?.significant == true || ev.change.open { driftVisible += 1 }
                    }
                    if let f = first, f <= 45 { detected += 1; delays.append(f) }
                }
                let med = PhysiologyContext.RobustStats.median(delays.map(Double.init)) ?? .nan
                lines.append(String(format: "%-16@  %.1f       %5.1f            %d/%d       %.2f         %d/%d",
                                    m.series.rawValue as NSString, k, med, detected, seeds,
                                    Double(flagged) / Double(max(flaggedDen, 1)), driftVisible, seeds))
                if k >= 2.0 {
                    XCTAssertGreaterThanOrEqual(detected, seeds - 1, "\(m.series) 2 SD step must open an episode")
                    XCTAssertLessThanOrEqual(med, 10, "\(m.series) 2 SD step alarm delay")
                }
                if k >= 2.0 {
                    XCTAssertGreaterThanOrEqual(driftVisible, seeds - 2,
                                                "\(m.series) \(k) SD step must stay visible 60 days later")
                } else if k >= 1.5 {
                    XCTAssertGreaterThanOrEqual(driftVisible, seeds / 2,
                                                "\(m.series) \(k) SD step must stay visible 60 days later")
                }
            }
        }
        print("LAYER1-V2-STEP\n" + lines.joined(separator: "\n"))
    }

    func testSlowRampIsReportedNotAbsorbed() {
        var lines = ["series            sd_per_week  trend_sig_delay_med  drift_sig_delay_med  detected(drift or trend)"]
        for m in Self.models {
            for perWeek in [0.25, 0.5] {
                var trendDelays: [Int] = [], driftDelays: [Int] = []
                var detected = 0
                let seeds = 6
                for seed in 1...seeds {
                    let start = 150
                    let obs = Self.tape(m, days: 330, seed: UInt64(seed * 15485863), phi: 0.3,
                                        shift: { $0 < start ? 0 : min(4.5, perWeek * Double($0 - start) / 7) * m.sd })
                    let probes = Set(stride(from: start, to: 330, by: 3).map(Self.iso))
                    let evs = LongitudinalBaseline.replayDaily(series: m.series, observations: obs,
                                                               through: Self.iso(329), fullDays: probes)
                    var ft: Int?, fd: Int?
                    for ev in evs where probes.contains(ev.asOf) {
                        guard let d = LongitudinalBaseline.isoEpochDay(ev.asOf) else { continue }
                        let i = d - Self.t0
                        if ft == nil, (ev.trend28?.significant == true && ev.trend28?.direction == 1)
                            || (ev.trend90?.significant == true && ev.trend90?.direction == 1) { ft = i - start }
                        if fd == nil, ev.drift?.significant == true, ev.drift?.direction == 1 { fd = i - start }
                    }
                    if let ft { trendDelays.append(ft) }
                    if let fd { driftDelays.append(fd) }
                    if ft != nil || fd != nil { detected += 1 }
                }
                let mt = PhysiologyContext.RobustStats.median(trendDelays.map(Double.init)) ?? .nan
                let md = PhysiologyContext.RobustStats.median(driftDelays.map(Double.init)) ?? .nan
                lines.append(String(format: "%-16@  %.2f         %5.1f                %5.1f                %d/%d",
                                    m.series.rawValue as NSString, perWeek, mt, md, detected, seeds))
                XCTAssertGreaterThanOrEqual(detected, seeds - 1, "\(m.series) ramp \(perWeek) SD/week must be reported")
            }
        }
        print("LAYER1-V2-RAMP\n" + lines.joined(separator: "\n"))
    }

    func testReplayDailyMatchesEvaluate() {
        let m = Self.models[0]
        let obs = Self.tape(m, days: 160, seed: 11, phi: 0.3)
        let t = Self.iso(159)
        let evs = LongitudinalBaseline.replayDaily(series: m.series, observations: obs, through: t)
        let one = LongitudinalBaseline.evaluate(asOf: t, series: m.series, observations: obs)
        XCTAssertEqual(evs.last?.asOf, t)
        XCTAssertEqual(evs.last?.zLong ?? .nan, one.zLong ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(evs.last?.pLong ?? .nan, one.pLong ?? .nan, accuracy: 1e-12)
        XCTAssertEqual(evs.last?.change, one.change)
        XCTAssertEqual(evs.last?.anchor, one.anchor)
    }

    func testIllnessFreezeExpiresAfterRecovery() {
        var logs: [String: LBDayLog] = [:]
        for i in 100...104 { logs[Self.iso(i)] = LBDayLog(feltIll: true) }
        XCTAssertTrue(LongitudinalBaseline.illnessFreezeActive(onset: Self.iso(100), dayLogs: logs, asOf: Self.iso(110)))
        XCTAssertTrue(LongitudinalBaseline.illnessFreezeActive(onset: Self.iso(100), dayLogs: logs, asOf: Self.iso(118)))
        XCTAssertFalse(LongitudinalBaseline.illnessFreezeActive(onset: Self.iso(100), dayLogs: logs, asOf: Self.iso(119)))
    }
}
