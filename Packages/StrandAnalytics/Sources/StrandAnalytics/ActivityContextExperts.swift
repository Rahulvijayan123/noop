import Foundation

// ActivityContextExperts.swift — the specialist evidence the decoder fuses beside its own stream features:
// HART's fine-grained activity distribution and ElderNet's wrist gait detector. Both are read as
// LIKELIHOODS of the body (and arm) modes, never as votes, and each only speaks about what it was trained
// to tell apart.
//
// HART (`wisdm-act-1`). HART's head is an 18-way softmax over the WISDM-19 watch activities. The manifest
// folds it into four coarse labels, which throws away exactly what matters here: sitting vs standing,
// stairs, typing / writing (desk work), eating / drinking / brushing (repetitive hand motion), ball sports
// and clapping. WISDM's protocol has every subject perform every activity for the same three minutes, so
// its class prior is flat and the softmax is (up to a constant) a scaled likelihood p(x | activity) — the
// hybrid HMM/ANN reading of a classifier. The body-mode likelihood is then
//     L(m) ∝ Σ_a p(a | x) · P(a | m)
// with P(a | m) "what HART would call this window if the body were in mode m" (`bodyRows`, each row a
// distribution), mixed with a uniform floor ε because HART is uncalibrated and moved from 20 Hz WISDM to a
// 100 Hz strap. The `unknown` mode is the uniform row: an activity HART was never shown explains every
// output equally, so a flat or out-of-vocabulary HART window lends `unknown` relative weight instead of
// forcing a mode. Modes HART cannot see (lying, cycling, a vehicle) take the row of what their wrist looks
// like to HART, so HART neither confirms nor refutes them against seated rest; other channels decide.
//
// ElderNet (`gait-quality-1`, ELDERNET.md). A ResNet-18 fine-tuned on Mobilise-D wrist gait, run on 10 s of
// 30 Hz accelerometer. Its gait probability q becomes a likelihood ratio against π, the mean served q:
// r(gait) = q/π for walk / brisk walk / stairs and r(non-gait) = (1 − q)/(1 − π) for the still and
// seated-moving modes. Running, other exercise, the four transitions and `unknown` are neutral: on held-out
// running and jogging windows ElderNet's mean q is ≈ π (it was never trained on them), so it may not vote
// on them. HART reads the same wrist accelerometer, so the channel is discounted while HART speaks.

/// One ElderNet window (10 s, 30 Hz accelerometer) from the optional gait expert.
public struct ActivityGaitWindow: Equatable, Sendable {
    public var startTs: Int
    public var endTs: Int
    /// Detector probability of gait (0 on pre-filtered, static windows).
    public var gaitProb: Double
    /// `gaitProb` at or above the served threshold, on a window that was not pre-filtered.
    public var isGait: Bool
    /// The window was static (per-axis variance under upstream's ceiling) and never reached the network.
    public var prefiltered: Bool
    /// Gait-quality heads, present on gait windows only.
    public var cadenceSpm: Double?
    public var speedMps: Double?
    public var strideM: Double?
    public var regularity: Double?
    public var steps: Double?
    public var modelVersion: String

    public init(startTs: Int, endTs: Int, gaitProb: Double, isGait: Bool, prefiltered: Bool = false,
                cadenceSpm: Double? = nil, speedMps: Double? = nil, strideM: Double? = nil,
                regularity: Double? = nil, steps: Double? = nil, modelVersion: String) {
        self.startTs = startTs; self.endTs = endTs; self.gaitProb = gaitProb; self.isGait = isGait
        self.prefiltered = prefiltered; self.cadenceSpm = cadenceSpm; self.speedMps = speedMps
        self.strideM = strideM; self.regularity = regularity; self.steps = steps
        self.modelVersion = modelVersion
    }
}

/// An ElderNet window as decoder evidence (held in the feature window, so Codable for snapshots).
public struct GaitExpertEvidence: Codable, Equatable, Sendable {
    public var gaitProb: Double
    public var isGait: Bool
    public var prefiltered: Bool
    public var cadenceSpm: Double?
    public var speedMps: Double?
    public var modelVersion: String
    /// End second of the window (what the evidence describes is the 10 s before it).
    public var endTs: Int

    public init(gaitProb: Double, isGait: Bool, prefiltered: Bool, cadenceSpm: Double? = nil,
                speedMps: Double? = nil, modelVersion: String, endTs: Int) {
        self.gaitProb = gaitProb; self.isGait = isGait; self.prefiltered = prefiltered
        self.cadenceSpm = cadenceSpm; self.speedMps = speedMps; self.modelVersion = modelVersion
        self.endTs = endTs
    }

    public init(window w: ActivityGaitWindow) {
        self.init(gaitProb: w.gaitProb, isGait: w.isGait, prefiltered: w.prefiltered, cadenceSpm: w.cadenceSpm,
                  speedMps: w.speedMps, modelVersion: w.modelVersion, endTs: w.endTs)
    }

    enum CodingKeys: String, CodingKey {
        case gaitProb = "gait_prob", isGait = "is_gait", prefiltered
        case cadenceSpm = "cadence_spm", speedMps = "speed_mps"
        case modelVersion = "model_version", endTs = "e"
    }
}

// MARK: - HART fine-grained activities

enum HartFineActivities {
    static let schema = "wisdm-act-1"
    /// Canonical order of the 18 WISDM-19 watch activities (letters A–S without N). Never reorder: the
    /// persisted `h` rows follow it.
    static let names = ["walking", "jogging", "stairs", "sitting", "standing", "typing", "brushing_teeth",
                        "eating_soup", "eating_chips", "eating_pasta", "drinking", "eating_sandwich", "kicking",
                        "playing_catch", "dribbling", "writing", "clapping", "folding_clothes"]
    static let index: [String: Int] = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
    static let count = names.count

    /// Uniform floor mixed into every P(a | m) row: HART is uncalibrated and off its training domain.
    static let epsilon = 0.25

    /// The window's distribution in canonical order, renormalized over the names it knows (unknown keys
    /// ignored). nil when nothing usable is present.
    static func vector(_ fine: [String: Double]) -> [Double]? {
        var v = [Double](repeating: 0, count: count)
        var total = 0.0
        for (i, name) in names.enumerated() {
            if let p = fine[name], p.isFinite, p > 0 { v[i] = p; total += p }
        }
        guard total > 0 else { return nil }
        return v.map { $0 / total }
    }

    private static func row(_ weights: [String: Double]) -> [Double] {
        var r = [Double](repeating: 0, count: count)
        for (name, w) in weights { if let i = index[name] { r[i] += w } }
        let t = r.reduce(0, +)
        return r.map { (1 - epsilon) * $0 / t + epsilon / Double(count) }
    }

    private static let eating: [String: Double] = ["eating_soup": 1, "eating_chips": 1, "eating_pasta": 1,
                                                    "eating_sandwich": 1, "drinking": 1]
    private static func with(_ base: [String: Double], _ extra: [String: Double], scale: Double = 1) -> [String: Double] {
        var out = base
        for (k, v) in extra { out[k, default: 0] += v * scale }
        return out
    }

    private static let seatedRow = row(with(["sitting": 40, "typing": 15, "writing": 10, "standing": 8,
                                              "folding_clothes": 3, "brushing_teeth": 2, "clapping": 2, "walking": 2],
                                             eating, scale: 3))
    private static let uprightRow = row(with(["standing": 40, "sitting": 12, "folding_clothes": 10, "brushing_teeth": 8,
                                               "typing": 3, "writing": 3, "clapping": 4, "dribbling": 2,
                                               "playing_catch": 1, "kicking": 1, "walking": 6],
                                              eating, scale: 2))
    private static let transitionRow = row(with(["sitting": 30, "standing": 30, "walking": 20, "folding_clothes": 5,
                                                  "typing": 5, "stairs": 5], eating, scale: 1))
    private static let cyclingRow = row(with(["sitting": 25, "standing": 20, "typing": 10, "writing": 5, "walking": 10,
                                               "folding_clothes": 5, "dribbling": 5, "clapping": 5, "jogging": 5],
                                              eating, scale: 1))
    private static let vehicleRow = row(with(["sitting": 40, "typing": 10, "writing": 5, "standing": 15,
                                               "folding_clothes": 5, "walking": 5, "clapping": 5, "brushing_teeth": 5],
                                              eating, scale: 2))
    private static let uniformRow = [Double](repeating: 1 / Double(count), count: count)

    /// P(activity | body mode), index == `BodyMode.rawValue`. Lying shares the seated row (HART was never
    /// shown a recumbent wrist; it reads it as sitting), cycling and vehicle rows are what a handlebar or a
    /// lap looks like to it.
    static let bodyRows: [[Double]] = BodyMode.allCases.map { mode in
        switch mode {
        case .unknown: return uniformRow
        case .bedRest, .seated: return seatedRow
        case .upright: return uprightRow
        case .walk: return row(["walking": 70, "stairs": 10, "jogging": 4, "standing": 6, "dribbling": 3,
                                "sitting": 2, "playing_catch": 2, "kicking": 2, "folding_clothes": 1])
        case .briskWalk: return row(["walking": 60, "jogging": 15, "stairs": 10, "dribbling": 4, "kicking": 3,
                                     "playing_catch": 3, "standing": 3, "clapping": 2])
        case .run: return row(["jogging": 75, "walking": 10, "dribbling": 5, "kicking": 4, "playing_catch": 3,
                               "stairs": 3])
        case .stairs: return row(["stairs": 60, "walking": 30, "jogging": 5, "standing": 5])
        case .cycling: return cyclingRow
        case .vehicle: return vehicleRow
        case .otherExercise: return row(["kicking": 15, "playing_catch": 15, "dribbling": 15, "clapping": 10,
                                         "jogging": 15, "folding_clothes": 5, "walking": 10, "standing": 5,
                                         "brushing_teeth": 5, "stairs": 5])
        case .sitToStand, .standToSit, .lyingDown, .gettingUp: return transitionRow
        }
    }

    /// Body-mode likelihoods (index == `BodyMode.rawValue`, `unknown` included) for one window's vector.
    static func bodyLikelihood(_ p: [Double]) -> [Double] {
        bodyRows.map { r in
            var s = 0.0
            for i in 0..<count { s += p[i] * r[i] }
            return s
        }
    }

    /// P(activity | arm class) for the arm chain, in `ArmBehaviorClass.allCases` order (unknown last,
    /// uniform). Typing and writing are desk work; eating, drinking and brushing are repetitive hand
    /// motion; clapping and folding are gesturing; ball sports and jogging are exercise; walking and
    /// stairs are the gait swing the arm chain files under `other`.
    static let armRows: [[Double]] = ArmBehaviorClass.allCases.map { c in
        switch c {
        case .quiet: return row(["sitting": 45, "standing": 45, "typing": 5, "writing": 5])
        case .deskLike: return row(["typing": 50, "writing": 40, "sitting": 10])
        case .fidgeting: return row(["sitting": 25, "standing": 25, "typing": 10, "writing": 10, "folding_clothes": 10,
                                     "clapping": 5, "brushing_teeth": 5, "drinking": 5, "eating_chips": 5])
        case .repetitiveHandMotion: return row(with(["brushing_teeth": 25, "clapping": 5], eating, scale: 14))
        case .activeGesturing: return row(["folding_clothes": 35, "clapping": 25, "playing_catch": 10, "standing": 10,
                                           "drinking": 10, "dribbling": 10])
        case .exerciseMotion: return row(["jogging": 25, "kicking": 20, "playing_catch": 20, "dribbling": 20,
                                          "clapping": 10, "stairs": 5])
        case .other: return row(["walking": 55, "stairs": 25, "jogging": 10, "standing": 5, "sitting": 5])
        case .unknown: return uniformRow
        }
    }

    static func armLikelihood(_ p: [Double]) -> [Double] {
        armRows.map { r in
            var s = 0.0
            for i in 0..<count { s += p[i] * r[i] }
            return s
        }
    }

    /// Mass HART puts on the activities that name a specialist mode (the stairs / exercise gate).
    static func stairsMass(_ p: [Double]) -> Double { p[index["stairs"]!] }
    static func sportMass(_ p: [Double]) -> Double {
        p[index["kicking"]!] + p[index["playing_catch"]!] + p[index["dribbling"]!]
    }
}

// MARK: - ElderNet gait expert

enum GaitExpert {
    static let schema = "gait-quality-1"
    /// π: the mean served gait_prob over the windows the decoder sees (Capture-24 VAL, threshold 0.5:
    /// 0.0849, 95 % CI 0.076–0.095). With it the channel is neutral on average.
    static let prior = 0.085
    static let weight = 0.25
    /// Weight × (1 − ρ) on seconds where HART's encoder channel also speaks (same accelerometer). The
    /// measured residual correlation is 0.33 on WISDM VAL; 0.65 is the cautious floor.
    static let hartRedundancy = 0.65
    static let epsilon = 0.02
    static let clip: ClosedRange<Double> = 0.1...10
    /// A window applies to the seconds after its end while younger than the served hop (5 s) + 1.
    static let holdS = 6

    static let gaitModes: Set<BodyMode> = [.walk, .briskWalk, .stairs]
    static let nonGaitModes: Set<BodyMode> = [.bedRest, .seated, .upright, .vehicle, .cycling]

    /// Likelihood per body mode (1 on neutral modes and `unknown`); q = π gives exactly 1 everywhere.
    static func likelihood(_ q: Double) -> [Double] {
        let qq = min(1, max(0, q))
        let rg = max(qq, 1e-9) / prior
        let rn = max(1 - qq, 1e-9) / (1 - prior)
        let a = (1 + epsilon) / (1 + 2 * epsilon)
        func c(_ x: Double) -> Double { min(clip.upperBound, max(clip.lowerBound, x)) }
        let lg = c(rn + a * (rg - rn)), ln = c(rg + a * (rn - rg))
        return BodyMode.allCases.map { m in gaitModes.contains(m) ? lg : (nonGaitModes.contains(m) ? ln : 1) }
    }
}
