import Foundation
import WhoopProtocol

// ActivitySitStand.swift — a verified, per-wearer "Likely sitting / Likely standing" head.
//
// Evidence (docs/sit-stand-calibration-findings.md, experiment code in _acx-scratch/sitstand/scripts/ssmodel.py):
//   • From the wrist alone, free-living sit vs stand is ~0.6–0.7 balanced accuracy. The best wrist option is a
//     PERSONAL logistic regression on held orientation only (the gravity unit vector), shrunk toward a prior, with
//     its per-second log-odds averaged over each still segment (segments split where the 10-s mean dynamic
//     acceleration exceeds 0.2 g).
//   • How well that fits on calibration data says nothing about free living (rank correlation 0.05–0.26), so the
//     head is enabled per wearer only by a VERIFICATION gate on their own in-the-moment confirmations (≥ 6 of the
//     last 8 right, both postures represented): ~55 % of wearers pass, at ~0.79 balanced accuracy. Even then
//     standing is right only about half the time, so every claim stays "likely".
//
// Pieces:
//   ActivitySitStandModel      the fitted head: logOdds(gravity:) > 0 means sitting.
//   ActivitySitStandFitter     guided holds + confirmations → a model (or needsMoreData).
//   ActivitySitStandSmoothing  still-segment log-odds averaging (offline / whole-span form).
//   ActivitySitStandGate       scores confirmations and decides whether the head may speak.
//   ActivitySitStandConfirmations  the confirmation label shape and its window.
//
// The decoder hookup (ActivityDecoderConfig.sitStandHead) lives in ActivityContextDecoder.swift; the app sets it
// only while the gate is `.enabled`. Everything here is a pure value computation: no I/O, no clocks, no randomness.

// MARK: - Per-second input

/// One second of the strap's 1 Hz streams, as the sit / stand head reads it.
public struct ActivitySitStandSecond: Equatable, Codable, Sendable {
    public var ts: Int
    /// Gravity vector in g (any scale; only its direction is used). nil when the second has none.
    public var gravity: [Double]?
    /// The strap's gravity-removed acceleration magnitude, g (`GravitySample.dynAccel`). nil = unknown, which is
    /// never still.
    public var dynG: Double?
    /// The strap was off the wrist this second: no posture, and a segment break.
    public var offWrist: Bool
    /// Asleep, or inside the night's in-bed window: no sit / stand claim, and a segment break.
    public var asleep: Bool
    /// Stepping or otherwise in locomotion (the strap's walk / run class, step ticks, a decoded walk): no claim,
    /// and a segment break. The strap's dynamic acceleration alone does not split a walk on this strap (see
    /// `ActivitySitStandSmoothing.segmentActiveDynG`), so locomotion is a break of its own.
    public var moving: Bool

    public init(ts: Int, gravity: [Double]?, dynG: Double?, offWrist: Bool = false, asleep: Bool = false,
                moving: Bool = false) {
        self.ts = ts; self.gravity = gravity; self.dynG = dynG; self.offWrist = offWrist; self.asleep = asleep
        self.moving = moving
    }

    /// The store's gravity row as one second (awake, on the wrist and not stepping unless the flags say so).
    public init(_ sample: GravitySample, offWrist: Bool = false, asleep: Bool = false, moving: Bool = false) {
        self.init(ts: sample.ts, gravity: [sample.x, sample.y, sample.z], dynG: sample.dynAccel,
                  offWrist: offWrist, asleep: asleep, moving: moving)
    }

    /// The store's gravity rows as seconds, `moving` set where the strap's step counter ticked or its activity
    /// class says walk / run (`StepSample.activityClass` ≥ 1), exactly as the decoder's observations read them.
    public static func seconds(gravity: [GravitySample], steps: [StepSample] = []) -> [ActivitySitStandSecond] {
        guard !steps.isEmpty, let lo = gravity.map(\.ts).min(), let hi = gravity.map(\.ts).max() else {
            return gravity.map { ActivitySitStandSecond($0) }
        }
        let (ticks, classes) = ActivityContextTrackBuilder.stepTicksAndClasses(steps, lo: lo, hi: hi + 1)
        return gravity.map { g in
            ActivitySitStandSecond(g, moving: (ticks[g.ts] ?? 0) > 0 || (classes[g.ts] ?? 0) >= 1)
        }
    }

    /// The gravity unit vector, or nil when there is none (missing, non-finite or near zero).
    var unit: (Double, Double, Double)? {
        guard let g = gravity, g.count >= 3, g[0].isFinite, g[1].isFinite, g[2].isFinite else { return nil }
        let n = (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
        guard n > 1e-6 else { return nil }
        return (g[0] / n, g[1] / n, g[2] / n)
    }
}

// MARK: - The model

/// A wearer's sit / stand head: logistic regression on the 1 Hz gravity unit vector, features [1, ux, uy, uz],
/// log-odds of sitting over standing. Codable so the app persists it as-is; `tag` keys decoder caches.
public struct ActivitySitStandModel: Codable, Equatable, Sendable {
    public static let version = "sitstand-orient-1"

    /// `ActivitySitStandModel.version` at fit time.
    public var modelVersion: String
    /// [bias, wx, wy, wz] on the raw unit vector: logOdds = bias + wx·ux + wy·uy + wz·uz. > 0 means sitting.
    public var weights: [Double]
    /// Provenance of the fit (not needed to evaluate): the per-feature centre and scale the fit was regularised
    /// in, the L2 strength, and the labelled still seconds per class.
    public var center: [Double]
    public var scale: [Double]
    public var lambda: Double
    public var sittingSeconds: Int
    public var standingSeconds: Int
    /// Guided sessions and confirmations that contributed seconds.
    public var sessionIds: [String]
    public var confirmations: Int

    public init(weights: [Double], center: [Double] = [0, 0, 0], scale: [Double] = [1, 1, 1],
                lambda: Double = ActivitySitStandFitConfig.defaultLambda, sittingSeconds: Int = 0,
                standingSeconds: Int = 0, sessionIds: [String] = [], confirmations: Int = 0) {
        self.modelVersion = Self.version
        self.weights = weights
        self.center = center
        self.scale = scale
        self.lambda = lambda
        self.sittingSeconds = sittingSeconds
        self.standingSeconds = standingSeconds
        self.sessionIds = sessionIds
        self.confirmations = confirmations
    }

    /// Log-odds of sitting over standing for one gravity reading (any scale; it is normalised). 0 (no lean) for a
    /// vector with no direction or malformed weights.
    public func logOdds(gravity x: Double, y: Double, z: Double) -> Double {
        guard weights.count == 4, x.isFinite, y.isFinite, z.isFinite else { return 0 }
        let n = (x * x + y * y + z * z).squareRoot()
        guard n > 1e-6 else { return 0 }
        let v = weights[0] + weights[1] * x / n + weights[2] * y / n + weights[3] * z / n
        return v.isFinite ? v : 0
    }

    func logOdds(_ second: ActivitySitStandSecond) -> Double? {
        guard let u = second.unit else { return nil }
        return logOdds(gravity: u.0, y: u.1, z: u.2)
    }

    /// Whether the weights are usable (four finite numbers). A model that is not is never evidence.
    public var isUsable: Bool { weights.count == 4 && weights.allSatisfy(\.isFinite) }

    /// Short, filename-safe hash of the version and weights (FNV-1a over their bit patterns): the decoder
    /// cache-tag suffix, so a refit re-decodes cached days.
    public var tag: String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in modelVersion.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        for w in weights {
            var bits = w.bitPattern
            for _ in 0..<8 { h = (h ^ (bits & 0xff)) &* 0x100000001b3; bits >>= 8 }
        }
        return String(String(h, radix: 16).suffix(8))
    }
}

// MARK: - Smoothing

/// One second after still-segment smoothing.
public struct ActivitySitStandSmoothedSecond: Equatable, Sendable {
    public var ts: Int
    /// The still segment the second belongs to (nil on active / excluded seconds).
    public var segment: Int?
    /// The second's own log-odds (still seconds only).
    public var logOdds: Double?
    /// The segment's mean log-odds over its still seconds: the posture claim for this second. nil = no claim
    /// (moving, active segment, off-wrist, asleep, no gravity).
    public var smoothedLogOdds: Double?
}

/// Still-segment smoothing (ssmodel.py `stream_segments` + `smooth_segments`, non-causal form).
///
/// A second is ACTIVE when the centred 10-s mean of the dynamic acceleration (over the seconds that have one)
/// exceeds `segmentActiveDynG`, or when no second in that window has one; off-wrist, asleep / in-bed and moving
/// (stepping) seconds are active too. A segment is a maximal run of non-active seconds: on Capture-24 only ~2 % of standing seconds
/// fell in sitting-majority segments, i.e. posture changes are almost always bracketed by activity. Inside a
/// segment, a STILL second (dynamic acceleration below `stillDynG`, gravity present) gets the segment's mean
/// log-odds over its still seconds; every other second makes no posture claim.
public enum ActivitySitStandSmoothing {
    /// Window of the dynamic-acceleration mean that splits segments (s).
    public static let segmentWindowS = 10
    /// 10-s mean dynamic acceleration above which a second is active (g): ssmodel.py `dyn_thr`, chosen on
    /// Capture-24 where `dyn` is the RMS of the 0.5 Hz high-passed raw signal. This strap's own dynamic
    /// acceleration reads ordinary walking at about 0.135 g (`ActivitySim`'s measured distributions), under this
    /// bar, so locomotion (`ActivitySitStandSecond.moving`; the decoder's moving / transition posterior) is a
    /// segment break of its own. Not re-tuned on WHOOP data: there is none with posture labels yet.
    public static let segmentActiveDynG = 0.2
    /// Dynamic acceleration below which a second is still (g): the experiments' "still" seconds.
    public static let stillDynG = 0.05

    /// Smooth `seconds` (any order; a duplicate ts keeps the last) with `model`. Output is in ts order, one per
    /// distinct input second.
    public static func smooth(_ seconds: [ActivitySitStandSecond],
                              model: ActivitySitStandModel) -> [ActivitySitStandSmoothedSecond] {
        let parts = segment(seconds)
        var out: [ActivitySitStandSmoothedSecond] = []
        out.reserveCapacity(parts.count)
        var sums: [Int: (Double, Int)] = [:]
        for p in parts {
            var s = ActivitySitStandSmoothedSecond(ts: p.second.ts, segment: p.segment, logOdds: nil, smoothedLogOdds: nil)
            if p.still, let lo = model.logOdds(p.second) {
                s.logOdds = lo
                if let seg = p.segment { let a = sums[seg] ?? (0, 0); sums[seg] = (a.0 + lo, a.1 + 1) }
            }
            out.append(s)
        }
        for i in out.indices {
            guard out[i].logOdds != nil, let seg = out[i].segment, let a = sums[seg], a.1 > 0 else { continue }
            out[i].smoothedLogOdds = a.0 / Double(a.1)
        }
        return out
    }

    /// The store's gravity rows smoothed (awake and on the wrist assumed; `steps` mark locomotion).
    public static func smooth(_ gravity: [GravitySample], steps: [StepSample] = [],
                              model: ActivitySitStandModel) -> [ActivitySitStandSmoothedSecond] {
        smooth(ActivitySitStandSecond.seconds(gravity: gravity, steps: steps), model: model)
    }

    struct Part {
        var second: ActivitySitStandSecond
        var segment: Int?
        var still: Bool
    }

    /// Segment ids and still flags, in ts order (duplicates collapsed to the last).
    static func segment(_ seconds: [ActivitySitStandSecond]) -> [Part] {
        var byTs: [Int: ActivitySitStandSecond] = [:]
        for s in seconds { byTs[s.ts] = s }
        let sorted = byTs.keys.sorted().map { byTs[$0]! }
        guard !sorted.isEmpty else { return [] }
        let half = segmentWindowS / 2   // window [t - half, t + half - 1]
        var out: [Part] = []
        out.reserveCapacity(sorted.count)
        var segmentId = 0
        // Runs whose consecutive gap is at most the window: a longer gap has seconds whose window holds no
        // dynamic acceleration at all, which are active, so it always splits. Inside a run, evaluate densely.
        var start = 0
        while start < sorted.count {
            var end = start
            while end + 1 < sorted.count, sorted[end + 1].ts - sorted[end].ts <= segmentWindowS { end += 1 }
            let lo = sorted[start].ts, hi = sorted[end].ts
            let n = hi - lo + 1
            var present = [ActivitySitStandSecond?](repeating: nil, count: n)
            for i in start...end { present[sorted[i].ts - lo] = sorted[i] }
            // Prefix sums of usable dyn (on-wrist, awake, finite).
            var sum = [Double](repeating: 0, count: n + 1), cnt = [Int](repeating: 0, count: n + 1)
            for i in 0..<n {
                var v = 0.0, c = 0
                if let s = present[i], !s.offWrist, !s.asleep, !s.moving, let d = s.dynG, d.isFinite { v = d; c = 1 }
                sum[i + 1] = sum[i] + v; cnt[i + 1] = cnt[i] + c
            }
            segmentId += 1
            var inSegment = false
            for i in 0..<n {
                let a = max(0, i - half), b = min(n, i + half)
                let c = cnt[b] - cnt[a]
                let excluded = present[i].map { $0.offWrist || $0.asleep || $0.moving } ?? false
                let active = excluded || c == 0 || (sum[b] - sum[a]) / Double(c) > segmentActiveDynG
                if active {
                    if inSegment { segmentId += 1; inSegment = false }
                } else {
                    inSegment = true
                }
                guard let s = present[i] else { continue }
                let still = !active && s.unit != nil && (s.dynG.map { $0.isFinite && $0 < stillDynG } ?? false)
                out.append(Part(second: s, segment: active ? nil : segmentId, still: still))
            }
            segmentId += 1
            start = end + 1
        }
        return out
    }
}

// MARK: - Confirmations

/// The wearer's in-the-moment answer.
public enum ActivitySitStandAnswer: String, Codable, CaseIterable, Sendable {
    case sitting, standing, neither

    /// The canonical posture code a confirmation label carries (nil for "neither").
    public var posture: String? {
        switch self {
        case .sitting: return PostureClass.seatedLikely.rawValue
        case .standing: return PostureClass.uprightStationary.rawValue
        case .neither: return nil
        }
    }

    init?(posture: String?) {
        switch posture {
        case PostureClass.seatedLikely.rawValue?: self = .sitting
        case PostureClass.uprightStationary.rawValue?: self = .standing
        default: return nil
        }
    }
}

/// The shape of a confirmation label. A confirmation answered at `ts` covers `[ts - before, ts + after)`; inside
/// that window only the still segment that covers most of it (the later one on a tie) is taken to be the answered
/// posture, both for fitting and for scoring, so a walk to the chair just before answering never labels the
/// standing before it.
public enum ActivitySitStandConfirmations {
    /// Seconds before the answer the confirmation covers.
    public static let beforeS = 30
    /// Seconds after the answer it covers (the wrist settles after tapping the notification).
    public static let afterS = 5
    /// Label-key stretch component: `"confirmation:sitstand:<startTs>"`.
    public static let keyComponent = "sitstand"

    /// The covered window for an answer at `ts`.
    public static func window(at ts: Int) -> Range<Int> { (ts - beforeS)..<(ts + afterS) }

    /// The answer time of a confirmation label built by `label(…)`.
    public static func answerTs(of label: ActivityGroundTruthLabel) -> Int { label.endTs - afterS }

    /// A confirmation label for an answer at `ts`. "Neither" is stored too (no posture): it is a valid answer and
    /// part of the record, but neither fits nor counts toward the gate.
    public static func label(answer: ActivitySitStandAnswer, ts: Int, id: UUID = UUID(), deviceId: String? = nil,
                             externalDeviceId: String? = nil,
                             modelContextAtLabelTime: [String: String]? = nil, appVersion: String? = nil,
                             appBuild: String? = nil, createdAt: Date = Date()) -> ActivityGroundTruthLabel {
        let w = window(at: ts)
        return ActivityGroundTruthLabel(source: .confirmation, stretchKey: keyComponent, startTs: w.lowerBound,
                                        endTs: w.upperBound, id: id, deviceId: deviceId,
                                        externalDeviceId: externalDeviceId, posture: answer.posture,
                                        locomotion: answer == .neither ? nil : LocomotionClass.stationary.rawValue,
                                        modelContextAtLabelTime: modelContextAtLabelTime,
                                        appVersion: appVersion, appBuild: appBuild, createdAt: createdAt)
    }

    /// Of `parts` (ts ordered), the still seconds of the segment that covers most of `[ts - before, ts + after)`.
    static func chosenSegment(_ parts: [ActivitySitStandSmoothedSecond], window: Range<Int>) -> Int? {
        var count: [Int: Int] = [:], last: [Int: Int] = [:]
        for p in parts where window.contains(p.ts) && p.smoothedLogOdds != nil {
            guard let seg = p.segment else { continue }
            count[seg, default: 0] += 1
            last[seg] = max(last[seg] ?? Int.min, p.ts)
        }
        return count.keys.max { a, b in
            count[a]! != count[b]! ? count[a]! < count[b]! : last[a]! < last[b]!
        }
    }
}

// MARK: - Fitting

public struct ActivitySitStandFitConfig: Codable, Equatable, Sendable {
    /// L2 strength in standardised feature space (ssmodel.py `Logit`: balanced class weights summing to 1, loss
    /// Σ wᵢ NLLᵢ + λ/2 ‖θ − prior‖², the intercept penalised at 1 %). With no validated WHOOP-frame population
    /// model the prior is zero weights and a bias of log(class prior) = 0 under balanced weighting, so the measured
    /// arm that matches is "pers" (λ = 0.05 toward zero): Capture-24 orientation-only bacc 0.66–0.68, within
    /// 0.01–0.04 of λ = 0.3 toward the POPULATION model (which we do not have); λ = 3 lost 0.04–0.06. λ = 0.3
    /// toward ZERO was never measured. The bound it implies: ‖θ‖ ≤ √(2 ln 2 / λ) ≈ 5.3 per standardised unit.
    public static let defaultLambda = 0.05
    public var lambda: Double = defaultLambda
    /// Each posture needs this many labelled still seconds before a model is fitted.
    public var minClassSeconds: Int = 60
    /// Guided holds lose this many seconds at the start (the wearer settles) and at the end, beyond the label's
    /// own cue guards: the HSMM fitter's trims (`ActivityPersonalProfileFitter.settleSeconds` / `endGuardSeconds`).
    public var settleSeconds: Int = ActivityPersonalProfileFitter.settleSeconds
    public var endGuardSeconds: Int = ActivityPersonalProfileFitter.endGuardSeconds
    /// Floor on the per-feature scale used to standardise: a wearer whose arm barely moves in calibration would
    /// otherwise get an unbounded weight on a tiny wobble.
    public var minScale: Double = 0.05
    /// Whether confirmation labels contribute (guided holds always do).
    public var useConfirmations: Bool = true

    public init() {}
}

public enum ActivitySitStandFitStatus: String, Codable, Sendable {
    case fitted
    /// Fewer than `minClassSeconds` labelled still seconds of sitting or of standing.
    case needsMoreData = "needs_more_data"
}

public struct ActivitySitStandFitResult: Equatable, Sendable {
    public var status: ActivitySitStandFitStatus
    /// nil unless `.fitted`.
    public var model: ActivitySitStandModel?
    /// Labelled still seconds per class (whether or not fitted).
    public var sittingSeconds: Int
    public var standingSeconds: Int
    public var minClassSeconds: Int
    /// Seconds still needed per class (0 when there are enough).
    public var sittingSecondsNeeded: Int { max(0, minClassSeconds - sittingSeconds) }
    public var standingSecondsNeeded: Int { max(0, minClassSeconds - standingSeconds) }
}

public enum ActivitySitStandFitter {
    /// Fit the head from `labels` (guided holds of seatedLikely / uprightStationary with no transition kind, and
    /// confirmation labels) over the 1 Hz `gravity` stream that covers them. Only still seconds count. Unsure,
    /// stretch-feedback and imported labels are ignored; a second two labels disagree on is dropped. Deterministic.
    public static func fit(labels: [ActivityGroundTruthLabel], gravity: [GravitySample], steps: [StepSample] = [],
                           config: ActivitySitStandFitConfig = ActivitySitStandFitConfig()) -> ActivitySitStandFitResult {
        fit(labels: labels, seconds: ActivitySitStandSecond.seconds(gravity: gravity, steps: steps), config: config)
    }

    /// `fit(labels:gravity:config:)` over prepared seconds.
    public static func fit(labels: [ActivityGroundTruthLabel], seconds: [ActivitySitStandSecond],
                           config: ActivitySitStandFitConfig = ActivitySitStandFitConfig()) -> ActivitySitStandFitResult {
        let samples = labelledStillSeconds(labels: labels, seconds: seconds, config: config)
        let sit = samples.rows.filter { $0.sitting }.count
        let stand = samples.rows.count - sit
        var result = ActivitySitStandFitResult(status: .needsMoreData, model: nil, sittingSeconds: sit,
                                               standingSeconds: stand, minClassSeconds: config.minClassSeconds)
        guard sit >= config.minClassSeconds, stand >= config.minClassSeconds, sit > 0, stand > 0 else { return result }
        guard var model = logistic(samples.rows, lambda: config.lambda, minScale: config.minScale) else { return result }
        model.sittingSeconds = sit
        model.standingSeconds = stand
        model.sessionIds = samples.sessions
        model.confirmations = samples.confirmations
        result.status = .fitted
        result.model = model
        return result
    }

    struct Row {
        var u: (Double, Double, Double)
        var sitting: Bool
    }

    /// The labelled still seconds: (unit vector, class) rows in ts order, plus the contributing sessions.
    static func labelledStillSeconds(labels: [ActivityGroundTruthLabel], seconds: [ActivitySitStandSecond],
                                     config: ActivitySitStandFitConfig)
        -> (rows: [Row], sessions: [String], confirmations: Int) {
        // Segments and still flags with a neutral model (log-odds 0): the smoothed value is only used to know
        // which seconds are still and which segment they are in.
        let parts = ActivitySitStandSmoothing.segment(seconds)
        var partAt: [Int: ActivitySitStandSmoothing.Part] = [:]
        for p in parts { partAt[p.second.ts] = p }
        let neutral = parts.map {
            ActivitySitStandSmoothedSecond(ts: $0.second.ts, segment: $0.segment, logOdds: $0.still ? 0 : nil,
                                           smoothedLogOdds: $0.still ? 0 : nil)
        }

        var truth: [Int: Bool] = [:]
        var conflicted = Set<Int>()
        var sessions = Set<String>()
        var confirmations = 0
        func mark(_ ts: Int, _ sitting: Bool) -> Bool {
            guard let p = partAt[ts], p.still else { return false }
            if let have = truth[ts], have != sitting { conflicted.insert(ts) } else { truth[ts] = sitting }
            return true
        }
        for label in labels.sorted(by: { ($0.startTs, $0.labelKey) < ($1.startTs, $1.labelKey) }) where !label.userUnsure {
            guard let answer = ActivitySitStandAnswer(posture: label.posture), label.transitionKind == nil,
                  label.locomotion == nil || label.locomotion == LocomotionClass.stationary.rawValue else { continue }
            let sitting = answer == .sitting
            switch label.source {
            case .guided:
                let lo = label.startTs + config.settleSeconds, hi = label.endTs - config.endGuardSeconds
                guard lo < hi else { continue }
                var any = false
                for t in lo..<hi where mark(t, sitting) { any = true }
                if any, let id = label.sessionId { sessions.insert(id) }
            case .confirmation:
                guard config.useConfirmations, label.endTs > label.startTs else { continue }
                let window = label.startTs..<label.endTs
                let slice = neutral.filter { window.contains($0.ts) }
                guard let seg = ActivitySitStandConfirmations.chosenSegment(slice, window: window) else { continue }
                var any = false
                for p in slice where p.segment == seg && mark(p.ts, sitting) { any = true }
                if any { confirmations += 1 }
            case .stretchFeedback, .imported:
                continue
            }
        }
        for t in conflicted { truth[t] = nil }
        let rows = truth.keys.sorted().compactMap { t -> Row? in
            guard let u = partAt[t]?.second.unit else { return nil }
            return Row(u: u, sitting: truth[t]!)
        }
        return (rows, sessions.sorted(), confirmations)
    }

    /// Balanced-weight, L2-shrunk logistic regression (ssmodel.py `Logit`) by damped Newton steps in standardised
    /// space, mapped back to raw unit-vector weights. nil if the optimisation does not produce finite weights.
    static func logistic(_ rows: [Row], lambda: Double, minScale: Double) -> ActivitySitStandModel? {
        let n = rows.count
        guard n > 0 else { return nil }
        // Standardise.
        var mean = [0.0, 0.0, 0.0]
        for r in rows { mean[0] += r.u.0; mean[1] += r.u.1; mean[2] += r.u.2 }
        for j in 0..<3 { mean[j] /= Double(n) }
        var sd = [0.0, 0.0, 0.0]
        for r in rows {
            let d = [r.u.0 - mean[0], r.u.1 - mean[1], r.u.2 - mean[2]]
            for j in 0..<3 { sd[j] += d[j] * d[j] }
        }
        let scale = sd.map { max(minScale, ($0 / Double(n)).squareRoot()) }
        let xs: [[Double]] = rows.map { r in
            [(r.u.0 - mean[0]) / scale[0], (r.u.1 - mean[1]) / scale[1], (r.u.2 - mean[2]) / scale[2], 1]
        }
        let ys = rows.map { $0.sitting ? 1.0 : 0.0 }
        let nPos = ys.reduce(0, +), nNeg = Double(n) - nPos
        let ws = ys.map { $0 > 0 ? 0.5 / max(1, nPos) : 0.5 / max(1, nNeg) }
        // Prior: zero weights, bias = log(class prior) = 0 under balanced weighting.
        let prior = [0.0, 0.0, 0.0, 0.0]
        let pen = [lambda, lambda, lambda, 0.01 * lambda]

        func loss(_ th: [Double]) -> Double {
            var l = 0.0
            for i in 0..<n {
                let z = zip(xs[i], th).reduce(0) { $0 + $1.0 * $1.1 }
                // log(1 + e^z) - y z, computed stably.
                let softplus = z > 0 ? z + log1p(exp(-z)) : log1p(exp(z))
                l += ws[i] * (softplus - ys[i] * z)
            }
            for j in 0..<4 { l += 0.5 * pen[j] * (th[j] - prior[j]) * (th[j] - prior[j]) }
            return l
        }

        var theta = prior
        var current = loss(theta)
        for _ in 0..<100 {
            var g = [Double](repeating: 0, count: 4)
            var h = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
            for i in 0..<n {
                let z = zip(xs[i], theta).reduce(0) { $0 + $1.0 * $1.1 }
                let p = 1 / (1 + exp(-min(30, max(-30, z))))
                let r = ws[i] * (p - ys[i]), c = ws[i] * p * (1 - p)
                for a in 0..<4 {
                    g[a] += r * xs[i][a]
                    for b in 0..<4 { h[a][b] += c * xs[i][a] * xs[i][b] }
                }
            }
            for j in 0..<4 { g[j] += pen[j] * (theta[j] - prior[j]); h[j][j] += pen[j] }
            guard let step = solve4(h, g) else { break }
            // Backtracking: halve the step until the loss does not rise (Newton on a convex loss rarely needs it).
            var t = 1.0, accepted = false
            for _ in 0..<30 {
                let cand = (0..<4).map { theta[$0] - t * step[$0] }
                let l = loss(cand)
                if l.isFinite, l <= current { theta = cand; current = l; accepted = true; break }
                t *= 0.5
            }
            let size = step.reduce(0) { $0 + abs($1) } * t
            if !accepted || size < 1e-10 { break }
        }
        // Back to raw unit-vector space: θ·((u − m)/s) + b.
        var w = [theta[3], theta[0] / scale[0], theta[1] / scale[1], theta[2] / scale[2]]
        w[0] -= w[1] * mean[0] + w[2] * mean[1] + w[3] * mean[2]
        guard w.allSatisfy(\.isFinite) else { return nil }
        return ActivitySitStandModel(weights: w, center: mean, scale: scale, lambda: lambda)
    }

    /// Solve the 4×4 system H x = g by Gaussian elimination with partial pivoting.
    static func solve4(_ hIn: [[Double]], _ gIn: [Double]) -> [Double]? {
        var a = hIn, b = gIn
        let n = 4
        for col in 0..<n {
            var piv = col
            for r in col..<n where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            guard abs(a[piv][col]) > 1e-300 else { return nil }
            if piv != col { a.swapAt(piv, col); b.swapAt(piv, col) }
            for r in (col + 1)..<n {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for c in col..<n { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<n { s -= a[r][c] * x[c] }
            x[r] = s / a[r][r]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }
}

// MARK: - Verification gate

/// What the head said at a confirmation.
public enum ActivitySitStandPrediction: String, Codable, Sendable {
    case sitting, standing
    /// Still and scorable, but the smoothed log-odds were within `ActivitySitStandGate.unresolvedMargin` of 0: an
    /// abstention. Counted as WRONG by the gate (an abstaining head must not pass by abstaining).
    case unresolved
    /// Nothing to score: no model, no data, not still, off the wrist, asleep / in bed, or a "neither" answer.
    /// Excluded from the gate.
    case unscorable
}

/// One confirmation scored against the head in force when it was answered.
public struct ActivitySitStandConfirmationScore: Codable, Equatable, Sendable {
    public var ts: Int
    public var answer: ActivitySitStandAnswer
    public var prediction: ActivitySitStandPrediction
    /// The smoothed log-odds the prediction came from (nil when unscorable).
    public var logOdds: Double?
    /// Why it is unscorable: "neither", "no_model", "no_data", "not_still", "off_wrist", "asleep".
    public var reason: String?
    /// `ActivitySitStandModel.tag` of the model that scored it.
    public var modelTag: String?
    public var gateVersion: String

    public init(ts: Int, answer: ActivitySitStandAnswer, prediction: ActivitySitStandPrediction,
                logOdds: Double? = nil, reason: String? = nil, modelTag: String? = nil,
                gateVersion: String = ActivitySitStandGate.version) {
        self.ts = ts; self.answer = answer; self.prediction = prediction; self.logOdds = logOdds
        self.reason = reason; self.modelTag = modelTag; self.gateVersion = gateVersion
    }

    /// Counts toward the gate: a sitting / standing answer and a scorable prediction (unresolved included).
    public var isScorable: Bool { answer != .neither && prediction != .unscorable }

    /// Scorable and the head named the answered posture.
    public var isCorrect: Bool {
        switch (answer, prediction) {
        case (.sitting, .sitting), (.standing, .standing): return true
        default: return false
        }
    }
}

public enum ActivitySitStandGateState: Equatable, Codable, Sendable {
    /// No fitted head: run the guided calibration (or keep confirming) first.
    case needsCalibration
    /// Still collecting: `scorable` of the last-8 window so far, `correct` of them, and how many more answers of
    /// each posture the window needs.
    case verifying(scorable: Int, correct: Int, needSitting: Int, needStanding: Int)
    /// The head may speak: "Likely sitting / Likely standing".
    case enabled
    /// Eight scorable confirmations and fewer than six right: the head is not reliable for this wearer.
    case notReliable
}

public struct ActivitySitStandGateDecision: Equatable, Codable, Sendable {
    public var state: ActivitySitStandGateState
    /// Over the last `window` scorable confirmations.
    public var scorable: Int
    public var correct: Int
    public var sittingAnswers: Int
    public var standingAnswers: Int
    /// Confirmations left out as unscorable (all of them, not just the window).
    public var excluded: Int
    public var gateVersion: String
    public var modelVersion: String?
    public var modelTag: String?

    public var isEnabled: Bool { state == .enabled }
}

/// The verification gate (findings: "≥ 6 of the last 8 user-confirmed bouts"). Rolling: it is re-evaluated on
/// the latest window every time, so an enabled wearer whose arm habits drift drops back.
public enum ActivitySitStandGate {
    public static let version = "sitstand-gate-1"
    /// Scorable confirmations the gate looks at (the latest ones).
    public static let window = 8
    /// Right answers in the window needed to enable.
    public static let minCorrect = 6
    /// Answers of EACH posture the window must hold to enable.
    public static let minPerPosture = 3
    /// |smoothed log-odds| below this is an abstention (`.unresolved`): about 52:48.
    public static let unresolvedMargin = 0.1

    /// Score one answer at `ts` against `model` over the seconds around it (pass at least the confirmation window
    /// `[ts - 30, ts + 5)`; more context lets the still segment's average use the whole segment, e.g. ± 10 min).
    /// Score with the model in force BEFORE this confirmation is added to the fit, then persist the score: a
    /// confirmation scored by a model fitted on it would be in-sample.
    public static func score(answer: ActivitySitStandAnswer, ts: Int, seconds: [ActivitySitStandSecond],
                             model: ActivitySitStandModel?) -> ActivitySitStandConfirmationScore {
        func unscorable(_ reason: String) -> ActivitySitStandConfirmationScore {
            ActivitySitStandConfirmationScore(ts: ts, answer: answer, prediction: .unscorable, reason: reason,
                                              modelTag: model?.tag)
        }
        if answer == .neither { return unscorable("neither") }
        guard let model, model.isUsable else { return unscorable("no_model") }
        let window = ActivitySitStandConfirmations.window(at: ts)
        let near = seconds.filter { abs($0.ts - ts) <= ActivitySitStandConfirmations.afterS }
        if near.contains(where: \.offWrist) { return unscorable("off_wrist") }
        if near.contains(where: \.asleep) { return unscorable("asleep") }
        let inWindow = seconds.filter { window.contains($0.ts) }
        guard inWindow.contains(where: { $0.unit != nil }) else { return unscorable("no_data") }
        let smoothed = ActivitySitStandSmoothing.smooth(seconds, model: model)
        guard let seg = ActivitySitStandConfirmations.chosenSegment(smoothed, window: window),
              let lo = smoothed.first(where: { $0.segment == seg && $0.smoothedLogOdds != nil })?.smoothedLogOdds
        else { return unscorable("not_still") }
        let prediction: ActivitySitStandPrediction = abs(lo) < unresolvedMargin ? .unresolved : (lo > 0 ? .sitting : .standing)
        return ActivitySitStandConfirmationScore(ts: ts, answer: answer, prediction: prediction, logOdds: lo,
                                                 modelTag: model.tag)
    }

    /// `score` over the store's gravity rows (awake and on the wrist assumed; use the seconds overload to mark
    /// off-wrist or asleep seconds).
    public static func score(answer: ActivitySitStandAnswer, ts: Int, gravity: [GravitySample],
                             steps: [StepSample] = [],
                             model: ActivitySitStandModel?) -> ActivitySitStandConfirmationScore {
        score(answer: answer, ts: ts, seconds: ActivitySitStandSecond.seconds(gravity: gravity, steps: steps),
              model: model)
    }

    /// The gate over the persisted scores (any order). No model → `.needsCalibration`. Of the latest `window`
    /// scorable confirmations: eight of them with fewer than `minCorrect` right → `.notReliable`; at least
    /// `minPerPosture` sitting AND standing answers and `minCorrect` right → `.enabled`; otherwise `.verifying`.
    public static func evaluate(model: ActivitySitStandModel?,
                                confirmations: [ActivitySitStandConfirmationScore]) -> ActivitySitStandGateDecision {
        let scorable = confirmations.filter(\.isScorable)
            .sorted { ($0.ts, $0.answer.rawValue) < ($1.ts, $1.answer.rawValue) }
        let recent = Array(scorable.suffix(window))
        let correct = recent.filter(\.isCorrect).count
        let sitting = recent.filter { $0.answer == .sitting }.count
        let standing = recent.filter { $0.answer == .standing }.count
        var decision = ActivitySitStandGateDecision(
            state: .needsCalibration, scorable: recent.count, correct: correct, sittingAnswers: sitting,
            standingAnswers: standing, excluded: confirmations.count - scorable.count, gateVersion: version,
            modelVersion: model?.modelVersion, modelTag: model?.tag)
        guard let model, model.isUsable else { return decision }
        if recent.count >= window, correct < minCorrect {
            decision.state = .notReliable
        } else if sitting >= minPerPosture, standing >= minPerPosture, correct >= minCorrect {
            decision.state = .enabled
        } else {
            decision.state = .verifying(scorable: recent.count, correct: correct,
                                        needSitting: max(0, minPerPosture - sitting),
                                        needStanding: max(0, minPerPosture - standing))
        }
        return decision
    }
}
