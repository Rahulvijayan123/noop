import Foundation

// PCExposures.swift — System E: treatment and exposure timing (spec §11).
//
// OWNER: exposures workstream.
//
// Exposures are recorded events, never inferred from wearable changes. Unrecorded is not "none"; a denied entry is
// explicit absence; a candidate is never confirmed. Event-aligned summaries are descriptive associations that carry
// their confounding (concurrent events, behaviour change) and never a causal label.
//
// Out of scope by design (spec §11): predicted pharmacological effect, drug clearance, dose-response modelling and
// any inference of a dose, meal, hydration state, infection or psychological stress from wearable data. Medication
// timing is known only as well as the event record says (`timePrecision`). Events of a pharmacological kind carry
// `pharmacology_not_modelled` in their aligned summary so no consumer mistakes a before/after description for an
// effect estimate.
//
// Time. Occurrence (`occurred`, half-open) and availability (`receivedAt`, else `recordedAt`) are separate. In causal
// mode a revision is only visible once it was available at the cutoff, so a late entry or a later correction never
// reaches an earlier live decision; a retrospective view uses every revision.

extension PhysiologyContext {

    public struct ExposureConfig: Codable, Equatable, Sendable {
        public var version = "pc-exposure-1"
        /// Prior-event lookback for envelope references and category status, in hours. Also the forward reach of
        /// an event used by `affectedDays` (and the SQL invalidation that mirrors it).
        public var lookbackH = 72
        /// Before/after window widths of event-aligned summaries, in hours (`[t - w, t)` vs `[t_end, t_end + w)`).
        public var alignedWindowsH: [Int] = [3, 24]
        /// Fewer measurements than this on either side of a window (per metric and method) is
        /// `insufficient_measurements`.
        public var minMeasurementsPerSide = 3
        /// A difference of at least this many seconds of exertion bouts, or of locomotion (scaled to the window),
        /// between the before and after windows is reported as `behavior_change`.
        public var behaviorChangeS = 600
        /// At most this many events are aligned per document (bounded document size); the rest are counted.
        public var maxAlignedEvents = 24
        /// `affectedDays` returns at most this many days (the SQL invalidation span cap).
        public var maxAffectedDays = 120
        public init() {}

        enum CodingKeys: String, CodingKey {
            case version, lookbackH, alignedWindowsH, minMeasurementsPerSide, behaviorChangeS, maxAlignedEvents,
                 maxAffectedDays
        }

        /// Missing keys take their defaults, so a policy encoded before a field existed still decodes.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ExposureConfig()
            version = try c.decodeIfPresent(String.self, forKey: .version) ?? d.version
            lookbackH = try c.decodeIfPresent(Int.self, forKey: .lookbackH) ?? d.lookbackH
            alignedWindowsH = try c.decodeIfPresent([Int].self, forKey: .alignedWindowsH) ?? d.alignedWindowsH
            minMeasurementsPerSide = try c.decodeIfPresent(Int.self, forKey: .minMeasurementsPerSide)
                ?? d.minMeasurementsPerSide
            behaviorChangeS = try c.decodeIfPresent(Int.self, forKey: .behaviorChangeS) ?? d.behaviorChangeS
            maxAlignedEvents = try c.decodeIfPresent(Int.self, forKey: .maxAlignedEvents) ?? d.maxAlignedEvents
            maxAffectedDays = try c.decodeIfPresent(Int.self, forKey: .maxAffectedDays) ?? d.maxAffectedDays
        }

        /// The lookback in seconds (never negative).
        public var lookbackS: Int { max(0, lookbackH) * 3600 }
        /// The widest aligned window in seconds (0 when none is configured).
        public var maxAlignedWindowS: Int { max(0, alignedWindowsH.max() ?? 0) * 3600 }
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
        /// For `denied` only: the share of the window the explicit denials cover (a "no" for one day of a 72 h
        /// window covers about a third of it; the rest is unrecorded, not denied). Nil otherwise.
        public var deniedCoverage: Double?
        public init(kind: ExposureKind, status: String, deniedCoverage: Double? = nil) {
            self.kind = kind; self.status = status; self.deniedCoverage = deniedCoverage
        }
    }

    /// Measurements of one metric and method in an aligned before/after window pair. Values are the published
    /// measurements unchanged; the counts and medians describe them, they do not estimate an effect.
    public struct AlignedMetricSummary: Codable, Equatable, Sendable {
        public var metric: MetricKind
        public var methodId: String
        public var units: String
        public var beforeCount: Int
        public var afterCount: Int
        public var beforeMedian: Double?
        public var afterMedian: Double?
        /// Measurements inside the windows left out because they had no value or were not `valid`/`degraded`.
        public var excludedCount: Int
        public var reasons: [ReasonCode]
        public init(metric: MetricKind, methodId: String, units: String, beforeCount: Int, afterCount: Int,
                    beforeMedian: Double?, afterMedian: Double?, excludedCount: Int, reasons: [ReasonCode]) {
            self.metric = metric; self.methodId = methodId; self.units = units; self.beforeCount = beforeCount
            self.afterCount = afterCount; self.beforeMedian = beforeMedian; self.afterMedian = afterMedian
            self.excludedCount = excludedCount; self.reasons = reasons
        }
    }

    /// Behaviour on each side of an aligned window: an explicit confounder, from heart-rate independent evidence.
    public struct AlignedBehavior: Codable, Equatable, Sendable {
        /// Seconds of detected exertion bouts inside each searched window (System D).
        public var beforeBoutS: Int
        public var afterBoutS: Int
        /// Locomotion seconds in the activity compositions of non-overlapping envelopes inside each window.
        public var beforeLocomotionS: Double
        public var afterLocomotionS: Double
        /// Labelled (observed) activity seconds behind those figures. Unobserved time is not stillness.
        public var beforeObservedS: Double
        public var afterObservedS: Double
        public init(beforeBoutS: Int, afterBoutS: Int, beforeLocomotionS: Double, afterLocomotionS: Double,
                    beforeObservedS: Double, afterObservedS: Double) {
            self.beforeBoutS = beforeBoutS; self.afterBoutS = afterBoutS
            self.beforeLocomotionS = beforeLocomotionS; self.afterLocomotionS = afterLocomotionS
            self.beforeObservedS = beforeObservedS; self.afterObservedS = afterObservedS
        }
    }

    /// Another event that overlapped an aligned window (confounding, never attributed).
    public struct ConcurrentExposure: Codable, Equatable, Sendable {
        public var eventId: String
        public var kind: ExposureKind
        public var label: String
        public var confirmation: ExposureConfirmation
        public var timePrecision: TimePrecision
        public init(eventId: String, kind: ExposureKind, label: String, confirmation: ExposureConfirmation,
                    timePrecision: TimePrecision) {
            self.eventId = eventId; self.kind = kind; self.label = label; self.confirmation = confirmation
            self.timePrecision = timePrecision
        }
    }

    /// One before/after window pair around an event.
    public struct AlignedWindow: Codable, Equatable, Sendable {
        public var widthS: Int
        /// `[occurred.start - width, occurred.start)`.
        public var before: Interval
        /// `[occurred.end, occurred.end + width)`. The occurrence range itself belongs to neither side.
        public var after: Interval
        /// The parts this document could search (its day, and before the cutoff in causal mode); nil when none.
        public var beforeSearched: Interval?
        public var afterSearched: Interval?
        public var metrics: [AlignedMetricSummary]
        public var behavior: AlignedBehavior
        public var concurrent: [ConcurrentExposure]
        public var reasons: [ReasonCode]
        public init(widthS: Int, before: Interval, after: Interval, beforeSearched: Interval?,
                    afterSearched: Interval?, metrics: [AlignedMetricSummary], behavior: AlignedBehavior,
                    concurrent: [ConcurrentExposure], reasons: [ReasonCode]) {
            self.widthS = widthS; self.before = before; self.after = after; self.beforeSearched = beforeSearched
            self.afterSearched = afterSearched; self.metrics = metrics; self.behavior = behavior
            self.concurrent = concurrent; self.reasons = reasons
        }
    }

    /// Event-aligned before/after description of one confirmed event. Always `association_only`: a description
    /// of measurements around a recorded event, with its confounding, never an effect or a causal label.
    public struct EventAlignedSummary: Codable, Equatable, Sendable {
        public var eventId: String
        public var revision: Int
        public var kind: ExposureKind
        public var label: String
        public var occurred: Interval
        public var timePrecision: TimePrecision
        public var doseAmount: Double?
        public var doseUnit: String?
        /// Empty when the time is too uncertain for any configured window (`time_uncertain`).
        public var windows: [AlignedWindow]
        public var reasons: [ReasonCode]
        public init(eventId: String, revision: Int, kind: ExposureKind, label: String, occurred: Interval,
                    timePrecision: TimePrecision, doseAmount: Double?, doseUnit: String?, windows: [AlignedWindow],
                    reasons: [ReasonCode]) {
            self.eventId = eventId; self.revision = revision; self.kind = kind; self.label = label
            self.occurred = occurred; self.timePrecision = timePrecision; self.doseAmount = doseAmount
            self.doseUnit = doseUnit; self.windows = windows; self.reasons = reasons
        }
    }

    /// The day's exposure product.
    public struct ExposureDaySummary: Codable, Equatable, Sendable {
        /// Events whose occurrence overlaps the day or its exposure lookback.
        public var events: [ExposureEvent]
        /// Per-category status over the document day itself.
        public var categoryStatus: [ExposureCategoryStatus]
        /// Retrospective only: revisions of the day's events that became available after the cutoff (a replay
        /// at an earlier cutoff with the full history). Always 0 in causal mode: the engine removed them before
        /// any system ran, and counting them would leak future information.
        public var revisionsNotYetAvailable: Int
        public var reasons: [ReasonCode]
        /// Event-aligned before/after descriptions (confirmed events with a known enough time).
        public var aligned: [EventAlignedSummary]
        /// Retrospective only: revisions of the day's events that became available after the day ended (a live
        /// view of this day never had them: late entries and later corrections). 0 in causal mode.
        public var lateRevisions: Int

        public init(events: [ExposureEvent], categoryStatus: [ExposureCategoryStatus],
                    revisionsNotYetAvailable: Int, reasons: [ReasonCode], aligned: [EventAlignedSummary] = [],
                    lateRevisions: Int = 0) {
            self.events = events; self.categoryStatus = categoryStatus
            self.revisionsNotYetAvailable = revisionsNotYetAvailable; self.reasons = reasons
            self.aligned = aligned; self.lateRevisions = lateRevisions
        }
        public static let empty = ExposureDaySummary(events: [], categoryStatus: [], revisionsNotYetAvailable: 0,
                                                     reasons: [])

        enum CodingKeys: String, CodingKey {
            case events, categoryStatus, revisionsNotYetAvailable, reasons, aligned, lateRevisions
        }

        /// Fields added after the contract skeleton decode with defaults, so an older document still reads.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            events = try c.decode([ExposureEvent].self, forKey: .events)
            categoryStatus = try c.decode([ExposureCategoryStatus].self, forKey: .categoryStatus)
            revisionsNotYetAvailable = try c.decode(Int.self, forKey: .revisionsNotYetAvailable)
            reasons = try c.decode([ReasonCode].self, forKey: .reasons)
            aligned = try c.decodeIfPresent([EventAlignedSummary].self, forKey: .aligned) ?? []
            lateRevisions = try c.decodeIfPresent(Int.self, forKey: .lateRevisions) ?? 0
        }
    }

    public enum Exposures {

        public static let version = "pc-exposure-1"

        // MARK: Reason codes
        /// Every aligned summary: a description of measurements around a recorded event, never an effect.
        public static let associationOnly: ReasonCode = "association_only"
        /// Other confirmed or candidate events overlap the aligned windows.
        public static let concurrentEvents: ReasonCode = "concurrent_events"
        /// The occurrence time is too uncertain for hour-level alignment (day-only, or a range wider than a window).
        public static let timeUncertain: ReasonCode = "time_uncertain"
        /// Too few measurements on one side of a window (per metric and method), or none at all.
        public static let insufficientMeasurements: ReasonCode = "insufficient_measurements"
        /// Exertion bouts or locomotion differ between the before and after windows.
        public static let behaviorChange: ReasonCode = "behavior_change"
        /// One side of a window has no labelled activity evidence, so behaviour change cannot be assessed.
        public static let behaviorUnobserved: ReasonCode = "behavior_unobserved"
        /// Part of a window lies outside the document day or after the causal cutoff.
        public static let windowPartiallySearched: ReasonCode = "window_partially_searched"
        /// The before and after measurements come from different measurement regimes.
        public static let regimeChange: ReasonCode = "regime_change"
        /// Pharmacological effect and clearance are not modelled (medication, supplement, caffeine, alcohol).
        public static let pharmacologyNotModelled: ReasonCode = "pharmacology_not_modelled"
        /// Retrospective: revisions that became available after the day ended are included.
        public static let lateEntriesIncluded: ReasonCode = "late_entries_included"
        /// More events qualified for alignment than `maxAlignedEvents`.
        public static let alignedEventsLimited: ReasonCode = "aligned_events_limited"
        /// No exposure event touches the day or its lookback. Unrecorded, not absence.
        public static let noExposureRecords: ReasonCode = "no_exposure_records"
        /// A software-proposed revision claimed `confirmed`; it is kept as `candidate`.
        public static let candidateNotConfirmed: ReasonCode = "candidate_not_confirmed"
        /// Revisions with an empty id, a revision below 1 or an empty occurrence range were ignored.
        public static let invalidRevisionsIgnored: ReasonCode = "invalid_revisions_ignored"
        /// A non-finite dose amount was dropped (the event is kept without a dose).
        public static let invalidDoseDropped: ReasonCode = "invalid_dose_dropped"

        public static let reasonCodes: [ReasonCode] = [
            associationOnly, concurrentEvents, timeUncertain, insufficientMeasurements, behaviorChange,
            behaviorUnobserved, windowPartiallySearched, regimeChange, pharmacologyNotModelled, lateEntriesIncluded,
            alignedEventsLimited, noExposureRecords, candidateNotConfirmed, invalidRevisionsIgnored,
            invalidDoseDropped,
        ]

        // MARK: Vocabulary
        public static let relationOverlaps = "overlaps"
        public static let relationPrecedes = "precedes"
        public static let statusRecorded = "recorded"
        public static let statusDenied = "denied"
        public static let statusCandidateOnly = "candidate_only"
        public static let statusUnrecorded = "unrecorded"
        /// Kinds whose aligned summaries carry `pharmacology_not_modelled`.
        public static let pharmacologicalKinds: Set<ExposureKind> = [.medication, .supplement, .caffeine, .alcohol]

        // MARK: - Current state

        /// Current event states from the revision history, as available at `cutoff` (causal) or in full
        /// (retrospective). The latest revision per event wins (revision number, then availability, then entry
        /// time); a `retracted` latest revision removes the event from current state; `revisionCount` counts the
        /// distinct revisions visible. Ordered by occurrence, then id.
        public static func current(_ revisions: [ExposureEventRevision], mode: ProcessingMode,
                                   cutoff: Int) -> [ExposureEvent] {
            var byEvent: [String: [ExposureEventRevision]] = [:]
            for r in revisions where isUsable(r) && (mode == .retrospective || r.availableAt <= cutoff) {
                byEvent[r.eventId, default: []].append(r)
            }
            var out: [ExposureEvent] = []
            out.reserveCapacity(byEvent.count)
            for (_, revs) in byEvent {
                guard let latest = revs.max(by: precedes), latest.confirmation != .retracted else { continue }
                out.append(event(from: latest, revisionCount: Set(revs.map(\.revision)).count))
            }
            return out.sorted(by: eventOrder)
        }

        /// Events overlapping `support` (relation `overlaps`, 0 s) or ending before it within the lookback
        /// (relation `precedes`, seconds from the occurrence end to the support start). Denied and candidate
        /// events are included with their own confirmation (explicit absence and proposals are information);
        /// nothing is promoted to confirmed. Nearest first, then by id.
        public static func refs(for support: Interval, events: [ExposureEvent],
                                config: ExposureConfig) -> [ExposureRef] {
            guard support.isValid else { return [] }
            let lookback = config.lookbackS
            var out: [(ref: ExposureRef, start: Int)] = []
            for e in events where e.confirmation != .retracted && e.occurred.isValid {
                let relation: String
                let since: Int
                if e.occurred.overlapSeconds(with: support) > 0 {
                    relation = relationOverlaps; since = 0
                } else if e.occurred.end <= support.start, support.start - e.occurred.end <= lookback {
                    relation = relationPrecedes; since = support.start - e.occurred.end
                } else {
                    continue
                }
                out.append((ExposureRef(eventId: e.eventId, revision: e.revision, kind: e.kind, label: e.label,
                                        relation: relation, secondsSinceOccurrence: since,
                                        timePrecision: e.timePrecision, confirmation: e.confirmation),
                            e.occurred.start))
            }
            return out.sorted {
                ($0.ref.secondsSinceOccurrence, -$0.start, $0.ref.eventId)
                    < ($1.ref.secondsSinceOccurrence, -$1.start, $1.ref.eventId)
            }.map(\.ref)
        }

        /// Per-category status over the lookback window ending at `support.end`
        /// (`[support.end - lookback, support.end)`). One entry per `ExposureKind`, in declaration order.
        public static func categoryStatus(for support: Interval, events: [ExposureEvent],
                                          config: ExposureConfig) -> [ExposureCategoryStatus] {
            status(over: Interval(support.end - config.lookbackS, support.end), events: events)
        }

        /// Category status over an arbitrary window: `recorded` when a confirmed event overlaps it, else `denied`
        /// when an explicit denial does (with the share of the window the denials cover), else `candidate_only`,
        /// else `unrecorded`. A confirmed occurrence outranks a denial because it is positive evidence.
        public static func status(over window: Interval, events: [ExposureEvent]) -> [ExposureCategoryStatus] {
            ExposureKind.allCases.map { kind in
                guard window.isValid else { return ExposureCategoryStatus(kind: kind, status: statusUnrecorded) }
                let hits = events.filter {
                    $0.kind == kind && $0.confirmation != .retracted && $0.occurred.overlapSeconds(with: window) > 0
                }
                if hits.contains(where: { $0.confirmation == .confirmed }) {
                    return ExposureCategoryStatus(kind: kind, status: statusRecorded)
                }
                let denials = hits.filter { $0.confirmation == .denied }.map(\.occurred)
                if !denials.isEmpty {
                    let covered = unionSeconds(denials, within: window)
                    return ExposureCategoryStatus(kind: kind, status: statusDenied,
                                                  deniedCoverage: Double(covered) / Double(window.duration))
                }
                if hits.contains(where: { $0.confirmation == .candidate }) {
                    return ExposureCategoryStatus(kind: kind, status: statusCandidateOnly)
                }
                return ExposureCategoryStatus(kind: kind, status: statusUnrecorded)
            }
        }

        // MARK: - Day summary

        /// The day summary: the events relevant to the day (its own window plus the lookback before it), the
        /// day's category status, revision accounting (retrospective only) and event-aligned before/after
        /// descriptions for confirmed events whose time is precise enough.
        public static func daySummary(revisions: [ExposureEventRevision], events: [ExposureEvent],
                                      envelopes: [MeasurementEnvelope], bouts: [ExertionBout],
                                      identity: DayIdentity, mode: ProcessingMode, cutoff: Int,
                                      config: ExposureConfig) -> ExposureDaySummary {
            let day = identity.dayWindow
            let relevantRange = Interval(day.start - config.lookbackS, day.end)
            let relevant = events.filter { $0.occurred.overlapSeconds(with: relevantRange) > 0 }
            var reasons: [ReasonCode] = []
            if relevant.isEmpty { reasons.append(noExposureRecords) }

            if revisions.contains(where: { !isUsable($0) }) { reasons.append(invalidRevisionsIgnored) }
            let relevantIds = Set(relevant.map(\.eventId))
            let relevantRevisions = revisions.filter { relevantIds.contains($0.eventId) && isUsable($0) }
            if relevantRevisions.contains(where: { $0.source == .inferredCandidate && $0.confirmation == .confirmed }) {
                reasons.append(candidateNotConfirmed)
            }
            if relevantRevisions.contains(where: { $0.doseAmount.map { !$0.isFinite } ?? false }) {
                reasons.append(invalidDoseDropped)
            }

            var notYetAvailable = 0
            var late = 0
            if mode == .retrospective {
                notYetAvailable = relevantRevisions.filter { $0.availableAt > cutoff }.count
                late = relevantRevisions.filter { $0.availableAt > day.end }.count
                if late > 0 { reasons.append(lateEntriesIncluded) }
            }

            // Search range: the document day, and nothing at or after the cutoff in causal mode.
            let searchEnd = mode == .causalLive ? min(day.end, cutoff) : day.end
            let search = Interval(day.start, searchEnd)
            let alignable = relevant.filter { $0.confirmation == .confirmed && $0.occurred.overlapSeconds(with: day) > 0 }
            let limit = max(0, config.maxAlignedEvents)
            if alignable.count > limit { reasons.append(alignedEventsLimited) }
            let sortedEnvelopes = envelopes.sorted { ($0.support, $0.id) < ($1.support, $1.id) }
            let aligned = alignable.prefix(limit).map {
                alignedSummary(for: $0, events: events, envelopes: sortedEnvelopes, bouts: bouts, search: search,
                               config: config)
            }

            return ExposureDaySummary(events: relevant, categoryStatus: status(over: day, events: events),
                                      revisionsNotYetAvailable: notYetAvailable, reasons: Array(Set(reasons)).sorted(),
                                      aligned: Array(aligned), lateRevisions: late)
        }

        // MARK: - Invalidation

        /// Local day keys whose context depends on this revision. The SQL invalidation mirrors this rule exactly
        /// (docs/physiology-context/notes/exposures.md):
        ///
        ///   from = min(occurred.start over {revision, previous}) - maxAlignedWindowS
        ///   to   = max(occurred.end   over {revision, previous}) + lookbackS
        ///   days = every local day (in `timezoneId`) from localDay(from) through localDay(to), inclusive,
        ///          capped at `maxAffectedDays` (the earliest days are kept).
        ///
        /// The forward reach is the lookback (a measurement starting up to `lookbackS` after the occurrence end
        /// references it). The backward reach is the widest aligned window: an earlier day's aligned summary lists
        /// this event as concurrent when it falls inside that day's after-window. An empty occurrence range is
        /// treated as the one second at its start (over-invalidating is safe; missing a day is not).
        public static func affectedDays(revision: ExposureEventRevision, previous: ExposureEventRevision?,
                                        timezoneId: String, config: ExposureConfig) -> [String] {
            let ranges = ([revision] + (previous.map { [$0] } ?? [])).map { r in
                Interval(r.occurred.start, max(r.occurred.end, r.occurred.start + 1))
            }
            guard let minStart = ranges.map(\.start).min(), let maxEnd = ranges.map(\.end).max() else { return [] }
            // Closed reach [minStart - aligned window, maxEnd + lookback]: `refs` includes an event whose end is
            // exactly `lookback` before a measurement, so the instant maxEnd + lookback is itself affected
            // (mirrored by record_exposure_event_v1).
            return dayKeys(from: minStart - config.maxAlignedWindowS, through: maxEnd + config.lookbackS,
                           timezoneId: timezoneId, limit: max(0, config.maxAffectedDays))
        }

        // MARK: - Helpers

        /// A revision the layer can use. A retraction is usable without a valid occurrence (it only withdraws).
        static func isUsable(_ r: ExposureEventRevision) -> Bool {
            !r.eventId.isEmpty && r.revision >= 1 && (r.confirmation == .retracted || r.occurred.isValid)
        }

        /// Total order of revisions of one event: revision, then availability, then entry time, then content.
        static func precedes(_ a: ExposureEventRevision, _ b: ExposureEventRevision) -> Bool {
            if a.revision != b.revision { return a.revision < b.revision }
            if a.availableAt != b.availableAt { return a.availableAt < b.availableAt }
            if a.recordedAt != b.recordedAt { return a.recordedAt < b.recordedAt }
            return (a.confirmation.rawValue, a.label, a.occurred) < (b.confirmation.rawValue, b.label, b.occurred)
        }

        static func eventOrder(_ a: ExposureEvent, _ b: ExposureEvent) -> Bool {
            (a.occurred, a.eventId) < (b.occurred, b.eventId)
        }

        static func event(from r: ExposureEventRevision, revisionCount: Int) -> ExposureEvent {
            // A software proposal never confirms itself: confirmation needs a person or an importing system.
            let confirmation: ExposureConfirmation =
                r.source == .inferredCandidate && r.confirmation == .confirmed ? .candidate : r.confirmation
            let dose = r.doseAmount.flatMap { $0.isFinite ? $0 : nil }
            return ExposureEvent(eventId: r.eventId, revision: r.revision, kind: r.kind, label: r.label,
                                 occurred: r.occurred, timePrecision: r.timePrecision, source: r.source,
                                 confirmation: confirmation, doseAmount: dose,
                                 doseUnit: dose == nil && r.doseAmount != nil ? nil : r.doseUnit,
                                 doseProvenance: dose == nil && r.doseAmount != nil ? nil : r.doseProvenance,
                                 availableAt: r.availableAt, revisionCount: revisionCount)
        }

        /// Seconds of `window` covered by the union of `ranges`.
        static func unionSeconds(_ ranges: [Interval], within window: Interval) -> Int {
            let clipped = ranges.compactMap { $0.intersection(window) }.sorted()
            var total = 0
            var cursor = Int.min
            for r in clipped {
                let lo = max(r.start, cursor)
                if r.end > lo { total += r.end - lo }
                cursor = max(cursor, r.end)
            }
            return total
        }

        static func alignedSummary(for e: ExposureEvent, events: [ExposureEvent], envelopes: [MeasurementEnvelope],
                                   bouts: [ExertionBout], search: Interval,
                                   config: ExposureConfig) -> EventAlignedSummary {
            var reasons: [ReasonCode] = [associationOnly]
            if pharmacologicalKinds.contains(e.kind) { reasons.append(pharmacologyNotModelled) }
            var windows: [AlignedWindow] = []
            if e.timePrecision == .dayOnly {
                // Only the local day is known: no hour-level alignment.
                reasons.append(timeUncertain)
            } else {
                for hours in Set(config.alignedWindowsH).sorted() where hours > 0 {
                    let width = hours * 3600
                    // A range wider than the window cannot say which side a measurement is on.
                    guard e.occurred.duration <= width else { reasons.append(timeUncertain); continue }
                    windows.append(alignedWindow(for: e, width: width, events: events, envelopes: envelopes,
                                                 bouts: bouts, search: search, config: config))
                }
            }
            if windows.contains(where: { $0.reasons.contains(concurrentEvents) }) { reasons.append(concurrentEvents) }
            // With no window at all the reason is the time uncertainty, not the measurements.
            if !windows.isEmpty && windows.allSatisfy({ $0.reasons.contains(insufficientMeasurements) }) {
                reasons.append(insufficientMeasurements)
            }
            return EventAlignedSummary(eventId: e.eventId, revision: e.revision, kind: e.kind, label: e.label,
                                       occurred: e.occurred, timePrecision: e.timePrecision,
                                       doseAmount: e.doseAmount, doseUnit: e.doseUnit, windows: windows,
                                       reasons: Array(Set(reasons)).sorted())
        }

        static func alignedWindow(for e: ExposureEvent, width: Int, events: [ExposureEvent],
                                  envelopes: [MeasurementEnvelope], bouts: [ExertionBout], search: Interval,
                                  config: ExposureConfig) -> AlignedWindow {
            let before = Interval(e.occurred.start - width, e.occurred.start)
            let after = Interval(e.occurred.end, e.occurred.end + width)
            let beforeSearched = search.isValid ? before.intersection(search) : nil
            let afterSearched = search.isValid ? after.intersection(search) : nil
            var reasons: [ReasonCode] = []
            if beforeSearched != before || afterSearched != after { reasons.append(windowPartiallySearched) }

            func inside(_ w: Interval?) -> [MeasurementEnvelope] {
                guard let w else { return [] }
                return envelopes.filter { $0.support.isValid && $0.support.start >= w.start && $0.support.end <= w.end }
            }
            let b = inside(beforeSearched), a = inside(afterSearched)

            // Measurements, grouped by metric and method (different methods are different quantities).
            struct Key: Hashable, Comparable {
                let metric: String, method: String
                static func < (l: Key, r: Key) -> Bool { (l.metric, l.method) < (r.metric, r.method) }
            }
            func usable(_ m: MeasurementEnvelope) -> Double? {
                guard m.validity.state == .valid || m.validity.state == .degraded,
                      let v = m.value, v.isFinite else { return nil }
                return v
            }
            var groups: [Key: (before: [MeasurementEnvelope], after: [MeasurementEnvelope])] = [:]
            for m in b { groups[Key(metric: m.metric.rawValue, method: m.method.id), default: ([], [])].before.append(m) }
            for m in a { groups[Key(metric: m.metric.rawValue, method: m.method.id), default: ([], [])].after.append(m) }
            let minimum = max(1, config.minMeasurementsPerSide)
            var metrics: [AlignedMetricSummary] = []
            for key in groups.keys.sorted() {
                let g = groups[key]!
                let sample = g.before.first ?? g.after.first!
                let bv = g.before.compactMap(usable), av = g.after.compactMap(usable)
                var r: [ReasonCode] = []
                if bv.count < minimum || av.count < minimum { r.append(insufficientMeasurements) }
                let bRegimes = Set(g.before.map(\.regimeKey)), aRegimes = Set(g.after.map(\.regimeKey))
                if !bRegimes.isEmpty && !aRegimes.isEmpty && bRegimes != aRegimes { r.append(regimeChange) }
                metrics.append(AlignedMetricSummary(
                    metric: sample.metric, methodId: sample.method.id, units: sample.method.units,
                    beforeCount: bv.count, afterCount: av.count, beforeMedian: RobustStats.median(bv),
                    afterMedian: RobustStats.median(av),
                    excludedCount: (g.before.count - bv.count) + (g.after.count - av.count), reasons: r))
            }
            if metrics.isEmpty || metrics.allSatisfy({ $0.reasons.contains(insufficientMeasurements) }) {
                reasons.append(insufficientMeasurements)
            }
            if metrics.contains(where: { $0.reasons.contains(regimeChange) }) { reasons.append(regimeChange) }

            // Behaviour (heart-rate independent): bout seconds and locomotion over non-overlapping supports.
            func boutSeconds(_ w: Interval?) -> Int {
                guard let w else { return 0 }
                return unionSeconds(bouts.map(\.interval), within: w)
            }
            func locomotion(_ inWindow: [MeasurementEnvelope]) -> (loc: Double, observed: Double) {
                var loc = 0.0, observed = 0.0, lastEnd = Int.min
                for m in inWindow where m.support.start >= lastEnd && !m.activity.heartRateDependent {
                    lastEnd = m.support.end
                    observed += max(0, m.activity.coveredS - m.activity.unknownS)
                    loc += m.activity.labels.filter { MotionVocabulary.isLocomotion($0.label) }
                        .reduce(0) { $0 + $1.seconds }
                }
                return (loc, observed)
            }
            let bl = locomotion(b), al = locomotion(a)
            let behavior = AlignedBehavior(beforeBoutS: boutSeconds(beforeSearched), afterBoutS: boutSeconds(afterSearched),
                                           beforeLocomotionS: bl.loc, afterLocomotionS: al.loc,
                                           beforeObservedS: bl.observed, afterObservedS: al.observed)
            let threshold = Double(max(1, config.behaviorChangeS))
            var changed = abs(Double(behavior.afterBoutS - behavior.beforeBoutS)) >= threshold
            if bl.observed > 0 && al.observed > 0 {
                let shift = abs(al.loc / al.observed - bl.loc / bl.observed) * Double(width)
                if shift >= threshold { changed = true }
            } else {
                reasons.append(behaviorUnobserved)
            }
            if changed { reasons.append(behaviorChange) }

            // Concurrent events: anything else confirmed or proposed that overlaps the whole aligned span.
            let span = Interval(before.start, after.end)
            let concurrent = events.filter {
                $0.eventId != e.eventId && ($0.confirmation == .confirmed || $0.confirmation == .candidate)
                    && $0.occurred.overlapSeconds(with: span) > 0
            }.map {
                ConcurrentExposure(eventId: $0.eventId, kind: $0.kind, label: $0.label,
                                   confirmation: $0.confirmation, timePrecision: $0.timePrecision)
            }
            if !concurrent.isEmpty { reasons.append(concurrentEvents) }

            return AlignedWindow(widthS: width, before: before, after: after, beforeSearched: beforeSearched,
                                 afterSearched: afterSearched, metrics: metrics, behavior: behavior,
                                 concurrent: concurrent, reasons: Array(Set(reasons)).sorted())
        }

        /// Local day keys from the day containing `from` through the day containing `through`, inclusive.
        static func dayKeys(from: Int, through: Int, timezoneId: String, limit: Int) -> [String] {
            guard through >= from, limit > 0 else { return [] }
            let zone = TimeZone(identifier: timezoneId) ?? TimeZone(identifier: "UTC")!
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let last = PhysiologyContext.localTime(at: through, timezoneId: timezoneId).localDay
            var cursor = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(from)))
            var out: [String] = []
            while out.count < limit {
                // Noon of the cursor day names it without DST edge effects.
                let noon = cal.date(byAdding: .hour, value: 12, to: cursor) ?? cursor
                let key = PhysiologyContext.localTime(at: Int(noon.timeIntervalSince1970), timezoneId: timezoneId).localDay
                out.append(key)
                if key >= last { break }
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return out
        }
    }
}
