import Foundation

// LongitudinalBaselineStatistics.swift — shared inferential primitives for Layer 1 v2 (param set `v2.clinical`).
//
// Why this file exists (audit 2026-10-07, branch feat/baseline-watchdog-rebuild-20261007):
//   • v1 compared today against `center ± k·spread` with k fixed (or an IN-SAMPLE 95th percentile). That ignores
//     the uncertainty of the center and of the spread estimated from 4–53 autocorrelated days, so the realised
//     false-flag rate was 8.5–10.5 %/day per series against a nominal ~5 % (simulation, audit §Layer 1).
//   • v1 fitted a Theil–Sen slope with no significance test and moved the comparison center along it, so a noise
//     slope was "usable" on pure noise and a real ramp was absorbed into the reference.
//   • v1's change detector folded |e| (E|Z| ≈ 0.80 > k = 0.5) and was reset whenever the noise slope was "usable",
//     so it never fired.
//
// Everything here reuses `PhysiologyContext.RobustStats` (the server context engine's estimators) so the phone's
// Layer 1 and the server's physiology-context references share one implementation of median / MAD / small-sample
// factor / median standard error / Theil–Sen. Every function is pure and deterministic; non-finite inputs are
// ignored and functions return nil instead of NaN.

extension LongitudinalBaseline {

    public enum Stats {

        typealias RS = PhysiologyContext.RobustStats

        // MARK: Distributions

        /// Standard normal CDF (exact via erfc).
        public static func normalCDF(_ z: Double) -> Double {
            0.5 * erfc(-z / 2.0.squareRoot())
        }

        /// Standard normal quantile (Acklam's rational approximation, |rel err| < 1.15e-9).
        public static func normalQuantile(_ p: Double) -> Double {
            let p = min(max(p, 1e-15), 1 - 1e-15)
            let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                     1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
            let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                     6.680131188771972e+01, -1.328068155288572e+01]
            let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                     -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
            let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                     3.754408661907416e+00]
            let pLow = 0.02425
            if p < pLow {
                let q = (-2 * log(p)).squareRoot()
                return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                    / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
            }
            if p > 1 - pLow {
                let q = (-2 * log(1 - p)).squareRoot()
                return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                    / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
            }
            let q = p - 0.5
            let r = q * q
            return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
                / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        }

        /// Two-sided Student-t p-value P(|T_df| ≥ |t|).
        public static func studentTTwoSidedP(_ t: Double, df: Double) -> Double {
            guard t.isFinite else { return 0 }
            return LongitudinalBaseline.studentTTwoTailP(abs(t), df: max(df, 1))
        }

        /// Two-sided Student-t critical value: the t with P(|T_df| ≥ t) = alpha (bisection, |err| < 1e-6).
        public static func studentTCritical(alpha: Double, df: Double) -> Double {
            let a = min(max(alpha, 1e-12), 0.999)
            let nu = max(df, 1)
            var lo = 0.0, hi = 1.0
            while studentTTwoSidedP(hi, df: nu) > a, hi < 1e6 { hi *= 2 }
            for _ in 0..<80 {
                let mid = (lo + hi) / 2
                if studentTTwoSidedP(mid, df: nu) > a { lo = mid } else { hi = mid }
                if hi - lo < 1e-7 { break }
            }
            return (lo + hi) / 2
        }

        // MARK: Autocorrelation

        /// Lag-1 autocorrelation of a daily residual series, using only calendar-consecutive pairs (a missing day
        /// breaks the pair; missing days are never interpolated). Clamped to [0, maxPhi]. nil below `minPairs`.
        ///
        /// Clamping negative φ̂ to 0 is deliberately conservative: negative autocorrelation would *raise* the
        /// effective sample size and narrow the bands; we never take that credit from a short noisy series.
        public static func lagOnePhi(pairs: [(epoch: Int, value: Double)], center: Double,
                                     minPairs: Int = 10, maxPhi: Double = 0.8) -> Double? {
            let sorted = pairs.sorted { $0.epoch < $1.epoch }
            var x: [Double] = [], y: [Double] = []
            if sorted.count >= 2 {
                for i in 1..<sorted.count where sorted[i].epoch == sorted[i - 1].epoch + 1 {
                    x.append(sorted[i - 1].value - center)
                    y.append(sorted[i].value - center)
                }
            }
            guard x.count >= minPairs else { return nil }
            let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
            var num = 0.0, dx = 0.0, dy = 0.0
            for i in 0..<x.count {
                num += (x[i] - mx) * (y[i] - my)
                dx += (x[i] - mx) * (x[i] - mx)
                dy += (y[i] - my) * (y[i] - my)
            }
            guard dx > 0, dy > 0 else { return 0 }
            // Kendall (1954) small-sample bias of the lag-1 estimate: E[φ̂] ≈ φ − (1 + 3φ)/n. Under-estimating φ
            // under-adjusts the CUSUM and the n_eff, i.e. too many false episodes (null simulation).
            let raw = num / (dx * dy).squareRoot()
            let corrected = raw + (1 + 3 * max(0, raw)) / Double(x.count)
            return min(maxPhi, max(0, corrected))
        }

        /// Effective sample size of n AR(1) values: n(1-φ)/(1+φ), at least 1.
        public static func effectiveN(_ n: Int, phi: Double) -> Double {
            guard n > 0 else { return 0 }
            let p = min(0.95, max(0, phi))
            return max(1, Double(n) * (1 - p) / (1 + p))
        }

        // MARK: Robust window copy with predictive uncertainty

        /// Consistency factor for the MAD of a Gaussian sample after symmetric trimming at ±k robust SD:
        /// the MAD of the kept values estimates m·σ with P(|Z| < m) = ½·P(|Z| < k), so the scale needs
        /// ×(0.6745 / m). k = 2 → ×1.053. Without it the trimmed scale is biased ~5 % low (audit finding).
        public static func trimmedMadConsistency(k: Double) -> Double {
            guard k.isFinite, k > 0 else { return 1 }
            let kept = 2 * normalCDF(k) - 1
            let m = normalQuantile(0.5 + kept / 4)
            guard m > 0 else { return 1 }
            return 0.674_489_75 / m
        }

        /// One robust reference copy built from daily values in math space (ln for HRV).
        public struct WindowCopy: Equatable, Sendable {
            public var center: Double
            /// 1.4826·MAD with the small-sample factor (and the trim consistency factor when trimmed), floored.
            public var scale: Double
            public var n: Int
            public var phi: Double
            public var phiAssumed: Bool
            public var nEff: Double
            /// Approximate standard error of the median center (1.2533·scale/√nEff).
            public var centerSE: Double
            /// Scale of a NEW day around this center: √(scale² + centerSE²). This is the predictive scale.
            public var predictiveScale: Double
            /// Degrees of freedom for the predictive Student-t: max(nEff − 1, 2).
            public var df: Double
            public var fromEpoch: Int
            public var toEpoch: Int
            public var trimmed: Bool
            public var scaleFloored: Bool
        }

        /// Default φ when it cannot be estimated (too few consecutive-day pairs). Conservative (PC uses 0.5 for its
        /// CUSUM; for the reference SE we use the median φ of nightly WHOOP-like series, 0.3, documented in
        /// docs/BASELINE_WATCHDOG_V2.md §2.2).
        public static let phiFallback = 0.3

        /// Builds a copy from (epoch, value) pairs. `trimK` > 0 applies the v1 fever-day trim (|x − m0|/s0 ≥ k
        /// dropped when at least `1 − pRegime` of days survive) and corrects the scale for the truncation.
        public static func windowCopy(pairs: [(epoch: Int, value: Double)], floor: Double, minN: Int,
                                      trimK: Double = LongitudinalBaseline.Params.kLearn,
                                      fromEpoch: Int, toEpoch: Int) -> WindowCopy? {
            let vals = pairs.map(\.value).filter(\.isFinite)
            guard vals.count >= max(1, minN), let m0 = RS.median(vals) else { return nil }
            var kept = pairs.filter { $0.value.isFinite }
            var trimmed = false
            if trimK > 0, vals.count >= 4,
               let s0raw = RS.madScale(vals, center: m0, smallSampleCorrection: true) {
                let s0 = max(s0raw, floor)
                let k = kept.filter { abs($0.value - m0) / s0 < trimK }
                if Double(k.count) / Double(vals.count) >= 1 - LongitudinalBaseline.Params.pRegime, k.count >= minN {
                    trimmed = k.count < kept.count
                    kept = k
                }
            }
            let keptVals = kept.map(\.value)
            guard let c = RS.median(keptVals),
                  var s = RS.madScale(keptVals, center: c, smallSampleCorrection: true) else { return nil }
            if trimmed { s *= trimmedMadConsistency(k: trimK) }
            let floored = s < floor
            s = max(s, floor)
            let phiHat = lagOnePhi(pairs: kept, center: c)
            let phi = phiHat ?? phiFallback
            let nEff = effectiveN(keptVals.count, phi: phi)
            let se = RS.medianStandardErrorFactor * s / nEff.squareRoot()
            return WindowCopy(center: c, scale: s, n: keptVals.count, phi: phi, phiAssumed: phiHat == nil,
                              nEff: nEff, centerSE: se, predictiveScale: (s * s + se * se).squareRoot(),
                              df: max(nEff - 1, 2), fromEpoch: fromEpoch, toEpoch: toEpoch, trimmed: trimmed,
                              scaleFloored: floored)
        }

        /// Predictive z and two-sided p of `x` against a copy.
        public static func predictive(_ x: Double, _ copy: WindowCopy) -> (z: Double, p: Double) {
            let z = (x - copy.center) / max(copy.predictiveScale, 1e-12)
            return (z, studentTTwoSidedP(z, df: copy.df))
        }

        // MARK: Trend (Theil–Sen + Mann–Kendall, autocorrelation-corrected)

        public struct Trend: Equatable, Sendable {
            /// Theil–Sen slope, math units per day.
            public var slopePerDay: Double
            public var lowerPerDay: Double
            public var upperPerDay: Double
            public var mannKendallZ: Double
            /// Two-sided p of the Mann–Kendall test with the variance inflated for lag-1 autocorrelation.
            public var p: Double
            public var n: Int
            public var spanDays: Int
            public var phi: Double
        }

        /// Theil–Sen slope with a Mann–Kendall significance test (variance × (1+φ)/(1−φ), φ from detrended
        /// consecutive-day residuals) and the distribution-free Sen confidence interval at `ciAlpha`.
        /// nil below 8 points or 7 calendar days of span.
        public static func trend(pairs: [(epoch: Int, value: Double)], ciAlpha: Double = 0.05) -> Trend? {
            let pts = pairs.filter { $0.value.isFinite }.sorted { $0.epoch < $1.epoch }
            let n = pts.count
            guard n >= 8, let first = pts.first, let last = pts.last, last.epoch - first.epoch >= 7 else { return nil }
            var slopes: [Double] = []
            slopes.reserveCapacity(n * (n - 1) / 2)
            var s = 0.0
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    let dy = pts[j].value - pts[i].value
                    let dx = Double(pts[j].epoch - pts[i].epoch)
                    if dx > 0 { slopes.append(dy / dx) }
                    s += dy > 0 ? 1 : (dy < 0 ? -1 : 0)
                }
            }
            slopes.sort()
            guard !slopes.isEmpty, let sen = RS.median(slopes) else { return nil }
            let intercept = RS.median(pts.map { $0.value - sen * Double($0.epoch) }) ?? 0
            let resid = pts.map { (epoch: $0.epoch, value: $0.value - (intercept + sen * Double($0.epoch))) }
            let phi = lagOnePhi(pairs: resid, center: 0, minPairs: 6) ?? phiFallback
            let nn = Double(n)
            var varS = nn * (nn - 1) * (2 * nn + 5) / 18
            varS *= (1 + phi) / (1 - phi)
            let z: Double
            if s > 0 { z = (s - 1) / varS.squareRoot() } else if s < 0 { z = (s + 1) / varS.squareRoot() } else { z = 0 }
            let p = 2 * (1 - normalCDF(abs(z)))
            let cAlpha = normalQuantile(1 - ciAlpha / 2) * varS.squareRoot()
            let nPairs = Double(slopes.count)
            let m1 = Int(((nPairs - cAlpha) / 2).rounded(.down))
            let m2 = Int(((nPairs + cAlpha) / 2).rounded(.up))
            let lower = slopes[min(max(m1, 0), slopes.count - 1)]
            let upper = slopes[min(max(m2, 0), slopes.count - 1)]
            return Trend(slopePerDay: sen, lowerPerDay: lower, upperPerDay: upper, mannKendallZ: z, p: p, n: n,
                         spanDays: last.epoch - first.epoch, phi: phi)
        }

        // MARK: Two-sided CUSUM on daily predictive z (PhysiologyContext design)

        /// Parameters follow `PhysiologyContext.ChangeConfig` (pc-change-2): reference k = 0.25, decision h (9 here),
        /// daily z clamped to ±2 (one extreme day supplies ≤ 25 % of an alarm), statistic capped at 1.25·h, input
        /// divided by the AR(1) long-run factor √((1+φ)/(1−φ)). The PC evaluation measured ≈0.03 false persistent
        /// episodes per series-week at φ ∈ {0, 0.3, 0.5}; Layer 1's own null simulation is in
        /// `LongitudinalBaselineV2CalibrationTests`.
        public struct CusumConfig: Equatable, Sendable {
            public var k = 0.25
            /// h = 10 (PC uses 7). Layer 1 runs ~8 series per person; at h = 7 the null simulation gave 2–4 false
            /// episodes per series-year. At h = 10 Siegmund's ARL₀ ≈ 2,000 days per arm (≈ 0.35/series-year
            /// two-sided, nominal; estimated-reference effects roughly double it — see
            /// LongitudinalBaselineV2CalibrationTests). Cost: a 2 SD step alarms ~2 days later than at h = 7.
            public var h = 10.0
            public var clampZ = 2.0
            public var capFactor = 1.25
            /// A gap longer than this many days between scored days resets both arms.
            public var maxGapDays = 7
            public init() {}
        }

        public struct CusumStep: Equatable, Sendable {
            public var pos: Double
            public var neg: Double
            /// +1 when the upper arm crossed h on this step, −1 for the lower arm, 0 otherwise.
            public var alarm: Int
        }

        public static func cusumStep(pos: Double, neg: Double, z: Double, phi: Double,
                                     config: CusumConfig = CusumConfig()) -> CusumStep {
            let p = min(0.95, max(0, phi))
            let adj = ((1 + p) / (1 - p)).squareRoot()
            let zz = min(config.clampZ, max(-config.clampZ, z)) / adj
            let cap = config.capFactor * config.h
            let newPos = min(cap, max(0, pos + zz - config.k))
            let newNeg = min(cap, max(0, neg - zz - config.k))
            var alarm = 0
            // Strictly above h (PhysiologyContext: `next > h`); the episode stays open while the arm is > h.
            if newPos > config.h && pos <= config.h { alarm = 1 }
            if newNeg > config.h && neg <= config.h { alarm = -1 }
            return CusumStep(pos: newPos, neg: newNeg, alarm: alarm)
        }
    }
}
