import Foundation

// ActivityContextGaitQualityFusion.swift — how an ElderNet window becomes decoder evidence, and the gait block
// the decoder reports (ELDERNET.md §5).
//
// Evidence (one channel, distinct from HART's encoder channel and from every Inertia channel, never averaged
// with either): the window's calibrated gait probability q is turned into a likelihood RATIO against π, r(gait) =
// q/π and r(non-gait) = (1 − q)/(1 − π), so a window that says q = π is exactly neutral (and the channel is
// neutral on average when π is the mean served q over the windows the decoder sees: `gaitPrior`). A fixed
// compat maps the two outcomes onto the body modes:
//   gait     = walk, briskWalk, stairs
//   non-gait = bedRest, seated, upright, vehicle, cycling
//   run, otherExercise, the four transition modes and `unknown` are neutral (L = 1)
// with an ε = 0.02 floor (the same as the Inertia heads), and L(m) = clip(Σ_y A[m,y]·r(y), 0.1, 10). The term
// is tempered like every channel and added with `isEvidence: false` (it never reduces the missing-sensor unknown
// bonus). ElderNet cannot name stairs: the stairs mode stays behind its specialist gate.
//
// `run` is neutral on purpose, and the data agree: ElderNet was fine-tuned on walking, and on VAL its served
// gait_prob on running / jogging windows averages 0.096 (3.4 % of them ≥ 0.5; cycling 0.061, vehicle 0.091), about
// π, so running reads as neither gait nor non-gait and putting run on either outcome would be wrong. With run
// neutral, a high q lifts walk / briskWalk / stairs against run and a low q lifts the non-gait modes against it
// (`testRunStaysNeutralAsMeasured` pins this). Revisit only on a new measurement.
//
// Redundancy: the weight is × (1 − ρ_HART) on seconds where HART's encoder channel speaks and × (1 − ρ_Inertia)
// on seconds where an Inertia locomotion term is active (the same wrist accelerometer; both ρ are the effective
// ones, max(config, measured ρ̂)), and the gait term then gets, per mode, only the room left under the shared
// budget after Inertia's whole pull on that mode (locomotion + posture inside its set + any specialist gate it
// opened); the brisk split gets what the gait term left.
//
// What the shared budget bounds, exactly: per second and per mode, |Inertia locomotion| + |Inertia posture (in
// S)| + Inertia's gate opening + |ElderNet gait| + |ElderNet brisk| ≤ T · max(B_acc, B_Inertia) · ln 10, each
// term counted in absolute value (no cancellation between them). It does NOT bound the other channels that also
// read the wrist: HART's encoder channel (weight 0.8), movement intensity, the gait-presence / cadence channel
// (step counter or IMU rhythm) and the gravity-orientation (posture) channel are outside it and add on top. And
// it is a per-mode bound: between two modes the log-odds can move by up to twice it (one mode pulled up by the
// full bound, the other down by the full bound).
//
// Walk vs brisk walk: on a gait window carrying the metric, a soft cadence (or speed) rule gives a ratio between
// the two modes only, renormalised inside {walk, briskWalk} against the current belief (it never changes
// P(gait)). Its weight defaults to 0: computed and logged, never applied, until validation supports it.
//
// A window applies each second while its age (since the second it was attached to) is below the model's hop.

/// The ElderNet channel of one decoder, prepared from an accepted `GaitQualityEvidenceConfig`.
struct PreparedGaitQuality: Sendable {
    let stamp: String
    let mode: GaitQualityEvidenceConfig.Mode
    /// A window applies each second while its age is below this (the model's hop).
    let holdS: Int
    /// hop / window: the share of a window's steps that is new at each hop (overlapping windows).
    let stepShare: Double
    let gaitWeight: Double
    let briskWeight: Double
    let briskRule: GaitQualityEvidenceConfig.BriskRule
    let briskCadenceSpm: Double
    let briskSpeedMps: Double
    let prior: Double
    let hartRedundancy: Double
    let inertiaRedundancy: Double
    let budget: Double

    static let gaitModes: [BodyMode] = [.walk, .briskWalk, .stairs]
    /// `run` is in neither set (neutral): its measured gait_prob is about π (see above).
    static let nonGaitModes: [BodyMode] = [.bedRest, .seated, .upright, .vehicle, .cycling]
    /// The only modes the walk-vs-brisk split moves mass between.
    static let briskPair: [BodyMode] = [.walk, .briskWalk]
    static let epsilon = 0.02
    static let lrClip: ClosedRange<Double> = 0.1...10
    /// Share of a gait mode's compat row on the gait outcome ((1 + ε) / (1 + 2ε); the rest is on non-gait).
    static let onOutcome = (1 + epsilon) / (1 + 2 * epsilon)
    /// Soft-rule scales of the brisk split.
    static let briskCadenceScale = 6.0
    static let briskSpeedScale = 0.08
    /// A stretch of reported gait needs the posterior on the gait modes to be at least this.
    static let posteriorGaitFloor = 0.5

    /// nil (with the reason) when the config refuses the model; the decoder then runs exactly as without it.
    static func prepare(_ config: GaitQualityEvidenceConfig?) -> (prepared: PreparedGaitQuality?, refusal: String?) {
        guard let config else { return (nil, nil) }
        if let why = config.evidenceRefusal { return (nil, why) }
        guard config.mode != .shadow else { return (nil, "shadow_mode") }
        guard let stamp = config.provenanceStamp else { return (nil, "no_stamp") }
        let hop = max(1, config.model.hopS)
        return (PreparedGaitQuality(stamp: stamp, mode: config.mode, holdS: hop,
                                    stepShare: Double(hop) / Double(max(1, config.model.windowS)),
                                    gaitWeight: config.gaitWeight, briskWeight: config.briskWeight,
                                    briskRule: config.briskRule, briskCadenceSpm: config.briskCadenceSpm,
                                    briskSpeedMps: config.briskSpeedMps, prior: config.gaitPrior,
                                    hartRedundancy: config.effectiveHartRedundancy,
                                    inertiaRedundancy: config.effectiveInertiaRedundancy,
                                    budget: config.accelerometerBudget), nil)
    }

    static func clip(_ x: Double) -> Double { min(lrClip.upperBound, max(lrClip.lowerBound, x)) }

    /// L per body mode for a window's gait probability (1 on neutral modes and `unknown`). Written as
    /// r_other + a·(r_own − r_other) so q = π gives exactly 1 (both ratios are exactly 1 then).
    func likelihood(_ q: Double) -> [Double] {
        let rg = max(q, 1e-9) / prior
        let rn = max(1 - q, 1e-9) / (1 - prior)
        let a = Self.onOutcome
        let lg = Self.clip(rn + a * (rg - rn))
        let ln = Self.clip(rg + a * (rn - rg))
        var L = [Double](repeating: 1, count: BodyMode.count)
        for m in Self.gaitModes { L[m.rawValue] = lg }
        for m in Self.nonGaitModes { L[m.rawValue] = ln }
        return L
    }

    /// The walk-vs-brisk ratio for a gait window that carries the rule's metric: L on walk and briskWalk (1
    /// elsewhere), and which side it favours. nil when the window is not gait or lacks the metric.
    func briskLikelihood(_ w: GaitQualityWindow) -> (L: [Double], favoursBrisk: Bool)? {
        guard w.isGait else { return nil }
        let z: Double
        switch briskRule {
        case .cadence:
            guard let c = w.cadenceSpm else { return nil }
            z = (c - briskCadenceSpm) / Self.briskCadenceScale
        case .speed:
            guard let s = w.speedMps else { return nil }
            z = (s - briskSpeedMps) / Self.briskSpeedScale
        }
        let p = acSigmoid(z)
        let e = Self.epsilon
        let rb = Self.clip(2 * (p * (1 - 2 * e) + e))
        let rw = Self.clip(2 * ((1 - p) * (1 - 2 * e) + e))
        var L = [Double](repeating: 1, count: BodyMode.count)
        L[BodyMode.walk.rawValue] = rw
        L[BodyMode.briskWalk.rawValue] = rb
        return (L, p > 0.5)
    }

    /// Per-second weights after the redundancy discounts (each overlap discounted on its own, so a second where
    /// both HART and Inertia speak keeps (1 − ρ_H)(1 − ρ_I) of the weight).
    func effectiveWeights(hartSpeaks: Bool, inertiaLocomotionSpeaks: Bool) -> (gait: Double, brisk: Double) {
        var g = gaitWeight, b = briskWeight
        if hartSpeaks { g *= min(1, max(0, 1 - hartRedundancy)) }
        if inertiaLocomotionSpeaks {
            let k = min(1, max(0, 1 - inertiaRedundancy))
            g *= k; b *= k
        }
        return (min(g, budget), min(b, budget))
    }

    /// Everything ElderNet contributes at one second, before the shared budget.
    struct Terms {
        var gait: (L: [Double], weight: Double)?
        var brisk: (L: [Double], weight: Double)?
        /// The brisk rule's verdict (logged even at weight 0); nil when it had nothing to say.
        var favoursBrisk: Bool?
    }

    func gaitTerms(for window: GaitQualityWindow, hartSpeaks: Bool, inertiaLocomotionSpeaks: Bool) -> Terms {
        let w = effectiveWeights(hartSpeaks: hartSpeaks, inertiaLocomotionSpeaks: inertiaLocomotionSpeaks)
        var t = Terms()
        t.gait = (likelihood(window.gaitProb), w.gait)
        if let b = briskLikelihood(window) {
            t.favoursBrisk = b.favoursBrisk
            t.brisk = (b.L, w.brisk)
        }
        return t
    }
}

// MARK: - Reported gait block

/// ElderNet's gait metrics over a stretch of detected gait: on a published state, the current walking stretch
/// (present only while the decoder's posterior is on the gait modes and ElderNet detects gait); on a run, an
/// interval or a class aggregate, every gait window inside it. REPORTED, never decoder evidence in v1.
///
/// Means are over the windows that carry each metric (`*Windows`; written only when they differ from
/// `windows`). `steps` is an estimate for the stretch: each window's steps × hop / window, since consecutive
/// windows overlap.
public struct ActivityGaitSummary: Codable, Equatable, Sendable {
    /// Start of the first gait window counted (unix seconds).
    public var since: Int?
    /// ElderNet gait windows counted.
    public var windows: Int
    /// Mean `gait_prob` over them.
    public var gaitProbability: Double
    public var speedMps: Double?
    public var cadenceSpm: Double?
    public var strideM: Double?
    public var regularity: Double?
    public var steps: Double?
    public var speedWindows: Int
    public var cadenceWindows: Int
    public var strideWindows: Int
    public var regularityWindows: Int
    public var stepsWindows: Int
    /// The gait provenance stamp (`eldernet:<model_version>:<weights12>:<cfgtag>`).
    public var provenance: String

    public init(since: Int?, windows: Int, gaitProbability: Double, speedMps: Double? = nil, cadenceSpm: Double? = nil,
                strideM: Double? = nil, regularity: Double? = nil, steps: Double? = nil,
                speedWindows: Int? = nil, cadenceWindows: Int? = nil, strideWindows: Int? = nil,
                regularityWindows: Int? = nil, stepsWindows: Int? = nil, provenance: String) {
        self.since = since; self.windows = windows; self.gaitProbability = gaitProbability
        self.speedMps = speedMps; self.cadenceSpm = cadenceSpm; self.strideM = strideM
        self.regularity = regularity; self.steps = steps
        self.speedWindows = speedWindows ?? (speedMps == nil ? 0 : windows)
        self.cadenceWindows = cadenceWindows ?? (cadenceSpm == nil ? 0 : windows)
        self.strideWindows = strideWindows ?? (strideM == nil ? 0 : windows)
        self.regularityWindows = regularityWindows ?? (regularity == nil ? 0 : windows)
        self.stepsWindows = stepsWindows ?? (steps == nil ? 0 : windows)
        self.provenance = provenance
    }

    enum CodingKeys: String, CodingKey {
        case since, windows, gaitProbability = "gait_probability", speedMps = "speed_mps"
        case cadenceSpm = "cadence_spm", strideM = "stride_m", regularity, steps
        case speedWindows = "speed_windows", cadenceWindows = "cadence_windows", strideWindows = "stride_windows"
        case regularityWindows = "regularity_windows", stepsWindows = "steps_windows", provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        since = try c.decodeIfPresent(Int.self, forKey: .since)
        let n = try c.decode(Int.self, forKey: .windows)
        windows = n
        gaitProbability = try c.decode(Double.self, forKey: .gaitProbability)
        let speed = try c.decodeIfPresent(Double.self, forKey: .speedMps)
        let cadence = try c.decodeIfPresent(Double.self, forKey: .cadenceSpm)
        let stride = try c.decodeIfPresent(Double.self, forKey: .strideM)
        let reg = try c.decodeIfPresent(Double.self, forKey: .regularity)
        let st = try c.decodeIfPresent(Double.self, forKey: .steps)
        speedMps = speed; cadenceSpm = cadence; strideM = stride; regularity = reg; steps = st
        func count(_ key: CodingKeys, _ value: Double?) throws -> Int {
            try c.decodeIfPresent(Int.self, forKey: key) ?? (value == nil ? 0 : n)
        }
        speedWindows = try count(.speedWindows, speed)
        cadenceWindows = try count(.cadenceWindows, cadence)
        strideWindows = try count(.strideWindows, stride)
        regularityWindows = try count(.regularityWindows, reg)
        stepsWindows = try count(.stepsWindows, st)
        provenance = try c.decode(String.self, forKey: .provenance)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func r(_ x: Double, _ scale: Double) -> Double { (x * scale).rounded() / scale }
        try c.encodeIfPresent(since, forKey: .since)
        try c.encode(windows, forKey: .windows)
        try c.encode(r(gaitProbability, 1000), forKey: .gaitProbability)
        try c.encodeIfPresent(speedMps.map { r($0, 100) }, forKey: .speedMps)
        try c.encodeIfPresent(cadenceSpm.map { r($0, 10) }, forKey: .cadenceSpm)
        try c.encodeIfPresent(strideM.map { r($0, 100) }, forKey: .strideM)
        try c.encodeIfPresent(regularity.map { r($0, 1000) }, forKey: .regularity)
        try c.encodeIfPresent(steps.map { r($0, 10) }, forKey: .steps)
        // Per-metric counts only when they differ from `windows` (every gait window normally carries every metric).
        let counts: [(CodingKeys, Int, Double?)] = [
            (.speedWindows, speedWindows, speedMps), (.cadenceWindows, cadenceWindows, cadenceSpm),
            (.strideWindows, strideWindows, strideM), (.regularityWindows, regularityWindows, regularity),
            (.stepsWindows, stepsWindows, steps),
        ]
        for (key, n, value) in counts where n != (value == nil ? 0 : windows) { try c.encode(n, forKey: key) }
        try c.encode(provenance, forKey: .provenance)
    }
}

/// Running sums behind an `ActivityGaitSummary` (exact while decoding; counts are Doubles so an interval cut into
/// parts can carry its share). Part of the decoder snapshot while the gait channel is active.
struct GaitTotals: Codable, Equatable, Sendable {
    struct Sum: Codable, Equatable, Sendable {
        var s = 0.0
        var n = 0.0
        mutating func add(_ x: Double?) { if let x { s += x; n += 1 } }
        var mean: Double? { n > 0 ? s / n : nil }
    }

    var since: Int?
    var windows = 0.0
    var prob = 0.0
    var speed = Sum()
    var cadence = Sum()
    var stride = Sum()
    var regularity = Sum()
    /// Steps already scaled by the hop share; `n` counts the windows that carried a step count.
    var steps = Sum()
    var provenance: String

    init(since: Int?, provenance: String) {
        self.since = since; self.provenance = provenance
    }

    /// Count one gait window.
    mutating func add(_ w: GaitQualityWindow, stepShare: Double) {
        if since == nil { since = w.startTs }
        windows += 1
        prob += w.gaitProb
        speed.add(w.speedMps); cadence.add(w.cadenceSpm); stride.add(w.strideM); regularity.add(w.regularity)
        if let s = w.steps { steps.s += s * stepShare; steps.n += 1 }
    }

    mutating func add(_ o: GaitTotals) {
        if let s = o.since { since = min(since ?? s, s) }
        windows += o.windows; prob += o.prob
        for (k, v) in [(\GaitTotals.speed, o.speed), (\.cadence, o.cadence), (\.stride, o.stride),
                       (\.regularity, o.regularity), (\.steps, o.steps)] {
            self[keyPath: k].s += v.s
            self[keyPath: k].n += v.n
        }
    }

    func scaled(_ f: Double) -> GaitTotals {
        var out = self
        out.windows *= f; out.prob *= f
        for k in [\GaitTotals.speed, \.cadence, \.stride, \.regularity, \.steps] {
            out[keyPath: k].s *= f
            out[keyPath: k].n *= f
        }
        return out
    }

    /// What `self` (a later reading of one stretch) added since `earlier`. Never negative.
    func minus(_ earlier: GaitTotals) -> GaitTotals {
        var out = self
        out.windows = max(0, windows - earlier.windows); out.prob = max(0, prob - earlier.prob)
        for k in [\GaitTotals.speed, \.cadence, \.stride, \.regularity, \.steps] {
            out[keyPath: k].s = max(0, self[keyPath: k].s - earlier[keyPath: k].s)
            out[keyPath: k].n = max(0, self[keyPath: k].n - earlier[keyPath: k].n)
        }
        return out
    }

    var isEmpty: Bool { windows <= 1e-9 }

    var summary: ActivityGaitSummary {
        func n(_ x: Double) -> Int { Int(min(1e9, max(0, x)).rounded()) }
        return ActivityGaitSummary(
            since: since, windows: n(windows), gaitProbability: windows > 0 ? prob / windows : 0,
            speedMps: speed.mean, cadenceSpm: cadence.mean, strideM: stride.mean, regularity: regularity.mean,
            steps: steps.n > 0 ? steps.s : nil,
            speedWindows: n(speed.n), cadenceWindows: n(cadence.n), strideWindows: n(stride.n),
            regularityWindows: n(regularity.n), stepsWindows: n(steps.n), provenance: provenance)
    }

    init(summary g: ActivityGaitSummary) {
        since = g.since; provenance = g.provenance
        windows = Double(g.windows)
        prob = g.gaitProbability * Double(g.windows)
        func sum(_ mean: Double?, _ count: Int) -> Sum {
            guard let mean else { return Sum() }
            return Sum(s: mean * Double(count), n: Double(count))
        }
        speed = sum(g.speedMps, g.speedWindows); cadence = sum(g.cadenceSpm, g.cadenceWindows)
        stride = sum(g.strideM, g.strideWindows); regularity = sum(g.regularity, g.regularityWindows)
        steps = g.steps.map { Sum(s: $0, n: Double(g.stepsWindows)) } ?? Sum()
    }
}

extension ActivityGaitSummary {
    /// Two summaries as one (weighted by their window counts). The first provenance is kept.
    public func combined(with other: ActivityGaitSummary) -> ActivityGaitSummary {
        var t = GaitTotals(summary: self)
        t.add(GaitTotals(summary: other))
        return t.summary
    }

    /// Combine optional summaries (nil when both are).
    static func combine(_ a: ActivityGaitSummary?, _ b: ActivityGaitSummary?) -> ActivityGaitSummary? {
        guard let a else { return b }
        guard let b else { return a }
        return a.combined(with: b)
    }
}
