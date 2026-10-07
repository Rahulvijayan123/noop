import Foundation

/// ElderNet's per-window gait reading as the server stores it (`gait-windows-1`): every `w`-second window on an
/// `h`-second hop, with the gait probability and, on detected gait, speed, cadence, stride, regularity and steps.
public struct GaitWindowColumns: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var start: Int
        public var gaitProbability: Double
        public var isGait: Bool
        public var speedMps: Double?
        public var cadenceSpm: Double?
        public var strideM: Double?
        /// 0...1.
        public var regularity: Double?
        public var steps: Double?
        /// Too still to be walking; the model was not run on it.
        public var prefiltered = false
    }

    public var windowSeconds: Int
    public var hopSeconds: Int
    public var windows: [Window]

    public init(windowSeconds: Int, hopSeconds: Int, windows: [Window]) {
        self.windowSeconds = windowSeconds; self.hopSeconds = hopSeconds; self.windows = windows
    }

    /// nil for anything that is not a well-formed `gait-windows-1` object.
    public init?(_ object: Any?) {
        guard let o = object as? [String: Any], o["format"] as? String == "gait-windows-1",
              let n = (o["n"] as? NSNumber)?.intValue, let w = (o["w"] as? NSNumber)?.intValue,
              let h = (o["h"] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        func column(_ key: String) -> [Int]? {
            guard let a = o[key] as? [Any], a.count == n else { return nil }
            let ints = a.compactMap { ($0 as? NSNumber)?.intValue }
            return ints.count == n ? ints : nil
        }
        guard let ds = column("ds"), let gp = column("gp"), let g = column("g"), let sp = column("sp"),
              let cad = column("cad"), let st = column("st"), let rg = column("rg"), let stp = column("stp")
        else { return nil }
        let pf = column("pf")
        func value(_ x: Int, _ scale: Double) -> Double? { x < 0 ? nil : Double(x) / scale }
        var out: [Window] = []
        out.reserveCapacity(n)
        if n > 0 {
            guard var t = (o["s0"] as? NSNumber)?.intValue else { return nil }
            for k in 0..<n {
                t += ds[k]
                out.append(Window(start: t, gaitProbability: Double(gp[k]) / 1000, isGait: g[k] == 1,
                                  speedMps: value(sp[k], 100), cadenceSpm: value(cad[k], 1),
                                  strideM: value(st[k], 100), regularity: value(rg[k], 100),
                                  steps: value(stp[k], 10), prefiltered: pf?[k] == 1))
            }
        }
        self.init(windowSeconds: w, hopSeconds: h, windows: out)
    }

    /// The windows that END inside `[from, to)`, as the activity decoder reads them.
    public func trackWindows(from: Int, to: Int) -> [GaitQualityWindow] {
        windows.compactMap { w in
            let end = w.start + windowSeconds
            guard end >= from, end < to else { return nil }
            return GaitQualityWindow(startTs: w.start, endTs: end, gaitProb: w.gaitProbability, isGait: w.isGait,
                                     prefiltered: w.prefiltered, speedMps: w.speedMps, cadenceSpm: w.cadenceSpm,
                                     strideM: w.strideM, regularity: w.regularity, steps: w.steps)
        }
    }
}

/// What the walking card shows for one stretch of time. The server's metric explanations read a day the same way
/// (Tools/MetricInsight/src/nara_metric_insight/gait.py, pinned by GaitServerMirrorTests).
public struct WalkingDayReading: Equatable, Sendable {
    public struct Bout: Equatable, Sendable, Identifiable {
        public var start: Int
        public var end: Int
        public var cadenceSpm: Double?
        public var speedMps: Double?
        public var steps: Double
        public var id: Int { start }
        public var seconds: Int { end - start }
    }

    public var walkingSeconds: Int
    public var briskSeconds: Int
    public var steps: Double?
    public var cadenceSpm: Double?
    public var speedMps: Double?
    public var strideM: Double?
    public var regularity: Double?
    /// Walks of at least `minBoutSeconds`, in time order.
    public var bouts: [Bout]
    /// Windows the model scored at all (pre-filtered still windows included), so "no walking" can be told from
    /// "no data".
    public var assessedWindows: Int
    /// Walking seconds by cadence band (`cadenceBands`); windows without a cadence are not counted.
    public var cadenceBandSeconds: [Int]
    /// Walking seconds in each hour from `from` (index 0 is the first hour).
    public var hourlySeconds: [Int]
    /// The median of the walks' own speeds: the pace this wearer usually walks at, steadier than the all-window
    /// mean because short shuffles do not pull it down.
    public var typicalSpeedMps: Double?

    /// Lower bounds (steps/min) of the cadence bands: strolling, steady, brisk, fast.
    public static let cadenceBands: [Double] = [0, 80, 100, 120]

    /// Brisk walking, the usual moderate-intensity cadence threshold for adults.
    public static let briskCadenceSpm = 100.0
    public static let minBoutSeconds = 60
    /// Gaps this short inside a walk (a pause at a door) do not split it.
    public static let boutMergeGapSeconds = 15

    public var isEmpty: Bool { walkingSeconds == 0 }

    /// The windows that START inside `[from, to)` across `days`, read as one stretch. Overlapping windows each
    /// own `hop` seconds and `hop / window` of their steps, as the server's own day summary does.
    public init(days: [GaitWindowColumns], from: Int, to: Int) {
        var walking = 0, brisk = 0, assessed = 0
        var bands = [Int](repeating: 0, count: Self.cadenceBands.count)
        var hourly = [Int](repeating: 0, count: max(1, (to - from + 3_599) / 3_600))
        var steps = 0.0, stepWindows = 0
        var sums: [Double] = [0, 0, 0, 0], counts: [Int] = [0, 0, 0, 0]
        var bouts: [Bout] = []
        var open: (start: Int, end: Int, cad: Double, cadN: Int, sp: Double, spN: Int, steps: Double)?

        func close() {
            guard let b = open else { return }
            open = nil
            guard b.end - b.start >= Self.minBoutSeconds else { return }
            bouts.append(Bout(start: b.start, end: b.end, cadenceSpm: b.cadN > 0 ? b.cad / Double(b.cadN) : nil,
                              speedMps: b.spN > 0 ? b.sp / Double(b.spN) : nil, steps: b.steps))
        }

        let all = days.flatMap { d in d.windows.map { (d.hopSeconds, d.windowSeconds, $0) } }
            .filter { $0.2.start >= from && $0.2.start < to }
            .sorted { $0.2.start < $1.2.start }
        var lastStart: Int?
        for (hop, width, w) in all {
            if w.start == lastStart { continue }
            lastStart = w.start
            assessed += 1
            guard w.isGait else { continue }
            walking += hop
            if let c = w.cadenceSpm, c >= Self.briskCadenceSpm { brisk += hop }
            if let c = w.cadenceSpm, let band = Self.cadenceBands.lastIndex(where: { c >= $0 }) { bands[band] += hop }
            hourly[min(hourly.count - 1, max(0, (w.start - from) / 3_600))] += hop
            let share = Double(hop) / Double(width)
            let stepShare = (w.steps ?? 0) * share
            if w.steps != nil { steps += stepShare; stepWindows += 1 }
            for (i, v) in [w.cadenceSpm, w.speedMps, w.strideM, w.regularity].enumerated() {
                if let v { sums[i] += v; counts[i] += 1 }
            }
            let end = w.start + hop
            if var b = open, w.start - b.end <= Self.boutMergeGapSeconds {
                b.end = end; b.steps += stepShare
                if let c = w.cadenceSpm { b.cad += c; b.cadN += 1 }
                if let s = w.speedMps { b.sp += s; b.spN += 1 }
                open = b
            } else {
                close()
                open = (w.start, end, w.cadenceSpm ?? 0, w.cadenceSpm == nil ? 0 : 1,
                        w.speedMps ?? 0, w.speedMps == nil ? 0 : 1, stepShare)
            }
        }
        close()
        func mean(_ i: Int) -> Double? { counts[i] > 0 ? sums[i] / Double(counts[i]) : nil }
        self.walkingSeconds = walking
        self.briskSeconds = brisk
        self.steps = stepWindows > 0 ? steps : nil
        self.cadenceSpm = mean(0)
        self.speedMps = mean(1)
        self.strideM = mean(2)
        self.regularity = mean(3)
        self.bouts = bouts
        self.assessedWindows = assessed
        self.cadenceBandSeconds = bands
        self.hourlySeconds = hourly
        let speeds = bouts.compactMap(\.speedMps).sorted()
        self.typicalSpeedMps = speeds.isEmpty ? nil
            : speeds.count % 2 == 1 ? speeds[speeds.count / 2] : (speeds[speeds.count / 2 - 1] + speeds[speeds.count / 2]) / 2
    }
}
