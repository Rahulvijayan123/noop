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
// ALL NUMBERS HERE ARE UNCALIBRATED PRIORS (decoder `hsmm-1.8`). They were set from this strap's own
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
    // Observation profile. `move`, `orientPath`, `hrRel`, `encoder` and `arm` are the fields a wearer's
    // `ActivityPersonalProfile` may adapt (`ActivityContextModel.profiles(for:)`); the rest stay fixed.
    var move: ClosedRange<Double>
    let moveIsBurst: Bool
    /// Judge `move` against the 30-s median instead of the 10-s mean: recumbent rest is almost always
    /// still, with occasional bursts (turning over) that must not refute it.
    let moveIsMedian: Bool
    let gaitExpect: Double
    let cadence: ClosedRange<Double>?
    var orientPath: ClosedRange<Double>
    let expectsPostureShift: Bool
    var hrRel: Double
    var encoder: [String: Double]
    var arm: [Double]          // compat with ArmBehaviorClass cases except unknown (7 values)
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

    /// The observation table one wearer is scored with: the static `profiles` with their adopted
    /// `ActivityPersonalProfile` applied (only the modes and fields it adapts). nil, or an empty profile,
    /// returns `profiles` itself.
    static func profiles(for personal: ActivityPersonalProfile?) -> [ModeProfile] {
        guard let personal, !personal.modes.isEmpty else { return profiles }
        var table = profiles
        for mode in ActivityPersonalProfile.adaptableModes {
            guard let adj = personal.modes[mode.personalKey] else { continue }
            var p = table[mode.rawValue]
            if let move = adj.move?.range { p.move = move }
            if let path = adj.orientPath?.range { p.orientPath = path }
            if let hr = adj.hrRel { p.hrRel = hr }
            if let arm = adj.arm, arm.count == p.arm.count { p.arm = arm }
            if let enc = adj.encoder, !enc.isEmpty { p.encoder = enc }
            table[mode.rawValue] = p
        }
        return table
    }

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
    static let wShift = 1.0, wHRTrend = 0.6, wTransition = 0.6
    static let uMotion = 0.20, uGait = 0.35, uOrient = 0.35, uEncoder = 0.30, uArm = 0.25, uHR = 0.55, uGate = 0.30
    static let uShift = 0.30, uTransition = 0.30
    /// Share of the posture-shift heuristic's weight kept while the learned transition expert speaks.
    static let shiftWeightWithExpert = 0.5
    /// The least a confident "none" from the transition expert leaves a transition mode (see channel 4b).
    static let expertNoneFloor = 0.30

    /// The transition expert's weight decay with window age (full to 2 s, then 0.8, then 0.5).
    static func transitionAgeFactor(_ age: Int?) -> Double {
        guard let age else { return 1 }
        return age <= 2 ? 1 : (age <= 4 ? 0.8 : 0.5)
    }
    /// Weight (before trust multipliers) of HART's fine distribution as arm-chain evidence.
    static let wArmEncoder = 0.6

    /// HART's fine distribution as arm-chain likelihoods (`ArmState` order, max 1) and the weight to apply
    /// them at; nil without a fine distribution. Same trust multipliers as body channel 4.
    static func armEncoder(_ f: ActivityFeatures) -> (likelihood: [Double], weight: Double)? {
        guard let enc = f.encoder, let p = enc.fineProbs.flatMap(HartFineActivities.vector) else { return nil }
        let L = HartFineActivities.armLikelihood(p)
        let best = max(L.max() ?? 1, 1e-12)
        var w = wArmEncoder
        if !enc.calibrated { w *= 0.6 }
        if enc.abstained { w *= 0.4 }
        if let age = f.encoderAgeS { w *= age <= 2 ? 1 : (age <= 4 ? 0.8 : 0.5) }
        return (L.map { max(0.01, $0 / best) }, w)
    }

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

    // MARK: Absolute forearm orientation (channel 3c, hsmm-1.8)

    /// Soft membership of a forearm-axis gravity component (strap +x; +1 = forearm pointing down) in four
    /// held-orientation categories: hand above the elbow, forearm flat, inclined, arm hanging. Sums to 1.
    static func orientationCategories(_ ux: Double) -> (neg: Double, flat: Double, mid: Double, hang: Double) {
        let a = acSigmoid((ux + 0.30) / 0.05), b = acSigmoid((ux - 0.30) / 0.05), c = acSigmoid((ux - 0.75) / 0.05)
        return (1 - a, a - b, b - c, c)
    }

    /// How often each stationary posture holds the forearm in each category (neg, flat, mid, hang). A
    /// population compromise, deliberately blunt: on this strap the owner's in-bed seconds are 69 % flat /
    /// 9 % hand-up against 3 % / 0.6 % by day, but scripted lab sitting rests the forearm flat on the lap
    /// 45–89 % of the time (FORTH, PAMAP2), and in free living (Capture-24) a raised hand separates sleep
    /// (45 %) from sitting (11 %) far better than a flat forearm (26 % vs 34 %). So a raised hand is the
    /// stronger recumbent cue, a flat forearm a mild one, and a hanging arm only weak upright evidence.
    static let orientationRows: (bed: [Double], seated: [Double], upright: [Double]) = (
        [0.35, 0.42, 0.17, 0.06], [0.12, 0.30, 0.40, 0.18], [0.04, 0.12, 0.36, 0.48])

    /// Per-second weights of the two orientation factors. Both are small on purpose: a held orientation
    /// repeats every second, so what it may claim is bounded by the decoder's posture-evidence memory, and
    /// these weights only set how many minutes it takes to get there (recumbent: several minutes of a held
    /// flat / raised forearm; seated vs upright: never more than a hedge on its own).
    static let wOrientRecumbent = 0.08, wOrientUpright = 0.01
    /// Weight of the direction terms the four transition modes take from the forearm axis during a shift.
    static let wShiftDirection = 1.0

    /// The transition modes' direction expectations from the forearm axis at both ends of a shift: standing
    /// up lowers the hand (the arm ends hanging), sitting down raises it, lying down ends with the forearm
    /// flat or the hand above the elbow, getting up starts there and leaves it. Values in (0, 1], index by
    /// mode; 1 for every other mode.
    static func shiftDirection(from a: Double, to b: Double) -> [Double] {
        var v = [Double](repeating: 1, count: BodyMode.count)
        let d = b - a
        let to = orientationCategories(b), from = orientationCategories(a)
        let lowFrom = from.flat + from.neg
        v[BodyMode.sitToStand.rawValue] = 0.25 + 0.75 * acSigmoid((d - 0.15) / 0.08)
        // Sitting down rarely ends with the hand raised above the elbow; lying down often does.
        v[BodyMode.standToSit.rawValue] = (0.25 + 0.75 * acSigmoid((-d - 0.15) / 0.08)) * (1 - 0.7 * to.neg)
        v[BodyMode.lyingDown.rawValue] = 0.2 + 0.8 * min(1, to.neg + 0.5 * to.flat) * (1 - 0.6 * lowFrom)
        v[BodyMode.gettingUp.rawValue] = 0.2 + 0.8 * lowFrom * (1 - (to.flat + to.neg))
        for m in 0..<BodyMode.count { v[m] = max(0.05, v[m]) }
        return v
    }

    /// Seated-vs-upright evidence a wearer's adopted personal profile is allowed to carry (log-odds); the
    /// population cap is `postureEvidenceCapSU`.
    static let postureEvidenceCapSU = log(8.0), postureEvidenceCapSUPersonal = log(12.0)
    /// Recumbent evidence cap (log-odds over the no-evidence ceiling `recumbentShareFloor`). Held orientation
    /// alone reaches at most its own source cap (ln 25, recumbent ≤ 75 % of the stationary mass); the
    /// staged night may go further.
    static let postureEvidenceCapRecumbent = log(200.0)
    /// Without recumbent evidence, recumbent rest may hold at most this share relative to seated + upright.
    static let recumbentShareFloor = 0.12
    /// Slack (log-odds) the seated / upright split may lean without any posture evidence: small enough that
    /// the published heads stay hedged ("Still, sitting or standing").
    static let postureNeutralSlack = log(1.25)
    /// ln(seated / upright) at which the published posture head is even (seated_likely = upright_stationary):
    /// the seated mode puts more of its mass on its own posture than the upright mode does, so an even split
    /// of the modes would read as a seated lean. Evidence is measured from here.
    static let postureNeutralLean: Double = {
        let s = profiles[BodyMode.seated.rawValue].posture, u = profiles[BodyMode.upright.rawValue].posture
        let ds = (s[.seatedLikely] ?? 0) - (s[.uprightStationary] ?? 0)
        let du = (u[.uprightStationary] ?? 0) - (u[.seatedLikely] ?? 0)
        let share = du / (ds + du)
        return log(share / (1 - share))
    }()

    /// The learned transition expert's confident, non-abstained reading: the share of its mass that names a
    /// posture change (1 − P(none)) and the four class probabilities, weighted by its age decay. nil when it
    /// is absent, abstained, or not confident enough to start a transition on its own.
    static func expertTransition(_ f: ActivityFeatures) -> (q: Double, p: [BodyMode: Double])? {
        guard let t = f.transition, !t.abstained else { return nil }
        let q = min(1, max(0, 1 - t.none)) * transitionAgeFactor(f.transitionAgeS)
        guard q >= 0.5 else { return nil }
        let raw: [(BodyMode, Double)] = [(.sitToStand, t.sitToStand), (.standToSit, t.standToSit),
                                         (.lyingDown, t.lieDown), (.gettingUp, t.getUp)]
        let total = raw.reduce(0) { $0 + max(0, $1.1) }
        guard total > 0 else { return nil }
        var p: [BodyMode: Double] = [:]
        for (m, v) in raw { p[m] = max(0, v) / total }
        return (q, p)
    }

    /// How strongly the encoder's FOLDED classes name a specialist label (channel 6b; the fine head, when
    /// present, replaces this for stairs and generic exercise). An abstained window says nothing, here as in
    /// channel 4 (D1V-02). The folded head files eating, drinking and brushing teeth under other_movement, so
    /// it opens generic exercise only when the movement or the heart corroborates (D1-08).
    static func encoderNames(_ label: String, mode: BodyMode, _ f: ActivityFeatures, effort: Double) -> Double {
        guard let enc = f.encoder, !enc.abstained else { return 0 }
        var said = enc.classProbs[label] ?? 0
        if mode == .otherExercise, enc.fineProbs.flatMap(HartFineActivities.vector) == nil {
            said *= max(acSigmoid(((f.m10 ?? 0) - 0.50) / 0.05), effort)
        }
        return said
    }

    /// No pulse, no wear event, and a strap stiller than any resting wrist (below ~5.4 mg median, no
    /// rotation) for this long is a strap on a table, not a person sitting quietly.
    static let noPulseStillOnsetS = 120
    @inline(__always) static func implausiblyStill(_ f: ActivityFeatures) -> Bool {
        (f.mMed30 ?? 1) <= 0.015 && (f.orientPath10 ?? 1) <= 0.1
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
    /// logged ride says nothing for stairs. A workout whose sport is unrecognised is evidence of generic
    /// exercise only: the wearer was demonstrably exercising, but the sport is unknown, so it never names
    /// cycling, stairs or a vehicle (WS-06-F03). The kind-specific mappings are unchanged.
    static func workoutCovers(_ mode: BodyMode, kind: WorkoutKind) -> Bool {
        switch kind {
        case .unspecified: return mode == .otherExercise
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
        /// The Inertia posture term was omitted this second (asleep / in bed: the sleep route speaks).
        var motionHeadsPostureOmitted = false
        /// ElderNet walk-vs-brisk term per body mode (tempered log factor, 0 outside {walk, briskWalk}). The
        /// decoder renormalises it inside that pair against its current belief, so it never changes P(gait).
        /// nil unless the split's weight is above 0 and the held window carries its metric.
        var briskShift: [Double]? = nil
        /// The ElderNet gait term entered this second's score.
        var gaitQualityApplied = false
        /// The shared accelerometer budget cut the gait or brisk term on some mode this second.
        var gaitBudgetLimited = false
        /// The brisk rule's verdict on the held window (logged at any weight); nil when it had nothing to say.
        var gaitFavoursBrisk: Bool? = nil
        /// The terms the shared accelerometer budget bounds, one by one. Only filled while the gait channel is
        /// active (a held ElderNet window under an accepted config); nil otherwise.
        var accelerometerTerms: AccelerometerTerms? = nil
        /// Posture evidence this second, by source, for the decoder's posture-evidence memory.
        var postureEvidence = PostureEvidence()
    }

    /// Tempered log-odds of posture evidence one second contributed, split by source so that each source's
    /// memory is capped on its own (`PostureEvidence.caps`): a wrist cue that is weak about posture must stay
    /// weak however many seconds repeat it. Seated over upright: the arm pattern (channel 5), the held forearm
    /// orientation, a shift's direction, and the learned / personal heads (fine HART, Inertia posture, any
    /// channel a personal profile made differ). Never the heart-rate level or the context gates: those are
    /// priors. Recumbent over sitting / standing: the held orientation and a shift into or out of lying.
    struct PostureEvidence: Equatable {
        var arm = 0.0, orientation = 0.0, direction = 0.0, learned = 0.0
        var recumbentOrientation = 0.0, recumbentDirection = 0.0
        /// The staged night (asleep, or awake in its in-bed window): set to its cap by the decoder, never by a
        /// second's score, and remembered for a while after the night ends.
        var recumbentNight = 0.0

        var values: [Double] { [arm, orientation, direction, learned, recumbentOrientation, recumbentDirection,
                                recumbentNight] }
        /// Index of the first recumbent source in `values`.
        static let recumbentStart = 4
        /// Per-source caps (log-odds), in `values` order. On its own the arm pattern or the held orientation
        /// leaves the published heads hedged; a shift whose direction the forearm shows, or a learned head,
        /// may commit. The seated / upright total is capped again by the decoder (higher with an adopted
        /// personal profile).
        static let caps: [Double] = [log(1.6), log(1.4), log(8.0), log(8.0), log(25.0), log(12.0), log(200.0)]
        /// The lower (upright / not recumbent) side of each cap, where it differs. A stand-up's direction
        /// carries less than a sit-down's: in free living standing still is about a tenth of still time and
        /// most stand-ups lead straight into walking, so "standing" after a stand-up is committed at a lower
        /// confidence than "sitting" after a sit-down.
        static let lowerCaps: [Double] = [log(1.6), log(1.4), log(3.0), log(8.0), log(25.0), log(12.0), 0]
        /// A shift is one event spread over a few seconds of tempered evidence: its direction is remembered at
        /// this gain so that one clear, direction-resolved change of posture can carry the split on its own
        /// (FORTH: 33 of 33 detected sit / stand shifts in the right direction once the forearm axis is read).
        static let directionGain = 2.5
        /// Memory time constants (s), in `values` order.
        static let taus: [Double] = [180, 180, 180, 180, 600, 600, 600]
        /// Index of the night source in `values`.
        static let night = 6
    }

    /// Every term the shared accelerometer budget bounds at one second, term by term, as the tempered, signed log
    /// factor it put on each body mode (0 where it did not speak): Inertia's locomotion term, its posture term
    /// (inside S; applied by the decoder, = `Score.postureShift`), the specialist-gate opening Inertia caused,
    /// the ElderNet gait term and the brisk split (= `Score.briskShift`). The budget holds when, per mode, the SUM
    /// OF THEIR ABSOLUTE VALUES is ≤ T · max(B_acc, B_Inertia) · ln 10 (`ActivityContextGaitQualityFusion.swift`).
    struct AccelerometerTerms {
        var inertiaLocomotion: [Double]
        var inertiaPosture: [Double]
        var inertiaGate: [Double]
        var gait: [Double]
        var brisk: [Double]
    }

    /// Instantaneous soft arm-behaviour likelihoods (not normalized) from movement-pattern features.
    /// `includeWorkout: false` leaves a logged workout out: the body chain's channel 7 already counts it, so
    /// the arm-pattern channel 5 must not count it a second time (D1-12). The arm chain keeps it.
    static func armPattern(_ f: ActivityFeatures, includeWorkout: Bool = true) -> [Double] {
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
        let workout = includeWorkout && f.loggedWorkout
        if workout { exercise = max(exercise, 0.7) }
        // Ordinary walking swings the arm hard enough to look like exercise motion; gait explains it.
        // Running (movement above ~0.78) keeps the exercise reading.
        let walkSwing = (1 - notGait) * (1 - acSigmoid((m - 0.78) / 0.04))
        if !workout { exercise *= 1 - 0.85 * walkSwing }
        q[ArmState.exercise] = exercise
        q[ArmState.other] = 0.30 + 0.5 * walkSwing
        q[ArmState.unknown] = 0.20
        return q
    }

    /// Score every body mode against the features. `motionHeads` adds the Inertia-1 channels (see
    /// `ActivityContextMotionHeadsFusion.swift`) after the existing ones, and `gaitQuality` the ElderNet channel
    /// after those (`ActivityContextGaitQualityFusion.swift`); nil (the default) scores exactly as before.
    ///
    /// `table` is the observation profile per mode: the static `profiles`, or a wearer's adapted copy from
    /// `profiles(for:)`. Duration priors and exits always come from the static table.
    static func score(_ f: ActivityFeatures, temperature: Double,
                      motionHeads: PreparedMotionHeads? = nil,
                      gaitQuality: PreparedGaitQuality? = nil,
                      table: [ModeProfile] = profiles) -> Score {
        let profiles = table
        let n = BodyMode.count
        var logL = [Double](repeating: 0, count: n)
        var dis = [Double](repeating: 0, count: n)
        var weightSum = 0.0
        var channels = 0
        let unknownIdx = BodyMode.unknown.rawValue
        // Inertia terms for this second (nil when Inertia is off, no window applies, or it is OOD).
        var inertia: PreparedMotionHeads.Terms? = nil
        var postureOmitted = false
        if let motionHeads, let window = f.motionHeads {
            // On an asleep / in-bed second the decoder's sleep and bed route already carries the posture
            // evidence the wrist head would add; the Inertia posture term steps aside (and is counted).
            inertia = motionHeads.terms(for: window, hartSpeaks: f.encoder != nil,
                                        sleepRoute: f.sleep == .asleep || f.inBed)
            postureOmitted = inertia?.postureOmitted ?? false
            if inertia?.isEmpty ?? false { inertia = nil }
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

        // 3c. Held absolute forearm orientation (hsmm-1.8). Two small factors, neither counted as an evidence
        // channel: recumbent rest against sitting / standing (a raised hand or a flat forearm, held, favours
        // lying; an inclined or hanging forearm argues against it), and seated against upright (a hanging arm
        // leans upright, weakly). A forearm flat on a desk is the confound: while the hands are busy (desk-like,
        // repetitive, gesturing) the recumbent factor reads the forearm as seated.
        let bed = BodyMode.bedRest.rawValue, seat = BodyMode.seated.rawValue, up = BodyMode.upright.rawValue
        var orientRecumbent = 0.0, orientSeated = 0.0
        if let ux = f.heldUx {
            let c = orientationCategories(ux)
            func held(_ row: [Double]) -> Double { row[0] * c.neg + row[1] * c.flat + row[2] * c.mid + row[3] * c.hang }
            let fb = held(orientationRows.bed), fs = held(orientationRows.seated), fu = held(orientationRows.upright)
            let q = armPattern(f, includeWorkout: false)
            let qs = q[0..<ArmState.unknown].reduce(0, +)
            let busy = qs > 0 ? (q[ArmState.desk] + q[ArmState.repetitive] + q[ArmState.gesture]) / qs : 0
            let fbed = fb * (1 - 0.8 * busy) + fs * 0.8 * busy
            var v = [Double](repeating: 1, count: n)
            v[bed] = max(0.01, fbed / max(fs, fu))
            add(v, unknownValue: 1, weight: wOrientRecumbent, isEvidence: false)
            orientRecumbent = wOrientRecumbent * log(v[bed])
            var w = [Double](repeating: 1, count: n)
            let ref = (fs + fu) / 2
            w[seat] = fs / ref; w[up] = fu / ref
            add(w, unknownValue: 1, weight: wOrientUpright, isEvidence: false)
            orientSeated = wOrientUpright * (log(w[seat]) - log(w[up]))
        }

        // 3b. Posture-shift signature: a burst of movement that leaves the wrist in a different
        // orientation. Stationary modes are penalized while it is present; the four transition modes
        // are only plausible while it is. (It also raises the hazard of entering a transition mode —
        // see ActivityContextDecoder.predictBody.)
        // While the learned transition expert speaks it sees the same burst from the raw IMU, so the share
        // of the heuristic that reports that burst (its strength `s`) is discounted toward
        // `shiftWeightWithExpert`, scaled by the expert's own age decay. A quiet heuristic ("no shift") is a
        // disagreement with the expert, not a duplicate.
        // hsmm-1.8: only the share of a firing heuristic that the expert CONFIRMS is a duplicate (a firing
        // heuristic beside an expert that says "none" is a disagreement and keeps its weight: the expert's
        // recall is low, so its "none" at a real transition must not halve the shift). And a quiet heuristic
        // no longer vetoes a confident expert at full weight: the 1 Hz gravity heuristic is blind to a return
        // within ~14 s, a bob-up, or a change of posture that barely rotates the wrist, which is exactly what
        // the raw-IMU expert is for (D2V-01).
        let transitionShare = (f.transition.map { !$0.abstained } ?? false) ? transitionAgeFactor(f.transitionAgeS) : 0
        let expertNamed = f.transition.map { $0.abstained ? 0 : min(1, max(0, 1 - $0.none)) } ?? 0
        let shift = f.net5 != nil ? shiftStrength(f) : 0
        if f.net5 != nil {
            let s = shift
            var v = [Double](repeating: 1, count: n)
            for m in 0..<n where m != unknownIdx {
                let mode = BodyMode(rawValue: m)!
                if mode.isTransition { v[m] = 0.05 + 0.95 * s }
                else if mode.isStationary { v[m] = 1 - 0.9 * s }
            }
            let duplicate = s * expertNamed
            let deferToExpert = (1 - s) * smoothStep((expertNamed - 0.4) / 0.4)
            let discount = 1 - transitionShare * ((1 - shiftWeightWithExpert) * duplicate + 0.85 * deferToExpert)
            add(v, unknownValue: uShift, weight: wShift * discount)
        }

        // 3d. Which way the shift went, from the forearm axis at both ends (hsmm-1.8). The four transition modes
        // used to share one observation profile, so the event kind came from where the belief's mass was
        // (D2-06, D7: direction right 15 of 35). Not an evidence channel; neutral for every other mode.
        if let a = f.shiftFromUx, let b = f.shiftToUx {
            add(shiftDirection(from: a, to: b), unknownValue: 1, weight: wShiftDirection, isEvidence: false)
        }

        // 4. Short-window motion encoder (HART or any other), weighted by how much to trust it. With HART's
        // fine distribution the channel reads that (see ActivityContextExperts.swift) INSTEAD of the four
        // folded labels — the same softmax, so never both.
        var encoderSpoke = false
        let fine = f.encoder?.fineProbs.flatMap(HartFineActivities.vector)
        if let enc = f.encoder, let fine {
            let L = HartFineActivities.bodyLikelihood(fine)
            let best = max(L.max() ?? 1, 1e-12)
            var w = wEncoder
            if !enc.calibrated { w *= 0.6 }
            if enc.abstained { w *= 0.4 }
            if let age = f.encoderAgeS { w *= age <= 2 ? 1 : (age <= 4 ? 0.8 : 0.5) }
            add(L.map { max(0.01, $0 / best) }, unknownValue: max(0.01, L[unknownIdx] / best), weight: w)
            encoderSpoke = true
        } else if let enc = f.encoder {
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
                encoderSpoke = true
            }
        }

        // 4c. ElderNet wrist-gait expert (optional): a likelihood ratio against its mean output π on the
        // gait modes vs the still / seated-moving modes; neutral on everything it was not trained to tell
        // apart (running, other exercise, transitions, unknown). Discounted while HART speaks (same
        // accelerometer). Not counted as a channel: it never shrinks the missing-sensor unknown bonus.
        if let g = f.gait {
            var w = GaitExpert.weight
            if encoderSpoke { w *= 1 - GaitExpert.hartRedundancy }
            add(GaitExpert.likelihood(g.gaitProb), unknownValue: 1, weight: w, isEvidence: false)
        }

        // 4b. Learned raw-IMU transition expert (optional; see `Tools/ActivityContext`). A small
        // classifier over 4-s windows says whether a posture change happened in this window and which
        // of the four it was. It is the one channel that names the transition modes directly; channel
        // 3b stays as the no-model fallback. Absent or abstained evidence skips the channel entirely,
        // so a day without the expert decodes exactly as before it existed.
        //
        // Likelihood magnitudes follow the encoder channel's compat conventions: a 0.05 floor (the
        // same floor channel 3b gives its transition modes). The four transition modes take their own
        // class probability, which already excludes P(none) (the five sum to one), so a confident "none"
        // leaves them at the floor and the expert cannot invent a transition it did not see; scaling by
        // (1 − P(none)) again would make a 50/50 window count as evidence against. "None" means "no posture change", which
        // walking, running and every other non-transition mode satisfy as much as sitting does, so all of
        // them take the same P(none) support: the channel only moves mass between "a transition" and "not a
        // transition", never between stationary and moving. Class probabilities are read in the fixed
        // canonical order, and `add` accumulates modes in a fixed order, so no sum depends on dictionary
        // iteration order. The unknown mode takes the mean of the known values, so the channel never
        // moves mass into or out of "unknown" (it says nothing about whether the body state is knowable).
        // hsmm-1.8: a "none" lowers the transition modes at most to `expertNoneFloor`. Measured on held-out
        // FORTH, the expert names 1 of 8 real stand-to-sits (it never names the wrong direction), so its "none"
        // is weak evidence and must not erase a transition the posture-shift heuristic sees (D7).
        if let trans = f.transition, !trans.abstained {
            let noneP = min(1, max(0, trans.none))
            var v = [Double](repeating: 1, count: n)
            var sum = 0.0, count = 0
            func named(_ p: Double) -> Double { max(expertNoneFloor, 0.05 + 0.95 * min(1, max(0, p))) }
            for m in 0..<n where m != unknownIdx {
                switch BodyMode(rawValue: m)! {
                case .sitToStand: v[m] = named(trans.sitToStand)
                case .standToSit: v[m] = named(trans.standToSit)
                case .lyingDown: v[m] = named(trans.lieDown)
                case .gettingUp: v[m] = named(trans.getUp)
                default: v[m] = 0.05 + 0.95 * noneP
                }
                sum += v[m]; count += 1
            }
            add(v, unknownValue: count > 0 ? sum / Double(count) : 1,
                weight: wTransition * transitionAgeFactor(f.transitionAgeS))
        }

        // 5. Instantaneous arm pattern → body mode compat (couples desk-like motion to seated, etc.).
        var armSeated = 0.0, armDiff = 0.0
        if f.m10 != nil || f.m4 != nil {
            let q = armPattern(f, includeWorkout: false)
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
                // Posture evidence only once the pattern is steady (4 s and 10 s means and the 30 s median agree):
                // the seconds after a walk pass through a desk-like movement level on their way to still.
                armDiff = wArm * (log(v[seat]) - log(v[up]))
                if let m4 = f.m4, let m10 = f.m10, let med = f.mMed30, abs(m4 - m10) < 0.1, abs(m10 - med) < 0.1 {
                    armSeated = armDiff
                }
            }
        }

        // 6. Heart rate (weak: exertion, stress and caffeine all move it).
        // A prior-like level, not posture evidence: kept out of the posture-evidence memory.
        var notPostureEvidence = 0.0
        if let hr = f.hrRel {
            var v = [Double](repeating: 1, count: n)
            for m in 0..<n where m != unknownIdx { v[m] = max(0.05, acGauss(hr - profiles[m].hrRel, 0.3)) }
            add(v, unknownValue: uHR, weight: wHR)
            notPostureEvidence += wHR * (log(v[seat]) - log(v[up]))
        }

        // 6a. Heart-rate trend. A rate that is clearly falling from an elevated level is recovery, which
        // argues against the modes that mean "working hard right now"; a steady or rising rate argues
        // against nothing. Not counted as an evidence channel: it only refines the level above.
        if let slope = f.hrSlope, let hr = f.hrRel, hr >= 0.25 {
            let recovering = min(1, max(0, (-slope - 2) / 6))
            if recovering > 0 {
                var v = [Double](repeating: 1, count: n)
                // Which modes mean "working hard" is a property of the mode, not of one wearer's resting
                // pulse in it: the static table decides, whatever `table` adapted.
                for m in 0..<n where m != unknownIdx && Self.profiles[m].hrRel >= exertionFull {
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
        // What Inertia's opening of a specialist gate added to each mode's log support (ElderNet's share of the
        // accelerometer budget is what Inertia left). Only read when the gait channel is active.
        var inertiaGatePull = [Double](repeating: 0, count: n)
        let effort = exertion(f)
        for m in 0..<n {
            guard let label = profiles[m].requiresLabel else { continue }
            specialists = true
            let mode = BodyMode(rawValue: m)!
            // HART's fine head can name stairs (the folded head files it under other_movement) and ball
            // sports; eating, drinking or brushing teeth no longer open the generic-exercise gate.
            var said = encoderNames(label, mode: mode, f, effort: effort)
            if let fine {
                switch mode {
                case .stairs: said = HartFineActivities.stairsMass(fine)
                case .otherExercise: said = HartFineActivities.sportMass(fine)
                default: break
                }
            }
            let covered = f.loggedWorkout && profiles[m].workout >= 0.9 && workoutCovers(mode, kind: f.workoutKind)
            // Inertia may name a specialist only for a strong class that is the window's argmax with its own
            // q ≥ τ, on a window that is not OOD (`PreparedMotionHeads.terms`). Alone it opens the gate only as
            // far as its per-second budget allows: never the encoder's full opening.
            let closed = 0.04
            let named = said >= 0.15 || covered
            var s = named ? 1.0 : closed
            if !named, let t = inertia, t.opens.contains(m) {
                specialistOpenedByMotionHeads = true
                s = t.openedSupport(m, closed: closed)
            }
            if mode == .otherExercise { s = max(s, closed + 0.96 * effort) }
            support[m] = s
            if gaitQuality != nil, specialistOpenedByMotionHeads, inertia?.opens.contains(m) ?? false {
                var without = named ? 1.0 : closed
                if mode == .otherExercise { without = max(without, closed + 0.96 * effort) }
                inertiaGatePull[m] = max(0, log(s) - log(without))
            }
        }
        if specialists { add(support, unknownValue: 1.0, weight: 1.0, isEvidence: false) }

        // 7. Context gates: sleep, the night's in-bed window, and logged workouts.
        // hsmm-1.8: lying awake in bed favours recumbent rest (it used to be penalised like any awake second,
        // so the posture posterior said seated while the class said lying, D1-04). Outside bed, awake or
        // unknown sleep is only a mild prior against lying: it used to compound per second into "never lying
        // awake" (D2-06); the decoder's posture-evidence bound, not this gate, now keeps a quiet wrist from
        // drifting into recumbent on the bed-rest dwell alone (D1V-01).
        let awakeInBed = f.sleep == .awake && f.inBed
        do {
            var v = [Double](repeating: 1, count: n)
            for m in 0..<n where m != unknownIdx {
                let p = profiles[m]
                let mode = BodyMode(rawValue: m)!
                var l = 1.0
                if f.sleep == .asleep { l *= p.sleepAsleep }
                if awakeInBed && (mode == .seated || mode == .upright) { l *= 0.3 }
                if !f.inBed && f.sleep == .awake && mode == .bedRest { l *= 0.97 }
                if !f.inBed && f.sleep == .unknown && mode == .bedRest { l *= 0.985 }
                if f.loggedWorkout { l *= p.workout }
                v[m] = max(0.01, l)
            }
            // Being awake alone favours no particular mode, so the unknown mode is not penalised for it.
            let informative = f.sleep == .asleep || f.loggedWorkout || awakeInBed
            if v.contains(where: { $0 != 1 }) || informative {
                // Unknown sleep is a new (mild) gate, not an evidence channel: the missing-sensor bonus of
                // the unknown mode is what it was.
                add(v, unknownValue: informative ? uGate : 1.0, weight: wGate,
                    isEvidence: f.sleep != .unknown || f.loggedWorkout)
                notPostureEvidence += wGate * (log(v[seat]) - log(v[up]))
            }
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

        // 9. ElderNet gait: its own tempered channel (never averaged with the encoder or Inertia), `isEvidence:
        // false`, unknown 1. Per mode it gets only the room Inertia's whole pull left under the shared
        // accelerometer budget; the walk-vs-brisk split takes what the gait term left.
        var briskShift: [Double]? = nil
        var gaitApplied = false, gaitLimited = false
        var favoursBrisk: Bool? = nil
        var accelerometerTerms: AccelerometerTerms? = nil
        if let gaitQuality, let window = f.gaitQuality {
            let inertiaLocomotion = (inertia?.locomotion?.weight ?? 0) > 0
            let t = gaitQuality.gaitTerms(for: window, hartSpeaks: f.encoder != nil,
                                      inertiaLocomotionSpeaks: inertiaLocomotion)
            favoursBrisk = t.favoursBrisk
            let budgetLog = gaitQuality.budget * log(10)
            var room = [Double](repeating: budgetLog, count: n)
            if let it = inertia {
                for m in 0..<n { room[m] = max(0, budgetLog - it.bodyPull(m) - inertiaGatePull[m]) }
            }
            // The bounded terms one by one, as applied (tempered): what the budget's tests check term by term.
            let zeros = [Double](repeating: 0, count: n)
            var terms = AccelerometerTerms(inertiaLocomotion: zeros, inertiaPosture: postureShift ?? zeros,
                                           inertiaGate: inertiaGatePull.map { temperature * $0 }, gait: zeros,
                                           brisk: zeros)
            if let loco = inertia?.locomotion {
                for m in 0..<n where m != unknownIdx {
                    terms.inertiaLocomotion[m] = temperature * loco.weight * log(max(loco.L[m], 1e-6))
                }
            }
            if let g = t.gait, g.weight > 0 {
                var v = [Double](repeating: 1, count: n)
                for m in 0..<n where m != unknownIdx {
                    let raw = g.weight * log(max(g.L[m], 1e-6))
                    let c = min(room[m], max(-room[m], raw))
                    if c != raw { gaitLimited = true; v[m] = exp(c / g.weight) } else { v[m] = g.L[m] }
                    room[m] = max(0, room[m] - abs(c))
                    terms.gait[m] = temperature * c
                }
                add(v, unknownValue: 1.0, weight: g.weight, isEvidence: false)
                gaitApplied = true
            }
            if let b = t.brisk, b.weight > 0 {
                var shift = [Double](repeating: 0, count: n)
                var L = [Double](repeating: 1, count: n)
                for mode in PreparedGaitQuality.briskPair {
                    let m = mode.rawValue
                    let raw = b.weight * log(max(b.L[m], 1e-6))
                    let c = min(room[m], max(-room[m], raw))
                    if c != raw { gaitLimited = true }
                    L[m] = exp(c / b.weight)
                    shift[m] = temperature * c
                    terms.brisk[m] = temperature * c
                }
                // Counted in the agreement measure like the Inertia posture term, applied by the decoder.
                weightSum += b.weight
                let best = max(L.max() ?? 1, 1e-6)
                for m in 0..<n where m != unknownIdx { dis[m] += b.weight * log(max(L[m], 1e-6) / best) }
                dis[unknownIdx] += b.weight * min(0, log(1 / best))
                briskShift = shift
            }
            accelerometerTerms = terms
        }

        // A missing primary movement channel is itself information: nothing can be claimed about
        // stillness or gait without it, so the unknown mode earns a standing bonus.
        if !hasMotion { logL[unknownIdx] += wMotion * log(1 / uMotion) * 0.8 }
        if channels < minChannels { logL[unknownIdx] += Double(minChannels - channels) * missingChannelBonus }
        // A strap stiller than a resting wrist with no pulse is no evidence anyone is there (D1-05): the unknown
        // mode's bonus outweighs what the still channels say for a seated wearer (about 4 nats per second).
        if f.noPulseStillS > noPulseStillOnsetS {
            logL[unknownIdx] += 8.0 * min(1, Double(f.noPulseStillS - noPulseStillOnsetS) / 180)
        }

        // Posture evidence (before temperature): seated over upright from every channel that tells them apart
        // except the priors above; during a shift (or a confident expert window) also the direction the
        // transition modes say. Recumbent: the held orientation, and a shift into vs out of lying.
        // A shift's sit / stand direction counts only for the share of it that is not a lie-down.
        let directionWeight = max(shift, transitionShare * expertNamed)
        let trans = { (m: BodyMode) in logL[m.rawValue] }
        let kinds: [BodyMode] = [.sitToStand, .standToSit, .lyingDown, .gettingUp]
        let top = kinds.map(trans).max() ?? 0
        let z = kinds.reduce(0.0) { $0 + exp(temperature * (trans($1) - top)) }
        let lieShare = exp(temperature * (trans(.lyingDown) - top)) / z
        var evidence = PostureEvidence()
        evidence.arm = temperature * armSeated
        evidence.orientation = temperature * orientSeated
        evidence.direction = PostureEvidence.directionGain * temperature * directionWeight * (1 - lieShare)
            * (trans(.standToSit) - trans(.sitToStand))
        evidence.learned = temperature * (logL[seat] - logL[up] - notPostureEvidence - armDiff - orientSeated)
            + (postureShift.map { $0[seat] - $0[up] } ?? 0)
        evidence.recumbentOrientation = temperature * orientRecumbent
        evidence.recumbentDirection = PostureEvidence.directionGain * temperature * directionWeight
            * (trans(.lyingDown) - max(trans(.standToSit), max(trans(.sitToStand), trans(.gettingUp))))

        for m in 0..<n { logL[m] *= temperature }
        if weightSum > 0 { for m in 0..<n { dis[m] /= weightSum } }
        return Score(logL: logL, disagreement: dis, hasMotion: hasMotion, channels: channels,
                     postureShift: postureShift, arm: armTerm, motionHeadsApplied: inertia != nil,
                     specialistOpenedByMotionHeads: specialistOpenedByMotionHeads,
                     motionHeadsPostureOmitted: postureOmitted, briskShift: briskShift,
                     gaitQualityApplied: gaitApplied, gaitBudgetLimited: gaitLimited, gaitFavoursBrisk: favoursBrisk,
                     accelerometerTerms: accelerometerTerms,
                     postureEvidence: evidence)
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
