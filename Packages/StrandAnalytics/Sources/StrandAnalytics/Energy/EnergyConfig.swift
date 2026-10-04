import Foundation

// EnergyConfig.swift — every tunable number of the energy-fusion model, in one place.
//
// Each value has a stated reason. They are plain `var`s so the evaluation harness and tests can sweep or
// perturb them, but production code only ever uses `EnergyConfig()`. Changing a default changes
// `modelVersion` semantics: bump `EnergyConfig.modelVersion` so stored rows can be told apart.

public struct EnergyConfig: Equatable, Sendable {
    public static let modelVersion = "energy-fusion-1.1.0"
    public static let featureVersion = "energy-features-1"

    public init() {}

    // MARK: Signal assembly

    /// A heart-rate dropout up to this long is bridged by interpolation between the surrounding readings.
    /// Longer than this the minute is `absent`: a gap is evidence of a missing sensor, never of exercise.
    public var hrCarryMaxGapS: Double = 120
    /// After the last reading before a dropout, hold it for at most this long (centre of the minute).
    public var hrHoldMaxS: Double = 90
    public var hrMinBpm: Int = 30
    public var hrMaxBpm: Int = 230
    /// Fewest 1 Hz gravity rows in a minute for its motion magnitude to be used.
    public var dynMinSamples: Int = 10
    /// Fewest step-counter rows in a minute for its cadence to be used.
    public var stepMinSamples: Int = 20
    /// A sleep interval is somebody's claim about a span of time (a detector's, or the wearer's edit); the
    /// heart rate can overrule it. A minute this far above the sleeper's resting level is not sleep:
    /// vigorous activity cannot hide inside an in-bed span, and a false session must not zero a real workout.
    public var sleepContradictionBpm: Double = 25
    /// Seconds of a minute an activity epoch must cover for its label to speak for the minute.
    public var epochMinCoverageS: Double = 20

    // MARK: Activity context from the step counter / motion magnitude (days without the classifier)

    public var cadenceWalkLow: Double = 20
    public var cadenceWalkFull: Double = 60
    public var cadenceRunLow: Double = 125
    public var cadenceRunFull: Double = 150
    /// Gravity-removed motion magnitude (g) where "moving" starts and where it is unambiguous.
    public var dynMoveLow: Double = 0.04
    public var dynMoveFull: Double = 0.12
    public var stepClassBeliefConfidence: Double = 0.6
    public var motionProxyBeliefConfidence: Double = 0.35

    // MARK: Motion-evidence widths (1-sigma, in METs)

    /// WristMET here is the model RETRAINED from the authors' public code and data (their weights are not
    /// public), and its published accuracy did not reproduce: the paper reports a 60-s RMSE of 0.281 MET;
    /// under genuine leave-one-participant-out validation the retrained model gets 0.76. The two stages
    /// differ sharply (artifact manifest, `loso.w60_primary` and `loso.w60_ablation_demographics_free`):
    /// the sedentary call is good (0.32 MET) while the regressor behind a non-sedentary call is not
    /// (1.31 MET, explaining about a quarter of the variance for people it has not seen). The sigma used
    /// is the P(non-sedentary)-weighted blend of the two. `EnergyModels/tests/test_evidence.py` fails if
    /// these drift from the manifest.
    public var wristMETSigmaSedentary: Double = 0.32
    public var wristMETSigmaActive: Double = 1.31
    /// The wrist CNN is trained against waist-ActiGraph-derived energy expenditure, not calorimetry. On the
    /// public sample it reproduces those labels to 0.74 MET RMSE (r 0.94, per-segment 0.43–1.73); its error
    /// against true expenditure is larger. It is supporting evidence: never tighter than WristMET's
    /// sedentary call, and wider than WristMET's regressor only through the router.
    public var cnnSigma: Double = 0.80
    /// Sigma is multiplied by `1 + gain * ood` (0 = typical input, 1 = far outside training data).
    public var oodSigmaGain: Double = 2.0
    public var demographicOODSigmaGain: Double = 2.5
    /// Estimators that run on the same wrist acceleration share error; the combined variance is inflated
    /// by `1 + rho * (k - 1)` for k motion estimators instead of treating them as independent.
    public var motionFamilyCorrelation: Double = 0.5
    public var cadenceWalkSigma: Double = 0.7
    public var cadenceRunSigma: Double = 1.0
    /// Gravity-removed motion magnitude → MET proxy: `1.2 + gain * max(0, dyn - floor)`. The strap's
    /// stationary p50 is 0.017 g and brisk walking sits at 0.15–0.30 g (owner data, Oct 2026).
    public var dynProxyGain: Double = 8.0
    public var dynProxyFloorG: Double = 0.012
    public var dynSigmaBase: Double = 0.9
    public var dynSigmaPerMET: Double = 0.25
    /// Extra width (METs) of the motion-magnitude proxy while the wrist is barely moving.
    public var dynQuietSigmaExtra: Double = 1.5
    /// Ground speed from GPS (ACSM equations) is good for locomotion; this is its error after the
    /// equation's own ±10 % and the speed noise.
    public var gpsSigma: Double = 0.6

    // MARK: Heart rate → MET

    /// `MET = floor + (METmax - floor) * x^exponent`, x = effective %HRR above the personal baseline.
    /// Convex because %HRR overstates %VO2R at low intensity (the ratio only converges near maximum).
    public var hrCurveExponent: Double = 1.4
    public var hrMetFloor: Double = 1.2
    /// Between-person scatter of the HR→MET relation without individual calibration is about ±1 MET at
    /// light intensity (the HR–VO2 line is flat and noisy there) and grows with intensity.
    public var hrSigmaBase: Double = 0.9
    public var hrSigmaPerMET: Double = 0.15
    /// …but the scatter is not constant. A heart rate at the wearer's quiet baseline is produced by rest or
    /// sedentary posture and by little else, so the HR-implied MET is tight there; it widens over the next
    /// `hrSigmaRampReserve` of reserve as light activity (a stroll barely lifts HR) and non-metabolic arousal
    /// start to move it. Without this a minute at baseline carried the full light-intensity scatter, the
    /// activity prior's heavy tails then dominated, and every minute of a heart-rate-only day read ~1.45 MET
    /// whether the wearer was asleep or not.
    public var hrSigmaAtBaseline: Double = 0.25
    public var hrSigmaRampReserve: Double = 0.12
    /// Personal "quiet, awake" HR sits this far above the resting HR when the day shows no quiet minutes.
    public var hrBaselineFallbackAboveRestingBpm: Double = 8
    /// And is never allowed above resting + this, so a day of persistent elevation cannot talk itself
    /// into being the baseline.
    public var hrBaselineMaxAboveRestingBpm: Double = 25
    /// HR leads/lags oxygen uptake by tens of seconds. The effective HR adds this fraction of the
    /// per-minute slope, clamped to `hrLeadClampBpm`.
    public var hrLeadGain: Double = 0.4
    public var hrLeadClampBpm: Double = 8
    /// After this many minutes of elevation, HR is a more reliable witness (the cardiac drift of a
    /// startle/stress spike has passed) and its sigma shrinks.
    public var sustainMinutes: Int = 8
    public var sustainSigmaFactorSupported: Double = 0.8
    public var sustainSigmaFactorUnsupported: Double = 0.92
    /// Cadence and wrist-motion estimates price the limbs' movement, not the external work: a grade, stairs,
    /// a pack, or a hand on a rail cost energy without moving the wrist or the step rate any faster. Their
    /// error is therefore one-sided. When heart rate has stayed far above what the movement implies, in a
    /// context where movement is expected to support it, the motion family's sigma is widened by up to this
    /// factor — upward only, so a heart rate BELOW the movement's estimate is never given extra say.
    /// 1 turns the allowance off.
    public var loadBlindSpotSigmaGain: Double = 2.5
    /// The allowance ramps in over this many METs of excess HR-implied cost (no effect below the first
    /// value, full effect at the second), and over `sustainMinutes` of elevation.
    public var loadBlindSpotGapLow: Double = 1.0
    public var loadBlindSpotGapFull: Double = 3.0
    /// HR stays elevated after effort stops: during recovery its sigma widens by `1 + gain * recovery`.
    public var recoverySigmaGain: Double = 1.5
    public var metMaxFloor: Double = 8
    public var metMaxCap: Double = 16
    public var defaultRestingHR: Double = 62
    public var defaultHRmax: Double = 190

    // MARK: Workout prior

    /// Within a detected workout the coarse class (walk/run/strength/cycle/ski) carries a Compendium
    /// prior; it is blended with the belief-based prior at this weight.
    public var workoutPriorWeight: Double = 0.6

    // MARK: Temporal filter

    /// Random-walk standard deviation per minute while the activity is steady (METs).
    public var processSigmaSteady: Double = 0.10
    /// …and across an activity transition (METs). Scaled by the size of the belief change.
    public var processSigmaTransition: Double = 2.5
    /// Hard ceiling on the change in smoothed MET between adjacent minutes (METs/min). Physiological
    /// VO2 kinetics (τ ≈ 30–45 s) are near steady state within ~2 min of a step change.
    public var maxSlewMetPerMin: Double = 4.0
    /// Innovations beyond this many sigma are treated as outliers: their measurement variance is inflated.
    public var huberZ: Double = 3.0
    public var sleepMetSigma: Double = 0.08

    // MARK: Confidence

    /// Confidence = Π componentᵢ^(weightᵢ / normalizer). The weights sum to more than the normalizer on
    /// purpose, so one poor component (disagreeing estimators, an out-of-distribution model) pulls the
    /// product down instead of being averaged away by five good ones.
    public var confidenceWeightAgreement: Double = 1.0
    public var confidenceWeightContext: Double = 0.8
    public var confidenceWeightQuality: Double = 1.0
    public var confidenceWeightDistribution: Double = 1.2
    public var confidenceWeightPlausibility: Double = 0.6
    public var confidenceWeightPrecision: Double = 1.0
    public var confidenceNormalizer: Double = 3.0
    /// Disagreement lowers confidence, down to this floor of the agreement component.
    public var agreementFloor: Double = 0.15
    /// How much a fully out-of-distribution input costs the distribution component.
    public var oodConfidencePenalty: Double = 0.9
    /// Sigma (METs) at which the precision component of confidence has fallen to 0.5.
    public var confidenceHalfSigma: Double = 1.2
    /// The smoother averages minute-to-minute noise away, but not error the minutes share (a biased HR
    /// curve for this wearer, a mislabelled activity). This fraction of the unsmoothed sigma is kept as
    /// systematic error when reporting a minute's uncertainty.
    public var systematicErrorShare: Double = 0.7
    public var confidenceFloor: Double = 0.05
    /// Confidence assigned to a minute of sleep (RMR-level by definition, unless the strap says otherwise).
    public var sleepConfidence: Double = 0.85

    // MARK: Intensity classes (standard MET bands)

    public var lightMET: Double = 1.5
    public var moderateMET: Double = 3.0
    public var highMET: Double = 6.0

    // MARK: Plausibility

    /// Energy above this many kcal/min/kg is not sustainable by a human wrist-worn-device wearer
    /// (≈ 17 MET) and caps the estimate.
    public var plausibleMaxMET: Double = 17.0
}
