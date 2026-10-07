import Foundation
import WhoopProtocol

/// WHOOP sleep interval. Col 19 is overlap with this span, never clock hour.
public struct WatchdogSleepInterval: Equatable, Sendable {
    public var startUnix: Int
    public var endUnix: Int
    public init(startUnix: Int, endUnix: Int) {
        self.startUnix = startUnix
        self.endUnix = endUnix
    }

    public func contains(_ unix: Int) -> Bool {
        unix >= startUnix && unix < endUnix
    }

    public func overlaps(start: Int, end: Int) -> Bool {
        start < endUnix && end > startUnix
    }
}

/// 20-column minute activity block. Core ML may consume this; effort lookup is not the physiology.
public enum WatchdogActivityFeatures: Sendable {
    public static let width = 20

    public static func build(window: WatchdogWindow,
                             imu: [WatchdogIMUSample]? = nil,
                             steps: [StepSample]? = nil,
                             lastWorkoutEndUnix: Int? = nil,
                             sleepIntervals: [WatchdogSleepInterval]? = nil) -> [[Double]] {
        let n = window.seqLen
        guard n > 0 else { return [] }
        let imu = imu ?? window.imu
        let steps = steps ?? window.steps
        let lastWorkoutEndUnix = lastWorkoutEndUnix ?? window.lastWorkoutEndUnix
        let sleepIntervals = sleepIntervals ?? window.sleepIntervals
        let span = max(window.nowUnix - window.startUnix, 1)
        let minuteSeconds = max(span / n, 1)
        func minuteIndex(_ ts: Int) -> Int {
            min(n - 1, max(0, ((ts - window.startUnix) * n) / span))
        }
        var dynSum = Array(repeating: 0.0, count: n)
        var dynSq = Array(repeating: 0.0, count: n)
        var dynN = Array(repeating: 0, count: n)
        var grav = Array(repeating: 0.0, count: n)
        var gravN = Array(repeating: 0, count: n)
        for g in imu where g.ts >= window.startUnix && g.ts < window.nowUnix {
            let i = minuteIndex(g.ts)
            let mag = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            grav[i] += abs(mag - 1)
            gravN[i] += 1
            if let d = g.dynAccel {
                dynSum[i] += d
                dynSq[i] += d * d
                dynN[i] += 1
            }
        }
        var still = Array(repeating: 0.0, count: n)
        var walk = Array(repeating: 0.0, count: n)
        var run = Array(repeating: 0.0, count: n)
        var stepN = Array(repeating: 0.0, count: n)
        for s in steps where s.ts >= window.startUnix && s.ts < window.nowUnix {
            let i = minuteIndex(s.ts)
            stepN[i] += 1
            switch s.activityClass {
            case 0: still[i] += 1
            case 1: walk[i] += 1
            case 2: run[i] += 1
            default: break
            }
        }
        let cal = Calendar.current
        return (0..<n).map { i in
            var row = Array(repeating: 0.0, count: width)
            let logits = i < window.activityLogits.count ? window.activityLogits[i] : []
            for k in 0..<min(8, logits.count) { row[k] = logits[k] }
            if let measured = i < window.motion.count ? window.motion[i] : nil {
                row[8] = max(0, min(1, measured))
            }
            let dn = Double(dynN[i])
            if dn > 0 {
                let dMean = dynSum[i] / dn
                row[9] = min(4, max(0, dMean))
                if dn > 1 {
                    let v = max(0, dynSq[i] / dn - dMean * dMean)
                    row[10] = min(4, sqrt(v))
                }
            }
            if gravN[i] > 0 {
                row[11] = min(1, grav[i] / Double(gravN[i]))
            }
            if stepN[i] > 0 {
                row[12] = still[i] / stepN[i]
                row[13] = walk[i] / stepN[i]
                row[14] = run[i] / stepN[i]
            }
            row[15] = i < window.autoWorkoutOverlap.count ? (window.autoWorkoutOverlap[i] >= 0.5 ? 1 : 0) : 0
            if lastWorkoutEndUnix > 0 {
                row[16] = min(2, max(0, Double(window.nowUnix - lastWorkoutEndUnix) / 3600.0))
            }
            let t0 = window.startUnix + i * minuteSeconds
            let mid = t0 + minuteSeconds / 2
            let hour = Double(cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(mid))))
            let ang = 2 * Double.pi * hour / 24
            row[17] = sin(ang)
            row[18] = cos(ang)
            row[19] = sleepIntervals.contains(where: { $0.overlaps(start: t0, end: t0 + minuteSeconds) }) ? 1 : 0
            return row
        }
    }

    public static func occupancyDebug(from features: [[Double]]) -> [Double] {
        features.map { row in
            guard row.count > 8 else { return 0 }
            return max(0, min(1, row[8]))
        }
    }

    public static func stepLocomotion(_ row: [Double]) -> Double {
        guard row.count > 14 else { return 0 }
        return max(0, row[13]) + max(0, row[14])
    }

    public static func sleepBit(_ row: [Double]) -> Double {
        guard row.count > 19 else { return 0 }
        return row[19] >= 0.5 ? 1 : 0
    }

    public static func usesRawActivity(_ features: [[Double]]) -> Bool {
        features.contains { row in
            guard row.count > 19 else { return false }
            return row[9] > 0 || row[10] > 0 || row[11] > 0
                || row[12] + row[13] + row[14] > 0
                || row[16] > 0 || row[19] > 0
        }
    }

    /// Frozen physiology occupancy from the 20-vector. Not the class lookup table.
    public static func priorOccupancy(_ row: [Double]) -> Double {
        guard row.count > 19 else { return 0 }
        if row[19] >= 0.5 { return 0 }
        let walk = max(0, min(1, row.count > 13 ? row[13] : 0))
        let run = max(0, min(1, row.count > 14 ? row[14] : 0))
        let dyn = max(0, min(1, (row.count > 9 ? row[9] : 0) / 4))
        let mag = max(0, min(1, row.count > 8 ? row[8] : 0))
        var classOcc = 0.0
        if row.count >= 8 {
            let labels = WatchdogActivityClass.allCases
            for (k, cls) in labels.enumerated() where k < 8 {
                let w = max(0, row[k])
                switch cls {
                case .walk: classOcc += w * 0.32
                case .run: classOcc += w * 0.85
                case .cycleLike: classOcc += w * 0.55
                case .resistance: classOcc += w * 0.42
                default: break
                }
            }
        }
        let steps = walk * 0.32 + run * 0.85
        return max(0, min(1, max(classOcc, max(steps, max(dyn, mag * 0.15)))))
    }
}
