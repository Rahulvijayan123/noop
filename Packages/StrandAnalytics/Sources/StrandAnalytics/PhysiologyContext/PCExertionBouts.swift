import Foundation
import WhoopProtocol

// PCExertionBouts.swift — System D: exertion bouts, response and recovery (spec §10).
//
// OWNER: responses & function workstream. Notes: docs/physiology-context/notes/responses.md.
//
// Bouts are detected from heart-rate independent evidence (HART epochs, strap motion, step counter, logged
// workouts), so a bout is never selected because heart rate rose. Response measurements are kept independently of
// any recovery classification; missing follow-up is censored, never invented.
//
//   1. Evidence. Per second, the HART label when HART has a confident label there, else the strap-motion label
//      (`BoutEvidence`). Neither source reads heart rate. HR-detected workouts (`source == detected`, found by
//      `WorkoutDetector` / `AutoWorkoutDetector` from HR thresholds) are never a bout source.
//   2. Segmentation. Contiguous locomotion spans are runs; runs and logged workouts separated by a pause of at most
//      `maxPauseS` merge into one bout unless the pause contains a recorded break or more than
//      `maxUncoveredInPauseS` seconds without motion evidence (no bridging). A bout needs `minBoutLocomotionS`
//      locomotion seconds or a logged workout. Id = FNV-1a of `bout|<deviceScope>|<start>`; day = local day of
//      the start.
//   3. Response. Pre-bout HR reference = median HR in `[start-180, start-30)` with ≥ 50 % coverage; HR during the
//      bout = median and a robust high quantile (p95); the signed rise is relative to the reference. Respiratory
//      response during movement is unavailable (RR-derived respiration is not valid during movement).
//   4. Recovery. Readings at +60/+120/+300/+600 s after the end are medians of ≥ 3 samples within ±15 s, without
//      interpolation (the `HeartRateRecovery` conventions). Follow-up is truncated at the first of: a recorded break
//      or an HR gap (`disconnect`), no HR at all after the end (`no_follow_up`), the next bout's start (`next_bout`,
//      so each outcome belongs to exactly one bout), resumed movement (`continued_movement`: behavioural cessation
//      is not physiological recovery), the cutoff (`cutoff_reached`). A reading whose window reaches the truncation
//      is censored, never estimated. Time-to-return is the first observed offset within tolerance of the pre-bout
//      reference, only when every earlier offset was observed.
//
// Free-living post-effort HR decline is not clinical heart-rate recovery (no standardized peak, posture or
// cool-down): it is a within-person descriptive quantity. Speed, grade, external load and ambient conditions are
// not measured, so every match key records them as unavailable.

extension PhysiologyContext {

    public struct ExertionConfig: Codable, Equatable, Sendable {
        public var version = "pc-exertion-1"
        /// Trailing exertion-summary windows in hours (candidate 24/48/72 h summaries).
        public var windowsH: [Int] = [24, 48, 72]

        // Detection (heart-rate independent evidence only).
        /// Locomotion separated by at most this many seconds of non-locomotion is one bout (crossings, doors).
        public var maxPauseS = 60
        /// A gap between runs inside a bout counts as a pause from this length on (shorter gaps are label flicker).
        public var minPauseS = 10
        /// A locomotion bout needs at least this many locomotion seconds.
        public var minBoutLocomotionS = 60
        /// A pause is bridged only when at most this many of its seconds have no motion evidence.
        public var maxUncoveredInPauseS = 10
        /// A span whose abstention fraction is at or above this is neither locomotion nor stillness evidence.
        public var maxUnknownFraction = 0.5
        /// Workout sources that are the person's own record. HR-detected workouts are never a bout source.
        public var loggedWorkoutSources: [String] = ["manual", "imported"]
        public var minWorkoutS = 60
        /// A bout's kind is its dominant locomotion label when that label holds this share of locomotion seconds.
        public var dominantKindShare = 0.8

        // Pre-bout context.
        public var precedingLookbackS = 1800
        /// Preceding stillness for the `rested` preceding state (the stable-awake policy's 300 s).
        public var restedStillS = 300
        /// Pre-bout HR window `[start - preWindowStartS, start - preWindowEndS)`.
        public var preWindowStartS = 180
        public var preWindowEndS = 30
        public var preMinCoverageShare = 0.5

        // Response.
        public var duringMinCoverageShare = 0.5
        public var peakQuantile = 0.95
        public var hrMinBpm = 30
        public var hrMaxBpm = 250

        // Recovery (offset and median conventions of `HeartRateRecovery`).
        /// End-of-bout HR = median over the final `endWindowS` seconds (`HeartRateRecovery.cessationWindowSeconds`).
        public var endWindowS = 30
        public var recoveryOffsetsS: [Int] = [60, 120, 300, 600]
        /// `HeartRateRecovery.measurementToleranceSeconds`.
        public var offsetToleranceS = 15
        /// `HeartRateRecovery.minimumSamplesPerReading`.
        public var minSamplesPerReading = 3
        /// A longer gap between HR samples is a disconnection (`HeartRateRecovery.maximumContinuousGapSeconds`).
        public var hrGapMaxS = 10
        /// Movement of at least this many contiguous seconds in the follow-up truncates recovery.
        public var followUpMovementMinS = 10
        /// Whether non-locomotion movement (`other_movement`) also counts as continued movement.
        public var followUpOtherMovementCounts = true
        /// HR within this many bpm of the pre-bout reference counts as returned.
        public var returnToleranceBpm = 5.0
        /// Fraction recovered and time-to-return need an end-of-bout rise of at least this many bpm.
        public var minRiseForFractionBpm = 5.0

        // Cadence (step counter).
        public var cadenceMinuteLocomotionShare = 0.5
        public var stepMinSamplesPerMinute = 2
        public var stepPreviousSampleMaxGapS = 10
        public var cadenceMinMinutes = 2

        // Matching bands.
        public var durationBandEdgesS: [Int] = [180, 600, 1800]
        public var cadenceBandEdges: [Double] = [80, 110, 140]

        /// Mirrors `JoinConfig.finalAfterDayEndS`: a retrospective bout is final only once its day is this long over.
        public var finalAfterDayEndS = 30 * 3600

        public init() {}

        /// Last second (inclusive) a recovery reading may use, relative to the bout end.
        var followUpHorizonS: Int { (recoveryOffsetsS.max() ?? 0) + offsetToleranceS }
    }

    public enum BoutStatus: String, Codable, CaseIterable, Sendable {
        /// Ended and its recovery follow-up was observed to the last supported offset.
        case complete
        /// Still in progress at the cutoff.
        case ongoing
        /// Ended but recovery follow-up is incomplete (reasons say why).
        case censored
    }

    /// Availability of one response channel (respiration, HRV) for a bout.
    public struct BoutChannel: Codable, Equatable, Sendable {
        /// `respiratory_rate` | `hrv_rmssd`.
        public var channel: String
        public var state: AvailabilityState
        public var reasons: [ReasonCode]
        public init(channel: String, state: AvailabilityState, reasons: [ReasonCode]) {
            self.channel = channel; self.state = state; self.reasons = reasons
        }
    }

    /// Step-counter cadence over the bout's locomotion minutes. Uncalibrated counter steps (the per-user
    /// `stepTicksPerStep` calibration is not applied); wrist cadence is not gait speed or stride length.
    public struct BoutCadence: Codable, Equatable, Sendable {
        /// `supported`, `partial` (legacy unclassed counter), or `unavailable`.
        public var state: AvailabilityState
        public var stepsPerMinMean: Double?
        /// Coefficient of variation across locomotion minutes (sample SD / mean); nil below two minutes.
        public var stepsPerMinCv: Double?
        /// Locomotion minutes that carried a cadence value.
        public var minutes: Int
        public var units: String
        public var reasons: [ReasonCode]
        public init(state: AvailabilityState, stepsPerMinMean: Double?, stepsPerMinCv: Double?, minutes: Int,
                    units: String = "counter_steps_per_min", reasons: [ReasonCode]) {
            self.state = state; self.stepsPerMinMean = stepsPerMinMean; self.stepsPerMinCv = stepsPerMinCv
            self.minutes = minutes; self.units = units; self.reasons = reasons
        }
    }

    /// What preceded a bout: the HR-independent preceding history and the pre-bout HR reference.
    public struct PreBoutContext: Codable, Equatable, Sendable {
        public var preceding: PrecedingHistory
        /// `rested` | `recent_movement` | `recent_bout` | `unknown`.
        public var state: String
        public var previousBoutId: String?
        public var secondsSincePreviousBout: Int?
        public var hrWindow: Interval
        /// Median HR over `hrWindow`; nil when coverage is insufficient.
        public var hrReferenceBpm: Double?
        public var hrSamples: Int
        public var reasons: [ReasonCode]
        public init(preceding: PrecedingHistory, state: String, previousBoutId: String?,
                    secondsSincePreviousBout: Int?, hrWindow: Interval, hrReferenceBpm: Double?, hrSamples: Int,
                    reasons: [ReasonCode]) {
            self.preceding = preceding; self.state = state; self.previousBoutId = previousBoutId
            self.secondsSincePreviousBout = secondsSincePreviousBout; self.hrWindow = hrWindow
            self.hrReferenceBpm = hrReferenceBpm; self.hrSamples = hrSamples; self.reasons = reasons
        }
    }

    /// HR during the bout. Kept whatever the recovery turns out to be.
    public struct BoutResponse: Codable, Equatable, Sendable {
        public var hrSamples: Int
        /// HR samples per bout second, in [0, 1].
        public var hrCoverage: Double
        public var hrMedianBpm: Double?
        /// Robust high quantile (`peakQuantile`) of HR during the bout, not the single maximum.
        public var hrPeakBpm: Double?
        public var peakQuantile: Double
        /// `hrMedianBpm - pre-bout reference` (signed).
        public var hrRiseBpm: Double?
        /// `hrPeakBpm - pre-bout reference` (signed).
        public var hrPeakRiseBpm: Double?
        /// Median HR over the bout's final `endWindowS` seconds (the recovery anchor).
        public var endHrBpm: Double?
        /// Respiratory response during movement: unavailable for an RR-derived estimator.
        public var respiratory: BoutChannel
        public var reasons: [ReasonCode]
        public init(hrSamples: Int, hrCoverage: Double, hrMedianBpm: Double?, hrPeakBpm: Double?,
                    peakQuantile: Double, hrRiseBpm: Double?, hrPeakRiseBpm: Double?, endHrBpm: Double?,
                    respiratory: BoutChannel, reasons: [ReasonCode]) {
            self.hrSamples = hrSamples; self.hrCoverage = hrCoverage; self.hrMedianBpm = hrMedianBpm
            self.hrPeakBpm = hrPeakBpm; self.peakQuantile = peakQuantile; self.hrRiseBpm = hrRiseBpm
            self.hrPeakRiseBpm = hrPeakRiseBpm; self.endHrBpm = endHrBpm; self.respiratory = respiratory
            self.reasons = reasons
        }
    }

    public enum RecoveryReadingState: String, Codable, CaseIterable, Sendable {
        case observed
        /// Follow-up was not truncated here but the window held too few samples.
        case unobserved
        /// The reading window reaches the truncation point; the bout's first censoring reason says why.
        case censored
    }

    /// One post-bout HR reading at a supported offset.
    public struct RecoveryObservation: Codable, Equatable, Sendable {
        public var offsetS: Int
        /// `[end + offset - tolerance, end + offset + tolerance + 1)`.
        public var window: Interval
        public var state: RecoveryReadingState
        public var hrBpm: Double?
        public var samples: Int
        /// `end HR - hrBpm` (positive = decline).
        public var declineBpm: Double?
        /// `hrBpm - pre-bout reference` (signed; within tolerance = returned).
        public var aboveReferenceBpm: Double?
        /// `(end HR - hrBpm) / (end HR - reference)` when the rise is meaningful.
        public var fractionRecovered: Double?
        public var reasons: [ReasonCode]
        public init(offsetS: Int, window: Interval, state: RecoveryReadingState, hrBpm: Double?, samples: Int,
                    declineBpm: Double?, aboveReferenceBpm: Double?, fractionRecovered: Double?,
                    reasons: [ReasonCode]) {
            self.offsetS = offsetS; self.window = window; self.state = state; self.hrBpm = hrBpm
            self.samples = samples; self.declineBpm = declineBpm; self.aboveReferenceBpm = aboveReferenceBpm
            self.fractionRecovered = fractionRecovered; self.reasons = reasons
        }
    }

    /// Post-effort HR decline ("recovery") of one bout, with censoring.
    public struct BoutRecovery: Codable, Equatable, Sendable {
        /// `[end, end + last offset + tolerance + 1)`.
        public var followUp: Interval
        public var anchorHrBpm: Double?
        public var referenceBpm: Double?
        public var observations: [RecoveryObservation]
        /// Where follow-up stopped being attributable to this bout; nil when it was observed to the last offset.
        public var truncatedAt: Int?
        /// Censoring events in time order; the first one truncated the follow-up.
        public var censoring: [ReasonCode]
        /// First observed offset within tolerance of the pre-bout reference (offset resolution), when observed.
        public var timeToReturnS: Int?
        public var hrv: BoutChannel
        public var respiratory: BoutChannel
        public var reasons: [ReasonCode]
        public init(followUp: Interval, anchorHrBpm: Double?, referenceBpm: Double?,
                    observations: [RecoveryObservation], truncatedAt: Int?, censoring: [ReasonCode],
                    timeToReturnS: Int?, hrv: BoutChannel, respiratory: BoutChannel, reasons: [ReasonCode]) {
            self.followUp = followUp; self.anchorHrBpm = anchorHrBpm; self.referenceBpm = referenceBpm
            self.observations = observations; self.truncatedAt = truncatedAt; self.censoring = censoring
            self.timeToReturnS = timeToReturnS; self.hrv = hrv; self.respiratory = respiratory
            self.reasons = reasons
        }

        public func observation(at offsetS: Int) -> RecoveryObservation? {
            observations.first { $0.offsetS == offsetS }
        }
    }

    /// The comparable-effort key a bout is matched on. An activity label alone does not establish equal effort,
    /// and unmeasured workload is recorded as unavailable rather than invented.
    public struct BoutMatchKey: Codable, Equatable, Sendable {
        /// `<kind>.<cadenceBand>.<durationBand>.<precedingState>`.
        public var key: String
        public var activityKind: String
        public var durationBand: String
        public var cadenceBand: String
        public var precedingState: String
        public var workloadLimitations: [ReasonCode]
        public init(key: String, activityKind: String, durationBand: String, cadenceBand: String,
                    precedingState: String, workloadLimitations: [ReasonCode]) {
            self.key = key; self.activityKind = activityKind; self.durationBand = durationBand
            self.cadenceBand = cadenceBand; self.precedingState = precedingState
            self.workloadLimitations = workloadLimitations
        }
    }

    /// One supported exertion bout with its measured response.
    public struct ExertionBout: Codable, Equatable, Sendable {
        /// Deterministic: `bout:<deviceScope>:<start>` hashed (stable across retries and re-runs).
        public var id: String
        public var interval: Interval
        /// Local day that owns the bout (day containing its start).
        public var day: String
        /// `walking` | `running` | `stepping` | `workout` | `mixed_locomotion`.
        public var kind: String
        public var status: BoutStatus
        public var durationS: Int
        public var reasons: [ReasonCode]
        /// `provisional` in causal mode, while ongoing or cutoff-censored, and before the day can be final.
        public var finality: Finality = .provisional
        /// Locomotion seconds inside the bout (pauses, unknown and uncovered time excluded).
        public var locomotionS: Int = 0
        /// Composition over the whole bout interval from the evidence the bout was detected on.
        public var composition: ActivityComposition? = nil
        /// Locomotion share of the whole bout as a heuristic score (not a probability); `notApplicable` for a
        /// logged workout, which is the person's own record.
        public var confidence: Confidence = .notApplicable
        /// `hart_epochs`, `strap_motion`, `logged_workout`.
        public var sourceEvidence: [String] = []
        public var evidenceSeconds: [Diagnostic] = []
        public var workoutIds: [String] = []
        /// Non-locomotion stretches of at least `minPauseS` between the bout's locomotion runs.
        public var pauses: [Interval] = []
        public var cadence: BoutCadence? = nil
        public var preBout: PreBoutContext? = nil
        public var response: BoutResponse? = nil
        /// Nil while the bout is ongoing.
        public var recovery: BoutRecovery? = nil
        public var matchKey: BoutMatchKey? = nil

        public init(id: String, interval: Interval, day: String, kind: String, status: BoutStatus, durationS: Int,
                    reasons: [ReasonCode] = []) {
            self.id = id; self.interval = interval; self.day = day; self.kind = kind; self.status = status
            self.durationS = durationS; self.reasons = reasons
        }

        enum CodingKeys: String, CodingKey {
            case id, interval, day, kind, status, durationS, reasons, finality, locomotionS, composition,
                 confidence, sourceEvidence, evidenceSeconds, workoutIds, pauses, cadence, preBout, response,
                 recovery, matchKey
        }

        /// Fields added after the contract skeleton decode to their defaults when absent.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            interval = try c.decode(Interval.self, forKey: .interval)
            day = try c.decode(String.self, forKey: .day)
            kind = try c.decode(String.self, forKey: .kind)
            status = try c.decode(BoutStatus.self, forKey: .status)
            durationS = try c.decode(Int.self, forKey: .durationS)
            reasons = try c.decodeIfPresent([ReasonCode].self, forKey: .reasons) ?? []
            finality = try c.decodeIfPresent(Finality.self, forKey: .finality) ?? .provisional
            locomotionS = try c.decodeIfPresent(Int.self, forKey: .locomotionS) ?? 0
            composition = try c.decodeIfPresent(ActivityComposition.self, forKey: .composition)
            confidence = try c.decodeIfPresent(Confidence.self, forKey: .confidence) ?? .notApplicable
            sourceEvidence = try c.decodeIfPresent([String].self, forKey: .sourceEvidence) ?? []
            evidenceSeconds = try c.decodeIfPresent([Diagnostic].self, forKey: .evidenceSeconds) ?? []
            workoutIds = try c.decodeIfPresent([String].self, forKey: .workoutIds) ?? []
            pauses = try c.decodeIfPresent([Interval].self, forKey: .pauses) ?? []
            cadence = try c.decodeIfPresent(BoutCadence.self, forKey: .cadence)
            preBout = try c.decodeIfPresent(PreBoutContext.self, forKey: .preBout)
            response = try c.decodeIfPresent(BoutResponse.self, forKey: .response)
            recovery = try c.decodeIfPresent(BoutRecovery.self, forKey: .recovery)
            matchKey = try c.decodeIfPresent(BoutMatchKey.self, forKey: .matchKey)
        }
    }

    /// A reference from a measurement to a bout that preceded it.
    public struct BoutRef: Codable, Equatable, Sendable, Hashable {
        public var boutId: String
        public var kind: String
        public var endedAt: Int
        public var secondsBeforeMeasurement: Int
        public var durationS: Int
        public init(boutId: String, kind: String, endedAt: Int, secondsBeforeMeasurement: Int, durationS: Int) {
            self.boutId = boutId; self.kind = kind; self.endedAt = endedAt
            self.secondsBeforeMeasurement = secondsBeforeMeasurement; self.durationS = durationS
        }
    }

    /// Observed-coverage accounting for one earlier day (so trailing windows report their missingness).
    public struct DayCoverage: Codable, Equatable, Sendable {
        public var day: String
        public var interval: Interval
        public var observedS: Int
        /// The observed seconds themselves, when known (lets a trailing window clip the day exactly; otherwise a
        /// partially overlapped day is prorated and bounded).
        public var observedIntervals: [Interval]? = nil
        public init(day: String, interval: Interval, observedS: Int) {
            self.day = day; self.interval = interval; self.observedS = observedS
        }
        public init(day: String, interval: Interval, observedS: Int, observedIntervals: [Interval]?) {
            self.day = day; self.interval = interval; self.observedS = observedS
            self.observedIntervals = observedIntervals
        }
    }

    /// Descriptive exertion over a trailing window ending at an instant.
    public struct ExertionWindowSummary: Codable, Equatable, Sendable, Hashable {
        public var windowH: Int
        public var interval: Interval
        /// Bouts overlapping the window.
        public var boutCount: Int
        /// Seconds inside bouts, clipped to the window (each second once).
        public var locomotionS: Int
        /// Seconds of the window with motion evidence; nil when unknown.
        public var observedS: Int?
        public var reasons: [ReasonCode]
        /// Bounds on `observedS` when a partially overlapped day had to be prorated.
        public var observedLowerS: Int? = nil
        public var observedUpperS: Int? = nil
        public init(windowH: Int, interval: Interval, boutCount: Int, locomotionS: Int, observedS: Int?,
                    reasons: [ReasonCode]) {
            self.windowH = windowH; self.interval = interval; self.boutCount = boutCount
            self.locomotionS = locomotionS; self.observedS = observedS; self.reasons = reasons
        }

        enum CodingKeys: String, CodingKey {
            case windowH, interval, boutCount, locomotionS, observedS, reasons, observedLowerS, observedUpperS
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            windowH = try c.decode(Int.self, forKey: .windowH)
            interval = try c.decode(Interval.self, forKey: .interval)
            boutCount = try c.decode(Int.self, forKey: .boutCount)
            locomotionS = try c.decode(Int.self, forKey: .locomotionS)
            observedS = try c.decodeIfPresent(Int.self, forKey: .observedS)
            reasons = try c.decodeIfPresent([ReasonCode].self, forKey: .reasons) ?? []
            observedLowerS = try c.decodeIfPresent(Int.self, forKey: .observedLowerS)
            observedUpperS = try c.decodeIfPresent(Int.self, forKey: .observedUpperS)
        }
    }

    public enum ExertionBouts {

        public static let version = "pc-exertion-1"

        // MARK: Reason codes — censoring
        public static let censorDisconnect: ReasonCode = "disconnect"
        public static let censorContinuedMovement: ReasonCode = "continued_movement"
        public static let censorNextBout: ReasonCode = "next_bout"
        public static let censorCutoffReached: ReasonCode = "cutoff_reached"
        public static let censorNoFollowUp: ReasonCode = "no_follow_up"
        // Bout
        public static let boutOngoing: ReasonCode = "bout_ongoing"
        public static let endedAtEvidenceGap: ReasonCode = "ended_at_evidence_gap"
        public static let mergedHartAndStrap: ReasonCode = "merged_hart_and_strap_evidence"
        public static let overlapsDetectedWorkout: ReasonCode = "overlaps_hr_detected_workout"
        public static let workoutWithoutLocomotion: ReasonCode = "workout_without_locomotion_evidence"
        public static let workoutClippedAtCutoff: ReasonCode = "workout_clipped_at_cutoff"
        public static let insufficientFollowUpSamples: ReasonCode = "insufficient_follow_up_samples"
        // Pre-bout
        public static let preBoutHrInsufficient: ReasonCode = "pre_bout_hr_insufficient_coverage"
        public static let preBoutInPriorRecovery: ReasonCode = "pre_bout_window_in_prior_recovery"
        public static let preBoutOverlapsPriorBout: ReasonCode = "pre_bout_window_overlaps_prior_bout"
        public static let precedingStateUnknown: ReasonCode = "preceding_state_unknown"
        // Response
        public static let hrInsufficientDuringBout: ReasonCode = "hr_insufficient_coverage_during_bout"
        public static let preBoutReferenceUnavailable: ReasonCode = "pre_bout_reference_unavailable"
        public static let endHrUnavailable: ReasonCode = "end_hr_unavailable"
        public static let opticalHrDuringMovement: ReasonCode = "optical_hr_during_movement_unvalidated"
        public static let respirationUnavailableDuringMovement: ReasonCode = "respiration_unavailable_during_movement"
        public static let noPostBoutRespiratoryEstimator: ReasonCode = "no_supported_post_bout_respiratory_estimator"
        public static let hrvRecoveryUnsupported: ReasonCode = "hrv_recovery_window_unsupported"
        // Recovery readings
        public static let insufficientSamplesAtOffset: ReasonCode = "insufficient_samples_at_offset"
        public static let followUpMotionUnobserved: ReasonCode = "follow_up_motion_unobserved"
        public static let riseTooSmallForFraction: ReasonCode = "rise_too_small_for_fraction"
        public static let riseTooSmallForReturn: ReasonCode = "rise_too_small_for_return"
        public static let notReturnedByLastObservedOffset: ReasonCode = "not_returned_by_last_observed_offset"
        public static let returnUndeterminedEarlierOffsetUnobserved: ReasonCode =
            "return_undetermined_earlier_offset_unobserved"
        public static let postEffortDeclineNotClinicalHrr: ReasonCode = "post_effort_hr_decline_not_clinical_hrr"
        // Cadence
        public static let cadenceUnavailable: ReasonCode = "cadence_unavailable"
        public static let insufficientCadenceMinutes: ReasonCode = "insufficient_cadence_minutes"
        public static let stepCounterUnclassed: ReasonCode = "step_counter_unclassed_legacy"
        public static let uncalibratedStepCounter: ReasonCode = "uncalibrated_step_counter"
        public static let wristCadenceNotGaitSpeed: ReasonCode = "wrist_cadence_not_gait_speed"
        // Workload (always recorded: nothing in the input measures them)
        public static let speedUnavailable: ReasonCode = "speed_unavailable"
        public static let gradeUnavailable: ReasonCode = "grade_unavailable"
        public static let externalLoadUnavailable: ReasonCode = "external_load_unavailable"
        public static let ambientUnavailable: ReasonCode = "ambient_unavailable"
        // Trailing windows
        public static let coverageUnknownForPartOfWindow: ReasonCode = "coverage_unknown_for_part_of_window"
        public static let observedProratedPartialDay: ReasonCode = "observed_prorated_partial_day"
        public static let noMotionObservedInWindow: ReasonCode = "no_motion_observed_in_window"

        public static let reasonCodes: [ReasonCode] = [
            censorDisconnect, censorContinuedMovement, censorNextBout, censorCutoffReached, censorNoFollowUp,
            boutOngoing, endedAtEvidenceGap, mergedHartAndStrap, overlapsDetectedWorkout, workoutWithoutLocomotion,
            workoutClippedAtCutoff, insufficientFollowUpSamples, preBoutHrInsufficient, preBoutInPriorRecovery,
            preBoutOverlapsPriorBout, precedingStateUnknown, hrInsufficientDuringBout, preBoutReferenceUnavailable,
            endHrUnavailable, opticalHrDuringMovement, respirationUnavailableDuringMovement,
            noPostBoutRespiratoryEstimator, hrvRecoveryUnsupported, insufficientSamplesAtOffset,
            followUpMotionUnobserved, riseTooSmallForFraction, riseTooSmallForReturn,
            notReturnedByLastObservedOffset, returnUndeterminedEarlierOffsetUnobserved,
            postEffortDeclineNotClinicalHrr, cadenceUnavailable, insufficientCadenceMinutes, stepCounterUnclassed,
            uncalibratedStepCounter, wristCadenceNotGaitSpeed, speedUnavailable, gradeUnavailable,
            externalLoadUnavailable, ambientUnavailable, coverageUnknownForPartOfWindow,
            observedProratedPartialDay, noMotionObservedInWindow,
        ]

        /// Workload inputs this layer never measures; recorded on every match key.
        public static let workloadLimitations: [ReasonCode] = [
            speedUnavailable, gradeUnavailable, externalLoadUnavailable, ambientUnavailable,
        ]

        // MARK: Vocabulary
        public static let kindWalking = "walking"
        public static let kindRunning = "running"
        public static let kindStepping = "stepping"
        public static let kindWorkout = "workout"
        public static let kindMixed = "mixed_locomotion"
        public static let precedingRested = "rested"
        public static let precedingRecentMovement = "recent_movement"
        public static let precedingRecentBout = "recent_bout"
        public static let precedingUnknown = "unknown"
        public static let sourceLoggedWorkout = "logged_workout"
        public static let responseSeriesPrefix = "hr_response"

        /// Deterministic bout id: FNV-1a of `bout|<deviceScope>|<start>`.
        public static func boutId(deviceScope: String, start: Int) -> String {
            PhysiologyContext.fnv1a("bout|\(deviceScope)|\(start)")
        }

        /// Series key of the first-offset post-effort HR decline (default `hr_recovery_60s.<activityKind>`).
        public static func recoverySeriesKey(kind: String, config: ExertionConfig) -> String {
            "hr_recovery_\(config.recoveryOffsetsS.min() ?? 60)s.\(kind)"
        }

        // MARK: Detection

        /// Detect bouts over the day window from heart-rate independent evidence, with response and recovery
        /// measured from the observations available at `cutoff`.
        public static func detect(identity: DayIdentity, hart: ResolvedTrack, strap: ResolvedTrack,
                                  workouts: [WorkoutInput], observations: SanitizedObservations,
                                  mode: ProcessingMode, cutoff: Int, config: ExertionConfig) -> [ExertionBout] {
            let evidence = BoutEvidence(hart: hart, strap: strap, maxUnknown: config.maxUnknownFraction)
            let breaks = observations.breaks.sorted()
            let heart = HeartSeries(observations.heartRate, minBpm: config.hrMinBpm, maxBpm: config.hrMaxBpm)
            let steps = observations.steps
                .map { StepSample(ts: $0.ts, counter: $0.counter, activityClass: $0.activityClass) }
                .sorted { ($0.ts, $0.counter, $0.activityClass ?? -1) < ($1.ts, $1.counter, $1.activityClass ?? -1) }
            // Every bout in the read window is segmented so that the previous and next bout of a day's bout are
            // known even across midnight; only bouts starting inside the day window are returned (ownership).
            let groups = boutGroups(evidence: evidence, workouts: workouts, breaks: breaks, cutoff: cutoff,
                                    config: config)
            let detected = workouts.filter { !config.loggedWorkoutSources.contains($0.source) && $0.interval.isValid }
            var out: [ExertionBout] = []
            for i in groups.indices where identity.dayWindow.contains(groups[i].interval.start) {
                out.append(measure(i, groups: groups, identity: identity, evidence: evidence, heart: heart,
                                   steps: steps, breaks: breaks, detectedWorkouts: detected, mode: mode,
                                   cutoff: cutoff, config: config))
            }
            return out
        }

        /// Bouts (today's and earlier days') that ended before `ts`, newest first, within the longest window.
        public static func recentRefs(before ts: Int, bouts: [ExertionBout], config: ExertionConfig) -> [BoutRef] {
            let horizon = (config.windowsH.max() ?? 72) * 3600
            return unique(bouts)
                .filter { $0.interval.end <= ts && ts - $0.interval.end <= horizon }
                .sorted { ($0.interval.end, $0.interval.start, $0.id) > ($1.interval.end, $1.interval.start, $1.id) }
                .map { BoutRef(boutId: $0.id, kind: $0.kind, endedAt: $0.interval.end,
                               secondsBeforeMeasurement: ts - $0.interval.end, durationS: $0.durationS) }
        }

        /// Trailing exertion summaries ending at `ts` for each configured window.
        ///
        /// `observedS` comes from `coverage`: a day wholly inside the window adds its observed seconds; a partially
        /// overlapped day adds its exact observed seconds when `observedIntervals` is known, else a prorated share
        /// with lower/upper bounds (`observed_prorated_partial_day`). Any part of the window without a coverage
        /// entry makes `observedS` nil (`coverage_unknown_for_part_of_window`): zero bouts there is not inactivity.
        public static func windows(endingAt ts: Int, bouts: [ExertionBout], coverage: [DayCoverage],
                                   config: ExertionConfig) -> [ExertionWindowSummary] {
            let all = unique(bouts)
            let days = uniqueCoverage(coverage)
            return config.windowsH.map { h in
                let w = Interval(ts - h * 3600, ts)
                var reasons: [ReasonCode] = []
                let inside = all.filter { $0.interval.start < w.end && $0.interval.end > w.start }
                let boutSeconds = totalDuration(merged(inside.compactMap { $0.interval.intersection(w) }))
                let known = totalDuration(merged(days.compactMap { $0.interval.intersection(w) }))
                var observed: Int? = nil, lower: Int? = nil, upper: Int? = nil
                if known < w.duration {
                    reasons.append(coverageUnknownForPartOfWindow)
                } else {
                    var exact = 0, lo = 0, hi = 0
                    var estimate = 0.0
                    var prorated = false
                    for d in days {
                        guard let ov = d.interval.intersection(w) else { continue }
                        let dayS = d.interval.duration
                        let obs = min(max(0, d.observedS), dayS)
                        if ov.duration == dayS {
                            exact += obs
                        } else if let spans = d.observedIntervals {
                            exact += totalDuration(merged(spans.compactMap { $0.intersection(ov) }))
                        } else {
                            prorated = true
                            lo += max(0, obs - (dayS - ov.duration))
                            hi += min(obs, ov.duration)
                            estimate += Double(obs) * Double(ov.duration) / Double(dayS)
                        }
                    }
                    observed = exact + Int(estimate.rounded())
                    lower = exact + lo
                    upper = exact + hi
                    if prorated { reasons.append(observedProratedPartialDay) }
                    if exact + hi == 0 { reasons.append(noMotionObservedInWindow) }
                }
                var s = ExertionWindowSummary(windowH: h, interval: w, boutCount: inside.count,
                                              locomotionS: boutSeconds, observedS: observed,
                                              reasons: reasons.sorted())
                s.observedLowerS = lower
                s.observedUpperS = upper
                return s
            }
        }

        /// Daily context-conditioned values contributed by bouts.
        ///
        /// - `hr_response.<match key>`: median HR rise (bout median - pre-bout reference) of the day's ended bouts
        ///   with that key. Censored recovery does not remove a bout's response.
        /// - `hr_recovery_60s.<activityKind>`: median post-effort HR decline at the first offset, only from
        ///   readings observed before any truncation (`activityKind` of the match key: the bout kind, or
        ///   `workout_<type>` for a logged workout).
        ///
        /// No value is produced for a key without a supported bout (missing is not zero). Finality: provisional in
        /// causal mode or when any contributing bout is provisional, else final.
        public static func dailyValues(_ bouts: [ExertionBout], identity: DayIdentity, regimeKey: String,
                                       mode: ProcessingMode, config: ExertionConfig) -> [DailyValue] {
            let own = unique(bouts).filter { $0.day == identity.day }
            let firstOffset = config.recoveryOffsetsS.min() ?? 60
            var response: [String: [(bout: ExertionBout, value: Double)]] = [:]
            var recovery: [String: [(bout: ExertionBout, value: Double)]] = [:]
            for b in own {
                if b.status != .ongoing, let key = b.matchKey?.key, let rise = b.response?.hrRiseBpm, rise.isFinite {
                    response["\(responseSeriesPrefix).\(key)", default: []].append((b, rise))
                }
                if let r = b.recovery?.observation(at: firstOffset), r.state == .observed,
                   let decline = r.declineBpm, decline.isFinite {
                    let kind = b.matchKey?.activityKind ?? b.kind
                    recovery[recoverySeriesKey(kind: kind, config: config), default: []].append((b, decline))
                }
            }
            func finality(_ items: [(bout: ExertionBout, value: Double)]) -> Finality {
                mode == .causalLive || items.contains { $0.bout.finality == .provisional } ? .provisional : .final
            }
            var out: [DailyValue] = []
            for key in response.keys.sorted() {
                let items = response[key]!
                guard let v = RobustStats.median(items.map { $0.value }) else { continue }
                out.append(DailyValue(day: identity.day, seriesKey: key, regimeKey: regimeKey, metric: .heartRate,
                                      value: v, units: "bpm", supportCount: items.count, supportUnit: "bout",
                                      supportS: items.reduce(0) { $0 + $1.bout.durationS }, mode: mode,
                                      finality: finality(items), sourceIds: items.map { $0.bout.id }.sorted(),
                                      reasons: workloadLimitations))
            }
            for key in recovery.keys.sorted() {
                let items = recovery[key]!
                guard let v = RobustStats.median(items.map { $0.value }) else { continue }
                out.append(DailyValue(day: identity.day, seriesKey: key, regimeKey: regimeKey, metric: .heartRate,
                                      value: v, units: "bpm", supportCount: items.count, supportUnit: "bout",
                                      supportS: items.count * (firstOffset + config.offsetToleranceS), mode: mode,
                                      finality: finality(items), sourceIds: items.map { $0.bout.id }.sorted(),
                                      reasons: [postEffortDeclineNotClinicalHrr]))
            }
            return out
        }

        // MARK: - Segmentation

        struct LocomotionRun {
            var interval: Interval
            var locomotionS: Double
            var labelSeconds: [String: Double]
            var hartS: Double
            var strapS: Double
        }

        struct BoutGroup {
            var interval: Interval
            var runs: [LocomotionRun] = []
            var workouts: [WorkoutInput] = []
            var clippedWorkout = false
            var locomotionS: Double { runs.reduce(0) { $0 + $1.locomotionS } }
        }

        /// Contiguous locomotion spans of the evidence.
        static func locomotionRuns(_ evidence: BoutEvidence) -> [LocomotionRun] {
            var runs: [LocomotionRun] = []
            var current: LocomotionRun?
            for s in evidence.spans {
                guard evidence.isLocomotion(s), let label = s.label else {
                    if let c = current { runs.append(c); current = nil }
                    continue
                }
                let w = Double(s.interval.duration) * (1 - s.unknownFraction)
                let hart = s.source == .hartEpochs ? w : 0
                let strap = s.source == .hartEpochs ? 0 : w
                if var c = current, c.interval.end == s.interval.start {
                    c.interval.end = s.interval.end
                    c.locomotionS += w
                    c.labelSeconds[label, default: 0] += w
                    c.hartS += hart
                    c.strapS += strap
                    current = c
                } else {
                    if let c = current { runs.append(c) }
                    current = LocomotionRun(interval: s.interval, locomotionS: w, labelSeconds: [label: w],
                                            hartS: hart, strapS: strap)
                }
            }
            if let c = current { runs.append(c) }
            return runs
        }

        /// Runs and logged workouts merged across bridgeable pauses; groups that are neither a logged workout nor
        /// long enough are dropped (they still count as movement when they interrupt another bout's follow-up).
        static func boutGroups(evidence: BoutEvidence, workouts: [WorkoutInput], breaks: [Interval], cutoff: Int,
                               config: ExertionConfig) -> [BoutGroup] {
            enum Piece { case run(LocomotionRun), workout(WorkoutInput, clipped: Bool) }
            var pieces: [(interval: Interval, order: Int, tie: String, piece: Piece)] = []
            for r in locomotionRuns(evidence) { pieces.append((r.interval, 0, "", .run(r))) }
            for w in workouts where config.loggedWorkoutSources.contains(w.source)
                && w.interval.duration >= config.minWorkoutS {
                let end = min(w.interval.end, cutoff)
                guard end > w.interval.start else { continue }
                var clipped = w
                clipped.interval = Interval(w.interval.start, end)
                pieces.append((clipped.interval, 1, w.id, .workout(clipped, clipped: end < w.interval.end)))
            }
            pieces.sort { ($0.interval.start, $0.interval.end, $0.order, $0.tie)
                < ($1.interval.start, $1.interval.end, $1.order, $1.tie) }
            func add(_ piece: Piece, to g: inout BoutGroup) {
                switch piece {
                case .run(let r): g.runs.append(r)
                case .workout(let w, let clipped):
                    g.workouts.append(w)
                    if clipped { g.clippedWorkout = true }
                }
            }
            var groups: [BoutGroup] = []
            var current: BoutGroup?
            for p in pieces {
                if var g = current {
                    let gap = p.interval.start - g.interval.end
                    if gap <= 0 || (gap <= config.maxPauseS
                                    && canBridge(Interval(g.interval.end, p.interval.start), evidence: evidence,
                                                 breaks: breaks, config: config)) {
                        g.interval.end = max(g.interval.end, p.interval.end)
                        add(p.piece, to: &g)
                        current = g
                        continue
                    }
                    groups.append(g)
                }
                var g = BoutGroup(interval: p.interval)
                add(p.piece, to: &g)
                current = g
            }
            if let g = current { groups.append(g) }
            return groups.filter { !$0.workouts.isEmpty || $0.locomotionS >= Double(config.minBoutLocomotionS) }
        }

        /// A pause can be bridged when no break falls inside it and its unobserved seconds are few.
        static func canBridge(_ gap: Interval, evidence: BoutEvidence, breaks: [Interval],
                              config: ExertionConfig) -> Bool {
            guard gap.isValid else { return true }
            if intersectsBreak(gap, breaks) { return false }
            return gap.duration - evidence.coveredSeconds(in: gap) <= config.maxUncoveredInPauseS
        }

        /// A zero-length break (an instantaneous clock reset) still occupies its second.
        static func breakEnd(_ b: Interval) -> Int { max(b.end, b.start + 1) }

        static func intersectsBreak(_ w: Interval, _ breaks: [Interval]) -> Bool {
            breaks.contains { $0.start < w.end && breakEnd($0) > w.start }
        }

        // MARK: - Measurement

        static func measure(_ i: Int, groups: [BoutGroup], identity: DayIdentity, evidence: BoutEvidence,
                            heart: HeartSeries, steps: [StepSample], breaks: [Interval],
                            detectedWorkouts: [WorkoutInput], mode: ProcessingMode, cutoff: Int,
                            config: ExertionConfig) -> ExertionBout {
            let g = groups[i]
            let iv = g.interval
            var reasons: [ReasonCode] = []

            // Evidence, composition, kind and confidence.
            let covered = evidence.coveredBySource(in: iv)
            let composition = IntervalAlgebra.composition(over: iv, track: evidence.track(source: covered.source))
            if covered.hartS > 0 && covered.strapS > 0 { reasons.append(mergedHartAndStrap) }
            var labelSeconds: [String: Double] = [:]
            var hartLocomotion = 0.0, strapLocomotion = 0.0
            for r in g.runs {
                for (k, v) in r.labelSeconds { labelSeconds[k, default: 0] += v }
                hartLocomotion += r.hartS
                strapLocomotion += r.strapS
            }
            let locomotion = g.locomotionS
            let kind = g.workouts.isEmpty
                ? dominantKind(labelSeconds, total: locomotion, share: config.dominantKindShare) : kindWorkout
            var sourceEvidence: [String] = []
            if hartLocomotion > 0 { sourceEvidence.append(ActivitySource.hartEpochs.rawValue) }
            if strapLocomotion > 0 { sourceEvidence.append(ActivitySource.strapMotion.rawValue) }
            if !g.workouts.isEmpty { sourceEvidence.append(sourceLoggedWorkout) }
            if !g.workouts.isEmpty && locomotion == 0 { reasons.append(workoutWithoutLocomotion) }
            if g.clippedWorkout { reasons.append(workoutClippedAtCutoff) }
            if detectedWorkouts.contains(where: { $0.interval.overlapSeconds(with: iv) > 0 }) {
                reasons.append(overlapsDetectedWorkout)
            }
            let confidence = g.workouts.isEmpty
                ? Confidence(kind: .heuristicScore, value: min(1, max(0, locomotion / Double(max(1, iv.duration)))))
                : .notApplicable

            // Pauses between the bout's locomotion runs.
            var pauses: [Interval] = []
            let runs = g.runs.sorted { $0.interval < $1.interval }
            if runs.count > 1 {
                for k in 1..<runs.count {
                    let gap = Interval(runs[k - 1].interval.end, runs[k].interval.start)
                    guard gap.duration >= config.minPauseS else { continue }
                    let uncovered = gap.duration - evidence.coveredSeconds(in: gap)
                    if uncovered * 2 < gap.duration { pauses.append(gap) }
                }
            }

            let cadence = boutCadence(over: iv, steps: steps, evidence: evidence, breaks: breaks, config: config)
            let pre = preBout(i, groups: groups, deviceScope: identity.deviceScope, evidence: evidence, heart: heart,
                              config: config)
            let response = boutResponse(iv, pre: pre, heart: heart, breaks: breaks, config: config)

            // Status and recovery. Cessation is established only once a pause longer than `maxPauseS` could have
            // been seen before the cutoff; until then the bout is ongoing.
            let ongoing = g.clippedWorkout || iv.end + config.maxPauseS > cutoff
            var status: BoutStatus
            var recovery: BoutRecovery?
            if ongoing {
                status = .ongoing
                reasons.append(boutOngoing)
            } else {
                let r = boutRecovery(i, groups: groups, evidence: evidence, heart: heart, breaks: breaks,
                                     endHr: response.endHrBpm, reference: pre.hrReferenceBpm, cutoff: cutoff,
                                     config: config)
                recovery = r
                let allObserved = r.observations.allSatisfy { $0.state == .observed }
                status = r.censoring.isEmpty && allObserved ? .complete : .censored
                if let first = r.censoring.first { reasons.append(first) }
                if r.censoring.isEmpty && !allObserved { reasons.append(insufficientFollowUpSamples) }
                let probe = Interval(iv.end, min(iv.end + config.maxPauseS, cutoff))
                if probe.isValid, probe.duration - evidence.coveredSeconds(in: probe) > config.maxUncoveredInPauseS {
                    reasons.append(endedAtEvidenceGap)
                }
            }

            let provisional = mode == .causalLive || status == .ongoing
                || (recovery?.censoring.contains(censorCutoffReached) ?? false)
                || cutoff < identity.dayWindow.end + config.finalAfterDayEndS
            var bout = ExertionBout(id: boutId(deviceScope: identity.deviceScope, start: iv.start), interval: iv,
                                    day: localTime(at: iv.start, timezoneId: identity.timezoneId).localDay,
                                    kind: kind, status: status, durationS: iv.duration,
                                    reasons: Array(Set(reasons)).sorted())
            bout.finality = provisional ? .provisional : .final
            bout.locomotionS = Int(locomotion.rounded())
            bout.composition = composition
            bout.confidence = confidence
            bout.sourceEvidence = sourceEvidence
            bout.evidenceSeconds = [Diagnostic("hart_epochs_covered_s", covered.hartS),
                                    Diagnostic("hart_epochs_locomotion_s", hartLocomotion),
                                    Diagnostic("strap_motion_covered_s", covered.strapS),
                                    Diagnostic("strap_motion_locomotion_s", strapLocomotion)]
            bout.workoutIds = g.workouts.map(\.id).sorted()
            bout.pauses = pauses
            bout.cadence = cadence
            bout.preBout = pre
            bout.response = response
            bout.recovery = recovery
            bout.matchKey = matchKey(kind: matchKind(kind, workouts: g.workouts), durationS: iv.duration,
                                     cadence: cadence, preceding: pre.state, config: config)
            return bout
        }

        static func dominantKind(_ labelSeconds: [String: Double], total: Double, share: Double) -> String {
            guard total > 0 else { return kindMixed }
            var byKind: [String: Double] = [:]
            for (label, s) in labelSeconds {
                let k: String
                switch label {
                case "walking", "brisk_walking": k = kindWalking
                case "running": k = kindRunning
                case "stepping": k = kindStepping
                default: k = label
                }
                byKind[k, default: 0] += s
            }
            let top = byKind.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first
            guard let t = top, t.value / total >= share else { return kindMixed }
            return t.key
        }

        static func preBout(_ i: Int, groups: [BoutGroup], deviceScope: String, evidence: BoutEvidence,
                            heart: HeartSeries, config: ExertionConfig) -> PreBoutContext {
            let start = groups[i].interval.start
            let lookback = Interval(start - config.precedingLookbackS, start)
            let preceding = IntervalAlgebra.precedingHistory(
                before: start, track: evidence.track(source: evidence.coveredBySource(in: lookback).source),
                lookbackS: config.precedingLookbackS)
            var reasons: [ReasonCode] = []
            let window = Interval(start - config.preWindowStartS, start - config.preWindowEndS)
            var previousId: String?
            var since: Int?
            if i > 0 {
                since = start - groups[i - 1].interval.end
                previousId = boutId(deviceScope: deviceScope, start: groups[i - 1].interval.start)
                if groups[i - 1].interval.end > window.start { reasons.append(preBoutOverlapsPriorBout) }
            }
            let state: String
            if let s = since, s <= config.followUpHorizonS {
                state = precedingRecentBout
                reasons.append(preBoutInPriorRecovery)
            } else if preceding.stillRunS >= config.restedStillS {
                state = precedingRested
            } else if preceding.stillRunEndedBy == IntervalAlgebra.stillRunMovement {
                state = precedingRecentMovement
            } else {
                state = precedingUnknown
                reasons.append(precedingStateUnknown)
            }
            let values = heart.values(window)
            let need = max(config.minSamplesPerReading,
                           Int((config.preMinCoverageShare * Double(window.duration)).rounded(.up)))
            var reference: Double?
            if window.isValid, values.count >= need {
                reference = RobustStats.median(values)
            } else {
                reasons.append(preBoutHrInsufficient)
            }
            return PreBoutContext(preceding: preceding, state: state, previousBoutId: previousId,
                                  secondsSincePreviousBout: since, hrWindow: window, hrReferenceBpm: reference,
                                  hrSamples: values.count, reasons: reasons.sorted())
        }

        static func boutResponse(_ iv: Interval, pre: PreBoutContext, heart: HeartSeries, breaks: [Interval],
                                 config: ExertionConfig) -> BoutResponse {
            var reasons: [ReasonCode] = [opticalHrDuringMovement]
            let values = heart.values(iv)
            let coverage = iv.duration > 0 ? min(1, Double(values.count) / Double(iv.duration)) : 0
            var median: Double?, peak: Double?
            if coverage >= config.duringMinCoverageShare, values.count >= config.minSamplesPerReading {
                median = RobustStats.median(values)
                peak = RobustStats.quantile(values, config.peakQuantile)
            } else {
                reasons.append(hrInsufficientDuringBout)
            }
            // End HR from the final seconds of the bout, never across a break.
            var endStart = iv.end - config.endWindowS
            for b in breaks where b.start < iv.end && breakEnd(b) > endStart {
                endStart = max(endStart, min(iv.end, breakEnd(b)))
            }
            let endValues = heart.values(Interval(endStart, iv.end))
            let endHr = endValues.count >= config.minSamplesPerReading ? RobustStats.median(endValues) : nil
            if endHr == nil { reasons.append(endHrUnavailable) }
            var rise: Double?, peakRise: Double?
            if let ref = pre.hrReferenceBpm {
                rise = median.map { $0 - ref }
                peakRise = peak.map { $0 - ref }
            } else {
                reasons.append(preBoutReferenceUnavailable)
            }
            return BoutResponse(hrSamples: values.count, hrCoverage: coverage, hrMedianBpm: median, hrPeakBpm: peak,
                                peakQuantile: config.peakQuantile, hrRiseBpm: rise, hrPeakRiseBpm: peakRise,
                                endHrBpm: endHr,
                                respiratory: BoutChannel(channel: MetricKind.respiratoryRate.rawValue,
                                                         state: .unavailable,
                                                         reasons: [respirationUnavailableDuringMovement]),
                                reasons: reasons.sorted())
        }

        static func boutRecovery(_ i: Int, groups: [BoutGroup], evidence: BoutEvidence, heart: HeartSeries,
                                 breaks: [Interval], endHr: Double?, reference: Double?, cutoff: Int,
                                 config: ExertionConfig) -> BoutRecovery {
            let end = groups[i].interval.end
            let followEnd = end + config.followUpHorizonS          // last second a reading may use (inclusive)
            // Censoring events: (time, tie rank, reason). Ties resolve disconnect, no_follow_up, next_bout,
            // continued_movement, cutoff_reached.
            var events: [(at: Int, rank: Int, reason: ReasonCode)] = []
            for b in breaks where b.start <= followEnd && breakEnd(b) > end {
                events.append((max(b.start, end), 0, censorDisconnect))
            }
            // HR continuity: a gap longer than `hrGapMaxS` is a disconnection; no sample at all is no follow-up.
            let horizon = min(followEnd, cutoff - 1)
            var last = heart.lastTs(in: Interval(end - config.endWindowS, end))
            var sawFollowUp = false
            var gapFound = false
            var idx = heart.lowerBound(end)
            while idx < heart.ts.count, heart.ts[idx] <= horizon {
                let t = heart.ts[idx]
                let previous = last ?? end
                if t - previous > config.hrGapMaxS {
                    events.append((previous, 0, censorDisconnect))
                    gapFound = true
                    break
                }
                last = t
                sawFollowUp = true
                idx += 1
            }
            if !gapFound {
                let tail = last ?? end
                if followEnd < cutoff {
                    if followEnd - tail > config.hrGapMaxS {
                        events.append(sawFollowUp ? (tail, 0, censorDisconnect) : (end, 1, censorNoFollowUp))
                    }
                } else if (cutoff - 1) - tail > config.hrGapMaxS {
                    // The stream stops before a cutoff that falls inside the follow-up: not yet available.
                    events.append((tail + 1, 4, censorCutoffReached))
                }
            }
            if cutoff <= followEnd { events.append((max(end, cutoff), 4, censorCutoffReached)) }
            if i + 1 < groups.count, groups[i + 1].interval.start <= followEnd {
                events.append((groups[i + 1].interval.start, 2, censorNextBout))
            }
            if let t = evidence.firstMovement(from: end, through: followEnd, minS: config.followUpMovementMinS,
                                              includeOther: config.followUpOtherMovementCounts) {
                events.append((t, 3, censorContinuedMovement))
            }
            events.sort { ($0.at, $0.rank) < ($1.at, $1.rank) }
            let truncatedAt = events.first?.at
            var censoring: [ReasonCode] = []
            for e in events where !censoring.contains(e.reason) { censoring.append(e.reason) }

            var observations: [RecoveryObservation] = []
            for o in config.recoveryOffsetsS.sorted() {
                let target = end + o
                let window = Interval(target - config.offsetToleranceS, target + config.offsetToleranceS + 1)
                var r = RecoveryObservation(offsetS: o, window: window, state: .unobserved, hrBpm: nil, samples: 0,
                                            declineBpm: nil, aboveReferenceBpm: nil, fractionRecovered: nil,
                                            reasons: [])
                if let t = truncatedAt, window.end > t {
                    r.state = .censored
                    r.reasons = [censoring[0]]
                    observations.append(r)
                    continue
                }
                let values = heart.values(window)
                r.samples = values.count
                guard values.count >= config.minSamplesPerReading, let hr = RobustStats.median(values) else {
                    r.reasons = [insufficientSamplesAtOffset]
                    observations.append(r)
                    continue
                }
                r.state = .observed
                r.hrBpm = hr
                if let e = endHr { r.declineBpm = e - hr } else { r.reasons.append(endHrUnavailable) }
                if let ref = reference {
                    r.aboveReferenceBpm = hr - ref
                    if let e = endHr {
                        if e - ref >= config.minRiseForFractionBpm, e - ref > 0 {
                            r.fractionRecovered = (e - hr) / (e - ref)
                        } else {
                            r.reasons.append(riseTooSmallForFraction)
                        }
                    }
                } else {
                    r.reasons.append(preBoutReferenceUnavailable)
                }
                let seen = Interval(end, window.end)
                if seen.duration - evidence.coveredSeconds(in: seen) > config.maxUncoveredInPauseS {
                    r.reasons.append(followUpMotionUnobserved)
                }
                r.reasons.sort()
                observations.append(r)
            }

            // Time to return: the first offset within tolerance, only when every earlier offset was observed.
            var reasons: [ReasonCode] = [postEffortDeclineNotClinicalHrr]
            var timeToReturn: Int?
            if let ref = reference {
                if let e = endHr, e - ref < config.minRiseForFractionBpm {
                    reasons.append(riseTooSmallForReturn)
                } else {
                    var decided = false
                    for r in observations {
                        guard r.state == .observed, let above = r.aboveReferenceBpm else {
                            reasons.append(r.state == .censored ? notReturnedByLastObservedOffset
                                                                : returnUndeterminedEarlierOffsetUnobserved)
                            decided = true
                            break
                        }
                        if above <= config.returnToleranceBpm {
                            timeToReturn = r.offsetS
                            decided = true
                            break
                        }
                    }
                    if !decided { reasons.append(notReturnedByLastObservedOffset) }
                }
            } else {
                reasons.append(preBoutReferenceUnavailable)
            }
            return BoutRecovery(
                followUp: Interval(end, followEnd + 1), anchorHrBpm: endHr, referenceBpm: reference,
                observations: observations, truncatedAt: truncatedAt, censoring: censoring,
                timeToReturnS: timeToReturn,
                hrv: BoutChannel(channel: MetricKind.hrvRmssd.rawValue, state: .unavailable,
                                 reasons: [hrvRecoveryUnsupported]),
                respiratory: BoutChannel(channel: MetricKind.respiratoryRate.rawValue, state: .unavailable,
                                         reasons: [noPostBoutRespiratoryEstimator]),
                reasons: Array(Set(reasons)).sorted())
        }

        /// Steps per locomotion minute from the wrap-aware counter (`StepsCounter.stepsInWindow`, the same
        /// per-minute slicing as the energy model); the increment ending at a minute's first sample comes from the
        /// sample just before it only when that sample is close and no break lies between.
        static func boutCadence(over iv: Interval, steps: [StepSample], evidence: BoutEvidence, breaks: [Interval],
                                config: ExertionConfig) -> BoutCadence {
            let limitations: [ReasonCode] = [uncalibratedStepCounter, wristCadenceNotGaitSpeed]
            let first = lowerBound(steps, iv.start)
            guard first < steps.count, steps[first].ts < iv.end else {
                return BoutCadence(state: .unavailable, stepsPerMinMean: nil, stepsPerMinCv: nil, minutes: 0,
                                   reasons: [cadenceUnavailable] + limitations)
            }
            var values: [Double] = []
            var unclassed = false
            for m in stride(from: iv.start, through: iv.end - 60, by: 60) {
                let minute = Interval(m, m + 60)
                guard evidence.locomotionSeconds(in: minute) >= config.cadenceMinuteLocomotionShare * 60 else {
                    continue
                }
                let lo = lowerBound(steps, m), hi = lowerBound(steps, m + 60)
                guard hi - lo >= config.stepMinSamplesPerMinute else { continue }
                var slice = Array(steps[lo..<hi])
                if lo > 0, m - steps[lo - 1].ts <= config.stepPreviousSampleMaxGapS,
                   !intersectsBreak(Interval(steps[lo - 1].ts, m), breaks) {
                    slice.insert(steps[lo - 1], at: 0)
                }
                if !slice.contains(where: { $0.activityClass != nil }) { unclassed = true }
                values.append(Double(StepsCounter.stepsInWindow(slice) ?? 0))
            }
            var reasons = limitations
            if unclassed { reasons.append(stepCounterUnclassed) }
            guard values.count >= config.cadenceMinMinutes, let mean = RobustStats.mean(values) else {
                return BoutCadence(state: .unavailable, stepsPerMinMean: nil, stepsPerMinCv: nil,
                                   minutes: values.count, reasons: ([insufficientCadenceMinutes] + reasons).sorted())
            }
            var cv: Double?
            if values.count >= 2, mean > 0 {
                let ss = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                cv = (ss / Double(values.count - 1)).squareRoot() / mean
            }
            return BoutCadence(state: unclassed ? .partial : .supported, stepsPerMinMean: mean, stepsPerMinCv: cv,
                               minutes: values.count, reasons: reasons.sorted())
        }

        /// The activity kind a bout is matched on: its kind, and for a logged workout the logged workout type
        /// (`workout_run`, `workout_mixed` for several types, `workout_unspecified`), so different efforts are not
        /// pooled under one `workout` label.
        static func matchKind(_ kind: String, workouts: [WorkoutInput]) -> String {
            guard kind == kindWorkout else { return kind }
            let types = Set(workouts.map { w -> String in
                let raw = (w.kind ?? "").lowercased()
                let cleaned = String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
                return cleaned.isEmpty ? "unspecified" : cleaned
            })
            return types.count == 1 ? "\(kindWorkout)_\(types.first!)" : "\(kindWorkout)_mixed"
        }

        static func matchKey(kind: String, durationS: Int, cadence: BoutCadence, preceding: String,
                             config: ExertionConfig) -> BoutMatchKey {
            let duration = band(Double(durationS), edges: config.durationBandEdgesS.map(Double.init), prefix: "d",
                                unit: "s")
            let cadenceBand = cadence.stepsPerMinMean.map {
                band($0, edges: config.cadenceBandEdges, prefix: "c", unit: "")
            } ?? cadenceUnavailable.rawValue
            return BoutMatchKey(key: "\(kind).\(cadenceBand).\(duration).\(preceding)", activityKind: kind,
                                durationBand: duration, cadenceBand: cadenceBand, precedingState: preceding,
                                workloadLimitations: workloadLimitations)
        }

        /// `<prefix>_lt<e0><unit>`, `<prefix><e0>_<e1><unit>`, ..., `<prefix>_ge<eN><unit>`.
        static func band(_ value: Double, edges: [Double], prefix: String, unit: String) -> String {
            let e = edges.sorted()
            func f(_ x: Double) -> String {
                x == x.rounded() ? String(Int(x)) : String(x).replacingOccurrences(of: ".", with: "p")
            }
            guard let firstEdge = e.first else { return "\(prefix)_all" }
            if value < firstEdge { return "\(prefix)_lt\(f(firstEdge))\(unit)" }
            for k in 1..<max(1, e.count) where value < e[k] {
                return "\(prefix)\(f(e[k - 1]))_\(f(e[k]))\(unit)"
            }
            return "\(prefix)_ge\(f(e[e.count - 1]))\(unit)"
        }

        // MARK: - Helpers

        /// One bout per id (a later revision of the same bout wins: larger end, then longer).
        static func unique(_ bouts: [ExertionBout]) -> [ExertionBout] {
            var byId: [String: ExertionBout] = [:]
            for b in bouts {
                if let existing = byId[b.id],
                   (existing.interval.end, existing.durationS) >= (b.interval.end, b.durationS) { continue }
                byId[b.id] = b
            }
            return byId.keys.sorted().map { byId[$0]! }
        }

        static func uniqueCoverage(_ coverage: [DayCoverage]) -> [DayCoverage] {
            var byDay: [String: DayCoverage] = [:]
            for c in coverage.sorted(by: { ($0.day, $0.observedS) < ($1.day, $1.observedS) }) {
                if let existing = byDay[c.day], existing.observedIntervals != nil, c.observedIntervals == nil {
                    continue
                }
                byDay[c.day] = c
            }
            return byDay.keys.sorted().map { byDay[$0]! }
        }

        static func merged(_ intervals: [Interval]) -> [Interval] {
            var out: [Interval] = []
            for iv in intervals.filter(\.isValid).sorted() {
                if var last = out.last, iv.start <= last.end {
                    last.end = max(last.end, iv.end)
                    out[out.count - 1] = last
                } else {
                    out.append(iv)
                }
            }
            return out
        }

        static func totalDuration(_ intervals: [Interval]) -> Int { intervals.reduce(0) { $0 + $1.duration } }

        static func lowerBound(_ steps: [StepSample], _ t: Int) -> Int {
            var lo = 0, hi = steps.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if steps[mid].ts < t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    // MARK: - Heart-rate independent evidence shared by Systems D and G

    /// One second-range of merged evidence: the HART label where HART has a confident label, else the strap label.
    struct EvidenceSpan: Equatable {
        var interval: Interval
        var label: String?
        var unknownFraction: Double
        var source: ActivitySource
    }

    struct BoutEvidence {
        let spans: [EvidenceSpan]
        let maxUnknown: Double

        init(hart: ResolvedTrack, strap: ResolvedTrack, maxUnknown: Double) {
            self.maxUnknown = maxUnknown
            let h = hart.spans.filter(\.interval.isValid).sorted { $0.interval < $1.interval }
            let s = strap.spans.filter(\.interval.isValid).sorted { $0.interval < $1.interval }
            var points = Set<Int>()
            for x in h { points.insert(x.interval.start); points.insert(x.interval.end) }
            for x in s { points.insert(x.interval.start); points.insert(x.interval.end) }
            let sorted = points.sorted()
            var out: [EvidenceSpan] = []
            var hi = 0, si = 0
            if sorted.count > 1 {
                for k in 0..<(sorted.count - 1) {
                    let lo = sorted[k], up = sorted[k + 1]
                    while hi < h.count, h[hi].interval.end <= lo { hi += 1 }
                    while si < s.count, s[si].interval.end <= lo { si += 1 }
                    let hs = hi < h.count && h[hi].interval.start <= lo ? h[hi] : nil
                    let ss = si < s.count && s[si].interval.start <= lo ? s[si] : nil
                    let pick: EvidenceSpan?
                    if let x = hs, x.label != nil, x.unknownFraction < maxUnknown {
                        pick = EvidenceSpan(interval: Interval(lo, up), label: x.label,
                                            unknownFraction: x.unknownFraction, source: .hartEpochs)
                    } else if let x = ss {
                        pick = EvidenceSpan(interval: Interval(lo, up), label: x.label,
                                            unknownFraction: x.unknownFraction, source: .strapMotion)
                    } else if let x = hs {
                        pick = EvidenceSpan(interval: Interval(lo, up), label: x.label,
                                            unknownFraction: x.unknownFraction, source: .hartEpochs)
                    } else {
                        pick = nil
                    }
                    guard let p = pick else { continue }
                    if var last = out.last, last.interval.end == lo, last.label == p.label,
                       last.unknownFraction == p.unknownFraction, last.source == p.source {
                        last.interval.end = up
                        out[out.count - 1] = last
                    } else {
                        out.append(p)
                    }
                }
            }
            spans = out
        }

        func isLocomotion(_ s: EvidenceSpan) -> Bool {
            MotionVocabulary.isLocomotion(s.label) && s.unknownFraction < maxUnknown
        }
        func isStationary(_ s: EvidenceSpan) -> Bool {
            MotionVocabulary.isStationary(s.label) && s.unknownFraction < maxUnknown
        }
        func isMovement(_ s: EvidenceSpan) -> Bool {
            MotionVocabulary.isMovement(s.label) && s.unknownFraction < maxUnknown
        }

        /// Index of the first span ending after `t`.
        func firstIndex(endingAfter t: Int) -> Int {
            var lo = 0, hi = spans.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if spans[mid].interval.end <= t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        func overlapping(_ w: Interval) -> ArraySlice<EvidenceSpan> {
            guard w.isValid, !spans.isEmpty else { return [] }
            let lo = firstIndex(endingAfter: w.start)
            var end = lo
            while end < spans.count, spans[end].interval.start < w.end { end += 1 }
            return spans[lo..<end]
        }

        func coveredSeconds(in w: Interval) -> Int {
            overlapping(w).reduce(0) { $0 + $1.interval.overlapSeconds(with: w) }
        }

        func locomotionSeconds(in w: Interval) -> Double {
            overlapping(w).reduce(0) { acc, s in
                isLocomotion(s) ? acc + Double(s.interval.overlapSeconds(with: w)) * (1 - s.unknownFraction) : acc
            }
        }

        /// Covered seconds per source over `w` and the source that holds most of them (HART on ties).
        func coveredBySource(in w: Interval) -> (source: ActivitySource, hartS: Double, strapS: Double) {
            var hart = 0, strap = 0
            for s in overlapping(w) {
                if s.source == .hartEpochs { hart += s.interval.overlapSeconds(with: w) }
                else { strap += s.interval.overlapSeconds(with: w) }
            }
            let source: ActivitySource = hart == 0 && strap == 0 ? .none : (hart >= strap ? .hartEpochs : .strapMotion)
            return (source, Double(hart), Double(strap))
        }

        func track(source: ActivitySource) -> ResolvedTrack {
            ResolvedTrack(source: source, heartRateDependent: false,
                          spans: spans.map { ResolvedSpan(interval: $0.interval, label: $0.label,
                                                          unknownFraction: $0.unknownFraction, revision: 0) },
                          overlaps: [], conflicts: [], droppedUnavailable: 0)
        }

        /// Start of the first contiguous movement run of at least `minS` seconds that starts in
        /// `[from, through]` (movement already under way at `from` counts from `from`).
        func firstMovement(from: Int, through: Int, minS: Int, includeOther: Bool) -> Int? {
            var runStart: Int?
            var runEnd = 0
            var i = firstIndex(endingAfter: from)
            while i < spans.count {
                let s = spans[i]
                let lo = max(s.interval.start, from)
                let moving = includeOther ? isMovement(s) : isLocomotion(s)
                if moving {
                    if let rs = runStart, runEnd == lo {
                        runEnd = s.interval.end
                        if runEnd - rs >= minS { return rs }
                    } else {
                        if lo > through { return nil }
                        runStart = lo
                        runEnd = s.interval.end
                        if runEnd - lo >= minS { return lo }
                    }
                } else {
                    runStart = nil
                    if s.interval.start > through { return nil }
                }
                i += 1
            }
            return nil
        }
    }

    /// Plausible HR samples sorted by time, with half-open range queries.
    struct HeartSeries {
        let ts: [Int]
        let bpm: [Double]

        init(_ observations: [HeartRateObservation], minBpm: Int, maxBpm: Int) {
            let sorted = observations.filter { (minBpm...maxBpm).contains($0.bpm) }
                .sorted { ($0.ts, $0.bpm) < ($1.ts, $1.bpm) }
            ts = sorted.map(\.ts)
            bpm = sorted.map { Double($0.bpm) }
        }

        func lowerBound(_ t: Int) -> Int {
            var lo = 0, hi = ts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ts[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        func values(_ w: Interval) -> [Double] {
            guard w.isValid else { return [] }
            return Array(bpm[lowerBound(w.start)..<lowerBound(w.end)])
        }

        /// Latest sample time inside `w`.
        func lastTs(in w: Interval) -> Int? {
            guard w.isValid else { return nil }
            let hi = lowerBound(w.end)
            return hi > lowerBound(w.start) ? ts[hi - 1] : nil
        }
    }
}
