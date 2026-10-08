import Foundation

// PCEligibility.swift — System B: physiological measurement eligibility (spec §8).
//
// OWNER: signal & eligibility workstream. Behaviour, defaults and reason codes: docs/physiology-context/notes/signal.md.
//
// Behavioural eligibility never requires a favourable value of the metric being studied: no gate reads the
// measurement's value (V03). Gates that read the target's own signal or sensor — signal validity and the input
// screens behind it (HR plausible band, RR kernel range, ectopic rejection), and for optical-pulse metrics the
// HR-confirmed sleep detector and HR-presence wear — are declared in `EligibilityVerdict.targetDependentGates` so
// their selection effect can be reviewed (notes/signal.md §6, "Selection bias").
//
// Tri-state logic: every check is evaluated and contributes `fail` (determined and failed → ineligible), `unknown`
// (could not be determined) or nothing. Any fail ⇒ ineligible; else any unknown ⇒ unknown; else eligible. All
// reasons are kept, the deciding ones first (fails, then unknowns; the positive reason when eligible); recorded
// limits that did not decide follow and are repeated in `notes`. Quiet motion is never evidence of being
// awake, worn or rested: those come only from `SleepWearContext` (System C), and unknown stays unknown (V02).
// Wrist posture is never an eligibility gate: arm orientation is a likelihood, not a confirmed standing or
// orthostatic event. It stratifies the stable-awake references instead (`PostureContext`, recumbent / upright
// likely, never sitting vs standing). A decoder POSTURAL TRANSITION event is a gate: stable awake rest needs the
// support and the settling time before it (`posturalSettlingS`, 1-2 min of cardiovascular settling after a change
// of posture) free of one. The decoder reads heart rate, so that gate is declared target-dependent for
// optical-pulse metrics, as is the per-epoch wear-signal quality (fused from optical signal quality).

extension PhysiologyContext {

    /// One row of the dose-scaled post-bout exclusion: a bout of `kind` (nil = any kind) lasting at least
    /// `minDurationS` excludes stable awake rest for `exclusionS` after it ends.
    public struct PostBoutDose: Codable, Equatable, Sendable {
        public var kind: String?
        public var minDurationS: Int
        public var exclusionS: Int
        public init(kind: String? = nil, minDurationS: Int, exclusionS: Int) {
            self.kind = kind; self.minDurationS = minDurationS; self.exclusionS = exclusionS
        }
    }

    public struct EligibilityConfig: Codable, Equatable, Sendable {
        public var version = Eligibility.version
        public var motion = MotionEvidenceConfig()
        /// Heart-rate free posture strata (reference stratification only; never a gate).
        public var posture = PostureConfig()
        /// Stable awake rest: stationary share of the WHOLE support (ActivityContextJoin.restingStationaryFloor).
        public var stationaryFloorShare = 0.90
        /// Stable awake rest: qualified (labelled) coverage of the whole support (restingCoverageFloor).
        public var qualifiedCoverageFloorShare = 0.90
        /// Stable awake rest: continuous stillness ending at the support start (ActivityPolicyConfig.minStillnessS).
        public var minPrecedingStillS = 300
        /// Stable awake rest: locomotion that ended less than this before the support excludes it
        /// (ActivityPolicyConfig.postActivityWindowS).
        public var postActivityWindowS = 600
        /// Stable awake rest: a supported bout that ended less than this before the support excludes it (0 disables
        /// every post-bout exclusion). The floor of the dose-scaled exclusion below.
        public var postBoutExclusionS = 600
        /// Dose-scaled post-bout exclusion (D8-06): the longest matching row applies, never below
        /// `postBoutExclusionS`. Bouts carry no intensity (they are heart-rate free), so the kind stands in for it.
        /// Literature (Seiler 2007, supine HRV): back to baseline 5-10 min after up to 120 min below the first
        /// ventilatory threshold, ~30 min after threshold work, 90 min or more after hard work in trained
        /// athletes. Walking and stepping of any length are light: the 600 s floor (that source, which says
        /// duration below the threshold does not lengthen recovery). Running stands in for threshold-or-harder
        /// work: 30 min, and 60 / 90 min when long (the duration steps are conservative choices; the source
        /// grades intensity, not duration). A logged workout of unknown intensity gets 30 min (60 min when it
        /// lasted an hour or more): a conservative choice, not derived from that source.
        public var postBoutDoses: [PostBoutDose] = [
            PostBoutDose(kind: ExertionBouts.kindWorkout, minDurationS: 0, exclusionS: 1800),
            PostBoutDose(kind: ExertionBouts.kindWorkout, minDurationS: 3600, exclusionS: 3600),
            PostBoutDose(kind: ExertionBouts.kindRunning, minDurationS: 0, exclusionS: 1800),
            PostBoutDose(kind: ExertionBouts.kindRunning, minDurationS: 1200, exclusionS: 3600),
            PostBoutDose(kind: ExertionBouts.kindRunning, minDurationS: 3600, exclusionS: 5400),
        ]
        /// Stable awake rest: optional exclusion when the trailing 24 h locomotion exceeds this (nil = record only).
        public var maxLocomotion24hS: Int? = nil
        /// Activity response: a support starting within this many seconds after a bout ended follows that bout.
        public var activityResponseWindowS = 900
        /// Activity response: locomotion share of the whole support that counts as inside the activity.
        public var activityResponseMinLocomotionShare = 0.50
        /// Activity response: labelled coverage below which "no activity" cannot be asserted.
        public var activityResponseMinCoverageShare = 0.50
        /// Stable awake rest: a decoder postural transition event in `[support.start - posturalSettlingS,
        /// support.end)` excludes the support (cardiovascular settling after a posture change takes 1-2 min,
        /// Watanabe 2007; Bourdillon 2017).
        public var posturalSettlingS = 120
        /// A postural event at or above this probability fails the support; a weaker one makes it unknown.
        public var posturalTransitionFailProbability = 0.5
        /// Below this share of the settling window covered by decoder documents, "no event" is recorded as only
        /// partly observed (a note, never a gate: older days have no decoder document).
        public var transitionCoverageFloorShare = 0.9
        /// Stable awake rest: a mean source confidence of the activity composition below this makes the
        /// stillness undetermined (sources without a confidence are thresholded, never gated here).
        public var minActivityConfidence = 0.5
        /// Stable awake rest: a share of the support above this with poor wear-signal quality (loose strap,
        /// motion artifact, sensor dropout, off wrist) makes the support unknown. 0 = any poor second.
        public var wearSignalPoorMaxShare = 0.0
        public init() {}
    }

    /// A named comparison a measurement can be eligible for.
    public enum ComparisonKind: String, Codable, CaseIterable, Sendable {
        /// Stable awake low movement (not "calm", not "recovered").
        case stableAwakeRest = "stable_awake_rest"
        /// A measurement taken during a supported sleep episode.
        case sleepMeasurement = "sleep_measurement"
        /// A measurement inside or right after a supported exertion bout.
        case activityResponse = "activity_response"
    }

    public enum EligibilityState: String, Codable, CaseIterable, Sendable {
        case eligible, ineligible, unknown
    }

    public struct EligibilityVerdict: Codable, Equatable, Sendable, Hashable {
        public var comparison: ComparisonKind
        public var state: EligibilityState
        /// Every reason, the deciding ones first: for `ineligible` the failed checks (then what was unknown), for
        /// `unknown` the undetermined checks, for `eligible` the positive reason. Recorded limits that did not
        /// decide the state follow them and are also listed in `notes`. `reasons.first` is therefore always why
        /// the verdict has its state.
        public var reasons: [ReasonCode]
        public var evidence: [Diagnostic]
        /// Gates in effect for this verdict that read the target metric's own signal or its sensor (declared for
        /// selection-bias review): `signal_invalid` always; `hr_plausible_band`, `rr_kernel_range` and
        /// `ectopic_rejection` when the validity assessment applied them to this measurement's input;
        /// `sleep_detector_hr_confirmation` and `wear_from_heart_rate_presence` when the sleep / wake or wear
        /// state the comparison relied on came from heart-rate evidence and the metric is optical-pulse derived.
        public var targetDependentGates: [ReasonCode]
        /// Evidence sources that depend on heart-derived signals (e.g. `sleep_detector_uses_heart_rate`).
        public var dependsOn: [String]
        public var policyVersion: String
        /// The subset of `reasons` that did not decide the state (e.g. `signal_degraded`,
        /// `recent_locomotion_unobserved`). Selection accounting counts only the other reasons as exclusions.
        public var notes: [ReasonCode] = []

        public init(comparison: ComparisonKind, state: EligibilityState, reasons: [ReasonCode],
                    evidence: [Diagnostic] = [], targetDependentGates: [ReasonCode] = [], dependsOn: [String] = [],
                    policyVersion: String, notes: [ReasonCode] = []) {
            self.comparison = comparison; self.state = state; self.reasons = reasons; self.evidence = evidence
            self.targetDependentGates = targetDependentGates; self.dependsOn = dependsOn
            self.policyVersion = policyVersion; self.notes = notes
        }

        public func evidence(_ name: String) -> Double? { evidence.first { $0.name == name }?.value }

        /// The reasons that decided the state (`reasons` without `notes`).
        public var decidingReasons: [ReasonCode] { reasons.filter { !notes.contains($0) } }

        enum CodingKeys: String, CodingKey {
            case comparison, state, reasons, evidence, targetDependentGates, dependsOn, policyVersion, notes
        }

        /// Verdicts written before `notes` existed decode with no notes; empty notes are not written.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            comparison = try c.decode(ComparisonKind.self, forKey: .comparison)
            state = try c.decode(EligibilityState.self, forKey: .state)
            reasons = try c.decode([ReasonCode].self, forKey: .reasons)
            evidence = try c.decode([Diagnostic].self, forKey: .evidence)
            targetDependentGates = try c.decode([ReasonCode].self, forKey: .targetDependentGates)
            dependsOn = try c.decode([String].self, forKey: .dependsOn)
            policyVersion = try c.decode(String.self, forKey: .policyVersion)
            notes = try c.decodeIfPresent([ReasonCode].self, forKey: .notes) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(comparison, forKey: .comparison)
            try c.encode(state, forKey: .state)
            try c.encode(reasons, forKey: .reasons)
            try c.encode(evidence, forKey: .evidence)
            try c.encode(targetDependentGates, forKey: .targetDependentGates)
            try c.encode(dependsOn, forKey: .dependsOn)
            try c.encode(policyVersion, forKey: .policyVersion)
            if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
        }
    }

    public struct ReasonCount: Codable, Equatable, Sendable {
        public var reason: ReasonCode
        public var count: Int
        public init(reason: ReasonCode, count: Int) { self.reason = reason; self.count = count }
    }

    /// Context-selection accounting for one comparison and metric over the day (spec §14 last bullet): how much of
    /// the observed day is eligible (System B), and how much of it actually entered the day's reference values
    /// (System F's daily values, which also drop degraded windows, other window lengths and days with too few
    /// windows).
    public struct SelectionSummary: Codable, Equatable, Sendable {
        public var comparison: ComparisonKind
        public var metric: MetricKind
        public var eligible: Int
        public var ineligible: Int
        public var unknown: Int
        /// Seconds of the day covered by the union of eligible supports (overlapping supports count once).
        public var eligibleSupportS: Int
        /// Seconds of the day with any observation of the metric's input stream (HR samples for heart-rate
        /// metrics, beat seconds for HRV / respiration, samples for skin temperature).
        public var observedS: Int
        /// `enteredObservedS / observedS`: the share of the day's observed time represented by measurements that
        /// entered a reference value (a daily value) for this comparison. nil when nothing was observed or when no
        /// envelope-built reference series exists for this comparison and metric (activity-response series are
        /// built from bouts, not envelopes). Never above 1, never above `eligibleShare`.
        public var representedShare: Double?
        /// Ineligible + unknown verdicts' deciding reasons (notes excluded), most frequent first
        /// (top `Eligibility.topExclusionReasons`).
        public var exclusionReasons: [ReasonCount]
        /// Observed seconds inside the union of eligible supports.
        public var eligibleObservedS: Int = 0
        /// `eligibleObservedS / observedS`: the eligibility-level share (System B only; nil when nothing observed).
        public var eligibleShare: Double? = nil
        /// Eligible verdicts whose envelope entered a daily value of this comparison (nil when no envelope-built
        /// reference series exists for the pair).
        public var enteredCount: Int? = nil
        /// Seconds of the day covered by the union of the entered envelopes' supports.
        public var enteredSupportS: Int = 0
        /// Observed seconds inside the union of the entered envelopes' supports.
        public var enteredObservedS: Int = 0

        public init(comparison: ComparisonKind, metric: MetricKind, eligible: Int, ineligible: Int, unknown: Int,
                    eligibleSupportS: Int, observedS: Int, representedShare: Double?,
                    exclusionReasons: [ReasonCount], eligibleObservedS: Int = 0, eligibleShare: Double? = nil,
                    enteredCount: Int? = nil, enteredSupportS: Int = 0, enteredObservedS: Int = 0) {
            self.comparison = comparison; self.metric = metric; self.eligible = eligible
            self.ineligible = ineligible; self.unknown = unknown; self.eligibleSupportS = eligibleSupportS
            self.observedS = observedS; self.representedShare = representedShare
            self.exclusionReasons = exclusionReasons; self.eligibleObservedS = eligibleObservedS
            self.eligibleShare = eligibleShare; self.enteredCount = enteredCount
            self.enteredSupportS = enteredSupportS; self.enteredObservedS = enteredObservedS
        }

        enum CodingKeys: String, CodingKey {
            case comparison, metric, eligible, ineligible, unknown, eligibleSupportS, observedS, representedShare,
                 exclusionReasons, eligibleObservedS, eligibleShare, enteredCount, enteredSupportS, enteredObservedS
        }

        /// Summaries written before the entered-share fields existed decode with their defaults.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            comparison = try c.decode(ComparisonKind.self, forKey: .comparison)
            metric = try c.decode(MetricKind.self, forKey: .metric)
            eligible = try c.decode(Int.self, forKey: .eligible)
            ineligible = try c.decode(Int.self, forKey: .ineligible)
            unknown = try c.decode(Int.self, forKey: .unknown)
            eligibleSupportS = try c.decode(Int.self, forKey: .eligibleSupportS)
            observedS = try c.decode(Int.self, forKey: .observedS)
            representedShare = try c.decodeIfPresent(Double.self, forKey: .representedShare)
            exclusionReasons = try c.decode([ReasonCount].self, forKey: .exclusionReasons)
            eligibleObservedS = try c.decodeIfPresent(Int.self, forKey: .eligibleObservedS) ?? 0
            eligibleShare = try c.decodeIfPresent(Double.self, forKey: .eligibleShare)
            enteredCount = try c.decodeIfPresent(Int.self, forKey: .enteredCount)
            enteredSupportS = try c.decodeIfPresent(Int.self, forKey: .enteredSupportS) ?? 0
            enteredObservedS = try c.decodeIfPresent(Int.self, forKey: .enteredObservedS) ?? 0
        }
    }

    public enum Eligibility {

        /// pc-eligibility-4: a decoder transition event counts over its onset-to-detection span `[onsetTs, ts]`
        /// (INT-C), not at its detection second only, so the postural-settling gate can move. Documents decided
        /// under pc-eligibility-3 are told apart by `PolicyVersions.eligibility` and the policy fingerprint.
        public static let version = "pc-eligibility-4"
        public static let topExclusionReasons = 10

        // MARK: Reason codes — positive
        public static let stableAwakeLowMovement: ReasonCode = "stable_awake_low_movement"
        public static let insideSupportedSleep: ReasonCode = "inside_supported_sleep"
        public static let insideLocomotion: ReasonCode = "inside_locomotion"
        public static let afterExertionBout: ReasonCode = "after_exertion_bout"
        // MARK: Reason codes — shared
        public static let invalidInterval: ReasonCode = "invalid_interval"
        public static let signalInvalid: ReasonCode = "signal_invalid"
        public static let signalDegraded: ReasonCode = "signal_degraded"
        public static let signalValidityMissing: ReasonCode = "signal_validity_missing"
        public static let signalUnverified: ReasonCode = "signal_unverified"
        public static let signalUnsupported: ReasonCode = "signal_unsupported"
        public static let heartRateDependentActivityIgnored: ReasonCode = "heart_rate_dependent_activity_ignored"
        public static let activityEvidenceUnavailable: ReasonCode = Engine.activityUnavailable
        public static let insufficientActivityCoverage: ReasonCode = "insufficient_activity_coverage"
        public static let asleep: ReasonCode = "asleep"
        public static let sleepWakeMixed: ReasonCode = "sleep_wake_mixed"
        public static let awakeEvidenceUnknown: ReasonCode = "awake_evidence_unknown"
        public static let notWorn: ReasonCode = "not_worn"
        public static let wearMixed: ReasonCode = "wear_mixed"
        public static let wearEvidenceUnknown: ReasonCode = "wear_evidence_unknown"
        // MARK: Reason codes — stable awake rest
        public static let movementInSupport: ReasonCode = "movement_in_support"
        public static let insufficientStationary: ReasonCode = "insufficient_stationary"
        public static let insufficientPrecedingStillness: ReasonCode = "insufficient_preceding_stillness"
        public static let precedingStillnessUnobserved: ReasonCode = "preceding_stillness_unobserved"
        public static let recentLocomotion: ReasonCode = "recent_locomotion"
        public static let recentLocomotionUnobserved: ReasonCode = "recent_locomotion_unobserved"
        public static let recentExertionBout: ReasonCode = "recent_exertion_bout"
        public static let exertionHistoryExceedsLimit: ReasonCode = "exertion_history_exceeds_limit"
        /// A decoder postural transition at or above the fail probability in the support or its settling window.
        public static let recentPosturalTransition: ReasonCode = "recent_postural_transition"
        /// A weaker decoder postural transition there: whether the posture changed is undetermined.
        public static let possiblePosturalTransition: ReasonCode = "possible_postural_transition"
        /// No event, but decoder documents cover less than the floor of the settling window (note).
        public static let transitionEventsPartlyObserved: ReasonCode = "transition_events_partly_observed"
        public static let lowActivityConfidence: ReasonCode = "low_activity_confidence"
        public static let wearSignalPoor: ReasonCode = "wear_signal_poor"
        // MARK: Reason codes — sleep measurement / activity response
        public static let notAsleep: ReasonCode = "not_asleep"
        public static let sleepEvidenceUnknown: ReasonCode = "sleep_evidence_unknown"
        public static let noSupportedExertion: ReasonCode = "no_supported_exertion"
        // MARK: Target-dependent gates (`EligibilityVerdict.targetDependentGates`; `signal_invalid` is the first)
        /// The sleep detector keeps a sleep run only when its heart rate is low enough relative to the day, and its
        /// "no sleep here" needs heart-rate coverage: the sleep / wake state of an optical-pulse metric is selected
        /// partly on that metric's own sensor.
        public static let gateSleepDetectorHrConfirmation: ReasonCode = "sleep_detector_hr_confirmation"
        /// Wear established from the presence of a heart-rate signal (the target's own sensor).
        public static let gateWearFromHeartRatePresence: ReasonCode = "wear_from_heart_rate_presence"
        public static let gateHrPlausibleBand: ReasonCode = SignalValidityEngine.gateHrPlausibleBand
        public static let gateRrKernelRange: ReasonCode = SignalValidityEngine.gateRrKernelRange
        public static let gateEctopicRejection: ReasonCode = SignalValidityEngine.gateEctopicRejection
        /// Postural transition events come from the v2 decoder, which reads heart rate.
        public static let gateDecoderTransitionEvents: ReasonCode = "decoder_transition_events"
        /// The per-epoch wear-signal quality is fused from optical signal quality (the target's sensor).
        public static let gateWearSignalOpticalQuality: ReasonCode = "wear_signal_optical_quality"

        public static let targetDependentGateCodes: [ReasonCode] = [
            signalInvalid, gateHrPlausibleBand, gateRrKernelRange, gateEctopicRejection,
            gateSleepDetectorHrConfirmation, gateWearFromHeartRatePresence, gateDecoderTransitionEvents,
            gateWearSignalOpticalQuality,
        ]

        public static let reasonCodes: [ReasonCode] = [
            stableAwakeLowMovement, insideSupportedSleep, insideLocomotion, afterExertionBout, invalidInterval,
            signalInvalid, signalDegraded, signalValidityMissing, signalUnverified, signalUnsupported,
            heartRateDependentActivityIgnored, activityEvidenceUnavailable, insufficientActivityCoverage, asleep,
            sleepWakeMixed, awakeEvidenceUnknown, notWorn, wearMixed, wearEvidenceUnknown, movementInSupport,
            insufficientStationary, insufficientPrecedingStillness, precedingStillnessUnobserved, recentLocomotion,
            recentLocomotionUnobserved, recentExertionBout, exertionHistoryExceedsLimit, notAsleep,
            sleepEvidenceUnknown, noSupportedExertion, gateSleepDetectorHrConfirmation, gateWearFromHeartRatePresence,
            gateHrPlausibleBand, gateRrKernelRange, gateEctopicRejection, recentPosturalTransition,
            possiblePosturalTransition, transitionEventsPartlyObserved, lowActivityConfidence, wearSignalPoor,
            gateDecoderTransitionEvents, gateWearSignalOpticalQuality,
        ]

        /// Metrics measured by the optical pulse sensor (HR, beat intervals and what is derived from them).
        static let opticalPulseMetrics: Set<MetricKind> = [.heartRate, .restingHeartRate, .hrvRmssd, .hrvSdnn,
                                                           .respiratoryRate]

        // MARK: Dependence labels (`EligibilityVerdict.dependsOn`)
        public static let sleepDetectorUsesHeartRate = "sleep_detector_uses_heart_rate"
        public static let wearFromHeartRateSignal = "wear_from_heart_rate_signal"
        public static let activityLabelsReadHeartRate = "activity_labels_read_heart_rate"
        public static let transitionEventsReadHeartRate = "transition_events_read_heart_rate"
        public static let wearSignalReadsOpticalQuality = "wear_signal_reads_optical_quality"

        /// The comparisons that apply to a metric/method. Series and context-derived windows (`series.*`,
        /// `context.*`) can be stable-awake, sleep or activity-response measurements; a nightly snapshot value
        /// (`snapshot.*`) is a sleep measurement only; the unverified SpO2 candidate takes part in none.
        public static func comparisons(for metric: MetricKind, method: MethodRef) -> [ComparisonKind] {
            if metric == .spo2Candidate { return [] }
            if method.id.hasPrefix("snapshot.") { return [.sleepMeasurement] }
            if method.id.hasPrefix("series.") || method.id.hasPrefix("context.") {
                return [.stableAwakeRest, .sleepMeasurement, .activityResponse]
            }
            // Unknown producers: session / day aggregates are sleep-or-day products, windows get all three.
            switch method.aggregation {
            case .session, .day: return [.sleepMeasurement]
            default: return [.stableAwakeRest, .sleepMeasurement, .activityResponse]
            }
        }

        /// Accumulates checks for one verdict. Failed, undetermined, positive and note reasons are kept apart so the
        /// verdict can list the deciding reasons first.
        private struct Builder {
            var fails: [ReasonCode] = []
            var unknowns: [ReasonCode] = []
            var positives: [ReasonCode] = []
            var notes: [ReasonCode] = []
            var evidence: [Diagnostic] = []
            var dependsOn: [String] = []
            var gates: [ReasonCode] = [signalInvalid]
            mutating func fail(_ r: ReasonCode) { Self.add(&fails, r) }
            mutating func unknown(_ r: ReasonCode) { Self.add(&unknowns, r) }
            /// A positive reason: deciding when the verdict is eligible, a note otherwise.
            mutating func positive(_ r: ReasonCode) { Self.add(&positives, r) }
            mutating func note(_ r: ReasonCode) { Self.add(&notes, r) }
            mutating func gate(_ r: ReasonCode) { Self.add(&gates, r) }
            mutating func depends(_ s: String) { if !dependsOn.contains(s) { dependsOn.append(s) } }
            static func add(_ list: inout [ReasonCode], _ r: ReasonCode) { if !list.contains(r) { list.append(r) } }
            /// Evidence is rounded to 1e-4 for the document (decisions use the unrounded values).
            mutating func diag(_ name: String, _ value: Double?) {
                if let v = value, v.isFinite { evidence.append(Diagnostic(name, (v * 10_000).rounded() / 10_000)) }
            }
            var state: EligibilityState {
                !fails.isEmpty ? .ineligible : (!unknowns.isEmpty ? .unknown : .eligible)
            }
            /// (all reasons with the deciding ones first, the non-deciding subset).
            func ordered() -> (reasons: [ReasonCode], notes: [ReasonCode]) {
                let deciding: [ReasonCode]
                var trailing: [ReasonCode]
                switch state {
                case .ineligible: deciding = fails + unknowns; trailing = positives + notes
                case .unknown: deciding = unknowns; trailing = positives + notes
                case .eligible: deciding = positives; trailing = notes
                }
                var seen = Set<ReasonCode>()
                let first = deciding.filter { seen.insert($0).inserted }
                trailing = trailing.filter { seen.insert($0).inserted }
                return (first + trailing, trailing)
            }
        }

        /// Activity shares over the whole support from an HR-independent composition.
        private struct Shares {
            var stationary = 0.0
            var movement = 0.0
            var locomotion = 0.0
            var qualified = 0.0
        }

        private static func shares(_ c: ActivityComposition) -> Shares {
            var s = Shares()
            let d = Double(max(1, c.intervalS))
            for l in c.labels {
                if MotionVocabulary.isStationary(l.label) { s.stationary += l.seconds }
                else if MotionVocabulary.isMovement(l.label) {
                    s.movement += l.seconds
                    if MotionVocabulary.isLocomotion(l.label) { s.locomotion += l.seconds }
                }
            }
            s.qualified = (s.stationary + s.movement) / d
            s.stationary /= d; s.movement /= d; s.locomotion /= d
            return s
        }

        /// Evaluate one comparison for one measurement.
        ///
        /// - Parameters:
        ///   - settlingTransitions: decoder transition events over `[support.start - posturalSettlingS,
        ///     support.end)` (`TransitionEvents.summary`); nil when no decoder document covers that window, which
        ///     gates nothing.
        ///   - wearSignal: the per-epoch wear-signal quality over the support; nil when no epoch carried one.
        public static func evaluate(_ kind: ComparisonKind, metric: MetricKind, support: Interval,
                                    validity: SignalValidity, activity: ActivityComposition,
                                    preceding: PrecedingHistory, sleepWear: SleepWearContext,
                                    exertion: [ExertionWindowSummary], recentBouts: [BoutRef],
                                    config: EligibilityConfig, settlingTransitions: TransitionEventSummary? = nil,
                                    wearSignal: WearSignalSummary? = nil) -> EligibilityVerdict {
            var b = Builder()
            guard support.isValid else {
                b.unknown(invalidInterval)
                return finish(kind, b, config)
            }
            // The target-dependent quality gate (reads the measurement's own signal, never its value alone).
            switch validity.state {
            case .valid: break
            case .degraded: b.note(signalDegraded)
            case .invalid: b.fail(signalInvalid)
            case .missing: b.unknown(signalValidityMissing)
            case .unverified: b.fail(signalUnverified)
            case .unsupported: b.unknown(signalUnsupported)
            }
            declareValidityGates(&b, metric: metric, validity: validity)
            declareContextGates(&b, kind: kind, metric: metric, sleepWear: sleepWear)
            let activityUsable = !activity.heartRateDependent && activity.source != .decoderIntervals
                && activity.source != .none && activity.coveredS > 0
            if activity.heartRateDependent || activity.source == .decoderIntervals {
                b.note(heartRateDependentActivityIgnored)
                b.depends(activityLabelsReadHeartRate)
            }
            switch kind {
            case .stableAwakeRest:
                stableAwake(&b, activity: activity, usable: activityUsable, preceding: preceding,
                            sleepWear: sleepWear, exertion: exertion, recentBouts: recentBouts, config: config)
                posturalSettling(&b, metric: metric, support: support, events: settlingTransitions, config: config)
                wearSignalQuality(&b, metric: metric, support: support, wearSignal: wearSignal, config: config)
            case .sleepMeasurement:
                sleepMeasurement(&b, activity: activity, usable: activityUsable, sleepWear: sleepWear)
            case .activityResponse:
                activityResponse(&b, activity: activity, usable: activityUsable, sleepWear: sleepWear,
                                 recentBouts: recentBouts, config: config)
            }
            return finish(kind, b, config)
        }

        private static func finish(_ kind: ComparisonKind, _ b: Builder, _ config: EligibilityConfig) -> EligibilityVerdict {
            var b = b
            if b.state == .eligible {
                switch kind {
                case .stableAwakeRest: b.positives.insert(stableAwakeLowMovement, at: 0)
                case .sleepMeasurement: b.positives.insert(insideSupportedSleep, at: 0)
                case .activityResponse: break  // the positive reason was added by the check that passed
                }
            }
            let (reasons, notes) = b.ordered()
            return EligibilityVerdict(comparison: kind, state: b.state, reasons: reasons, evidence: b.evidence,
                                      targetDependentGates: b.gates, dependsOn: b.dependsOn,
                                      policyVersion: config.version, notes: notes)
        }

        /// Validity gates that read the target's own input values: the HR plausible band (a majority of samples
        /// outside it degrades the estimate), the RR kernel range (300–2000 ms beats are rejected) and ectopic
        /// rejection (beats that differ too much from their neighbours are rejected). Declared when the
        /// assessment applied them to this measurement (its incident counters are non-zero), whatever the state.
        private static func declareValidityGates(_ b: inout Builder, metric: MetricKind, validity: SignalValidity) {
            switch metric {
            case .heartRate, .restingHeartRate:
                if (validity.diagnostic("out_of_band_samples") ?? 0) > 0 { b.gate(gateHrPlausibleBand) }
            case .hrvRmssd, .hrvSdnn:
                if (validity.diagnostic("out_of_range_beats") ?? 0) > 0 { b.gate(gateRrKernelRange) }
                if (validity.diagnostic("ectopic_rejected") ?? 0) > 0 { b.gate(gateEctopicRejection) }
            default:
                break
            }
        }

        /// Context gates that read the target's own sensor for optical-pulse metrics: a sleep / wake state from the
        /// HR-confirmed sleep detector (or the band's undocumented sleep state), and wear from heart-rate presence
        /// where wear is required. Skin temperature is not read by either, so it only records the dependence.
        private static func declareContextGates(_ b: inout Builder, kind: ComparisonKind, metric: MetricKind,
                                                sleepWear: SleepWearContext) {
            guard opticalPulseMetrics.contains(metric) else { return }
            if sleepWear.sleepDependsOnHeartSignals { b.gate(gateSleepDetectorHrConfirmation) }
            let wearRequired = kind != .activityResponse
            let wearFromHeart = sleepWear.wearDependsOnHeartSignals
                || sleepWear.wearEvidence.contains(SleepRhythm.evidenceHeartRateSignal)
            if wearRequired && wearFromHeart { b.gate(gateWearFromHeartRatePresence) }
        }

        private static func awakeAndWorn(_ b: inout Builder, _ sw: SleepWearContext) {
            switch sw.sleepState {
            case .awake: break
            case .asleep: b.fail(asleep)
            case .mixed: b.fail(sleepWakeMixed)
            case .unknown: b.unknown(awakeEvidenceUnknown)
            }
            worn(&b, sw, required: true)
            if sw.sleepDependsOnHeartSignals && sw.sleepState != .unknown { b.depends(sleepDetectorUsesHeartRate) }
        }

        private static func worn(_ b: inout Builder, _ sw: SleepWearContext, required: Bool) {
            switch sw.wearState {
            case .worn: break
            case .notWorn: b.fail(notWorn)
            case .mixed: if required { b.fail(wearMixed) } else { b.note(wearMixed) }
            case .unknown: if required { b.unknown(wearEvidenceUnknown) } else { b.note(wearEvidenceUnknown) }
            }
            if sw.wearEvidence.contains("heart_rate_signal_present") { b.depends(wearFromHeartRateSignal) }
        }

        // MARK: Stable awake rest

        private static func stableAwake(_ b: inout Builder, activity: ActivityComposition, usable: Bool,
                                        preceding: PrecedingHistory, sleepWear: SleepWearContext,
                                        exertion: [ExertionWindowSummary], recentBouts: [BoutRef],
                                        config: EligibilityConfig) {
            awakeAndWorn(&b, sleepWear)
            if usable {
                let s = shares(activity)
                b.diag("stationary_share", s.stationary)
                b.diag("movement_share", s.movement)
                b.diag("qualified_coverage", s.qualified)
                // Even if every unlabelled second were stationary the floor could not be met: determined.
                if 1 - s.movement < config.stationaryFloorShare { b.fail(movementInSupport) }
                else if s.qualified < config.qualifiedCoverageFloorShare { b.unknown(insufficientActivityCoverage) }
                else if s.stationary < config.stationaryFloorShare { b.unknown(insufficientStationary) }
                // A stationary label the classifier itself is unsure of does not establish stillness.
                if let c = activity.meanConfidence {
                    b.diag("activity_mean_confidence", c)
                    if c < config.minActivityConfidence { b.unknown(lowActivityConfidence) }
                }

                b.diag("preceding_still_run_s", Double(preceding.stillRunS))
                if preceding.stillRunS < config.minPrecedingStillS {
                    if preceding.stillRunEndedBy == IntervalAlgebra.stillRunMovement {
                        b.fail(insufficientPrecedingStillness)
                    } else {
                        b.unknown(precedingStillnessUnobserved)
                    }
                }
                if let since = preceding.secondsSinceSupportedActivity {
                    b.diag("seconds_since_locomotion", Double(since))
                    if since < config.postActivityWindowS { b.fail(recentLocomotion) }
                } else if preceding.stillRunS < config.postActivityWindowS
                            && preceding.stillRunEndedBy != IntervalAlgebra.stillRunMovement {
                    // No locomotion seen, but the post-activity window was not fully observed: recorded, not gating.
                    b.note(recentLocomotionUnobserved)
                }
            } else {
                b.unknown(activity.coveredS > 0 && !activity.heartRateDependent ? insufficientActivityCoverage
                                                                                : activityEvidenceUnavailable)
            }
            exertionEvidence(&b, exertion: exertion, recentBouts: recentBouts)
            if config.postBoutExclusionS > 0 {
                // Every recent bout is checked: a long run two hours ago can still exclude after a short walk.
                let excluding = recentBouts.filter { $0.secondsBeforeMeasurement < postBoutExclusionS($0, config) }
                if let deciding = excluding.max(by: { postBoutExclusionS($0, config) < postBoutExclusionS($1, config) }) {
                    b.diag("post_bout_exclusion_s", Double(postBoutExclusionS(deciding, config)))
                    b.fail(recentExertionBout)
                }
            }
            if let limit = config.maxLocomotion24hS, let w = exertion.first(where: { $0.windowH == 24 }),
               w.locomotionS > limit {
                b.fail(exertionHistoryExceedsLimit)
            }
        }

        /// Stable awake rest: no decoder postural transition in the support or the settling time before it. Only
        /// "a change happened" is used (the decoder's direction is unreliable).
        private static func posturalSettling(_ b: inout Builder, metric: MetricKind, support: Interval,
                                             events: TransitionEventSummary?, config: EligibilityConfig) {
            guard let e = events else { return }
            b.depends(transitionEventsReadHeartRate)
            if opticalPulseMetrics.contains(metric) { b.gate(gateDecoderTransitionEvents) }
            b.diag("postural_transitions_settling", Double(e.postural))
            if e.postural > 0 {
                if (e.maxPosturalProbability ?? 0) >= config.posturalTransitionFailProbability {
                    b.fail(recentPosturalTransition)
                } else {
                    b.unknown(possiblePosturalTransition)
                }
            } else if Double(e.coveredS) < config.transitionCoverageFloorShare * Double(max(1, e.interval.duration)) {
                b.note(transitionEventsPartlyObserved)
            }
        }

        /// Stable awake rest: the HART lane's per-epoch wear-signal quality. A loose strap, motion artifact, sensor
        /// dropout or off-wrist epoch inside the support makes the optical contact undetermined.
        private static func wearSignalQuality(_ b: inout Builder, metric: MetricKind, support: Interval,
                                              wearSignal: WearSignalSummary?, config: EligibilityConfig) {
            guard let w = wearSignal else { return }
            b.depends(wearSignalReadsOpticalQuality)
            if opticalPulseMetrics.contains(metric) { b.gate(gateWearSignalOpticalQuality) }
            let share = Double(w.poorS) / Double(max(1, support.duration))
            b.diag("wear_signal_poor_share", share)
            if w.poorS > 0 && share > config.wearSignalPoorMaxShare { b.unknown(wearSignalPoor) }
        }

        /// The post-bout exclusion of one bout: the longest matching dose row, never below the floor.
        public static func postBoutExclusionS(_ bout: BoutRef, _ config: EligibilityConfig) -> Int {
            config.postBoutDoses
                .filter { ($0.kind == nil || $0.kind == bout.kind) && bout.durationS >= $0.minDurationS }
                .map(\.exclusionS).reduce(config.postBoutExclusionS, max)
        }

        private static func exertionEvidence(_ b: inout Builder, exertion: [ExertionWindowSummary],
                                             recentBouts: [BoutRef]) {
            // Counts and observed seconds per window live in the envelope's `history.exertion`; the verdict keeps
            // the locomotion totals it can be excluded on, and the nearest bout.
            if !recentBouts.isEmpty { b.diag("recent_bout_count", Double(recentBouts.count)) }
            if let last = recentBouts.min(by: { $0.secondsBeforeMeasurement < $1.secondsBeforeMeasurement }) {
                b.diag("seconds_since_last_bout", Double(last.secondsBeforeMeasurement))
            }
            for w in exertion.sorted(by: { $0.windowH < $1.windowH }) {
                b.diag("exertion_\(w.windowH)h_locomotion_s", Double(w.locomotionS))
            }
        }

        // MARK: Sleep measurement

        private static func sleepMeasurement(_ b: inout Builder, activity: ActivityComposition, usable: Bool,
                                             sleepWear: SleepWearContext) {
            switch sleepWear.sleepState {
            case .asleep: break
            case .awake: b.fail(notAsleep)
            case .mixed: b.fail(sleepWakeMixed)
            case .unknown: b.unknown(sleepEvidenceUnknown)
            }
            if sleepWear.sleepDependsOnHeartSignals { b.depends(sleepDetectorUsesHeartRate) }
            worn(&b, sleepWear, required: true)
        }

        // MARK: Activity response

        private static func activityResponse(_ b: inout Builder, activity: ActivityComposition, usable: Bool,
                                             sleepWear: SleepWearContext, recentBouts: [BoutRef],
                                             config: EligibilityConfig) {
            if sleepWear.sleepState == .asleep { b.fail(asleep) }
            worn(&b, sleepWear, required: false)
            let s = usable ? shares(activity) : Shares()
            if usable {
                b.diag("locomotion_share", s.locomotion)
                b.diag("qualified_coverage", s.qualified)
            }
            let follows = recentBouts.filter { $0.secondsBeforeMeasurement <= config.activityResponseWindowS }
                .min { $0.secondsBeforeMeasurement < $1.secondsBeforeMeasurement }
            if let f = follows { b.diag("seconds_since_last_bout", Double(f.secondsBeforeMeasurement)) }
            if usable && s.locomotion >= config.activityResponseMinLocomotionShare {
                b.positive(insideLocomotion)
            } else if follows != nil {
                b.positive(afterExertionBout)
            } else if !usable {
                b.unknown(activity.coveredS > 0 && !activity.heartRateDependent ? insufficientActivityCoverage
                                                                                : activityEvidenceUnavailable)
            } else if s.qualified < config.activityResponseMinCoverageShare {
                b.unknown(insufficientActivityCoverage)
            } else {
                b.fail(noSupportedExertion)
            }
        }

        // MARK: Selection accounting

        /// Selection accounting over the day's envelopes for each (comparison, metric) pair present.
        ///
        /// `dailyValues` are the day's System F values built from these envelopes; when nil they are rebuilt here
        /// with `reference` (`ContextReferences.dailyValues`), so the entered counts follow the same inclusion
        /// rules. An envelope "entered" a comparison when its id is a source of a daily value of that comparison's
        /// series (`*.stable_awake_*` for stable awake rest, the nightly series for sleep measurement).
        public static func selection(envelopes: [MeasurementEnvelope], observations: SanitizedObservations,
                                     dayWindow: Interval, dailyValues: [DailyValue]? = nil,
                                     reference: ReferenceConfig = .init()) -> [SelectionSummary] {
            struct Key: Hashable { let comparison: ComparisonKind; let metric: MetricKind }
            var groups: [Key: [(MeasurementEnvelope, EligibilityVerdict)]] = [:]
            for e in envelopes {
                for v in e.eligibility { groups[Key(comparison: v.comparison, metric: e.metric), default: []].append((e, v)) }
            }
            let entered = enteredEnvelopes(envelopes: envelopes, dayWindow: dayWindow, dailyValues: dailyValues,
                                           reference: reference)
            var observedCache: [String: [Int]] = [:]
            func observedSeconds(_ metric: MetricKind) -> [Int] {
                let key: String
                switch metric {
                case .heartRate, .restingHeartRate: key = "hr"
                case .hrvRmssd, .hrvSdnn, .respiratoryRate: key = "rr"
                case .skinTemperature: key = "skin"
                case .spo2Candidate: key = "none"
                }
                if let cached = observedCache[key] { return cached }
                let raw: [Int]
                switch key {
                case "hr": raw = observations.heartRate.map(\.ts)
                case "rr": raw = observations.beatIntervals.map(\.ts)
                case "skin": raw = observations.skinTemperature.map(\.ts)
                default: raw = []
                }
                var out: [Int] = []
                for t in raw.sorted() where dayWindow.contains(t) && out.last != t { out.append(t) }
                observedCache[key] = out
                return out
            }
            let keys = groups.keys.sorted { ($0.comparison.rawValue, $0.metric.rawValue) < ($1.comparison.rawValue, $1.metric.rawValue) }
            func observedInside(_ union: [Interval], _ observed: [Int]) -> Int {
                var inside = 0
                var u = 0
                for t in observed {
                    while u < union.count, union[u].end <= t { u += 1 }
                    if u < union.count, union[u].contains(t) { inside += 1 }
                }
                return inside
            }
            return keys.map { key in
                let items = groups[key]!
                var eligible = 0, ineligible = 0, unknown = 0, enteredCount = 0
                var reasonCounts: [ReasonCode: Int] = [:]
                var supports: [Interval] = []
                var enteredSupports: [Interval] = []
                for (e, v) in items {
                    switch v.state {
                    case .eligible:
                        eligible += 1
                        if let iv = e.support.intersection(dayWindow) { supports.append(iv) }
                        if entered[key.comparison]?.contains(e.id) ?? false {
                            enteredCount += 1
                            if let iv = e.support.intersection(dayWindow) { enteredSupports.append(iv) }
                        }
                    case .ineligible, .unknown:
                        if v.state == .ineligible { ineligible += 1 } else { unknown += 1 }
                        // Only the reasons that decided the verdict are exclusions; notes are recorded limits.
                        for r in v.decidingReasons { reasonCounts[r, default: 0] += 1 }
                    }
                }
                let union = SignalValidityEngine.mergeIntervals(supports)
                let enteredUnion = SignalValidityEngine.mergeIntervals(enteredSupports)
                let observed = observedSeconds(key.metric)
                let inside = observedInside(union, observed)
                let enteredInside = observedInside(enteredUnion, observed)
                let hasSeries = hasReferenceSeries(key.comparison, metric: key.metric, reference: reference)
                let top = reasonCounts.map { ReasonCount(reason: $0.key, count: $0.value) }
                    .sorted { ($1.count, $0.reason.rawValue) < ($0.count, $1.reason.rawValue) }
                    .prefix(topExclusionReasons)
                let share: (Int) -> Double? = { n in observed.isEmpty ? nil : Double(n) / Double(observed.count) }
                return SelectionSummary(comparison: key.comparison, metric: key.metric, eligible: eligible,
                                        ineligible: ineligible, unknown: unknown,
                                        eligibleSupportS: union.reduce(0) { $0 + $1.duration },
                                        observedS: observed.count,
                                        representedShare: hasSeries ? share(enteredInside) : nil,
                                        exclusionReasons: Array(top), eligibleObservedS: inside,
                                        eligibleShare: share(inside), enteredCount: hasSeries ? enteredCount : nil,
                                        enteredSupportS: enteredUnion.reduce(0) { $0 + $1.duration },
                                        enteredObservedS: enteredInside)
            }
        }

        /// Whether System F builds a reference series from envelopes of this comparison and metric.
        static func hasReferenceSeries(_ comparison: ComparisonKind, metric: MetricKind,
                                       reference: ReferenceConfig) -> Bool {
            switch comparison {
            case .stableAwakeRest:
                return reference.stableAwakeMetrics.contains(metric)
                    && ContextReferences.stableAwakeSeriesKey(metric: metric, config: reference) != nil
            case .sleepMeasurement:
                return reference.nightlyMetrics.contains(metric) && metric != .spo2Candidate
            case .activityResponse:
                return false
            }
        }

        /// Envelope ids that are sources of a daily value, per comparison.
        static func enteredEnvelopes(envelopes: [MeasurementEnvelope], dayWindow: Interval,
                                     dailyValues: [DailyValue]?,
                                     reference: ReferenceConfig) -> [ComparisonKind: Set<String>] {
            let values = dailyValues ?? ContextReferences.dailyValues(
                envelopes: envelopes,
                identity: DayIdentity(deviceScope: "", day: "", timezoneId: "UTC", dayWindow: dayWindow),
                mode: .retrospective, finality: .provisional, config: reference)
            var byId: [String: MeasurementEnvelope] = [:]
            for e in envelopes { byId[e.id] = e }
            var out: [ComparisonKind: Set<String>] = [:]
            for v in values {
                for id in v.sourceIds {
                    guard let e = byId[id] else { continue }
                    if let key = ContextReferences.stableAwakeSeriesKey(metric: e.metric, config: reference),
                       v.seriesKey == key || v.seriesKey.hasPrefix(key + ".") {
                        out[.stableAwakeRest, default: []].insert(id)
                    } else if let key = ContextReferences.nightlySeriesKey(metric: e.metric, method: e.method),
                              v.seriesKey == key {
                        out[.sleepMeasurement, default: []].insert(id)
                    }
                }
            }
            return out
        }
    }
}
