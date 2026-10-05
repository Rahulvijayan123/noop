import Foundation

// PCSignalValidity.swift — System A: signal validity and measurement regime (spec §7).
//
// OWNER: signal & eligibility workstream. SKELETON — signatures are the shared contract; bodies are placeholders
// that return explicit unavailable states until the workstream implements them.

extension PhysiologyContext {

    public struct ValidityConfig: Codable, Equatable, Sendable {
        public var version = "pc-validity-1"
        public init() {}
    }

    /// Metric-specific signal validity. Valid HR does not establish valid HRV or respiration.
    public enum ValidityState: String, Codable, CaseIterable, Sendable {
        /// Passed the metric's signal-quality gates.
        case valid
        /// Usable with stated limitations (reasons say which).
        case degraded
        /// Failed a signal-quality gate (reasons say which). The observation is preserved for audit.
        case invalid
        /// No observations in the support interval.
        case missing
        /// The measurement exists but its validity is not established (the strap SpO2 candidate).
        case unverified
        /// No qualified input exists for this assessment (e.g. PPG waveform quality without a waveform).
        case unsupported
    }

    public struct SignalValidity: Codable, Equatable, Sendable {
        public var state: ValidityState
        public var reasons: [ReasonCode]
        /// Observed share of the support interval for the metric's input stream, when defined.
        public var coverage: Double?
        public var observedS: Int?
        public var diagnostics: [Diagnostic]
        public var confidence: Confidence

        public init(state: ValidityState, reasons: [ReasonCode], coverage: Double? = nil, observedS: Int? = nil,
                    diagnostics: [Diagnostic] = [], confidence: Confidence = .notApplicable) {
            self.state = state; self.reasons = reasons; self.coverage = coverage; self.observedS = observedS
            self.diagnostics = diagnostics; self.confidence = confidence
        }

        public static func missing(_ reasons: [ReasonCode] = []) -> SignalValidity {
            SignalValidity(state: .missing, reasons: reasons)
        }
    }

    /// The conditions a measurement was collected under (spec §7). Two values are pooled into one baseline only
    /// when their regimes are comparable under a documented rule.
    public struct MeasurementRegime: Codable, Equatable, Hashable, Sendable {
        /// Canonical key (FNV-1a of the comparable attributes); equal keys are comparable by construction.
        public var key: String
        public var vendor: String
        public var deviceFamily: String?
        public var sourceKind: String?
        public var firmware: String?
        /// `wrist` | `bicep` | `other` | `unknown` — never back-filled from today's placement.
        public var placement: String
        /// `user` | `device` | `none`.
        public var placementSource: String
        public var methodId: String
        public var algorithmVersion: String
        public var aggregation: Aggregation
        public var windowS: Int
        public var units: String
        public var decoderVersion: String?

        public init(key: String, vendor: String, deviceFamily: String?, sourceKind: String?, firmware: String?,
                    placement: String, placementSource: String, methodId: String, algorithmVersion: String,
                    aggregation: Aggregation, windowS: Int, units: String, decoderVersion: String?) {
            self.key = key; self.vendor = vendor; self.deviceFamily = deviceFamily; self.sourceKind = sourceKind
            self.firmware = firmware; self.placement = placement; self.placementSource = placementSource
            self.methodId = methodId; self.algorithmVersion = algorithmVersion; self.aggregation = aggregation
            self.windowS = windowS; self.units = units; self.decoderVersion = decoderVersion
        }
    }

    /// A known boundary between measurement regimes (placement / device / firmware / method / source change).
    public struct RegimeBoundary: Codable, Equatable, Sendable {
        public var at: Int
        /// `placement` | `device` | `firmware` | `method` | `source` | `placement_history_start`.
        public var kind: String
        public var fromValue: String?
        public var toValue: String?
        public var reasons: [ReasonCode]
        public init(at: Int, kind: String, fromValue: String?, toValue: String?, reasons: [ReasonCode] = []) {
            self.at = at; self.kind = kind; self.fromValue = fromValue; self.toValue = toValue; self.reasons = reasons
        }
    }

    /// Effective placement over an interval of the read window.
    public struct PlacementSegment: Codable, Equatable, Sendable {
        public var interval: Interval
        public var placement: String
        public var placementSource: String
        public init(interval: Interval, placement: String, placementSource: String) {
            self.interval = interval; self.placement = placement; self.placementSource = placementSource
        }
    }

    public struct RegimeTimeline: Codable, Equatable, Sendable {
        public var placements: [PlacementSegment]
        public var boundaries: [RegimeBoundary]
        /// Every regime referenced by an envelope or daily value in the document.
        public var registry: [MeasurementRegime]
        public init(placements: [PlacementSegment], boundaries: [RegimeBoundary], registry: [MeasurementRegime]) {
            self.placements = placements; self.boundaries = boundaries; self.registry = registry
        }
        public static let empty = RegimeTimeline(placements: [], boundaries: [], registry: [])
    }

    public enum RegimeComparability: Codable, Equatable, Sendable {
        case comparable(rule: String)
        case incompatible(reasons: [ReasonCode])
    }

    public enum AvailabilityState: String, Codable, CaseIterable, Sendable {
        case supported, partial, unavailable, unverified, unsupported
    }

    /// One row of the availability / comparability matrix (spec §7): an assessment for a metric from a source.
    public struct AvailabilityEntry: Codable, Equatable, Sendable {
        public var metric: MetricKind?
        /// e.g. `hrv_signal_validity`, `ppg_waveform_quality`, `stable_awake_eligibility`.
        public var assessment: String
        public var source: String
        public var state: AvailabilityState
        /// The comparability rule applied across regimes for this metric/source.
        public var comparability: String
        public var reasons: [ReasonCode]
        public init(metric: MetricKind?, assessment: String, source: String, state: AvailabilityState,
                    comparability: String, reasons: [ReasonCode]) {
            self.metric = metric; self.assessment = assessment; self.source = source; self.state = state
            self.comparability = comparability; self.reasons = reasons
        }
    }

    /// Input-contract findings, produced before any statistics (spec §7 last bullet, V05).
    public struct InputContractReport: Codable, Equatable, Sendable {
        public var reasons: [ReasonCode]
        public var counts: [Diagnostic]
        /// `ingested_at` when every observation carried an availability time, else `sensor_time`.
        public var availabilityBasis: String
        public init(reasons: [ReasonCode], counts: [Diagnostic], availabilityBasis: String) {
            self.reasons = reasons; self.counts = counts; self.availabilityBasis = availabilityBasis
        }
        public static let empty = InputContractReport(reasons: [], counts: [], availabilityBasis: "sensor_time")
    }

    /// Observations after identity de-duplication, contract checks and causal availability filtering.
    public struct SanitizedObservations: Equatable, Sendable {
        public var heartRate: [HeartRateObservation]
        public var beatIntervals: [BeatIntervalObservation]
        public var motion: [MotionObservation]
        public var steps: [StepObservation]
        public var skinTemperature: [SkinTemperatureObservation]
        public var wearEvents: [WearEventObservation]
        public var bandSleepStates: [BandSleepStateObservation]
        /// Intervals that must not be bridged (disconnections, clock resets, source changes).
        public var breaks: [Interval]
        public init(heartRate: [HeartRateObservation] = [], beatIntervals: [BeatIntervalObservation] = [],
                    motion: [MotionObservation] = [], steps: [StepObservation] = [],
                    skinTemperature: [SkinTemperatureObservation] = [], wearEvents: [WearEventObservation] = [],
                    bandSleepStates: [BandSleepStateObservation] = [], breaks: [Interval] = []) {
            self.heartRate = heartRate; self.beatIntervals = beatIntervals; self.motion = motion
            self.steps = steps; self.skinTemperature = skinTemperature; self.wearEvents = wearEvents
            self.bandSleepStates = bandSleepStates; self.breaks = breaks
        }
    }

    public enum SignalValidityEngine {

        public static let reasonCodes: [ReasonCode] = []

        /// Identity de-duplication (never by value alone), timestamp / unit / source-contract checks and causal
        /// availability filtering. Rejected observations are counted in the report, never silently dropped.
        public static func sanitize(_ input: DayInput, config: ValidityConfig) -> (SanitizedObservations, InputContractReport) {
            (SanitizedObservations(heartRate: input.heartRate, beatIntervals: input.beatIntervals,
                                   motion: input.motion, steps: input.steps,
                                   skinTemperature: input.skinTemperature, wearEvents: input.wearEvents,
                                   bandSleepStates: input.bandSleepStates),
             .empty)
        }

        /// Metric-specific validity of one measurement over its support interval.
        public static func assess(_ measurement: MeasurementInput, observations: SanitizedObservations,
                                  motion: ResolvedTrack, config: ValidityConfig) -> SignalValidity {
            .missing(["not_implemented"])
        }

        /// Placement segments (unknown before the first record; never back-filled) and regime boundaries.
        public static func regimeTimeline(_ input: DayInput, config: ValidityConfig) -> RegimeTimeline {
            .empty
        }

        /// The regime of one measurement (placement at its support start).
        public static func regime(for measurement: MeasurementInput, timeline: RegimeTimeline,
                                  device: DeviceRegimeInput) -> MeasurementRegime {
            MeasurementRegime(key: "unknown", vendor: device.vendor, deviceFamily: device.deviceFamily,
                              sourceKind: device.sourceKind, firmware: device.firmware, placement: "unknown",
                              placementSource: "none", methodId: measurement.method.id,
                              algorithmVersion: measurement.method.algorithmVersion,
                              aggregation: measurement.method.aggregation, windowS: measurement.method.windowS,
                              units: measurement.method.units, decoderVersion: device.decoderVersion)
        }

        /// Whether two regimes may be pooled into one reference, and under which documented rule.
        public static func comparability(_ a: MeasurementRegime, _ b: MeasurementRegime,
                                         config: ValidityConfig) -> RegimeComparability {
            a.key == b.key ? .comparable(rule: "identical_regime") : .incompatible(reasons: ["regime_differs"])
        }

        /// The availability / comparability matrix for every metric and source in the input.
        public static func availabilityMatrix(_ input: DayInput, observations: SanitizedObservations,
                                              config: ValidityConfig) -> [AvailabilityEntry] {
            []
        }
    }
}
