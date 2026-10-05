import Foundation

// PCRobustStats.swift — robust statistics primitives for the context layer (spec §12.2).
//
// OWNER: statistics workstream (seeded by the lead so every system shares one implementation; the existing
// helpers in the package are module-internal and duplicated per engine).
//
// Everything here is pure and deterministic. Non-finite inputs are ignored, never propagated; functions return nil
// instead of a NaN or an infinity so nothing non-finite can reach the document encoder.

extension PhysiologyContext {

    public enum RobustStats {

        /// Normal-consistency constant for the MAD (Rousseeuw & Croux 1993): `1.4826 * MAD` estimates sigma for
        /// Gaussian data. It is a scale estimate, not a probability statement.
        public static let madNormalConsistency = 1.4826

        /// `sqrt(pi / 2)`: the asymptotic standard error of the sample median is `1.2533 * sigma / sqrt(n)` for
        /// independent Gaussian data. Used only as an approximate, labelled center uncertainty.
        public static let medianStandardErrorFactor = 1.2533

        /// Median of finite values; nil when empty.
        public static func median(_ values: [Double]) -> Double? {
            let v = values.filter { $0.isFinite }.sorted()
            guard !v.isEmpty else { return nil }
            let mid = v.count / 2
            return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
        }

        /// Raw median absolute deviation about `center` (median of |x - center|); nil when empty.
        public static func mad(_ values: [Double], center: Double) -> Double? {
            median(values.filter { $0.isFinite }.map { abs($0 - center) })
        }

        /// Linear-interpolation quantile (type 7) of finite values, q in [0, 1]; nil when empty.
        public static func quantile(_ values: [Double], _ q: Double) -> Double? {
            let v = values.filter { $0.isFinite }.sorted()
            guard !v.isEmpty else { return nil }
            guard v.count > 1 else { return v[0] }
            let pos = min(1, max(0, q)) * Double(v.count - 1)
            let lo = Int(pos.rounded(.down)), hi = min(v.count - 1, lo + 1)
            return v[lo] + (v[hi] - v[lo]) * (pos - Double(lo))
        }

        public static func mean(_ values: [Double]) -> Double? {
            let v = values.filter { $0.isFinite }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }

        /// Sample standard deviation (n - 1); nil below two finite values.
        public static func standardDeviation(_ values: [Double]) -> Double? {
            let v = values.filter { $0.isFinite }
            guard v.count >= 2, let m = mean(v) else { return nil }
            let ss = v.reduce(0) { $0 + ($1 - m) * ($1 - m) }
            return (ss / Double(v.count - 1)).squareRoot()
        }

        /// Finite-sample factor `b_n` so that `E[b_n * 1.4826 * MAD] ≈ sigma` for n Gaussian values.
        ///
        /// The raw normal-consistent MAD is biased low in small samples (Rousseeuw & Croux 1993, Table 1: mean 0.911
        /// at n = 10, 0.959 at n = 20, 0.978 at n = 40). For n ≥ 10 we use `n / (n - 0.8)`, which reproduces those
        /// table values within 1 %; for n ≤ 9 the factors are our own Monte Carlo (400 000 Gaussian samples per n,
        /// numpy seed 20261005, the same even-n median convention as `median`). Re-checked by
        /// `PCEvaluationTests.testSmallSampleMadFactorIsUnbiasedAtGaussianData`. For one value the MAD is 0 and no
        /// factor helps: callers floor the scale.
        public static func madSmallSampleFactor(_ n: Int) -> Double {
            switch n {
            case ..<2: return 1
            case 2: return 1.196
            case 3: return 1.486
            case 4: return 1.361
            case 5: return 1.217
            case 6: return 1.187
            case 7: return 1.139
            case 8: return 1.126
            case 9: return 1.100
            default: return Double(n) / (Double(n) - 0.8)
            }
        }

        /// `1.4826 * MAD` about the median (optionally with the finite-sample factor); nil when empty.
        public static func madScale(_ values: [Double], center: Double, smallSampleCorrection: Bool) -> Double? {
            let v = values.filter { $0.isFinite }
            guard let m = mad(v, center: center) else { return nil }
            return madNormalConsistency * m * (smallSampleCorrection ? madSmallSampleFactor(v.count) : 1)
        }

        /// Approximate standard error of a median of `n` independent values with spread `sigma`
        /// (`1.2533 * sigma / sqrt(n)`). Autocorrelated daily values have fewer effective samples, so this is a
        /// lower bound in practice; it is always labelled approximate.
        public static func medianStandardError(sigma: Double, n: Int) -> Double? {
            guard n > 0, sigma.isFinite, sigma >= 0 else { return nil }
            return medianStandardErrorFactor * sigma / Double(n).squareRoot()
        }

        /// Values clamped to `[center - k * scale, center + k * scale]` (winsorization). The input is not modified.
        public static func winsorized(_ values: [Double], center: Double, scale: Double, k: Double) -> [Double] {
            let lo = center - k * scale, hi = center + k * scale
            return values.filter { $0.isFinite }.map { min(hi, max(lo, $0)) }
        }

        /// Variance of a standard normal winsorized at ±k: `(2Φ(k) - 1) - 2kφ(k) + 2k²(1 - Φ(k))`. Its square root
        /// rescales a winsorized SD back to sigma at Gaussian data.
        public static func winsorizedNormalVariance(k: Double) -> Double {
            guard k.isFinite, k > 0 else { return 1 }
            let phi = exp(-k * k / 2) / (2 * Double.pi).squareRoot()
            let cdf = 0.5 * erfc(-k / 2.0.squareRoot())
            return (2 * cdf - 1) - 2 * k * phi + 2 * k * k * (1 - cdf)
        }

        /// Theil–Sen slope: the median of pairwise slopes over points with distinct x; nil below two distinct x.
        /// Robust to isolated artifacts (29 % breakdown point), so a single extreme day does not fake a trend.
        public static func theilSenSlope(x: [Double], y: [Double]) -> Double? {
            guard x.count == y.count else { return nil }
            var slopes: [Double] = []
            slopes.reserveCapacity(x.count * (x.count - 1) / 2)
            for i in 0..<x.count where x[i].isFinite && y[i].isFinite {
                for j in (i + 1)..<x.count where x[j].isFinite && y[j].isFinite && x[j] != x[i] {
                    slopes.append((y[j] - y[i]) / (x[j] - x[i]))
                }
            }
            return median(slopes)
        }
    }
}
