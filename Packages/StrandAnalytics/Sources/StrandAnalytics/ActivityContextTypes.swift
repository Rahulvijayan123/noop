import Foundation

// ActivityContextTypes.swift — pure value types for the Nara activity-context ontology (v1).
//
// This is the shared vocabulary of the activity pipeline: the HART Python service emits per-window
// predictions (`ActivityWindowPrediction`), the temporal policy folds them into 30-s epochs on the
// UTC grid (`ActivityEpoch`), and the join layer attaches those epochs to physiological support
// intervals (`ActivityContextSummary` and the C10 "contexts" JSON). Everything here is a plain
// value type — Codable / Equatable / Sendable — with no I/O, clock or storage, so the whole policy
// runs in a unit test without Python, storage or the network.
//
// JSON names are pinned by integration contract C10 (snapshot daily.activity_context) and must not
// drift from the worker that serializes them. `unknown` is a first-class result everywhere: the
// policy abstains rather than inventing a label.

// MARK: - Ontology enums (exact C10 raw values)

/// Coarse motion label from the HART classification head (ontology v1, C2).
public enum MotionLabel: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case stationary
    case walking
    case running
    case otherMovement = "other_movement"
    case unknown
}

/// Posture label (C2). v1 keeps AUTOMATIC posture unknown; only user-confirmed intervals set it.
public enum PostureLabel: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case sitting
    case standing
    case lying
    case unknown
}

/// Exercise-session tri-state (C2). Absence of a workout record is NOT evidence of false — the
/// policy only ever emits `true` (overlap with a record) or `unknown`.
public enum ExerciseState: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case `true`
    case `false`
    case unknown
}

/// Sleep state with provenance (C2). Reuses existing sleep results; stillness alone never sets it.
public enum SleepStateLabel: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case awake
    case asleep
    case unknown
}

/// Exertion context (C2). `post_activity` marks the configurable window after supported activity
/// ends (default 600 s) and is never cleared by HR.
public enum ExertionContext: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case restingCandidate = "resting_candidate"
    case active
    case postActivity = "post_activity"
    case mixed
    case unknown
}

/// Wear state (C2). Quiet IMU is never on-wrist evidence — the policy defaults to `unknown` unless
/// device/contact evidence is supplied.
public enum WearState: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case onWrist = "on_wrist"
    case offWrist = "off_wrist"
    case unknown
}

/// Metric-specific measurement quality (C2) — independent of activity confidence. v1 defines the
/// vocabulary only; each physiological metric supplies its own reasons.
public enum MeasurementQuality: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case acceptable
    case uncertain
    case poor
    case unavailable
}

/// Snapshot-level activity availability (C10 `status`).
public enum ActivityStatus: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case available
    case partial
    case noData = "no_data"
    case pending
}

// MARK: - Epoch / window value types

/// One 30-s supported epoch on the UTC grid (C10 epoch row).
public struct ActivityEpoch: Codable, Equatable, Sendable {
    public let startTs: Int
    public let endTs: Int
    public let motion: MotionLabel
    public let posture: PostureLabel
    public let exercise: ExerciseState
    public let sleepState: SleepStateLabel
    public let exertion: ExertionContext
    public let wear: WearState
    /// Wear-signal-quality classification for the epoch (feat/wear-signal-quality V1): the
    /// six-state interpretation context from `WearSignalQualityEngine`. Optional and additive:
    /// older documents/rows decode as nil (missing evidence, never fabricated), the existing
    /// three-state `wear` enrichment stays the authority, and `coarseWear` folds back into it.
    public let wearSignal: WearSignalState?
    /// Model confidence in the epoch's motion decision, in [0, 1] (0 when the epoch abstained).
    public let confidence: Double
    /// Seconds of the epoch covered by at least one model window (observed, incl. abstaining).
    public let observedS: Int
    /// Seconds of the epoch covered by ACCEPTED (confident, non-unknown) windows.
    public let validS: Int

    public init(startTs: Int, endTs: Int, motion: MotionLabel, posture: PostureLabel,
                exercise: ExerciseState, sleepState: SleepStateLabel,
                exertion: ExertionContext, wear: WearState,
                wearSignal: WearSignalState? = nil,
                confidence: Double, observedS: Int, validS: Int) {
        self.startTs = startTs; self.endTs = endTs
        self.motion = motion; self.posture = posture; self.exercise = exercise
        self.sleepState = sleepState; self.exertion = exertion; self.wear = wear
        self.wearSignal = wearSignal
        self.confidence = confidence; self.observedS = observedS; self.validS = validS
    }

    /// Full grid width of the epoch (normally 30 s; partial at run edges).
    public var durationSeconds: Int { endTs - startTs }

    /// Fraction of the epoch that abstained (no accepted window), in [0, 1].
    ///
    /// Invariant maintained by the epoch builder: an epoch whose `motion` is `.unknown` has
    /// `validS == 0`, so `unknownFraction` is 1 for it and the interval joins need only this
    /// quantity to split label-share vs unknown-share.
    public var unknownFraction: Double {
        observedS > 0 ? Double(observedS - validS) / Double(observedS) : 1.0
    }

    /// Whether the epoch is a supported, non-stationary activity (walking/running).
    public var isSupportedNonStationary: Bool {
        motion == .walking || motion == .running
    }

    enum CodingKeys: String, CodingKey {
        case startTs = "s", endTs = "e", motion = "m", posture = "p", exercise = "ex",
             sleepState = "sl", exertion = "ec", wear = "w", wearSignal = "wsq",
             confidence = "c", observedS = "os", validS = "vs"
    }
}

/// One 4-s model window prediction returned by the Python service (C10 serve protocol).
public struct ActivityWindowPrediction: Codable, Equatable, Sendable {
    public let startTs: Int
    public let endTs: Int
    public let label: MotionLabel
    /// Raw class probabilities keyed by ontology label raw value (e.g. "walking": 0.91).
    public let probs: [String: Double]
    /// True when the window came from the conservative heuristic baseline, not HART.
    public let baseline: Bool
    /// A01: calibrated status carried on the wire from the serve response (which derives it from
    /// the manifest's calibration artifact). Absent on older payloads -> false (uncalibrated).
    /// Never derived from `baseline` — model identity is not calibration provenance.
    public let calibrated: Bool

    public init(startTs: Int, endTs: Int, label: MotionLabel,
                probs: [String: Double], baseline: Bool = false, calibrated: Bool = false) {
        self.startTs = startTs; self.endTs = endTs; self.label = label
        self.probs = probs; self.baseline = baseline; self.calibrated = calibrated
    }

    /// Older payloads predate the `calibrated` wire field (A01) and decode as uncalibrated —
    /// a missing key must never fail the window, and must never read as calibrated.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startTs = try c.decode(Int.self, forKey: .startTs)
        endTs = try c.decode(Int.self, forKey: .endTs)
        label = try c.decode(MotionLabel.self, forKey: .label)
        probs = try c.decode([String: Double].self, forKey: .probs)
        baseline = try c.decodeIfPresent(Bool.self, forKey: .baseline) ?? false
        calibrated = try c.decodeIfPresent(Bool.self, forKey: .calibrated) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startTs, forKey: .startTs)
        try c.encode(endTs, forKey: .endTs)
        try c.encode(label, forKey: .label)
        try c.encode(probs, forKey: .probs)
        try c.encode(baseline, forKey: .baseline)
        try c.encode(calibrated, forKey: .calibrated)
    }

    /// Highest class probability across `probs`, or nil when `probs` is empty.
    public var maxProb: Double? { probs.values.max() }

    /// Top-2 margin (max − second max), or nil when fewer than two classes are present.
    public var top2Margin: Double? {
        let sorted = probs.values.sorted(by: >)
        guard sorted.count >= 2 else { return nil }
        return sorted[0] - sorted[1]
    }

    enum CodingKeys: String, CodingKey {
        case startTs = "s", endTs = "e", label = "label", probs = "probs", baseline = "baseline"
        case calibrated
    }
}

/// A causal label flip recorded by the temporal policy, with the offset where the new label's
/// data actually began (the first of the `requiredConsecutiveVotes` disagreeing windows).
public struct ActivityTransition: Codable, Equatable, Sendable {
    public let from: MotionLabel
    public let to: MotionLabel
    /// Unix seconds of the first disagreeing window that started the flip.
    public let offset: Int

    public init(from: MotionLabel, to: MotionLabel, offset: Int) {
        self.from = from; self.to = to; self.offset = offset
    }
}

/// Result of building epochs from window predictions.
public struct ActivityEpochBuild: Equatable, Sendable {
    public let epochs: [ActivityEpoch]
    /// Causal label flips (hysteresis-verified), newest last, with transition offsets.
    public let transitions: [ActivityTransition]

    public init(epochs: [ActivityEpoch], transitions: [ActivityTransition]) {
        self.epochs = epochs; self.transitions = transitions
    }
}

// MARK: - Interval join result

/// Duration-weighted activity composition over a physiological support interval (spec §9).
public struct ActivityContextSummary: Equatable, Sendable {
    /// Duration-weighted motion shares (valid seconds only), keyed by label. Never includes
    /// `.unknown` — unknown seconds live in `unknownShare`. Sum(shares) + unknownShare == 1.
    public let shares: [MotionLabel: Double]
    public let unknownShare: Double
    /// Number of motion-label changes between consecutive overlapping epochs.
    public let transitions: Int
    /// Seconds since the last supported non-stationary epoch ended, measured from the interval
    /// end; nil when no supported epoch ends at or before the interval end.
    public let recentActivity: Int?
    /// "user_confirmed" | "model" | "none" — v1 policy only ever writes user_confirmed or none.
    public let postureSource: String
    /// Metric-agnostic quality reasons derived from the overlapping epochs.
    public let qualityReasons: [String]

    public init(shares: [MotionLabel: Double], unknownShare: Double, transitions: Int,
                recentActivity: Int?, postureSource: String, qualityReasons: [String]) {
        self.shares = shares; self.unknownShare = unknownShare
        self.transitions = transitions; self.recentActivity = recentActivity
        self.postureSource = postureSource; self.qualityReasons = qualityReasons
    }

    /// Share (valid-weighted) of a single label in [0, 1].
    public func share(of label: MotionLabel) -> Double { shares[label] ?? 0 }

    enum CodingKeys: String, CodingKey {
        case shares = "shares", unknownShare = "unknown_share", transitions = "transitions",
             recentActivity = "recent_activity", postureSource = "posture_source",
             qualityReasons = "quality_reasons"
    }
}

extension ActivityContextSummary: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawShares = try c.decode([String: Double].self, forKey: .shares)
        var shares: [MotionLabel: Double] = [:]
        for (raw, value) in rawShares {
            if let label = MotionLabel(rawValue: raw) { shares[label] = value }
        }
        self.shares = shares
        self.unknownShare = try c.decode(Double.self, forKey: .unknownShare)
        self.transitions = try c.decode(Int.self, forKey: .transitions)
        self.recentActivity = try c.decodeIfPresent(Int.self, forKey: .recentActivity)
        self.postureSource = try c.decode(String.self, forKey: .postureSource)
        self.qualityReasons = try c.decode([String].self, forKey: .qualityReasons)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var rawShares: [String: Double] = [:]
        for (label, value) in shares { rawShares[label.rawValue] = value }
        try c.encode(rawShares, forKey: .shares)
        try c.encode(unknownShare, forKey: .unknownShare)
        try c.encode(transitions, forKey: .transitions)
        try c.encodeIfPresent(recentActivity, forKey: .recentActivity)
        try c.encode(postureSource, forKey: .postureSource)
        try c.encode(qualityReasons, forKey: .qualityReasons)
    }
}

// MARK: - C10 snapshot shapes

/// Day-level snapshot summary (C10 `summary`).
public struct ActivitySnapshotSummary: Codable, Equatable, Sendable {
    /// Total valid (accepted) seconds across the epoch grid.
    public let supportedS: Int
    /// Fraction of observed seconds that abstained, in [0, 1].
    public let unknownShare: Double
    /// Number of motion-label changes between adjacent epochs on the grid.
    public let transitions: Int

    public init(supportedS: Int, unknownShare: Double, transitions: Int) {
        self.supportedS = supportedS; self.unknownShare = unknownShare
        self.transitions = transitions
    }

    enum CodingKeys: String, CodingKey {
        case supportedS = "supported_s", unknownShare = "unknown_share", transitions = "transitions"
    }
}

/// Activity composition aligned to a 15-min HRV slot (C10 `contexts.hrv_slots`).
public struct HrvSlotContext: Codable, Equatable, Sendable {
    /// Slot start (Unix seconds); the slot interval is `[slot_s, slot_s + 900)`.
    public let slotS: Int
    /// Duration-weighted motion shares over the WHOLE slot bucket.
    public let shares: [String: Double]
    public let unknownShare: Double
    /// Seconds since the last supported activity ended, from the slot end; nil when none.
    public let recentActivityS: Int?
    /// True when the slot overlaps the post-activity annotation window.
    public let postActivity: Bool

    public init(slotS: Int, shares: [String: Double], unknownShare: Double,
                recentActivityS: Int?, postActivity: Bool) {
        self.slotS = slotS; self.shares = shares; self.unknownShare = unknownShare
        self.recentActivityS = recentActivityS; self.postActivity = postActivity
    }

    enum CodingKeys: String, CodingKey {
        case slotS = "slot_s", shares = "shares", unknownShare = "unknown_share",
             recentActivityS = "recent_activity_s", postActivity = "post_activity"
    }
}

/// Activity composition aligned to a sleep session (C10 `contexts.sleep_sessions`).
public struct SleepSessionContext: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let shares: [String: Double]
    public let unknownShare: Double

    public init(start: Int, end: Int, shares: [String: Double], unknownShare: Double) {
        self.start = start; self.end = end; self.shares = shares; self.unknownShare = unknownShare
    }

    enum CodingKeys: String, CodingKey {
        case start = "start", end = "end", shares = "shares", unknownShare = "unknown_share"
    }
}

/// `contexts` object of the C10 snapshot.
public struct ActivityContexts: Codable, Equatable, Sendable {
    public let hrvSlots: [HrvSlotContext]
    public let sleepSessions: [SleepSessionContext]

    public init(hrvSlots: [HrvSlotContext], sleepSessions: [SleepSessionContext]) {
        self.hrvSlots = hrvSlots; self.sleepSessions = sleepSessions
    }

    enum CodingKeys: String, CodingKey {
        case hrvSlots = "hrv_slots", sleepSessions = "sleep_sessions"
    }
}

/// The `daily.activity_context` snapshot object (C10, exact JSON).
public struct ActivityContextDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let ontologyVersion: String
    public let modelVersion: String
    public let preprocessingVersion: String
    public let inputRevision: Int
    /// ISO-8601 wall time through which activity data is fresh (dedicated activity dataThrough).
    public let dataThrough: String
    public let status: ActivityStatus
    public let reasons: [String]
    public let epochs: [ActivityEpoch]
    public let summary: ActivitySnapshotSummary
    public let contexts: ActivityContexts

    public init(schemaVersion: Int = 1, ontologyVersion: String = "v1",
                modelVersion: String, preprocessingVersion: String, inputRevision: Int,
                dataThrough: String, status: ActivityStatus, reasons: [String],
                epochs: [ActivityEpoch], summary: ActivitySnapshotSummary,
                contexts: ActivityContexts) {
        self.schemaVersion = schemaVersion; self.ontologyVersion = ontologyVersion
        self.modelVersion = modelVersion; self.preprocessingVersion = preprocessingVersion
        self.inputRevision = inputRevision; self.dataThrough = dataThrough
        self.status = status; self.reasons = reasons; self.epochs = epochs
        self.summary = summary; self.contexts = contexts
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", ontologyVersion = "ontology_version",
             modelVersion = "model_version", preprocessingVersion = "preprocessing_version",
             inputRevision = "input_revision", dataThrough = "data_through",
             status = "status", reasons = "reasons", epochs = "epochs",
             summary = "summary", contexts = "contexts"
    }
}

// MARK: - Policy inputs (enrichment evidence)

/// A user-confirmed posture interval (v1 automatic posture stays unknown).
public struct PostureAnnotation: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let posture: PostureLabel

    public init(start: Int, end: Int, posture: PostureLabel) {
        self.start = start; self.end = end; self.posture = posture
    }
}

/// Device/contact wear evidence for an interval (never inferred from quiet IMU).
public struct WearInterval: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let wear: WearState

    public init(start: Int, end: Int, wear: WearState) {
        self.start = start; self.end = end; self.wear = wear
    }
}

// MARK: - Resting eligibility (C4, NEW view, not wired to any metric)

/// Verdict for the optional context-filtered resting eligibility view (spec §9 / C4).
public struct RestingEligibility: Equatable, Sendable {
    public let eligible: Bool
    /// Human-readable rejection reasons (empty when eligible).
    public let reasons: [String]
    /// Duration-weighted stationary share over the window, in [0, 1].
    public let stationaryFraction: Double
    /// Duration-weighted valid coverage over the window, in [0, 1].
    public let coverageFraction: Double
    /// Sustained stationary seconds immediately before the window.
    public let priorStillnessS: Int
    public let onWrist: Bool
    public let awake: Bool

    public init(eligible: Bool, reasons: [String], stationaryFraction: Double,
                coverageFraction: Double, priorStillnessS: Int, onWrist: Bool, awake: Bool) {
        self.eligible = eligible; self.reasons = reasons
        self.stationaryFraction = stationaryFraction; self.coverageFraction = coverageFraction
        self.priorStillnessS = priorStillnessS; self.onWrist = onWrist; self.awake = awake
    }
}
