import Foundation

// ActivityContextModel.swift — the parameter tables and observation model behind ActivityContextDecoder.
//
// The decoder is a hidden semi-Markov model over a small set of BODY MODES. Each mode has
//   • a duration prior (mean dwell + Erlang phases, so very short stays are unlikely),
//   • an exit distribution (which modes can follow it — this is where "walking → stop → sit-like
//     transition → long quiet period" gets its meaning),
//   • fixed soft mappings onto the posture and locomotion heads (with ambiguity baked in: no mode puts
//     all of its mass on `seated_likely`, because a wrist cannot see body height),
//   • an observation profile: what each evidence channel looks like when that mode is true.
//
// Arm behaviour is a second, small chain that runs beside the body chain and is coupled to it only
// through a context prior. Heads are marginals of those two filtered posteriors; none is ever a raw
// per-window classifier output.
//
// ALL NUMBERS HERE ARE UNCALIBRATED PRIORS (decoder `hsmm-1.2`). They were set from this strap's own
// distributions where those exist (dynamic-acceleration percentiles for still / walking / running
// seconds) and from physiological plausibility elsewhere. They are versioned, centralized, and meant
// to be replaced by fitted values once labelled data exists; tests pin behaviour, not the numbers.

/// Body-level latent modes. The raw value is the index into every table below.
enum BodyMode: Int, CaseIterable, Codable {
    case unknown = 0
    case bedRest
    case seated
    case upright
    case walk
    case briskWalk
    case run
    case stairs
    case cycling
    case vehicle
    case otherExercise
    case sitToStand
    case standToSit
    case lyingDown
    case gettingUp

    static let count = BodyMode.allCases.count

    var isTransition: Bool {
        switch self {
        case .sitToStand, .standToSit, .lyingDown, .gettingUp: return true
        default: return false
        }
    }

    var isStationary: Bool {
        switch self {
        case .bedRest, .seated, .upright: return true
        default: return false
        }
    }

    var isLocomotion: Bool {
        switch self {
        case .walk, .briskWalk, .run, .stairs: return true
        default: return false
        }
    }
}

/// Index of an arm-chain state; the raw order matches `ArmBehaviorClass.allCases`.
enum ArmState {
    static let classes = ArmBehaviorClass.allCases
    static let count = classes.count
    static func index(_ c: ArmBehaviorClass) -> Int { classes.firstIndex(of: c)! }
    static let quiet = index(.quiet), desk = index(.deskLike), fidget = index(.fidgeting)
    static let repetitive = index(.repetitiveHandMotion), gesture = index(.activeGesturing)
    static let exercise = index(.exerciseMotion), other = index(.other), unknown = index(.unknown)
}

// MARK: - Small math helpers

@inline(__always) func acGauss(_ d: Double, _ sigma: Double) -> Double {
    let z = d / sigma
    return exp(-0.5 * z * z)
}

@inline(__always) func acSigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

/// 1 inside `range`, falling off as a Gaussian outside it; never below `floor`.
@inline(__always) func acSoftRange(_ x: Double, _ range: ClosedRange<Double>, sigma: Double, floor: Double = 0.03) -> Double {
    let d = x < range.lowerBound ? range.lowerBound - x : (x > range.upperBound ? x - range.upperBound : 0)
    return max(floor, acGauss(d, sigma))
}

// MARK: - Mode profile

struct ModeProfile {
    // Duration prior.
    let meanDwellS: Double
    let phases: Int
    // Who can follow this mode (weights; normalized at load).
    let exits: [(BodyMode, Double)]
    // Fixed soft mappings onto the public heads.
    let posture: [PostureClass: Double]
    let locomotion: [LocomotionClass: Double]
    // Observation profile.
    let move: ClosedRange<Double>
    let moveIsBurst: Bool
    /// Judge `move` against the 30-s median instead of the 10-s mean: recumbent rest is almost always
    /// still, with occasional bursts (turning over) that must not refute it.
    let moveIsMedian: Bool
    let gaitExpect: Double
    let cadence: ClosedRange<Double>?
    let orientPath: ClosedRange<Double>
    let expectsPostureShift: Bool
    let hrRel: Double
    let encoder: [String: Double]
    let arm: [Double]          // compat with ArmBehaviorClass cases except unknown (7 values)
    let sleepAsleep: Double
    let workout: Double
    /// Specialist modes (stairs, cycling, vehicle) have no evidence of their own in the current feature
    /// set; they are only plausible when the encoder names them.
    let requiresLabel: String?

    init(meanDwellS: Double, phases: Int, exits: [(BodyMode, Double)], posture: [PostureClass: Double],
         locomotion: [LocomotionClass: Double], move: ClosedRange<Double>, moveIsBurst: Bool,
         gaitExpect: Double, cadence: ClosedRange<Double>?, orientPath: ClosedRange<Double>,
         expectsPostureShift: Bool, hrRel: Double, encoder: [String: Double], arm: [Double],
         sleepAsleep: Double, workout: Double, requiresLabel: String? = nil, moveIsMedian: Bool = false) {
        self.meanDwellS = meanDwellS; self.phases = phases; self.exits = exits; self.posture = posture
        self.locomotion = locomotion; self.move = move; self.moveIsBurst = moveIsBurst
        self.moveIsMedian = moveIsMedian
        self.gaitExpect = gaitExpect; self.cadence = cadence; self.orientPath = orientPath
        self.expectsPostureShift = expectsPostureShift; self.hrRel = hrRel; self.encoder = encoder
        self.arm = arm; self.sleepAsleep = sleepAsleep; self.workout = workout
        self.requiresLabel = requiresLabel
    }
}

enum ActivityContextModel {

    // MARK: Tables

    /// Arm-class compat columns: quiet, desk, fidget, repetitive, gesture, exercise, other.
    private static func arm(_ q: Double, _ d: Double, _ f: Double, _ r: Double, _ g: Double, _ e: Double, _ o: Double) -> [Double] {
        let s = q + d + f + r + g + e + o
        return [q, d, f, r, g, e, o].map { $0 / s }
    }

    /// Arm-class compat for a stationary seated wrist. Recumbent rest deliberately shares it: with no sleep
    /// evidence, a quiet or desk-like wrist says nothing about lying versus sitting.
    private static let stationaryArm: [Double] = arm(0.33, 0.37, 0.12, 0.06, 0.06, 0.0, 0.06)

    private static let stationaryEnc: [String: Double] =
        ["stationary": 0.86, "other_movement": 0.10, "walking": 0.03, "running": 0.01]
    private static let transitionEnc: [String: Double] =
        ["other_movement": 0.45, "stationary": 0.35, "walking": 0.18, "running": 0.02]

    /// Index == `BodyMode.rawValue`.
    static let profiles: [ModeProfile] = [
        // unknown — re-acquisition prior; observation profile unused (flat).
        ModeProfile(meanDwellS: 15, phases: 1,
                    exits: [(.seated, 0.28), (.upright, 0.20), (.bedRest, 0.10), (.walk, 0.14), (.briskWalk, 0.04),
                            (.run, 0.02), (.stairs, 0.02), (.cycling, 0.02), (.vehicle, 0.04), (.otherExercise, 0.04),
                            (.unknown, 0.10)],
                    posture: [.unknown: 1], locomotion: [.unknown: 1],
                    move: 0...1, moveIsBurst: false, gaitExpect: 0.5, cadence: nil, orientPath: 0...2,
                    expectsPostureShift: false, hrRel: 0.3, encoder: [:], arm: arm(1, 1, 1, 1, 1, 1, 1),
                    sleepAsleep: 0.3, workout: 0.5),
        // bedRest
        ModeProfile(meanDwellS: 1800, phases: 2,
                    exits: [(.gettingUp, 0.60), (.seated, 0.10), (.upright, 0.05), (.walk, 0.05), (.unknown, 0.20)],
                    posture: [.recumbent: 0.88, .unknown: 0.12], locomotion: [.stationary: 0.97, .unknown: 0.03],
                    move: 0...0.20, moveIsBurst: false, gaitExpect: 0, cadence: nil, orientPath: 0...0.9,
                    expectsPostureShift: false, hrRel: 0.06, encoder: stationaryEnc,
                    arm: stationaryArm, sleepAsleep: 1.0, workout: 0.05, moveIsMedian: true),
        // seated
        ModeProfile(meanDwellS: 900, phases: 2,
                    exits: [(.sitToStand, 0.50), (.upright, 0.06), (.lyingDown, 0.06), (.bedRest, 0.04), (.walk, 0.06),
                            (.vehicle, 0.05), (.otherExercise, 0.02), (.briskWalk, 0.02), (.cycling, 0.02),
                            (.unknown, 0.17)],
                    posture: [.seatedLikely: 0.84, .uprightStationary: 0.10, .unknown: 0.06],
                    locomotion: [.stationary: 0.97, .unknown: 0.03],
                    move: 0...0.50, moveIsBurst: false, gaitExpect: 0, cadence: nil, orientPath: 0...0.9,
                    expectsPostureShift: false, hrRel: 0.08, encoder: stationaryEnc,
                    arm: stationaryArm, sleepAsleep: 0.2, workout: 0.35),
        // upright (standing, stationary)
        ModeProfile(meanDwellS: 100, phases: 2,
                    exits: [(.walk, 0.40), (.standToSit, 0.18), (.seated, 0.10), (.briskWalk, 0.05), (.stairs, 0.03),
                            (.run, 0.02), (.lyingDown, 0.02), (.cycling, 0.02), (.vehicle, 0.03),
                            (.otherExercise, 0.03), (.unknown, 0.12)],
                    posture: [.uprightStationary: 0.72, .seatedLikely: 0.20, .unknown: 0.08],
                    locomotion: [.stationary: 0.97, .unknown: 0.03],
                    move: 0...0.50, moveIsBurst: false, gaitExpect: 0, cadence: nil, orientPath: 0...0.9,
                    expectsPostureShift: false, hrRel: 0.12, encoder: stationaryEnc,
                    arm: arm(0.38, 0.12, 0.20, 0.08, 0.16, 0.0, 0.06), sleepAsleep: 0.2, workout: 0.6),
        // walk
        ModeProfile(meanDwellS: 90, phases: 2,
                    exits: [(.upright, 0.50), (.briskWalk, 0.10), (.stairs, 0.06), (.run, 0.04), (.seated, 0.03),
                            (.vehicle, 0.03), (.cycling, 0.03), (.otherExercise, 0.03), (.unknown, 0.18)],
                    posture: [.unknown: 1], locomotion: [.walking: 0.93, .briskWalking: 0.04, .unknown: 0.03],
                    move: 0.42...0.78, moveIsBurst: false, gaitExpect: 1, cadence: 70...125, orientPath: 0.3...1.5,
                    expectsPostureShift: false, hrRel: 0.35,
                    encoder: ["walking": 0.86, "other_movement": 0.07, "stationary": 0.05, "running": 0.02],
                    arm: arm(0.25, 0.0, 0.08, 0.04, 0.05, 0.04, 0.54), sleepAsleep: 0.04, workout: 0.9),
        // briskWalk
        ModeProfile(meanDwellS: 240, phases: 2,
                    exits: [(.walk, 0.35), (.upright, 0.25), (.run, 0.15), (.otherExercise, 0.05), (.stairs, 0.03),
                            (.seated, 0.05), (.unknown, 0.12)],
                    posture: [.unknown: 1], locomotion: [.briskWalking: 0.88, .walking: 0.08, .running: 0.02, .unknown: 0.02],
                    move: 0.55...0.88, moveIsBurst: false, gaitExpect: 1, cadence: 105...150, orientPath: 0.4...1.6,
                    expectsPostureShift: false, hrRel: 0.50,
                    encoder: ["walking": 0.72, "running": 0.12, "other_movement": 0.08, "brisk_walking": 0.06, "stationary": 0.02],
                    arm: arm(0.12, 0.0, 0.05, 0.03, 0.05, 0.15, 0.60), sleepAsleep: 0.04, workout: 1.0),
        // run
        ModeProfile(meanDwellS: 600, phases: 2,
                    exits: [(.walk, 0.35), (.upright, 0.25), (.briskWalk, 0.15), (.otherExercise, 0.05), (.seated, 0.05),
                            (.unknown, 0.15)],
                    posture: [.unknown: 1], locomotion: [.running: 0.93, .briskWalking: 0.04, .unknown: 0.03],
                    move: 0.62...1.0, moveIsBurst: false, gaitExpect: 1, cadence: 135...210, orientPath: 0.4...1.6,
                    expectsPostureShift: false, hrRel: 0.65,
                    encoder: ["running": 0.86, "walking": 0.10, "other_movement": 0.04],
                    arm: arm(0.05, 0.0, 0.03, 0.02, 0.02, 0.45, 0.43), sleepAsleep: 0.04, workout: 1.0),
        // stairs
        ModeProfile(meanDwellS: 40, phases: 2,
                    exits: [(.walk, 0.55), (.upright, 0.20), (.briskWalk, 0.08), (.seated, 0.07), (.unknown, 0.10)],
                    posture: [.unknown: 1], locomotion: [.stairs: 0.70, .walking: 0.25, .unknown: 0.05],
                    move: 0.45...0.85, moveIsBurst: false, gaitExpect: 1, cadence: 60...115, orientPath: 0.4...1.5,
                    expectsPostureShift: false, hrRel: 0.50,
                    encoder: ["stairs": 0.90, "walking": 0.60, "other_movement": 0.20, "running": 0.05],
                    arm: arm(0.20, 0.0, 0.08, 0.03, 0.05, 0.08, 0.56), sleepAsleep: 0.04, workout: 0.9,
                    requiresLabel: "stairs"),
        // cycling
        ModeProfile(meanDwellS: 1200, phases: 2,
                    exits: [(.upright, 0.35), (.walk, 0.25), (.seated, 0.15), (.vehicle, 0.05), (.otherExercise, 0.05),
                            (.unknown, 0.15)],
                    posture: [.unknown: 1], locomotion: [.cycling: 0.80, .other: 0.10, .unknown: 0.10],
                    move: 0.15...0.62, moveIsBurst: false, gaitExpect: 0.15, cadence: nil, orientPath: 0.1...1.1,
                    expectsPostureShift: false, hrRel: 0.50,
                    encoder: ["cycling": 0.90, "other_movement": 0.55, "stationary": 0.15, "walking": 0.10, "running": 0.03],
                    arm: arm(0.20, 0.0, 0.05, 0.15, 0.02, 0.30, 0.28), sleepAsleep: 0.05, workout: 1.0,
                    requiresLabel: "cycling"),
        // vehicle
        ModeProfile(meanDwellS: 900, phases: 2,
                    exits: [(.upright, 0.30), (.walk, 0.30), (.seated, 0.20), (.unknown, 0.20)],
                    posture: [.seatedLikely: 0.55, .unknown: 0.45],
                    locomotion: [.vehicleMotion: 0.80, .stationary: 0.10, .unknown: 0.10],
                    move: 0.05...0.42, moveIsBurst: false, gaitExpect: 0, cadence: nil, orientPath: 0.05...0.9,
                    expectsPostureShift: false, hrRel: 0.12,
                    encoder: ["vehicle_motion": 0.90, "stationary": 0.40, "other_movement": 0.35, "walking": 0.05],
                    arm: arm(0.35, 0.12, 0.20, 0.05, 0.08, 0.0, 0.20), sleepAsleep: 0.1, workout: 0.2,
                    requiresLabel: "vehicle_motion"),
        // otherExercise
        ModeProfile(meanDwellS: 300, phases: 2,
                    exits: [(.upright, 0.35), (.walk, 0.25), (.seated, 0.10), (.run, 0.05), (.cycling, 0.05),
                            (.briskWalk, 0.05), (.unknown, 0.15)],
                    posture: [.unknown: 1], locomotion: [.other: 0.80, .unknown: 0.20],
                    move: 0.45...1.0, moveIsBurst: false, gaitExpect: 0.35, cadence: nil, orientPath: 0.3...1.7,
                    expectsPostureShift: false, hrRel: 0.60,
                    encoder: ["other_movement": 0.70, "running": 0.20, "walking": 0.10, "stationary": 0.05],
                    arm: arm(0.05, 0.0, 0.08, 0.15, 0.10, 0.50, 0.12), sleepAsleep: 0.04, workout: 1.0,
                    requiresLabel: "other_movement"),
        // sitToStand
        ModeProfile(meanDwellS: 5, phases: 2,
                    exits: [(.upright, 0.70), (.walk, 0.25), (.unknown, 0.05)],
                    posture: [.posturalTransition: 0.80, .unknown: 0.20],
                    locomotion: [.stationary: 0.85, .other: 0.10, .unknown: 0.05],
                    move: 0.30...0.85, moveIsBurst: true, gaitExpect: 0.10, cadence: nil, orientPath: 0.5...1.7,
                    expectsPostureShift: true, hrRel: 0.20, encoder: transitionEnc,
                    arm: arm(0.20, 0.05, 0.30, 0.02, 0.10, 0.0, 0.33), sleepAsleep: 0.3, workout: 0.5),
        // standToSit
        ModeProfile(meanDwellS: 5, phases: 2,
                    exits: [(.seated, 0.90), (.unknown, 0.10)],
                    posture: [.posturalTransition: 0.80, .unknown: 0.20],
                    locomotion: [.stationary: 0.85, .other: 0.10, .unknown: 0.05],
                    move: 0.30...0.85, moveIsBurst: true, gaitExpect: 0.10, cadence: nil, orientPath: 0.5...1.7,
                    expectsPostureShift: true, hrRel: 0.20, encoder: transitionEnc,
                    arm: arm(0.20, 0.05, 0.30, 0.02, 0.10, 0.0, 0.33), sleepAsleep: 0.3, workout: 0.5),
        // lyingDown
        ModeProfile(meanDwellS: 8, phases: 2,
                    exits: [(.bedRest, 0.90), (.unknown, 0.10)],
                    posture: [.posturalTransition: 0.80, .unknown: 0.20],
                    locomotion: [.stationary: 0.85, .other: 0.10, .unknown: 0.05],
                    move: 0.25...0.85, moveIsBurst: true, gaitExpect: 0.05, cadence: nil, orientPath: 0.5...1.7,
                    expectsPostureShift: true, hrRel: 0.15, encoder: transitionEnc,
                    arm: arm(0.20, 0.05, 0.30, 0.02, 0.10, 0.0, 0.33), sleepAsleep: 0.6, workout: 0.3),
        // gettingUp
        ModeProfile(meanDwellS: 8, phases: 2,
                    exits: [(.seated, 0.35), (.upright, 0.50), (.walk, 0.10), (.unknown, 0.05)],
                    posture: [.posturalTransition: 0.80, .unknown: 0.20],
                    locomotion: [.stationary: 0.85, .other: 0.10, .unknown: 0.05],
                    move: 0.25...0.85, moveIsBurst: true, gaitExpect: 0.10, cadence: nil, orientPath: 0.5...1.7,
                    expectsPostureShift: true, hrRel: 0.20, encoder: transitionEnc,
                    arm: arm(0.20, 0.05, 0.30, 0.02, 0.10, 0.0, 0.33), sleepAsleep: 0.6, workout: 0.5),
    ]

    /// Multiplier on exit weights INTO recumbent modes, by sleep evidence. Lying down is something the
    /// band can know (sleep session) far better than a wrist can sense, so without sleep evidence the
    /// decoder makes entering it hard rather than letting a quiet wrist drift there.
    static func bedEntryScale(_ sleep: SleepEvidence) -> Double {
        switch sleep {
        case .asleep: return 1.0
        case .awake: return 0.5
        case .unknown: return 0.3
        }
    }

    /// Initial belief over modes (before any evidence): honest about not knowing.
    static let prior: [Double] = {
        var p = [Double](repeating: 0.01, count: BodyMode.count)
        p[BodyMode.unknown.rawValue] = 0.45
        p[BodyMode.seated.rawValue] = 0.17
        p[BodyMode.upright.rawValue] = 0.12
        p[BodyMode.walk.rawValue] = 0.05
        p[BodyMode.bedRest.rawValue] = 0.03
        let t = p.reduce(0, +)
        return p.map { $0 / t }
    }()

    static let armPrior: [Double] = {
        var p = [Double](repeating: 0.05, count: ArmState.count)
        p[ArmState.quiet] = 0.25; p[ArmState.desk] = 0.15; p[ArmState.unknown] = 0.30
        let t = p.reduce(0, +)
        return p.map { $0 / t }
    }()

    /// Per-second probability of staying in each arm state (mean dwell = 1 / (1 − stay)).
    static let armStay: [Double] = {
        var s = [Double](repeating: 0.92, count: ArmState.count)
        s[ArmState.quiet] = 0.97; s[ArmState.desk] = 0.96; s[ArmState.fidget] = 0.90
        s[ArmState.repetitive] = 0.94; s[ArmState.gesture] = 0.90; s[ArmState.exercise] = 0.97
        s[ArmState.other] = 0.92; s[ArmState.unknown] = 0.85
        return s
    }()

    // MARK: Channel weights and "no information" constants

    static let wMotion = 1.0, wGait = 1.0, wOrient = 0.7, wEncoder = 0.8, wArm = 0.4, wHR = 0.35, wGate = 1.0
    static let wShift = 1.0, wHRTrend = 0.6
    static let uMotion = 0.20, uGait = 0.35, uOrient = 0.35, uEncoder = 0.30, uArm = 0.25, uHR = 0.55, uGate = 0.30
    static let uShift = 0.30

    /// Fewer evidence channels than this and the unknown mode earns a bonus per missing channel.
    static let minChannels = 3
    static let missingChannelBonus = 0.6

    /// Per-second hazard (at full strength) of a clear posture-shift burst starting a transition.
    static let shiftHazard = 0.15

    /// 0…1: how strongly the last ~10 s look like a posture shift — a movement burst that left the wrist
    /// in a different orientation, with no gait. Reaching and returning does not count once the wrist
    /// has returned (the net change is measured against 5 s ago).
    static func shiftStrength(_ f: ActivityFeatures) -> Double {
        guard let net = f.shiftNet else { return 0 }
        let burst = f.mBurst10 ?? 0
        let gait = f.gaitPresence ?? 0
        return acSigmoid((net - 50) / 10) * acSigmoid((burst - 0.38) / 0.05) * (1 - min(1, gait))
    }

    // MARK: Exertion (what the heart says about effort)

    /// Heart rate as a fraction of reserve at which effort starts to count, and at which it counts fully.
    /// 0.30 of reserve is a brisk walk for most people; 0.45 is where "higher-intensity" starts.
    static let exertionStart = 0.30, exertionFull = 0.45

    /// Smooth 0…1 ramp.
    @inline(__always) static func smoothStep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// 0…1: how strongly the heart says "working hard right now". A rate well above rest that is steady or
    /// still climbing counts in full; a rate that is falling is recovery and counts for little; a steep
    /// climb counts early (the first minutes of a hard effort, before the rate has caught up).
    ///
    /// This is the only cue the strap streams offer for vigorous effort that has no gait — rowing,
    /// lifting, HIIT — which is why it alone can lift the generic-exercise mode out of its "needs a label"
    /// gate. It never makes a still wrist exercise: the movement channels still have to agree.
    static func exertion(_ f: ActivityFeatures) -> Double {
        guard let hr = f.hrRel else { return 0 }
        let level = smoothStep((hr - exertionStart) / (exertionFull - exertionStart))
        let slope = f.hrSlope ?? 0
        let falling = min(1, max(0, -slope / 6))
        let rising = min(1, max(0, slope / 6))
        let onset = rising * smoothStep((hr - 0.15) / 0.12)
        return min(1, max(0, level * (1 - 0.6 * falling) + 0.5 * onset * (1 - level)))
    }

    /// Whether a logged workout of `kind` explains `mode`. A logged run says nothing for cycling, and a
    /// logged ride says nothing for stairs; an unrecognised sport keeps the permissive behaviour.
    static func workoutCovers(_ mode: BodyMode, kind: WorkoutKind) -> Bool {
        switch kind {
        case .unspecified: return true
        case .running: return mode == .otherExercise
        case .walking: return mode == .stairs
        case .cycling: return mode == .cycling
        case .other: return mode == .otherExercise || mode == .stairs
        }
    }

    // MARK: Observation score

    struct Score {
        /// Tempered log-likelihood per body mode.
        var logL: [Double]
        /// Weighted mean of ln(L_c(mode) / max_m L_c(m)) per mode (≤ 0): how far the mode sits from the
        /// best-supported mode channel by channel. 0 = it is the best on every channel.
        var disagreement: [Double]
        /// True when the primary movement channel had data.
        var hasMotion: Bool
        var channels: Int
        /// Inertia posture term per body mode (tempered log factor, 0 outside the stationary / transition
        /// set). The decoder renormalises it inside that set against its current belief, so it moves mass only
        /// within the set. nil without Inertia posture evidence.
        var postureShift: [Double]? = nil
        /// Inertia arm-head likelihood per arm state and its weight (before `armTemperature`).
        var arm: (L: [Double], weight: Double)? = nil
        /// An Inertia term entered this second's score.
        var motionHeadsApplied = false
        /// A specialist mode was plausible this second only because Inertia named it.
        var specialistOpenedByMotionHeads = false
    }

    /// Instantaneous soft arm-behaviour likelihoods (not normalized) from movement-pattern features.
    static func armPattern(_ f: ActivityFeatures) -> [Double] {
        var q = [Double](repeating: 0.2, count: ArmState.count)
        guard let m = f.m10 ?? f.m4 else {
            q[ArmState.unknown] = 1
            return q
        }
        let burst = f.mBurst10 ?? m
        let g = f.gaitPresence ?? 0
        let notGait = 1 - 0.9 * acSigmoid((g - 0.5) / 0.15)
        let cvHigh = f.cv30.map { acSigmoid(($0 - 0.9) / 0.2) } ?? 0.5
        let cvLow = f.cv30.map { 1 - 0.9 * acSigmoid(($0 - 1.1) / 0.2) } ?? 0.7
        let path = f.orientPath10.map { log10(1 + $0) } ?? 0.4

        q[ArmState.quiet] = acSoftRange(m, 0...0.16, sigma: 0.05) * acSoftRange(burst, 0...0.38, sigma: 0.08)
        q[ArmState.desk] = acSoftRange(m, 0.18...0.50, sigma: 0.05) * notGait
            * cvLow
            * acSoftRange(path, 0...0.85, sigma: 0.2)
        q[ArmState.fidget] = acSoftRange(burst, 0.40...0.95, sigma: 0.08) * acSoftRange(m, 0.15...0.65, sigma: 0.08)
            * (0.1 + 0.9 * cvHigh) * notGait
        if let r = f.rhythm {
            q[ArmState.repetitive] = acSigmoid((r - 0.35) / 0.10) * acSoftRange(m, 0.30...0.75, sigma: 0.08) * notGait
        } else {
            q[ArmState.repetitive] = 0.15
        }
        q[ArmState.gesture] = acSoftRange(m, 0.45...0.85, sigma: 0.08) * acSigmoid((path - 0.8) / 0.15) * notGait
        var exercise = acSoftRange(m, 0.72...1.0, sigma: 0.06)
        if let hr = f.hrRel, hr >= 0.45 { exercise = max(exercise, 0.6 * acSoftRange(m, 0.5...1.0, sigma: 0.1)) }
        if f.loggedWorkout { exercise = max(exercise, 0.7) }
        // Ordinary walking swings the arm hard enough to look like exercise motion; gait explains it.
        // Running (movement above ~0.78) keeps the exercise reading.
        let walkSwing = (1 - notGait) * (1 - acSigmoid((m - 0.78) / 0.04))
        if !f.loggedWorkout { exercise *= 1 - 0.85 * walkSwing }
        q[ArmState.exercise] = exercise
        q[ArmState.other] = 0.30 + 0.5 * walkSwing
        q[ArmState.unknown] = 0.20
        return q
    }

    /// Score every body mode against the features. `motionHeads` adds the Inertia-1 channels (see
    /// `ActivityContextMotionHeadsFusion.swift`) after the existing ones; nil (the default) scores exactly
    /// as before.
    static func score(_ f: ActivityFeatures, temperature: Double,
                      motionHeads: PreparedMotionHeads? = nil) -> Score {
        let n = BodyMode.count
        var logL = [Double](repeating: 0, count: n)
        var dis = [Double](repeating: 0, count: n)
        var weightSum = 0.0
        var channels = 0
        let unknownIdx = BodyMode.unknown.rawValue
        // Inertia terms for this second (nil when Inertia is off, no window applies, or it is OOD).
        var inertia: PreparedMotionHeads.Terms? = nil
        if let motionHeads, let window = f.motionHeads {
            inertia = motionHeads.terms(for: window, hartSpeaks: f.encoder != nil)
        }
        var specialistOpenedByMotionHeads = false

        // Accumulate one channel: `values[m]` are per-mode likelihoods in (0, 1]; `unknownValue` is the
        // constant the unknown mode gets (no discrimination).
        func add(_ values: [Double], unknownValue: Double, weight: Double, isEvidence: Bool = true) {
            if isEvidence { channels += 1 }
            weightSum += weight
            let best = max(values.max() ?? 1, 1e-6)
            for m in 0..<n {
                if m == unknownIdx {
                    logL[m] += weight * log(unknownValue)
                    dis[m] += weight * min(0, log(unknownValue / best))
                } else {
                    let v = max(values[m], 1e-6)
                    logL[m] += weight * log(v)
                    dis[m] += weight * log(v / best)
                }
            }
        }

        // 1. Movement intensity.
        var hasMotion = false
        if let m10 = f.m10 {
            hasMotion = true
            var v = [Double](repeating: 1, count: n)
            for m in 0..<n where m != unknownIdx {
                let p = profiles[m]
                let x = p.moveIsBurst ? (f.mBurst10 ?? m10) : (p.moveIsMedian ? (f.mMed30 ?? m10) : m10)
                v[m] = acSoftRange(x, p.move, sigma: 0.08)
            }
            add(v, unknownValue: uMotion, weight: wMotion)
        }

        // 2. Gait presence (step counter, or IMU rhythm as a fallback) and cadence.
        if let g = f.gaitPresence {
            var v = [Double](repeating: 1, count: n)
            for m in 0..<n where m != unknownIdx {
                let p = profiles[m]
                var l = max(0.03, acGauss(g - p.gaitExpect, 0.35))
                if let spm = f.cadenceSpm, let cad = p.cadence, g >= 0.4 {
                    l *= acSoftRange(spm, cad, sigma: 15, floor: 0.15)
                }
                v[m] = l
            }
            add(v, unknownValue: uGait, weight: wGait)
        }

        // 3. Orientation stability (mean per-second change of the gravity direction).
        if let path = f.orientPath10 {
            var v = [Double](repeating: 1, count: n)
            let x = log10(1 + path)
            for m in 0..<n where m != unknownIdx {
                v[m] = acSoftRange(x, profiles[m].orientPath, sigma: 0.25, floor: 0.1)
            }
            add(v, unknownValue: uOrient, weight: wOrient)
        }

        // 3b. Posture-shift signature: a burst of movement that leaves the wrist in a different
        // orientation. Stationary modes are penalized while it is present; the four transition modes
        // are only plausible while it is. (It also raises the hazard of entering a transition mode —
        // see ActivityContextDecoder.predictBody.)
        if f.net5 != nil {
            let s = shiftStrength(f)
            var v = [Double](repeating: 1, count: n)
            for m in 0..<n where m != unknownIdx {
                let mode = BodyMode(rawValue: m)!
                if mode.isTransition { v[m] = 0.05 + 0.95 * s }
                else if mode.isStationary { v[m] = 1 - 0.9 * s }
            }
            add(v, unknownValue: uShift, weight: wShift)
        }

        // 4. Short-window motion encoder (HART or any other), weighted by how much to trust it.
        if let enc = f.encoder {
            var known = 0.0
            // Fixed order: floating-point sums must not depend on dictionary iteration order, or two runs
            // over the same stream (or a restored one) could differ in the last bit.
            var probs: [(label: String, p: Double)] = []
            for label in enc.classProbs.keys.sorted() where label != "unknown" {
                let p = enc.classProbs[label] ?? 0
                if p > 0 { probs.append((label, p)); known += p }
            }
            if known > 0 {
                var v = [Double](repeating: 1, count: n)
                for m in 0..<n where m != unknownIdx {
                    var s = 0.0
                    let compat = profiles[m].encoder
                    for (label, p) in probs { s += (p / known) * (compat[label] ?? 0.02) }
                    v[m] = max(0.01, s)
                }
                var w = wEncoder
                if !enc.calibrated { w *= 0.6 }
                if enc.abstained { w *= 0.4 }
                if let age = f.encoderAgeS { w *= age <= 2 ? 1 : (age <= 4 ? 0.8 : 0.5) }
                add(v, unknownValue: uEncoder, weight: w)
            }
        }

        // 5. Instantaneous arm pattern → body mode compat (couples desk-like motion to seated, etc.).
        if f.m10 != nil || f.m4 != nil {
            let q = armPattern(f)
            let qs = q[0..<ArmState.unknown].reduce(0, +)
            if qs > 0 {
                var v = [Double](repeating: 1, count: n)
                for m in 0..<n where m != unknownIdx {
                    var s = 0.0
                    for a in 0..<ArmState.unknown { s += (q[a] / qs) * profiles[m].arm[a] }
                    // A fully matching pattern scores about 0.35 (rows spread over 7 classes); 3.2× maps that to ~1.
                    v[m] = min(1, max(0.01, s * 3.2))
                }
                add(v, unknownValue: uArm, weight: wArm)
            }
        }

        // 6. Heart rate (weak: exertion, stress and caffeine all move it).
        if let hr = f.hrRel {
            var v = [Double](repeating: 1, count: n)
            for m in 0..<n where m != unknownIdx { v[m] = max(0.05, acGauss(hr - profiles[m].hrRel, 0.3)) }
            add(v, unknownValue: uHR, weight: wHR)
        }

        // 6a. Heart-rate trend. A rate that is clearly falling from an elevated level is recovery, which
        // argues against the modes that mean "working hard right now"; a steady or rising rate argues
        // against nothing. Not counted as an evidence channel: it only refines the level above.
        if let slope = f.hrSlope, let hr = f.hrRel, hr >= 0.25 {
            let recovering = min(1, max(0, (-slope - 2) / 6))
            if recovering > 0 {
                var v = [Double](repeating: 1, count: n)
                for m in 0..<n where m != unknownIdx && profiles[m].hrRel >= exertionFull {
                    v[m] = 1 - 0.7 * recovering
                }
                add(v, unknownValue: 1.0, weight: wHRTrend, isEvidence: false)
            }
        }

        // 6b. Specialist support: stairs / cycling / vehicle / generic exercise have no cue of their own
        // in the strap streams, so they are only plausible while the encoder names them or a logged
        // workout of a compatible kind covers the time. Generic exercise has one more way in: a heart
        // that says "working hard" (see `exertion`). No penalty for the other modes.
        var specialists = false
        var support = [Double](repeating: 1, count: n)
        let effort = exertion(f)
        for m in 0..<n {
            guard let label = profiles[m].requiresLabel else { continue }
            specialists = true
            let mode = BodyMode(rawValue: m)!
            let said = f.encoder?.classProbs[label] ?? 0
            let covered = f.loggedWorkout && profiles[m].workout >= 0.9 && workoutCovers(mode, kind: f.workoutKind)
            // Inertia may open the gate only for a strong class at or above its threshold, on a window that is
            // not OOD (`PreparedMotionHeads.terms`).
            let namedByInertia = inertia?.opens.contains(m) ?? false
            if namedByInertia && !(said >= 0.15 || covered) { specialistOpenedByMotionHeads = true }
            var s = (said >= 0.15 || covered || namedByInertia) ? 1.0 : 0.04
            if mode == .otherExercise { s = max(s, 0.04 + 0.96 * effort) }
            support[m] = s
        }
        if specialists { add(support, unknownValue: 1.0, weight: 1.0, isEvidence: false) }

        // 7. Context gates: sleep and logged workouts.
        if f.sleep == .asleep || f.loggedWorkout || f.sleep == .awake {
            var v = [Double](repeating: 1, count: n)
            for m in 0..<n where m != unknownIdx {
                let p = profiles[m]
                var l = 1.0
                if f.sleep == .asleep { l *= p.sleepAsleep }
                if f.sleep == .awake && BodyMode(rawValue: m) == .bedRest { l *= 0.8 }
                if f.loggedWorkout { l *= p.workout }
                v[m] = max(0.01, l)
            }
            // Being awake alone favours no particular mode, so the unknown mode is not penalised for it.
            let informative = f.sleep == .asleep || f.loggedWorkout
            add(v, unknownValue: informative ? uGate : 1.0, weight: wGate)
        }

        // 8. Inertia-1 heads: distinct, tempered channels (never averaged with the encoder above), all with
        // `isEvidence: false` so they never reduce the missing-sensor unknown bonus. Unknown gets 1.
        var postureShift: [Double]? = nil
        var armTerm: (L: [Double], weight: Double)? = nil
        if let t = inertia {
            if let loco = t.locomotion {
                add(loco.L, unknownValue: 1.0, weight: loco.weight, isEvidence: false)
            }
            if let post = t.posture {
                // Counted in the agreement measure like any channel, but applied by the decoder (renormalised
                // inside the stationary / transition set), not through `logL`.
                weightSum += post.weight
                let best = max(post.L.max() ?? 1, 1e-6)
                for m in 0..<n where m != unknownIdx { dis[m] += post.weight * log(max(post.L[m], 1e-6) / best) }
                dis[unknownIdx] += post.weight * min(0, log(1 / best))
                postureShift = post.L.map { temperature * post.weight * log(max($0, 1e-6)) }
            }
            armTerm = t.arm
        }

        // A missing primary movement channel is itself information: nothing can be claimed about
        // stillness or gait without it, so the unknown mode earns a standing bonus.
        if !hasMotion { logL[unknownIdx] += wMotion * log(1 / uMotion) * 0.8 }
        if channels < minChannels { logL[unknownIdx] += Double(minChannels - channels) * missingChannelBonus }

        for m in 0..<n { logL[m] *= temperature }
        if weightSum > 0 { for m in 0..<n { dis[m] /= weightSum } }
        return Score(logL: logL, disagreement: dis, hasMotion: hasMotion, channels: channels,
                     postureShift: postureShift, arm: armTerm, motionHeadsApplied: inertia != nil,
                     specialistOpenedByMotionHeads: specialistOpenedByMotionHeads)
    }

    /// Arm-chain emission context: how plausible each arm class is given the body posterior.
    static func armContext(bodyPosterior b: [Double]) -> [Double] {
        var ctx = [Double](repeating: 0, count: ArmState.count)
        for m in 0..<BodyMode.count where m != BodyMode.unknown.rawValue {
            for a in 0..<ArmState.unknown { ctx[a] += b[m] * profiles[m].arm[a] }
        }
        let unknownMass = b[BodyMode.unknown.rawValue]
        for a in 0..<ArmState.unknown { ctx[a] = 0.05 + 0.95 * ctx[a] + unknownMass * (1.0 / 7.0) }
        ctx[ArmState.unknown] = 0.08
        return ctx
    }
}
