import Foundation

// PCReferences.swift — System F (part 1): daily context-conditioned values and reference views (spec §12.1-12.2).
//
// OWNER: statistics workstream. SKELETON — signatures are the shared contract.
//
// Every comparison scores an observation against references built ONLY from earlier days, before the observation
// can enter any adaptive reference. Frozen references are explicitly versioned and never silently replaced. A
// robust z is a distance in robust-scale units, not a probability.

extension PhysiologyContext {

    public struct ReferenceConfig: Codable, Equatable, Sendable {
        public var version = "pc-reference-1"
        public init() {}
    }

    /// One day's context-conditioned value of one series (the unit references and episodes are built from).
    public struct DailyValue: Codable, Equatable, Sendable {
        public var day: String
        /// Series identity, e.g. `hrv_rmssd.sleep_night`, `hrv_rmssd.stable_awake_5min`,
        /// `functional.locomotion_s_per_worn_hour`. Defines the context condition.
        public var seriesKey: String
        public var regimeKey: String
        public var metric: MetricKind?
        /// Value in original units.
        public var value: Double
        public var units: String
        /// Independent support units behind the value (windows, bouts or nights) and their kind.
        public var supportCount: Int
        public var supportUnit: String
        public var supportS: Int
        public var mode: ProcessingMode
        public var finality: Finality
        /// Envelopes (or bouts) the value was aggregated from.
        public var sourceIds: [String]
        public var reasons: [ReasonCode]
        public init(day: String, seriesKey: String, regimeKey: String, metric: MetricKind?, value: Double,
                    units: String, supportCount: Int, supportUnit: String, supportS: Int, mode: ProcessingMode,
                    finality: Finality, sourceIds: [String] = [], reasons: [ReasonCode] = []) {
            self.day = day; self.seriesKey = seriesKey; self.regimeKey = regimeKey; self.metric = metric
            self.value = value; self.units = units; self.supportCount = supportCount
            self.supportUnit = supportUnit; self.supportS = supportS; self.mode = mode; self.finality = finality
            self.sourceIds = sourceIds; self.reasons = reasons
        }
    }

    public enum ReferenceView: String, Codable, CaseIterable, Sendable {
        case recent, rolling, frozen, conditioned
    }

    public enum ReferenceStatus: String, Codable, CaseIterable, Sendable {
        case ready, provisional, insufficient, unavailable
        case regimeMismatch = "regime_mismatch"
    }

    /// An explicitly versioned historical reference. It is a historical reference, not a healthy baseline.
    public struct FrozenReference: Codable, Equatable, Sendable {
        public var id: String
        public var seriesKey: String
        public var regimeKey: String
        public var version: Int
        public var fromDay: String
        public var toDay: String
        public var supportDays: Int
        public var center: Double
        public var scale: Double
        /// `identity` | `ln`.
        public var transform: String
        /// How the reference interval was selected (recorded verbatim, e.g. `first_14_supported_days_in_regime`).
        public var selectionRule: String
        public var createdForDay: String
        public var policyFingerprint: String
        public init(id: String, seriesKey: String, regimeKey: String, version: Int, fromDay: String, toDay: String,
                    supportDays: Int, center: Double, scale: Double, transform: String, selectionRule: String,
                    createdForDay: String, policyFingerprint: String) {
            self.id = id; self.seriesKey = seriesKey; self.regimeKey = regimeKey; self.version = version
            self.fromDay = fromDay; self.toDay = toDay; self.supportDays = supportDays; self.center = center
            self.scale = scale; self.transform = transform; self.selectionRule = selectionRule
            self.createdForDay = createdForDay; self.policyFingerprint = policyFingerprint
        }
    }

    /// One observation compared with one reference view.
    public struct ReferenceComparison: Codable, Equatable, Sendable {
        public var day: String
        public var seriesKey: String
        public var regimeKey: String
        public var view: ReferenceView
        public var referenceId: String?
        public var status: ReferenceStatus
        public var supportDays: Int
        public var fromDay: String?
        public var toDay: String?
        public var value: Double
        public var center: Double?
        public var scale: Double?
        public var scaleFloored: Bool
        /// `value - center` in original units.
        public var signedDifference: Double?
        /// Difference on the transformed scale (e.g. ln ratio for RMSSD), when a transform applies.
        public var transformedDifference: Double?
        /// Robust distance in scale units; never a probability.
        public var robustZ: Double?
        /// Uncertainty of the reference center (same units as `center`), when estimable.
        public var centerUncertainty: Double?
        public var transform: String
        /// Share of the reference contributed by a parent / population level (0 when purely personal).
        public var pooledContribution: Double
        public var reasons: [ReasonCode]
        public init(day: String, seriesKey: String, regimeKey: String, view: ReferenceView, referenceId: String?,
                    status: ReferenceStatus, supportDays: Int, fromDay: String?, toDay: String?, value: Double,
                    center: Double?, scale: Double?, scaleFloored: Bool, signedDifference: Double?,
                    transformedDifference: Double?, robustZ: Double?, centerUncertainty: Double?, transform: String,
                    pooledContribution: Double, reasons: [ReasonCode]) {
            self.day = day; self.seriesKey = seriesKey; self.regimeKey = regimeKey; self.view = view
            self.referenceId = referenceId; self.status = status; self.supportDays = supportDays
            self.fromDay = fromDay; self.toDay = toDay; self.value = value; self.center = center
            self.scale = scale; self.scaleFloored = scaleFloored; self.signedDifference = signedDifference
            self.transformedDifference = transformedDifference; self.robustZ = robustZ
            self.centerUncertainty = centerUncertainty; self.transform = transform
            self.pooledContribution = pooledContribution; self.reasons = reasons
        }
    }

    public enum ContextReferences {

        public static let reasonCodes: [ReasonCode] = []

        /// Daily context-conditioned values from the day's envelopes (nightly products and eligible windows).
        public static func dailyValues(envelopes: [MeasurementEnvelope], identity: DayIdentity, mode: ProcessingMode,
                                       finality: Finality, config: ReferenceConfig) -> [DailyValue] {
            []
        }

        /// Compare today's values with recent / rolling / frozen / conditioned references built from `history`
        /// (strictly earlier days). Returns the comparisons and any frozen reference this run registers.
        public static func compare(_ values: [DailyValue], history: [DailyValue], frozen: [FrozenReference],
                                   day: String, policyFingerprint: String,
                                   config: ReferenceConfig) -> (comparisons: [ReferenceComparison],
                                                                newFrozen: [FrozenReference]) {
            ([], [])
        }
    }
}
