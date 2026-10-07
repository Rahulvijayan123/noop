import Foundation
import WhoopProtocol

// SleepAnalyticsV1.swift — the shared contract for Phase 1 sleep analytics
// (`snapshot.daily.sleep_analytics_v1`, docs/sleep-analytics/spec.md sections 4–8).
//
// A PURE extractor in this shared package: the worker publishes the document it computes from
// the day's already-loaded streams, and the app decodes the same typed document from the hosted
// snapshot. No sidecar call, no model, no DB, no UI. It is ADDITIVE: the canonical sleep
// detection, stage assignments, Rest/Charge scores, canonical RMSSD and recovery calculations
// are unchanged, and a failure here withholds its own document and nothing else.
//
// Scope is the day's MAIN-NIGHT GROUP — the fragments `DayResult.mainNightBlocks` resolved
// (including split nights), never a re-picked longest session. Adapters (the worker's
// `DayScoring`, the app's local compute path) assemble `SleepAnalyticsInput` from that exact
// lineage; the extractor never chooses a different main night or re-runs a stager.
//
// Honesty rules the whole document enforces:
//   * Unknown stays unknown: no forward-fill, no interpolation, absent samples are never
//     awake/asleep/still (spec 4.6).
//   * Every metric is `value` + `unit` + `status` + optional `reason`; JSON null is explicit
//     and never a fabricated zero. NaN/Infinity are never emitted.
//   * "Observed" means observed in the supported input/label record, not an independently
//     observed PSG state. Stage-derived text says "estimated".
//   * Gaps between bridged fragments stay `inferred_inter_fragment_awake` — separate from
//     observed WASO, never sensor coverage, never a completed bout or transition (spec 4.7).
//   * Counts can be zero with qualifying exposure; missing evidence is null with a reason.

// MARK: - Status vocabulary (spec section 8)

/// Machine-readable per-metric availability.
public enum SleepAnalyticsStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case available
    case partial
    case unavailable
    case disabled
}

/// Machine-readable unavailability reasons (spec section 8; closed vocabulary).
public enum SleepAnalyticsReason: String, Codable, Equatable, Sendable, CaseIterable {
    case insufficientCoverage = "insufficient_coverage"
    case insufficientDuration = "insufficient_duration"
    case unsupportedSource = "unsupported_source"
    case missingMarker = "missing_marker"
    case invalidMarker = "invalid_marker"
    case onsetNotObserved = "onset_not_observed"
    case noObservedSleep = "no_observed_sleep"
    case noObservedRem = "no_observed_rem"
    case noObservedDeep = "no_observed_deep"
    case insufficientBouts = "insufficient_bouts"
    case unresolvedAdjacency = "unresolved_adjacency"
    case unreliableBeats = "unreliable_beats"
    case zeroDenominator = "zero_denominator"
    case sourceMismatch = "source_mismatch"
    case staleEdit = "stale_edit"
    case computationFailed = "computation_failed"
    case noSamples = "no_samples"
}

// MARK: - Metric wrappers (spec section 8)

/// One real-valued metric: `value`, `unit`, `status`, optional `reason`. `value` is nil unless
/// `status` carries a number (available, or partial with a value). Counts use
/// `SleepAnalyticsCount` so integers stay integers on the wire.
public struct SleepAnalyticsMetric: Codable, Equatable, Sendable {
    public let value: Double?
    public let unit: String
    public let status: SleepAnalyticsStatus
    public let reason: SleepAnalyticsReason?

    public init(value: Double?, unit: String, status: SleepAnalyticsStatus,
                reason: SleepAnalyticsReason? = nil) {
        // Finite-only by SANITIZATION, not precondition (review P2-4: precondition() is
        // stripped under -O, so the shipped builds would have no guard and JSONEncoder
        // would throw away the WHOLE document over one bad leaf). A non-finite value
        // becomes an explicit null with `computation_failed` — the metric withholds
        // itself, never the day.
        if let v = value, v.isFinite {
            self.value = v
            self.status = status
            self.reason = reason
        } else if value == nil {
            self.value = nil
            self.status = status
            self.reason = reason
        } else {
            self.value = nil
            self.status = .unavailable
            self.reason = .computationFailed
        }
        self.unit = unit
    }

    public static func available(_ value: Double, unit: String) -> SleepAnalyticsMetric {
        SleepAnalyticsMetric(value: value, unit: unit, status: .available)
    }
    public static func partial(_ value: Double, unit: String) -> SleepAnalyticsMetric {
        SleepAnalyticsMetric(value: value, unit: unit, status: .partial)
    }
    public static func unavailable(_ reason: SleepAnalyticsReason,
                                   unit: String = "s") -> SleepAnalyticsMetric {
        SleepAnalyticsMetric(value: nil, unit: unit, status: .unavailable, reason: reason)
    }
    public static func disabled(_ reason: SleepAnalyticsReason? = nil,
                                unit: String = "s") -> SleepAnalyticsMetric {
        SleepAnalyticsMetric(value: nil, unit: unit, status: .disabled, reason: reason)
    }

    private enum CodingKeys: String, CodingKey { case value, unit, status, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant: a future/malformed leaf never breaks the day (house decode rule).
        let raw = try? c.decodeIfPresent(Double.self, forKey: .value)
        self.value = (raw ?? nil).flatMap { $0.isFinite ? $0 : nil }
        self.unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? ""
        self.status = (try? c.decodeIfPresent(SleepAnalyticsStatus.self, forKey: .status)) ?? .unavailable
        self.reason = try? c.decodeIfPresent(SleepAnalyticsReason.self, forKey: .reason)
    }
}

/// One integer-valued metric (bout and transition counts): same wrapper contract, `Int` value.
public struct SleepAnalyticsCount: Codable, Equatable, Sendable {
    public let value: Int?
    public let unit: String
    public let status: SleepAnalyticsStatus
    public let reason: SleepAnalyticsReason?

    public init(value: Int?, unit: String, status: SleepAnalyticsStatus,
                reason: SleepAnalyticsReason? = nil) {
        self.value = value
        self.unit = unit
        self.status = status
        self.reason = reason
    }

    public static func available(_ value: Int, unit: String = "count") -> SleepAnalyticsCount {
        SleepAnalyticsCount(value: value, unit: unit, status: .available)
    }
    public static func unavailable(_ reason: SleepAnalyticsReason) -> SleepAnalyticsCount {
        SleepAnalyticsCount(value: nil, unit: "count", status: .unavailable, reason: reason)
    }
    public static func disabled() -> SleepAnalyticsCount {
        SleepAnalyticsCount(value: nil, unit: "count", status: .disabled)
    }

    private enum CodingKeys: String, CodingKey { case value, unit, status, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try? c.decodeIfPresent(Int.self, forKey: .value)
        let dbl = (try? c.decodeIfPresent(Double.self, forKey: .value)).flatMap { $0.rounded() == $0 ? Int($0) : nil }
        self.value = raw ?? dbl
        self.unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? "count"
        self.status = (try? c.decodeIfPresent(SleepAnalyticsStatus.self, forKey: .status)) ?? .unavailable
        self.reason = try? c.decodeIfPresent(SleepAnalyticsReason.self, forKey: .reason)
    }
}

// MARK: - Stage source vocabulary (spec sections 4.3–4.5, 4.9)

/// What produced a fragment's stage labels.
public enum SleepAnalyticsStageSourceKind: String, Codable, Equatable, Sendable {
    /// The shared Swift stager (SleepStagerV2 today) over native WHOOP streams: native 30-second
    /// epochs; input-support masks apply (spec 4.4).
    case nativeWhoop = "native_whoop_v2"
    /// A timed external hypnogram (imported with timestamps, at its REAL resolution). Supports
    /// label summaries only; `sensor_support_unknown`; no native epoch matrix (spec 4.5, 4.9).
    case timestampedExternal = "timestamped_external"
    /// Totals-only or synthetic imported timeline: label summaries at most; bout/transition/
    /// latency metrics are `unsupported_source` (spec 4.5).
    case totalsOnly = "totals_only"
}

// MARK: - Input (spec section 4: adapters assemble; the extractor never re-picks)

/// The bounded input for one main-night group. Everything is within the caller's already-loaded
/// read window; the extractor only filters to fragments and the explicitly defined peri-sleep
/// intervals. Pure value; adapters own lineage.
///
/// Not `Sendable`: the raw stream rows (`HRSample`, `GravitySample`, `SkinTempSample`,
/// `RRInterval`) are value types the protocol package has not marked Sendable; adapters
/// construct and consume the input on one task (the worker inside its lane thread, the app
/// inside its compute pass), so the document — the value that crosses boundaries — carries
/// the `Sendable` requirement instead.
public struct SleepAnalyticsInput: Equatable {
    /// One effective main-night fragment: a detected session's EFFECTIVE bounds and the stage
    /// segments that tile `[start, end)` (as resolved by the existing main-night-group lineage —
    /// `DayResult.mainNightBlocks` matched sessions — including edit-applied bounds/stages).
    public struct Fragment: Equatable, Sendable {
        /// Stable fragment identity: the session's canonical id on the wire
        /// (`sleep-<deviceId>-<start>`), so a hosted document can be matched against the
        /// night it describes.
        public let id: String
        /// Half-open effective start (unix seconds).
        public let start: Int
        /// Effective end (unix seconds), > start.
        public let end: Int
        /// What produced this fragment's labels.
        public let sourceKind: SleepAnalyticsStageSourceKind
        /// The source's own epoch resolution in seconds (30 for native; the real resolution for
        /// a timed external hypnogram; nil for totals-only).
        public let sourceEpochSeconds: Int?
        /// The stager's OWN grid anchor for this fragment (the original session start the
        /// stager gridded its 30-second epochs at), when it differs from the effective
        /// start (an edit that moved the effective bounds). The extractor verifies epoch
        /// alignment against THIS anchor (spec 4.9 / review P2-4: left-clipping to an
        /// edited start would otherwise trivially satisfy a fragment-start-relative
        /// check and silently shift the grid). nil = the effective start is the anchor.
        public let stageGridAnchorSeconds: Int?
        /// A user edit was applied to this fragment's effective bounds or stages.
        public let edited: Bool
        /// Stage-minute totals for a totals-only import fragment (no timestamps). Non-nil only
        /// for `.totalsOnly` fragments; ignored otherwise.
        public let totalsMinutes: SleepAnalyticsStageMinutes?
        /// The edit lineage revision (the accepted edit's input revision), when known.
        public let editRevision: Int64?
        /// The effective stage segments within `[start, end)` (union-able, may be empty).
        public let stages: [StageSegment]

        public init(id: String, start: Int, end: Int,
                    sourceKind: SleepAnalyticsStageSourceKind,
                    sourceEpochSeconds: Int? = nil,
                    edited: Bool = false, editRevision: Int64? = nil,
                    stageGridAnchorSeconds: Int? = nil,
                    totalsMinutes: SleepAnalyticsStageMinutes? = nil,
                    stages: [StageSegment]) {
            self.id = id; self.start = start; self.end = end
            self.sourceKind = sourceKind
            self.sourceEpochSeconds = sourceEpochSeconds
            self.edited = edited; self.editRevision = editRevision
            self.stageGridAnchorSeconds = stageGridAnchorSeconds
            self.totalsMinutes = totalsMinutes
            self.stages = stages
        }
    }

    /// An explicitly intended attempted-sleep / lights-out marker paired to this night.
    /// Phase 1 wires NONE: no marker source has verified semantics yet, so adapters pass nil
    /// and the latency metric answers `missing_marker` — never zero (spec section 5).
    public struct AttemptedSleepMarker: Equatable, Sendable {
        /// The marker's unix second.
        public let ts: Int
        /// The mapped marker kind (closed vocabulary, e.g. `user_mark`).
        public let kind: String
        /// Owner/device/session lineage the extractor checks before accepting the marker
        /// (`source_mismatch` / `invalid_marker` otherwise).
        public let sourceId: String?
        public init(ts: Int, kind: String, sourceId: String? = nil) {
            self.ts = ts; self.kind = kind; self.sourceId = sourceId
        }
    }

    /// The effective main-night fragments, in start order (the resolved group, NOT a re-pick).
    public let fragments: [Fragment]
    /// The night's IANA timezone id (the claim's / the app's zone). Recorded on the document.
    public let timezoneId: String
    /// 1 Hz heart-rate samples within the bounded read (the same rows scoring loaded).
    public let hr: [HRSample]
    /// 1 Hz gravity samples within the bounded read.
    public let gravity: [GravitySample]
    /// Skin-temperature raw samples within the bounded read (family-aware conversion inside).
    public let skinTemp: [SkinTempSample]
    /// R-R interval rows within the bounded read (original observation identity preserved).
    public let beats: [RRInterval]
    /// The device family that wrote the streams (thermal conversion + cadence policy).
    public let deviceFamily: DeviceFamily
    /// Per-device WHOOP 4.0 worn anchor raw; nil elsewhere (the same value the funnel uses).
    public let skinTempAnchorRaw: Double?
    /// Explicit off-wrist `[start, end)` intervals (paired WRIST_OFF/WRIST_ON evidence).
    public let offWristIntervals: [SleepAnalyticsInterval]
    /// Optional explicit attempted-sleep marker (Phase 1: nil).
    public let attemptedSleepMarker: AttemptedSleepMarker?
    /// The canonical staging algorithm version actually used for these fragments
    /// (e.g. "sleep-stager-v2-…" / the claim's algorithm version).
    public let stageSourceVersion: String
    /// The outer input revision the adapter computed from (hosted lineage/freshness).
    public let inputRevision: Int64

    public init(fragments: [Fragment], timezoneId: String,
                hr: [HRSample], gravity: [GravitySample], skinTemp: [SkinTempSample],
                beats: [RRInterval], deviceFamily: DeviceFamily,
                skinTempAnchorRaw: Double? = nil,
                offWristIntervals: [SleepAnalyticsInterval] = [],
                attemptedSleepMarker: AttemptedSleepMarker? = nil,
                stageSourceVersion: String, inputRevision: Int64) {
        self.fragments = fragments
        self.timezoneId = timezoneId
        self.hr = hr; self.gravity = gravity; self.skinTemp = skinTemp; self.beats = beats
        self.deviceFamily = deviceFamily
        self.skinTempAnchorRaw = skinTempAnchorRaw
        self.offWristIntervals = offWristIntervals
        self.attemptedSleepMarker = attemptedSleepMarker
        self.stageSourceVersion = stageSourceVersion
        self.inputRevision = inputRevision
    }
}

// MARK: - Normalized timeline contract (spec section 4; produced by normalization)

/// Canonical normalized labels after vocabulary mapping (spec 4.3). Unscored, artifact,
/// unsupported, uncovered and conflicting labels become `unknown`.
public enum SleepAnalyticsLabel: String, Codable, Equatable, Sendable, CaseIterable {
    case wake, light, deep, rem, unknown
}

/// A half-open `[start, end)` unix-second interval (equatable/Sendable value type so
/// quality structures synthesize conformance).
public struct SleepAnalyticsInterval: Equatable, Sendable, Codable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

/// Stage-minute totals for a totals-only import (no timestamps). Label summaries use these
/// at face value; bout/transition/latency metrics are `unsupported_source` (spec 4.5 — never
/// synthetic intervals manufactured for totals-only imports).
public struct SleepAnalyticsStageMinutes: Equatable, Sendable, Codable {
    public var wake: Double
    public var light: Double
    public var deep: Double
    public var rem: Double
    public init(wake: Double = 0, light: Double = 0, deep: Double = 0, rem: Double = 0) {
        self.wake = wake; self.light = light; self.deep = deep; self.rem = rem
    }
}

/// The normalized timeline for one main-night group: the single structure every group derives
/// from. Built by `SleepAnalyticsV1.normalize` (normalization file) and CONSUMED by the
/// continuity/stage-dynamics, movement, thermal and PRV group computers. All intervals are
/// half-open `[start, end)` in unix seconds, sorted, disjoint within a fragment, and no
/// interval crosses a fragment boundary.
public struct SleepAnalyticsTimeline: Equatable, Sendable {
    /// One normalized labeled interval.
    public struct Interval: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let label: SleepAnalyticsLabel
        /// Index into `fragments` (the owning fragment). Intervals never cross fragments.
        public let fragmentIndex: Int
        /// True only where the source supports the label (native epoch support mask / timed
        /// external coverage). `unknown` intervals always carry `false`.
        public let labelSupported: Bool
        /// Distinct seconds inside `[start, end)` with valid HR or gravity evidence
        /// (actual input support; never fabricated from label presence).
        public let inputSupportedSeconds: Int
        public init(start: Int, end: Int, label: SleepAnalyticsLabel, fragmentIndex: Int,
                    labelSupported: Bool, inputSupportedSeconds: Int) {
            self.start = start; self.end = end; self.label = label
            self.fragmentIndex = fragmentIndex
            self.labelSupported = labelSupported
            self.inputSupportedSeconds = inputSupportedSeconds
        }
    }

    /// One retained fragment span after clipping/validation (sorted by start, disjoint).
    public struct FragmentSpan: Equatable, Sendable {
        public let id: String
        public let start: Int
        public let end: Int
        public let sourceKind: SleepAnalyticsStageSourceKind
        public let sourceEpochSeconds: Int?
        /// The stager's own grid anchor when it differs from the effective start
        /// (spec 4.9 / review P2-4); nil = the effective start is the anchor.
        public let stageGridAnchorSeconds: Int?
        /// Stage-minute totals for a totals-only fragment, when the input carried them.
        public let totalsMinutes: SleepAnalyticsStageMinutes?
        public init(id: String, start: Int, end: Int,
                    sourceKind: SleepAnalyticsStageSourceKind, sourceEpochSeconds: Int?,
                    stageGridAnchorSeconds: Int? = nil,
                    totalsMinutes: SleepAnalyticsStageMinutes? = nil) {
            self.id = id; self.start = start; self.end = end
            self.sourceKind = sourceKind; self.sourceEpochSeconds = sourceEpochSeconds
            self.stageGridAnchorSeconds = stageGridAnchorSeconds
            self.totalsMinutes = totalsMinutes
        }
        /// The epoch-grid anchor: the stager's own anchor when supplied, else the
        /// effective start.
        public var gridAnchor: Int { stageGridAnchorSeconds ?? start }
    }

    /// The whole group's span (earliest fragment start, latest fragment end).
    public let windowStart: Int
    public let windowEnd: Int
    /// Retained fragments (invalid/discarded spans are counted in `discardedFragmentCount`).
    public let fragments: [FragmentSpan]
    /// The normalized labeled intervals (see `Interval`); unknown where unsupported/uncovered.
    public let intervals: [Interval]
    /// Inter-fragment gaps INSIDE the group, retained separately with origin
    /// `inferred_inter_fragment_awake` (spec 4.7). They never create sensor coverage, completed
    /// bouts, or observed transitions.
    public let inferredGapIntervals: [SleepAnalyticsInterval]
    /// Stage segments dropped as invalid (zero/negative spans) before normalization (spec 4.1).
    public let discardedSpanCount: Int
    /// Seconds those discarded invalid spans claimed (0 for empty spans).
    public let discardedSpanSeconds: Int
    /// Fragment ids that repeated in the adapter's input (exact duplicates dropped; spec 4.1
    /// reports them rather than silently ignoring the second copy).
    public let duplicateFragmentCount: Int
    /// Seconds of fragment-fragment overlap the adapter's input carried (clipped for
    /// containment, REPORTED here — never silently re-bounded lineage; a resolved
    /// main-night group is disjoint by construction, so > 0 is an adapter contract
    /// violation the quality blocks surface).
    public let fragmentOverlapSeconds: Double
    /// True when every retained native stage segment boundary is a multiple of the
    /// epoch grid from its fragment start — the stager's original grid alignment is
    /// established (spec 4.9). False (e.g. an edit moved the effective start to a
    /// non-epoch boundary) means the native epoch TRANSITION MATRIX is withheld
    /// (`unsupported_source`); duration metrics are unaffected.
    public let epochAlignmentEstablished: Bool
    /// Shared stream diagnostics the normalization pass already computed (spec
    /// section 4 "Quality and missingness": received/valid/duplicate/rejected), for
    /// group quality blocks to surface (the evidence sets are the shared input
    /// support mask's own counts).
    public let streamCounts: [String: Int]
    /// Overlap/conflict seconds resolved to `unknown` (spec 4.2).
    public let conflictSeconds: Int

    /// The first SUPPORTED asleep (light/deep/REM) interval's start, or nil (no observed sleep).
    public let firstSupportedAsleepStart: Int?
    /// The last SUPPORTED asleep interval's end, or nil.
    public let lastSupportedAsleepEnd: Int?
    /// The sleep period `[firstSupportedAsleepStart, lastSupportedAsleepEnd)`.
    public var sleepPeriod: (start: Int?, end: Int?) {
        (firstSupportedAsleepStart, lastSupportedAsleepEnd)
    }
    /// True when a supported WAKE epoch precedes the first supported asleep onset inside the
    /// window (the prefix is observed; onset is not left-censored) — spec section 4 quality.
    public let onsetPrefixObserved: Bool
    /// True when a supported WAKE epoch follows the last supported asleep end inside the
    /// window (offset not right-censored).
    public let offsetSuffixObserved: Bool

    /// Union seconds of a label's supported intervals (spec: no overlap double counting).
    public func supportedSeconds(of label: SleepAnalyticsLabel) -> Double {
        var seconds = 0.0
        for iv in intervals where iv.label == label && iv.labelSupported {
            seconds += Double(max(0, iv.end - iv.start))
        }
        return seconds
    }
    /// Total label-supported seconds across wake/light/deep/rem.
    public var totalLabelSupportedSeconds: Double {
        SleepAnalyticsLabel.allCases.filter { $0 != .unknown }.reduce(0.0) { $0 + supportedSeconds(of: $1) }
    }
    /// Distinct input-supported seconds across all intervals (union over fragments).
    public var totalInputSupportedSeconds: Double {
        var seconds = 0.0
        for iv in intervals { seconds += Double(iv.inputSupportedSeconds) }
        return seconds
    }
    /// Total fragment span seconds (the denominator for coverage fractions).
    public var fragmentSpanSeconds: Double {
        fragments.reduce(0.0) { $0 + Double(max(0, $1.end - $1.start)) }
    }
}

// MARK: - Quality block (spec section 4 "Quality and missingness")

/// Per-group quality/exposure metadata. Coverage is computed from interval unions and
/// timestamp-aware support, never row counts.
public struct SleepAnalyticsQuality: Codable, Equatable, Sendable {
    /// The group's overall availability (available/partial/unavailable/disabled).
    public let status: SleepAnalyticsStatus
    /// Sum of the retained fragment spans (s).
    public let fragmentSpanSeconds: Double
    /// The whole group span `[windowStart, windowEnd)` (s).
    public let groupSpanSeconds: Double
    /// Union seconds of label-supported (observed) labeled time (s).
    public let observedLabeledSeconds: Double
    /// Seconds inside fragments that are unknown (uncovered/unsupported/conflict) (s).
    public let unknownSeconds: Double
    /// The existing canonical inferred inter-fragment awake seconds within the group (s),
    /// reported separately from observed WASO (spec 4.7).
    public let inferredGapAwakeSeconds: Double
    /// Distinct seconds with valid HR or gravity evidence (actual input support) (s).
    public let inputSupportedSeconds: Double
    /// `inputSupportedSeconds / fragmentSpanSeconds`, nil when the span is zero.
    public let inputSupportedFraction: Double?
    /// Label-supported fraction of fragment span, nil when the span is zero.
    public let labelSupportedFraction: Double?
    /// The source's epoch resolution (s), when established.
    public let sourceResolutionSeconds: Int?
    /// Stream diagnostics for the group's own inputs (received/valid/duplicate/rejected/
    /// supported-duration where the group reads a raw stream); keys are closed-vocabulary.
    public let streamCounts: [String: Int]
    /// Adapter input carried repeated fragment ids (exact duplicates dropped; spec 4.1,
    /// review P2-3): surfaced here instead of staying internal-only.
    public let duplicateFragmentCount: Int?
    /// Adapter input carried overlapping fragments (clipped for containment; a resolved
    /// main-night group is disjoint by construction, so > 0 is an adapter contract
    /// violation; spec 4.1, review P2-3/P2-5): surfaced in seconds.
    public let fragmentOverlapSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case status
        case fragmentSpanSeconds = "fragment_span_seconds"
        case groupSpanSeconds = "group_span_seconds"
        case observedLabeledSeconds = "observed_labeled_seconds"
        case unknownSeconds = "unknown_seconds"
        case inferredGapAwakeSeconds = "inferred_gap_awake_seconds"
        case inputSupportedSeconds = "input_supported_seconds"
        case inputSupportedFraction = "input_supported_fraction"
        case labelSupportedFraction = "label_supported_fraction"
        case sourceResolutionSeconds = "source_resolution_seconds"
        case streamCounts = "stream_counts"
        case duplicateFragmentCount = "duplicate_fragment_count"
        case fragmentOverlapSeconds = "fragment_overlap_seconds"
    }

    public init(status: SleepAnalyticsStatus, fragmentSpanSeconds: Double,
                groupSpanSeconds: Double, observedLabeledSeconds: Double,
                unknownSeconds: Double, inferredGapAwakeSeconds: Double,
                inputSupportedSeconds: Double, inputSupportedFraction: Double?,
                labelSupportedFraction: Double?, sourceResolutionSeconds: Int?,
                streamCounts: [String: Int] = [:],
                duplicateFragmentCount: Int? = nil,
                fragmentOverlapSeconds: Double? = nil) {
        self.status = status
        self.fragmentSpanSeconds = fragmentSpanSeconds
        self.groupSpanSeconds = groupSpanSeconds
        self.observedLabeledSeconds = observedLabeledSeconds
        self.unknownSeconds = unknownSeconds
        self.inferredGapAwakeSeconds = inferredGapAwakeSeconds
        self.inputSupportedSeconds = inputSupportedSeconds
        self.inputSupportedFraction = inputSupportedFraction
        self.labelSupportedFraction = labelSupportedFraction
        self.sourceResolutionSeconds = sourceResolutionSeconds
        self.streamCounts = streamCounts
        self.duplicateFragmentCount = duplicateFragmentCount
        self.fragmentOverlapSeconds = fragmentOverlapSeconds
    }
}

// MARK: - Continuity group (spec section 5)

public struct SleepAnalyticsContinuityGroup: Codable, Equatable, Sendable {
    public let quality: SleepAnalyticsQuality
    /// Union duration of supported light+deep+REM intervals (s); unknown excluded.
    public let observedAsleepSeconds: SleepAnalyticsMetric

    private enum CodingKeys: String, CodingKey {
        case quality
        case observedAsleepSeconds = "observed_asleep_seconds"
        case observedWasoSeconds = "observed_waso_seconds"
        case inferredGapAwakeSecondsWithinSleepPeriod =
            "inferred_gap_awake_seconds_within_sleep_period"
        case estimatedWasoIncludingInferredGapsSeconds =
            "estimated_waso_including_inferred_gaps_seconds"
        case onsetDelayFromWindowSeconds = "onset_delay_from_window_seconds"
        case sleepOnsetLatencyFromMarkerSeconds = "sleep_onset_latency_from_marker_seconds"
        case remLatencyFromSleepOnsetSeconds = "rem_latency_from_sleep_onset_seconds"
        case deepLatencyFromSleepOnsetSeconds = "deep_latency_from_sleep_onset_seconds"
        case longestObservedSleepBoutSeconds = "longest_observed_sleep_bout_seconds"
        case longestBoutCensored = "longest_bout_censored"
        case awakeningBoutCount = "awakening_bout_count"
        case censoredWakeStretchCount = "censored_wake_stretch_count"
        case sleepToWakeTransitionCount = "sleep_to_wake_transition_count"
        case sleepToWakeTransitionsPerAsleepHour = "sleep_to_wake_transitions_per_asleep_hour"
    }
    /// Supported wake duration strictly between first and last observed asleep (s);
    /// excludes initial/terminal wake, unknown and inter-fragment gaps.
    public let observedWasoSeconds: SleepAnalyticsMetric
    /// Existing canonical inferred inter-fragment awake duration intersecting the sleep
    /// period (s). Separate from observed WASO; never sensor coverage.
    public let inferredGapAwakeSecondsWithinSleepPeriod: SleepAnalyticsMetric
    /// Sum of the previous two when usable (s). Explicitly an ESTIMATE including the existing
    /// gap assumption; never "observed". Canonical daily totals are unchanged.
    public let estimatedWasoIncludingInferredGapsSeconds: SleepAnalyticsMetric
    /// First supported asleep onset minus the effective detected-window start (s). A boundary
    /// estimate only when the prefix is unobserved; never clinical SOL.
    public let onsetDelayFromWindowSeconds: SleepAnalyticsMetric
    /// First supported asleep onset minus a verified attempted-sleep marker (s), or null
    /// (`missing_marker` in Phase 1: no marker source is wired).
    public let sleepOnsetLatencyFromMarkerSeconds: SleepAnalyticsMetric
    /// First supported REM start minus first supported asleep start (s); null with
    /// `no_observed_rem` / `onset_not_observed`. YASA's default starts at recording start, so
    /// the oracle must subtract SOL (documented deviation source).
    public let remLatencyFromSleepOnsetSeconds: SleepAnalyticsMetric
    /// First supported deep start minus first supported asleep start (s); descriptive only.
    public let deepLatencyFromSleepOnsetSeconds: SleepAnalyticsMetric
    /// Longest continuously observed run of any asleep labels, allowing stage changes; wake,
    /// unknown and fragment boundaries split the run (s).
    public let longestObservedSleepBoutSeconds: SleepAnalyticsMetric
    /// True when that run touches an unobserved edge (left/right censoring).
    public let longestBoutCensored: Bool?
    /// Wake bouts inside the sleep period with an observed sleep→wake entry AND an observed
    /// return to sleep (count). Label-level awakenings, not EEG arousals.
    public let awakeningBoutCount: SleepAnalyticsCount
    /// Edge/unknown-censored wake stretches inside the sleep period, reported separately and
    /// never silently counted as complete awakenings (count).
    public let censoredWakeStretchCount: SleepAnalyticsCount
    /// All valid adjacent asleep→wake label changes inside fragments, including a terminal
    /// observed wake change (count). Kept separate from complete awakenings.
    public let sleepToWakeTransitionCount: SleepAnalyticsCount
    /// The previous count per observed asleep hour (per h). Primary rate requires the
    /// complete-stage gate AND ≥30 min observed asleep; counts still exist below it.
    public let sleepToWakeTransitionsPerAsleepHour: SleepAnalyticsMetric
}

// MARK: - Stage dynamics group (spec section 5)

/// One stage's bout statistics. Complete bouts are bounded by an observed change on both
/// sides (or the fragment edge with an observed neighbour); censored bouts touch an unknown
/// span or an unobserved edge.
public struct SleepAnalyticsStageBouts: Codable, Equatable, Sendable {
    public let label: SleepAnalyticsLabel
    /// Total observed (label-supported) bout count (complete + censored).
    public let boutCount: SleepAnalyticsCount
    public let completeBoutCount: SleepAnalyticsCount
    public let censoredBoutCount: SleepAnalyticsCount
    /// Longest observed bout (s), available whenever a bout exists.
    public let longestObservedSeconds: SleepAnalyticsMetric
    /// Median complete-bout duration (s); requires ≥3 complete bouts (else null,
    /// `insufficient_bouts`). Even n: mean of the two middle values.
    public let medianCompleteBoutSeconds: SleepAnalyticsMetric
    /// Nearest-rank p90 of complete-bout durations (s): sorted value at ceil(0.9·n)−1.
    public let p90CompleteBoutSeconds: SleepAnalyticsMetric

    private enum CodingKeys: String, CodingKey {
        case label
        case boutCount = "bout_count"
        case completeBoutCount = "complete_bout_count"
        case censoredBoutCount = "censored_bout_count"
        case longestObservedSeconds = "longest_observed_seconds"
        case medianCompleteBoutSeconds = "median_complete_bout_seconds"
        case p90CompleteBoutSeconds = "p90_complete_bout_seconds"
    }
}

/// The 4×4 native epoch transition matrix. Rows are origin, columns destination, order
/// `[wake, light, deep, rem]`. Only genuinely adjacent valid native epoch pairs count
/// (self-transitions included); a row with no outgoing pairs has NULL probabilities, not a
/// zero-probability row. Available only for native sources at established resolution
/// (`unsupported_source` for coarse/totals-only imports — spec 4.9).
public struct SleepAnalyticsTransitionMatrix: Codable, Equatable, Sendable {
    /// Raw 4×4 counts (rows origin, cols destination, order wake, light, deep, rem).
    public let counts: [[Int]]
    /// Row exposure: eligible outgoing pairs per origin row (4 entries).
    public let rowExposure: [Int]
    /// Row-normalized probabilities (4 rows), nil rows when a row has no outgoing pairs.
    public let rowProbabilities: [[Double]?]
    /// The native epoch duration (s) these counts were computed at.
    public let epochSeconds: Int
    /// Eligible adjacent epoch pairs behind the matrix (count).
    public let eligiblePairCount: SleepAnalyticsCount
    /// Adjacent eligible pairs with different labels (count) — the matrix's stage changes.
    public let stageChangeCount: SleepAnalyticsCount
    /// For coarse/timed imports: the actual observed bout changes at the source's real
    /// resolution (count). Present separately; never claimed as a native epoch matrix.
    public let observedBoutChangeCount: SleepAnalyticsCount?

    private enum CodingKeys: String, CodingKey {
        case counts
        case rowExposure = "row_exposure"
        case rowProbabilities = "row_probabilities"
        case epochSeconds = "epoch_seconds"
        case eligiblePairCount = "eligible_pair_count"
        case stageChangeCount = "stage_change_count"
        case observedBoutChangeCount = "observed_bout_change_count"
    }
}

public struct SleepAnalyticsStageDynamicsGroup: Codable, Equatable, Sendable {
    public let quality: SleepAnalyticsQuality
    /// Union durations per label (wake/light/deep/rem/unknown), no overlap double counting.
    public let stageSeconds: [SleepAnalyticsStageSeconds]
    /// Bout statistics per stage label (wake/light/deep/rem).
    public let stageBouts: [SleepAnalyticsStageBouts]
    /// The 4×4 native epoch transition matrix (+exposure/probabilities/eligible pairs).
    public let epochTransitions: SleepAnalyticsTransitionMatrix?

    private enum CodingKeys: String, CodingKey {
        case quality
        case stageSeconds = "stage_seconds"
        case stageBouts = "stage_bouts"
        case epochTransitions = "epoch_transitions"
    }
}

/// Union duration for one label (s).
public struct SleepAnalyticsStageSeconds: Codable, Equatable, Sendable {
    public let label: SleepAnalyticsLabel
    public let seconds: SleepAnalyticsMetric
    private enum CodingKeys: String, CodingKey { case label; case seconds }
}

// MARK: - Movement group (spec section 6)

public struct SleepAnalyticsMovementGroup: Codable, Equatable, Sendable {
    public let quality: SleepAnalyticsQuality
    /// Classified moving seconds (one-second supported adjacencies above threshold) (s).
    public let movementSeconds: SleepAnalyticsMetric
    /// Eligible seconds: true one-second supported adjacencies inside fragments (s).
    public let eligibleSeconds: SleepAnalyticsMetric
    /// 100 × moving / eligible (%). A device-specific movement proxy, not activity/EEG.
    public let movementPercentage: SleepAnalyticsMetric
    /// Moving-bout count (count).
    public let movementBoutCount: SleepAnalyticsCount
    /// Movement bouts per eligible observed hour (per h); primary rate behind the exposure gate.
    public let movementBoutsPerEligibleHour: SleepAnalyticsMetric
    public let immobilityBoutCompleteCount: SleepAnalyticsCount
    public let immobilityBoutCensoredCount: SleepAnalyticsCount
    /// Longest observed immobility bout (s).
    public let longestObservedImmobilitySeconds: SleepAnalyticsMetric
    public let medianCompleteImmobilityBoutSeconds: SleepAnalyticsMetric
    public let p90CompleteImmobilityBoutSeconds: SleepAnalyticsMetric
    /// The movement threshold in g this run used (`SleepStager.gravityStillThresholdG`
    /// at v1) — recorded with the output.
    public let thresholdG: Double
    /// Movement source resolution description (e.g. "gravity_1hz_adjacent").
    public let sourceResolution: String
    /// Algorithm/config fingerprint of the movement computation.
    public let algorithmVersion: String

    private enum CodingKeys: String, CodingKey {
        case quality
        case movementSeconds = "movement_seconds"
        case eligibleSeconds = "eligible_seconds"
        case movementPercentage = "movement_percentage"
        case movementBoutCount = "movement_bout_count"
        case movementBoutsPerEligibleHour = "movement_bouts_per_eligible_hour"
        case immobilityBoutCompleteCount = "immobility_bout_complete_count"
        case immobilityBoutCensoredCount = "immobility_bout_censored_count"
        case longestObservedImmobilitySeconds = "longest_observed_immobility_seconds"
        case medianCompleteImmobilityBoutSeconds = "median_complete_immobility_bout_seconds"
        case p90CompleteImmobilityBoutSeconds = "p90_complete_immobility_bout_seconds"
        case thresholdG = "threshold_g"
        case sourceResolution = "source_resolution"
        case algorithmVersion = "algorithm_version"
    }
}

// MARK: - Thermal group (spec section 6)

/// An OLS slope over UTC-minute medians with its own window/exposure report.
public struct SleepAnalyticsSlope: Codable, Equatable, Sendable {
    /// Slope (°C per hour).
    public let value: SleepAnalyticsMetric
    /// The window's nominal `[start, end)` bounds (unix seconds).
    public let windowStart: Int
    public let windowEnd: Int
    /// Valid minute bins inside the window (count).
    public let validMinutes: Int
    /// Eligible minutes in the window (count).
    public let eligibleMinutes: Int
    /// Minute coverage fraction (valid/eligible), nil when no eligible minutes.
    public let coverage: Double?
    /// Longest missing run inside the window (s); gates require ≤ 5 min.
    public let longestMissingRunSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case value
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case validMinutes = "valid_minutes"
        case eligibleMinutes = "eligible_minutes"
        case coverage
        case longestMissingRunSeconds = "longest_missing_run_seconds"
    }
}

public struct SleepAnalyticsThermalGroup: Codable, Equatable, Sendable {
    public let quality: SleepAnalyticsQuality
    /// Median of valid in-fragment minute medians (°C); ≥30 valid minutes and ≥80% eligible
    /// coverage for a primary summary.
    public let nightMedianC: SleepAnalyticsMetric
    /// Q75 − Q25 of those minute medians, linear-interpolation quantiles (°C).
    public let nightIqrC: SleepAnalyticsMetric
    /// Q95 − Q05 (°C); descriptive spread only.
    public let nightP95MinusP05C: SleepAnalyticsMetric
    /// OLS slope over `[first observed onset − 60 min, onset)` (°C/h); requires onset
    /// observability, ≥45/60 valid minutes, no missing run > 5 min.
    public let preOnsetSlopeCPerHour: SleepAnalyticsSlope?
    /// OLS slope over `[effective final night end, end + 30 min)` (°C/h); requires ≥20/30
    /// valid minutes, no missing run > 5 min. Labelled after the estimated window END, never
    /// a measured awakening.
    public let postWakeSlopeCPerHour: SleepAnalyticsSlope?
    /// Minutes excluded by the 5-minute post-re-wear equilibration rule (engineering rule).
    public let equilibrationExcludedMinutes: Int
    /// True when an explicit re-wear/device-reset event backed those exclusions; false means
    /// warmup was NOT verified (spec: state it, never invent an event).
    public let rewearEventVerified: Bool
    /// The device family + anchor identity the conversion used (fingerprint string).
    public let conversionIdentity: String

    private enum CodingKeys: String, CodingKey {
        case quality
        case nightMedianC = "night_median_c"
        case nightIqrC = "night_iqr_c"
        case nightP95MinusP05C = "night_p95_minus_p05_c"
        case preOnsetSlopeCPerHour = "pre_onset_slope_c_per_hour"
        case postWakeSlopeCPerHour = "post_wake_slope_c_per_hour"
        case equilibrationExcludedMinutes = "equilibration_excluded_minutes"
        case rewearEventVerified = "rewear_event_verified"
        case conversionIdentity = "conversion_identity"
    }
}

// MARK: - PRV diagnostics group (spec section 7)

/// One eligible 5-minute window's Poincaré result (ms).
public struct SleepAnalyticsPrvWindow: Codable, Equatable, Sendable {
    /// Window `[start, start+300)` (unix seconds), fully inside one fragment.
    public let start: Int
    public let sd1Ms: Double
    public let sd2Ms: Double
    /// Valid adjacent cleaned pairs behind the window.
    public let pairs: Int
    /// Supported interval-duration coverage fraction inside the window.
    public let coverage: Double

    private enum CodingKeys: String, CodingKey {
        case start
        case sd1Ms = "sd1_ms"
        case sd2Ms = "sd2_ms"
        case pairs
        case coverage
    }
}

public struct SleepAnalyticsPrvDiagnosticsGroup: Codable, Equatable, Sendable {
    public let quality: SleepAnalyticsQuality
    /// Nightly SD1: MEDIAN of eligible window SD1 values (ms). Preserves windows; never
    /// concatenates the night into one series.
    public let nightlySd1Ms: SleepAnalyticsMetric
    /// Nightly SD2: median of eligible window SD2 values (ms).
    public let nightlySd2Ms: SleepAnalyticsMetric
    /// nightlySd1 / nightlySd2, null when summary SD2 is zero. The ratio OF the two summary
    /// values, never a mean of per-window ratios.
    public let nightlyRatio: SleepAnalyticsMetric
    /// Windows that passed the gates (count).
    public let eligibleWindowCount: SleepAnalyticsCount
    /// Windows withheld by a gate (count) — the gates are engineering rules, deliberately
    /// stricter than canonical HRV's floor.
    public let withheldWindowCount: SleepAnalyticsCount
    /// Rejected original observations / original deduplicated observations across the night
    /// (fraction ≤ 5% required).
    public let rejectionFraction: SleepAnalyticsMetric
    /// Total valid adjacent pairs across eligible windows (count).
    public let validPairs: SleepAnalyticsCount
    /// How beat timing was resolved (e.g. "rr_seq_ord", or the specific unresolved case).
    public let timingMethod: String
    /// The beat source label (e.g. "prv_optical"; PRV, never implied ECG-equivalent HRV).
    public let source: String
    /// Per-window results (compact; bounded by the night's window count).
    public let windows: [SleepAnalyticsPrvWindow]

    private enum CodingKeys: String, CodingKey {
        case quality
        case nightlySd1Ms = "nightly_sd1_ms"
        case nightlySd2Ms = "nightly_sd2_ms"
        case nightlyRatio = "nightly_ratio"
        case eligibleWindowCount = "eligible_window_count"
        case withheldWindowCount = "withheld_window_count"
        case rejectionFraction = "rejection_fraction"
        case validPairs = "valid_pairs"
        case timingMethod = "timing_method"
        case source
        case windows
    }
}

// MARK: - Document (spec section 8)

/// Fragment lineage recorded on the document (matched against the current night before a
/// cached document renders — staleness/fingerprint guard).
public struct SleepAnalyticsFragmentInfo: Codable, Equatable, Sendable {
    public let id: String
    public let sourceKind: SleepAnalyticsStageSourceKind
    public let startAt: String
    public let endAt: String
    public let edited: Bool
    public let editRevision: Int64?
    /// The effective bounds the fingerprint hashed (unix seconds, half-open).
    public let start: Int
    public let end: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceKind = "source_kind"
        case startAt = "start_at"
        case endAt = "end_at"
        case edited
        case editRevision = "edit_revision"
        case start, end
    }
}

/// The additive `daily.sleep_analytics_v1` document. schema_version 1,
/// algorithm_version "nara-sleep-analytics-1", scope "main_night". The outer hosted
/// `inputRevision`/`resultRevision` own freshness; the fingerprint detects stale documents
/// when effective bounds change. No inner pre-publication result revision exists.
public struct SleepAnalyticsDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let algorithmVersion: String
    public let configVersion: String
    public let scope: String
    public let timezone: String
    public let startAt: String
    public let endAt: String
    /// Effective group bounds (unix seconds, half-open).
    public let start: Int
    public let end: Int
    public let fragments: [SleepAnalyticsFragmentInfo]
    /// Deterministic SHA-256 fingerprint over fragment ids/bounds/sources/edited lineage/
    /// stage source version/config version/input revision — for stale-document detection.
    public let fingerprint: String
    public let stageSourceVersion: String
    /// Native epoch resolution (s) when established (nil for non-native sources).
    public let nativeEpochResolutionSeconds: Int?
    public let inputRevision: Int64
    public let continuity: SleepAnalyticsContinuityGroup
    public let stageDynamics: SleepAnalyticsStageDynamicsGroup
    public let movement: SleepAnalyticsMovementGroup
    public let thermal: SleepAnalyticsThermalGroup
    public let prvDiagnostics: SleepAnalyticsPrvDiagnosticsGroup

    /// Wire keys are the spec section 8 names (snake_case). Synthesized Codable
    /// would emit camelCase (`schemaVersion`) — the spec's contract example and field
    /// tables name `schema_version`, `observed_waso_seconds`, …, so the keys are
    /// explicit (review deviation W3-4: the first worker adapter round-tripped the
    /// synthesized camelCase; the spec is the source of truth).
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case algorithmVersion = "algorithm_version"
        case configVersion = "config_version"
        case scope
        case timezone
        case startAt = "start_at"
        case endAt = "end_at"
        case start, end
        case fragments
        case fingerprint
        case stageSourceVersion = "stage_source_version"
        case nativeEpochResolutionSeconds = "native_epoch_resolution_seconds"
        case inputRevision = "input_revision"
        case continuity
        case stageDynamics = "stage_dynamics"
        case movement
        case thermal
        case prvDiagnostics = "prv_diagnostics"
    }

    public init(schemaVersion: Int, algorithmVersion: String, configVersion: String,
                scope: String, timezone: String, startAt: String, endAt: String,
                start: Int, end: Int, fragments: [SleepAnalyticsFragmentInfo],
                fingerprint: String, stageSourceVersion: String,
                nativeEpochResolutionSeconds: Int?, inputRevision: Int64,
                continuity: SleepAnalyticsContinuityGroup,
                stageDynamics: SleepAnalyticsStageDynamicsGroup,
                movement: SleepAnalyticsMovementGroup,
                thermal: SleepAnalyticsThermalGroup,
                prvDiagnostics: SleepAnalyticsPrvDiagnosticsGroup) {
        self.schemaVersion = schemaVersion
        self.algorithmVersion = algorithmVersion
        self.configVersion = configVersion
        self.scope = scope
        self.timezone = timezone
        self.startAt = startAt; self.endAt = endAt
        self.start = start; self.end = end
        self.fragments = fragments
        self.fingerprint = fingerprint
        self.stageSourceVersion = stageSourceVersion
        self.nativeEpochResolutionSeconds = nativeEpochResolutionSeconds
        self.inputRevision = inputRevision
        self.continuity = continuity
        self.stageDynamics = stageDynamics
        self.movement = movement
        self.thermal = thermal
        self.prvDiagnostics = prvDiagnostics
    }
}

// MARK: - Config (spec sections 4–7: versioned engineering defaults)

/// Versioned engineering gates/defaults (spec: conservative PRODUCT rules, not physiological
/// validity thresholds; version them and test their boundaries).
public struct SleepAnalyticsConfig: Equatable, Sendable {
    /// Recorded on the document (`config_version`).
    public var version: String = "v1"
    // ── Support mask (spec 4.4) ─────────────────────────────────────────
    /// Native epoch length the support mask grids at (s).
    public var nativeEpochSeconds: Int = 30
    /// A native epoch is label-supported when ≥ this many DISTINCT seconds inside it carry
    /// valid HR or gravity evidence (consistent with available wear evidence).
    public var nativeMinDistinctSupportedSeconds: Int = 15
    /// Clipped native epochs use the same ≥50% rule against the clipped duration.
    public var nativeMinSupportFraction: Double = 0.5
    // ── Completeness gates (spec 4 "Engineering defaults") ──────────────
    /// Complete stage summary: minimum label-supported coverage of fragment time.
    public var stageSummaryMinLabelSupportedFraction: Double = 0.95
    /// Complete stage summary (native WHOOP): minimum actual input-supported seconds fraction.
    public var stageSummaryMinInputSupportedFraction: Double = 0.95
    /// Bout quantiles need ≥ this many complete bouts.
    public var minCompleteBoutsForQuantiles: Int = 3
    /// Primary per-hour rates need ≥ this observed/asleep/eligible seconds.
    public var primaryRateMinObservedSeconds: Int = 1800
    /// Motion primary rate: minimum eligible observed time.
    public var motionMinEligibleFraction: Double = 0.80
    public var motionMinObservedMinutes: Int = 30
    // ── Input-evidence validity (spec 4.4 engineering presence check) ────
    /// A heart-rate second counts as valid evidence inside this range (bpm).
    public var hrPlausibleMinBpm: Double = 20
    public var hrPlausibleMaxBpm: Double = 250
    /// A gravity sample counts as valid evidence when |g| is finite inside this band (g).
    public var gravityNormMinG: Double = 0.5
    public var gravityNormMaxG: Double = 1.5
    // ── Movement (spec 6) ────────────────────────────────────────────────
    /// The shared stager stillness threshold (`SleepStager.gravityStillThresholdG`, 0.01 g).
    public var movementThresholdG: Double = SleepStager.gravityStillThresholdG
    // ── Thermal (spec 6) ────────────────────────────────────────────────
    public var thermalMinValidMinutes: Int = 30
    public var thermalMinEligibleMinuteFraction: Double = 0.80
    public var preOnsetSlopeWindowSeconds: Int = 3600
    public var preOnsetSlopeMinValidMinutes: Int = 45
    public var postWakeSlopeWindowSeconds: Int = 1800
    public var postWakeSlopeMinValidMinutes: Int = 20
    /// No missing run longer than this inside a slope window (s).
    public var slopeMaxMissingRunSeconds: Int = 300
    /// Equilibration exclusion after an explicit re-wear/device-reset event (s).
    public var thermalRewearExclusionSeconds: Int = 300
    /// WHOOP 1 Hz minute bins need ≥ this many distinct accepted sample seconds.
    public var tempMinuteMinDistinctSampleSeconds: Int = 30
    /// Existing funnel plausibility band (°C).
    public var tempPlausibilityMinC: Double = 28.0
    public var tempPlausibilityMaxC: Double = 42.0
    // ── PRV (spec 7) ─────────────────────────────────────────────────────
    /// PRV diagnostics computed only when true (config-off → `disabled`).
    public var prvDiagnosticsEnabled: Bool = true
    public var prvWindowSeconds: Int = 300
    public var prvMinValidPairs: Int = 200
    public var prvMinCoverageFraction: Double = 0.90
    public var prvMaxRejectedFraction: Double = 0.05

    public init() {}

    /// The canonical v1 defaults.
    public static let v1 = SleepAnalyticsConfig()

    /// Deterministic fingerprint of the config's gate values (recorded on the document via
    /// `configVersion` plus this digest in the group metadata).
    public var gateFingerprint: String {
        var parts: [String] = [version]
        parts += [nativeEpochSeconds, nativeMinDistinctSupportedSeconds].map(String.init)
        parts += [nativeMinSupportFraction, stageSummaryMinLabelSupportedFraction,
                  stageSummaryMinInputSupportedFraction, movementThresholdG,
                  thermalMinEligibleMinuteFraction, motionMinEligibleFraction,
                  prvMinCoverageFraction, prvMaxRejectedFraction].map { String(format: "%.4f", $0) }
        parts += [minCompleteBoutsForQuantiles, primaryRateMinObservedSeconds,
                  motionMinObservedMinutes, thermalMinValidMinutes,
                  preOnsetSlopeWindowSeconds, preOnsetSlopeMinValidMinutes,
                  postWakeSlopeWindowSeconds, postWakeSlopeMinValidMinutes,
                  slopeMaxMissingRunSeconds, thermalRewearExclusionSeconds,
                  tempMinuteMinDistinctSampleSeconds].map(String.init)
        parts += [tempPlausibilityMinC, tempPlausibilityMaxC].map { String(format: "%.1f", $0) }
        parts += [prvDiagnosticsEnabled ? "1" : "0"]
        parts += [prvWindowSeconds, prvMinValidPairs].map(String.init)
        return parts.joined(separator: "|")
    }
}

// MARK: - Extractor entry point (spec section 4; shared by worker + app local path)

/// Phase 1 sleep analytics: descriptive continuity, stage dynamics, wrist movement,
/// skin-temperature trends and strictly gated SD1/SD2 PRV diagnostics for the day's
/// resolved main-night group. Pure, deterministic, Linux-compatible; no UI/DB/network/model
/// dependencies. Canonical scoring is untouched.
public enum SleepAnalyticsV1 {
    public static let schemaVersion = 1
    public static let algorithmVersion = "nara-sleep-analytics-1"
    public static let scope = "main_night"

    /// ISO-8601 UTC, second resolution (the document's `*_at` wire format).
    public static func isoUTC(_ ts: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// The deterministic document fingerprint: SHA-256 (pure Swift, Linux-safe) over the
    /// fragment ids/bounds/sources/epoch resolutions/edited lineage, the stage source version,
    /// the config gate fingerprint and the input revision. Detects a stale pre-edit document
    /// the moment effective bounds or lineage change.
    public static func documentFingerprint(input: SleepAnalyticsInput,
                                          timeline: SleepAnalyticsTimeline,
                                          config: SleepAnalyticsConfig) -> String {
        // Fragments are hashed in (start, id) order (review P3-4): the fingerprint is
        // stable under adapter fragment reordering. Stage-CONTENT changes are covered
        // through `inputRevision` (the adapter bumps it when edits re-stage a night) —
        // that dependency is documented for the worker adapter.
        var parts: [String] = []
        for f in timeline.fragments.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            parts.append("\(f.id):\(f.start):\(f.end):\(f.sourceKind.rawValue):\(f.sourceEpochSeconds.map(String.init) ?? "-")")
        }
        for f in input.fragments.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            parts.append("edit:\(f.id):\(f.edited ? 1 : 0):\(f.editRevision.map(String.init) ?? "-")")
        }
        parts.append("stage:\(input.stageSourceVersion)")
        parts.append("cfg:\(config.gateFingerprint)")
        parts.append("rev:\(input.inputRevision)")
        let joined = parts.joined(separator: "|")
        return SleepAnalyticsSHA256.hex(Data(joined.utf8))
    }
}

// MARK: - Pure Swift SHA-256 (fingerprint only; no CryptoKit — the worker builds on Linux)

/// A compact, dependency-free SHA-256 (FIPS 180-4) used ONLY for the document fingerprint.
/// Not a security boundary: it detects stale documents when effective bounds change.
enum SleepAnalyticsSHA256 {
    static func hex(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for t in 0..<16 {
                let o = chunkStart + t * 4
                w[t] = (UInt32(message[o]) << 24) | (UInt32(message[o + 1]) << 16)
                    | (UInt32(message[o + 2]) << 8) | UInt32(message[o + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in h {
            out.append(UInt8((word >> 24) & 0xff)); out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff)); out.append(UInt8(word & 0xff))
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
