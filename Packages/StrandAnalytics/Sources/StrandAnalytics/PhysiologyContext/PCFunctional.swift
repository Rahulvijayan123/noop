import Foundation

// PCFunctional.swift — System G: functional behaviour features and the versioned feature registry (spec §13).
//
// OWNER: responses & function workstream. SKELETON — signatures are the shared contract.
//
// Observable behaviour is a product of its own, kept beside context-matched physiology; it is not adjusted away as a
// confounder. Lower captured activity under lower wear coverage is missingness, not decline.

extension PhysiologyContext {

    public struct FunctionalConfig: Codable, Equatable, Sendable {
        public var version = "pc-functional-1"
        public init() {}
    }

    /// The day's general functional features.
    public struct FunctionalDaySummary: Codable, Equatable, Sendable {
        public var day: String
        /// Seconds of the day with wear evidence, and the evidence basis.
        public var observedWearS: Int?
        public var wearBasis: String
        public var dayS: Int
        /// True when wear coverage is sufficient for day totals to be compared across days.
        public var totalsComparable: Bool
        public var reasons: [ReasonCode]
        public init(day: String, observedWearS: Int?, wearBasis: String, dayS: Int, totalsComparable: Bool,
                    reasons: [ReasonCode]) {
            self.day = day; self.observedWearS = observedWearS; self.wearBasis = wearBasis; self.dayS = dayS
            self.totalsComparable = totalsComparable; self.reasons = reasons
        }
        public static func unavailable(day: String, dayS: Int, reasons: [ReasonCode]) -> FunctionalDaySummary {
            FunctionalDaySummary(day: day, observedWearS: nil, wearBasis: "none", dayS: dayS,
                                 totalsComparable: false, reasons: reasons)
        }
    }

    public enum Functional {

        public static let reasonCodes: [ReasonCode] = []

        public static func daySummary(identity: DayIdentity, bouts: [ExertionBout], hart: ResolvedTrack,
                                      strap: ResolvedTrack, observations: SanitizedObservations,
                                      sleep: SleepRhythmSummary, mode: ProcessingMode, cutoff: Int,
                                      config: FunctionalConfig) -> FunctionalDaySummary {
            .unavailable(day: identity.day, dayS: identity.dayWindow.duration, reasons: ["not_implemented"])
        }

        /// Daily values contributed by the functional product (only when `totalsComparable` or wear-normalized).
        public static func dailyValues(_ summary: FunctionalDaySummary, regimeKey: String, mode: ProcessingMode,
                                       finality: Finality, config: FunctionalConfig) -> [DailyValue] {
            []
        }
    }

    // MARK: - Feature registry

    public enum FeatureValidationStatus: String, Codable, CaseIterable, Sendable {
        /// Arithmetic / integration verified only; no accuracy or clinical validation.
        case technicalVerificationOnly = "technical_verification_only"
        /// Defined but not computable without inputs or labels that do not exist yet.
        case notValidated = "not_validated"
    }

    /// A versioned feature definition. Specialized (disease-specific) definitions declare their requirements and
    /// stay unavailable until those inputs and independent labels exist; no coefficients are invented.
    public struct FeatureDefinition: Codable, Equatable, Sendable {
        public var id: String
        public var version: Int
        /// `general` | `specialized`.
        public var tier: String
        public var requiredSensors: [String]
        public var requiredPlacement: [String]
        public var requiredLabels: [String]
        public var referenceAssessments: [String]
        public var timing: String
        public var intendedPopulation: String
        public var units: String
        public var validationStatus: FeatureValidationStatus
        public init(id: String, version: Int, tier: String, requiredSensors: [String], requiredPlacement: [String],
                    requiredLabels: [String], referenceAssessments: [String], timing: String,
                    intendedPopulation: String, units: String, validationStatus: FeatureValidationStatus) {
            self.id = id; self.version = version; self.tier = tier; self.requiredSensors = requiredSensors
            self.requiredPlacement = requiredPlacement; self.requiredLabels = requiredLabels
            self.referenceAssessments = referenceAssessments; self.timing = timing
            self.intendedPopulation = intendedPopulation; self.units = units
            self.validationStatus = validationStatus
        }
    }

    public struct FeatureEvaluation: Codable, Equatable, Sendable {
        public var featureId: String
        public var version: Int
        /// `computed` | `unavailable`.
        public var state: String
        public var value: Double?
        public var units: String
        /// What is missing when unavailable (sensor, placement, label, reference assessment).
        public var missing: [ReasonCode]
        public var validationStatus: FeatureValidationStatus
        public init(featureId: String, version: Int, state: String, value: Double?, units: String,
                    missing: [ReasonCode], validationStatus: FeatureValidationStatus) {
            self.featureId = featureId; self.version = version; self.state = state; self.value = value
            self.units = units; self.missing = missing; self.validationStatus = validationStatus
        }
    }

    public enum FeatureRegistry {
        public static let version = "pc-features-1"
        public static let definitions: [FeatureDefinition] = []

        /// Evaluate every registered definition against what the day actually has.
        public static func evaluate(functional: FunctionalDaySummary, regimes: RegimeTimeline,
                                    availability: [AvailabilityEntry]) -> [FeatureEvaluation] {
            []
        }
    }
}
