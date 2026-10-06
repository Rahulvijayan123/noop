import Foundation
import WhoopProtocol

// PCSignalValidity.swift — System A: signal validity and measurement regime (spec §7).
//
// OWNER: signal & eligibility workstream. Behaviour, defaults and reason codes: docs/physiology-context/notes/signal.md.
//
// Three separations this file keeps:
//   • Input contract vs plausibility. `sanitize` rejects observations that break the transport/unit contract (bpm
//     outside 20–250, RR outside 50–30000 ms, negative / NaN dynamic acceleration, skin temperature outside 0–60 °C,
//     timestamps outside the read window or after generation) and de-duplicates by observation identity only.
//     Physiological plausibility is a separate, metric-specific step in `assess`.
//   • Signal quality vs value. `assess` never invalidates on the value of the metric alone (V03): a high heart rate
//     or a low RMSSD is a measurement, not an artifact. Gates read coverage, adjacency, over-count, beat accuracy,
//     flatlines and motion contamination of optical beat timing.
//   • Validity vs eligibility. A valid active measurement can be ineligible for a resting comparison (System B).
// Every rejection is counted by name in `InputContractReport.counts`; nothing is dropped silently. The engine removes
// data beyond the causal cutoff before `sanitize` runs, so no count here describes unavailable data.

extension PhysiologyContext {

    public struct ValidityConfig: Codable, Equatable, Sendable {
        public var version = "pc-validity-2"

        // MARK: Input contract (sanitize)
        public var hrContractMinBpm = 20
        public var hrContractMaxBpm = 250
        public var rrContractMinMs = 50
        public var rrContractMaxMs = 30_000
        public var skinContractMinC = 0.0
        public var skinContractMaxC = 60.0
        /// The decoder's own gate for `dynamic_acceleration@41` (Streams.swift `GravitySample.dynAccel`: `[0, 8] g`).
        public var dynAccelContractMaxG = 8.0
        /// A 1 Hz gravity vector is a ~1 g orientation estimate; a norm beyond this is another unit (mg) or corrupt.
        public var gravityVectorMaxNormG = 4.0
        /// Sensor time later than `generatedAt` by more than this is a future (clock-ahead) timestamp.
        public var futureToleranceS = 300
        /// Transport-order jump treated as a clock event (spike or reset), seconds.
        public var clockJumpS = 300
        /// Sensor time later than its own availability by more than this flags a device clock running ahead.
        public var deviceClockAheadToleranceS = 120
        /// No HR, RR or motion row from any stream for longer than this is a disconnection break.
        public var disconnectGapS = 60
        /// Conflicting heart-rate seconds spanning at least this long (holes ≤ 2 s) suggest two overlapping clocks.
        public var conflictClusterMinS = 30

        // MARK: Heart rate (heart_rate, resting_heart_rate)
        /// Plausibility band for one sample (the engine's derived windows use the same 30–220 bpm).
        public var hrPlausibleMinBpm = 30
        public var hrPlausibleMaxBpm = 220
        /// Observed share of the support's seconds below which the HR estimate is invalid.
        public var hrMinCoverage = 0.10
        /// Observed share below which it is degraded.
        public var hrValidCoverage = 0.50
        /// Out-of-band share of samples above which the estimate is degraded (never invalid on value).
        public var hrOutOfBandDegradedShare = 0.50
        /// Consecutive equal samples at most this far apart continue a flatline run.
        public var hrFlatlineMaxStepS = 2
        /// A constant-value run at least this long degrades the estimate. Integer bpm from a smoothed optical
        /// estimate can legitimately hold one value for minutes in deep sleep, so the bars are deliberately long.
        public var hrFlatlineDegradedS = 300
        /// A constant run at least this long that also covers `hrFlatlineInvalidShare` of the support is a stuck
        /// signal (invalid).
        public var hrFlatlineInvalidS = 900
        public var hrFlatlineInvalidShare = 0.80

        // MARK: Beat intervals (hrv_rmssd, hrv_sdnn, respiratory_rate)
        /// Wall-clock seconds by which a beat may trail its predecessor's own length before the pair is a splice
        /// (IntradaySeries.Tuning.spliceToleranceSeconds, SleepStager.rsaGapToleranceS).
        public var spliceToleranceS = 3.0
        /// Supports up to this long use the 5-minute series gates; longer supports are judged per window.
        public var shortSupportMaxS = 600
        /// Series gates (IntradaySeries.Tuning: 45 clean beats, 30 pairs, 0.2 coverage, 0.35 rejected).
        public var hrvMinCleanBeats = 45
        public var hrvMinPairs = 30
        public var hrvMinCoverage = 0.20
        public var hrvValidCoverage = 0.50
        public var hrvMaxRejectedFraction = 0.35
        /// ≥ 80 % normal beats convention (Peltola 2012, notes/research.md §4).
        public var hrvDegradedRejectedFraction = 0.20
        /// Long supports: window width and per-window gates (nightly kernel: ≥ 20 clean beats per 5-minute window).
        public var longSupportWindowS = 300
        public var hrvWindowMinCleanBeats = 20
        public var hrvWindowMinPairs = 10
        /// Share of windows that must qualify for a long support to be valid rather than degraded.
        public var longSupportValidWindowShare = 0.50
        /// Motion: labelled (stationary + movement) share of the support needed before a motion share is computed.
        public var motionMinObservedShare = 0.10
        /// Movement share of the labelled seconds above which optical beat timing is degraded / invalid
        /// (IntradaySeries.Tuning.restingMaxAmbulatoryShare 0.10, DaytimeStress.activityMaskFraction 0.30).
        public var motionDegradedShare = 0.10
        public var motionInvalidShare = 0.30
        /// Respiratory (RSA) gates (IntradaySeries.Tuning: 30 beats, 6 breath intervals, 0.33 run coverage).
        public var respMinBeats = 30
        public var respMinBreathIntervals = 6
        public var respMinCoverage = 0.33
        public var respValidCoverage = 0.50

        // MARK: Skin temperature
        /// Worn band (AnalyticsEngine.skinTempMinC / skinTempMaxC): samples inside are worn evidence.
        public var skinWornMinC = 28.0
        public var skinWornMaxC = 42.0
        /// In-band samples a support needs (AnalyticsEngine.minSkinTempSamples), capped at half its seconds.
        public var skinMinInBandSamples = 300
        public var skinValidInBandShare = 0.50

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

    public struct SignalValidity: Codable, Equatable, Sendable, Hashable {
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

        public func diagnostic(_ name: String) -> Double? { diagnostics.first { $0.name == name }?.value }
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
        /// `wrist` | `bicep` | `other` | `unknown` | `mixed` — never back-filled from today's placement.
        public var placement: String
        /// `user` | `device` | `none` | `mixed`.
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
        /// `account` when the placement comes from an account-level record (no device-scoped record covers the
        /// interval); nil for a device-scoped record or no record.
        public var scope: String? = nil
        public init(interval: Interval, placement: String, placementSource: String, scope: String? = nil) {
            self.interval = interval; self.placement = placement; self.placementSource = placementSource
            self.scope = scope
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

        public func count(_ name: String) -> Double { counts.first { $0.name == name }?.value ?? 0 }
    }

    /// Observations after identity de-duplication, contract checks and causal availability filtering. Every
    /// stream is sorted by `ts` (beat intervals by `ts`, then transport order `ord`, then value and `seq`).
    public struct SanitizedObservations: Equatable, Sendable {
        public var heartRate: [HeartRateObservation]
        public var beatIntervals: [BeatIntervalObservation]
        public var motion: [MotionObservation]
        public var steps: [StepObservation]
        public var skinTemperature: [SkinTemperatureObservation]
        public var wearEvents: [WearEventObservation]
        public var bandSleepStates: [BandSleepStateObservation]
        /// Intervals that must not be bridged (disconnections, clock resets, source changes), sorted and merged.
        /// Two observations at `a ≤ b` are not adjacent when a break intersects the closed span `[a, b]`
        /// (`break.start ≤ b && a < break.end`). A disconnection break is the unobserved stretch
        /// `[last + 1, next)`; a source change inside one whole second cannot be localized finer than that second.
        public var breaks: [Interval]
        public init(heartRate: [HeartRateObservation] = [], beatIntervals: [BeatIntervalObservation] = [],
                    motion: [MotionObservation] = [], steps: [StepObservation] = [],
                    skinTemperature: [SkinTemperatureObservation] = [], wearEvents: [WearEventObservation] = [],
                    bandSleepStates: [BandSleepStateObservation] = [], breaks: [Interval] = []) {
            self.heartRate = heartRate; self.beatIntervals = beatIntervals; self.motion = motion
            self.steps = steps; self.skinTemperature = skinTemperature; self.wearEvents = wearEvents
            self.bandSleepStates = bandSleepStates; self.breaks = breaks
        }

        /// True when a break intersects the closed span `[a, b]` (so observations at `a` and `b` are not adjacent).
        public func breakSeparates(_ a: Int, _ b: Int) -> Bool {
            SignalValidityEngine.breakTouches(breaks, a, b)
        }
    }

    public enum SignalValidityEngine {

        public static let version = "pc-validity-2"

        // MARK: Reason codes — input contract
        public static let outOfContractUnits: ReasonCode = "out_of_contract_units"
        public static let outsideReadWindow: ReasonCode = "outside_read_window"
        public static let futureTimestamp: ReasonCode = "future_timestamp"
        public static let timestampSpike: ReasonCode = "timestamp_spike"
        public static let exactDuplicatesCollapsed: ReasonCode = "exact_duplicates_collapsed"
        public static let conflictingDuplicatesRejected: ReasonCode = "conflicting_duplicates_rejected"
        public static let nonMonotonicTimestamps: ReasonCode = "non_monotonic_timestamps"
        public static let clockResetDetected: ReasonCode = "clock_reset_detected"
        public static let overlappingTimelinesSuspected: ReasonCode = "overlapping_timelines_suspected"
        public static let disconnection: ReasonCode = "disconnection"
        public static let sourceChange: ReasonCode = "source_change"
        public static let availabilityBasisSensorTime: ReasonCode = "availability_basis_sensor_time"
        public static let deviceClockAhead: ReasonCode = "device_clock_ahead"

        // MARK: Reason codes — validity
        public static let invalidInterval: ReasonCode = "invalid_interval"
        public static let noHeartRateSamples: ReasonCode = "no_heart_rate_samples"
        public static let noBeatIntervals: ReasonCode = "no_beat_intervals"
        public static let noSkinTemperatureSamples: ReasonCode = "no_skin_temperature_samples"
        public static let insufficientCoverage: ReasonCode = "insufficient_coverage"
        public static let partialCoverage: ReasonCode = "partial_coverage"
        public static let flatline: ReasonCode = "flatline"
        public static let flatlineRun: ReasonCode = "flatline_run"
        public static let outOfBandSamples: ReasonCode = "out_of_band_samples"
        public static let mostlyOutOfBand: ReasonCode = "mostly_out_of_band"
        public static let containsBreak: ReasonCode = "contains_break"
        public static let insufficientCleanBeats: ReasonCode = "insufficient_clean_beats"
        public static let insufficientValidPairs: ReasonCode = "insufficient_valid_pairs"
        public static let insufficientBeatCoverage: ReasonCode = "insufficient_beat_coverage"
        public static let partialBeatCoverage: ReasonCode = "partial_beat_coverage"
        public static let partialWindowCoverage: ReasonCode = "partial_window_coverage"
        public static let excessRejectedBeats: ReasonCode = "excess_rejected_beats"
        public static let elevatedRejectedBeats: ReasonCode = "elevated_rejected_beats"
        public static let beatsOutsideKernelRange: ReasonCode = "beats_outside_kernel_range"
        public static let rrOverCountSameSecond: ReasonCode = "rr_over_count_same_second"
        public static let rrOverCountCrossSecond: ReasonCode = "rr_over_count_cross_second"
        public static let rrUnderCovered: ReasonCode = "rr_under_covered"
        public static let rrCoverageUnmeasurable: ReasonCode = "rr_coverage_unmeasurable"
        public static let beatValuesUntrustworthy: ReasonCode = "beat_values_untrustworthy"
        public static let equalValueBeatsKept: ReasonCode = "equal_value_beats_kept"
        public static let motionContaminated: ReasonCode = "motion_contaminated"
        public static let motionPresent: ReasonCode = "motion_present"
        public static let motionUnobserved: ReasonCode = "motion_unobserved"
        public static let heartRateDependentMotionIgnored: ReasonCode = "heart_rate_dependent_motion_ignored"
        public static let windowLengthDependent: ReasonCode = "window_length_dependent"
        public static let insufficientBeats: ReasonCode = "insufficient_beats"
        public static let insufficientBreathIntervals: ReasonCode = "insufficient_breath_intervals"
        public static let insufficientRunCoverage: ReasonCode = "insufficient_run_coverage"
        public static let partialRunCoverage: ReasonCode = "partial_run_coverage"
        public static let rsaOnlyEstimate: ReasonCode = "rsa_only_estimate"
        public static let noInBandSamples: ReasonCode = "no_in_band_samples"
        public static let insufficientInBandSamples: ReasonCode = "insufficient_in_band_samples"
        public static let partialInBand: ReasonCode = "partial_in_band"
        public static let skinNotCoreTemperature: ReasonCode = "skin_not_core_temperature"
        public static let unverifiedStrapEstimate: ReasonCode = "unverified_strap_estimate"
        // Target-dependent screens inside the assessments: they read the target's own input values. Declared in
        // the availability matrix (per assessment) and in eligibility verdicts' `targetDependentGates` (per
        // measurement, when applied) for selection-bias review.
        /// HR samples outside 30–220 bpm; a majority outside degrades the estimate (never invalid on value).
        public static let gateHrPlausibleBand: ReasonCode = "hr_plausible_band"
        /// Beats outside the HRV kernel's 300–2000 ms range are rejected and count toward the rejected fraction.
        public static let gateRrKernelRange: ReasonCode = "rr_kernel_range"
        /// Ectopic-looking beats (successive-difference screen) are rejected and count toward the rejected fraction.
        public static let gateEctopicRejection: ReasonCode = "ectopic_rejection"
        /// Sleep / wake from the HR-confirmed sleep detector (eligibility rows).
        public static let gateSleepDetectorHrConfirmation: ReasonCode = "sleep_detector_hr_confirmation"

        // MARK: Reason codes — regime and comparability
        public static let placementChanged: ReasonCode = "placement_changed"
        public static let placementHistoryStarts: ReasonCode = "placement_history_starts"
        public static let placementRecordGap: ReasonCode = "placement_record_gap"
        public static let methodVersionChanged: ReasonCode = "method_version_changed"
        public static let vendorDiffers: ReasonCode = "vendor_differs"
        public static let deviceFamilyDiffers: ReasonCode = "device_family_differs"
        public static let deviceFamilyUnknown: ReasonCode = "device_family_unknown"
        public static let sourceKindDiffers: ReasonCode = "source_kind_differs"
        public static let sourceKindUnknown: ReasonCode = "source_kind_unknown"
        public static let firmwareDiffers: ReasonCode = "firmware_differs"
        public static let firmwareUnknown: ReasonCode = "firmware_unknown"
        public static let placementDiffers: ReasonCode = "placement_differs"
        public static let placementUnknown: ReasonCode = "placement_unknown"
        public static let placementMixed: ReasonCode = "placement_mixed"
        public static let methodDiffers: ReasonCode = "method_differs"
        public static let algorithmVersionDiffers: ReasonCode = "algorithm_version_differs"
        public static let aggregationDiffers: ReasonCode = "aggregation_differs"
        public static let windowDiffers: ReasonCode = "window_differs"
        public static let unitsDiffers: ReasonCode = "units_differs"
        public static let regimeKeyDiffers: ReasonCode = "regime_key_differs"

        // MARK: Reason codes — availability matrix
        public static let noQualifiedWaveform: ReasonCode = "no_qualified_waveform"
        public static let noCoreTemperatureSensor: ReasonCode = "no_core_temperature_sensor"
        public static let wristOrientationLikelihoodOnly: ReasonCode = "wrist_orientation_likelihood_only"
        public static let noGravityVector: ReasonCode = "no_gravity_vector"
        public static let heartRateIndependentSource: ReasonCode = "heart_rate_independent_source"
        public static let displayOnly: ReasonCode = "display_only"
        public static let sleepDetectorUsesHeartRate: ReasonCode = "sleep_detector_uses_heart_rate"
        public static let wearFromHeartRateSignal: ReasonCode = "wear_from_heart_rate_signal"
        public static let awakeEvidenceUnavailable: ReasonCode = "awake_evidence_unavailable"
        public static let wearEvidenceUnavailable: ReasonCode = "wear_evidence_unavailable"
        public static let sleepEvidenceUnavailable: ReasonCode = "sleep_evidence_unavailable"
        public static let noSourceRecords: ReasonCode = "no_source_records"
        public static let stepCounterPresent: ReasonCode = "step_counter_present"
        public static let excludedFromComparisons: ReasonCode = "excluded_from_comparisons"

        public static let reasonCodes: [ReasonCode] = [
            outOfContractUnits, outsideReadWindow, futureTimestamp, timestampSpike, exactDuplicatesCollapsed,
            conflictingDuplicatesRejected, nonMonotonicTimestamps, clockResetDetected, overlappingTimelinesSuspected,
            disconnection, sourceChange, availabilityBasisSensorTime, deviceClockAhead,
            invalidInterval, noHeartRateSamples, noBeatIntervals, noSkinTemperatureSamples, insufficientCoverage,
            partialCoverage, flatline, flatlineRun, outOfBandSamples, mostlyOutOfBand, containsBreak,
            insufficientCleanBeats, insufficientValidPairs, insufficientBeatCoverage, partialBeatCoverage,
            partialWindowCoverage, excessRejectedBeats, elevatedRejectedBeats, beatsOutsideKernelRange,
            rrOverCountSameSecond, rrOverCountCrossSecond, rrUnderCovered, rrCoverageUnmeasurable,
            beatValuesUntrustworthy, equalValueBeatsKept, motionContaminated, motionPresent, motionUnobserved,
            heartRateDependentMotionIgnored, windowLengthDependent, insufficientBeats, insufficientBreathIntervals,
            insufficientRunCoverage, partialRunCoverage, rsaOnlyEstimate, noInBandSamples,
            insufficientInBandSamples, partialInBand, skinNotCoreTemperature, unverifiedStrapEstimate,
            placementChanged, placementHistoryStarts, placementRecordGap, methodVersionChanged, vendorDiffers,
            deviceFamilyDiffers, deviceFamilyUnknown, sourceKindDiffers, sourceKindUnknown, firmwareDiffers,
            firmwareUnknown, placementDiffers, placementUnknown, placementMixed, methodDiffers,
            algorithmVersionDiffers, aggregationDiffers, windowDiffers, unitsDiffers, regimeKeyDiffers,
            noQualifiedWaveform, noCoreTemperatureSensor, wristOrientationLikelihoodOnly, noGravityVector,
            heartRateIndependentSource, displayOnly, sleepDetectorUsesHeartRate, wearFromHeartRateSignal,
            awakeEvidenceUnavailable, wearEvidenceUnavailable, sleepEvidenceUnavailable, noSourceRecords,
            stepCounterPresent, excludedFromComparisons, gateHrPlausibleBand, gateRrKernelRange,
            gateEctopicRejection, gateSleepDetectorHrConfirmation,
        ]

        /// Placement record scopes (`PlacementInput.scope`): a device-scoped record wins over an account-level one.
        public static let placementScopeDevice = "device"
        public static let placementScopeAccount = "account"

        /// The engine's raw read window for a day: `[dayStart − 30 h, dayEnd + 6 h)`.
        public static func readWindow(_ identity: DayIdentity) -> Interval {
            Interval(identity.dayWindow.start - Engine.rawLookbackS, identity.dayWindow.end + Engine.rawLookaheadS)
        }

        // MARK: - Sanitize

        /// Identity de-duplication (never by value alone), timestamp / unit / source-contract checks and breaks.
        /// Rejected observations are counted in the report, never silently dropped. The causal cutoff has already
        /// been applied by `Engine.causalView`.
        public static func sanitize(_ input: DayInput, config: ValidityConfig) -> (SanitizedObservations, InputContractReport) {
            var acc = Accumulator(window: readWindow(input.identity), generatedAt: input.generatedAt, config: config)

            // Heart rate: identity = ts; conflicting values at one ts are rejected, never averaged.
            let hr = acc.stream(
                input.heartRate, name: "heart_rate", ts: { $0.ts }, availableAt: { $0.availableAt },
                validate: { o in (config.hrContractMinBpm...config.hrContractMaxBpm).contains(o.bpm) ? o : nil },
                less: { ($0.ts, $0.bpm) < ($1.ts, $1.bpm) }, sameIdentity: { $0.ts == $1.ts },
                sameValue: { $0.bpm == $1.bpm },
                withAvailability: { o, at in var c = o; c.availableAt = at; return c },
                recordConflicts: true)

            // Beat intervals: identity = (ts, rrMs, seq). Equal values with different seq are distinct beats.
            let rr = acc.stream(
                input.beatIntervals, name: "beat_intervals", ts: { $0.ts }, availableAt: { $0.availableAt },
                validate: { o in (config.rrContractMinMs...config.rrContractMaxMs).contains(o.rrMs) ? o : nil },
                less: { a, b in
                    (a.ts, a.rrMs, a.seq, a.ord ?? Int.max, a.channel ?? Int.max)
                        < (b.ts, b.rrMs, b.seq, b.ord ?? Int.max, b.channel ?? Int.max)
                },
                sameIdentity: { $0.ts == $1.ts && $0.rrMs == $1.rrMs && $0.seq == $1.seq },
                sameValue: { _, _ in true },
                withAvailability: { o, at in var c = o; c.availableAt = at; return c },
                recordConflicts: false)
                .sorted { a, b in (a.ts, a.ord ?? Int.max, a.rrMs, a.seq) < (b.ts, b.ord ?? Int.max, b.rrMs, b.seq) }

            // Motion: dynamic acceleration and the gravity vector are checked separately; a row keeps whichever
            // part passes, and is rejected only when neither does.
            var dynRejected = 0, vectorRejected = 0
            func validateMotion(_ o: MotionObservation) -> MotionObservation? {
                var c = o
                if let d = c.dynAccelG, !(d.isFinite && d >= 0 && d <= config.dynAccelContractMaxG) {
                    c.dynAccelG = nil; dynRejected += 1
                }
                if c.x != nil || c.y != nil || c.z != nil {
                    var ok = false
                    if let x = c.x, let y = c.y, let z = c.z, x.isFinite, y.isFinite, z.isFinite {
                        let norm: Double = (x * x + y * y + z * z).squareRoot()
                        ok = norm <= config.gravityVectorMaxNormG
                    }
                    if !ok { c.x = nil; c.y = nil; c.z = nil; vectorRejected += 1 }
                }
                return (c.dynAccelG != nil || c.x != nil) ? c : nil
            }
            func motionLess(_ a: MotionObservation, _ b: MotionObservation) -> Bool {
                if a.ts != b.ts { return a.ts < b.ts }
                let pa: (Double, Double) = (a.dynAccelG ?? -1, a.x ?? -9)
                let pb: (Double, Double) = (b.dynAccelG ?? -1, b.x ?? -9)
                if pa != pb { return pa < pb }
                let qa: (Double, Double) = (a.y ?? -9, a.z ?? -9)
                let qb: (Double, Double) = (b.y ?? -9, b.z ?? -9)
                return qa < qb
            }
            func motionSame(_ a: MotionObservation, _ b: MotionObservation) -> Bool {
                a.dynAccelG == b.dynAccelG && a.x == b.x && a.y == b.y && a.z == b.z
            }
            let motion: [MotionObservation] = acc.stream(
                input.motion, name: "motion", ts: { $0.ts }, availableAt: { $0.availableAt },
                validate: validateMotion, less: motionLess, sameIdentity: { $0.ts == $1.ts },
                sameValue: motionSame, withAvailability: { o, at in var c = o; c.availableAt = at; return c },
                recordConflicts: false)
            acc.extra("motion.dyn_accel_contract_rejected", dynRejected)
            acc.extra("motion.vector_contract_rejected", vectorRejected)

            let steps = acc.stream(
                input.steps, name: "steps", ts: { $0.ts }, availableAt: { $0.availableAt },
                validate: { o in (0...0xFFFF).contains(o.counter) ? o : nil },
                less: { ($0.ts, $0.counter, $0.activityClass ?? -1) < ($1.ts, $1.counter, $1.activityClass ?? -1) },
                sameIdentity: { $0.ts == $1.ts },
                sameValue: { $0.counter == $1.counter && $0.activityClass == $1.activityClass },
                withAvailability: { o, at in var c = o; c.availableAt = at; return c },
                recordConflicts: false)

            let skin = acc.stream(
                input.skinTemperature, name: "skin_temperature", ts: { $0.ts }, availableAt: { $0.availableAt },
                validate: { o in
                    guard let c = o.celsius, c.isFinite, c >= config.skinContractMinC,
                          c <= config.skinContractMaxC else { return nil }
                    return o
                },
                less: { ($0.ts, $0.celsius ?? -1) < ($1.ts, $1.celsius ?? -1) },
                sameIdentity: { $0.ts == $1.ts }, sameValue: { $0.celsius == $1.celsius },
                withAvailability: { o, at in var c = o; c.availableAt = at; return c },
                recordConflicts: false)

            let wear = acc.stream(
                input.wearEvents, name: "wear_events", ts: { $0.ts }, availableAt: { $0.availableAt },
                validate: { $0 },
                less: { ($0.ts, $0.state.rawValue, $0.kind) < ($1.ts, $1.state.rawValue, $1.kind) },
                sameIdentity: { $0.ts == $1.ts }, sameValue: { $0.state == $1.state },
                withAvailability: { o, at in var c = o; c.availableAt = at; return c },
                recordConflicts: false)

            let band = acc.stream(
                input.bandSleepStates, name: "band_sleep_states", ts: { $0.ts }, availableAt: { $0.availableAt },
                validate: { $0 },
                less: { ($0.ts, $0.state) < ($1.ts, $1.state) },
                sameIdentity: { $0.ts == $1.ts }, sameValue: { $0.state == $1.state },
                withAvailability: { o, at in var c = o; c.availableAt = at; return c },
                recordConflicts: false)

            // Breaks: disconnections over the union of HR, RR and motion; RR source-channel changes; clusters of
            // conflicting heart-rate seconds (two clocks writing the same span).
            var breaks = acc.clockBreaks
            var disconnections = 0
            let union = mergedUniqueTimes(hr.map(\.ts), rr.map(\.ts), motion.map(\.ts))
            if union.count >= 2 {
                for i in 1..<union.count where union[i] - union[i - 1] > config.disconnectGapS {
                    breaks.append(Interval(union[i - 1] + 1, union[i])); disconnections += 1
                }
            }
            var sourceChanges = 0
            if rr.count >= 2 {
                for i in 1..<rr.count {
                    guard let a = rr[i - 1].channel, let b = rr[i].channel, a != b else { continue }
                    let p = rr[i - 1].ts, n = rr[i].ts
                    breaks.append(n >= p + 2 ? Interval(p + 1, n) : Interval(n, n + 1))
                    sourceChanges += 1
                }
            }
            var conflictClusters = 0
            let conflicts = acc.conflictSeconds.sorted()
            var c0 = 0
            while c0 < conflicts.count {
                var c1 = c0
                while c1 + 1 < conflicts.count, conflicts[c1 + 1] - conflicts[c1] <= 2 { c1 += 1 }
                if conflicts[c1] - conflicts[c0] + 1 >= config.conflictClusterMinS {
                    breaks.append(Interval(conflicts[c0], conflicts[c1] + 1)); conflictClusters += 1
                }
                c0 = c1 + 1
            }
            let merged = mergeIntervals(breaks)

            acc.extra("breaks.disconnection", disconnections)
            acc.extra("breaks.source_change", sourceChanges)
            acc.extra("breaks.conflict_cluster", conflictClusters)
            acc.extra("breaks.clock_reset", acc.clockBreaks.count)
            acc.extra("breaks.merged", merged.count)
            acc.extra("breaks.total_s", merged.reduce(0) { $0 + $1.duration })
            if disconnections > 0 { acc.reason(disconnection) }
            if sourceChanges > 0 { acc.reason(sourceChange) }
            if conflictClusters > 0 { acc.reason(overlappingTimelinesSuspected) }

            let keptTotal = hr.count + rr.count + motion.count + steps.count + skin.count + wear.count + band.count
            let basis: String
            if keptTotal > 0 && acc.withoutAvailability == 0 {
                basis = "ingested_at"
            } else {
                basis = "sensor_time"
                if acc.withoutAvailability > 0 { acc.reason(availabilityBasisSensorTime) }
            }
            acc.extra("observations.without_availability", acc.withoutAvailability)

            let observations = SanitizedObservations(heartRate: hr, beatIntervals: rr, motion: motion, steps: steps,
                                                     skinTemperature: skin, wearEvents: wear, bandSleepStates: band,
                                                     breaks: merged)
            let report = InputContractReport(reasons: acc.orderedReasons(), counts: acc.counts,
                                             availabilityBasis: basis)
            return (observations, report)
        }

        /// Per-stream sanitizing with counting. One instance per `sanitize` call.
        private struct Accumulator {
            let window: Interval
            let generatedAt: Int
            let config: ValidityConfig
            var counts: [Diagnostic] = []
            var reasons: Set<ReasonCode> = []
            var clockBreaks: [Interval] = []
            var conflictSeconds: [Int] = []
            var withoutAvailability = 0

            init(window: Interval, generatedAt: Int, config: ValidityConfig) {
                self.window = window; self.generatedAt = generatedAt; self.config = config
            }

            mutating func reason(_ r: ReasonCode) { reasons.insert(r) }
            mutating func extra(_ name: String, _ value: Int) {
                if value != 0 || name.hasSuffix(".kept") || name.hasSuffix(".input") {
                    counts.append(Diagnostic(name, Double(value)))
                }
            }
            func orderedReasons() -> [ReasonCode] { SignalValidityEngine.reasonCodes.filter(reasons.contains) }

            mutating func stream<T>(_ rows: [T], name: String, ts: (T) -> Int, availableAt: (T) -> Int?,
                                    validate: (T) -> T?, less: (T, T) -> Bool, sameIdentity: (T, T) -> Bool,
                                    sameValue: (T, T) -> Bool, withAvailability: (T, Int?) -> T,
                                    recordConflicts: Bool) -> [T] {
                var contract = 0, outside = 0, future = 0
                // 1. Unit / range contract, read window, future timestamps (input order preserved).
                var ordered: [T] = []
                ordered.reserveCapacity(rows.count)
                for r in rows {
                    guard let v = validate(r) else { contract += 1; continue }
                    let t = ts(v)
                    if !window.contains(t) { outside += 1; continue }
                    if t > generatedAt + config.futureToleranceS { future += 1; continue }
                    ordered.append(v)
                }
                // 2. Transport order: isolated spikes are rejected; backward steps are counted; a large backward
                //    step inside one delivery (same availability) is a clock reset whose overlapped span is a break.
                var spikes = 0, nonMonotonic = 0, resets = 0
                var spike = [Bool](repeating: false, count: ordered.count)
                let jump = config.clockJumpS
                if ordered.count >= 3 {
                    for i in 1..<(ordered.count - 1) {
                        let a = ts(ordered[i - 1]), b = ts(ordered[i]), c = ts(ordered[i + 1])
                        if abs(b - a) > jump && abs(c - b) > jump && abs(c - a) <= jump { spike[i] = true; spikes += 1 }
                    }
                }
                var timeline: [T] = []
                timeline.reserveCapacity(ordered.count)
                var runningMax = Int.min
                for (i, r) in ordered.enumerated() where !spike[i] {
                    let t = ts(r)
                    if let prev = timeline.last {
                        let p = ts(prev)
                        if t < p {
                            nonMonotonic += 1
                            if p - t > jump && availableAt(prev) == availableAt(r) {
                                resets += 1
                                clockBreaks.append(Interval(t, runningMax + 1))
                            }
                        }
                    }
                    runningMax = max(runningMax, t)
                    timeline.append(r)
                }
                // 3. Identity de-duplication: exact duplicates collapse (earliest known availability); differing
                //    values under one identity are all rejected.
                let sorted = timeline.sorted(by: less)
                var kept: [T] = []
                kept.reserveCapacity(sorted.count)
                var exact = 0, conflictRows = 0, conflictIds = 0
                var i = 0
                while i < sorted.count {
                    var j = i + 1
                    while j < sorted.count, sameIdentity(sorted[i], sorted[j]) { j += 1 }
                    let group = sorted[i..<j]
                    if group.allSatisfy({ sameValue($0, sorted[i]) }) {
                        let at = group.compactMap(availableAt).min()
                        kept.append(withAvailability(sorted[i], at))
                        exact += group.count - 1
                    } else {
                        conflictRows += group.count; conflictIds += 1
                        if recordConflicts { conflictSeconds.append(ts(sorted[i])) }
                    }
                    i = j
                }
                kept.sort { ts($0) < ts($1) }
                // 4. Availability accounting on what is kept.
                var noAvailability = 0, ahead = 0
                for r in kept {
                    if let at = availableAt(r) {
                        if ts(r) > at + config.deviceClockAheadToleranceS { ahead += 1 }
                    } else {
                        noAvailability += 1
                    }
                }
                withoutAvailability += noAvailability

                extra("\(name).input", rows.count)
                extra("\(name).kept", kept.count)
                extra("\(name).contract_rejected", contract)
                extra("\(name).outside_read_window", outside)
                extra("\(name).future_timestamp_rejected", future)
                extra("\(name).timestamp_spike_rejected", spikes)
                extra("\(name).exact_duplicates_collapsed", exact)
                extra("\(name).conflicting_duplicates_rejected", conflictRows)
                extra("\(name).conflicting_identities", conflictIds)
                extra("\(name).non_monotonic_steps", nonMonotonic)
                extra("\(name).clock_resets", resets)
                extra("\(name).without_availability", noAvailability)
                extra("\(name).sensor_time_after_availability", ahead)
                if contract > 0 { reason(SignalValidityEngine.outOfContractUnits) }
                if outside > 0 { reason(SignalValidityEngine.outsideReadWindow) }
                if future > 0 { reason(SignalValidityEngine.futureTimestamp) }
                if spikes > 0 { reason(SignalValidityEngine.timestampSpike) }
                if exact > 0 { reason(SignalValidityEngine.exactDuplicatesCollapsed) }
                if conflictRows > 0 { reason(SignalValidityEngine.conflictingDuplicatesRejected) }
                if nonMonotonic > 0 { reason(SignalValidityEngine.nonMonotonicTimestamps) }
                if resets > 0 { reason(SignalValidityEngine.clockResetDetected) }
                if ahead > 0 { reason(SignalValidityEngine.deviceClockAhead) }
                return kept
            }
        }

        // MARK: - Assess

        /// Metric-specific validity of one measurement over its support interval.
        public static func assess(_ measurement: MeasurementInput, observations: SanitizedObservations,
                                  motion: ResolvedTrack, config: ValidityConfig) -> SignalValidity {
            let support = measurement.support
            guard support.isValid else { return SignalValidity(state: .missing, reasons: [invalidInterval]) }
            switch measurement.metric {
            case .heartRate, .restingHeartRate:
                return assessHeartRate(support, observations, motion, config)
            case .hrvRmssd, .hrvSdnn:
                return assessHRV(measurement, observations, motion, config)
            case .respiratoryRate:
                return assessRespiration(support, observations, motion, config)
            case .skinTemperature:
                return assessSkin(support, observations, config)
            case .spo2Candidate:
                return SignalValidity(state: .unverified, reasons: [unverifiedStrapEstimate])
            }
        }

        /// Collects gate outcomes: `fail` makes the state invalid, `degrade` makes a valid state degraded, `note`
        /// records an interpretation limit without changing the state.
        private struct Verdict {
            var state: ValidityState = .valid
            var reasons: [ReasonCode] = []
            var diagnostics: [Diagnostic] = []
            mutating func fail(_ r: ReasonCode) { state = .invalid; add(r) }
            mutating func degrade(_ r: ReasonCode) { if state == .valid { state = .degraded }; add(r) }
            mutating func note(_ r: ReasonCode) { add(r) }
            mutating func add(_ r: ReasonCode) { if !reasons.contains(r) { reasons.append(r) } }
            /// Reported diagnostics are rounded to 1e-4 (decisions use the unrounded values).
            mutating func diag(_ name: String, _ value: Double?) {
                if let v = value, v.isFinite { diagnostics.append(Diagnostic(name, (v * 10_000).rounded() / 10_000)) }
            }
            /// Incident counters are reported only when non-zero (absent = 0).
            mutating func incident(_ name: String, _ count: Int) {
                if count != 0 { diag(name, Double(count)) }
            }
            func result(coverage: Double?, observedS: Int?) -> SignalValidity {
                SignalValidity(state: state, reasons: reasons, coverage: coverage.map { min(1, max(0, $0)) },
                               observedS: observedS, diagnostics: diagnostics, confidence: .notApplicable)
            }
        }

        /// Movement share of the support from the HR-independent track, over its labelled (stationary + movement)
        /// seconds; nil when too little of the support is labelled. Whole-interval shares are in the envelope's
        /// `activity` composition.
        private struct MotionShare {
            var share: Double?
            var reasons: [ReasonCode]
        }

        private static func motionShare(_ support: Interval, _ track: ResolvedTrack,
                                        _ config: ValidityConfig) -> MotionShare {
            guard !track.heartRateDependent else {
                return MotionShare(share: nil, reasons: [heartRateDependentMotionIgnored])
            }
            let c = IntervalAlgebra.composition(over: support, track: track)
            var movement = 0.0, stationary = 0.0
            for l in c.labels {
                if MotionVocabulary.isMovement(l.label) { movement += l.seconds }
                else if MotionVocabulary.isStationary(l.label) { stationary += l.seconds }
            }
            let d = Double(max(1, support.duration))
            let labelled = movement + stationary
            guard labelled / d >= config.motionMinObservedShare, labelled > 0 else {
                return MotionShare(share: nil, reasons: [motionUnobserved])
            }
            return MotionShare(share: movement / labelled, reasons: [])
        }

        private static func applyOpticalMotion(_ m: MotionShare, _ v: inout Verdict, _ config: ValidityConfig) {
            for r in m.reasons { v.note(r) }
            if let s = m.share {
                if s > config.motionInvalidShare { v.fail(motionContaminated) }
                else if s > config.motionDegradedShare { v.degrade(motionPresent) }
            }
            v.diag("movement_share", m.share)
        }

        // MARK: Heart rate

        private static func assessHeartRate(_ support: Interval, _ o: SanitizedObservations, _ track: ResolvedTrack,
                                            _ config: ValidityConfig) -> SignalValidity {
            let samples = slice(o.heartRate, support) { $0.ts }
            let d = support.duration
            var v = Verdict()
            guard !samples.isEmpty else {
                v.state = .missing; v.add(noHeartRateSamples)
                return v.result(coverage: 0, observedS: 0)
            }
            let n = samples.count
            let coverage = Double(n) / Double(d)
            var outOfBand = 0
            var longest = 0, runStart = samples.first!.ts, prev = samples.first!
            for (k, s) in samples.enumerated() {
                if !(config.hrPlausibleMinBpm...config.hrPlausibleMaxBpm).contains(s.bpm) { outOfBand += 1 }
                if k > 0 {
                    if !(s.bpm == prev.bpm && s.ts - prev.ts <= config.hrFlatlineMaxStepS) { runStart = s.ts }
                }
                longest = max(longest, s.ts - runStart + 1)
                prev = s
            }
            if coverage < config.hrMinCoverage { v.fail(insufficientCoverage) }
            else if coverage < config.hrValidCoverage { v.degrade(partialCoverage) }
            if longest >= config.hrFlatlineInvalidS && Double(longest) >= config.hrFlatlineInvalidShare * Double(d) {
                v.fail(flatline)
            } else if longest >= config.hrFlatlineDegradedS {
                v.degrade(flatlineRun)
            }
            if outOfBand > 0 {
                if Double(outOfBand) / Double(n) > config.hrOutOfBandDegradedShare { v.degrade(mostlyOutOfBand) }
                else { v.note(outOfBandSamples) }
            }
            let breaks = breaksInside(o.breaks, support)
            if breaks > 0 { v.note(containsBreak) }
            // Motion is a diagnostic for HR: movement raises heart rate, it does not corrupt the sample.
            let m = motionShare(support, track, config)
            v.diag("samples", Double(n))
            v.diag("longest_flatline_s", Double(longest))
            v.incident("out_of_band_samples", outOfBand)
            v.incident("breaks_in_support", breaks)
            v.diag("movement_share", m.share)
            return v.result(coverage: coverage, observedS: n)
        }

        // MARK: HRV (RMSSD / SDNN)

        /// Beat-run statistics of one window: gap-aware cleaning per unbroken run (HRVAnalyzer.cleanRRGapAware).
        struct BeatStats: Equatable {
            var beats = 0
            var clean = 0
            var pairs = 0
            var cleanMs = 0.0
            var outOfRange = 0
            var ectopic = 0
            var runs = 0
            mutating func add(_ o: BeatStats) {
                beats += o.beats; clean += o.clean; pairs += o.pairs; cleanMs += o.cleanMs
                outOfRange += o.outOfRange; ectopic += o.ectopic; runs += o.runs
            }
        }

        /// Split sorted beats into unbroken runs: a new run starts where the wall clock ran ahead of the beat's own
        /// length by more than the splice tolerance, where the source channel changes, or where a break touches
        /// the pair. No pair is ever formed across a run boundary.
        static func runs(_ beats: ArraySlice<BeatIntervalObservation>, breaks: [Interval],
                         toleranceS: Double) -> [[BeatIntervalObservation]] {
            var out: [[BeatIntervalObservation]] = []
            var current: [BeatIntervalObservation] = []
            var previous: BeatIntervalObservation? = nil
            for b in beats {
                if let p = previous {
                    let splice = Double(b.ts - p.ts) - Double(b.rrMs) / 1000.0 > toleranceS
                    let channel = p.channel != nil && b.channel != nil && p.channel != b.channel
                    if splice || channel || breakTouches(breaks, p.ts, b.ts) {
                        out.append(current); current = []
                    }
                }
                current.append(b)
                previous = b
            }
            if !current.isEmpty { out.append(current) }
            return out
        }

        static func beatStats(_ beats: ArraySlice<BeatIntervalObservation>, breaks: [Interval],
                              toleranceS: Double) -> BeatStats {
            var s = BeatStats()
            for run in runs(beats, breaks: breaks, toleranceS: toleranceS) {
                let values = run.map { Double($0.rrMs) }
                let inRange = values.filter { $0 >= HRVAnalyzer.rrMinMs && $0 <= HRVAnalyzer.rrMaxMs }.count
                let cleaned = HRVAnalyzer.cleanRRGapAware(values)
                s.beats += run.count
                s.runs += 1
                s.outOfRange += run.count - inRange
                s.ectopic += inRange - cleaned.nn.count
                s.clean += cleaned.nn.count
                s.cleanMs += cleaned.nn.reduce(0, +)
                s.pairs += cleaned.contiguous.filter { $0 }.count
            }
            return s
        }

        private static func assessHRV(_ m: MeasurementInput, _ o: SanitizedObservations, _ track: ResolvedTrack,
                                      _ config: ValidityConfig) -> SignalValidity {
            let support = m.support
            let d = support.duration
            let beats = slice(o.beatIntervals, support) { $0.ts }
            var v = Verdict()
            let sdnn = m.metric == .hrvSdnn
            if sdnn {
                v.note(windowLengthDependent)
                v.diag("window_s", Double(m.method.windowS))
            }
            guard !beats.isEmpty else {
                v.state = .missing; v.add(noBeatIntervals)
                return v.result(coverage: 0, observedS: 0)
            }
            let ts = beats.map(\.ts)
            let ms = beats.map { Double($0.rrMs) }
            let coverageRatio = HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: ms)
            let collapsed = HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: ms)
            let verdict = HRVAnalyzer.classifyCoverage(coverage: coverageRatio, collapsed: collapsed)
            let accurate = HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: ms)
            let equalValue = HRVAnalyzer.duplicateBeatCount(tsSec: ts, rrMs: ms)

            var total = BeatStats()
            var windows = 0, qualified = 0
            let short = d <= config.shortSupportMaxS
            if short {
                total = beatStats(beats, breaks: o.breaks, toleranceS: config.spliceToleranceS)
            } else {
                let width = max(60, config.longSupportWindowS)
                var w0 = support.start
                while w0 < support.end {
                    let w = Interval(w0, min(support.end, w0 + width))
                    let s = beatStats(slice(o.beatIntervals, w) { $0.ts }, breaks: o.breaks,
                                      toleranceS: config.spliceToleranceS)
                    windows += 1
                    if s.clean >= config.hrvWindowMinCleanBeats && s.pairs >= config.hrvWindowMinPairs { qualified += 1 }
                    total.add(s)
                    w0 += width
                }
            }
            let coverage = total.cleanMs / (Double(d) * 1000.0)
            let rejected = total.beats > 0 ? 1.0 - Double(total.clean) / Double(total.beats) : 1.0

            if short {
                if total.clean < config.hrvMinCleanBeats { v.fail(insufficientCleanBeats) }
                if total.pairs < config.hrvMinPairs { v.fail(insufficientValidPairs) }
                if coverage < config.hrvMinCoverage { v.fail(insufficientBeatCoverage) }
                else if coverage < config.hrvValidCoverage { v.degrade(partialBeatCoverage) }
            } else {
                if qualified == 0 { v.fail(insufficientCleanBeats) }
                else if Double(qualified) / Double(max(1, windows)) < config.longSupportValidWindowShare {
                    v.degrade(partialWindowCoverage)
                }
            }
            if rejected > config.hrvMaxRejectedFraction { v.fail(excessRejectedBeats) }
            else if rejected > config.hrvDegradedRejectedFraction { v.degrade(elevatedRejectedBeats) }
            if total.outOfRange > 0 { v.note(beatsOutsideKernelRange) }
            applyCoverageVerdict(verdict, &v)
            if !HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: accurate) {
                // SDNN is a spread over every stored value; RMSSD is not gated on beat accuracy by HRVAnalyzer.
                if sdnn { v.fail(beatValuesUntrustworthy) } else { v.degrade(beatValuesUntrustworthy) }
            }
            if equalValue > 0 { v.note(equalValueBeatsKept) }
            let breaks = breaksInside(o.breaks, support)
            if breaks > 0 { v.note(containsBreak) }
            applyOpticalMotion(motionShare(support, track, config), &v, config)

            v.diag("beats", Double(total.beats))
            v.diag("clean_beats", Double(total.clean))
            v.diag("valid_pairs", Double(total.pairs))
            v.diag("runs", Double(total.runs))
            v.diag("rejected_fraction", rejected)
            v.diag("beat_coverage", coverage)
            v.diag("rr_coverage_ratio", coverageRatio)
            if coverageRatio > HRVAnalyzer.coveragePlausibleCeiling { v.diag("collapsed_coverage_ratio", collapsed) }
            v.diag("beat_accurate_fraction", accurate)
            v.incident("out_of_range_beats", total.outOfRange)
            v.incident("ectopic_rejected", total.ectopic)
            v.incident("equal_value_same_second_beats", equalValue)
            v.incident("breaks_in_support", breaks)
            if !short {
                v.diag("windows", Double(windows))
                v.diag("qualified_windows", Double(qualified))
            }
            return v.result(coverage: coverage, observedS: distinctCount(ts))
        }

        private static func applyCoverageVerdict(_ verdict: HRVAnalyzer.RrCoverageVerdict, _ v: inout Verdict) {
            switch verdict {
            case .sameSecondOverCount: v.fail(rrOverCountSameSecond)
            case .crossSecondOverCount: v.fail(rrOverCountCrossSecond)
            case .underCovered: v.note(rrUnderCovered)
            case .unmeasurable: v.note(rrCoverageUnmeasurable)
            case .plausible: break
            }
        }

        // MARK: Respiratory rate (RSA from beat intervals)

        private static func assessRespiration(_ support: Interval, _ o: SanitizedObservations,
                                              _ track: ResolvedTrack, _ config: ValidityConfig) -> SignalValidity {
            let d = support.duration
            let beats = slice(o.beatIntervals, support) { $0.ts }
            var v = Verdict()
            v.note(rsaOnlyEstimate)
            guard !beats.isEmpty else {
                v.state = .missing; v.add(noBeatIntervals)
                return v.result(coverage: 0, observedS: 0)
            }
            let ts = beats.map(\.ts)
            let ms = beats.map { Double($0.rrMs) }
            let verdict = HRVAnalyzer.classifyCoverage(coverage: HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: ms),
                                                       collapsed: HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: ms))
            let accurate = HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: ms)

            // Breath intervals per break-free, single-channel segment (the breath track itself splits at splices).
            var segments: [[RRInterval]] = []
            var current: [RRInterval] = []
            var previous: BeatIntervalObservation? = nil
            for b in beats {
                if let p = previous {
                    let channel = p.channel != nil && b.channel != nil && p.channel != b.channel
                    if channel || breakTouches(o.breaks, p.ts, b.ts) { segments.append(current); current = [] }
                }
                current.append(RRInterval(ts: b.ts, rrMs: b.rrMs, seq: b.seq))
                previous = b
            }
            if !current.isEmpty { segments.append(current) }
            var breaths = 0
            var covered = 0
            for seg in segments {
                let t = SleepStager.respBreathTrack(seg)
                breaths += t.intervals.filter { support.contains($0.ts) }.count
                for run in t.runs {
                    covered += Interval(run.start, run.end + 1).overlapSeconds(with: support)
                }
            }
            let coverage = Double(covered) / Double(d)

            if beats.count < config.respMinBeats { v.fail(insufficientBeats) }
            if breaths < config.respMinBreathIntervals { v.fail(insufficientBreathIntervals) }
            if coverage < config.respMinCoverage { v.fail(insufficientRunCoverage) }
            else if coverage < config.respValidCoverage { v.degrade(partialRunCoverage) }
            applyCoverageVerdict(verdict, &v)
            // The respiration kernels share the SDNN beat-accuracy gate (HRVAnalyzer.beatAccuracyToleranceS).
            if !HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: accurate) { v.fail(beatValuesUntrustworthy) }
            let breaks = breaksInside(o.breaks, support)
            if breaks > 0 { v.note(containsBreak) }
            // RSA respiration is unreliable outside rest (Charlton 2016/2018, notes/research.md §6).
            applyOpticalMotion(motionShare(support, track, config), &v, config)

            v.diag("beats", Double(beats.count))
            v.diag("breath_intervals", Double(breaths))
            v.diag("run_covered_s", Double(covered))
            v.diag("segments", Double(segments.count))
            v.diag("beat_accurate_fraction", accurate)
            v.incident("breaks_in_support", breaks)
            return v.result(coverage: coverage, observedS: distinctCount(ts))
        }

        // MARK: Skin temperature

        private static func assessSkin(_ support: Interval, _ o: SanitizedObservations,
                                       _ config: ValidityConfig) -> SignalValidity {
            let d = support.duration
            let samples = slice(o.skinTemperature, support) { $0.ts }
            var v = Verdict()
            v.note(skinNotCoreTemperature)
            guard !samples.isEmpty else {
                v.state = .missing; v.add(noSkinTemperatureSamples)
                return v.result(coverage: 0, observedS: 0)
            }
            let inBand = samples.filter { s in
                guard let c = s.celsius else { return false }
                return c >= config.skinWornMinC && c <= config.skinWornMaxC
            }.count
            let needed = max(1, min(config.skinMinInBandSamples, Int(Double(d) * config.skinValidInBandShare)))
            let share = Double(inBand) / Double(samples.count)
            if inBand == 0 { v.fail(noInBandSamples) }
            else {
                if inBand < needed { v.degrade(insufficientInBandSamples) }
                if share < config.skinValidInBandShare { v.degrade(partialInBand) }
            }
            v.diag("samples", Double(samples.count))
            v.diag("in_band_samples", Double(inBand))
            v.diag("in_band_share", share)
            v.diag("in_band_needed", Double(needed))
            return v.result(coverage: Double(samples.count) / Double(d), observedS: samples.count)
        }

        // MARK: - Regime

        /// Placement segments (unknown before the first record; never back-filled) and regime boundaries
        /// (placement changes; method version changes visible across the day's measurements). Device, firmware
        /// and source-kind changes across days surface through the regime keys of daily values.
        public static func regimeTimeline(_ input: DayInput, config: ValidityConfig) -> RegimeTimeline {
            let window = readWindow(input.identity)
            let earliest = input.placements.map(\.start).min()
            // Scope first (RC-17, the app's `PlacementStore` rule): a device-scoped record (scope nil or `device`)
            // wins over an account-level record wherever they overlap, whatever their revisions; the account-level
            // record applies only where no device-scoped record exists. Within one scope, overlaps resolve by
            // revision, then `recordedAt`, then a stable id.
            var deviceRecords: [LabelRecord] = []
            var accountRecords: [LabelRecord] = []
            for p in input.placements {
                let end = p.end ?? window.end
                guard end > p.start, let iv = Interval(p.start, end).intersection(window) else { continue }
                let placement = normalize(p.placement)
                let account = p.scope.map(normalize) == placementScopeAccount
                let record = LabelRecord(interval: iv, label: "\(placement)|\(normalize(p.source))",
                                         revision: p.revision, availableAt: p.recordedAt,
                                         tieBreak: "placement:\(p.start):\(p.end ?? -1):\(placement):\(p.source)")
                if account { accountRecords.append(record) } else { deviceRecords.append(record) }
            }
            let device = IntervalAlgebra.resolve(deviceRecords, source: .none, heartRateDependent: false).spans
            let account = IntervalAlgebra.resolve(accountRecords, source: .none, heartRateDependent: false).spans
            var spans: [(interval: Interval, label: String?, scope: String?)] = device.map { ($0.interval, $0.label, nil) }
            let deviceCover = mergeIntervals(device.map(\.interval))
            for s in account {
                for piece in subtract(deviceCover, from: s.interval) {
                    spans.append((piece, s.label, placementScopeAccount))
                }
            }
            spans.sort { $0.interval < $1.interval }
            var segments: [PlacementSegment] = []
            func append(_ iv: Interval, _ placement: String, _ source: String, _ scope: String?) {
                if var last = segments.last, last.interval.end == iv.start, last.placement == placement,
                   last.placementSource == source, last.scope == scope {
                    last.interval.end = iv.end
                    segments[segments.count - 1] = last
                } else {
                    segments.append(PlacementSegment(interval: iv, placement: placement, placementSource: source,
                                                     scope: scope))
                }
            }
            var cursor = window.start
            for span in spans {
                if span.interval.start > cursor {
                    append(Interval(cursor, span.interval.start), "unknown", "none", nil)
                }
                let parts = (span.label ?? "unknown|none").split(separator: "|", maxSplits: 1).map(String.init)
                append(span.interval, parts.first ?? "unknown", parts.count > 1 ? parts[1] : "none", span.scope)
                cursor = span.interval.end
            }
            if cursor < window.end { append(Interval(cursor, window.end), "unknown", "none", nil) }

            var boundaries: [RegimeBoundary] = []
            if segments.count >= 2 {
                for k in 1..<segments.count where segments[k].placement != segments[k - 1].placement {
                    let a = segments[k - 1], b = segments[k]
                    let at = b.interval.start
                    if a.placement == "unknown", a.placementSource == "none", let e = earliest, at <= e {
                        boundaries.append(RegimeBoundary(at: at, kind: "placement_history_start", fromValue: nil,
                                                         toValue: b.placement, reasons: [placementHistoryStarts]))
                    } else {
                        let reasons: [ReasonCode] = b.placementSource == "none" ? [placementRecordGap] : [placementChanged]
                        boundaries.append(RegimeBoundary(at: at, kind: "placement", fromValue: a.placement,
                                                         toValue: b.placement, reasons: reasons))
                    }
                }
            }
            boundaries += methodBoundaries(input.measurements)
            boundaries.sort { ($0.at, $0.kind, $0.toValue ?? "") < ($1.at, $1.kind, $1.toValue ?? "") }
            return RegimeTimeline(placements: segments, boundaries: boundaries, registry: [])
        }

        /// A method id whose algorithm version, aggregation, window or units change between consecutive
        /// measurements of the same metric is a method boundary at the first support of the new version.
        static func methodBoundaries(_ measurements: [MeasurementInput]) -> [RegimeBoundary] {
            var byMethod: [String: [MeasurementInput]] = [:]
            for m in measurements { byMethod["\(m.metric.rawValue)|\(m.method.id)", default: []].append(m) }
            var out: [RegimeBoundary] = []
            for key in byMethod.keys.sorted() {
                let ms = byMethod[key]!.sorted { ($0.support, $0.method.algorithmVersion) < ($1.support, $1.method.algorithmVersion) }
                guard ms.count >= 2 else { continue }
                for k in 1..<ms.count {
                    let a = ms[k - 1].method, b = ms[k].method
                    guard a.algorithmVersion != b.algorithmVersion || a.aggregation != b.aggregation
                            || windowClass(a) != windowClass(b) || a.units != b.units else { continue }
                    out.append(RegimeBoundary(at: ms[k].support.start, kind: "method",
                                              fromValue: "\(a.id)@\(a.algorithmVersion)",
                                              toValue: "\(b.id)@\(b.algorithmVersion)",
                                              reasons: [methodVersionChanged]))
                }
            }
            return out
        }

        /// The regime of one measurement: placement over its whole support (`mixed` when it spans a placement
        /// boundary, `unknown` before the first record) with the device and method attributes.
        public static func regime(for measurement: MeasurementInput, timeline: RegimeTimeline,
                                  device: DeviceRegimeInput) -> MeasurementRegime {
            let support = measurement.support
            let overlapping = timeline.placements.filter {
                support.isValid ? $0.interval.overlapSeconds(with: support) > 0 : $0.interval.contains(support.start)
            }
            let placement: String
            let source: String
            if overlapping.isEmpty {
                placement = "unknown"; source = "none"
            } else if Set(overlapping.map(\.placement)).count == 1 {
                placement = overlapping[0].placement
                source = Set(overlapping.map(\.placementSource)).count == 1 ? overlapping[0].placementSource : "mixed"
            } else {
                placement = "mixed"; source = "mixed"
            }
            let method = measurement.method
            let vendor = normalize(device.vendor)
            let family = device.deviceFamily.map(normalize)
            let kind = device.sourceKind.map(normalize)
            let firmware = device.firmware.map { $0.trimmingCharacters(in: .whitespaces) }
            let fields = [
                "pc-regime-1", vendor, family ?? "unknown", kind ?? "unknown", firmware ?? "unknown", placement,
                method.id, method.algorithmVersion, method.aggregation.rawValue, windowClass(method), method.units,
            ]
            return MeasurementRegime(key: PhysiologyContext.fnv1a(fields.joined(separator: "\u{1f}")),
                                     vendor: vendor, deviceFamily: family, sourceKind: kind, firmware: firmware,
                                     placement: placement, placementSource: source, methodId: method.id,
                                     algorithmVersion: method.algorithmVersion, aggregation: method.aggregation,
                                     windowS: method.windowS, units: method.units,
                                     decoderVersion: device.decoderVersion)
        }

        /// Session and day aggregates are keyed by their aggregation class (a night is one unit whatever its
        /// length); every other aggregation is keyed by its exact window length.
        static func windowClass(_ method: MethodRef) -> String {
            switch method.aggregation {
            case .session, .day: return method.aggregation.rawValue
            default: return String(method.windowS)
            }
        }

        static func windowClass(_ r: MeasurementRegime) -> String {
            switch r.aggregation {
            case .session, .day: return r.aggregation.rawValue
            default: return String(r.windowS)
            }
        }

        /// Whether two regimes may be pooled into one reference, and under which documented rule.
        ///
        /// Rule: identical regime key ⇒ comparable (`identical_regime`; `identical_regime_session_length_varies`
        /// when two session/day aggregates differ only in length; `identical_regime_decoder_differs` when both
        /// decoder versions are known and differ — the decoder is not part of the key, see notes/signal.md).
        /// Anything else is incompatible with every differing attribute named. No pooling across vendor,
        /// placement, method, algorithm version, aggregation, window or units.
        public static func comparability(_ a: MeasurementRegime, _ b: MeasurementRegime,
                                         config: ValidityConfig) -> RegimeComparability {
            if a.key == b.key {
                if let da = a.decoderVersion, let db = b.decoderVersion, da != db {
                    return .comparable(rule: "identical_regime_decoder_differs")
                }
                if a.windowS != b.windowS { return .comparable(rule: "identical_regime_session_length_varies") }
                return .comparable(rule: "identical_regime")
            }
            var reasons: [ReasonCode] = []
            func compare(_ x: String?, _ y: String?, differs: ReasonCode, unknown: ReasonCode) {
                guard x != y else { return }
                reasons.append(x == nil || y == nil ? unknown : differs)
            }
            if a.vendor != b.vendor { reasons.append(vendorDiffers) }
            compare(a.deviceFamily, b.deviceFamily, differs: deviceFamilyDiffers, unknown: deviceFamilyUnknown)
            compare(a.sourceKind, b.sourceKind, differs: sourceKindDiffers, unknown: sourceKindUnknown)
            compare(a.firmware, b.firmware, differs: firmwareDiffers, unknown: firmwareUnknown)
            if a.placement != b.placement {
                if a.placement == "mixed" || b.placement == "mixed" { reasons.append(placementMixed) }
                else if a.placement == "unknown" || b.placement == "unknown" { reasons.append(placementUnknown) }
                else { reasons.append(placementDiffers) }
            }
            if a.methodId != b.methodId { reasons.append(methodDiffers) }
            if a.algorithmVersion != b.algorithmVersion { reasons.append(algorithmVersionDiffers) }
            if a.aggregation != b.aggregation { reasons.append(aggregationDiffers) }
            else if windowClass(a) != windowClass(b) { reasons.append(windowDiffers) }
            if a.units != b.units { reasons.append(unitsDiffers) }
            if reasons.isEmpty { reasons.append(regimeKeyDiffers) }
            return .incompatible(reasons: reasons)
        }

        // MARK: - Availability matrix

        /// The availability / comparability matrix for every metric and source in the input. In causal mode only
        /// measurements available at the cutoff are listed (the same filter the engine applies).
        public static func availabilityMatrix(_ input: DayInput, observations o: SanitizedObservations,
                                              config: ValidityConfig) -> [AvailabilityEntry] {
            var rows: [AvailabilityEntry] = []
            let hasHR = !o.heartRate.isEmpty
            let rr = o.beatIntervals

            // Heart rate.
            // Target-dependent screens are declared on the rows of the assessments that apply them (spec §8:
            // a necessary target-dependent quality gate is declared and evaluated for selection bias).
            for metric in [MetricKind.heartRate, .restingHeartRate] {
                rows.append(AvailabilityEntry(metric: metric, assessment: "\(metric.rawValue)_signal_validity",
                                              source: "strap_heart_rate", state: hasHR ? .supported : .unavailable,
                                              comparability: "identical_regime_only",
                                              reasons: (hasHR ? [] : [noHeartRateSamples]) + [gateHrPlausibleBand]))
            }

            // Beat intervals: day-level over-count and beat-accuracy screens.
            var rrState: AvailabilityState = .unavailable
            var rrReasons: [ReasonCode] = rr.isEmpty ? [noBeatIntervals] : []
            if !rr.isEmpty {
                let ts = rr.map(\.ts), ms = rr.map { Double($0.rrMs) }
                let verdict = HRVAnalyzer.classifyCoverage(coverage: HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: ms),
                                                           collapsed: HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: ms))
                rrState = .supported
                switch verdict {
                case .sameSecondOverCount: rrState = .partial; rrReasons.append(rrOverCountSameSecond)
                case .crossSecondOverCount: rrState = .partial; rrReasons.append(rrOverCountCrossSecond)
                default: break
                }
                if !HRVAnalyzer.beatValuesAreTrustworthy(
                    beatAccurateFraction: HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: ms)) {
                    rrState = .partial; rrReasons.append(beatValuesUntrustworthy)
                }
            }
            let hrvGates = [gateRrKernelRange, gateEctopicRejection]
            rows.append(AvailabilityEntry(metric: .hrvRmssd, assessment: "hrv_signal_validity",
                                          source: "strap_rr_intervals", state: rrState,
                                          comparability: "identical_regime_only", reasons: rrReasons + hrvGates))
            rows.append(AvailabilityEntry(metric: .hrvSdnn, assessment: "hrv_signal_validity",
                                          source: "strap_rr_intervals", state: rrState,
                                          comparability: "identical_window_length_only",
                                          reasons: rrReasons + [windowLengthDependent] + hrvGates))
            rows.append(AvailabilityEntry(metric: .respiratoryRate, assessment: "respiratory_signal_validity",
                                          source: "strap_rr_intervals_rsa", state: rrState,
                                          comparability: "identical_regime_only", reasons: rrReasons + [rsaOnlyEstimate]))

            // Skin temperature.
            let skin = o.skinTemperature
            let inBand = skin.contains { s in s.celsius.map { $0 >= config.skinWornMinC && $0 <= config.skinWornMaxC } ?? false }
            let skinState: AvailabilityState = skin.isEmpty ? .unavailable : (inBand ? .supported : .partial)
            var skinReasons: [ReasonCode] = [skinNotCoreTemperature]
            if skin.isEmpty { skinReasons.insert(noSkinTemperatureSamples, at: 0) }
            else if !inBand { skinReasons.insert(noInBandSamples, at: 0) }
            rows.append(AvailabilityEntry(metric: .skinTemperature, assessment: "skin_temperature_signal_validity",
                                          source: "strap_skin_temperature", state: skinState,
                                          comparability: "relative_within_regime_only", reasons: skinReasons))
            rows.append(AvailabilityEntry(metric: nil, assessment: "core_temperature", source: "none",
                                          state: .unsupported, comparability: "not_applicable",
                                          reasons: [noCoreTemperatureSensor]))
            rows.append(AvailabilityEntry(metric: .spo2Candidate, assessment: "spo2_signal_validity",
                                          source: "strap_spo2_candidate_byte", state: .unverified,
                                          comparability: "excluded_from_comparisons",
                                          reasons: [unverifiedStrapEstimate, excludedFromComparisons]))
            rows.append(AvailabilityEntry(metric: nil, assessment: "ppg_waveform_quality", source: "none",
                                          state: .unsupported, comparability: "not_applicable",
                                          reasons: [noQualifiedWaveform]))
            let hasVector = o.motion.contains { $0.x != nil }
            rows.append(AvailabilityEntry(metric: nil, assessment: "posture", source: "strap_gravity_orientation",
                                          state: hasVector ? .unverified : .unavailable, comparability: "not_applicable",
                                          reasons: hasVector ? [wristOrientationLikelihoodOnly]
                                                             : [noGravityVector, wristOrientationLikelihoodOnly]))

            // Activity sources.
            let hasEpochs = !input.activityEpochs.isEmpty
            rows.append(AvailabilityEntry(metric: nil, assessment: "activity_composition",
                                          source: ActivitySource.hartEpochs.rawValue,
                                          state: hasEpochs ? .supported : .unavailable, comparability: "not_applicable",
                                          reasons: hasEpochs ? [heartRateIndependentSource]
                                                             : [noSourceRecords, heartRateIndependentSource]))
            let strap = MotionEvidence.strapEvidence(motion: o.motion, steps: o.steps, window: readWindow(input.identity),
                                                     config: MotionEvidenceConfig())
            let hasStrap = !strap.track.spans.isEmpty
            var strapReasons: [ReasonCode] = [heartRateIndependentSource]
            strapReasons += strap.reasons.filter { $0 != MotionEvidence.noMotionSamples }
            if !o.steps.isEmpty { strapReasons.append(stepCounterPresent) }
            if !hasStrap { strapReasons.insert(MotionEvidence.noMotionSamples, at: 0) }
            rows.append(AvailabilityEntry(metric: nil, assessment: "activity_composition",
                                          source: ActivitySource.strapMotion.rawValue,
                                          state: hasStrap ? .supported : .unavailable, comparability: "not_applicable",
                                          reasons: strapReasons))
            let hasDecoder = !input.activityIntervals.isEmpty
            rows.append(AvailabilityEntry(metric: nil, assessment: "activity_composition",
                                          source: ActivitySource.decoderIntervals.rawValue,
                                          state: hasDecoder ? .supported : .unavailable, comparability: "not_applicable",
                                          reasons: (hasDecoder ? [] : [noSourceRecords])
                                            + [IntervalAlgebra.heartRateDependentSource, displayOnly]))

            // Eligibility evidence.
            let hasActivity = hasEpochs || hasStrap
            let hasSleep = !input.sleepSessions.isEmpty || !o.bandSleepStates.isEmpty
            let hasWear = !o.wearEvents.isEmpty || hasHR
            var awakeReasons: [ReasonCode] = []
            var awakeState: AvailabilityState = .partial
            if !hasActivity { awakeReasons.append(Engine.activityUnavailable) }
            if !hasSleep { awakeReasons.append(awakeEvidenceUnavailable) }
            if !hasWear { awakeReasons.append(wearEvidenceUnavailable) }
            if !awakeReasons.isEmpty { awakeState = .unavailable }
            if !input.sleepSessions.isEmpty {
                awakeReasons.append(sleepDetectorUsesHeartRate)
                awakeReasons.append(gateSleepDetectorHrConfirmation)
            }
            if o.wearEvents.isEmpty && hasHR { awakeReasons.append(wearFromHeartRateSignal) }
            rows.append(AvailabilityEntry(metric: nil, assessment: "stable_awake_eligibility", source: "context_layer",
                                          state: awakeState, comparability: "not_applicable", reasons: awakeReasons))
            var sleepReasons: [ReasonCode] = []
            if input.sleepSessions.isEmpty { sleepReasons.append(sleepEvidenceUnavailable) }
            else { sleepReasons += [sleepDetectorUsesHeartRate, gateSleepDetectorHrConfirmation] }
            rows.append(AvailabilityEntry(metric: nil, assessment: "sleep_measurement_eligibility",
                                          source: "detected_sleep_sessions",
                                          state: input.sleepSessions.isEmpty ? .unavailable : .partial,
                                          comparability: "not_applicable", reasons: sleepReasons))
            rows.append(AvailabilityEntry(metric: nil, assessment: "activity_response_eligibility",
                                          source: "context_layer",
                                          state: hasActivity || !input.workouts.isEmpty ? .supported : .unavailable,
                                          comparability: "not_applicable",
                                          reasons: hasActivity || !input.workouts.isEmpty ? [heartRateIndependentSource]
                                                                                          : [Engine.activityUnavailable]))

            // Measurement products present (available at the cutoff in causal mode).
            let causal = input.mode == .causalLive
            let cutoff = input.availabilityCutoff
            var products: [String: (MetricKind, SourceProduct, String)] = [:]
            for m in input.measurements {
                if causal && (m.support.end > cutoff || !(m.availableAt.map { $0 <= cutoff } ?? true)) { continue }
                products["\(m.metric.rawValue)|\(m.source.product.rawValue)|\(m.method.id)"] =
                    (m.metric, m.source.product, m.method.id)
            }
            for key in products.keys.sorted() {
                let (metric, product, method) = products[key]!
                let spo2 = metric == .spo2Candidate
                rows.append(AvailabilityEntry(metric: metric, assessment: "measurement_product",
                                              source: "\(product.rawValue):\(method)",
                                              state: spo2 ? .unverified : .supported,
                                              comparability: comparabilityRule(metric),
                                              reasons: spo2 ? [unverifiedStrapEstimate, excludedFromComparisons] : []))
            }
            return rows
        }

        static func comparabilityRule(_ metric: MetricKind) -> String {
            switch metric {
            case .hrvSdnn: return "identical_window_length_only"
            case .skinTemperature: return "relative_within_regime_only"
            case .spo2Candidate: return "excluded_from_comparisons"
            default: return "identical_regime_only"
            }
        }

        // MARK: - Helpers

        static func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        /// Elements of a `ts`-sorted array inside `[interval.start, interval.end)` (binary search).
        static func slice<T>(_ a: [T], _ interval: Interval, _ ts: (T) -> Int) -> ArraySlice<T> {
            let lo = lowerBound(a, interval.start, ts)
            let hi = lowerBound(a, interval.end, ts)
            return a[lo..<max(lo, hi)]
        }

        static func lowerBound<T>(_ a: [T], _ value: Int, _ ts: (T) -> Int) -> Int {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ts(a[mid]) < value { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        /// True when a break in the sorted, merged `breaks` intersects the closed span `[a, b]`.
        static func breakTouches(_ breaks: [Interval], _ a: Int, _ b: Int) -> Bool {
            guard !breaks.isEmpty else { return false }
            // First break whose end is after `a` (ends ascend because breaks are merged and sorted).
            var lo = 0, hi = breaks.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if breaks[mid].end <= a { lo = mid + 1 } else { hi = mid }
            }
            return lo < breaks.count && breaks[lo].start <= b
        }

        static func breaksInside(_ breaks: [Interval], _ support: Interval) -> Int {
            breaks.reduce(0) { $0 + ($1.overlapSeconds(with: support) > 0 ? 1 : 0) }
        }

        static func distinctCount(_ sortedTs: [Int]) -> Int {
            var n = 0
            var last: Int? = nil
            for t in sortedTs where t != last { n += 1; last = t }
            return n
        }

        static func mergedUniqueTimes(_ lists: [Int]...) -> [Int] {
            var all: [Int] = []
            for l in lists { all += l }
            all.sort()
            var out: [Int] = []
            out.reserveCapacity(all.count)
            for t in all where out.last != t { out.append(t) }
            return out
        }

        /// `interval` minus the sorted, merged `holes`.
        static func subtract(_ holes: [Interval], from interval: Interval) -> [Interval] {
            var out: [Interval] = []
            var cursor = interval.start
            for h in holes where h.end > cursor && h.start < interval.end {
                if h.start > cursor { out.append(Interval(cursor, h.start)) }
                cursor = max(cursor, h.end)
            }
            if cursor < interval.end { out.append(Interval(cursor, interval.end)) }
            return out
        }

        static func mergeIntervals(_ list: [Interval]) -> [Interval] {
            let sorted = list.filter(\.isValid).sorted()
            var out: [Interval] = []
            for iv in sorted {
                if var last = out.last, iv.start <= last.end {
                    last.end = max(last.end, iv.end)
                    out[out.count - 1] = last
                } else {
                    out.append(iv)
                }
            }
            return out
        }
    }
}
