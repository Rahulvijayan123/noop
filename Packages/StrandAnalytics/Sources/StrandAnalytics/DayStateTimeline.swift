import Foundation
import WhoopProtocol

/// What the wearer was doing, as far as a wrist strap can tell.
///
/// There is deliberately no "sitting" or "standing": a wrist accelerometer sees the arm, not the torso, so
/// the two are indistinguishable. Both land in `.still`, and the UI says so.
public enum DayState: String, Sendable, CaseIterable, Equatable, Codable {
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
public enum DayStateBasis: String, Sendable, Equatable, Codable {
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

    /// A night's sleep as spans: the non-wake stretches of its staged `[{start, end, stage}]` segments,
    /// clipped to the night's `[start, end)` and joined where they touch. Wake inside the night, lying awake
    /// before sleep came included, is left out. A night with no segment timeline (an imported
    /// `{stage: minutes}` total, or nothing) is asleep for its whole window, the only claim it carries.
    public static func asleep(stagesJSON: String?, start: Int, end: Int) -> [DayStateSpan] {
        guard end > start else { return [] }
        guard let json = stagesJSON, let data = json.data(using: .utf8),
              let segs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !segs.isEmpty else {
            return [DayStateSpan(start: start, end: end)]
        }
        let stages = segs.compactMap { seg -> StageSegment? in
            guard let s = (seg["start"] as? NSNumber)?.intValue, let e = (seg["end"] as? NSNumber)?.intValue,
                  let stage = seg["stage"] as? String else { return nil }
            return StageSegment(start: s, end: e, stage: stage)
        }
        return asleep(stages: stages, start: start, end: end)
    }

    /// `asleep(stagesJSON:start:end:)` over decoded segments (a night the caller has just staged).
    public static func asleep(stages: [StageSegment], start: Int, end: Int) -> [DayStateSpan] {
        guard end > start else { return [] }
        var timed: [(Int, Int, Bool)] = []
        for seg in stages {
            let lo = max(seg.start, start), hi = min(seg.end, end)
            if hi > lo { timed.append((lo, hi, seg.stage != "wake" && seg.stage != "awake")) }
        }
        guard !timed.isEmpty else { return [DayStateSpan(start: start, end: end)] }
        var out: [DayStateSpan] = []
        for (lo, hi, asleep) in timed.sorted(by: { $0.0 < $1.0 }) where asleep {
            if let last = out.last, lo <= last.end {
                out[out.count - 1] = DayStateSpan(start: last.start, end: max(last.end, hi))
            } else {
                out.append(DayStateSpan(start: lo, end: hi))
            }
        }
        return out
    }
}

public struct DayStateSegment: Equatable, Sendable, Identifiable, Codable {
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
    /// Step-counter ticks over the stretch, when the strap reported a counter. About two a second is a walk.
    public let stepTicks: Int?
    public let workoutSport: String?

    public var id: Int { start }
    public var durationSeconds: Int { end - start }

    public init(state: DayState, basis: DayStateBasis, start: Int, end: Int,
                avgHr: Int?, minHr: Int?, maxHr: Int?, motionG: Double?,
                locomotionShare: Double?, stepTicks: Int? = nil, workoutSport: String?) {
        self.state = state; self.basis = basis; self.start = start; self.end = end
        self.avgHr = avgHr; self.minHr = minHr; self.maxHr = maxHr
        self.motionG = motionG; self.locomotionShare = locomotionShare; self.stepTicks = stepTicks
        self.workoutSport = workoutSport
    }
}

/// Builds a one-day state timeline from stored strap data.
///
/// Every label is derived from a real signal and carries its `basis`. Two layers:
///
/// 1. Minutes. Precedence per minute: logged sleep, explicit wrist-off span, no pulse (strap still recording,
///    so likely off wrist), logged workout, then gravity motion (moving or still). Runs shorter than
///    `minRunMinutes` are folded into their longer neighbour so one stray minute does not fragment the day.
/// 2. Seconds. The strap labels each reading still, walk or run, and its step counter ticks about twice a
///    second while walking. Stretches of walk or run labels backed by counter ticks become bursts as short as
///    `minBurstSeconds`, laid over the still and moving minutes. Sleep, off wrist and logged workouts are
///    never split.
public enum DayStateTimeline {
    public static let binSeconds = 60
    public static let minHrSecondsPerBin = 6
    public static let minRunMinutes = 2
    /// Mean gravity delta above which a minute counts as moving. Matches `WorkoutDetector`'s threshold.
    public static let movingDeltaG = 0.20
    public static let validHr = 30...220

    /// Non-walking seconds a burst may bridge. The strap's label drops out for a second or two mid-walk.
    public static let burstBridgeSeconds = 8
    public static let minBurstSeconds = 10
    /// A burst needs the step counter to back the label: at least this many ticks per second on average.
    public static let minBurstTicksPerSecond = 0.5
    /// After bursts are laid over the minutes, any run shorter than this folds into its neighbour.
    public static let minRunSeconds = 10

    struct Bin {
        var hrN = 0
        var gravN = 0
        var deltaN = 0
        var deltaSum = 0.0
        var stepN = 0
    }

    /// One slot per second of the day.
    struct Seconds {
        var bpm: [Int]
        var delta: [Double]
        var cls: [Int]
        var ticks: [Int]
        var hasGravity: [Bool]
        var hasStep: [Bool]
        var count: Int { bpm.count }
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
        let n = dayEnd - dayStart
        var sec = Seconds(bpm: [Int](repeating: 0, count: n),
                          delta: [Double](repeating: .nan, count: n),
                          cls: [Int](repeating: -1, count: n),
                          ticks: [Int](repeating: 0, count: n),
                          hasGravity: [Bool](repeating: false, count: n),
                          hasStep: [Bool](repeating: false, count: n))

        for s in hr where validHr.contains(s.bpm) && s.ts >= dayStart && s.ts < dayEnd {
            sec.bpm[s.ts - dayStart] = s.bpm
        }

        let g = gravity.sorted { $0.ts < $1.ts }
        for (k, s) in g.enumerated() where s.ts >= dayStart && s.ts < dayEnd {
            let i = s.ts - dayStart
            sec.hasGravity[i] = true
            guard k > 0 else { continue }
            let p = g[k - 1]
            let dt = s.ts - p.ts
            guard dt >= 1, dt <= 2 else { continue }
            let dx = s.x - p.x, dy = s.y - p.y, dz = s.z - p.z
            sec.delta[i] = (dx * dx + dy * dy + dz * dz).squareRoot()
        }

        let st = steps.sorted { $0.ts < $1.ts }
        for (k, s) in st.enumerated() where s.ts >= dayStart && s.ts < dayEnd {
            let i = s.ts - dayStart
            sec.hasStep[i] = true
            if let c = s.activityClass { sec.cls[i] = c }
            guard k > 0 else { continue }
            let p = st[k - 1]
            let dt = s.ts - p.ts
            let d = (s.counter - p.counter) & 0xFFFF
            if dt >= 1, dt <= 2, d < StepsCounter.maxStepDelta { sec.ticks[i] = d }
        }

        let minutes = (n + binSeconds - 1) / binSeconds
        var bins = [Bin](repeating: Bin(), count: minutes)
        for i in 0..<n {
            let b = i / binSeconds
            if sec.bpm[i] > 0 { bins[b].hrN += 1 }
            if sec.hasGravity[i] { bins[b].gravN += 1 }
            if sec.hasStep[i] { bins[b].stepN += 1 }
            if !sec.delta[i].isNaN { bins[b].deltaN += 1; bins[b].deltaSum += sec.delta[i] }
        }

        var minuteKeys: [Key] = []
        minuteKeys.reserveCapacity(minutes)
        for b in 0..<minutes {
            let mid = dayStart + b * binSeconds + binSeconds / 2
            let c = classify(bin: bins[b], mid: mid, sleep: sleep, workouts: workouts, offWrist: offWrist)
            minuteKeys.append(Key(state: c.0, basis: c.1, sport: c.2))
        }

        let minuteRuns = foldShortRuns(minuteKeys, minLength: minRunMinutes)
        var secKey = [Key](repeating: minuteKeys[0], count: n)
        for run in minuteRuns {
            let lo = run.start * binSeconds
            let hi = min(n, (run.start + run.length) * binSeconds)
            for i in lo..<hi { secKey[i] = run.key }
        }
        var earned = (0..<n).map { minuteKeys[$0 / binSeconds] }

        for burst in bursts(sec) {
            let key = Key(state: burst.running ? .running : .walking, basis: .strapActivityClass, sport: nil)
            for i in burst.start..<burst.end where overlayable.contains(secKey[i].state) {
                secKey[i] = key
                earned[i] = key
            }
        }

        let runs = foldShortRuns(secKey, minLength: minRunSeconds)
        return runs.map { segment($0, sec: sec, earned: earned, dayStart: dayStart) }
    }

    /// States a walk or run burst may replace. Sleep, off wrist, no data and logged workouts stand.
    static let overlayable: Set<DayState> = [.still, .active, .wornUnknown]

    struct Burst {
        let start: Int
        let end: Int
        let running: Bool
    }

    /// Stretches of one walk or run label, bridged across short dropouts and backed by step-counter ticks.
    static func bursts(_ sec: Seconds) -> [Burst] {
        var out: [Burst] = []
        let n = sec.count
        var i = 0
        while i < n {
            let c = sec.cls[i]
            guard c == 1 || c == 2 else { i += 1; continue }
            var last = i
            var k = i + 1
            while k < n, k - last <= burstBridgeSeconds + 1 {
                if sec.cls[k] == c {
                    last = k
                } else if sec.cls[k] == 1 || sec.cls[k] == 2 {
                    break
                }
                k += 1
            }
            let end = last + 1
            let duration = end - i
            let ticks = sec.ticks[i..<end].reduce(0, +)
            if duration >= minBurstSeconds, Double(ticks) >= minBurstTicksPerSecond * Double(duration) {
                out.append(Burst(start: i, end: end, running: c == 2))
            }
            i = end
        }
        return out
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
        guard bin.deltaN > 0 else { return (.wornUnknown, .noMotionData, nil) }
        let mean = bin.deltaSum / Double(bin.deltaN)
        return (mean >= movingDeltaG ? .active : .still, .motion, nil)
    }

    struct Key: Equatable {
        let state: DayState
        let basis: DayStateBasis
        let sport: String?

        /// Adjacent slots merge on state and sport; the first slot's basis stands for the run.
        static func == (a: Key, b: Key) -> Bool { a.state == b.state && a.sport == b.sport }
    }

    struct Run {
        var key: Key
        var start: Int
        var length: Int
    }

    /// Run-length encode `keys`, then fold every run shorter than `minLength` (sleep excepted) into its
    /// longer neighbour, shortest first, until none remain.
    static func foldShortRuns(_ keys: [Key], minLength: Int) -> [Run] {
        var runs: [Run] = []
        for (i, k) in keys.enumerated() {
            if var last = runs.last, last.key == k {
                last.length += 1
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(key: k, start: i, length: 1))
            }
        }
        while runs.count > 1 {
            guard let shortIdx = runs.indices
                .filter({ runs[$0].length < minLength && runs[$0].key.state != .sleeping })
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
            runs[target].start = min(runs[target].start, absorbed.start)
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
        }
        return runs
    }

    /// Stats come from the seconds that earned the run's label. Seconds folded in from a neighbour set the
    /// run's edges but would otherwise leak their heart rate into, say, an off-wrist box.
    static func segment(_ run: Run, sec: Seconds, earned: [Key], dayStart: Int) -> DayStateSegment {
        let range = run.start..<(run.start + run.length)
        let own = range.filter { earned[$0].state == run.key.state }
        let idx = own.isEmpty ? Array(range) : own
        var hrN = 0, hrSum = 0, lo = Int.max, hi = 0
        var dN = 0, dSum = 0.0, classed = 0, loco = 0, ticks = 0, stepN = 0
        for i in idx {
            let b = sec.bpm[i]
            if b > 0 { hrN += 1; hrSum += b; lo = min(lo, b); hi = max(hi, b) }
            if !sec.delta[i].isNaN { dN += 1; dSum += sec.delta[i] }
            if sec.cls[i] >= 0 {
                classed += 1
                if sec.cls[i] >= 1 { loco += 1 }
            }
            if sec.hasStep[i] { stepN += 1; ticks += sec.ticks[i] }
        }
        return DayStateSegment(
            state: run.key.state, basis: run.key.basis,
            start: dayStart + run.start, end: dayStart + run.start + run.length,
            avgHr: hrN > 0 ? Int((Double(hrSum) / Double(hrN)).rounded()) : nil,
            minHr: hrN > 0 ? lo : nil, maxHr: hrN > 0 ? hi : nil,
            motionG: dN > 0 ? dSum / Double(dN) : nil,
            locomotionShare: classed > 0 ? Double(loco) / Double(classed) : nil,
            stepTicks: stepN > 0 ? ticks : nil,
            workoutSport: run.key.sport)
    }

    /// Total seconds per state, for the summary tiles.
    public static func totals(_ segments: [DayStateSegment]) -> [DayState: Int] {
        segments.reduce(into: [:]) { $0[$1.state, default: 0] += $1.durationSeconds }
    }
}
