import Foundation

// EnergyTemporalFilter.swift — temporal consistency for the metabolic timeline.
//
// A scalar random-walk Kalman filter followed by a Rauch–Tung–Striebel smoother over the day's minutes.
// The measurement at each minute is the fused estimate and its own variance, so a confident minute pulls
// the state hard and an ambiguous one barely moves it. The process noise is small while the activity is
// steady and large across an activity transition, which is what lets a real step change (sitting → run)
// through within a couple of minutes while a lone noisy minute is absorbed. A Huber guard inflates the
// variance of an innovation beyond `huberZ` sigma, and a slew limit is the last line of defence against
// a physiologically impossible jump.
//
// It is a smoother, not a causal filter: for a day still in progress the latest few minutes will be
// revised as later minutes arrive, which is what a recomputed-per-cycle daily score already does.

struct TemporalObservation {
    /// The fused MET for the minute, or nil for a minute without evidence (a coverage gap).
    var value: Double?
    /// Measurement variance of `value`.
    var variance: Double
    /// 0…1: how much the underlying state is expected to have changed since the previous minute.
    var transition: Double
}

struct TemporalEstimate {
    var mean: Double
    var variance: Double
    var slewLimited: Bool
}

enum MetabolicTemporalFilter {
    static func smooth(_ obs: [TemporalObservation], config: EnergyConfig) -> [TemporalEstimate] {
        let n = obs.count
        guard n > 0 else { return [] }

        var mFilt = [Double](repeating: 0, count: n)
        var pFilt = [Double](repeating: 0, count: n)
        var mPred = [Double](repeating: 0, count: n)
        var pPred = [Double](repeating: 0, count: n)

        let steadyVar = config.processSigmaSteady * config.processSigmaSteady
        let transVar = config.processSigmaTransition * config.processSigmaTransition

        var m = obs.first(where: { $0.value != nil })?.value ?? 1.2
        var p = 4.0
        for t in 0..<n {
            let q = steadyVar + (transVar - steadyVar) * obs[t].transition.clamped(0, 1)
            mPred[t] = m
            pPred[t] = p + q
            if let y = obs[t].value {
                let s = pPred[t] + obs[t].variance
                let z = abs(y - mPred[t]) / s.squareRoot()
                var r = obs[t].variance
                if z > config.huberZ { r *= (z / config.huberZ) * (z / config.huberZ) }
                let k = pPred[t] / (pPred[t] + r)
                m = mPred[t] + k * (y - mPred[t])
                p = (1 - k) * pPred[t]
            } else {
                m = mPred[t]
                p = pPred[t]
            }
            mFilt[t] = m
            pFilt[t] = p
        }

        var mSm = mFilt
        var pSm = pFilt
        if n > 1 {
            for t in stride(from: n - 2, through: 0, by: -1) {
                let c = pFilt[t] / pPred[t + 1]
                mSm[t] = mFilt[t] + c * (mSm[t + 1] - mPred[t + 1])
                pSm[t] = pFilt[t] + c * c * (pSm[t + 1] - pPred[t + 1])
            }
        }

        var limited = [Bool](repeating: false, count: n)
        let cap = config.maxSlewMetPerMin
        if n > 1 {
            for t in 1..<n {
                let d = mSm[t] - mSm[t - 1]
                if abs(d) > cap { mSm[t] = mSm[t - 1] + (d > 0 ? cap : -cap); limited[t] = true }
            }
            for t in stride(from: n - 2, through: 0, by: -1) {
                let d = mSm[t] - mSm[t + 1]
                if abs(d) > cap { mSm[t] = mSm[t + 1] + (d > 0 ? cap : -cap); limited[t] = true }
            }
        }

        return (0..<n).map { TemporalEstimate(mean: mSm[$0], variance: max(1e-6, pSm[$0]), slewLimited: limited[$0]) }
    }
}
