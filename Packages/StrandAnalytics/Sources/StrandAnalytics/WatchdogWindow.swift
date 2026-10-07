import Foundation
import WhoopProtocol
import WhoopStore

public enum WatchdogHRSource: String, Equatable, Sendable, Codable {
    case v18
    case ppgHr
    case live2A37
    case liveType40
}

public struct WatchdogPPGIdentity: Equatable, Sendable {
    public var ts: Int
    public var recordIndex: Int
    public init(ts: Int, recordIndex: Int) {
        self.ts = ts
        self.recordIndex = recordIndex
    }
}

public struct WatchdogScalarSample: Equatable, Sendable {
    public var ts: Int
    public var value: Double
    public init(ts: Int, value: Double) {
        self.ts = ts
        self.value = value
    }
}

/// Raw inputs for one 30-minute Watchdog window. Physical units only (bpm, ms, °C, breaths/min, 0…1 motion).
public struct WatchdogFeed: Equatable {
    public var family: DeviceFamily
    public var hrSource: WatchdogHRSource
    public var nowUnix: Int
    public var hr: [HRSample]
    public var rr: [RRInterval]
    public var skinTempC: [WatchdogScalarSample]
    public var respPerMin: [WatchdogScalarSample]
    public var motion: [WatchdogScalarSample]
    public var spo2Pct: [WatchdogScalarSample]
    public var ppgIdentities: [WatchdogPPGIdentity]
    public var wristOff: Bool
    public var holdSeeds: WatchdogHoldSeeds
    public var imu: [WatchdogIMUSample]
    public var steps: [StepSample]

    public init(family: DeviceFamily,
                hrSource: WatchdogHRSource,
                nowUnix: Int,
                hr: [HRSample] = [],
                rr: [RRInterval] = [],
                skinTempC: [WatchdogScalarSample] = [],
                respPerMin: [WatchdogScalarSample] = [],
                motion: [WatchdogScalarSample] = [],
                spo2Pct: [WatchdogScalarSample] = [],
                ppgIdentities: [WatchdogPPGIdentity] = [],
                wristOff: Bool = false,
                holdSeeds: WatchdogHoldSeeds = .empty,
                imu: [WatchdogIMUSample] = [],
                steps: [StepSample] = []) {
        self.family = family
        self.hrSource = hrSource
        self.nowUnix = nowUnix
        self.hr = hr
        self.rr = rr
        self.skinTempC = skinTempC
        self.respPerMin = respPerMin
        self.motion = motion
        self.spo2Pct = spo2Pct
        self.ppgIdentities = ppgIdentities
        self.wristOff = wristOff
        self.holdSeeds = holdSeeds
        self.imu = imu
        self.steps = steps
    }
}

public struct WatchdogHoldSeeds: Equatable, Sendable {
    public var resp: Double?
    public var hrv: Double?
    public var temp: Double?
    public var spo2: Double?
    public static let empty = WatchdogHoldSeeds()
    public init(resp: Double? = nil, hrv: Double? = nil, temp: Double? = nil, spo2: Double? = nil) {
        self.resp = resp; self.hrv = hrv; self.temp = temp; self.spo2 = spo2
    }
}

public enum WatchdogUnavailable: String, Equatable, Sendable, Codable, Error {
    case wristOff
    case coverage
    case gap
    case stale
    case empty
}

public struct WatchdogWindow: Equatable, Sendable {
    public var family: DeviceFamily
    public var hrSource: WatchdogHRSource
    public var startUnix: Int
    public var nowUnix: Int
    public var hr: [Double?]
    public var hrv: [Double?]
    public var temp: [Double?]
    public var resp: [Double?]
    public var motion: [Double?]
    public var rhr: [Double?]
    public var spo2: [Double?]
    public var hrMin: [Double?]
    public var hrMax: [Double?]
    public var coverage: Double
    public var maxGapSeconds: Int
    public var newestAgeSeconds: Int
    public var keptPPGIdentities: Int
    public var bucketCoverage: Double
    public var maxEmptyMinutes: Int
    public var activityLogits: [[Double]]
    /// Auto-workout overlap 0/1 per minute (past-future covariate). Never a saved Charge workout.
    public var autoWorkoutOverlap: [Double]
    public var imu: [WatchdogIMUSample] = []
    public var steps: [StepSample] = []
    public var lastWorkoutEndUnix: Int = 0
    public var sleepIntervals: [WatchdogSleepInterval] = []
    /// Last bind of the 20-col block. Reconstruct rebuilds from imu/steps/sleep if this is empty.
    public var activityFeatures: [[Double]] = []
    /// v2 sensor-quality metadata for the alert-verification stage (`WatchdogVerification.swift`). Empty means
    /// UNKNOWN, never good.
    public var quality: WatchdogQualityFeed = .empty
    /// Respiration came from beat intervals (no respiration waveform): it is the beat stream, not independent
    /// evidence, and never a safety input.
    public var respFromBeats: Bool = true

    public var seqLen: Int { hr.count }

    public mutating func bindActivityContext(lastWorkoutEndUnix: Int,
                                             sleepIntervals: [WatchdogSleepInterval]) {
        self.lastWorkoutEndUnix = lastWorkoutEndUnix
        self.sleepIntervals = sleepIntervals
        self.activityFeatures = WatchdogActivityFeatures.build(window: self)
    }

    public func resolvedActivityFeatures() -> [[Double]] {
        if !activityFeatures.isEmpty { return activityFeatures }
        return WatchdogActivityFeatures.build(window: self)
    }

    /// Drop a whole series when its last finite minute is older than that channel's clock.
    /// Student UniTS / TimesFM never see a stale last pair as current.
    public mutating func maskStaleChannels() {
        func wipe(_ series: inout [Double?], channel: Int) {
            if !WatchdogQuality.channelFresh(series, startUnix: startUnix, nowUnix: nowUnix,
                                             channel: channel, family: family) {
                series = Array(repeating: nil, count: series.count)
            }
        }
        wipe(&hr, channel: 0)
        wipe(&rhr, channel: 1)
        wipe(&hrv, channel: 2)
        wipe(&temp, channel: 3)
        wipe(&resp, channel: 4)
        wipe(&spo2, channel: 5)
    }

    public enum Channel: String, Equatable, Sendable, CaseIterable, Codable, Hashable {
        case hr, rhr, hrv, temp, resp, spo2, motion
        public var isVital: Bool { self != .motion }
    }

    public func series(_ channel: Channel) -> [Double?] {
        switch channel {
        case .hr: return hr
        case .rhr: return rhr
        case .hrv: return hrv
        case .temp: return temp
        case .resp: return resp
        case .spo2: return spo2
        case .motion: return motion
        }
    }
}

public enum WatchdogWindowBuilder {
    /// PR 15: several PPG records may share a unix second. Deduping on `ts` alone drops extras.
    public static func uniquePPGIdentities(_ rows: [WatchdogPPGIdentity]) -> [WatchdogPPGIdentity] {
        var seen = Set<String>()
        var out: [WatchdogPPGIdentity] = []
        out.reserveCapacity(rows.count)
        for row in rows.sorted(by: { $0.ts == $1.ts ? $0.recordIndex < $1.recordIndex : $0.ts < $1.ts }) {
            let key = "\(row.ts)#\(row.recordIndex)"
            if seen.insert(key).inserted { out.append(row) }
        }
        return out
    }

    public static func build(_ feed: WatchdogFeed) -> Result<WatchdogWindow, WatchdogUnavailable> {
        if feed.wristOff { return .failure(.wristOff) }
        let end = feed.nowUnix
        let start = end - WatchdogConfig.contextSeconds
        guard end > start else { return .failure(.empty) }

        let hrDeduped = collapseCarryForward(feed.hr)
        let inWindow = hrDeduped.filter { $0.ts >= start && $0.ts < end }
        if inWindow.isEmpty { return .failure(.empty) }

        let hr = bucketMean(inWindow.map { ($0.ts, Double($0.bpm)) }, start: start, end: end)
        let hrMin = bucketReduce(inWindow.map { ($0.ts, Double($0.bpm)) }, start: start, end: end, pick: min)
        let hrMax = bucketReduce(inWindow.map { ($0.ts, Double($0.bpm)) }, start: start, end: end, pick: max)
        let temp = bucketMean(feed.skinTempC.map { ($0.ts, $0.value) }, start: start, end: end)
        var resp = bucketMean(feed.respPerMin.map { ($0.ts, $0.value) }, start: start, end: end)
        var respFromBeats = false
        if resp.compactMap({ $0 }).isEmpty {
            resp = respFromRR(feed.rr, start: start, end: end)
            respFromBeats = true
        }
        let motion = bucketMean(feed.motion.map { ($0.ts, $0.value) }, start: start, end: end)
        let hrv = rmssdGrid(feed.rr, start: start, end: end)
        let spo2All = bucketMean(percentSpO2(feed.spo2Pct).map { ($0.ts, $0.value) }, start: start, end: end)
        let spo2 = maskLookback(spo2All, keepSeconds: WatchdogConfig.spo2LookbackSeconds)
        let logitsRaw = WatchdogActivityRuntime.embed(motion: motion, hr: hr, steps: feed.steps, imu: feed.imu,
                                                   startUnix: start, nowUnix: end, family: feed.family)
        let workoutBits = Self.autoWorkoutBits(hr: hrDeduped, start: start, end: end)
        let logits = WatchdogActivityRuntime.applyAutoWorkoutOverlap(logitsRaw, overlap: workoutBits)
        let rhr = restHr(hr: hr, motion: motion, logits: logits, nowUnix: end, steps: feed.steps,
                         startUnix: start, endUnix: end)
        let ppg = uniquePPGIdentities(feed.ppgIdentities)

        let coverage = coverageFraction(hr: hr, family: feed.family, hrTimes: inWindow.map(\.ts), start: start, end: end)
        let buckets = Double(hr.filter { $0 != nil }.count) / Double(max(hr.count, 1))
        let emptyRun = WatchdogQuality.maxEmptyMinutes(hr)
        let gap = maxGap(inWindow.map(\.ts), start: start, end: end)
        let newest = inWindow.map(\.ts).max().map { end - $0 } ?? WatchdogConfig.contextSeconds

        var window = WatchdogWindow(
            family: feed.family,
            hrSource: feed.hrSource,
            startUnix: start,
            nowUnix: end,
            hr: hr, hrv: hrv, temp: temp, resp: resp, motion: motion,
            rhr: rhr, spo2: spo2,
            hrMin: hrMin, hrMax: hrMax,
            coverage: coverage,
            maxGapSeconds: gap,
            newestAgeSeconds: newest,
            keptPPGIdentities: ppg.count,
            bucketCoverage: buckets,
            maxEmptyMinutes: emptyRun,
            activityLogits: logits,
            autoWorkoutOverlap: workoutBits,
            imu: feed.imu,
            steps: feed.steps
        )
        window.activityFeatures = WatchdogActivityFeatures.build(window: window)
        window.respFromBeats = respFromBeats
        return .success(window)
    }

    /// Identical BPM with no new timestamp is not a new observation.
    static func collapseCarryForward(_ hr: [HRSample]) -> [HRSample] {
        var lastTs: Int?
        var out: [HRSample] = []
        for sample in hr.sorted(by: { $0.ts < $1.ts }) {
            if sample.ts == lastTs { continue }
            lastTs = sample.ts
            out.append(sample)
        }
        return out
    }

    /// Percent SpO₂ only. ADC ratios and out-of-band optical counts are dropped (50…110).
    public static func percentSpO2(_ samples: [WatchdogScalarSample]) -> [WatchdogScalarSample] {
        samples.compactMap { sample in
            let rounded = Int(sample.value.rounded())
            guard AnalyticsEngine.spo2SingleChannelPlausible.contains(rounded) else { return nil }
            return WatchdogScalarSample(ts: sample.ts, value: min(sample.value, 100))
        }
    }

    /// Live percent from an optical row. Oura stores % in `red` with `ir == 0`. Some WHOOP
    /// packets also write a 50…110 percent in `red` even when IR is present. Raw ADC pairs
    /// (thousands) are not a percent and stay out of scoring — they are not `red/ir`.
    public static func percentFromOptical(red: Int, ir: Int) -> Double? {
        if AnalyticsEngine.spo2SingleChannelPlausible.contains(red) {
            return min(Double(red), 100)
        }
        if ir <= 0 {
            let v = Double(red)
            return AnalyticsEngine.spo2SingleChannelPlausible.contains(Int(v.rounded())) ? min(v, 100) : nil
        }
        return nil
    }

    /// Vendor rate rows (Oura milli-bpm) or WHOOP waveform → breaths/min samples.
    public static func respPerMin(rawRows: [(ts: Int, raw: Int)], ringRate: Bool,
                                  start: Int, end: Int) -> [WatchdogScalarSample] {
        if ringRate {
            return rawRows.compactMap { row in
                let bpm = OuraRespScale.breathsPerMin(raw: row.raw)
                guard SleepStager.respPlausibleRangeBpm.contains(bpm) else { return nil }
                return WatchdogScalarSample(ts: row.ts, value: bpm)
            }
        }
        var out: [WatchdogScalarSample] = []
        var b = start
        let block = 5 * 60
        while b < end {
            let e = min(b + block, end)
            let win = rawRows.filter { $0.ts >= b && $0.ts < e }.map { Double($0.raw) }
            if let rate = SleepStager.respRateFromWaveform(win),
               SleepStager.respPlausibleRangeBpm.contains(rate) {
                out.append(WatchdogScalarSample(ts: max(b, e - 1), value: rate))
            }
            b += block
        }
        return out
    }

    /// Last good reading fills a gap. Display helper only — `build` does not apply this to scored channels.
    public static func holdForward(_ series: [Double?], seed: Double? = nil) -> [Double?] {
        var last = seed
        return series.map { value in
            if let value {
                last = value
                return value
            }
            return last
        }
    }

    /// Linear interior gaps, hold at the ends. Empty motion minutes must not become occupancy 0
    /// or the reconstructed usual is a flat rest line for the whole strip.
    public static func interpolateGaps(_ series: [Double?]) -> [Double?] {
        var out = series
        var i = 0
        while i < out.count {
            if out[i] != nil {
                i += 1
                continue
            }
            let start = i
            while i < out.count && out[i] == nil { i += 1 }
            let left = start > 0 ? out[start - 1] : nil
            let right = i < out.count ? out[i] : nil
            if let left, let right, i > start {
                let denom = Double(i - start + 1)
                for k in start..<i {
                    let t = Double(k - start + 1) / denom
                    out[k] = left + (right - left) * t
                }
            } else if let left {
                for k in start..<i { out[k] = left }
            } else if let right {
                for k in start..<i { out[k] = right }
            }
        }
        return out
    }

    public static func maskLookback(_ series: [Double?], keepSeconds: Int) -> [Double?] {
        let keepFrom = max(0, WatchdogConfig.seqLen - (keepSeconds / WatchdogConfig.gridSeconds))
        return series.enumerated().map { index, value in
            index >= keepFrom ? value : nil
        }
    }

    /// Resting HR: still / standing minutes only. Walk, run, lift, cycle, artifact never enter RHR.
    static func restHr(hr: [Double?], motion: [Double?], logits: [[Double]], nowUnix: Int,
                       steps: [StepSample] = [], startUnix: Int = 0, endUnix: Int = 0) -> [Double?] {
        let span = max(endUnix - startUnix, 1)
        let n = hr.count
        func minuteIndex(_ ts: Int) -> Int {
            guard n > 0 else { return 0 }
            return min(n - 1, max(0, ((ts - startUnix) * n) / span))
        }
        var loco = Array(repeating: 0.0, count: n)
        var stepN = Array(repeating: 0.0, count: n)
        if endUnix > startUnix {
            for s in steps where s.ts >= startUnix && s.ts < endUnix {
                let i = minuteIndex(s.ts)
                stepN[i] += 1
                if s.activityClass == 1 || s.activityClass == 2 { loco[i] += 1 }
            }
        }
        let still = (0..<hr.count).map { i -> Double? in
            guard let bpm = hr[i] else { return nil }
            if stepN[i] > 0, loco[i] / stepN[i] >= 0.5 { return nil }
            // No IMU this minute is not the same as sitting still. A live walk often has HR
            // before the gravity row lands; that beat must not enter resting HR.
            guard let measured = motion[i] else { return nil }
            let occ = measured
            let label = i < logits.count
                ? (WatchdogActivityClass.labels(logits: [logits[i]]).first ?? "")
                : ""
            switch label {
            case WatchdogActivityClass.walk.rawValue,
                 WatchdogActivityClass.run.rawValue,
                 WatchdogActivityClass.cycleLike.rawValue,
                 WatchdogActivityClass.resistance.rawValue,
                 WatchdogActivityClass.artifact.rawValue:
                return nil
            default:
                break
            }
            if occ >= 0.15 && label != WatchdogActivityClass.still.rawValue
                && label != WatchdogActivityClass.stand.rawValue {
                return nil
            }
            return bpm
        }
        return still
    }

    /// Display helper only. Scoring windows must not use this — empty minutes stay nil.
    static func fillStrip(_ series: [Double?], seed: Double? = nil) -> [Double?] {
        let forward = holdForward(series, seed: seed)
        let first = forward.compactMap { $0 }.first
        return forward.map { $0 ?? first }
    }

    static func bucketMean(_ pairs: [(Int, Double)], start: Int, end: Int) -> [Double?] {
        bucketReduce(pairs, start: start, end: end) { a, b in (a + b) / 2 }
    }

    static func bucketReduce(_ pairs: [(Int, Double)], start: Int, end: Int,
                             pick: (Double, Double) -> Double) -> [Double?] {
        var sums = Array(repeating: 0.0, count: WatchdogConfig.seqLen)
        var counts = Array(repeating: 0, count: WatchdogConfig.seqLen)
        var first = Array(repeating: Optional<Double>.none, count: WatchdogConfig.seqLen)
        let span = end - start
        for (ts, value) in pairs where ts >= start && ts < end {
            let idx = min(WatchdogConfig.seqLen - 1, ((ts - start) * WatchdogConfig.seqLen) / max(span, 1))
            if let cur = first[idx] {
                first[idx] = pick(cur, value)
            } else {
                first[idx] = value
            }
            sums[idx] += value
            counts[idx] += 1
        }
        if pick(1, 2) == 1.5 {
            return zip(sums, counts).map { $1 == 0 ? nil : $0 / Double($1) }
        }
        return first
    }

    static func respFromRR(_ rr: [RRInterval], start: Int, end: Int) -> [Double?] {
        var out = Array(repeating: Optional<Double>.none, count: WatchdogConfig.seqLen)
        let block = 5 * 60
        var b = start
        while b < end {
            let e = min(b + block, end)
            let rate = SleepStager.respRateFromRR(rr, start: b, end: e)
            if rate.isFinite {
                let idx = min(WatchdogConfig.seqLen - 1, ((b - start) * WatchdogConfig.seqLen) / max(end - start, 1))
                let last = min(WatchdogConfig.seqLen - 1, ((e - 1 - start) * WatchdogConfig.seqLen) / max(end - start, 1))
                for i in idx...last { out[i] = rate }
            }
            b += block
        }
        return out
    }

    /// 5-minute RMSSD on the minute grid, same cleaning as nightly HRV (range + Malik ectopics).
    /// Does not invent values across empty minutes except last-good hold in `build`.
    static func rmssdGrid(_ rr: [RRInterval], start: Int, end: Int) -> [Double?] {
        let lookback = start - 5 * 60
        let points = HRVAnalyzer.rollingRmssd(
            rr: rr.filter { $0.ts >= lookback && $0.ts < end },
            windowSec: 5 * 60,
            stepSec: WatchdogConfig.gridSeconds,
            minBeatsPerWindow: 8
        )
        var out = Array(repeating: Optional<Double>.none, count: WatchdogConfig.seqLen)
        let span = max(end - start, 1)
        for point in points where point.ts >= start && point.ts < end {
            guard point.rmssd > 0 else { continue }
            let idx = min(WatchdogConfig.seqLen - 1, ((point.ts - start) * WatchdogConfig.seqLen) / span)
            out[idx] = point.rmssd
        }
        return median3(out)
    }

    /// Smooth one-minute RMSSD jitter. Keep a sample the high/low rule is supposed to see.
    static func median3(_ xs: [Double?]) -> [Double?] {
        guard xs.count >= 2 else { return xs }
        return xs.indices.map { i in
            if let v = xs[i], isHRVSafetyExtreme(v) { return v }
            let vals = [xs[max(0, i - 1)], xs[i], xs[min(xs.count - 1, i + 1)]].compactMap { $0 }
            guard !vals.isEmpty else { return nil }
            return vals.sorted()[vals.count / 2]
        }
    }

    static func isHRVSafetyExtreme(_ rmssd: Double) -> Bool {
        rmssd > 0 && (rmssd < WatchdogConfig.rmssdLow || rmssd > WatchdogConfig.rmssdHigh)
    }

    static func coverageFraction(hr: [Double?], family: DeviceFamily, hrTimes: [Int],
                                 start: Int, end: Int) -> Double {
        if family == .whoop5 {
            let filled = hr.filter { $0 != nil }.count
            return Double(filled) / Double(WatchdogConfig.seqLen)
        }
        var seconds = Set<Int>()
        for ts in hrTimes where ts >= start && ts < end { seconds.insert(ts) }
        return Double(seconds.count) / Double(max(end - start, 1))
    }

    static func maxGap(_ times: [Int], start: Int, end: Int) -> Int {
        let ts = times.filter { $0 >= start && $0 < end }.sorted()
        guard !ts.isEmpty else { return end - start }
        var gap = ts[0] - start
        for i in 1..<ts.count { gap = max(gap, ts[i] - ts[i - 1]) }
        gap = max(gap, end - 1 - ts[ts.count - 1])
        return gap
    }

    /// Binary overlap of in-tree Auto Workout (HR-only). Not Charge. Missing IMU is still unknown class.
    static func autoWorkoutBits(hr: [HRSample], start: Int, end: Int) -> [Double] {
        let pairs = hr.map { ($0.ts, $0.bpm) }
        let bouts = AutoWorkoutDetector.detect(hr: pairs, restingBpm: 60)
        let span = max(end - start, 1)
        return (0..<WatchdogConfig.seqLen).map { i in
            let t0 = start + (i * span) / WatchdogConfig.seqLen
            let t1 = start + ((i + 1) * span) / WatchdogConfig.seqLen
            let hit = bouts.contains { $0.startSec < t1 && $0.endSec > t0 }
            return hit ? 1.0 : 0.0
        }
    }
}
