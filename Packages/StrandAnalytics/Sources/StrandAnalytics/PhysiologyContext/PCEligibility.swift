import Foundation

// PCEligibility.swift — System B: physiological measurement eligibility (spec §8).
//
// OWNER: signal & eligibility workstream. SKELETON — signatures are the shared contract.
//
// Behavioural eligibility never requires a favourable value of the metric being studied. Any target-dependent
// signal-quality gate is declared in `EligibilityVerdict.targetDependentGates`.

extension PhysiologyContext {

    public struct EligibilityConfig: Codable, Equatable, Sendable {
        public var version = "pc-eligibility-1"
        public var motion = MotionEvidenceConfig()
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

    public struct EligibilityVerdict: Codable, Equatable, Sendable {
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
        public var eligibleSupportS: Int
        /// Seconds of the day with any observation of the metric's input stream.
        public var observedS: Int
        /// `eligibleSupportS / observedS` (nil when nothing was observed).
        public var representedShare: Double?
        public var exclusionReasons: [ReasonCount]
        public init(comparison: ComparisonKind, metric: MetricKind, eligible: Int, ineligible: Int, unknown: Int,
                    eligibleSupportS: Int, observedS: Int, representedShare: Double?,
                    exclusionReasons: [ReasonCount]) {
            self.comparison = comparison; self.metric = metric; self.eligible = eligible
            self.ineligible = ineligible; self.unknown = unknown; self.eligibleSupportS = eligibleSupportS
            self.observedS = observedS; self.representedShare = representedShare
            self.exclusionReasons = exclusionReasons
        }
    }

    public enum Eligibility {

        public static let reasonCodes: [ReasonCode] = []

        /// The comparisons that apply to a metric/method (e.g. stable awake rest does not apply to a nightly value).
        public static func comparisons(for metric: MetricKind, method: MethodRef) -> [ComparisonKind] {
            []
        }

        /// Evaluate one comparison for one measurement.
        public static func evaluate(_ kind: ComparisonKind, metric: MetricKind, support: Interval,
                                    validity: SignalValidity, activity: ActivityComposition,
                                    preceding: PrecedingHistory, sleepWear: SleepWearContext,
                                    exertion: [ExertionWindowSummary], recentBouts: [BoutRef],
                                    config: EligibilityConfig) -> EligibilityVerdict {
            EligibilityVerdict(comparison: kind, state: .unknown, reasons: ["not_implemented"],
                               policyVersion: config.version)
        }

        /// Selection accounting over the day's envelopes for each (comparison, metric) pair present.
        public static func selection(envelopes: [MeasurementEnvelope], observations: SanitizedObservations,
                                     dayWindow: Interval) -> [SelectionSummary] {
            []
        }
    }
}
