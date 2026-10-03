import Foundation
import WhoopProtocol

/// What the wearer was doing, as far as a wrist strap can tell.
///
/// There is deliberately no "sitting" or "standing": a wrist accelerometer sees the arm, not the torso, so
/// the two are indistinguishable. Both land in `.still`, and the UI says so.
public enum DayState: String, Sendable, CaseIterable, Equatable {
    case sleeping
    case offWrist
    case running
    case walking
    case workout
    case active
    case still
    case wornUnknown
    case noData
}

/// Where a segment's label came from. Shown next to each box so the wearer can judge how much to trust it.
public enum DayStateBasis: String, Sendable, Equatable {
    case sleepSession
    case wristEvent
    case noPulseSignal
    case loggedWorkout
    case strapActivityClass
    case motion
    case noMotionData
    case noRecords
}

public struct DayStateWorkout: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let sport: String
    public init(start: Int, end: Int, sport: String) {
        self.start = start; self.end = end; self.sport = sport
    }
}

public struct DayStateSpan: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

public struct DayStateSegment: Equatable, Sendable, Identifiable {
    public let state: DayState
    public let basis: DayStateBasis
    public let start: Int
    public let end: Int
    public let avgHr: Int?
    public let minHr: Int?
    public let maxHr: Int?
    /// Mean 1 Hz gravity-vector change in g, the same proxy the workout detector uses. nil with no gravity.
    public let motionG: Double?
    /// Share of the strap's per-second activity labels that said walk or run. nil when it labelled nothing.
    public let locomotionShare: Double?
    public let workoutSport: String?

    public var id: Int { start }
    public var durationSeconds: Int { end - start }

    public init(state: DayState, basis: DayStateBasis, start: Int, end: Int,
                avgHr: Int?, minHr: Int?, maxHr: Int?, motionG: Double?,
                locomotionShare: Double?, workoutSport: String?) {
        self.state = state; self.basis = basis; self.start = start; self.end = end
        self.avgHr = avgHr; self.minHr = minHr; self.maxHr = maxHr
        self.motionG = motionG; self.locomotionShare = locomotionShare
        self.workoutSport = workoutSport
    }
}

/// Builds a one-day state timeline from stored strap data, in whole minutes.
///
/// Every label is derived from a real signal and carries its `basis`. Precedence per minute:
/// logged sleep, explicit wrist-off span, no pulse (strap still recording, so likely off wrist), logged
/// workout, the strap's own walk/run labels, then gravity motion. Runs shorter than `minRunMinutes` are
/// folded into their longer neighbour so one stray minute does not fragment the day.
public enum DayStateTimeline {
    public static let binSeconds = 60
    public static let minHrSecondsPerBin = 6
    public static let minRunMinutes = 2
    /// Seconds of walk/run strap labels in a minute before the minute counts as walking or running. Real
    /// indoor walking arrives as scattered bursts (a day on the author's strap: 80 bursts, mostly 10 to 19 s
    /// per minute), so a stricter gate would call nearly all of it still.
    public static let minLocomotionSecondsPerBin = 10
    /// Mean gravity delta above which a minute counts as moving. Matches `WorkoutDetector`'s threshold.
    public static let movingDeltaG = 0.20
    public static let validHr = 30...220

    struct Bin {
        var hrN = 0, hrSum = 0, hrMin = Int.max, hrMax = 0
        var gravN = 0
        var deltaN = 0
        var deltaSum = 0.0
        var stepN = 0, stillN = 0, walkN = 0, runN = 0
    }

    public static func build(dayStart: Int,
                             dayEnd: Int,
                             hr: [HRSample],
                             gravity: [GravitySample],
                             steps: [StepSample],
                             sleep: [DayStateSpan],
                             workouts: [DayStateWorkout],
                             offWrist: [DayStateSpan] = []) -> [DayStateSegment] {
        guard dayEnd > dayStart else { return [] }
        let count = (dayEnd - dayStart + binSeconds - 1) / binSeconds
        var bins = [Bin](repeating: Bin(), count: count)

        func index(_ ts: Int) -> Int? {
            guard ts >= dayStart, ts < dayEnd else { return nil }
            return (ts - dayStart) / binSeconds
        }

        for s in hr where validHr.contains(s.bpm) {
            guard let i = index(s.ts) else { continue }
            bins[i].hrN += 1
            bins[i].hrSum += s.bpm
            bins[i].hrMin = min(bins[i].hrMin, s.bpm)
            bins[i].hrMax = max(bins[i].hrMax, s.bpm)
        }

        let g = gravity.sorted { $0.ts < $1.ts }
        for (k, s) in g.enumerated() {
            guard let i = index(s.ts) else { continue }
            bins[i].gravN += 1
            guard k > 0 else { continue }
            let p = g[k - 1]
            let dt = s.ts - p.ts
            guard dt >= 1, dt <= 2 else { continue }
            let dx = s.x - p.x, dy = s.y - p.y, dz = s.z - p.z
            bins[i].deltaSum += (dx * dx + dy * dy + dz * dz).squareRoot()
            bins[i].deltaN += 1
        }

        for s in steps {
            guard let i = index(s.ts) else { continue }
            bins[i].stepN += 1
            switch s.activityClass {
            case 0: bins[i].stillN += 1
            case 1: bins[i].walkN += 1
            case 2: bins[i].runN += 1
            default: break
            }
        }

        var labels: [(DayState, DayStateBasis, String?)] = []
        labels.reserveCapacity(count)
        for i in 0..<count {
            let mid = dayStart + i * binSeconds + binSeconds / 2
            labels.append(classify(bin: bins[i], mid: mid, sleep: sleep, workouts: workouts, offWrist: offWrist))
        }

        let runs = foldShortRuns(labels.map { Key(state: $0.0, basis: $0.1, sport: $0.2) })
        return segments(from: runs, bins: bins, rawStates: labels.map(\.0), dayStart: dayStart, dayEnd: dayEnd)
    }

    static func classify(bin: Bin, mid: Int, sleep: [DayStateSpan], workouts: [DayStateWorkout],
                         offWrist: [DayStateSpan]) -> (DayState, DayStateBasis, String?) {
        if sleep.contains(where: { mid >= $0.start && mid < $0.end }) {
            return (.sleeping, .sleepSession, nil)
        }
        if offWrist.contains(where: { mid >= $0.start && mid < $0.end }) {
            return (.offWrist, .wristEvent, nil)
        }
        if bin.hrN < minHrSecondsPerBin {
            return (bin.gravN + bin.stepN > 0) ? (.offWrist, .noPulseSignal, nil) : (.noData, .noRecords, nil)
        }
        if let w = workouts.first(where: { mid >= $0.start && mid < $0.end }) {
            let sport = w.sport.lowercased()
            if sport.contains("run") || sport.contains("jog") { return (.running, .loggedWorkout, w.sport) }
            if sport.contains("walk") || sport.contains("hik") { return (.walking, .loggedWorkout, w.sport) }
            return (.workout, .loggedWorkout, w.sport)
        }
        if bin.runN >= minLocomotionSecondsPerBin { return (.running, .strapActivityClass, nil) }
        if bin.walkN + bin.runN >= minLocomotionSecondsPerBin { return (.walking, .strapActivityClass, nil) }
        guard bin.deltaN > 0 else { return (.wornUnknown, .noMotionData, nil) }
        let mean = bin.deltaSum / Double(bin.deltaN)
        return (mean >= movingDeltaG ? .active : .still, .motion, nil)
    }

    struct Key: Equatable {
        let state: DayState
        let basis: DayStateBasis
        let sport: String?

        /// Adjacent minutes merge on state and sport; the first minute's basis stands for the run.
        static func == (a: Key, b: Key) -> Bool { a.state == b.state && a.sport == b.sport }
    }

    struct Run {
        var key: Key
        var startBin: Int
        var length: Int
    }

    static func foldShortRuns(_ keys: [Key]) -> [Run] {
        var runs: [Run] = []
        for (i, k) in keys.enumerated() {
            if var last = runs.last, last.key == k {
                last.length += 1
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(key: k, startBin: i, length: 1))
            }
        }
        var changed = true
        while changed, runs.count > 1 {
            changed = false
            guard let shortIdx = runs.indices
                .filter({ runs[$0].length < minRunMinutes && runs[$0].key.state != .sleeping })
                .min(by: { runs[$0].length < runs[$1].length }) else { break }
            let prev = shortIdx > 0 ? shortIdx - 1 : nil
            let next = shortIdx + 1 < runs.count ? shortIdx + 1 : nil
            let target: Int
            switch (prev, next) {
            case let (p?, n?): target = runs[n].length > runs[p].length ? n : p
            case let (p?, nil): target = p
            case let (nil, n?): target = n
            default: return runs
            }
            let absorbed = runs[shortIdx]
            runs[target].length += absorbed.length
            runs[target].startBin = min(runs[target].startBin, absorbed.startBin)
            runs.remove(at: shortIdx)
            var merged: [Run] = []
            for r in runs {
                if var last = merged.last, last.key == r.key {
                    last.length += r.length
                    merged[merged.count - 1] = last
                } else {
                    merged.append(r)
                }
            }
            runs = merged
            changed = true
        }
        return runs
    }

    /// Stats come from the minutes that earned the run's label. Minutes folded in from a neighbour set the
    /// run's edges but would otherwise leak their heart rate into, say, an off-wrist box.
    static func segments(from runs: [Run], bins: [Bin], rawStates: [DayState],
                         dayStart: Int, dayEnd: Int) -> [DayStateSegment] {
        runs.map { run in
            let range = run.startBin..<(run.startBin + run.length)
            let own = range.filter { rawStates[$0] == run.key.state }
            let slice = (own.isEmpty ? Array(range) : own).map { bins[$0] }
            let hrN = slice.reduce(0) { $0 + $1.hrN }
            let hrSum = slice.reduce(0) { $0 + $1.hrSum }
            let lo = slice.filter { $0.hrN > 0 }.map(\.hrMin).min()
            let hi = slice.filter { $0.hrN > 0 }.map(\.hrMax).max()
            let dN = slice.reduce(0) { $0 + $1.deltaN }
            let dSum = slice.reduce(0.0) { $0 + $1.deltaSum }
            let classed = slice.reduce(0) { $0 + $1.stillN + $1.walkN + $1.runN }
            let loco = slice.reduce(0) { $0 + $1.walkN + $1.runN }
            let start = dayStart + run.startBin * binSeconds
            let end = min(dayEnd, dayStart + (run.startBin + run.length) * binSeconds)
            return DayStateSegment(
                state: run.key.state, basis: run.key.basis, start: start, end: end,
                avgHr: hrN > 0 ? Int((Double(hrSum) / Double(hrN)).rounded()) : nil,
                minHr: lo, maxHr: hi,
                motionG: dN > 0 ? dSum / Double(dN) : nil,
                locomotionShare: classed > 0 ? Double(loco) / Double(classed) : nil,
                workoutSport: run.key.sport)
        }
    }

    /// Total seconds per state, for the summary tiles.
    public static func totals(_ segments: [DayStateSegment]) -> [DayState: Int] {
        segments.reduce(into: [:]) { $0[$1.state, default: 0] += $1.durationSeconds }
    }
}
