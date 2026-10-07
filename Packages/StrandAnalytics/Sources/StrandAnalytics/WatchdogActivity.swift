import Foundation
import WhoopProtocol

/// Per-sample IMU (1 Hz gravity + optional dynAccel). Watchdog never trains on device.
public struct WatchdogIMUSample: Equatable, Sendable {
    public var ts: Int
    public var x: Double
    public var y: Double
    public var z: Double
    public var dynAccel: Double?
    public init(ts: Int, x: Double, y: Double, z: Double, dynAccel: Double? = nil) {
        self.ts = ts; self.x = x; self.y = y; self.z = z; self.dynAccel = dynAccel
    }
}

/// Minute-level activity embedding. Uses IMU + step @63 class + in-tree
/// `WorkoutTypeClassifier` (not a single occupancy scalar). Artifact widens σ, does not inflate J.
public enum WatchdogActivityRuntime: Sendable {
    public static func embed(motion: [Double?], hr: [Double?],
                             steps: [StepSample], imu: [WatchdogIMUSample],
                             startUnix: Int, nowUnix: Int,
                             family: DeviceFamily = .whoop4) -> [[Double]] {
        let n = motion.count
        guard n > 0 else { return WatchdogActivityClass.unknownLogits(minutes: 0) }
        let span = max(nowUnix - startUnix, 1)
        func minuteIndex(_ ts: Int) -> Int {
            min(n - 1, max(0, ((ts - startUnix) * n) / span))
        }
        var stepStill = Array(repeating: 0, count: n)
        var stepWalk = Array(repeating: 0, count: n)
        var stepRun = Array(repeating: 0, count: n)
        var stepN = Array(repeating: 0, count: n)
        for s in steps where s.ts >= startUnix && s.ts < nowUnix {
            let i = minuteIndex(s.ts)
            stepN[i] += 1
            switch s.activityClass {
            case 0: stepStill[i] += 1
            case 1: stepWalk[i] += 1
            case 2: stepRun[i] += 1
            default: break
            }
        }
        var dynSum = Array(repeating: 0.0, count: n)
        var dynSq = Array(repeating: 0.0, count: n)
        var dynN = Array(repeating: 0, count: n)
        var gravVar = Array(repeating: 0.0, count: n)
        var gravN = Array(repeating: 0, count: n)
        for g in imu where g.ts >= startUnix && g.ts < nowUnix {
            let i = minuteIndex(g.ts)
            let mag = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            gravVar[i] += abs(mag - 1)
            gravN[i] += 1
            if let d = g.dynAccel {
                dynSum[i] += d
                dynSq[i] += d * d
                dynN[i] += 1
            }
        }
        let dynMeans: [Double] = (0..<n).map { i in
            dynN[i] > 0 ? dynSum[i] / Double(dynN[i]) : max(0, motion[i] ?? 0) * 0.4
        }
        let windowDynCV = cv(dynMeans.filter { $0 > 1e-6 })
        let setRest = isSetRestCadence(dynMeans)
        let samplesPerMin = family == .whoop5 ? 2.0 : 60.0
        var logits = (0..<n).map { i -> [Double] in
            let occ = max(0, min(1, motion[i] ?? 0))
            let ticks = max(stepN[i], 1)
            let walkF = Double(stepWalk[i]) / Double(ticks)
            let runF = Double(stepRun[i]) / Double(ticks)
            let stillF = Double(stepStill[i]) / Double(ticks)
            let dynMean = dynMeans[i]
            let dynCV: Double = {
                guard dynN[i] > 1 else { return 0 }
                let mean = dynMean
                let var_ = max(0, dynSq[i] / Double(dynN[i]) - mean * mean)
                return mean > 1e-4 ? sqrt(var_) / mean : 0
            }()
            let gVar = gravN[i] > 0 ? gravVar[i] / Double(gravN[i]) : occ
            let sparseSteps = Double(stepN[i]) < samplesPerMin * 0.35
            return oneHot(pick(occ: occ, dynMean: dynMean, dynCV: dynCV, gravVar: gVar,
                               walkF: walkF, runF: runF, stillF: stillF, hasTicks: stepN[i] > 0,
                               hasImu: dynN[i] + gravN[i] > 0, hr: hr[i],
                               windowDynCV: windowDynCV, setRest: setRest, sparseSteps: sparseSteps))
        }
        blendWorkout(logits: &logits, motion: motion, hr: hr, steps: steps, imu: imu,
                     startUnix: startUnix, nowUnix: nowUnix, family: family,
                     windowDynCV: windowDynCV, setRest: setRest)
        return logits
    }

    public static func applyAutoWorkoutOverlap(_ logits: [[Double]], overlap: [Double]) -> [[Double]] {
        zip(logits, overlap).map { row, bit in
            guard bit >= 0.5 else { return row }
            guard let idx = row.enumerated().max(by: { $0.element < $1.element })?.offset else { return row }
            let label = WatchdogActivityClass.allCases[idx]
            guard label == .unknown || label == .still || label == .stand else { return row }
            var out = row
            let w = WatchdogActivityClass.walk.index
            for j in out.indices { out[j] *= 0.65 }
            out[w] += 0.35
            return out
        }
    }

    /// Occupancy the reconstructor may use: class effort, not raw 0–1, except unknown falls back to IMU mag.
    public static func effortOccupancy(motion: [Double?], logits: [[Double]]) -> [Double] {
        let n = motion.count
        return (0..<n).map { i in
            let row = i < logits.count ? logits[i] : []
            let cls: WatchdogActivityClass
            if let idx = row.enumerated().max(by: { $0.element < $1.element })?.offset,
               idx < WatchdogActivityClass.allCases.count {
                cls = WatchdogActivityClass.allCases[idx]
            } else {
                cls = .unknown
            }
            let measured = motion[i].map { max(0, min(1, $0)) }
            switch cls {
            case .still, .stand: return 0
            case .walk: return max(0.32, measured ?? 0.32)
            case .run: return max(0.85, measured ?? 0.85)
            case .cycleLike: return max(0.55, measured ?? 0.55)
            case .resistance: return max(0.42, measured ?? 0.42)
            case .artifact: return 0
            case .unknown:
                // Nil motion is unknown, not rest. Tensor stays 0; score skips these minutes (F18).
                return measured ?? 0
            }
        }
    }

    public static func displayName(_ raw: String) -> String {
        switch raw {
        case "still": return "Still"
        case "stand": return "Standing"
        case "walk": return "Walking"
        case "run": return "Running"
        case "cycleLike": return "Cycle-like"
        case "resistance": return "Lifting"
        case "artifact": return "Motion artifact"
        default: return "Context unknown"
        }
    }

    public static func isArtifact(_ logits: [[Double]], from startIndex: Int = 0) -> Bool {
        let labels = WatchdogActivityClass.labels(logits: logits)
        let lo = min(max(0, startIndex), labels.count)
        guard lo < labels.count else { return false }
        let slice = Array(labels[lo...])
        return slice.suffix(min(8, slice.count)).contains(WatchdogActivityClass.artifact.rawValue)
    }

    public static func isStillish(_ logits: [[Double]]) -> Bool {
        guard let last = WatchdogActivityClass.labels(logits: logits).last else { return false }
        return last == WatchdogActivityClass.still.rawValue || last == WatchdogActivityClass.stand.rawValue
    }

    private static func pick(occ: Double, dynMean: Double, dynCV: Double, gravVar: Double,
                             walkF: Double, runF: Double, stillF: Double, hasTicks: Bool,
                             hasImu: Bool, hr: Double?,
                             windowDynCV: Double = 0, setRest: Bool = false,
                             sparseSteps: Bool = false) -> WatchdogActivityClass {
        if !hasTicks && !hasImu { return .unknown }
        let stepSport = hasTicks && !sparseSteps && (walkF >= 0.45 || runF >= 0.45)
        if !stepSport && occ > 0.35 && (dynCV > 1.4 || windowDynCV > 0.85) && !hasTicks {
            return .artifact
        }
        if occ > 0.35 && dynCV > 1.4 { return .artifact }
        if occ > 0.45, let hr, abs(hr - 60) < 6, dynMean > 0.15 { return .artifact }
        if hasTicks && runF >= 0.45 { return .run }
        if hasTicks && walkF >= 0.45 { return .walk }
        if hasTicks && stillF >= 0.45 && occ < WatchdogConfig.chairStillOccupancy {
            return occ < 0.14 ? .still : .stand
        }
        if !stepSport && occ < WatchdogConfig.chairStillOccupancy
            && dynMean < WatchdogConfig.chairStillDynMean
            && dynCV < 1.15 && windowDynCV < 0.80 {
            return occ < 0.14 ? .still : .stand
        }
        if occ < 0.10 && dynMean < 0.08 { return .still }
        if occ < 0.20 && gravVar < 0.16 { return .stand }
        if setRest && occ >= 0.18 && occ < 0.55 && walkF < 0.35 && runF < 0.35 {
            return .resistance
        }
        if occ >= 0.55 { return .run }
        if occ >= 0.22 && occ < 0.55 && dynCV < 0.35 && windowDynCV < 0.55 && !setRest {
            return .cycleLike
        }
        if occ >= 0.18 && (dynCV > 0.85 || setRest) { return .resistance }
        if occ >= 0.18 { return .walk }
        return .unknown
    }

    private static func oneHot(_ cls: WatchdogActivityClass) -> [Double] {
        var row = Array(repeating: 0.0, count: WatchdogActivityClass.count)
        row[cls.index] = 1
        return row
    }

    /// Last 10 minutes: in-tree coarse workout classifier biases the embedding (same job as Auto Workout).
    private static func blendWorkout(logits: inout [[Double]], motion: [Double?], hr: [Double?],
                                     steps: [StepSample], imu: [WatchdogIMUSample],
                                     startUnix: Int, nowUnix: Int,
                                     family: DeviceFamily = .whoop4,
                                     windowDynCV: Double = 0, setRest: Bool = false) {
        let n = logits.count
        let tail = min(10, n)
        guard tail >= 4 else { return }
        let slice = (n - tail)..<n
        let artifactIdx = WatchdogActivityClass.artifact.index
        let tailArtifact = slice.filter { i in
            guard i < logits.count, artifactIdx < logits[i].count else { return false }
            return logits[i][artifactIdx] >= 0.5
        }.count
        if tailArtifact * 2 >= tail { return }
        if windowDynCV > 0.85 && !setRest { return }
        let occs = slice.compactMap { motion[$0] }
        let hrs = slice.compactMap { hr[$0] }
        guard occs.count >= 3, let meanHR = average(hrs) else { return }
        let meanOcc = average(occs) ?? 0
        guard meanOcc >= 0.18 else { return }
        let peak = Int((hrs.max() ?? meanHR).rounded())
        let hrCV = cv(hrs)
        var still = 0.0, walk = 0.0, run = 0.0, ticks = 0.0
        let from = nowUnix - tail * WatchdogConfig.gridSeconds
        for s in steps where s.ts >= from && s.ts < nowUnix {
            ticks += 1
            switch s.activityClass {
            case 0: still += 1
            case 1: walk += 1
            case 2: run += 1
            default: break
            }
        }
        let samplesPerMin = family == .whoop5 ? 2.0 : 60.0
        let dens = ticks / max(1, Double(tail) * samplesPerMin)
        let cover = min(1, dens * 8)
        let dyns = imu.filter { $0.ts >= from && $0.ts < nowUnix }.compactMap(\.dynAccel)
        let mVar = variance(dyns.isEmpty ? occs : dyns)
        let mCV = cv(dyns.isEmpty ? occs : dyns)
        let features = WorkoutClassFeatures(
            durationSec: Double(tail * WatchdogConfig.gridSeconds),
            meanHR: meanHR, peakHR: peak, meanHRRPct: nil, hrCV: hrCV,
            stillFraction: ticks > 0 ? still / ticks : 0,
            walkFraction: ticks > 0 ? walk / ticks : 0,
            runFraction: ticks > 0 ? run / ticks : 0,
            tickCoverage: cover,
            motionVariance: mVar, motionCV: mCV, kcalPerMin: nil)
        let pred = WorkoutTypeClassifier.classify(features)
        guard pred.confidence >= 0.35 else { return }
        let cls: WatchdogActivityClass
        switch pred.predictedClass {
        case .walk: cls = .walk
        case .run: cls = .run
        case .strength: cls = .resistance
        case .cycle, .ski:
            if setRest || (windowDynCV > 0.70 && walk + run < ticks * 0.25) { return }
            cls = .cycleLike
        case .other: return
        }
        let w = min(0.65, pred.confidence)
        for i in slice {
            if i < logits.count, logits[i][artifactIdx] >= 0.5 { continue }
            var row = logits[i]
            for j in 0..<row.count { row[j] *= (1 - w) }
            row[cls.index] += w
            logits[i] = row
        }
    }

    /// Alternating high/low dynAccel across minutes (sets vs rest) — lift, not smooth cycle.
    private static func isSetRestCadence(_ dynMeans: [Double]) -> Bool {
        let xs = dynMeans.suffix(10)
        guard xs.count >= 6 else { return false }
        let hi = xs.filter { $0 >= 0.22 }.count
        let lo = xs.filter { $0 <= 0.10 }.count
        guard hi >= 2 && lo >= 2 else { return false }
        var flips = 0
        var prev: Bool?
        for x in xs {
            let high = x >= 0.22
            if let prev, prev != high { flips += 1 }
            prev = high
        }
        return flips >= 3
    }

    private static func average(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    private static func variance(_ xs: [Double]) -> Double {
        guard xs.count > 1, let m = average(xs) else { return 0 }
        return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)
    }

    private static func cv(_ xs: [Double]) -> Double {
        guard let m = average(xs), m > 1e-4 else { return 0 }
        return sqrt(variance(xs)) / m
    }
}
