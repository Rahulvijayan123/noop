import Foundation
import WhoopProtocol

// EnergySignals.swift — turns the day's raw streams into one aligned record per minute.
//
// Nothing here estimates energy. It only bins what the strap measured (heart rate, gravity-removed motion
// magnitude, the step counter), what the existing activity classifier said (epochs), and what the offline
// motion models produced (WristMET / wrist CNN minutes), so the later stages see one consistent grid.

struct MinuteSignals {
    var startTs: Int
    /// Seconds of this minute that fall inside the (possibly still-open) day.
    var lengthS: Int

    var hr: Double?
    var hrSource: EnergyHRSource = .absent

    /// Mean gravity-removed motion magnitude in g, when ≥ `dynMinSamples` rows exist.
    var dyn: Double?
    /// Steps per minute from the wrap-aware step counter, when the minute has step rows.
    var cadence: Double?
    var runClassShare: Double = 0
    var walkClassShare: Double = 0

    /// The existing classifier's belief for this minute, when epochs cover it.
    var epochBelief: ActivityBelief?
    var epochAsleep = false
    var epochOffWrist = false

    var motion: MotionEvidenceMinute?
    var gpsSpeedMps: Double?
    var gpsGradePct: Double?

    var sleep = false
    /// Inside a sleep interval, but the heart rate says otherwise (see `reconcileSleepWithHeartRate`).
    var sleepContradicted = false
    var offWrist = false
    var workoutIndex: Int?

    var hasMotionSignal: Bool { dyn != nil || cadence != nil || epochBelief != nil || motion != nil }
    var covered: Bool { hrSource != .absent || hasMotionSignal }
}

enum MinuteSignalBuilder {
    static func build(_ input: EnergyDayInput, config: EnergyConfig) -> [MinuteSignals] {
        let end = min(input.dayEnd, input.asOf ?? input.dayEnd)
        guard end > input.dayStart else { return [] }
        let n = (end - input.dayStart + 59) / 60
        var minutes: [MinuteSignals] = []
        minutes.reserveCapacity(n)
        for i in 0..<n {
            let s = input.dayStart + i * 60
            minutes.append(MinuteSignals(startTs: s, lengthS: min(60, end - s)))
        }
        fillHeartRate(&minutes, input.hr, dayStart: input.dayStart, end: end, config: config)
        fillGravity(&minutes, input.gravity, dayStart: input.dayStart, end: end, config: config)
        fillSteps(&minutes, input.steps, dayStart: input.dayStart, end: end,
                  ticksPerStep: input.profile.stepTicksPerStep, config: config)
        fillEpochs(&minutes, input.activityEpochs, dayStart: input.dayStart, end: end, config: config)
        fillMotionEvidence(&minutes, input.motionEvidence, dayStart: input.dayStart)
        fillSpeed(&minutes, input.speedSamples, dayStart: input.dayStart, end: end)
        markIntervals(&minutes, input)
        reconcileSleepWithHeartRate(&minutes, restingHR: input.restingHR, config: config)
        return minutes
    }

    // MARK: Heart rate

    private static func fillHeartRate(_ minutes: inout [MinuteSignals], _ hr: [HRSample],
                                      dayStart: Int, end: Int, config: EnergyConfig) {
        let samples = hr
            .filter { $0.bpm >= config.hrMinBpm && $0.bpm <= config.hrMaxBpm
                && $0.ts >= dayStart - 300 && $0.ts < end + 300 }
            .sorted { $0.ts < $1.ts }
        var sum = [Double](repeating: 0, count: minutes.count)
        var cnt = [Int](repeating: 0, count: minutes.count)
        for s in samples where s.ts >= dayStart && s.ts < end {
            let i = (s.ts - dayStart) / 60
            sum[i] += Double(s.bpm)
            cnt[i] += 1
        }
        for i in minutes.indices {
            if cnt[i] > 0 {
                minutes[i].hr = sum[i] / Double(cnt[i])
                minutes[i].hrSource = .measured
                continue
            }
            let start = minutes[i].startTs
            let center = Double(start) + Double(minutes[i].lengthS) / 2
            let k = lowerBound(samples, ts: start)
            let prev: HRSample? = k > 0 ? samples[k - 1] : nil
            let next: HRSample? = k < samples.count ? samples[k] : nil
            if let p = prev, let q = next, q.ts > p.ts, Double(q.ts - p.ts) <= config.hrCarryMaxGapS {
                let f = (center - Double(p.ts)) / Double(q.ts - p.ts)
                minutes[i].hr = Double(p.bpm) + f * Double(q.bpm - p.bpm)
                minutes[i].hrSource = .carried
            } else if let p = prev, center - Double(p.ts) <= config.hrHoldMaxS {
                minutes[i].hr = Double(p.bpm)
                minutes[i].hrSource = .carried
            } else if let q = next, Double(q.ts) - center <= config.hrHoldMaxS {
                minutes[i].hr = Double(q.bpm)
                minutes[i].hrSource = .carried
            }
        }
    }

    private static func lowerBound(_ samples: [HRSample], ts: Int) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Gravity-removed motion magnitude

    private static func fillGravity(_ minutes: inout [MinuteSignals], _ gravity: [GravitySample],
                                    dayStart: Int, end: Int, config: EnergyConfig) {
        var sum = [Double](repeating: 0, count: minutes.count)
        var cnt = [Int](repeating: 0, count: minutes.count)
        for g in gravity where g.ts >= dayStart && g.ts < end {
            guard let d = g.dynAccel, d.isFinite, d >= 0, d <= 8 else { continue }
            let i = (g.ts - dayStart) / 60
            sum[i] += d
            cnt[i] += 1
        }
        for i in minutes.indices where cnt[i] >= config.dynMinSamples {
            minutes[i].dyn = sum[i] / Double(cnt[i])
        }
    }

    // MARK: Step counter → cadence

    private static func fillSteps(_ minutes: inout [MinuteSignals], _ steps: [StepSample],
                                  dayStart: Int, end: Int, ticksPerStep: Double, config: EnergyConfig) {
        guard !steps.isEmpty else { return }
        let sorted = steps
            .filter { $0.ts >= dayStart - 120 && $0.ts < end }
            .sorted { $0.ts < $1.ts }
        let tps = max(0.5, ticksPerStep)
        var lo = 0
        for i in minutes.indices {
            let start = minutes[i].startTs
            let stop = start + minutes[i].lengthS
            while lo < sorted.count && sorted[lo].ts < start { lo += 1 }
            var hi = lo
            while hi < sorted.count && sorted[hi].ts < stop { hi += 1 }
            let inside = hi - lo
            guard inside >= config.stepMinSamples else { continue }
            var slice = Array(sorted[lo..<hi])
            if lo > 0, start - sorted[lo - 1].ts <= 120 { slice.insert(sorted[lo - 1], at: 0) }
            let ticks = Double(StepsCounter.stepsInWindow(slice) ?? 0)
            minutes[i].cadence = ticks / tps * 60.0 / Double(minutes[i].lengthS)
            let classed = slice.suffix(inside).compactMap { $0.activityClass }
            if !classed.isEmpty {
                let total = Double(classed.count)
                minutes[i].walkClassShare = Double(classed.filter { $0 == 1 }.count) / total
                minutes[i].runClassShare = Double(classed.filter { $0 == 2 }.count) / total
            }
        }
    }

    // MARK: Activity epochs (existing classifier)

    private static func fillEpochs(_ minutes: inout [MinuteSignals], _ epochs: [ActivityEpoch],
                                   dayStart: Int, end: Int, config: EnergyConfig) {
        guard !epochs.isEmpty else { return }
        let k = EnergyActivity.allCases.count
        var vec = [[Double]](repeating: [Double](repeating: 0, count: k), count: minutes.count)
        var wSum = [Double](repeating: 0, count: minutes.count)
        var cSum = [Double](repeating: 0, count: minutes.count)
        var asleepS = [Double](repeating: 0, count: minutes.count)
        var offS = [Double](repeating: 0, count: minutes.count)
        var seen = [Bool](repeating: false, count: minutes.count)

        for e in epochs {
            let s = max(e.startTs, dayStart)
            let t = min(e.endTs, end)
            guard t > s else { continue }
            let validFrac = e.observedS > 0 ? Double(e.validS) / Double(e.observedS) : 0
            let belief = ActivityBelief.fromLabel(EnergyActivity(e.motion), confidence: e.confidence, source: .hart)
            let first = (s - dayStart) / 60
            let last = (t - 1 - dayStart) / 60
            for i in first...last {
                let mStart = dayStart + i * 60
                let overlap = Double(min(t, mStart + 60) - max(s, mStart))
                guard overlap > 0 else { continue }
                seen[i] = true
                if e.sleepState == .asleep { asleepS[i] += overlap }
                if e.wear == .offWrist { offS[i] += overlap }
                let w = overlap * validFrac
                guard w > 0, e.motion != .unknown else { continue }
                for a in 0..<k { vec[i][a] += w * belief.probabilities[a] }
                wSum[i] += w
                cSum[i] += w * e.confidence
            }
        }
        for i in minutes.indices where seen[i] {
            let half = Double(minutes[i].lengthS) / 2
            minutes[i].epochAsleep = asleepS[i] > half
            minutes[i].epochOffWrist = offS[i] > half
            guard wSum[i] >= config.epochMinCoverageS else { continue }
            let coverage = min(1, wSum[i] / Double(minutes[i].lengthS))
            let meanConf = cSum[i] / wSum[i]
            minutes[i].epochBelief = ActivityBelief(probabilities: vec[i], confidence: meanConf * coverage,
                                                    source: .hart)
        }
    }

    // MARK: Offline motion-model evidence

    private static func fillMotionEvidence(_ minutes: inout [MinuteSignals], _ evidence: [MotionEvidenceMinute],
                                           dayStart: Int) {
        for e in evidence where e.imuSeconds >= 30 {
            let i = (e.minuteStart - dayStart) / 60
            guard i >= 0, i < minutes.count, e.minuteStart >= dayStart else { continue }
            if let existing = minutes[i].motion, existing.imuSeconds >= e.imuSeconds { continue }
            minutes[i].motion = e
        }
    }

    // MARK: GPS speed

    private static func fillSpeed(_ minutes: inout [MinuteSignals], _ speeds: [EnergySpeedSample],
                                  dayStart: Int, end: Int) {
        guard !speeds.isEmpty else { return }
        var sum = [Double](repeating: 0, count: minutes.count)
        var gSum = [Double](repeating: 0, count: minutes.count)
        var cnt = [Int](repeating: 0, count: minutes.count)
        var gCnt = [Int](repeating: 0, count: minutes.count)
        for s in speeds where s.ts >= dayStart && s.ts < end && s.speedMps.isFinite && s.speedMps >= 0 {
            let i = (s.ts - dayStart) / 60
            sum[i] += s.speedMps
            cnt[i] += 1
            if let g = s.gradePct, g.isFinite { gSum[i] += g; gCnt[i] += 1 }
        }
        for i in minutes.indices where cnt[i] >= 5 {
            minutes[i].gpsSpeedMps = sum[i] / Double(cnt[i])
            if gCnt[i] >= 5 { minutes[i].gpsGradePct = gSum[i] / Double(gCnt[i]) }
        }
    }

    // MARK: Sleep / wear / workout membership

    private static func markIntervals(_ minutes: inout [MinuteSignals], _ input: EnergyDayInput) {
        for i in minutes.indices {
            let center = Double(minutes[i].startTs) + Double(minutes[i].lengthS) / 2
            minutes[i].sleep = minutes[i].epochAsleep || input.sleepIntervals.contains { $0.contains(center) }
            minutes[i].offWrist = minutes[i].epochOffWrist || input.offWristIntervals.contains { $0.contains(center) }
            minutes[i].workoutIndex = input.workouts.firstIndex {
                center >= Double($0.start) && center < Double($0.end)
            }
        }
    }

    // MARK: Sleep the heart rate contradicts

    /// A sleep interval is a claim about a span of time; the heart rate can overrule it. A minute whose HR
    /// sits `sleepContradictionBpm` above the sleeper's resting level is awake: sleeping does not produce
    /// it, and zeroing it would hide real activity inside a false or over-long session.
    ///
    /// The resting level is the day's resting HR when known, else the 10th percentile of the heart rate
    /// measured inside the sleep intervals themselves. With too few measured sleep minutes there is no
    /// level to compare against, and the intervals stand.
    private static func reconcileSleepWithHeartRate(_ minutes: inout [MinuteSignals], restingHR: Double?,
                                                    config: EnergyConfig) {
        var asleepHR: [Double] = []
        for m in minutes where m.sleep && m.hrSource == .measured {
            if let hr = m.hr { asleepHR.append(hr) }
        }
        guard asleepHR.count >= 30 else { return }
        let reference: Double
        if let rhr = restingHR {
            reference = rhr.clamped(35, 110)
        } else {
            asleepHR.sort()
            reference = asleepHR[Int(0.10 * Double(asleepHR.count - 1))]
        }
        let ceiling = reference + config.sleepContradictionBpm
        for i in minutes.indices where minutes[i].sleep {
            guard let hr = minutes[i].hr, minutes[i].hrSource != .absent, hr >= ceiling else { continue }
            minutes[i].sleep = false
            minutes[i].sleepContradicted = true
        }
    }
}
