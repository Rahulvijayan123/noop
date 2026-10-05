import Foundation

// PCExposures.swift — System E: treatment and exposure timing (spec §11).
//
// OWNER: exposures workstream. SKELETON — signatures are the shared contract.
//
// Exposures are recorded events, never inferred from wearable changes. Unrecorded is not "none"; a denied entry is
// explicit absence; a candidate is never confirmed. Event-aligned summaries are descriptive associations that carry
// their confounding (concurrent events, behaviour change) and never a causal label.

extension PhysiologyContext {

    public struct ExposureConfig: Codable, Equatable, Sendable {
        public var version = "pc-exposure-1"
        /// Prior-event lookback for envelope references and category status, in hours.
        public var lookbackH = 72
        public init() {}
    }

    /// The current state of one exposure event at the document's cutoff (latest available revision).
    public struct ExposureEvent: Codable, Equatable, Sendable {
        public var eventId: String
        public var revision: Int
        public var kind: ExposureKind
        public var label: String
        public var occurred: Interval
        public var timePrecision: TimePrecision
        public var source: ExposureSource
        public var confirmation: ExposureConfirmation
        public var doseAmount: Double?
        public var doseUnit: String?
        public var doseProvenance: String?
        public var availableAt: Int
        /// Number of revisions available at the cutoff (history is preserved, not collapsed).
        public var revisionCount: Int
        public init(eventId: String, revision: Int, kind: ExposureKind, label: String, occurred: Interval,
                    timePrecision: TimePrecision, source: ExposureSource, confirmation: ExposureConfirmation,
                    doseAmount: Double?, doseUnit: String?, doseProvenance: String?, availableAt: Int,
                    revisionCount: Int) {
            self.eventId = eventId; self.revision = revision; self.kind = kind; self.label = label
            self.occurred = occurred; self.timePrecision = timePrecision; self.source = source
            self.confirmation = confirmation; self.doseAmount = doseAmount; self.doseUnit = doseUnit
            self.doseProvenance = doseProvenance; self.availableAt = availableAt; self.revisionCount = revisionCount
        }
    }

    /// A reference from a measurement to an event that overlapped or preceded it.
    public struct ExposureRef: Codable, Equatable, Sendable {
        public var eventId: String
        public var revision: Int
        public var kind: ExposureKind
        public var label: String
        /// `overlaps` | `precedes`.
        public var relation: String
        /// Seconds from the end of the occurrence range to the measurement start (0 when overlapping).
        public var secondsSinceOccurrence: Int
        public var timePrecision: TimePrecision
        public var confirmation: ExposureConfirmation
        public init(eventId: String, revision: Int, kind: ExposureKind, label: String, relation: String,
                    secondsSinceOccurrence: Int, timePrecision: TimePrecision, confirmation: ExposureConfirmation) {
            self.eventId = eventId; self.revision = revision; self.kind = kind; self.label = label
            self.relation = relation; self.secondsSinceOccurrence = secondsSinceOccurrence
            self.timePrecision = timePrecision; self.confirmation = confirmation
        }
    }

    /// Whether a category was recorded over a window. `unrecorded` is not evidence of absence.
    public struct ExposureCategoryStatus: Codable, Equatable, Sendable {
        public var kind: ExposureKind
        /// `recorded` | `denied` | `candidate_only` | `unrecorded`.
        public var status: String
        public init(kind: ExposureKind, status: String) { self.kind = kind; self.status = status }
    }

    /// The day's exposure product.
    public struct ExposureDaySummary: Codable, Equatable, Sendable {
        /// Events whose occurrence overlaps the day or its exposure lookback.
        public var events: [ExposureEvent]
        public var categoryStatus: [ExposureCategoryStatus]
        /// Revisions in the input that were not yet available at the cutoff (causal mode).
        public var revisionsNotYetAvailable: Int
        public var reasons: [ReasonCode]
        public init(events: [ExposureEvent], categoryStatus: [ExposureCategoryStatus],
                    revisionsNotYetAvailable: Int, reasons: [ReasonCode]) {
            self.events = events; self.categoryStatus = categoryStatus
            self.revisionsNotYetAvailable = revisionsNotYetAvailable; self.reasons = reasons
        }
        public static let empty = ExposureDaySummary(events: [], categoryStatus: [], revisionsNotYetAvailable: 0,
                                                     reasons: [])
    }

    public enum Exposures {

        public static let reasonCodes: [ReasonCode] = []

        /// Current event states from the revision history, as available at `cutoff` (causal) or in full.
        public static func current(_ revisions: [ExposureEventRevision], mode: ProcessingMode,
                                   cutoff: Int) -> [ExposureEvent] {
            []
        }

        /// Events overlapping or preceding `support` within the lookback.
        public static func refs(for support: Interval, events: [ExposureEvent],
                                config: ExposureConfig) -> [ExposureRef] {
            []
        }

        /// Per-category status over the lookback window ending at `support.end`.
        public static func categoryStatus(for support: Interval, events: [ExposureEvent],
                                          config: ExposureConfig) -> [ExposureCategoryStatus] {
            []
        }

        /// The day summary, including event-aligned before/after descriptions where data exist.
        public static func daySummary(revisions: [ExposureEventRevision], events: [ExposureEvent],
                                      envelopes: [MeasurementEnvelope], bouts: [ExertionBout],
                                      identity: DayIdentity, mode: ProcessingMode, cutoff: Int,
                                      config: ExposureConfig) -> ExposureDaySummary {
            .empty
        }

        /// Local day keys whose context depends on this revision (old and new occurrence plus the lookahead the
        /// exposure windows reach). The SQL invalidation trigger mirrors this rule.
        public static func affectedDays(revision: ExposureEventRevision, previous: ExposureEventRevision?,
                                        timezoneId: String, config: ExposureConfig) -> [String] {
            []
        }
    }
}
