import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// Deterministic synthetic wrist-sensor streams for ActivityContext decoder tests.
///
/// Magnitudes follow this strap's measured distributions: resting dynAccel ≈ 7–10 mg, desk activity
/// 15–60 mg, walking ≈ 135 mg (about 2 step-counter ticks per second), running ≈ 400 mg.
struct ActivitySim {
    var ts: Int
    var seed: UInt64
    private(set) var observations: [ActivityObservation] = []
    /// Where the wrist's orientation is centred (rotation about the x axis, degrees). Only deliberate
    /// posture changes and slow drift move it; per-second jitter does not accumulate.
    private var gravityDeg: Double = 0
    private var counter: Int = 0

    init(start: Int = 1_760_000_000, seed: UInt64 = 7) {
        self.ts = start
        self.seed = seed
    }

    // Small LCG so every run of the suite sees identical noise.
    mutating func rand() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }

    mutating func noise(_ amplitude: Double) -> Double { (rand() - 0.5) * 2 * amplitude }

    private func gravityVector(jitter: Double) -> [Double] {
        let r = (gravityDeg + jitter) * .pi / 180
        return [0.2, cos(r) * 0.9, sin(r) * 0.9 + 0.35]
    }

    struct Options {
        var hr: Int? = 66
        var sleep: SleepEvidence = .unknown
        var wear: WearEvidence = .onWrist
        var workout = false
        var gravity = true
        var dyn = true
        var steps = true
        var encoder: ((Int) -> MotionEncoderOutput?)? = nil
        var imu: ((Int) -> ImuWindowFeatures?)? = nil
    }

    /// `rotate` moves the orientation centre (posture change / drift); `jitter` is an instantaneous
    /// wobble around it (arm swing, fidgeting) that is gone the next second.
    mutating func emit(dyn: Double?, ticks: Int, cls: Int, rotate: Double, jitter: Double = 0, opt: Options) {
        gravityDeg += rotate
        counter += ticks
        var o = ActivityObservation(ts: ts)
        if opt.dyn { o.dynAccelG = dyn }
        if opt.gravity { o.gravity = gravityVector(jitter: jitter) }
        if opt.steps { o.stepTicks = ticks; o.strapClass = cls }
        o.hrBpm = opt.hr
        o.sleep = opt.sleep
        o.wear = opt.wear
        o.loggedWorkout = opt.workout
        o.encoder = opt.encoder?(ts)
        o.imu = opt.imu?(ts)
        observations.append(o)
        ts += 1
    }

    /// Resting wrist: tiny noise, no steps.
    mutating func still(_ seconds: Int, dyn: Double = 0.008, opt: Options = Options()) {
        for _ in 0..<seconds {
            emit(dyn: max(0.003, dyn + noise(dyn * 0.4)), ticks: 0, cls: 0, rotate: noise(0.15), opt: opt)
        }
    }

    /// Desk-like: continuous small hand motion, stable orientation, no steps.
    mutating func desk(_ seconds: Int, opt: Options = Options()) {
        for _ in 0..<seconds {
            let d = 0.015 + rand() * 0.05
            emit(dyn: d, ticks: 0, cls: 0, rotate: noise(0.8), opt: opt)
        }
    }

    /// Fidgeting: mostly quiet with bursts of larger, irregular movement and orientation shifts.
    mutating func fidget(_ seconds: Int, opt: Options = Options()) {
        var burstLeft = 0
        for _ in 0..<seconds {
            if burstLeft == 0, rand() < 0.14 { burstLeft = 1 + Int(rand() * 2.5) }
            if burstLeft > 0 {
                emit(dyn: 0.10 + rand() * 0.16, ticks: 0, cls: 0, rotate: noise(0.3), jitter: noise(22), opt: opt)
                burstLeft -= 1
            } else {
                emit(dyn: 0.010 + rand() * 0.02, ticks: 0, cls: 0, rotate: noise(0.4), opt: opt)
            }
        }
    }

    mutating func walk(_ seconds: Int, brisk: Bool = false, opt: Options = Options()) {
        var o = opt
        o.hr = opt.hr == nil ? nil : (brisk ? 124 : 104)
        for i in 0..<seconds {
            let d = (brisk ? 0.22 : 0.135) + noise(0.04)
            emit(dyn: d, ticks: (i % 2 == 0) ? 2 : (brisk ? 2 : 1), cls: 1, rotate: noise(0.3), jitter: noise(10), opt: o)
        }
    }

    mutating func run(_ seconds: Int, opt: Options = Options()) {
        var o = opt
        o.hr = opt.hr == nil ? nil : 152
        for _ in 0..<seconds {
            emit(dyn: 0.42 + noise(0.12), ticks: 3, cls: 2, rotate: noise(0.3), jitter: noise(14), opt: o)
        }
    }

    /// A short movement burst with a net orientation change (sit↔stand, lie down, get up).
    mutating func postureShift(netDegrees: Double, seconds: Int = 3, opt: Options = Options()) {
        let step = netDegrees / Double(seconds)
        for _ in 0..<seconds {
            emit(dyn: 0.22 + noise(0.06), ticks: 0, cls: 0, rotate: step, opt: opt)
        }
    }

    /// Quiet wrist while the band reports sleep.
    mutating func sleeping(_ seconds: Int, opt: Options = Options()) {
        var o = opt
        o.sleep = .asleep
        o.hr = opt.hr == nil ? nil : 54
        still(seconds, dyn: 0.006, opt: o)
    }

    /// Strap off the wrist: wear gate closed, no sensor values.
    mutating func offWrist(_ seconds: Int) {
        for _ in 0..<seconds {
            var o = ActivityObservation(ts: ts)
            o.wear = .offWrist
            observations.append(o)
            ts += 1
        }
    }

    /// Silence: no observations at all for `seconds` (a data gap).
    mutating func gap(_ seconds: Int) { ts += seconds }
}

extension ActivitySim {
    /// The same stream as stored sensor rows, the way the app has them: 1 Hz HR, gravity vector with the
    /// strap's dynAccel, and a cumulative step counter with the strap's activity label.
    func trackInput(start: Int? = nil, end: Int? = nil,
                    sleep: [DayStateSpan] = [], workouts: [DayStateWorkout] = [],
                    offWrist: [DayStateSpan] = [], sleepKnownOutsideSessions: Bool = true) -> ActivityContextTrackInput {
        let lo = start ?? observations.first?.ts ?? 0
        let hi = end ?? ((observations.last?.ts ?? 0) + 1)
        var hr: [HRSample] = [], grav: [GravitySample] = [], steps: [StepSample] = []
        var counter = 1000
        for o in observations where o.wear != .offWrist {
            if let b = o.hrBpm { hr.append(HRSample(ts: o.ts, bpm: b)) }
            if let g = o.gravity, g.count == 3 {
                grav.append(GravitySample(ts: o.ts, x: g[0], y: g[1], z: g[2], dynAccel: o.dynAccelG))
            }
            if let t = o.stepTicks {
                counter = (counter + t) & 0xFFFF
                steps.append(StepSample(ts: o.ts, counter: counter, activityClass: o.strapClass))
            }
        }
        return ActivityContextTrackInput(dayStart: lo, dayEnd: hi, hr: hr, gravity: grav, steps: steps,
                                         sleep: sleep, sleepKnownOutsideSessions: sleepKnownOutsideSessions,
                                         workouts: workouts, offWrist: offWrist)
    }
}

extension ActivityContextDecoder {
    /// Runs observations through the decoder and returns the published states.
    mutating func run(_ observations: [ActivityObservation]) -> [ActivityContextState] {
        var out: [ActivityContextState] = []
        for o in observations { if let s = ingest(o) { out.append(s) } }
        return out
    }
}

/// Convenience encoder window generators.
enum SimEncoder {
    static func coarse(_ dominant: String, p: Double = 0.92, baseline: Bool = false) -> (Int) -> MotionEncoderOutput? {
        return { ts in
            guard ts % 2 == 0 else { return nil }
            var labels = ["stationary", "walking", "running", "other_movement"]
            if !labels.contains(dominant) { labels.append(dominant) }
            var probs: [String: Double] = [:]
            let rest = (1 - p) / Double(labels.count - 1)
            for l in labels { probs[l] = l == dominant ? p : rest }
            return MotionEncoderOutput(encoderId: baseline ? "baseline" : "hart", encoderVersion: "test-1",
                                       startTs: ts - 4, endTs: ts, classProbs: probs,
                                       calibrated: !baseline, abstained: false)
        }
    }
}
