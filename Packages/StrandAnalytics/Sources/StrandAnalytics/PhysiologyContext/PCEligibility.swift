import Foundation

// PCEligibility.swift — System B: physiological measurement eligibility (spec §8).
//
// OWNER: signal & eligibility workstream. Behaviour, defaults and reason codes: docs/physiology-context/notes/signal.md.
//
// Behavioural eligibility never requires a favourable value of the metric being studied: no gate reads the
// measurement's value (V03). The one gate that reads the target's own signal — signal validity — is declared in
// `EligibilityVerdict.targetDependentGates` so its selection effect can be reviewed.
//
// Tri-state logic: every check is evaluated and contributes `fail` (determined and failed → ineligible), `unknown`
// (could not be determined) or nothing. Any fail ⇒ ineligible; else any unknown ⇒ unknown; else eligible. All
// reasons are kept, so an ineligible verdict also lists what was unknown. Quiet motion is never evidence of being
// awake, worn or rested: those come only from `SleepWearContext` (System C), and unknown stays unknown (V02).
// Wrist posture is never used: arm orientation is a likelihood, not a confirmed standing or orthostatic event.

extension PhysiologyContext {

    public struct EligibilityConfig: Codable, Equatable, Sendable {
        public var version = "pc-eligibility-1"
        public var motion = MotionEvidenceConfig()
        /// Stable awake rest: stationary share of the WHOLE support (ActivityContextJoin.restingStationaryFloor).
        public var stationaryFloorShare = 0.90
        /// Stable awake rest: qualified (labelled) coverage of the whole support (restingCoverageFloor).
        public var qualifiedCoverageFloorShare = 0.90
        /// Stable awake rest: continuous stillness ending at the support start (ActivityPolicyConfig.minStillnessS).
        public var minPrecedingStillS = 300
        /// Stable awake rest: locomotion that ended less than this before the support excludes it
        /// (ActivityPolicyConfig.postActivityWindowS).
        public var postActivityWindowS = 600
        /// Stable awake rest: a supported bout that ended less than this before the support excludes it (0 disables).
        public var postBoutExclusionS = 600
        /// Stable awake rest: optional exclusion when the trailing 24 h locomotion exceeds this (nil = record only).
        public var maxLocomotion24hS: Int? = nil
        /// Activity response: a support starting within this many seconds after a bout ended follows that bout.
        public var activityResponseWindowS = 900
        /// Activity response: locomotion share of the whole support that counts as inside the activity.
        public var activityResponseMinLocomotionShare = 0.50
        /// Activity response: labelled coverage below which "no activity" cannot be asserted.
        public var activityResponseMinCoverageShare = 0.50
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
        public var reasons: [ReasonCode]
        public var evidence: [Diagnostic]
        /// Gates that read the target metric's own signal (declared for selection-bias review).
        public var targetDependentGates: [ReasonCode]
        /// Evidence sources that depend on heart-derived signals (e.g. `sleep_detector_uses_heart_rate`).
        public var dependsOn: [String]
        public var policyVersion: String

        public init(comparison: ComparisonKind, state: EligibilityState, reasons: [ReasonCode],
                    evidence: [Diagnostic] = [], targetDependentGates: [ReasonCode] = [], dependsOn: [String] = [],
                    policyVersion: String) {
            self.comparison = comparison; self.state = state; self.reasons = reasons; self.evidence = evidence
            self.targetDependentGates = targetDependentGates; self.dependsOn = dependsOn
            self.policyVersion = policyVersion
        }

        public func evidence(_ name: String) -> Double? { evidence.first { $0.name == name }?.value }
    }

    public struct ReasonCount: Codable, Equatable, Sendable {
        public var reason: ReasonCode
        public var count: Int
        public init(reason: ReasonCode, count: Int) { self.reason = reason; self.count = count }
    }

    /// Context-selection accounting for one comparison and metric over the day (spec §14 last bullet).
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
        /// `eligibleObservedS / observedS`: the share of the day's observed time that eligible measurements
        /// represent (nil when nothing was observed). Never above 1.
        public var representedShare: Double?
        /// Ineligible + unknown reason counts, most frequent first (top `Eligibility.topExclusionReasons`).
        public var exclusionReasons: [ReasonCount]
        /// Observed seconds inside the union of eligible supports.
        public var eligibleObservedS: Int = 0

        public init(comparison: ComparisonKind, metric: MetricKind, eligible: Int, ineligible: Int, unknown: Int,
                    eligibleSupportS: Int, observedS: Int, representedShare: Double?,
                    exclusionReasons: [ReasonCount], eligibleObservedS: Int = 0) {
            self.comparison = comparison; self.metric = metric; self.eligible = eligible
            self.ineligible = ineligible; self.unknown = unknown; self.eligibleSupportS = eligibleSupportS
            self.observedS = observedS; self.representedShare = representedShare
            self.exclusionReasons = exclusionReasons; self.eligibleObservedS = eligibleObservedS
        }
    }

    public enum Eligibility {

        public static let version = "pc-eligibility-1"
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
        // MARK: Reason codes — sleep measurement / activity response
        public static let notAsleep: ReasonCode = "not_asleep"
        public static let sleepEvidenceUnknown: ReasonCode = "sleep_evidence_unknown"
        public static let noSupportedExertion: ReasonCode = "no_supported_exertion"

        public static let reasonCodes: [ReasonCode] = [
            stableAwakeLowMovement, insideSupportedSleep, insideLocomotion, afterExertionBout, invalidInterval,
            signalInvalid, signalDegraded, signalValidityMissing, signalUnverified, signalUnsupported,
            heartRateDependentActivityIgnored, activityEvidenceUnavailable, insufficientActivityCoverage, asleep,
            sleepWakeMixed, awakeEvidenceUnknown, notWorn, wearMixed, wearEvidenceUnknown, movementInSupport,
            insufficientStationary, insufficientPrecedingStillness, precedingStillnessUnobserved, recentLocomotion,
            recentLocomotionUnobserved, recentExertionBout, exertionHistoryExceedsLimit, notAsleep,
            sleepEvidenceUnknown, noSupportedExertion,
        ]

        // MARK: Dependence labels (`EligibilityVerdict.dependsOn`)
        public static let sleepDetectorUsesHeartRate = "sleep_detector_uses_heart_rate"
        public static let wearFromHeartRateSignal = "wear_from_heart_rate_signal"
        public static let activityLabelsReadHeartRate = "activity_labels_read_heart_rate"

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

        /// Accumulates checks for one verdict.
        private struct Builder {
            var failed = false
            var undetermined = false
            var reasons: [ReasonCode] = []
            var evidence: [Diagnostic] = []
            var dependsOn: [String] = []
            mutating func fail(_ r: ReasonCode) { failed = true; add(r) }
            mutating func unknown(_ r: ReasonCode) { undetermined = true; add(r) }
            mutating func note(_ r: ReasonCode) { add(r) }
            mutating func add(_ r: ReasonCode) { if !reasons.contains(r) { reasons.append(r) } }
            mutating func depends(_ s: String) { if !dependsOn.contains(s) { dependsOn.append(s) } }
            /// Evidence is rounded to 1e-4 for the document (decisions use the unrounded values).
            mutating func diag(_ name: String, _ value: Double?) {
                if let v = value, v.isFinite { evidence.append(Diagnostic(name, (v * 10_000).rounded() / 10_000)) }
            }
            var state: EligibilityState { failed ? .ineligible : (undetermined ? .unknown : .eligible) }
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
        public static func evaluate(_ kind: ComparisonKind, metric: MetricKind, support: Interval,
                                    validity: SignalValidity, activity: ActivityComposition,
                                    preceding: PrecedingHistory, sleepWear: SleepWearContext,
                                    exertion: [ExertionWindowSummary], recentBouts: [BoutRef],
                                    config: EligibilityConfig) -> EligibilityVerdict {
            var b = Builder()
            guard support.isValid else {
                b.unknown(invalidInterval)
                return finish(kind, b, config)
            }
            // The target-dependent quality gate (reads the measurement's own signal, never its value).
            switch validity.state {
            case .valid: break
            case .degraded: b.note(signalDegraded)
            case .invalid: b.fail(signalInvalid)
            case .missing: b.unknown(signalValidityMissing)
            case .unverified: b.fail(signalUnverified)
            case .unsupported: b.unknown(signalUnsupported)
            }
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
            case .sleepMeasurement:
                sleepMeasurement(&b, activity: activity, usable: activityUsable, sleepWear: sleepWear)
            case .activityResponse:
                activityResponse(&b, activity: activity, usable: activityUsable, sleepWear: sleepWear,
                                 recentBouts: recentBouts, config: config)
            }
            return finish(kind, b, config)
        }

        private static func finish(_ kind: ComparisonKind, _ b: Builder, _ config: EligibilityConfig) -> EligibilityVerdict {
            var reasons = b.reasons
            if b.state == .eligible {
                switch kind {
                case .stableAwakeRest: reasons.insert(stableAwakeLowMovement, at: 0)
                case .sleepMeasurement: reasons.insert(insideSupportedSleep, at: 0)
                case .activityResponse: break  // the positive reason was added by the check that passed
                }
            }
            return EligibilityVerdict(comparison: kind, state: b.state, reasons: reasons, evidence: b.evidence,
                                      targetDependentGates: [signalInvalid], dependsOn: b.dependsOn,
                                      policyVersion: config.version)
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
            if config.postBoutExclusionS > 0,
               let last = recentBouts.min(by: { $0.secondsBeforeMeasurement < $1.secondsBeforeMeasurement }),
               last.secondsBeforeMeasurement < config.postBoutExclusionS {
                b.fail(recentExertionBout)
            }
            if let limit = config.maxLocomotion24hS, let w = exertion.first(where: { $0.windowH == 24 }),
               w.locomotionS > limit {
                b.fail(exertionHistoryExceedsLimit)
            }
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
                b.note(insideLocomotion)
            } else if follows != nil {
                b.note(afterExertionBout)
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
        public static func selection(envelopes: [MeasurementEnvelope], observations: SanitizedObservations,
                                     dayWindow: Interval) -> [SelectionSummary] {
            struct Key: Hashable { let comparison: ComparisonKind; let metric: MetricKind }
            var groups: [Key: [(MeasurementEnvelope, EligibilityVerdict)]] = [:]
            for e in envelopes {
                for v in e.eligibility { groups[Key(comparison: v.comparison, metric: e.metric), default: []].append((e, v)) }
            }
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
            return keys.map { key in
                let items = groups[key]!
                var eligible = 0, ineligible = 0, unknown = 0
                var reasonCounts: [ReasonCode: Int] = [:]
                var supports: [Interval] = []
                for (e, v) in items {
                    switch v.state {
                    case .eligible:
                        eligible += 1
                        if let iv = e.support.intersection(dayWindow) { supports.append(iv) }
                    case .ineligible, .unknown:
                        if v.state == .ineligible { ineligible += 1 } else { unknown += 1 }
                        for r in v.reasons { reasonCounts[r, default: 0] += 1 }
                    }
                }
                let union = SignalValidityEngine.mergeIntervals(supports)
                let eligibleS = union.reduce(0) { $0 + $1.duration }
                let observed = observedSeconds(key.metric)
                var inside = 0
                var u = 0
                for t in observed {
                    while u < union.count, union[u].end <= t { u += 1 }
                    if u < union.count, union[u].contains(t) { inside += 1 }
                }
                let top = reasonCounts.map { ReasonCount(reason: $0.key, count: $0.value) }
                    .sorted { ($1.count, $0.reason.rawValue) < ($0.count, $1.reason.rawValue) }
                    .prefix(topExclusionReasons)
                return SelectionSummary(comparison: key.comparison, metric: key.metric, eligible: eligible,
                                        ineligible: ineligible, unknown: unknown, eligibleSupportS: eligibleS,
                                        observedS: observed.count,
                                        representedShare: observed.isEmpty ? nil
                                            : Double(inside) / Double(observed.count),
                                        exclusionReasons: Array(top), eligibleObservedS: inside)
            }
        }
    }
}
