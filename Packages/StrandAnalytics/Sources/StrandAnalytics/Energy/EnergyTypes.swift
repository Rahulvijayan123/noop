import Foundation
import WhoopProtocol

// EnergyTypes.swift — public value types of the multimodel metabolic estimator ("energy fusion").
//
// The estimator turns the day's streams into a per-minute metabolic timeline (MET + confidence),
// then splits the day into 24 h resting expenditure (RMR) and active expenditure. Everything here is a
// plain value type: no I/O, clock or storage, so the whole model runs in a unit test.
//
// Reading order for the model: EnergyConfig (every tunable number) → MinuteSignalBuilder (streams →
// per-minute signals) → ActivityBeliefBuilder (context) → HeartRatePhysiology + MetabolicPriors +
// MinuteFusion (evidence → MET) → MetabolicTemporalFilter (smoothness) → MetabolicEstimator (day).

// MARK: - Model selection

/// Which estimator feeds `DailyMetric.activeKcalEst`.
public enum EnergyModelChoice: String, Equatable, Sendable, CaseIterable {
    /// The activity-aware multi-evidence fusion (default for new callers of `analyzeDay`).
    case fusion
    /// The pre-fusion heart-rate-only estimator (`Calories.estimateDayEnergy`), kept for A/B comparison
    /// and as an instant rollback.
    case legacyHR
}

// MARK: - Activity context

/// The coarse activity classes the router knows about. Mirrors `MotionLabel` one-to-one; kept as its own
/// type so a step-counter-derived belief (no HART model on the day) speaks the same vocabulary.
public enum EnergyActivity: Int, CaseIterable, Sendable, Codable {
    case stationary = 0
    case walking
    case running
    case otherMovement
    case unknown

    public init(_ label: MotionLabel) {
        switch label {
        case .stationary: self = .stationary
        case .walking: self = .walking
        case .running: self = .running
        case .otherMovement: self = .otherMovement
        case .unknown: self = .unknown
        }
    }

    public var name: String {
        switch self {
        case .stationary: return "stationary"
        case .walking: return "walking"
        case .running: return "running"
        case .otherMovement: return "other_movement"
        case .unknown: return "unknown"
        }
    }
}

/// A distribution over `EnergyActivity` for one minute plus how far to trust the labeller.
///
/// `probabilities` sums to 1. `confidence` is the labeller's own reliability for this minute in [0, 1]
/// (the existing activity classifier's confidence, scaled by how much of the minute it observed);
/// the fusion mixes the distribution toward `unknown` by `1 - confidence`, so a weak or missing context
/// can only ever widen the estimate, never silently pick an activity.
public struct ActivityBelief: Equatable, Sendable {
    public enum Source: String, Sendable, Codable {
        /// Existing activity-classification epochs (HART), used as supplied.
        case hart
        /// Strap step counter / activity-class bytes (no classifier on this day).
        case stepClass
        /// Gravity-removed motion magnitude only.
        case motionProxy
        /// Nothing usable.
        case none
    }

    public var probabilities: [Double]
    public var confidence: Double
    public var source: Source

    public init(probabilities: [Double], confidence: Double, source: Source) {
        precondition(probabilities.count == EnergyActivity.allCases.count)
        let total = probabilities.reduce(0, +)
        self.probabilities = total > 0 ? probabilities.map { $0 / total } : ActivityBelief.unknownVector
        self.confidence = min(1, max(0, confidence))
        self.source = source
    }

    static let unknownVector: [Double] = [0, 0, 0, 0, 1]

    /// No information at all.
    public static let none = ActivityBelief(probabilities: unknownVector, confidence: 0, source: .none)

    public subscript(_ activity: EnergyActivity) -> Double { probabilities[activity.rawValue] }

    public var dominant: EnergyActivity {
        var best = EnergyActivity.unknown
        var bestP = -1.0
        for a in EnergyActivity.allCases where probabilities[a.rawValue] > bestP {
            best = a
            bestP = probabilities[a.rawValue]
        }
        return best
    }

    /// Where the mass of a wrong label goes, per label. Rows: stationary, walking, running, other,
    /// unknown. A stationary call is most often wrong because of a movement the wrist did not carry
    /// (other), a walking call because of a run or a non-locomotion movement, and so on.
    private static let leak: [[Double]] = [
        [0.00, 0.05, 0.00, 0.45, 0.50],
        [0.10, 0.00, 0.15, 0.45, 0.30],
        [0.00, 0.35, 0.00, 0.30, 0.35],
        [0.30, 0.30, 0.10, 0.00, 0.30],
        [0.00, 0.00, 0.00, 0.00, 1.00],
    ]

    /// A hard label with a confidence, expanded to a distribution via the leak table.
    public static func fromLabel(_ activity: EnergyActivity, confidence: Double, source: Source) -> ActivityBelief {
        let c = min(1, max(0, confidence))
        guard activity != .unknown else { return ActivityBelief(probabilities: unknownVector, confidence: 0, source: source) }
        var p = leak[activity.rawValue].map { $0 * (1 - c) }
        p[activity.rawValue] += c
        return ActivityBelief(probabilities: p, confidence: c, source: source)
    }
}

// MARK: - Per-minute provenance

/// Where a minute's heart rate came from.
public enum EnergyHRSource: String, Sendable, Codable {
    case measured
    /// Interpolated or held across a short dropout (≤ `EnergyConfig.hrCarryMaxGapS`).
    case carried
    case absent
}

/// Which evidence families had a vote in a minute. Audit trail, not a weight.
public struct EnergyEvidenceSet: OptionSet, Sendable, Codable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let wristMET = EnergyEvidenceSet(rawValue: 1 << 0)
    public static let wristCNN = EnergyEvidenceSet(rawValue: 1 << 1)
    public static let cadence = EnergyEvidenceSet(rawValue: 1 << 2)
    public static let motionProxy = EnergyEvidenceSet(rawValue: 1 << 3)
    public static let gps = EnergyEvidenceSet(rawValue: 1 << 4)
    public static let heartRate = EnergyEvidenceSet(rawValue: 1 << 5)
    public static let hart = EnergyEvidenceSet(rawValue: 1 << 6)
    public static let stepClass = EnergyEvidenceSet(rawValue: 1 << 7)
    public static let workoutPrior = EnergyEvidenceSet(rawValue: 1 << 8)

    /// Stable names for reports and JSON.
    public var names: [String] {
        let table: [(EnergyEvidenceSet, String)] = [
            (.wristMET, "wristmet"), (.wristCNN, "wrist_cnn"), (.cadence, "cadence"),
            (.motionProxy, "motion_proxy"), (.gps, "gps"), (.heartRate, "heart_rate"),
            (.hart, "hart"), (.stepClass, "step_class"), (.workoutPrior, "workout_prior"),
        ]
        return table.filter { contains($0.0) }.map { $0.1 }
    }
}

/// Reasons a minute's estimate should be read with care.
public struct EnergyQualityFlags: OptionSet, Sendable, Codable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let hrCarried = EnergyQualityFlags(rawValue: 1 << 0)
    public static let hrAbsent = EnergyQualityFlags(rawValue: 1 << 1)
    public static let noMotionEvidence = EnergyQualityFlags(rawValue: 1 << 2)
    public static let wristMETOutOfDistribution = EnergyQualityFlags(rawValue: 1 << 3)
    public static let cnnOutOfDistribution = EnergyQualityFlags(rawValue: 1 << 4)
    public static let estimatorsDisagree = EnergyQualityFlags(rawValue: 1 << 5)
    public static let lowContextConfidence = EnergyQualityFlags(rawValue: 1 << 6)
    public static let slewLimited = EnergyQualityFlags(rawValue: 1 << 7)
    public static let sleep = EnergyQualityFlags(rawValue: 1 << 8)
    public static let uncovered = EnergyQualityFlags(rawValue: 1 << 9)
    public static let hrOnly = EnergyQualityFlags(rawValue: 1 << 10)
    public static let implausible = EnergyQualityFlags(rawValue: 1 << 11)
    /// The minute lies inside a sleep interval but the heart rate is far above the sleeper's resting level.
    public static let sleepContradicted = EnergyQualityFlags(rawValue: 1 << 12)

    public var names: [String] {
        let table: [(EnergyQualityFlags, String)] = [
            (.hrCarried, "hr_carried"), (.hrAbsent, "hr_absent"), (.noMotionEvidence, "no_motion_evidence"),
            (.wristMETOutOfDistribution, "wristmet_ood"), (.cnnOutOfDistribution, "cnn_ood"),
            (.estimatorsDisagree, "estimators_disagree"), (.lowContextConfidence, "low_context_confidence"),
            (.slewLimited, "slew_limited"), (.sleep, "sleep"), (.uncovered, "uncovered"),
            (.hrOnly, "hr_only"), (.implausible, "implausible"), (.sleepContradicted, "sleep_contradicted"),
        ]
        return table.filter { contains($0.0) }.map { $0.1 }
    }
}

/// How the final precision of a minute splits across evidence families (sums to 1). The auditable
/// answer to "what drove this number": the motion models, heart rate, or the activity prior.
public struct EvidenceShare: Equatable, Sendable, Codable {
    public var motion: Double
    public var heartRate: Double
    public var prior: Double

    public init(motion: Double, heartRate: Double, prior: Double) {
        self.motion = motion; self.heartRate = heartRate; self.prior = prior
    }

    public static let priorOnly = EvidenceShare(motion: 0, heartRate: 0, prior: 1)
}

// MARK: - Inputs

/// A half-open time interval `[start, end)` in unix seconds.
public struct EnergyInterval: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }

    func contains(_ ts: Double) -> Bool { ts >= Double(start) && ts < Double(end) }
}

/// A workout window (already detected or logged) and its coarse class, when known.
public struct EnergyWorkoutInterval: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let coarseClass: CoarseWorkoutClass?
    public init(start: Int, end: Int, coarseClass: CoarseWorkoutClass? = nil) {
        self.start = start; self.end = end; self.coarseClass = coarseClass
    }
}

/// A GPS-derived ground speed (and optional grade) at one instant, when the day has a route.
public struct EnergySpeedSample: Equatable, Sendable {
    public let ts: Int
    public let speedMps: Double
    public let gradePct: Double?
    public init(ts: Int, speedMps: Double, gradePct: Double? = nil) {
        self.ts = ts; self.speedMps = speedMps; self.gradePct = gradePct
    }
}

/// Everything the estimator reads for one local day. (Not `Sendable`: it carries the existing stream
/// sample types, which are plain value types but do not declare the conformance.)
public struct EnergyDayInput {
    public var dayStart: Int
    public var dayEnd: Int
    /// "Now" for a day still in progress. nil for a complete day. Resting energy is counted up to here.
    public var asOf: Int?
    public var hr: [HRSample]
    public var gravity: [GravitySample]
    public var steps: [StepSample]
    public var profile: UserProfile
    public var hrmax: Double?
    public var restingHR: Double?
    public var sleepIntervals: [EnergyInterval]
    public var offWristIntervals: [EnergyInterval]
    public var workouts: [EnergyWorkoutInterval]
    /// Output of the existing activity-classification system. Read, never recomputed.
    public var activityEpochs: [ActivityEpoch]
    /// Per-minute WristMET / wrist-CNN evidence produced by `Tools/EnergyModels`. Empty when the day has
    /// no raw IMU (every day recorded before raw-IMU capture was switched on).
    public var motionEvidence: [MotionEvidenceMinute]
    public var speedSamples: [EnergySpeedSample]

    public init(dayStart: Int, dayEnd: Int, asOf: Int? = nil,
                hr: [HRSample], gravity: [GravitySample] = [], steps: [StepSample] = [],
                profile: UserProfile = UserProfile(), hrmax: Double? = nil, restingHR: Double? = nil,
                sleepIntervals: [EnergyInterval] = [], offWristIntervals: [EnergyInterval] = [],
                workouts: [EnergyWorkoutInterval] = [], activityEpochs: [ActivityEpoch] = [],
                motionEvidence: [MotionEvidenceMinute] = [], speedSamples: [EnergySpeedSample] = []) {
        self.dayStart = dayStart; self.dayEnd = dayEnd; self.asOf = asOf
        self.hr = hr; self.gravity = gravity; self.steps = steps
        self.profile = profile; self.hrmax = hrmax; self.restingHR = restingHR
        self.sleepIntervals = sleepIntervals; self.offWristIntervals = offWristIntervals
        self.workouts = workouts; self.activityEpochs = activityEpochs
        self.motionEvidence = motionEvidence; self.speedSamples = speedSamples
    }
}

// MARK: - Outputs

/// One minute of the metabolic timeline.
public struct EnergyMinute: Equatable, Sendable {
    public let startTs: Int
    /// Metabolic equivalents (multiples of resting metabolic rate; 1.0 = rest). Smoothed.
    public let met: Double
    /// 1-sigma uncertainty of `met` after smoothing.
    public let metSigma: Double
    /// Confidence in [0, 1] that `met` is a physiologically sound estimate for this minute.
    public let confidence: Double
    /// Active (above-rest) energy for the minute. Net of resting: `max(0, met - 1) * kcalPerMET`.
    public let activeKcal: Double
    /// Resting energy for the minute: RMR / 1440. Counted for every elapsed minute, covered or not.
    public let restingKcal: Double
    public let activity: EnergyActivity
    public let isSleep: Bool
    /// False when the strap supplied neither heart rate nor motion for the minute (a coverage gap).
    public let covered: Bool
    public let inWorkout: Bool
    public let hr: Double?
    public let hrSource: EnergyHRSource
    public let evidence: EnergyEvidenceSet
    public let share: EvidenceShare
    public let flags: EnergyQualityFlags

    public var totalKcal: Double { activeKcal + restingKcal }
}

/// Energy attributed to one workout window (a subset of the day's active energy).
public struct WorkoutEnergy: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let activeKcal: Double
    public let averageMET: Double?
    public let confidence: Double
}

/// Where the 24 h resting term came from.
public enum RmrSource: String, Sendable, Codable {
    /// Indirect calorimetry supplied by the wearer.
    case measured
    /// The population equation already in `Calories` (revised Harris–Benedict).
    case equation
}

/// The day, split the way the energy schema stores it: resting (24 h) + active (separately modelled).
public struct DayEnergy: Equatable, Sendable {
    public let modelVersion: String
    public let featureVersion: String

    public let rmrKcalPerDay: Double
    public let rmrSource: RmrSource
    /// Resting energy for the elapsed part of the day, regardless of strap coverage.
    public let restingKcal: Double
    /// The part of `restingKcal` falling in minutes the strap did not cover.
    public let restingGapKcal: Double
    /// Active energy above resting, summed over covered awake minutes. Never zero-filled across gaps.
    public let activeKcal: Double
    /// The part of `activeKcal` falling inside workout windows. A subset: never added to the total.
    public let workoutKcal: Double
    /// `restingKcal + activeKcal`.
    public let totalKcal: Double
    /// Complete-day projection for a day still in progress (resting only is projected). nil when complete.
    public let projectedTotalKcal: Double?

    public let averageMET: Double?
    public let peakMET: Double?
    public let sleepMinutes: Int
    public let sedentaryMinutes: Int
    public let lightMinutes: Int
    public let moderateMinutes: Int
    public let highMinutes: Int

    public let expectedMinutes: Int
    public let coverageMinutes: Int
    public let gapMinutes: Int

    /// Day-level confidence in [0, 1]: active-energy-weighted mean of minute confidence, discounted by
    /// coverage. Describes the active estimate; resting is the equation or the measurement.
    public let confidence: Double
    /// Minutes in which each evidence family voted, by `EnergyEvidenceSet.names`.
    public let evidenceMinutes: [String: Int]
    public let workouts: [WorkoutEnergy]
    public let minutes: [EnergyMinute]
}
