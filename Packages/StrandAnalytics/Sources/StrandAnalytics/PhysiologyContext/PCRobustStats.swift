import Foundation

// PCRobustStats.swift — robust statistics primitives for the context layer (spec §12.2).
//
// OWNER: statistics workstream (seeded by the lead so every system shares one implementation; the existing
// helpers in the package are module-internal and duplicated per engine).

extension PhysiologyContext {

    public enum RobustStats {

        /// Normal-consistency constant for the MAD (Rousseeuw & Croux 1993): `1.4826 * MAD` estimates sigma for
        /// Gaussian data. It is a scale estimate, not a probability statement.
        public static let madNormalConsistency = 1.4826

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
    }
}
