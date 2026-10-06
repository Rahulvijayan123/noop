import Foundation

// PCContract.swift — the shared contract of the physiology context layer (docs/physiology-context/contracts.md).
//
// The layer attaches measurement conditions, recent history, exposures and physiological responses to the
// measurements Nara already publishes. It never replaces a canonical metric: every value it carries points back at
// the product it came from (`SourceRef`), and its own comparisons are named context-conditioned products.
//
// Everything here is a pure value type. The engine (`PhysiologyContext.Engine`) is deterministic for a given
// `DayInput`, `HistoryInput` and `Policy`, so the worker, the app and the tests produce byte-identical documents
// from the same inputs (encode with `PhysiologyContext.encoder()`).
//
// STATES ARE NOT INTERCHANGEABLE. Unknown (could not be determined), missing (no input), ineligible (determined and
// failed), invalid (signal failed quality), unverified (exists but validity not established), unsupported (no
// qualified input exists) and explicitly absent (e.g. a journal "no") are separate values everywhere. A missing
// journal entry is never "no exposure", a missing metric is never zero, an uncovered second is never sedentary.
//
// JSON. Types encode with `.convertToSnakeCase` and sorted keys. To keep that lossless, Codable types in this layer
// use camelCase property names without consecutive capitals and never encode a Swift dictionary (dictionary keys
// would be re-cased on decode); keyed data uses arrays of named entries instead.

public enum PhysiologyContext {
    /// Day-document schema version (bumped on a breaking change to `DayDocument`).
    public static let schemaVersion = 1
    /// Version of this shared contract.
    public static let contractVersion = "pc-contract-1"
}

// MARK: - Time

extension PhysiologyContext {

    /// A half-open UTC interval `[start, end)` in Unix seconds.
    public struct Interval: Codable, Equatable, Hashable, Sendable, Comparable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public init(_ start: Int, _ end: Int) { self.start = start; self.end = end }

        /// Length in seconds; 0 for an empty or inverted interval.
        public var duration: Int { max(0, end - start) }
        public var isValid: Bool { end > start }
        public func contains(_ ts: Int) -> Bool { ts >= start && ts < end }
        public func overlapSeconds(with other: Interval) -> Int {
            max(0, min(end, other.end) - max(start, other.start))
        }
        public func intersection(_ other: Interval) -> Interval? {
            let lo = max(start, other.start), hi = min(end, other.end)
            return hi > lo ? Interval(lo, hi) : nil
        }
        public static func < (a: Interval, b: Interval) -> Bool {
            a.start != b.start ? a.start < b.start : a.end < b.end
        }
    }

    /// How a product was computed (spec §6.3).
    ///
    /// `causalLive` uses only observations whose sensor time is before the measurement's decision point AND whose
    /// availability time is at or before the document's `availabilityCutoff`; it never reads a later sleep end, a
    /// next-day awakening, retrospective smoothing or a later correction. `retrospective` may use the whole day,
    /// later days and later corrections. The two are stored separately and never presented as each other.
    public enum ProcessingMode: String, Codable, CaseIterable, Sendable {
        case causalLive = "causal_live"
        case retrospective
    }

    /// Whether a product can still change because its inputs are incomplete (spec §15).
    public enum Finality: String, Codable, CaseIterable, Sendable {
        case provisional
        case final
    }
}

// MARK: - Reason codes and confidence

extension PhysiologyContext {

    /// A machine-readable reason. Each system declares its codes as static constants in its own file and lists
    /// them in a `reasonCodes` array; `contracts.md` is the consolidated table.
    public struct ReasonCode: RawRepresentable, Codable, Hashable, Comparable, Sendable,
                              ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
        public var description: String { rawValue }
        public static func < (a: ReasonCode, b: ReasonCode) -> Bool { a.rawValue < b.rawValue }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    /// What kind of number a confidence is (spec §6.1). A heuristic score is not a probability.
    public enum ConfidenceKind: String, Codable, CaseIterable, Sendable {
        case heuristicScore = "heuristic_score"
        case modelScore = "model_score"
        case calibratedProbability = "calibrated_probability"
        /// No confidence is defined for this output; `value` is nil.
        case notApplicable = "not_applicable"
    }

    public struct Confidence: Codable, Equatable, Sendable, Hashable {
        public var kind: ConfidenceKind
        /// In [0, 1]; nil when `kind == .notApplicable` or the evidence was unavailable.
        public var value: Double?
        public init(kind: ConfidenceKind, value: Double?) { self.kind = kind; self.value = value }
        public static let notApplicable = Confidence(kind: .notApplicable, value: nil)
    }

    /// A named numeric diagnostic (arrays of these replace dictionaries in the JSON).
    public struct Diagnostic: Codable, Equatable, Sendable, Hashable {
        public var name: String
        public var value: Double
        public init(_ name: String, _ value: Double) { self.name = name; self.value = value }
    }
}

// MARK: - Metrics, methods and sources

extension PhysiologyContext {

    /// Physiological quantities the layer contextualizes. RMSSD, SDNN and SDNN index are different quantities even
    /// though they share a unit; the method (`MethodRef.id`/`aggregation`/`windowS`) keeps them apart.
    public enum MetricKind: String, Codable, CaseIterable, Sendable {
        case heartRate = "heart_rate"
        case hrvRmssd = "hrv_rmssd"
        case hrvSdnn = "hrv_sdnn"
        case restingHeartRate = "resting_heart_rate"
        case respiratoryRate = "respiratory_rate"
        /// Wrist skin temperature. Never core temperature.
        case skinTemperature = "skin_temperature"
        /// The documented, unverified strap SpO2 byte. Never a clinical oxygen saturation.
        case spo2Candidate = "spo2_candidate"
    }

    public enum Aggregation: String, Codable, CaseIterable, Sendable {
        case window
        case meanOverWindows = "mean_over_windows"
        case session
        case day
        case minimumOfBins = "minimum_of_bins"
        case mean
        case median
    }

    /// The method that produced a measurement: part of its measurement regime.
    public struct MethodRef: Codable, Hashable, Sendable {
        /// Stable method identifier, e.g. `series.hrv_rmssd.5min`, `snapshot.hrv_rmssd.night`.
        public var id: String
        /// Version of the producing algorithm, e.g. `frwhoop-series-2`, `frwhoop-server-1`.
        public var algorithmVersion: String
        public var aggregation: Aggregation
        /// Nominal window of one estimate in seconds (a session aggregate uses its session length).
        public var windowS: Int
        /// Original clinical units: `ms`, `bpm`, `breaths_per_min`, `degC`, `percent`.
        public var units: String

        public init(id: String, algorithmVersion: String, aggregation: Aggregation, windowS: Int, units: String) {
            self.id = id; self.algorithmVersion = algorithmVersion; self.aggregation = aggregation
            self.windowS = windowS; self.units = units
        }
    }

    public enum SourceProduct: String, Codable, CaseIterable, Sendable {
        /// A published `server_metric_series` bucket.
        case metricSeries = "metric_series"
        /// A field of a published `scoring_snapshots_v2` payload.
        case scoringSnapshot = "scoring_snapshot"
        /// Computed by this layer from raw observations (named, never a canonical field).
        case contextDerived = "context_derived"
    }

    /// Where a contextualized value came from. Context never rewrites the canonical product.
    public struct SourceRef: Codable, Hashable, Sendable {
        public var product: SourceProduct
        /// Product-specific key, e.g. `hrv_rmssd_ms@1759651200` or `daily.hrv_rmssd_ms`.
        public var key: String
        public var inputRevision: Int?
        public var resultRevision: Int?

        public init(product: SourceProduct, key: String, inputRevision: Int? = nil, resultRevision: Int? = nil) {
            self.product = product; self.key = key
            self.inputRevision = inputRevision; self.resultRevision = resultRevision
        }
    }
}

// MARK: - Raw observations (availability-aware inputs)

extension PhysiologyContext {

    /// One heart-rate sample. `availableAt` is when the observation reached storage (server `ingested_at`); nil
    /// means unknown, in which case causal processing falls back to sensor time and says so
    /// (`availability_basis_sensor_time`).
    public struct HeartRateObservation: Codable, Equatable, Sendable {
        public var ts: Int
        public var bpm: Int
        public var availableAt: Int?
        public init(ts: Int, bpm: Int, availableAt: Int? = nil) { self.ts = ts; self.bpm = bpm; self.availableAt = availableAt }
    }

    /// One R-R interval. Identity is `(ts, rrMs, seq)`: `seq` is the occurrence index of an equal value within the
    /// second, so two equal intervals in one second are two beats. Storage is whole-second; no sub-second beat time
    /// is reconstructed.
    public struct BeatIntervalObservation: Codable, Equatable, Sendable {
        public var ts: Int
        public var rrMs: Int
        public var seq: Int
        /// Position within the second when the transport recorded it.
        public var ord: Int?
        /// `RRSourceChannel` raw value when known.
        public var channel: Int?
        public var availableAt: Int?
        public init(ts: Int, rrMs: Int, seq: Int = 0, ord: Int? = nil, channel: Int? = nil, availableAt: Int? = nil) {
            self.ts = ts; self.rrMs = rrMs; self.seq = seq; self.ord = ord; self.channel = channel
            self.availableAt = availableAt
        }
    }

    /// One gravity / dynamic-acceleration sample (heart-rate independent motion evidence).
    public struct MotionObservation: Codable, Equatable, Sendable {
        public var ts: Int
        /// Gravity-removed motion magnitude in g, when the strap reports it.
        public var dynAccelG: Double?
        public var x: Double?
        public var y: Double?
        public var z: Double?
        public var availableAt: Int?
        public init(ts: Int, dynAccelG: Double?, x: Double? = nil, y: Double? = nil, z: Double? = nil,
                    availableAt: Int? = nil) {
            self.ts = ts; self.dynAccelG = dynAccelG; self.x = x; self.y = y; self.z = z
            self.availableAt = availableAt
        }
    }

    /// One strap step-counter sample (WHOOP 5.0/MG). `counter` wraps at 65536.
    public struct StepObservation: Codable, Equatable, Sendable {
        public var ts: Int
        public var counter: Int
        public var activityClass: Int?
        public var availableAt: Int?
        public init(ts: Int, counter: Int, activityClass: Int? = nil, availableAt: Int? = nil) {
            self.ts = ts; self.counter = counter; self.activityClass = activityClass; self.availableAt = availableAt
        }
    }

    /// One converted skin-temperature sample.
    public struct SkinTemperatureObservation: Codable, Equatable, Sendable {
        public var ts: Int
        public var celsius: Double?
        public var availableAt: Int?
        public init(ts: Int, celsius: Double?, availableAt: Int? = nil) {
            self.ts = ts; self.celsius = celsius; self.availableAt = availableAt
        }
    }

    public enum WearEventState: String, Codable, CaseIterable, Sendable {
        case offWrist = "off_wrist"
        case onWrist = "on_wrist"
    }

    /// A strap wrist on/off event (`noop_events` WRIST_OFF* / WRIST_ON*).
    public struct WearEventObservation: Codable, Equatable, Sendable {
        public var ts: Int
        public var state: WearEventState
        public var kind: String
        public var availableAt: Int?
        public init(ts: Int, state: WearEventState, kind: String, availableAt: Int? = nil) {
            self.ts = ts; self.state = state; self.kind = kind; self.availableAt = availableAt
        }
    }

    /// One sample of the strap's own band sleep state (vendor-derived; its inputs are not documented).
    public struct BandSleepStateObservation: Codable, Equatable, Sendable {
        public var ts: Int
        public var state: Int
        public var availableAt: Int?
        public init(ts: Int, state: Int, availableAt: Int? = nil) {
            self.ts = ts; self.state = state; self.availableAt = availableAt
        }
    }
}

// MARK: - Context records (inputs produced by other engines)

extension PhysiologyContext {

    /// A measurement to contextualize, read from a published product.
    public struct MeasurementInput: Codable, Equatable, Sendable {
        public var metric: MetricKind
        public var method: MethodRef
        public var source: SourceRef
        /// Value in original units; nil when the product published no value (kept as missing, never zero).
        public var value: Double?
        /// The actual support interval of the estimate (e.g. a trailing 2-minute respiratory window).
        public var support: Interval
        /// The display bucket the value is drawn in, when different from `support`.
        public var displayBucket: Interval?
        public var sampleCount: Int?
        public var coverage: Double?
        /// When the value was first computable; nil when unknown.
        public var availableAt: Int?
        /// Sleep session id when the support is a sleep session.
        public var sessionId: String?

        public init(metric: MetricKind, method: MethodRef, source: SourceRef, value: Double?, support: Interval,
                    displayBucket: Interval? = nil, sampleCount: Int? = nil, coverage: Double? = nil,
                    availableAt: Int? = nil, sessionId: String? = nil) {
            self.metric = metric; self.method = method; self.source = source; self.value = value
            self.support = support; self.displayBucket = displayBucket; self.sampleCount = sampleCount
            self.coverage = coverage; self.availableAt = availableAt; self.sessionId = sessionId
        }
    }

    public struct StageSpan: Codable, Equatable, Sendable {
        public var interval: Interval
        /// `wake` | `light` | `deep` | `rem` (unverified staging; never a mandatory condition).
        public var stage: String
        public init(interval: Interval, stage: String) { self.interval = interval; self.stage = stage }
    }

    /// A detected sleep session from a published scoring snapshot.
    public struct SleepSessionInput: Codable, Equatable, Sendable {
        public var id: String
        public var interval: Interval
        /// The scorer's own nap flag when it published one.
        public var isNap: Bool?
        public var efficiency: Double?
        /// Staged from heart rate alone (no motion spine).
        public var hrOnly: Bool?
        public var stages: [StageSpan]
        /// When the session (with this end) was first published; nil when unknown.
        public var availableAt: Int?
        /// The local day whose snapshot published it.
        public var sourceDay: String?
        /// Producing detector version.
        public var detector: String
        /// The publishing snapshot's `dataThrough` (Unix seconds): how far the detector had data when it ran.
        public var dataThrough: Int?
        /// The zone the publishing snapshot interpreted its day in.
        public var timezoneId: String?

        public init(id: String, interval: Interval, isNap: Bool? = nil, efficiency: Double? = nil,
                    hrOnly: Bool? = nil, stages: [StageSpan] = [], availableAt: Int? = nil,
                    sourceDay: String? = nil, detector: String, dataThrough: Int? = nil, timezoneId: String? = nil) {
            self.id = id; self.interval = interval; self.isNap = isNap; self.efficiency = efficiency
            self.hrOnly = hrOnly; self.stages = stages; self.availableAt = availableAt
            self.sourceDay = sourceDay; self.detector = detector
            self.dataThrough = dataThrough; self.timezoneId = timezoneId
        }
    }

    /// A logged or detected workout.
    public struct WorkoutInput: Codable, Equatable, Sendable {
        public var id: String
        public var interval: Interval
        public var kind: String?
        /// `detected` | `manual` | `imported`.
        public var source: String
        public var availableAt: Int?
        public init(id: String, interval: Interval, kind: String? = nil, source: String, availableAt: Int? = nil) {
            self.id = id; self.interval = interval; self.kind = kind; self.source = source
            self.availableAt = availableAt
        }
    }

    /// A v1 HART activity epoch (heart-rate independent), with the publishing revision.
    public struct ActivityEpochInput: Codable, Equatable, Sendable {
        public var epoch: ActivityEpoch
        public var revision: Int
        public var availableAt: Int?
        public init(epoch: ActivityEpoch, revision: Int, availableAt: Int? = nil) {
            self.epoch = epoch; self.revision = revision; self.availableAt = availableAt
        }
    }

    /// A v2 decoder interval. The v2 decoder reads heart rate, so anything derived from it is flagged
    /// heart-rate dependent and never used as independent evidence for a heart-rate-derived metric.
    public struct ActivityIntervalInput: Codable, Equatable, Sendable {
        public var interval: Interval
        public var activityClass: String
        public var confidence: Double
        public var locomotion: String?
        public var posture: String?
        public var sleep: String?
        public var wear: String?
        public var revision: Int
        public var availableAt: Int?
        public init(interval: Interval, activityClass: String, confidence: Double, locomotion: String? = nil,
                    posture: String? = nil, sleep: String? = nil, wear: String? = nil, revision: Int,
                    availableAt: Int? = nil) {
            self.interval = interval; self.activityClass = activityClass; self.confidence = confidence
            self.locomotion = locomotion; self.posture = posture; self.sleep = sleep; self.wear = wear
            self.revision = revision; self.availableAt = availableAt
        }
    }

    /// An effective-dated placement record (`placement_intervals`). `end == nil` means open-ended.
    public struct PlacementInput: Codable, Equatable, Sendable {
        public var start: Int
        public var end: Int?
        /// `wrist` | `bicep` | `other` | `unknown`.
        public var placement: String
        /// `user` | `device`.
        public var source: String
        public var revision: Int
        public var recordedAt: Int?
        /// `device` (the record names this device) or `account` (a user-level record with no device). nil = device.
        /// A device-scoped record wins over an account-level one where they overlap (the app's rule,
        /// `Placement.swift`).
        public var scope: String?
        public init(start: Int, end: Int?, placement: String, source: String, revision: Int, recordedAt: Int? = nil,
                    scope: String? = nil) {
            self.start = start; self.end = end; self.placement = placement; self.source = source
            self.revision = revision; self.recordedAt = recordedAt; self.scope = scope
        }
    }

    /// Device and processing attributes that define a measurement regime.
    public struct DeviceRegimeInput: Codable, Equatable, Sendable {
        public var vendor: String
        public var deviceFamily: String?
        public var sourceKind: String?
        public var firmware: String?
        public var decoderVersion: String?
        public var scoringAlgorithmVersion: String
        public var seriesAlgorithmVersion: String?
        public init(vendor: String = "whoop", deviceFamily: String? = nil, sourceKind: String? = nil,
                    firmware: String? = nil, decoderVersion: String? = nil,
                    scoringAlgorithmVersion: String, seriesAlgorithmVersion: String? = nil) {
            self.vendor = vendor; self.deviceFamily = deviceFamily; self.sourceKind = sourceKind
            self.firmware = firmware; self.decoderVersion = decoderVersion
            self.scoringAlgorithmVersion = scoringAlgorithmVersion; self.seriesAlgorithmVersion = seriesAlgorithmVersion
        }
    }
}

// MARK: - Exposure events (System E inputs)

extension PhysiologyContext {

    public enum ExposureKind: String, Codable, CaseIterable, Sendable {
        case medication, supplement, caffeine, alcohol, meal, heat, travel, symptom, other
    }

    public enum ExposureSource: String, Codable, CaseIterable, Sendable {
        /// Entered by the person with a time.
        case userEntered = "user_entered"
        /// A day-granular journal answer (time known only to the local day).
        case journalDayAnswer = "journal_day_answer"
        /// Imported from another system (e.g. HealthKit).
        case imported
        /// Proposed by software; never treated as confirmed.
        case inferredCandidate = "inferred_candidate"
    }

    public enum ExposureConfirmation: String, Codable, CaseIterable, Sendable {
        case confirmed
        /// Explicitly did not occur (a journal "no").
        case denied
        /// Inferred, not confirmed by the person.
        case candidate
        /// Withdrawn by a later revision (a delete). Kept in history; excluded from current state.
        case retracted
    }

    public enum TimePrecision: String, Codable, CaseIterable, Sendable {
        case exact
        case approximate
        /// Only the local day is known; `occurred` spans that day.
        case dayOnly = "day_only"
    }

    /// One immutable revision of an exposure event. An edit is a new revision of the same `eventId`; a delete is a
    /// `retracted` revision. Occurrence time (`occurred`) and availability (`receivedAt`, else `recordedAt`) are
    /// distinct: a late entry describes the past but was not available to an earlier live decision.
    public struct ExposureEventRevision: Codable, Equatable, Sendable {
        public var eventId: String
        public var revision: Int
        public var kind: ExposureKind
        /// Event label (medication name, journal question canonical key, ...).
        public var label: String
        /// When it happened: `[t, t+1)` for an exact point, a wider range when uncertain.
        public var occurred: Interval
        public var timePrecision: TimePrecision
        /// When the person entered this revision (client clock).
        public var recordedAt: Int
        /// When the server received it; the availability time for causal processing.
        public var receivedAt: Int?
        public var source: ExposureSource
        public var confirmation: ExposureConfirmation
        public var doseAmount: Double?
        public var doseUnit: String?
        /// `user_entered` | `imported` | `catalog_default`.
        public var doseProvenance: String?

        public init(eventId: String, revision: Int, kind: ExposureKind, label: String, occurred: Interval,
                    timePrecision: TimePrecision, recordedAt: Int, receivedAt: Int? = nil,
                    source: ExposureSource, confirmation: ExposureConfirmation,
                    doseAmount: Double? = nil, doseUnit: String? = nil, doseProvenance: String? = nil) {
            self.eventId = eventId; self.revision = revision; self.kind = kind; self.label = label
            self.occurred = occurred; self.timePrecision = timePrecision; self.recordedAt = recordedAt
            self.receivedAt = receivedAt; self.source = source; self.confirmation = confirmation
            self.doseAmount = doseAmount; self.doseUnit = doseUnit; self.doseProvenance = doseProvenance
        }

        /// The time this revision became available: server receipt when known, else the entry time.
        public var availableAt: Int { receivedAt ?? recordedAt }
    }
}

// MARK: - Engine input

extension PhysiologyContext {

    public struct DayIdentity: Codable, Equatable, Sendable {
        /// Opaque device scope (the canonical device id). Never an account id.
        public var deviceScope: String
        /// Local day key `yyyy-MM-dd`.
        public var day: String
        /// IANA zone the day is interpreted in.
        public var timezoneId: String
        /// `[local midnight, next local midnight)` in UTC (23 h / 25 h on DST days).
        public var dayWindow: Interval
        public init(deviceScope: String, day: String, timezoneId: String, dayWindow: Interval) {
            self.deviceScope = deviceScope; self.day = day; self.timezoneId = timezoneId; self.dayWindow = dayWindow
        }
    }

    /// Revision of one input the document depends on (spec §6.3 revision dependencies).
    public struct InputRevision: Codable, Equatable, Hashable, Sendable {
        /// `scoring_snapshot`, `metric_series`, `activity_epochs`, `activity_days`, `placement`, `exposures`,
        /// `history_daily_values`, `frozen_references`, ...
        public var input: String
        public var revision: String
        public init(input: String, revision: String) { self.input = input; self.revision = revision }
    }

    /// Everything the engine reads for one device-day. Raw streams cover `[dayWindow.start - 30 h,
    /// dayWindow.end + 6 h)` (the scoring night window) when available; the engine clips by mode and cutoff.
    public struct DayInput: Codable, Equatable, Sendable {
        public var identity: DayIdentity
        public var mode: ProcessingMode
        /// Unix seconds. Causal: observations with `availableAt > cutoff` or `ts >= cutoff` are not used.
        public var availabilityCutoff: Int
        public var generatedAt: Int

        public var heartRate: [HeartRateObservation]
        public var beatIntervals: [BeatIntervalObservation]
        public var motion: [MotionObservation]
        public var steps: [StepObservation]
        public var skinTemperature: [SkinTemperatureObservation]
        public var wearEvents: [WearEventObservation]
        public var bandSleepStates: [BandSleepStateObservation]

        public var measurements: [MeasurementInput]
        /// Sleep sessions for this day and the preceding nights in the read window.
        public var sleepSessions: [SleepSessionInput]
        public var workouts: [WorkoutInput]
        public var activityEpochs: [ActivityEpochInput]
        public var activityIntervals: [ActivityIntervalInput]
        public var placements: [PlacementInput]
        public var regime: DeviceRegimeInput
        /// All revisions of exposure events overlapping the exposure read window.
        public var exposures: [ExposureEventRevision]
        public var inputRevisions: [InputRevision]

        public init(identity: DayIdentity, mode: ProcessingMode, availabilityCutoff: Int, generatedAt: Int,
                    heartRate: [HeartRateObservation] = [], beatIntervals: [BeatIntervalObservation] = [],
                    motion: [MotionObservation] = [], steps: [StepObservation] = [],
                    skinTemperature: [SkinTemperatureObservation] = [], wearEvents: [WearEventObservation] = [],
                    bandSleepStates: [BandSleepStateObservation] = [], measurements: [MeasurementInput] = [],
                    sleepSessions: [SleepSessionInput] = [], workouts: [WorkoutInput] = [],
                    activityEpochs: [ActivityEpochInput] = [], activityIntervals: [ActivityIntervalInput] = [],
                    placements: [PlacementInput] = [], regime: DeviceRegimeInput,
                    exposures: [ExposureEventRevision] = [], inputRevisions: [InputRevision] = []) {
            self.identity = identity; self.mode = mode; self.availabilityCutoff = availabilityCutoff
            self.generatedAt = generatedAt; self.heartRate = heartRate; self.beatIntervals = beatIntervals
            self.motion = motion; self.steps = steps; self.skinTemperature = skinTemperature
            self.wearEvents = wearEvents; self.bandSleepStates = bandSleepStates; self.measurements = measurements
            self.sleepSessions = sleepSessions; self.workouts = workouts; self.activityEpochs = activityEpochs
            self.activityIntervals = activityIntervals; self.placements = placements; self.regime = regime
            self.exposures = exposures; self.inputRevisions = inputRevisions
        }
    }

    /// History the engine reads from earlier products. Every element must come from a day strictly before
    /// `DayInput.identity.day` (enforced by the engine: later elements are dropped and reported).
    public struct HistoryInput: Codable, Equatable, Sendable {
        /// Context-conditioned daily values of earlier days (same mode), any regime.
        public var dailyValues: [DailyValue]
        /// Exertion bouts of earlier days, for 24/48/72 h exertion history and matched-bout references.
        public var bouts: [ExertionBout]
        /// Frozen references already registered for this device.
        public var frozenReferences: [FrozenReference]
        /// Sleep sessions of earlier days (for recent sleep loss and timing change; 14 nights by default).
        public var priorSleep: [SleepSessionInput]
        public init(dailyValues: [DailyValue] = [], bouts: [ExertionBout] = [],
                    frozenReferences: [FrozenReference] = [], priorSleep: [SleepSessionInput] = []) {
            self.dailyValues = dailyValues; self.bouts = bouts; self.frozenReferences = frozenReferences
            self.priorSleep = priorSleep
        }
        public static let empty = HistoryInput()
    }
}

// MARK: - Envelope (the per-measurement context)

extension PhysiologyContext {

    /// Context attached to one measurement over its whole support interval (spec §6.1).
    public struct MeasurementEnvelope: Codable, Equatable, Sendable {
        /// Deterministic: `<method.id>@<support.start>-<support.end>`.
        public var id: String
        public var metric: MetricKind
        public var method: MethodRef
        public var source: SourceRef
        public var value: Double?

        public var support: Interval
        public var displayBucket: Interval?
        /// Local-time interpretation of the support start.
        public var localTime: LocalTimeRef

        public var validity: SignalValidity
        /// Key into `DayDocument.regimes.registry` (the full regime is stored once per document).
        public var regimeKey: String
        /// Heart-rate independent composition (HART epochs, else strap motion) over the whole support.
        public var activity: ActivityComposition
        /// v2 decoder composition when available. It reads heart rate: display and audit only, never used as
        /// eligibility evidence for a heart-rate-derived metric.
        public var decoderActivity: ActivityComposition?
        public var preceding: PrecedingHistory
        public var sleepWear: SleepWearContext
        public var history: HistoryContext
        public var eligibility: [EligibilityVerdict]
        /// Filled for measurements that are themselves daily context-conditioned values (nightly products).
        public var comparisons: [ReferenceComparison]
        public var finality: Finality

        public init(id: String, metric: MetricKind, method: MethodRef, source: SourceRef, value: Double?,
                    support: Interval, displayBucket: Interval?, localTime: LocalTimeRef,
                    validity: SignalValidity, regimeKey: String, activity: ActivityComposition,
                    decoderActivity: ActivityComposition?, preceding: PrecedingHistory,
                    sleepWear: SleepWearContext, history: HistoryContext,
                    eligibility: [EligibilityVerdict], comparisons: [ReferenceComparison], finality: Finality) {
            self.id = id; self.metric = metric; self.method = method; self.source = source; self.value = value
            self.support = support; self.displayBucket = displayBucket; self.localTime = localTime
            self.validity = validity; self.regimeKey = regimeKey; self.activity = activity
            self.decoderActivity = decoderActivity; self.preceding = preceding
            self.sleepWear = sleepWear; self.history = history; self.eligibility = eligibility
            self.comparisons = comparisons; self.finality = finality
        }

        public func verdict(_ kind: ComparisonKind) -> EligibilityVerdict? {
            eligibility.first { $0.comparison == kind }
        }

        public static func makeId(method: MethodRef, support: Interval) -> String {
            "\(method.id)@\(support.start)-\(support.end)"
        }
    }

    /// Local wall-clock interpretation of an instant, with the zone that produced it.
    public struct LocalTimeRef: Codable, Equatable, Sendable, Hashable {
        public var timezoneId: String
        public var utcOffsetS: Int
        /// `yyyy-MM-dd` local day containing the instant.
        public var localDay: String
        /// Seconds after local midnight.
        public var secondsOfDay: Int
        public init(timezoneId: String, utcOffsetS: Int, localDay: String, secondsOfDay: Int) {
            self.timezoneId = timezoneId; self.utcOffsetS = utcOffsetS
            self.localDay = localDay; self.secondsOfDay = secondsOfDay
        }
    }

    // MARK: Activity (join semantics, spec §6.2; implemented in PCIntervalAlgebra.swift)

    /// Which evidence an activity composition was built from.
    public enum ActivitySource: String, Codable, CaseIterable, Sendable {
        /// v1 HART epochs (IMU only, heart-rate independent).
        case hartEpochs = "hart_epochs"
        /// Strap gravity / dynamic acceleration and step counter (heart-rate independent).
        case strapMotion = "strap_motion"
        /// v2 decoder intervals (reads heart rate; flagged dependent).
        case decoderIntervals = "decoder_intervals"
        case none
    }

    /// Duration of one label inside an interval.
    public struct LabelShare: Codable, Equatable, Sendable, Hashable {
        public var label: String
        public var seconds: Double
        /// `seconds / interval duration` (whole-interval denominator).
        public var share: Double
        public init(label: String, seconds: Double, share: Double) {
            self.label = label; self.seconds = seconds; self.share = share
        }
    }

    /// Duration-weighted composition over the WHOLE interval (spec §6.2). `labels` + `unknownS` + `uncoveredS`
    /// reconcile to `intervalS` within numeric tolerance; nothing is labelled by its final second.
    public struct ActivityComposition: Codable, Equatable, Sendable, Hashable {
        public var interval: Interval
        public var intervalS: Int
        public var source: ActivitySource
        /// True when the source reads heart rate (circular for heart-rate-derived metrics).
        public var heartRateDependent: Bool
        public var labels: [LabelShare]
        /// Covered by a record whose label is unknown / abstained.
        public var unknownS: Double
        /// Not covered by any record.
        public var uncoveredS: Double
        /// Number of label changes between adjacent resolved spans inside the interval.
        public var transitions: Int
        /// More than one supported label each above the mixed floor.
        public var mixed: Bool
        /// The label holding at least `dominantFloor` of the interval, if any.
        public var dominantLabel: String?
        /// Seconds where overlapping records disagreed and were resolved by revision order.
        public var resolvedOverlapS: Int
        public var reasons: [ReasonCode]

        public init(interval: Interval, intervalS: Int, source: ActivitySource, heartRateDependent: Bool,
                    labels: [LabelShare], unknownS: Double, uncoveredS: Double, transitions: Int, mixed: Bool,
                    dominantLabel: String?, resolvedOverlapS: Int, reasons: [ReasonCode]) {
            self.interval = interval; self.intervalS = intervalS; self.source = source
            self.heartRateDependent = heartRateDependent; self.labels = labels; self.unknownS = unknownS
            self.uncoveredS = uncoveredS; self.transitions = transitions; self.mixed = mixed
            self.dominantLabel = dominantLabel; self.resolvedOverlapS = resolvedOverlapS; self.reasons = reasons
        }

        public func seconds(of label: String) -> Double { labels.first { $0.label == label }?.seconds ?? 0 }
        public func share(of label: String) -> Double { labels.first { $0.label == label }?.share ?? 0 }
        public var coveredS: Double { Double(intervalS) - uncoveredS }
    }

    /// The history window before a measurement, separate from the measurement interval (spec §6.2).
    public struct PrecedingHistory: Codable, Equatable, Sendable, Hashable {
        public var lookback: Interval
        public var source: ActivitySource
        /// Continuous supported stationary seconds ending at the measurement start.
        public var stillRunS: Int
        /// Why the still run ended (`gap`, `movement`, `unknown_label`, `lookback_limit`).
        public var stillRunEndedBy: ReasonCode?
        /// Seconds from the end of the last supported movement (walking/running/stepping) to the measurement start.
        public var secondsSinceSupportedActivity: Int?
        public var lastSupportedActivityLabel: String?
        public var coveredS: Int
        public var transitions: Int
        public init(lookback: Interval, source: ActivitySource, stillRunS: Int, stillRunEndedBy: ReasonCode?,
                    secondsSinceSupportedActivity: Int?, lastSupportedActivityLabel: String?, coveredS: Int,
                    transitions: Int) {
            self.lookback = lookback; self.source = source; self.stillRunS = stillRunS
            self.stillRunEndedBy = stillRunEndedBy; self.secondsSinceSupportedActivity = secondsSinceSupportedActivity
            self.lastSupportedActivityLabel = lastSupportedActivityLabel; self.coveredS = coveredS
            self.transitions = transitions
        }
    }

    /// Recent-history context of one measurement (spec §6.1 "History"). Built by the engine from Systems C, D, E.
    public struct HistoryContext: Codable, Equatable, Sendable {
        /// Wake-relative timing (System C).
        public var wake: WakeReference
        /// Bouts that ended before the measurement started, newest first (System D).
        public var recentBouts: [BoutRef]
        /// Exertion summaries over the configured trailing windows ending at the measurement start (System D).
        public var exertion: [ExertionWindowSummary]
        /// Confirmed / denied / candidate exposure events overlapping or preceding the support (System E).
        public var exposures: [ExposureRef]
        /// Per-category recording status over the exposure lookback; unrecorded is not "none" (System E).
        public var exposureCoverage: [ExposureCategoryStatus]
        public init(wake: WakeReference, recentBouts: [BoutRef], exertion: [ExertionWindowSummary],
                    exposures: [ExposureRef], exposureCoverage: [ExposureCategoryStatus]) {
            self.wake = wake; self.recentBouts = recentBouts; self.exertion = exertion
            self.exposures = exposures; self.exposureCoverage = exposureCoverage
        }
    }

    /// The interpretation header shared by every product in a document.
    public struct Interpretation: Codable, Equatable, Sendable {
        public var mode: ProcessingMode
        public var finality: Finality
        public var availabilityCutoff: Int
        public var generatedAt: Int
        public init(mode: ProcessingMode, finality: Finality, availabilityCutoff: Int, generatedAt: Int) {
            self.mode = mode; self.finality = finality
            self.availabilityCutoff = availabilityCutoff; self.generatedAt = generatedAt
        }
    }
}

// MARK: - Dependence (spec §12.3, V13)

extension PhysiologyContext {

    /// A declared dependence between derived signals or between a label and a signal.
    public struct DependenceNote: Codable, Equatable, Sendable {
        /// Shared-input group, e.g. `rr_intervals`, `heart_rate`, `sleep_detector`.
        public var group: String
        public var members: [String]
        public var note: ReasonCode
        public init(group: String, members: [String], note: ReasonCode) {
            self.group = group; self.members = members; self.note = note
        }
    }
}

// MARK: - Document

extension PhysiologyContext {

    public enum ProductStatus: String, Codable, CaseIterable, Sendable {
        case available
        case partial
        case noData = "no_data"
        case unavailable
    }

    public struct DocumentHeader: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var contractVersion: String
        public var identity: DayIdentity
        public var interpretation: Interpretation
        public var versions: PolicyVersions
        /// FNV-1a of the full policy (every tunable); part of every cache / reprocessing key.
        public var policyFingerprint: String
        /// FNV-1a of the canonical input encoding; equal inputs + policy give byte-identical documents.
        public var inputFingerprint: String
        public var inputRevisions: [InputRevision]
        public init(schemaVersion: Int, contractVersion: String, identity: DayIdentity,
                    interpretation: Interpretation, versions: PolicyVersions, policyFingerprint: String,
                    inputFingerprint: String, inputRevisions: [InputRevision]) {
            self.schemaVersion = schemaVersion; self.contractVersion = contractVersion; self.identity = identity
            self.interpretation = interpretation; self.versions = versions
            self.policyFingerprint = policyFingerprint; self.inputFingerprint = inputFingerprint
            self.inputRevisions = inputRevisions
        }
    }

    /// One device-day of context products.
    public struct DayDocument: Codable, Equatable, Sendable {
        public var header: DocumentHeader
        public var status: ProductStatus
        public var statusReasons: [ReasonCode]
        /// Input-contract findings (timestamps, units, duplicates, clock resets, availability).
        public var inputReport: InputContractReport
        public var availability: [AvailabilityEntry]
        public var regimes: RegimeTimeline
        public var envelopes: [MeasurementEnvelope]
        public var sleep: SleepRhythmSummary
        public var bouts: [ExertionBout]
        public var exertion: [ExertionWindowSummary]
        public var exposures: ExposureDaySummary
        public var dailyValues: [DailyValue]
        public var comparisons: [ReferenceComparison]
        /// Frozen references this run registered (immutable once stored).
        public var newFrozenReferences: [FrozenReference]
        public var episodes: [ChangeEpisode]
        public var multiSignal: [MultiSignalSummary]
        public var functional: FunctionalDaySummary
        public var features: [FeatureEvaluation]
        public var dependence: [DependenceNote]
        public var selection: [SelectionSummary]
        /// Set only on a stored SUMMARY document (`StoredDocument.split`): the envelope tables split off from it.
        /// nil on a complete document. An empty `envelopes` with a non-nil index means "stored separately", not
        /// "no measurements".
        public var envelopeIndex: [EnvelopeTableIndex]? = nil

        public init(header: DocumentHeader, status: ProductStatus, statusReasons: [ReasonCode],
                    inputReport: InputContractReport, availability: [AvailabilityEntry], regimes: RegimeTimeline,
                    envelopes: [MeasurementEnvelope], sleep: SleepRhythmSummary, bouts: [ExertionBout],
                    exertion: [ExertionWindowSummary], exposures: ExposureDaySummary, dailyValues: [DailyValue],
                    comparisons: [ReferenceComparison], newFrozenReferences: [FrozenReference],
                    episodes: [ChangeEpisode], multiSignal: [MultiSignalSummary], functional: FunctionalDaySummary,
                    features: [FeatureEvaluation], dependence: [DependenceNote], selection: [SelectionSummary]) {
            self.header = header; self.status = status; self.statusReasons = statusReasons
            self.inputReport = inputReport; self.availability = availability; self.regimes = regimes
            self.envelopes = envelopes; self.sleep = sleep; self.bouts = bouts; self.exertion = exertion
            self.exposures = exposures; self.dailyValues = dailyValues; self.comparisons = comparisons
            self.newFrozenReferences = newFrozenReferences; self.episodes = episodes
            self.multiSignal = multiSignal; self.functional = functional; self.features = features
            self.dependence = dependence; self.selection = selection
        }
    }
}

// MARK: - Policy

extension PhysiologyContext {

    /// Version strings of every policy (spec §15: versions go into caches and reprocessing keys).
    public struct PolicyVersions: Codable, Equatable, Sendable {
        public var contract: String
        public var join: String
        public var validity: String
        public var eligibility: String
        public var sleep: String
        public var exertion: String
        public var exposure: String
        public var reference: String
        public var change: String
        public var functional: String
        public var featureRegistry: String
    }

    /// All tunables of the layer. Every field participates in `fingerprint`, so changing any parameter changes
    /// the reprocessing key and no stale cached product is reused.
    public struct Policy: Codable, Equatable, Sendable {
        public var join: JoinConfig
        public var validity: ValidityConfig
        public var eligibility: EligibilityConfig
        public var sleep: SleepConfig
        public var exertion: ExertionConfig
        public var exposure: ExposureConfig
        public var reference: ReferenceConfig
        public var change: ChangeConfig
        public var functional: FunctionalConfig

        public init(join: JoinConfig = .init(), validity: ValidityConfig = .init(),
                    eligibility: EligibilityConfig = .init(), sleep: SleepConfig = .init(),
                    exertion: ExertionConfig = .init(), exposure: ExposureConfig = .init(),
                    reference: ReferenceConfig = .init(), change: ChangeConfig = .init(),
                    functional: FunctionalConfig = .init()) {
            self.join = join; self.validity = validity; self.eligibility = eligibility; self.sleep = sleep
            self.exertion = exertion; self.exposure = exposure; self.reference = reference
            self.change = change; self.functional = functional
        }

        public static let `default` = Policy()

        public var versions: PolicyVersions {
            PolicyVersions(contract: PhysiologyContext.contractVersion, join: join.version,
                           validity: validity.version, eligibility: eligibility.version, sleep: sleep.version,
                           exertion: exertion.version, exposure: exposure.version, reference: reference.version,
                           change: change.version, functional: functional.version,
                           featureRegistry: FeatureRegistry.version)
        }

        /// FNV-1a 64 over the canonical (sorted-key) JSON of the policy plus the feature registry version.
        public var fingerprint: String {
            let data = (try? PhysiologyContext.encoder().encode(self)) ?? Data()
            return PhysiologyContext.fnv1a(data + Data(FeatureRegistry.version.utf8))
        }
    }

    /// Join tunables (owned by the lead, implemented in PCIntervalAlgebra.swift).
    public struct JoinConfig: Codable, Equatable, Sendable {
        public var version = "pc-join-1"
        /// Seconds of history before a measurement that the preceding-history window inspects.
        public var precedingLookbackS = 1800
        /// A label is "mixed" when a second supported label holds at least this share of the interval.
        public var mixedFloorShare = 0.10
        /// A label is dominant when it holds at least this share of the WHOLE interval.
        public var dominantFloorShare = 0.90
        /// Reconciliation tolerance in seconds.
        public var reconcileToleranceS = 1e-6
        /// A retrospective document is final once its cutoff is this long after the day ends (the following
        /// night's sleep can still be attributed to the day until then).
        public var finalAfterDayEndS = 30 * 3600
        public init() {}
    }
}

// MARK: - Coding and hashing

extension PhysiologyContext {

    /// The canonical encoder: snake_case keys, sorted keys, no whitespace. Deterministic for equal values.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .throw
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// FNV-1a 64-bit, hex. Matches the repo's existing fingerprint convention (ActivityContextDayBuilder).
    public static func fnv1a(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    public static func fnv1a(_ text: String) -> String { fnv1a(Data(text.utf8)) }
}
