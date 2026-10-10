import Foundation

// ActivityPostureHeartRate.swift — a wearer's own heart-rate-by-posture model: weak, personal, verified (hsmm-2.0).
//
// Standing raises heart rate over sitting (orthostatic load): PAMAP2 +8.5 bpm median, positive for every subject
// (docs/sit-stand-calibration-findings.md). It is still a weak cue: exertion, recovery, caffeine and stress move the
// rate by far more, the owner's own 2026-10-06 calibration shows about +6 bpm, and on 2026-10-09 their seated rate
// fell from 89 to 65 bpm over 40 minutes of recovery from a walk. So the decoder uses it only:
//   • for a wearer whose OWN labelled seconds (guided calibration holds, in-the-moment confirmations, stretch
//     verdicts) show a gap that holds up on held-out runs (`ActivityPostureHeartRateFitter`) — no population model
//     stands in until then ("no stand-in models"); with no model the rate stays posture-neutral as before;
//   • on SETTLED seconds: a still stretch at least `settleS` old, no exertion for `afterExertionS`, a flat trend;
//   • relative to the wearer's resting reference (the decoder config's `restingHeartRate`), so day-to-day drift in
//     the resting rate does not read as a posture;
//   • bounded: its lean alone stays below the commit bar of a sitting / standing label (`maxLean`), and it is kept
//     out of the learned-posture agreement, so heart rate can tip an otherwise even split, never make a claim alone.
//
// Circularity: physiology context stratifies heart rate by posture. A posture partly inferred from the rate biases
// that stratification toward the model's own gap. The bound above keeps the rate from ever being the sole basis of a
// committed label, which is what those strata use.

public struct ActivityPostureHeartRateModel: Codable, Equatable, Sendable {
    public static let version = "posture-hr-1"
    public var modelVersion: String = version
    /// Settled seated / standing heart rate minus the resting reference the labels were measured against (bpm).
    public var seatedOffsetBpm: Double
    public var uprightOffsetBpm: Double
    /// Pooled within-posture standard deviation of 30-s means (bpm).
    public var sdBpm: Double
    public var seatedSeconds: Int
    public var uprightSeconds: Int
    /// Distinct runs (sessions or days) the fit used.
    public var runs: Int
    /// Mean held-out AUC (leave-one-run-out) the fit reached.
    public var heldOutAUC: Double

    public init(seatedOffsetBpm: Double, uprightOffsetBpm: Double, sdBpm: Double, seatedSeconds: Int,
                uprightSeconds: Int, runs: Int, heldOutAUC: Double) {
        self.seatedOffsetBpm = seatedOffsetBpm; self.uprightOffsetBpm = uprightOffsetBpm; self.sdBpm = sdBpm
        self.seatedSeconds = seatedSeconds; self.uprightSeconds = uprightSeconds; self.runs = runs
        self.heldOutAUC = heldOutAUC
    }

    public var gapBpm: Double { uprightOffsetBpm - seatedOffsetBpm }

    public var isUsable: Bool {
        modelVersion == Self.version && seatedOffsetBpm.isFinite && uprightOffsetBpm.isFinite && sdBpm.isFinite
            && sdBpm > 0 && gapBpm >= ActivityPostureHeartRateFitter.minGapBpm
    }

    /// Short stable tag for cache keys.
    public var tag: String {
        func q(_ x: Double) -> Int { Int((x * 10).rounded()) }
        return "s\(q(seatedOffsetBpm))u\(q(uprightOffsetBpm))d\(q(sdBpm))"
            .replacingOccurrences(of: "-", with: "m")
    }

    /// Log-likelihood ratio, seated over standing, of a settled 30-s mean `offsetBpm` above the resting reference.
    public func logOdds(offsetBpm x: Double) -> Double {
        let v = 2 * sdBpm * sdBpm
        return ((x - uprightOffsetBpm) * (x - uprightOffsetBpm) - (x - seatedOffsetBpm) * (x - seatedOffsetBpm)) / v
    }
}

/// When a second's heart rate may speak about posture, and how loudly.
public enum ActivityPostureHeartRateGate {
    /// The still stretch must be at least this old: the orthostatic response and post-movement recovery settle
    /// within about 2–3 minutes.
    public static let settleS = 180
    /// Seconds after the last exertion (heart rate at or above `exertionHrRel` of reserve) before the rate is posture
    /// evidence again: recovery from a walk reads as standing for many minutes.
    public static let afterExertionS = 900
    public static let exertionHrRel = 0.30
    /// Largest |trend| (bpm / min) at which the rate counts as settled.
    public static let maxSlopeBpmPerMin = 1.0
    /// Time constant (s) of the rate average the model reads.
    public static let averageTauS = 30.0
    /// Gain on the log-likelihood ratio, and the most the rate may lean either way (log-odds). ln 1.5 is below the
    /// ~ln 1.9 lean a sitting label needs and the ~ln 2.1 a standing one needs (`ActivityDisplay.derive`).
    public static let gain = 0.5
    public static let maxLean = log(1.5)

    /// The bounded lean (> 0 toward seated) for a settled average `averageBpm`, or 0 when it is not settled.
    public static func lean(model: ActivityPostureHeartRateModel, averageBpm: Double?, restingBpm: Double,
                            stillForS: Int, sinceExertionS: Int?, slope: Double?) -> Double {
        guard model.isUsable, let hr = averageBpm, hr.isFinite, stillForS >= settleS else { return 0 }
        if let since = sinceExertionS, since < afterExertionS { return 0 }
        guard let slope, abs(slope) <= maxSlopeBpmPerMin else { return 0 }
        // A rate well above the wearer's standing level is effort or recovery, not standing (C-hr §3c: every
        // post-exercise sit read as standing at +18–32 bpm).
        let x = hr - restingBpm
        if x > model.uprightOffsetBpm + model.gapBpm / 2 { return 0 }
        let l = gain * model.logOdds(offsetBpm: x)
        return min(maxLean, max(-maxLean, l))
    }
}

/// One labelled stretch of sitting or standing, as the fitter reads it.
public struct ActivityPostureHeartRateLabel: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var seated: Bool
    /// The run the stretch belongs to (calibration session id, or the local day of a confirmation / verdict).
    public var run: String

    public init(start: Int, end: Int, seated: Bool, run: String) {
        self.start = start; self.end = end; self.seated = seated; self.run = run
    }
}

public enum ActivityPostureHeartRateFitStatus: String, Codable, Sendable {
    case adopted
    case needsMoreData = "needs_more_data"
    /// Enough data, but the gap does not hold on held-out runs: heart rate stays posture-neutral for this wearer.
    case notSeparable = "not_separable"
}

public struct ActivityPostureHeartRateFitResult: Codable, Equatable, Sendable {
    public var status: ActivityPostureHeartRateFitStatus
    public var model: ActivityPostureHeartRateModel?
    public var seatedSeconds: Int
    public var uprightSeconds: Int
    public var runs: Int
    public var gapBpm: Double?
    public var heldOutAUC: Double?
    public var reason: String
}

public enum ActivityPostureHeartRateFitter {
    /// Seconds into a labelled stretch before its rate counts (orthostatic settling).
    public static let settleIntoLabelS = 45
    /// Needed per posture overall, and the runs that must each hold both postures (leave-one-run-out needs 2).
    public static let minSecondsPerPosture = 120
    public static let minRuns = 2
    /// The gap must be at least this many bpm and hold on held-out runs at this AUC.
    /// PAMAP2 (C-hr): the settled gap is 10.5 bpm median within a session, but the same seated posture sits 5.6 bpm
    /// RMS away at another time or task, so a gap under 8 bpm is mostly drift. The owner's own 2026-10-06 run shows
    /// about 6 bpm: for them the rate stays posture-neutral until more runs say otherwise.
    public static let minGapBpm = 8.0
    public static let minHeldOutAUC = 0.75
    /// Floor on the model's SD (bpm): fitted SDs of 1.5–4 bpm made raw likelihood ratios tens of nats and up to 10 %
    /// of seconds confidently wrong (C-hr §3).
    public static let minSdBpm = 4.0
    /// Width of the averaged blocks the model and the AUC read (s).
    public static let blockS = 30

    /// `hr`: (ts, bpm) samples covering the labels; `restingBpm`: the resting reference per run (the decoder's
    /// `restingHeartRate` for the label's day), falling back to `defaultRestingBpm`.
    public static func fit(labels: [ActivityPostureHeartRateLabel], hr: [(ts: Int, bpm: Double)],
                           restingBpm: [String: Double] = [:], defaultRestingBpm: Double = 60)
        -> ActivityPostureHeartRateFitResult {
        let byTs = Dictionary(hr.map { ($0.ts, $0.bpm) }, uniquingKeysWith: { a, _ in a })
        // 30-s block means of settled labelled seconds, as offsets from the run's resting reference.
        struct Block { var run: String; var seated: Bool; var offset: Double; var seconds: Int }
        var blocks: [Block] = []
        for l in labels {
            let rest = restingBpm[l.run] ?? defaultRestingBpm
            var t = l.start + settleIntoLabelS
            while t + blockS <= l.end {
                let v = (t..<(t + blockS)).compactMap { byTs[$0] }.filter { $0.isFinite && $0 >= 30 && $0 <= 220 }
                if v.count >= blockS * 2 / 3 {
                    blocks.append(Block(run: l.run, seated: l.seated, offset: v.reduce(0, +) / Double(v.count) - rest,
                                        seconds: v.count))
                }
                t += blockS
            }
        }
        let sSec = blocks.filter(\.seated).reduce(0) { $0 + $1.seconds }
        let uSec = blocks.filter { !$0.seated }.reduce(0) { $0 + $1.seconds }
        let bothRuns = Set(blocks.map(\.run)).filter { r in
            blocks.contains { $0.run == r && $0.seated } && blocks.contains { $0.run == r && !$0.seated }
        }
        func result(_ s: ActivityPostureHeartRateFitStatus, _ m: ActivityPostureHeartRateModel? = nil,
                    gap: Double? = nil, auc: Double? = nil, reason: String) -> ActivityPostureHeartRateFitResult {
            ActivityPostureHeartRateFitResult(status: s, model: m, seatedSeconds: sSec, uprightSeconds: uSec,
                                              runs: bothRuns.count, gapBpm: gap, heldOutAUC: auc, reason: reason)
        }
        guard sSec >= minSecondsPerPosture, uSec >= minSecondsPerPosture, bothRuns.count >= minRuns else {
            return result(.needsMoreData, reason: "needs \(minSecondsPerPosture) s settled per posture across \(minRuns) runs")
        }
        func model(_ bs: [Block]) -> ActivityPostureHeartRateModel? {
            let s = bs.filter(\.seated).map(\.offset), u = bs.filter { !$0.seated }.map(\.offset)
            guard s.count >= 2, u.count >= 2 else { return nil }
            func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(x.count) }
            let ms = mean(s), mu = mean(u)
            let ss = s.reduce(0) { $0 + ($1 - ms) * ($1 - ms) } + u.reduce(0) { $0 + ($1 - mu) * ($1 - mu) }
            let sd = max(minSdBpm, (ss / Double(s.count + u.count - 2)).squareRoot())
            return ActivityPostureHeartRateModel(seatedOffsetBpm: ms, uprightOffsetBpm: mu, sdBpm: sd,
                                                 seatedSeconds: sSec, uprightSeconds: uSec,
                                                 runs: bothRuns.count, heldOutAUC: 0)
        }
        // Leave one run out: the model of the other runs must rank the held-out run's blocks.
        var aucs: [Double] = []
        for r in bothRuns.sorted() {
            guard let m = model(blocks.filter { $0.run != r }) else { continue }
            let test = blocks.filter { $0.run == r }
            let sc = test.filter(\.seated).map { m.logOdds(offsetBpm: $0.offset) }
            let uc = test.filter { !$0.seated }.map { m.logOdds(offsetBpm: $0.offset) }
            guard !sc.isEmpty, !uc.isEmpty else { continue }
            var wins = 0.0
            for a in sc { for b in uc { wins += a > b ? 1 : (a == b ? 0.5 : 0) } }
            aucs.append(wins / Double(sc.count * uc.count))
        }
        guard var full = model(blocks), !aucs.isEmpty else {
            return result(.needsMoreData, reason: "no held-out run had both postures")
        }
        let auc = aucs.reduce(0, +) / Double(aucs.count)
        full.heldOutAUC = auc
        guard full.gapBpm >= minGapBpm, auc >= minHeldOutAUC else {
            return result(.notSeparable, gap: full.gapBpm, auc: auc,
                          reason: String(format: "gap %.1f bpm, held-out AUC %.2f: below %.0f bpm / %.2f",
                                 full.gapBpm, auc, minGapBpm, minHeldOutAUC))
        }
        return result(.adopted, full, gap: full.gapBpm, auc: auc,
                      reason: String(format: "gap %.1f bpm, held-out AUC %.2f", full.gapBpm, auc))
    }
}

extension ActivityPostureHeartRateFitter {
    /// The labelled sitting / standing stretches a fit reads from the wearer's ground truth: guided holds,
    /// in-the-moment confirmations and stretch verdicts that name `seated_likely` or `upright_stationary`, long enough
    /// to hold one settled block, and not flagged unsure. The run is the guided session, else the UTC day.
    public static func labels(from groundTruth: [ActivityGroundTruthLabel]) -> [ActivityPostureHeartRateLabel] {
        groundTruth.compactMap { g in
            guard !g.userUnsure, g.endTs - g.startTs >= settleIntoLabelS + blockS else { return nil }
            let seated: Bool
            switch g.posture {
            case PostureClass.seatedLikely.rawValue: seated = true
            case PostureClass.uprightStationary.rawValue: seated = false
            default: return nil
            }
            let run = g.sessionId.flatMap { $0.isEmpty ? nil : "s:\($0)" } ?? "d:\(Int(floor(Double(g.startTs) / 86_400)))"
            return ActivityPostureHeartRateLabel(start: g.startTs, end: g.endTs, seated: seated, run: run)
        }
    }
}
