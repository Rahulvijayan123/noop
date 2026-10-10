import Foundation

// ActivityVerticalShift.swift — the strap's change of height across a stand-up or sit-down, from the raw IMU
// (hsmm-2.0).
//
// Standing up lifts the shoulder, and so an upper-arm strap, by roughly 0.3–0.5 m; sitting down drops it by the same.
// Over the few seconds of a transition that is measurable by integrating the gravity-aligned acceleration twice with
// the strap still (zero velocity) at both ends. Unlike the 1 Hz forearm-orientation rules this does not care how the
// arm is held, which is what makes it the upper arm's posture cue.

/// One measured shift, as the decoder reads it (`ActivityObservation.verticalShift`, on the second it completes).
public struct ActivityVerticalShiftEvidence: Codable, Equatable, Sendable {
    /// The second the shift's movement ended (the decoder sees it then).
    public var ts: Int
    /// The second its movement began.
    public var startTs: Int
    /// Net vertical displacement of the strap, metres (> 0 up).
    public var displacementM: Double
    /// 0…1: how well the measurement held (stillness at both ends, residual drift, sampling).
    public var quality: Double
    public var version: String

    public init(ts: Int, startTs: Int, displacementM: Double, quality: Double,
                version: String = ActivityVerticalShift.version) {
        self.ts = ts; self.startTs = startTs; self.displacementM = displacementM; self.quality = quality
        self.version = version
    }
}

public enum ActivityVerticalShift {
    public static let version = "vshift-1"

    /// One raw IMU sample: accelerometer in g (gravity included), gyroscope in °/s.
    public struct Sample: Equatable, Sendable {
        public var ax, ay, az, gx, gy, gz: Double
        public init(ax: Double, ay: Double, az: Double, gx: Double, gy: Double, gz: Double) {
            self.ax = ax; self.ay = ay; self.az = az; self.gx = gx; self.gy = gy; self.gz = gz
        }
    }

    // Parameters (port of _build-scratch/bicep-posture/B-upperarm/vdisp_ref.py; thresholds from its REPORT.md).
    /// Rate the detector works at: raw 100 Hz is averaged down to this.
    public static let workRateHz = 50.0
    /// Runs shorter than this hold no event with stillness on both sides.
    public static let minRunSeconds = 6
    /// Activity envelope (moving total SD of the three axes, g): active above, still below.
    public static let activeG = 0.06, stillG = 0.03
    static let envelopeWindowS = 0.5, mergeGapS = 0.7, minEventS = 0.8, maxEventS = 6.0
    static let stillNeedS = 1.0, stillFraction = 0.7, stillSearchS = 1.5, edgeS = 0.25, onsetLengthS = 2.5
    /// Zero-velocity pads either side of the event (s).
    static let padS = 1.0
    /// Gyro-aided gravity: pull toward the accelerometer direction (1/s), down-weighted away from 1 g.
    static let gravityGain = 1.0, gravityNormTolerance = 0.15
    /// Decision: |Δh| at least this (m) with a peak vertical velocity of the same sign at least `minPeakVelocity`.
    ///
    /// Opportunity's upper-arm IMUs (4 people, B-upperarm/REPORT.md) put stand-ups at +0.48 m median (p10 +0.32) and
    /// sit-downs at −0.52 m; the owner's own bicep strap measured +0.34 / +0.37 / −0.23 / −0.25 m, so the floor is
    /// 0.20 m for movements bounded by stillness (direction right on every such burst there and on the owner's).
    public static let minDisplacementM = 0.20
    public static let minPeakVelocity = 0.25
    /// Larger than any sit-down (Opportunity p10 −0.61 m): bending or squatting to a low drawer (−0.7 to −0.9 m), not a
    /// change of posture.
    public static let maxDisplacementM = 0.70
    /// Pad velocity residual (m/s RMS) at which a measurement is worthless (quality 0); half of it gives 0.5.
    static let maxPadVelocity = 0.20

    static let g0 = 9.80665

    /// Measured stand-ups (Δh > 0) and sit-downs (Δh < 0) over one contiguous run of samples starting at `startTs`
    /// (Unix seconds of the first sample) at `sampleRateHz`. Only shifts that pass the decision rule are returned,
    /// each with its quality (0…1). Pure and deterministic.
    public static func detect(_ raw: [Sample], sampleRateHz: Double, startTs: Double) -> [ActivityVerticalShiftEvidence] {
        guard sampleRateHz > 0, Double(raw.count) / sampleRateHz >= Double(minRunSeconds) else { return [] }
        // Average down to the work rate.
        let k = max(1, Int((sampleRateHz / workRateHz).rounded()))
        let fs = sampleRateHz / Double(k)
        var acc: [(Double, Double, Double)] = [], gyr: [(Double, Double, Double)] = []
        acc.reserveCapacity(raw.count / k + 1); gyr.reserveCapacity(raw.count / k + 1)
        var i = 0
        while i + k <= raw.count {
            var a = (0.0, 0.0, 0.0), w = (0.0, 0.0, 0.0)
            for j in i..<(i + k) {
                let r = raw[j]
                a.0 += r.ax; a.1 += r.ay; a.2 += r.az
                w.0 += r.gx; w.1 += r.gy; w.2 += r.gz
            }
            let d = Double(k), rad = Double.pi / 180
            acc.append((a.0 / d, a.1 / d, a.2 / d)); gyr.append((w.0 / d * rad, w.1 / d * rad, w.2 / d * rad))
            i += k
        }
        let n = acc.count
        guard n > Int(2 * padS * fs) + 4 else { return [] }
        guard acc.allSatisfy({ $0.0.isFinite && $0.1.isFinite && $0.2.isFinite }),
              gyr.allSatisfy({ $0.0.isFinite && $0.1.isFinite && $0.2.isFinite }) else { return [] }
        let gravity = gravityDirection(acc, gyr, fs: fs)
        var out: [ActivityVerticalShiftEvidence] = []
        for event in segment(acc, fs: fs) {
            guard let m = measure(acc, gravity, fs: fs, from: event.0, to: event.1) else { continue }
            guard abs(m.dh) >= minDisplacementM, abs(m.dh) <= maxDisplacementM, abs(m.vpeak) >= minPeakVelocity,
                  (m.dh > 0) == (m.vpeak > 0) else {
                continue
            }
            let quality = max(0, min(1, 1 - m.padVelocity / maxPadVelocity))
            let t0 = startTs + Double(event.0) / fs, t1 = startTs + Double(event.1) / fs
            out.append(ActivityVerticalShiftEvidence(ts: Int(t1.rounded(.up)), startTs: Int(t0.rounded(.down)),
                                                     displacementM: m.dh, quality: quality))
        }
        // Overlapping candidates (a burst and an onset of the same movement) keep the better-measured one.
        var kept: [ActivityVerticalShiftEvidence] = []
        for e in out.sorted(by: { ($0.startTs, $0.ts) < ($1.startTs, $1.ts) }) {
            if let last = kept.last, e.startTs < last.ts {
                if e.quality > last.quality { kept[kept.count - 1] = e }
            } else {
                kept.append(e)
            }
        }
        return kept
    }

    /// Gravity direction in the sensor frame: the gyro propagates it (a world-fixed vector seen from a rotating
    /// frame obeys dv/dt = −ω × v) and the accelerometer pulls it back, less so the further |a| is from 1 g; a
    /// forward and a time-reversed pass are averaged.
    static func gravityDirection(_ acc: [(Double, Double, Double)], _ gyr: [(Double, Double, Double)],
                                 fs: Double) -> [(Double, Double, Double)] {
        let n = acc.count, dt = 1 / fs
        func pass(_ order: [Int], sign: Double) -> [(Double, Double, Double)] {
            var out = [(Double, Double, Double)](repeating: (0, 0, 1), count: n)
            let m = min(n, max(1, Int(0.5 * fs)))
            var g = (0.0, 0.0, 0.0)
            for j in order.prefix(m) { g.0 += acc[j].0; g.1 += acc[j].1; g.2 += acc[j].2 }
            func normalised(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
                let l = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
                return l > 1e-12 ? (v.0 / l, v.1 / l, v.2 / l) : (0, 0, 1)
            }
            g = normalised(g)
            for j in order {
                let w = (sign * gyr[j].0, sign * gyr[j].1, sign * gyr[j].2)
                let c = (w.1 * g.2 - w.2 * g.1, w.2 * g.0 - w.0 * g.2, w.0 * g.1 - w.1 * g.0)
                g = (g.0 - c.0 * dt, g.1 - c.1 * dt, g.2 - c.2 * dt)
                let a = acc[j]
                let na = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).squareRoot()
                if na > 1e-6 {
                    let z = (na - 1) / gravityNormTolerance
                    let wt = gravityGain * dt * exp(-z * z)
                    g = (g.0 + wt * (a.0 / na - g.0), g.1 + wt * (a.1 / na - g.1), g.2 + wt * (a.2 / na - g.2))
                }
                g = normalised(g)
                out[j] = g
            }
            return out
        }
        let f = pass(Array(0..<n), sign: 1)
        let b = pass(Array((0..<n).reversed()), sign: -1)
        return (0..<n).map { j in
            let v = (f[j].0 + b[j].0, f[j].1 + b[j].1, f[j].2 + b[j].2)
            let l = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
            return l > 1e-12 ? (v.0 / l, v.1 / l, v.2 / l) : f[j]
        }
    }

    /// Candidate movements (sample index ranges, edges included): active bursts of `minEventS`…`maxEventS` with
    /// relative stillness on both sides, and the first / last `onsetLengthS` of a longer activity (walking away
    /// after standing up, walking up before sitting down) on the side that is still.
    static func segment(_ acc: [(Double, Double, Double)], fs: Double) -> [(Int, Int)] {
        let n = acc.count
        let win = max(1, Int((envelopeWindowS * fs).rounded()))
        // Centred moving SD per axis via prefix sums.
        var p1 = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: 3)
        var p2 = p1
        for j in 0..<n {
            let v = [acc[j].0, acc[j].1, acc[j].2]
            for a in 0..<3 { p1[a][j + 1] = p1[a][j] + v[a]; p2[a][j + 1] = p2[a][j] + v[a] * v[a] }
        }
        var env = [Double](repeating: 0, count: n)
        for j in 0..<n {
            let lo = max(0, j - win / 2), hi = min(n, j - win / 2 + win)
            let c = Double(max(1, hi - lo))
            var v = 0.0
            for a in 0..<3 {
                let m1 = (p1[a][hi] - p1[a][lo]) / c, m2 = (p2[a][hi] - p2[a][lo]) / c
                v += max(0, m2 - m1 * m1)
            }
            env[j] = v.squareRoot()
        }
        var runs: [(Int, Int)] = []
        var j = 0
        while j < n {
            if env[j] > activeG {
                let s = j
                while j < n, env[j] > activeG { j += 1 }
                if let last = runs.last, Double(s - last.1) < mergeGapS * fs { runs[runs.count - 1].1 = j }
                else { runs.append((s, j)) }
            } else {
                j += 1
            }
        }
        var stillPrefix = [Int](repeating: 0, count: n + 1)
        for j in 0..<n { stillPrefix[j + 1] = stillPrefix[j] + (env[j] < stillG ? 1 : 0) }
        let need = Int((stillNeedS * fs).rounded()), search = Int((stillSearchS * fs).rounded())
        func stillWindow(_ lo: Int, _ hi: Int) -> Bool {
            let a0 = max(0, lo), h = min(n, hi)
            guard h - a0 >= need else { return false }
            for a in a0...(h - need) where Double(stillPrefix[a + need] - stillPrefix[a]) >= stillFraction * Double(need) {
                return true
            }
            return false
        }
        let edge = Int((edgeS * fs).rounded()), onset = Int((onsetLengthS * fs).rounded())
        var out: [(Int, Int)] = []
        for (s, t) in runs {
            let dur = Double(t - s) / fs
            guard dur >= minEventS else { continue }
            let pre = stillWindow(s - search - need, s), post = stillWindow(t, t + search + need)
            if dur <= maxEventS {
                if pre && post { out.append((max(0, s - edge), min(n - 1, t + edge))) }
            } else {
                if pre { out.append((max(0, s - edge), min(n - 1, s + onset))) }
                if post { out.append((max(0, t - onset), min(n - 1, t + edge))) }
            }
        }
        return out
    }

    struct Measurement { var dh: Double; var vpeak: Double; var padVelocity: Double }

    /// Net vertical displacement between the still pads either side of `[from, to)`: a_v = (a·ĝ − 1 g)·g0,
    /// integrated twice with the linear velocity drift removed so the mean velocity is 0 in both pads.
    static func measure(_ acc: [(Double, Double, Double)], _ gravity: [(Double, Double, Double)], fs: Double,
                        from: Int, to: Int) -> Measurement? {
        let n = acc.count
        let p = max(1, Int((padS * fs).rounded()))
        guard from - p >= 0, to + p <= n, to > from else { return nil }
        let a = from - p, b = to + p, m = b - a
        let k0 = from - a, k1 = to - a
        var av = [Double](repeating: 0, count: m)
        for j in 0..<m {
            let x = acc[a + j], g = gravity[a + j]
            av[j] = (x.0 * g.0 + x.1 * g.1 + x.2 * g.2 - 1) * g0
        }
        let dt = 1 / fs
        var v = [Double](repeating: 0, count: m)
        for j in 1..<m { v[j] = v[j - 1] + 0.5 * (av[j] + av[j - 1]) * dt }
        func mean(_ x: [Double], _ r: Range<Int>) -> Double { r.isEmpty ? 0 : x[r].reduce(0, +) / Double(r.count) }
        let pre = 0..<max(1, k0), post = min(k1, m - 1)..<m
        let tp = (Double(pre.lowerBound + pre.upperBound - 1) / 2) * dt
        let tq = (Double(post.lowerBound + post.upperBound - 1) / 2) * dt
        let vp = mean(v, pre), vq = mean(v, post)
        let c1 = tq > tp ? (vq - vp) / (tq - tp) : 0
        let c0 = vp - c1 * tp
        for j in 0..<m { v[j] -= c0 + c1 * Double(j) * dt }
        var h = [Double](repeating: 0, count: m)
        for j in 1..<m { h[j] = h[j - 1] + 0.5 * (v[j] + v[j - 1]) * dt }
        let dh = mean(h, post) - mean(h, pre)
        var vpeak = 0.0
        for j in k0..<max(k0 + 1, k1) where abs(v[j]) > abs(vpeak) { vpeak = v[j] }
        var padSq = 0.0, padN = 0
        for j in Array(pre) + Array(post) { padSq += v[j] * v[j]; padN += 1 }
        let padVelocity = padN > 0 ? (padSq / Double(padN)).squareRoot() : .infinity
        guard dh.isFinite, vpeak.isFinite else { return nil }
        return Measurement(dh: dh, vpeak: vpeak, padVelocity: padVelocity)
    }
}
