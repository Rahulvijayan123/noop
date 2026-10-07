import Foundation

// ActivityPersonalProfile.swift — one wearer's own observation profiles, learned from their guided
// calibration labels.
//
// The decoder tells sitting, standing, lying and walking apart with population-wide `ModeProfile` values
// (movement range, wrist-orientation change, relative heart rate, arm-pattern and HART compat). A person
// whose standing wrist is busier than average, or whose heart sits higher at rest, is scored against
// someone else's numbers. The fitter replays the decoder over each guided calibration run, taps the
// per-second features inside every static label, and shrinks the default profile of each labelled mode
// toward this wearer's own values (`w = n / (n + k)`, clamped). Each mode is kept only when it beats the
// defaults on runs it was not fit on (leave-one-run-out), so an adaptation that does not help is never used.

// MARK: - Profile

public struct ActivityPersonalRange: Codable, Equatable, Sendable {
    public var lo: Double
    public var hi: Double

    public init(lo: Double, hi: Double) { self.lo = lo; self.hi = hi }

    var range: ClosedRange<Double> { min(lo, hi)...max(lo, hi) }
}

/// The adapted observation fields of one body mode. nil fields keep the default.
public struct ActivityPersonalModeAdjustment: Codable, Equatable, Sendable {
    /// Labelled seconds the adjustment was fit on.
    public var seconds: Int
    public var move: ActivityPersonalRange?
    /// log10(1 + orientPath10) range.
    public var orientPath: ActivityPersonalRange?
    public var hrRel: Double?
    /// Arm-class compat (7 values, sums to 1), the `ArmBehaviorClass` order without unknown.
    public var arm: [Double]?
    /// HART class compat keyed by label raw value.
    public var encoder: [String: Double]?

    public init(seconds: Int, move: ActivityPersonalRange? = nil, orientPath: ActivityPersonalRange? = nil,
                hrRel: Double? = nil, arm: [Double]? = nil, encoder: [String: Double]? = nil) {
        self.seconds = seconds; self.move = move; self.orientPath = orientPath
        self.hrRel = hrRel; self.arm = arm; self.encoder = encoder
    }
}

public struct ActivityPersonalClassScore: Codable, Equatable, Sendable {
    public var seconds: Int
    public var baselineRecall: Double
    public var personalRecall: Double

    public init(seconds: Int, baselineRecall: Double, personalRecall: Double) {
        self.seconds = seconds; self.baselineRecall = baselineRecall; self.personalRecall = personalRecall
    }
}

/// Leave-one-run-out result: every run decoded with the defaults and with a profile fit on the other runs.
public struct ActivityPersonalValidation: Codable, Equatable, Sendable {
    public var runs: Int
    public var labelledSeconds: Int
    public var baselineBalancedAccuracy: Double
    public var personalBalancedAccuracy: Double
    /// Keyed by mode key (`ActivityPersonalProfile.modeKeys`).
    public var classes: [String: ActivityPersonalClassScore]
    public var transitions: Int
    public var baselineTransitionHits: Int
    public var personalTransitionHits: Int

    public init(runs: Int, labelledSeconds: Int, baselineBalancedAccuracy: Double, personalBalancedAccuracy: Double,
                classes: [String: ActivityPersonalClassScore], transitions: Int,
                baselineTransitionHits: Int, personalTransitionHits: Int) {
        self.runs = runs; self.labelledSeconds = labelledSeconds
        self.baselineBalancedAccuracy = baselineBalancedAccuracy
        self.personalBalancedAccuracy = personalBalancedAccuracy
        self.classes = classes; self.transitions = transitions
        self.baselineTransitionHits = baselineTransitionHits; self.personalTransitionHits = personalTransitionHits
    }

    public var gain: Double { personalBalancedAccuracy - baselineBalancedAccuracy }

    /// The largest recall loss of any validated class (0 when none got worse).
    public var worstRecallDrop: Double {
        classes.values.map { $0.baselineRecall - $0.personalRecall }.max().map { max(0, $0) } ?? 0
    }
}

public struct ActivityPersonalProfile: Codable, Equatable, Sendable {
    public static let currentVersion = "personal-profile-1"
    /// The modes a profile may adapt, by key: lying, sitting, standing, walking, brisk walking.
    public static let modeKeys = ["bedRest", "seated", "upright", "walk", "briskWalk"]
    static let adaptableModes: [BodyMode] = [.bedRest, .seated, .upright, .walk, .briskWalk]

    public var version: String
    public var fittedAt: Int
    /// Guided session ids the profile was fit on, sorted.
    public var sessionIds: [String]
    public var modes: [String: ActivityPersonalModeAdjustment]
    public var validation: ActivityPersonalValidation?
    /// Short, filename-safe hash of `modes`: the decoder cache-tag suffix.
    public var tag: String

    public init(fittedAt: Int, sessionIds: [String], modes: [String: ActivityPersonalModeAdjustment],
                validation: ActivityPersonalValidation? = nil) {
        self.version = Self.currentVersion
        self.fittedAt = fittedAt
        self.sessionIds = sessionIds.sorted()
        self.modes = modes
        self.validation = validation
        self.tag = Self.tag(for: modes)
    }

    static func tag(for modes: [String: ActivityPersonalModeAdjustment]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(modes)) ?? Data()
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(String(h, radix: 16).suffix(8))
    }
}

extension BodyMode {
    /// Key of an adaptable mode in `ActivityPersonalProfile.modes`.
    var personalKey: String {
        switch self {
        case .bedRest: return "bedRest"
        case .seated: return "seated"
        case .upright: return "upright"
        case .walk: return "walk"
        case .briskWalk: return "briskWalk"
        default: return "mode\(rawValue)"
        }
    }
}

// MARK: - Fit result

/// One guided calibration session: its labels and the observations covering it (with lead-in, so the
/// decoder's trailing windows are full when the first label starts).
public struct ActivityCalibrationRun: Sendable {
    public var sessionId: String
    public var observations: [ActivityObservation]
    public var labels: [ActivityGroundTruthLabel]

    public init(sessionId: String, observations: [ActivityObservation], labels: [ActivityGroundTruthLabel]) {
        self.sessionId = sessionId; self.observations = observations; self.labels = labels
    }
}

public struct ActivityPersonalFitResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case adopted
        case needsMoreRuns = "needs_more_runs"
        case notBetter = "not_better"
    }

    public enum Outcome: Equatable, Sendable {
        case adopted(ActivityPersonalProfile)
        case needsMoreRuns(have: Int, need: Int)
        case notBetter(baseline: Double, personal: Double)
    }

    public var status: Status
    public var fittedAt: Int
    public var runs: Int
    public var runsNeeded: Int
    /// The adopted profile (status `adopted` only).
    public var profile: ActivityPersonalProfile?
    /// The held-out comparison (nil when there were too few runs to run one).
    public var validation: ActivityPersonalValidation?

    public init(status: Status, fittedAt: Int, runs: Int, runsNeeded: Int,
                profile: ActivityPersonalProfile? = nil, validation: ActivityPersonalValidation? = nil) {
        self.status = status; self.fittedAt = fittedAt; self.runs = runs; self.runsNeeded = runsNeeded
        self.profile = profile; self.validation = validation
    }

    public var outcome: Outcome {
        switch status {
        case .adopted:
            if let profile { return .adopted(profile) }
            return .notBetter(baseline: validation?.baselineBalancedAccuracy ?? 0,
                              personal: validation?.personalBalancedAccuracy ?? 0)
        case .needsMoreRuns: return .needsMoreRuns(have: runs, need: runsNeeded)
        case .notBetter:
            return .notBetter(baseline: validation?.baselineBalancedAccuracy ?? 0,
                              personal: validation?.personalBalancedAccuracy ?? 0)
        }
    }
}

// MARK: - Fitter

public enum ActivityPersonalProfileFitter {

    /// Shrinkage strength: a mode with `k` labelled seconds moves halfway to the wearer's own values.
    static let shrinkSeconds = 120.0
    /// Seconds of one mode needed before any of its fields move.
    static let minModeSeconds = 60
    public static let minRuns = 2
    static let minGain = 0.03
    /// Held-out balanced-accuracy gain a mode has to add to be kept.
    static let minStepGain = 0.005
    static let maxRecallDrop = 0.05
    /// Seconds dropped at the start of a static label (the body is still settling into the state) and at
    /// its end (the next step's cue).
    static let settleSeconds = 3
    static let endGuardSeconds = 1
    /// Seconds after a change of state (a transition label's `transitionTs`, or a static bout following one of
    /// another mode) that are neither fit nor scored: the decoder's trailing windows (`m10`, `orientPath10`,
    /// `mBurst10`) still hold the previous state, so those seconds measure decoder latency, not the profile.
    static let changeSettleSeconds = 10
    static let transitionToleranceS = 5
    /// A class needs this many held-out seconds to take part in the recall guard.
    static let minClassSeconds = 10

    /// Fit, validate and decide. `config` is the wearer's decode config without a personal profile (one, if
    /// present, is ignored): the baseline the profile has to beat.
    public static func fit(runs: [ActivityCalibrationRun], config: ActivityDecoderConfig,
                           now: Int) -> ActivityPersonalFitResult {
        var base = config
        base.personalProfile = nil
        let usable = runs
            .filter { run in run.labels.contains { staticMode(of: $0) != nil } }
            .sorted { $0.sessionId < $1.sessionId }
        guard usable.count >= minRuns else {
            return ActivityPersonalFitResult(status: .needsMoreRuns, fittedAt: now, runs: usable.count, runsNeeded: minRuns)
        }

        let baseline = usable.map { replay($0, config: base) }
        let folds = usable.indices.map { i in
            fitModes(baseline.indices.filter { $0 != i }.flatMap { baseline[$0].samples })
        }
        // Only modes every fold adapted can be validated; the rest stay default even if the full fit could move them.
        let candidates = folds.dropFirst().reduce(Set(folds.first.map { Array($0.keys) } ?? [])) {
            $0.intersection($1.keys)
        }

        func validate(_ keep: Set<String>) -> ActivityPersonalValidation {
            let personal = usable.indices.map { i -> Replay in
                let adjustments = folds[i].filter { keep.contains($0.key) }
                guard !adjustments.isEmpty else { return baseline[i] }
                var cfg = base
                cfg.personalProfile = ActivityPersonalProfile(fittedAt: now, sessionIds: [], modes: adjustments)
                return replay(usable[i], config: cfg)
            }
            return score(baseline: baseline, personal: personal)
        }
        func holds(_ v: ActivityPersonalValidation) -> Bool {
            let rate = { (hits: Int) in v.transitions > 0 ? Double(hits) / Double(v.transitions) : 0 }
            return v.worstRecallDrop <= maxRecallDrop + 1e-9
                && rate(v.personalTransitionHits) >= rate(v.baselineTransitionHits) - maxRecallDrop - 1e-9
        }

        // Backward elimination over the validated modes: drop a mode while the held-out result breaks a guard,
        // or while dropping it costs less than `minStepGain`. Adapting one mode can make it swallow another (a
        // short, sleepless lie-down teaches "quiet wrist", which is also quiet sitting), and all-or-nothing would
        // let that sink the modes that help; adding modes one at a time instead misses pairs that only help together
        // (a busy standing range needs the seated range beside it).
        let all = validate(candidates)
        var kept = candidates
        var validation = all
        while !kept.isEmpty {
            var drop: (mode: String, v: ActivityPersonalValidation)?
            for mode in ActivityPersonalProfile.modeKeys where kept.contains(mode) {
                let v = validate(kept.subtracting([mode]))
                if let d = drop {
                    let better = holds(v) != holds(d.v) ? holds(v)
                        : v.personalBalancedAccuracy > d.v.personalBalancedAccuracy + 1e-9
                    if !better { continue }
                }
                drop = (mode, v)
            }
            guard let drop else { break }
            let cheap = holds(drop.v)
                && drop.v.personalBalancedAccuracy >= validation.personalBalancedAccuracy - minStepGain - 1e-9
            guard !holds(validation) || cheap else { break }
            kept.remove(drop.mode)
            validation = drop.v
        }
        if kept.isEmpty { validation = all }

        let better = !kept.isEmpty && validation.gain >= minGain - 1e-9 && holds(validation)
        let full = fitModes(baseline.flatMap(\.samples)).filter { kept.contains($0.key) }
        guard better, !full.isEmpty else {
            return ActivityPersonalFitResult(status: .notBetter, fittedAt: now, runs: usable.count,
                                             runsNeeded: minRuns, validation: validation)
        }
        let profile = ActivityPersonalProfile(fittedAt: now, sessionIds: usable.map(\.sessionId), modes: full,
                                              validation: validation)
        return ActivityPersonalFitResult(status: .adopted, fittedAt: now, runs: usable.count, runsNeeded: minRuns,
                                         profile: profile, validation: validation)
    }

    // MARK: Labels

    /// The body mode a guided, confident static label says the wearer was in; nil for transition labels,
    /// unsure labels and classes no profile governs.
    static func staticMode(of label: ActivityGroundTruthLabel) -> BodyMode? {
        guard label.source == .guided, !label.userUnsure, label.transitionKind == nil else { return nil }
        switch label.locomotion {
        case LocomotionClass.walking.rawValue?: return .walk
        case LocomotionClass.briskWalking.rawValue?: return .briskWalk
        default: break
        }
        switch label.posture {
        case PostureClass.seatedLikely.rawValue?: return .seated
        case PostureClass.uprightStationary.rawValue?: return .upright
        case PostureClass.recumbent.rawValue?: return .bedRest
        default: return nil
        }
    }

    /// Labelled second → mode, without settle and guard edges or the seconds just after a change of state. A
    /// second two labels disagree on is dropped.
    static func truthBySecond(_ labels: [ActivityGroundTruthLabel]) -> [Int: BodyMode] {
        var truth: [Int: BodyMode] = [:]
        var conflicted = Set<Int>()
        let statics = labels.compactMap { l in staticMode(of: l).map { (label: l, mode: $0) } }
            .sorted { $0.label.startTs < $1.label.startTs }
        for (label, mode) in statics {
            let lo = label.startTs + settleSeconds, hi = label.endTs - endGuardSeconds
            guard lo < hi else { continue }
            for t in lo..<hi {
                if let have = truth[t], have != mode { conflicted.insert(t) } else { truth[t] = mode }
            }
        }
        var changes = labels.compactMap { l -> Int? in
            guard l.source == .guided, l.transitionKind != nil else { return nil }
            return l.transitionTs
        }
        for (prev, next) in zip(statics, statics.dropFirst()) where prev.mode != next.mode {
            let between = changes.contains { $0 >= prev.label.endTs - 1 && $0 <= next.label.startTs + 1 }
            if !between { changes.append(next.label.startTs) }
        }
        for c in changes {
            for t in c..<(c + changeSettleSeconds) { truth[t] = nil }
        }
        for t in conflicted { truth[t] = nil }
        return truth
    }

    // MARK: Replay

    struct Sample {
        let truth: BodyMode
        let predicted: BodyMode
        let features: ActivityFeatures
    }

    struct Replay {
        var samples: [Sample] = []
        var transitions = 0
        var transitionHits = 0
    }

    /// Decode one run and keep every labelled second's features and most likely body mode, plus whether
    /// each transition label was matched by a decoded event of its kind within the tolerance.
    static func replay(_ run: ActivityCalibrationRun, config: ActivityDecoderConfig) -> Replay {
        let truth = truthBySecond(run.labels)
        var decoder = ActivityContextDecoder(config: config)
        decoder.recordsScoredSeconds = true
        var events: [ActivityTransitionEvent] = []
        var out = Replay()
        for o in run.observations {
            let state = decoder.ingest(o)
            if let t = state?.transition { events.append(t) }
            guard let mode = truth[o.ts], let scored = decoder.lastScored else { continue }
            var best = 0
            for m in scored.posterior.indices where scored.posterior[m] > scored.posterior[best] { best = m }
            out.samples.append(Sample(truth: mode, predicted: BodyMode(rawValue: best) ?? .unknown,
                                      features: scored.features))
        }
        for label in run.labels where label.source == .guided && !label.userUnsure {
            guard let kind = label.transitionKind, let ts = label.transitionTs else { continue }
            out.transitions += 1
            if events.contains(where: { $0.kind.rawValue.hasPrefix(kind) && abs($0.ts - ts) <= transitionToleranceS }) {
                out.transitionHits += 1
            }
        }
        return out
    }

    // MARK: Fit

    /// Per-mode adjustments from pooled labelled seconds. Modes under `minModeSeconds` are left out.
    static func fitModes(_ samples: [Sample]) -> [String: ActivityPersonalModeAdjustment] {
        var byMode: [BodyMode: [ActivityFeatures]] = [:]
        for s in samples { byMode[s.truth, default: []].append(s.features) }
        var out: [String: ActivityPersonalModeAdjustment] = [:]
        for mode in ActivityPersonalProfile.adaptableModes {
            guard let fs = byMode[mode], fs.count >= minModeSeconds else { continue }
            if let adj = fitMode(mode, fs) { out[mode.personalKey] = adj }
        }
        return out
    }

    static func fitMode(_ mode: BodyMode, _ fs: [ActivityFeatures]) -> ActivityPersonalModeAdjustment? {
        let p = ActivityContextModel.profiles[mode.rawValue]
        let n = Double(fs.count)
        let w = n / (n + shrinkSeconds)
        var adj = ActivityPersonalModeAdjustment(seconds: fs.count)

        let moves = fs.compactMap { f -> Double? in
            guard let m10 = f.m10 else { return nil }
            return p.moveIsBurst ? (f.mBurst10 ?? m10) : (p.moveIsMedian ? (f.mMed30 ?? m10) : m10)
        }
        if moves.count >= minModeSeconds {
            adj.move = shrinkRange(p.move, toward: moves, w: w, bounds: 0...1, minWidth: 0.06)
        }

        let paths = fs.compactMap { $0.orientPath10.map { log10(1 + $0) } }
        if paths.count >= minModeSeconds {
            adj.orientPath = shrinkRange(p.orientPath, toward: paths, w: w, bounds: 0...2, minWidth: 0.15)
        }

        let hrs = fs.compactMap(\.hrRel)
        if hrs.count >= minModeSeconds, let median = quantile(hrs, 0.5) {
            let shift = min(0.15, max(-0.15, w * (median - p.hrRel)))
            adj.hrRel = round4(p.hrRel + shift)
        }

        var armSum = [Double](repeating: 0, count: p.arm.count), armN = 0
        for f in fs where f.m10 != nil || f.m4 != nil {
            let q = ActivityContextModel.armPattern(f)
            let qs = q[0..<ArmState.unknown].reduce(0, +)
            guard qs > 0, ArmState.unknown == p.arm.count else { continue }
            for a in 0..<ArmState.unknown { armSum[a] += q[a] / qs }
            armN += 1
        }
        if armN >= minModeSeconds {
            let mixed = p.arm.indices.map { (1 - w) * p.arm[$0] + w * armSum[$0] / Double(armN) }
            let s = mixed.reduce(0, +)
            if s > 0 { adj.arm = mixed.map { round4($0 / s) } }
        }

        var encSum: [String: Double] = [:], encN = 0
        for f in fs {
            guard let enc = f.encoder else { continue }
            let known = enc.classProbs.filter { $0.key != "unknown" && $0.value > 0 }
            let total = known.values.reduce(0, +)
            guard total > 0 else { continue }
            for (label, prob) in known { encSum[label, default: 0] += prob / total }
            encN += 1
        }
        if encN >= minModeSeconds {
            var mixed: [String: Double] = [:]
            for label in Set(p.encoder.keys).union(encSum.keys) {
                let user = (encSum[label] ?? 0) / Double(encN)
                mixed[label] = round4(max(0.02, (1 - w) * (p.encoder[label] ?? 0.02) + w * user))
            }
            adj.encoder = mixed
        }

        let changed = adj.move != nil || adj.orientPath != nil || adj.hrRel != nil || adj.arm != nil || adj.encoder != nil
        return changed ? adj : nil
    }

    /// Move each end of `prior` toward the wearer's 5th / 95th percentile by `w`, each end by at most half
    /// the default width, inside `bounds` and never narrower than `minWidth`.
    static func shrinkRange(_ prior: ClosedRange<Double>, toward xs: [Double], w: Double,
                            bounds: ClosedRange<Double>, minWidth: Double) -> ActivityPersonalRange? {
        guard let q05 = quantile(xs, 0.05), let q95 = quantile(xs, 0.95) else { return nil }
        let maxShift = 0.5 * (prior.upperBound - prior.lowerBound)
        func moved(_ from: Double, _ to: Double) -> Double {
            let shifted = from + min(maxShift, max(-maxShift, w * (to - from)))
            return min(bounds.upperBound, max(bounds.lowerBound, shifted))
        }
        var lo = moved(prior.lowerBound, q05), hi = moved(prior.upperBound, q95)
        if hi - lo < minWidth {
            let mid = (lo + hi) / 2
            lo = max(bounds.lowerBound, mid - minWidth / 2)
            hi = min(bounds.upperBound, lo + minWidth)
            lo = max(bounds.lowerBound, hi - minWidth)
        }
        return ActivityPersonalRange(lo: round4(lo), hi: round4(hi))
    }

    static func quantile(_ xs: [Double], _ q: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let i = Int((q * Double(sorted.count - 1)).rounded())
        return sorted[min(sorted.count - 1, max(0, i))]
    }

    static func round4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }

    // MARK: Validation scoring

    static func score(baseline: [Replay], personal: [Replay]) -> ActivityPersonalValidation {
        var total: [BodyMode: Int] = [:], baseHit: [BodyMode: Int] = [:], persHit: [BodyMode: Int] = [:]
        for r in baseline {
            for s in r.samples {
                total[s.truth, default: 0] += 1
                if s.predicted == s.truth { baseHit[s.truth, default: 0] += 1 }
            }
        }
        for r in personal {
            for s in r.samples where s.predicted == s.truth { persHit[s.truth, default: 0] += 1 }
        }
        var classes: [String: ActivityPersonalClassScore] = [:]
        var baseRecalls: [Double] = [], persRecalls: [Double] = []
        for mode in ActivityPersonalProfile.adaptableModes {
            guard let n = total[mode], n >= minClassSeconds else { continue }
            let b = Double(baseHit[mode] ?? 0) / Double(n)
            let p = Double(persHit[mode] ?? 0) / Double(n)
            classes[mode.personalKey] = ActivityPersonalClassScore(seconds: n, baselineRecall: round4(b),
                                                                   personalRecall: round4(p))
            baseRecalls.append(b); persRecalls.append(p)
        }
        let mean = { (xs: [Double]) in xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        return ActivityPersonalValidation(
            runs: baseline.count,
            labelledSeconds: total.values.reduce(0, +),
            baselineBalancedAccuracy: round4(mean(baseRecalls)),
            personalBalancedAccuracy: round4(mean(persRecalls)),
            classes: classes,
            transitions: baseline.map(\.transitions).reduce(0, +),
            baselineTransitionHits: baseline.map(\.transitionHits).reduce(0, +),
            personalTransitionHits: personal.map(\.transitionHits).reduce(0, +))
    }
}
