import Foundation

// Review v1: per-series params, TRUST / HOW OFF, slow slope, stable FPR.
// Spec: Packages/StrandAnalytics/Baseline/FRWHOOP_BASELINE_REVIEW_CHANGES.md

public enum LBWorseDirection: String, Equatable, Sendable {
    case higher
    case lower
    case either
}

public enum LBOffCopy: String, Equatable, Sendable {
    case longer
    case thisWeek
}

/// When that biometric is most stable. k is estimated from residuals in this window, not a global 2.
public enum LBStableWindow: String, Equatable, Sendable {
    case overnightSleep = "overnight_sleep"
    case stillWaking = "still_waking"
    case movingWaking = "moving_waking"
    case allHours = "all_hours"
    case wakingLoad = "waking_load"

    public var caption: String {
        switch self {
        case .overnightSleep: return "Most stable overnight (sleep)"
        case .stillWaking: return "Most stable while still and awake"
        case .movingWaking: return "Most stable while moving"
        case .allHours: return "Uses the all-day mean (no quieter window)"
        case .wakingLoad: return "Most stable across waking hours"
        }
    }
}

/// Knobs that may differ by biometric. Changing a row bumps `param_set`.
public struct LBSeriesParams: Equatable, Sendable {
    public var kBand: Double
    public var span7: Int
    public var alpha: Double
    public var nLongEstablished: Int
    public var floor: Double
    public var worse: LBWorseDirection
    public var primaryOff: LBOffCopy
    public var spo2EstablishExtraNights: Int

    public init(kBand: Double, span7: Int, nLongEstablished: Int, floor: Double,
                worse: LBWorseDirection, primaryOff: LBOffCopy = .longer,
                spo2EstablishExtraNights: Int = 0) {
        self.kBand = kBand
        self.span7 = span7
        self.alpha = 2.0 / (Double(span7) + 1.0)
        self.nLongEstablished = nLongEstablished
        self.floor = floor
        self.worse = worse
        self.primaryOff = primaryOff
        self.spo2EstablishExtraNights = spo2EstablishExtraNights
    }
}

public struct LBStableFPRRow: Equatable, Sendable {
    public var series: LBSeries
    public var nStableDays: Int
    public var offLonger: Int
    public var offThisWeek: Int
    public var twoOfThree: Int
    public var aboveMdc: Int
    public var realWhoopRun: Bool

    public var rateLonger: Double {
        nStableDays == 0 ? 0 : Double(offLonger) / Double(nStableDays)
    }
}

public struct LBTrustInputs: Equatable, Sendable {
    public var nOk: Int
    public var nWindow: Int
    public var nLowQuality: Int
    public var nEff: Double
    public var nEstablish: Int
    public var ageLastOk: Int?
    public var staleDays: Int
    public var slopeUsable: Bool
    public var freezeOk: Double
    public var confoundToday: Bool
    public var tonightStatus: LBQualityStatus?
}

extension LongitudinalBaseline {

    public static let reviewDisclaimer =
        "This is the difference from what this series was doing before the start, including any slow trend. Sleep, activity, illness, diet, another medication, or the disease itself can move the same number. It is not proof the treatment caused the change."

    public static let slopeHorizonDays = 30
    public static let trustHideThreshold = 35

    /// Table k is the prior. Live k is the 95th percentile of |residual|/spread on **unconfounded**
    /// nights only, once that clean copy is established. Clamped so one wild week cannot explode the band.
    public static func kBandFromStableWindow(tableK: Double, absResidualZ: [Double], nLong: Int) -> Double {
        guard nLong >= 14, absResidualZ.count >= 14 else { return tableK }
        let s = absResidualZ.filter(\.isFinite).sorted()
        guard s.count >= 14 else { return tableK }
        let idx = min(s.count - 1, max(0, Int((Double(s.count) - 1) * 0.95)))
        let empirical = s[idx]
        let lo = tableK * 0.75
        let hi = tableK * 1.40
        return min(max(empirical, lo), hi)
    }

    /// No daily log, or a log with no usual-confounders, may train the rails.
    public static func nightIsClean(_ epoch: Int, dayLogs: [String: LBDayLog]) -> Bool {
        let d = isoFromEpochDay(epoch)
        guard let log = dayLogs[d] else { return true }
        return !log.confoundsUsual
    }

    /// Among real DailyMetric columns in one family, the series whose clean `k_used` is smallest.
    /// Fake rest/active stand-ins (`hasDailyMetricColumn == false`) are ignored.
    public static func quietestRealColumn(asOf: String,
                                          tapes: [(LBSeries, [LBDailyObservation])],
                                          dayLogs: [String: LBDayLog] = [:]) -> LBSeries? {
        var best: (LBSeries, Double)?
        let family = tapes.first(where: { $0.0.hasDailyMetricColumn })?.0.biometricFamily
        for (series, obs) in tapes {
            guard series.hasDailyMetricColumn else { continue }
            if let family, series.biometricFamily != family { continue }
            let ev = evaluate(asOf: asOf, series: series, observations: obs,
                              trial: LBTrialRequest(dayLogsByDay: dayLogs))
            let need = params(for: series).nLongEstablished
            guard ev.nLong >= need else { continue }
            if best == nil || ev.kBandUsed < best!.1 {
                best = (series, ev.kBandUsed)
            }
        }
        return best?.0
    }

    public static func stableWindow(for series: LBSeries) -> LBStableWindow {
        switch series {
        case .sleepRHR, .sleepHRVLn, .sleepResp, .sleepTemp, .sleepSpO2Mean, .sleepSpO2Nadir:
            return .overnightSleep
        case .awakeRestHR, .awakeRestHRVLn, .awakeRestSpO2Mean:
            return .stillWaking
        case .awakeActiveHR, .awakeActiveHRVLn, .awakeActiveSpO2Mean:
            return .movingWaking
        case .continuousHR, .continuousHRVLn, .continuousSpO2Mean:
            return .allHours
        case .wakingSteps, .wakingActiveMin, .wakingImuEnergy:
            return .wakingLoad
        }
    }

    public static func params(for series: LBSeries) -> LBSeriesParams {
        switch series {
        case .sleepRHR:
            return LBSeriesParams(kBand: 2.0, span7: 7, nLongEstablished: 14, floor: 2,
                                  worse: .higher)
        case .awakeRestHR:
            return LBSeriesParams(kBand: 2.0, span7: 7, nLongEstablished: 14, floor: 3,
                                  worse: .higher)
        case .awakeActiveHR:
            return LBSeriesParams(kBand: 2.2, span7: 7, nLongEstablished: 14, floor: 4,
                                  worse: .higher)
        case .continuousHR:
            return LBSeriesParams(kBand: 2.2, span7: 7, nLongEstablished: 14, floor: 5,
                                  worse: .higher)
        case .sleepHRVLn, .awakeRestHRVLn:
            return LBSeriesParams(kBand: 2.6, span7: 10, nLongEstablished: 14, floor: 0.08,
                                  worse: .lower)
        case .awakeActiveHRVLn, .continuousHRVLn:
            return LBSeriesParams(kBand: 2.6, span7: 10, nLongEstablished: 14, floor: 0.08,
                                  worse: .lower)
        case .sleepResp:
            return LBSeriesParams(kBand: 1.6, span7: 7, nLongEstablished: 14, floor: 0.5,
                                  worse: .higher)
        case .sleepTemp:
            return LBSeriesParams(kBand: 2.0, span7: 7, nLongEstablished: 14, floor: 0.3,
                                  worse: .either)
        case .sleepSpO2Mean, .awakeRestSpO2Mean, .awakeActiveSpO2Mean, .continuousSpO2Mean:
            return LBSeriesParams(kBand: 1.5, span7: 7, nLongEstablished: 14, floor: 0.5,
                                  worse: .lower, spo2EstablishExtraNights: 10)
        case .sleepSpO2Nadir:
            return LBSeriesParams(kBand: 1.7, span7: 7, nLongEstablished: 14, floor: 0.5,
                                  worse: .lower, spo2EstablishExtraNights: 10)
        case .wakingSteps:
            return LBSeriesParams(kBand: 2.4, span7: 7, nLongEstablished: 21, floor: 500,
                                  worse: .either, primaryOff: .thisWeek)
        case .wakingActiveMin:
            return LBSeriesParams(kBand: 2.4, span7: 7, nLongEstablished: 21, floor: 10,
                                  worse: .either, primaryOff: .thisWeek)
        case .wakingImuEnergy:
            return LBSeriesParams(kBand: 2.4, span7: 7, nLongEstablished: 21, floor: 0.02,
                                  worse: .either, primaryOff: .thisWeek)
        }
    }

    public static func rawEwmaWeight(age: Int, alpha: Double) -> Double {
        alpha * pow(1.0 - alpha, Double(age))
    }

    public static func slopeIsUsable(slope: Double, spread: Double, n: Int,
                                     residualSpread: Double, established: Bool) -> Bool {
        guard established, n >= 8, spread > 0, slope.isFinite else { return false }
        guard abs(slope) * Double(Params.lookbackLong) > 0.35 * spread else { return false }
        return residualSpread < 3.0 * spread
    }

    public static func expectedOnPath(center: Double, slope: Double, usable: Bool,
                                      day: Int, origin: Int, lastNight: Int) -> Double {
        guard usable else { return center }
        let raw = day - origin
        let cappedFromLast = min(day, lastNight + slopeHorizonDays) - origin
        let dt = Double(min(max(raw, -slopeHorizonDays), slopeHorizonDays))
        let capDt = Double(min(max(cappedFromLast, -slopeHorizonDays), slopeHorizonDays))
        if day - lastNight > slopeHorizonDays { return center + slope * capDt }
        return center + slope * dt
    }

    public static func expectedUntreated(level0: Double, slopeG0: Double, usable: Bool,
                                         asOfEpoch: Int, freezeEpoch: Int) -> Double {
        expectedOnPath(center: level0, slope: slopeG0, usable: usable,
                       day: asOfEpoch, origin: freezeEpoch, lastNight: freezeEpoch)
    }

    public static func usualTrustPct(_ input: LBTrustInputs) -> Int {
        let coverage = Double(input.nOk) / Double(max(input.nWindow, 1))
        let freshness: Double
        if let age = input.ageLastOk {
            freshness = max(0, 1 - Double(age) / Double(max(input.staleDays, 1)))
        } else {
            freshness = 0
        }
        let quality = qualityFrac(nOk: input.nOk, nLowQuality: input.nLowQuality)
        let nEffFrac = min(input.nEff / Double(max(input.nEstablish, 1)), 1)
        let slopeOk = input.slopeUsable ? 1.0 : 0.75
        let confound = input.confoundToday ? 0.5 : 1.0
        let tonight: Double
        switch input.tonightStatus {
        case .ok: tonight = 1
        case .lowQuality: tonight = 0.25
        case .missing, nil: tonight = 0
        }
        let dataQ = coverage * freshness * quality * nEffFrac * slopeOk * input.freezeOk * confound
        return clipPct(100.0 * dataQ * (0.5 + 0.5 * tonight))
    }

    /// High when |z| is extreme. Complementary Student-t two-tail p-value, 0–100.
    public static func howUnusualPct(z: Double?, nEff: Double) -> Int? {
        guard let z, z.isFinite else { return nil }
        let df = max(nEff - 1, 3)
        let p = studentTTwoTailP(abs(z), df: df)
        return clipPct(100.0 * (1.0 - p))
    }

    public static func studentTTwoTailP(_ tAbs: Double, df: Double) -> Double {
        let t = max(tAbs, 0)
        let x = df / (df + t * t)
        let ib = regularizedIncompleteBeta(x: x, a: df / 2.0, b: 0.5)
        return min(1, max(0, ib))
    }

    /// Regularized incomplete beta I_x(a,b) via continued fraction (small x).
    public static func regularizedIncompleteBeta(x: Double, a: Double, b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let lnBeta = lgamma(a) + lgamma(b) - lgamma(a + b)
        let front = exp(a * log(x) + b * log(1 - x) - lnBeta) / a
        let cf = betaContinuedFraction(x: x, a: a, b: b)
        if x < (a + 1) / (a + b + 2) {
            return min(1, max(0, front * cf))
        }
        let front2 = exp(b * log(1 - x) + a * log(x) - lnBeta) / b
        let cf2 = betaContinuedFraction(x: 1 - x, a: b, b: a)
        return min(1, max(0, 1 - front2 * cf2))
    }

    static func betaContinuedFraction(x: Double, a: Double, b: Double) -> Double {
        let maxIter = 200
        let eps = 1e-12
        let qab = a + b
        let qap = a + 1
        let qam = a - 1
        var c = 1.0
        var d = 1.0 - qab * x / qap
        if abs(d) < 1e-30 { d = 1e-30 }
        d = 1 / d
        var h = d
        var m = 1
        while m <= maxIter {
            let m2 = 2 * m
            var aa = Double(m) * (b - Double(m)) * x / ((qam + Double(m2)) * (a + Double(m2)))
            d = 1 + aa * d
            if abs(d) < 1e-30 { d = 1e-30 }
            c = 1 + aa / c
            if abs(c) < 1e-30 { c = 1e-30 }
            d = 1 / d
            h *= d * c
            aa = -(a + Double(m)) * (qab + Double(m)) * x / ((a + Double(m2)) * (qap + Double(m2)))
            d = 1 + aa * d
            if abs(d) < 1e-30 { d = 1e-30 }
            c = 1 + aa / c
            if abs(c) < 1e-30 { c = 1e-30 }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < eps { break }
            m += 1
        }
        return h
    }

    public static func isOffUsual(z: Double?, k: Double) -> Bool {
        guard let z else { return false }
        return abs(z) >= k
    }

    /// Stable-stretch FPR table. `realWhoopRun` stays false until a WHOOP tape is passed in.
    public static func stableFalsePositiveTable(
        tapes: [(series: LBSeries, observations: [LBDailyObservation], asOf: String)],
        realWhoopRun: Bool = false
    ) -> [LBStableFPRRow] {
        tapes.map { tape in
            let p = params(for: tape.series)
            var offL = 0, offW = 0, two = 0, mdc = 0, n = 0
            let ev = evaluate(asOf: tape.asOf, series: tape.series, observations: tape.observations)
            let stable = ev.establishedLong && !ev.stale && ev.pChange < Params.pThr
                && ev.trial.phase == .none && ev.usualTrustPctLong >= trustHideThreshold
            if stable, let tEpoch = isoEpochDay(tape.asOf) {
                for back in 0..<8 {
                    let day = isoFromEpochDay(tEpoch - back)
                    let one = evaluate(asOf: day, series: tape.series,
                                       observations: tape.observations, replay: false)
                    let stretch = one.establishedLong && !one.stale && one.pChange < Params.pThr
                        && one.trial.phase == .none && one.usualTrustPctLong >= trustHideThreshold
                    guard stretch else { continue }
                    n += 1
                    if isOffUsual(z: one.zLong, k: p.kBand) { offL += 1 }
                    if isOffUsual(z: one.z7, k: p.kBand) { offW += 1 }
                    if one.twoOfThree { two += 1 }
                    if one.trial.aboveMdc == true { mdc += 1 }
                }
            }
            return LBStableFPRRow(series: tape.series, nStableDays: n, offLonger: offL,
                                  offThisWeek: offW, twoOfThree: two, aboveMdc: mdc,
                                  realWhoopRun: realWhoopRun)
        }
    }

    public static func printStableFPRTable(_ rows: [LBStableFPRRow]) -> String {
        var lines = ["series                  n    off_long  off_week  2of3  mdc  real"]
        for r in rows {
            let name = r.series.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)
            lines.append("\(name) \(r.nStableDays)  \(r.offLonger)  \(r.offThisWeek)  \(r.twoOfThree)  \(r.aboveMdc)  \(r.realWhoopRun ? "yes" : "not run yet")")
        }
        return lines.joined(separator: "\n")
    }
}
