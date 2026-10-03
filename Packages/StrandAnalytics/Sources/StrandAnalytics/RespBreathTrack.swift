import Foundation
import WhoopProtocol

/// Breath-by-breath respiratory track from the R-R stream, for a rate reported far more often than the
/// nightly one.
///
/// `SleepStager.respRateFromRR` answers "what was the rate over this session": it works in 300 s windows and
/// throws away any window that contains a wall-clock splice, which is the right call for one nightly number
/// and the wrong one for a daytime stream, where the strap's R-R arrives in runs of a minute or two between
/// dropouts. On a real day that rejects almost every window. This keeps the same signal chain (4 Hz
/// tachogram, 8 s moving-mean detrend, peaks at least 2.5 s apart, 6-24 breaths/min band) but runs it
/// per CONTINUOUS RUN instead, so every stretch of unbroken beats contributes whatever breaths it holds and
/// a dropout costs only the seconds it covers. The breaths are then pooled over whatever window the caller
/// asks about (`estimate`), which is how a once-a-minute value is produced.
///
/// The nightly kernel is untouched: the stored nightly rate and its parity with the Android port do not
/// move. The two agree in kind (RSA peak-to-peak median) but not to the decimal, since the windows differ.
public struct RespBreathTrack: Equatable, Sendable {
    /// The time between two successive tachogram peaks, stamped at the wall-clock second of the later one.
    public struct Interval: Equatable, Sendable {
        public let ts: Int
        public let seconds: Double
    }

    /// A stretch of unbroken beats long enough to read breaths from, in wall-clock seconds, inclusive.
    public struct Run: Equatable, Sendable {
        public let start: Int
        public let end: Int
    }

    public struct Estimate: Equatable, Sendable {
        public let breathsPerMinute: Double
        /// Breath intervals behind the value.
        public let intervals: Int
        /// How many of those ended in the caller's "current" slice.
        public let currentIntervals: Int
        /// Seconds of the window covered by usable runs of beats.
        public let coveredSeconds: Double
    }

    /// Sorted by `ts`.
    public let intervals: [Interval]
    /// Sorted by `start`, non-overlapping.
    public let runs: [Run]

    public static let empty = RespBreathTrack(intervals: [], runs: [])

    public init(intervals: [Interval], runs: [Run]) {
        self.intervals = intervals
        self.runs = runs
    }

    /// Rate over breaths that ended in `[from, to)`.
    ///
    /// - `currentFrom`: breaths ending at or after this must number at least `minCurrentIntervals`, so a
    ///   point stamped for a slice is never just its predecessor's data repeated across a dropout.
    /// - Returns nil when there are too few breaths, or when the median falls outside
    ///   `SleepStager.respPlausibleRangeBpm`, the band every consumer of the rate acts on.
    public func estimate(from: Int, to: Int, currentFrom: Int, minIntervals: Int = 6,
                         minCurrentIntervals: Int = 2) -> Estimate? {
        guard to > from else { return nil }
        let lo = lowerBound(from)
        let hi = lowerBound(to)
        guard hi - lo >= minIntervals else { return nil }
        let window = intervals[lo..<hi]
        let current = window.reduce(0) { $0 + ($1.ts >= currentFrom ? 1 : 0) }
        guard current >= minCurrentIntervals else { return nil }
        let median = HRVAnalyzer.median(window.map(\.seconds))
        guard median > 0 else { return nil }
        let rate = 60.0 / median
        guard SleepStager.respPlausibleRangeBpm.contains(rate) else { return nil }

        var covered = 0.0
        for run in runs where run.end >= from && run.start < to {
            covered += Double(min(run.end + 1, to) - max(run.start, from))
        }
        return Estimate(breathsPerMinute: rate, intervals: hi - lo, currentIntervals: current,
                        coveredSeconds: min(covered, Double(to - from)))
    }

    private func lowerBound(_ ts: Int) -> Int {
        var lo = 0, hi = intervals.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if intervals[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

extension SleepStager {
    /// Shortest run of unbroken beats that is read for breaths (seconds of beat time). Below this the
    /// detrend window, which needs about eight seconds on each side, leaves no interior to find a peak in.
    static let respTrackMinRunS = 20.0

    /// Peaks within this many seconds of a run's ends are ignored: the centred moving mean is truncated
    /// there, so the detrended signal is biased and a spurious edge peak is likely.
    static let respTrackEdgeTrimS = rsaDetrendWindowS / 2.0

    /// A beat further than this fraction from the median of its neighbours is treated as an ectopic or a
    /// missed/doubled beat and replaced by that median, so a single bad beat does not become a "breath". The
    /// nightly kernel does not do this; a window of 300 s dilutes one such beat, a 90 s run does not.
    static let respTrackEctopicFraction = 0.30

    /// Longest stretch peaks are picked over in one call. `findPeaks` is quadratic in the candidates it
    /// resolves, and an unbroken night run is hours long.
    static let respTrackChunkS = 600.0

    /// Build the breath track for a set of R-R rows (any order, any span).
    ///
    /// Beats are split into runs wherever the wall clock ran ahead of the beat's own length by more than
    /// `rsaGapToleranceS`, the same splice rule the nightly kernel uses, and each run is read on its own.
    /// The beat-accuracy gate is the caller's to apply to the window it reports, as the nightly kernel
    /// applies it to a session: this function does not judge a stream's provenance.
    public static func respBreathTrack(_ rr: [RRInterval]) -> RespBreathTrack {
        let rows = rr.sortedByTsStable().filter {
            Double($0.rrMs) >= HRVAnalyzer.rrMinMs && Double($0.rrMs) <= HRVAnalyzer.rrMaxMs
        }
        guard rows.count >= 2 else { return .empty }

        var intervals: [RespBreathTrack.Interval] = []
        var runs: [RespBreathTrack.Run] = []
        var begin = 0
        for i in 1...rows.count {
            let atEnd = i == rows.count
            let splice = !atEnd && Double(rows[i].ts - rows[i - 1].ts) - Double(rows[i].rrMs) / 1000.0 > rsaGapToleranceS
            guard atEnd || splice else { continue }
            let slice = rows[begin..<i]
            begin = i
            let beatSeconds = slice.reduce(0.0) { $0 + Double($1.rrMs) } / 1000.0
            guard beatSeconds >= respTrackMinRunS else { continue }
            runs.append(RespBreathTrack.Run(start: slice.first!.ts, end: slice.last!.ts))
            intervals.append(contentsOf: breathIntervals(in: Array(slice)))
        }
        return RespBreathTrack(intervals: intervals, runs: runs)
    }

    private static func breathIntervals(in run: [RRInterval]) -> [RespBreathTrack.Interval] {
        let values = replacingEctopics(run.map { Double($0.rrMs) })
        var beatTimes = [Double](repeating: 0, count: values.count)
        var acc = 0.0
        for i in values.indices {
            acc += values[i] / 1000.0
            beatTimes[i] = acc
        }
        let dt = 1.0 / rsaResampleHz
        let nGrid = Int(acc / dt) + 1
        guard nGrid >= 8 else { return [] }

        var grid = [Double](repeating: 0, count: nGrid)
        var seg = 0
        for g in 0..<nGrid {
            let t = Double(g) * dt
            while seg < beatTimes.count - 2 && beatTimes[seg + 1] < t { seg += 1 }
            let t0 = beatTimes[seg], t1 = beatTimes[seg + 1]
            let v0 = values[seg], v1 = values[seg + 1]
            grid[g] = t1 <= t0 ? v0 : v0 + min(max((t - t0) / (t1 - t0), 0), 1) * (v1 - v0)
        }

        var prefix = [Double](repeating: 0, count: nGrid + 1)
        for i in 0..<nGrid { prefix[i + 1] = prefix[i] + grid[i] }
        let halfW = max(1, Int((rsaDetrendWindowS * rsaResampleHz / 2.0).rounded()))
        var detrended = [Double](repeating: 0, count: nGrid)
        for i in 0..<nGrid {
            let lo = max(0, i - halfW)
            let hi = min(nGrid - 1, i + halfW)
            detrended[i] = grid[i] - (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }

        let minDistSamples = max(2, Int((rsaMinPeakDistanceS * rsaResampleHz).rounded()))
        let trim = Int((respTrackEdgeTrimS * rsaResampleHz).rounded())
        let chunk = Int((respTrackChunkS * rsaResampleHz).rounded())
        var out: [RespBreathTrack.Interval] = []
        var chunkStart = 0
        while chunkStart < nGrid {
            let chunkEnd = min(nGrid, chunkStart + chunk)
            if chunkEnd - chunkStart >= minDistSamples * 3 {
                let peaks = findPeaks(Array(detrended[chunkStart..<chunkEnd]), distance: minDistSamples, height: 0.0)
                    .map { $0 + chunkStart }
                    .filter { $0 >= trim && $0 < nGrid - trim }
                if peaks.count >= 2 {
                    for k in 1..<peaks.count {
                        let seconds = Double(peaks[k] - peaks[k - 1]) * dt
                        guard seconds >= rsaMinBreathIntervalS, seconds <= rsaMaxBreathIntervalS else { continue }
                        let t = Double(peaks[k]) * dt
                        out.append(RespBreathTrack.Interval(ts: run[beatIndex(atOrAfter: t, in: beatTimes)].ts,
                                                            seconds: seconds))
                    }
                }
            }
            chunkStart = chunkEnd
        }
        return out
    }

    /// The first beat whose end time is not before `t`; the last beat when `t` is past them all. The wall
    /// clock second of that beat is how a breath is placed on the day, so cumulative drift between summed
    /// beat time and the wall clock cannot move it by more than the run's own rounding.
    private static func beatIndex(atOrAfter t: Double, in beatTimes: [Double]) -> Int {
        var lo = 0, hi = beatTimes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beatTimes[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return min(lo, beatTimes.count - 1)
    }

    private static func replacingEctopics(_ values: [Double]) -> [Double] {
        guard values.count >= 7 else { return values }
        var out = values
        for i in values.indices {
            let lo = max(0, i - 3), hi = min(values.count - 1, i + 3)
            let local = HRVAnalyzer.median(Array(values[lo...hi]))
            if local > 0, abs(values[i] - local) > respTrackEctopicFraction * local { out[i] = local }
        }
        return out
    }
}
