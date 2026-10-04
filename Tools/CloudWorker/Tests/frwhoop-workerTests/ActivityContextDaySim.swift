import Foundation
import WhoopProtocol
@testable import frwhoop_worker

/// Deterministic wrist-sensor data for one UTC day as the worker has it after inference: the stored 1 Hz
/// heart rate, gravity and step-counter rows, and the Python service's per-window predictions (4 s windows
/// on a 2 s hop, each with its `imu-feat-1` features).
///
/// Magnitudes follow this strap's measured distributions: resting dynAccel about 8 mg, walking about
/// 135 mg with roughly 1.5 step-counter ticks a second.
struct DaySim {
    private(set) var ts: Int
    private var seed: UInt64
    private var gravityDeg = 0.0
    private var counter = 1000
    private(set) var hr: [HRSample] = []
    private(set) var gravity: [GravitySample] = []
    private(set) var steps: [StepSample] = []
    private(set) var windows: [ActivityPythonService.WindowPrediction] = []
    /// What the service stamps on its windows: the heuristic baseline or the trained encoder.
    var baseline = false

    init(start: Int, seed: UInt64 = 7) {
        self.ts = start
        self.seed = seed
    }

    private mutating func rand() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }

    private mutating func noise(_ amplitude: Double) -> Double { (rand() - 0.5) * 2 * amplitude }

    static let stationaryProbs: [String: Double] = [
        "stationary": 0.92, "walking": 0.03, "running": 0.01, "other_movement": 0.04, "unknown": 0.0]
    static let walkingProbs: [String: Double] = [
        "walking": 0.9, "stationary": 0.05, "running": 0.02, "other_movement": 0.03, "unknown": 0.0]
    static let stationaryFeatures: [String: Double] = [
        "accel_rms_g": 0.009, "gyro_rms_dps": 3, "jerk_rms": 0.03, "cadence_strength": 0.1,
        "orientation_change_deg": 0.5]
    static let walkingFeatures: [String: Double] = [
        "accel_rms_g": 0.14, "gyro_rms_dps": 60, "jerk_rms": 0.2, "cadence_hz": 1.9,
        "cadence_strength": 0.7, "orientation_change_deg": 6]

    private mutating func emit(dyn: Double, ticks: Int, activityClass: Int, bpm: Int,
                               rotate: Double, jitter: Double, label: String,
                               probs: [String: Double], features: [String: Double]) {
        gravityDeg += rotate
        counter = (counter + ticks) & 0xFFFF
        hr.append(HRSample(ts: ts, bpm: bpm))
        let r = (gravityDeg + jitter) * .pi / 180
        gravity.append(GravitySample(ts: ts, x: 0.2, y: cos(r) * 0.9, z: sin(r) * 0.9 + 0.35, dynAccel: dyn))
        steps.append(StepSample(ts: ts, counter: counter, activityClass: activityClass))
        if ts % 2 == 0 {
            windows.append(ActivityPythonService.WindowPrediction(
                start: Double(ts - 4), end: Double(ts), label: label, probs: probs,
                baseline: baseline, features: features))
        }
        ts += 1
    }

    /// A resting wrist: tiny motion, no steps, a stable orientation.
    mutating func still(_ seconds: Int) {
        for _ in 0..<seconds {
            let dyn = max(0.003, 0.008 + noise(0.003))
            emit(dyn: dyn, ticks: 0, activityClass: 0, bpm: 66, rotate: noise(0.15), jitter: 0,
                 label: "stationary", probs: Self.stationaryProbs, features: Self.stationaryFeatures)
        }
    }

    /// Steady walking: arm swing, a step tick or two a second, an elevated heart rate.
    mutating func walk(_ seconds: Int) {
        for i in 0..<seconds {
            emit(dyn: 0.135 + noise(0.04), ticks: i % 2 == 0 ? 2 : 1, activityClass: 1, bpm: 104,
                 rotate: noise(0.3), jitter: noise(10),
                 label: "walking", probs: Self.walkingProbs, features: Self.walkingFeatures)
        }
    }

    /// Silence: no rows for `seconds` (the strap was off or out of range).
    mutating func gap(_ seconds: Int) { ts += seconds }

    var streams: ActivityContextDays.Streams {
        ActivityContextDays.Streams(hr: hr, gravity: gravity, steps: steps, events: [])
    }
}
