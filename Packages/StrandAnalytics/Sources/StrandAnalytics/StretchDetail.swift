import Foundation
import WhoopProtocol

/// One slice of a stretch, at a resolution fine enough to see what changed inside it.
public struct StretchBin: Equatable, Sendable, Identifiable {
    public let start: Int
    public let end: Int
    public let avgHr: Int?
    public let minHr: Int?
    public let maxHr: Int?
    /// Mean 1 Hz gravity-vector change in g over the slice (the proxy the state timeline and the workout
    /// detector use). nil when the strap sent no gravity here.
    public let motionG: Double?
    /// Step-counter ticks over the slice. nil when the strap reported no counter here.
    public let stepTicks: Int?
    /// Share of the strap's per-second activity labels in the slice that said walk or run.
    public let locomotionShare: Double?

    public var id: Int { start }
    public var durationSeconds: Int { end - start }
}

/// What the strap recorded inside one stretch: summary numbers and a short series of slices.
public struct StretchDetail: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let binSeconds: Int
    public let bins: [StretchBin]

    public let avgHr: Int?
    public let minHr: Int?
    public let maxHr: Int?
    /// Share of the stretch's seconds that carry a valid heart-rate reading.
    public let hrCoverage: Double
    public let meanMotionG: Double?
    public let peakMotionG: Double?
    public let stepTicks: Int?
    public let locomotionShare: Double?

    public var durationSeconds: Int { end - start }
    public var hasSignal: Bool { avgHr != nil || meanMotionG != nil || stepTicks != nil }
}

public enum StretchDetailBuilder {
    /// Slice lengths worth showing, shortest first. The builder picks the shortest that keeps a stretch at or
    /// under `maxBins` slices, so a five-minute stretch reads in ten-second slices and a three-hour one in
    /// five-minute slices.
    public static let niceBinSeconds = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800]

    public static func binSeconds(forDuration seconds: Int, maxBins: Int = 40) -> Int {
        let wanted = Int((Double(max(1, seconds)) / Double(max(1, maxBins))).rounded(.up))
        return niceBinSeconds.first { $0 >= wanted } ?? niceBinSeconds[niceBinSeconds.count - 1]
    }

    /// Build the detail for `[start, end)`. The inputs may reach outside the stretch (they are clipped), and
    /// should start a couple of samples early so the first second has a previous sample to difference against.
    public static func build(start: Int, end: Int,
                             hr: [HRSample], gravity: [GravitySample], steps: [StepSample],
                             maxBins: Int = 40) -> StretchDetail {
        guard end > start else {
            return StretchDetail(start: start, end: start, binSeconds: 1, bins: [], avgHr: nil, minHr: nil,
                                 maxHr: nil, hrCoverage: 0, meanMotionG: nil, peakMotionG: nil,
                                 stepTicks: nil, locomotionShare: nil)
        }
        let n = end - start
        let size = binSeconds(forDuration: n, maxBins: maxBins)
        let count = (n + size - 1) / size

        var bpm = [Int](repeating: 0, count: n)
        for s in hr where DayStateTimeline.validHr.contains(s.bpm) && s.ts >= start && s.ts < end {
            bpm[s.ts - start] = s.bpm
        }

        var delta = [Double](repeating: .nan, count: n)
        let g = gravity.sorted { $0.ts < $1.ts }
        for (k, s) in g.enumerated() where k > 0 && s.ts >= start && s.ts < end {
            let p = g[k - 1]
            let dt = s.ts - p.ts
            guard dt >= 1, dt <= 2 else { continue }
            let dx = s.x - p.x, dy = s.y - p.y, dz = s.z - p.z
            delta[s.ts - start] = (dx * dx + dy * dy + dz * dz).squareRoot()
        }

        var hasStep = [Bool](repeating: false, count: n)
        var ticks = [Int](repeating: 0, count: n)
        var cls = [Int](repeating: -1, count: n)
        let st = steps.sorted { $0.ts < $1.ts }
        for (k, s) in st.enumerated() where s.ts >= start && s.ts < end {
            let i = s.ts - start
            hasStep[i] = true
            if let c = s.activityClass { cls[i] = c }
            guard k > 0 else { continue }
            let p = st[k - 1]
            let dt = s.ts - p.ts
            let d = (s.counter - p.counter) & 0xFFFF
            if dt >= 1, dt <= 2, d < StepsCounter.maxStepDelta { ticks[i] = d }
        }

        var bins: [StretchBin] = []
        bins.reserveCapacity(count)
        var allHrN = 0, allHrSum = 0, allLo = Int.max, allHi = 0
        var allDN = 0, allDSum = 0.0, allPeak = 0.0
        var allStepN = 0, allTicks = 0, allClassed = 0, allLoco = 0

        for b in 0..<count {
            let lo = b * size, hi = min(n, lo + size)
            var hrN = 0, hrSum = 0, bLo = Int.max, bHi = 0
            var dN = 0, dSum = 0.0, stepN = 0, tick = 0, classed = 0, loco = 0
            for i in lo..<hi {
                if bpm[i] > 0 { hrN += 1; hrSum += bpm[i]; bLo = min(bLo, bpm[i]); bHi = max(bHi, bpm[i]) }
                if !delta[i].isNaN { dN += 1; dSum += delta[i]; allPeak = max(allPeak, delta[i]) }
                if hasStep[i] { stepN += 1; tick += ticks[i] }
                if cls[i] >= 0 { classed += 1; if cls[i] >= 1 { loco += 1 } }
            }
            bins.append(StretchBin(
                start: start + lo, end: start + hi,
                avgHr: hrN > 0 ? Int((Double(hrSum) / Double(hrN)).rounded()) : nil,
                minHr: hrN > 0 ? bLo : nil, maxHr: hrN > 0 ? bHi : nil,
                motionG: dN > 0 ? dSum / Double(dN) : nil,
                stepTicks: stepN > 0 ? tick : nil,
                locomotionShare: classed > 0 ? Double(loco) / Double(classed) : nil))
            allHrN += hrN; allHrSum += hrSum
            if hrN > 0 { allLo = min(allLo, bLo); allHi = max(allHi, bHi) }
            allDN += dN; allDSum += dSum
            allStepN += stepN; allTicks += tick; allClassed += classed; allLoco += loco
        }

        return StretchDetail(
            start: start, end: end, binSeconds: size, bins: bins,
            avgHr: allHrN > 0 ? Int((Double(allHrSum) / Double(allHrN)).rounded()) : nil,
            minHr: allHrN > 0 ? allLo : nil, maxHr: allHrN > 0 ? allHi : nil,
            hrCoverage: Double(allHrN) / Double(n),
            meanMotionG: allDN > 0 ? allDSum / Double(allDN) : nil,
            peakMotionG: allDN > 0 ? allPeak : nil,
            stepTicks: allStepN > 0 ? allTicks : nil,
            locomotionShare: allClassed > 0 ? Double(allLoco) / Double(allClassed) : nil)
    }
}
