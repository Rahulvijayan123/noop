import Foundation

// ActivityContextOntology.swift — ontology v2: independent, probabilistic activity heads.
//
// v1 (`ActivityContextTypes.swift`) carries ONE coarse motion label per 30-s epoch. v2 keeps that
// document and adds a richer, temporally decoded state: several heads that are each a probability
// distribution, never a forced class. A wrist IMU cannot see body height, so posture is a *likelihood*
// ("seated_likely"), not a measurement, and composite labels ("Desk sitting") are derived views.
//
// Everything here is a plain value type with no I/O so the whole decoder runs in a unit test.

/// Version stamps carried on every persisted state so old and new decoders / ontologies / encoders can
/// be compared offline. Bump the matching constant whenever behaviour that changes outputs changes.
public enum ActivityContextVersions {
    /// Persisted-state schema (additive over the v1 document, whose `schema_version` is 1).
    public static let schema = 2
    /// Head vocabularies below.
    public static let ontology = "v2.0"
    /// Temporal decoder structure + parameter tables. 1.3: sleep evidence is the staged sleep (wake inside a
    /// night is awake, not asleep) and the night's in-bed window is carried beside it (`SleepContext.inBed`).
    /// 1.4: `workoutCovers(.unspecified)` covers only generic exercise (WS-06-F03), `resetBelief` clears the
    /// carried display label + hysteresis candidate (WS-05-F03), and encoder windows are uncalibrated unless
    /// the serve response says otherwise (A01).
    /// 1.5: adds the optional learned raw-IMU transition expert evidence channel (`ActivityContextModel`
    /// channel 4b) and the `transition` field on observations/features/windows.
    public static let decoder = "hsmm-1.5"
    /// Per-window IMU feature vector layout (`ImuWindowFeatures`).
    /// imu-feat-2 (2026): gyro is true RMS (not mean), jerk is per-second g/s (`jerk_rms_gps`),
    /// cadence band is 0.8–3.5 Hz. Stored imu-feat-1 output is invalidated by this bump
    /// (decoder snapshot restore + track isCurrent checks compare against this value).
    public static let featureSchema = "imu-feat-2"
}

// MARK: - Head vocabularies

/// Stationary body posture. While the wearer is moving (walking, running, cycling …) the mass sits in
/// `.unknown` and the locomotion head carries the state — the wrist cannot say how upright a walker is.
public enum PostureClass: String, Codable, CaseIterable, Hashable, Sendable {
    case recumbent
    case seatedLikely = "seated_likely"
    case uprightStationary = "upright_stationary"
    case posturalTransition = "postural_transition"
    case unknown
}

public enum LocomotionClass: String, Codable, CaseIterable, Hashable, Sendable {
    case stationary
    case walking
    case briskWalking = "brisk_walking"
    case running
    case stairs
    case cycling
    case vehicleMotion = "vehicle_motion"
    case other
    case unknown
}

public enum ArmBehaviorClass: String, Codable, CaseIterable, Hashable, Sendable {
    case quiet
    case deskLike = "desk_like"
    case fidgeting
    case repetitiveHandMotion = "repetitive_hand_motion"
    case activeGesturing = "active_gesturing"
    case exerciseMotion = "exercise_motion"
    case other
    case unknown
}

/// Discrete events the decoder can flag. Posture-change kinds end in `_like`: they are movement
/// signatures, not observed body-height changes.
public enum ActivityTransitionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sitToStandLike = "sit_to_stand_like"
    case standToSitLike = "stand_to_sit_like"
    case lyingDownLike = "lying_down_like"
    case gettingUpLike = "getting_up_like"
    case walkStart = "walk_start"
    case walkStop = "walk_stop"
    case runStart = "run_start"
    case runStop = "run_stop"
}

public enum SleepContextState: String, Codable, CaseIterable, Hashable, Sendable {
    case asleep
    case awake
    case unknown
}

public enum WearContextState: String, Codable, CaseIterable, Hashable, Sendable {
    case onWrist = "on_wrist"
    case offWrist = "off_wrist"
    case unknown
}

// MARK: - Probability head

/// A sparse probability distribution over a head vocabulary. Zero entries are omitted, so the JSON is
/// `{"seated_likely": 0.68, "unknown": 0.08}` rather than every class listed.
public struct HeadProbabilities<Class: RawRepresentable & Hashable & CaseIterable & Sendable>: Equatable, Sendable
    where Class.RawValue == String {

    public private(set) var values: [Class: Double]

    /// Entries below this are dropped from the serialized form (they are noise, not evidence).
    public static var reportFloor: Double { 0.005 }

    public init(_ values: [Class: Double] = [:]) {
        self.values = values.filter { $0.value > 0 }
    }

    public subscript(_ c: Class) -> Double { values[c] ?? 0 }

    /// Summed in vocabulary order (not dictionary order) so results are bit-for-bit reproducible.
    public var total: Double { Class.allCases.reduce(0) { $0 + (values[$1] ?? 0) } }

    /// Highest-probability class (ties break on declaration order so output is deterministic).
    public var top: (Class, Double)? {
        var best: (Class, Double)? = nil
        for c in Class.allCases {
            let p = self[c]
            if p > 0, best == nil || p > best!.1 { best = (c, p) }
        }
        return best
    }

    /// Top class excluding `exclude` (used to read "the best real answer" next to an `unknown` mass).
    public func top(excluding exclude: Class) -> (Class, Double)? {
        var best: (Class, Double)? = nil
        for c in Class.allCases where c != exclude {
            let p = self[c]
            if p > 0, best == nil || p > best!.1 { best = (c, p) }
        }
        return best
    }

    public func normalized() -> HeadProbabilities<Class> {
        let t = total
        guard t > 0 else { return self }
        return HeadProbabilities(values.mapValues { $0 / t })
    }

    /// Normalized Shannon entropy in [0, 1] (1 = uniform over the vocabulary).
    public var normalizedEntropy: Double {
        let n = Class.allCases.count
        guard n > 1 else { return 0 }
        let t = total
        guard t > 0 else { return 1 }
        var h = 0.0
        for c in Class.allCases { let p = self[c]; if p > 0 { let q = p / t; h -= q * log(q) } }
        return min(1, max(0, h / log(Double(n))))
    }
}

extension HeadProbabilities: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: Double].self)
        var v: [Class: Double] = [:]
        for (k, p) in raw { if let c = Class(rawValue: k), p > 0 { v[c] = p } }
        self.values = v
    }

    public func encode(to encoder: Encoder) throws {
        var raw: [String: Double] = [:]
        for (c, p) in values where p >= Self.reportFloor {
            raw[c.rawValue] = (p * 1000).rounded() / 1000
        }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// MARK: - Output state

/// Version stamps stored with each state. `encoder*` identifies the short-window motion encoder (HART
/// today); the decoder never assumes it is HART, so another encoder can be benchmarked in its place.
public struct ActivityStateVersions: Codable, Equatable, Sendable {
    public var schema: Int
    public var ontology: String
    public var decoder: String
    public var featureSchema: String
    public var encoderId: String?
    public var encoderVersion: String?

    public init(schema: Int = ActivityContextVersions.schema,
                ontology: String = ActivityContextVersions.ontology,
                decoder: String = ActivityContextVersions.decoder,
                featureSchema: String = ActivityContextVersions.featureSchema,
                encoderId: String? = nil, encoderVersion: String? = nil) {
        self.schema = schema; self.ontology = ontology; self.decoder = decoder
        self.featureSchema = featureSchema
        self.encoderId = encoderId; self.encoderVersion = encoderVersion
    }

    enum CodingKeys: String, CodingKey {
        case schema, ontology, decoder
        case featureSchema = "feature_schema"
        case encoderId = "encoder", encoderVersion = "encoder_version"
    }
}

/// A flagged event with the probability that it really happened and when it was first flagged.
public struct ActivityTransitionEvent: Codable, Equatable, Sendable {
    public var kind: ActivityTransitionKind
    public var probability: Double
    /// Unix seconds when the decoder first flagged the event.
    public var ts: Int

    public init(kind: ActivityTransitionKind, probability: Double, ts: Int) {
        self.kind = kind; self.probability = probability; self.ts = ts
    }
}

public struct SleepContext: Codable, Equatable, Sendable {
    public var state: SleepContextState
    /// Probability asleep when the source supplied one; nil when it only reported a state.
    public var probability: Double?
    /// Inside a detected night's in-bed window, asleep or not. Lying awake in bed is `state == .awake` with
    /// this set. Written only when true, so documents from before it existed read back unchanged.
    public var inBed: Bool

    public init(state: SleepContextState, probability: Double? = nil, inBed: Bool = false) {
        self.state = state; self.probability = probability; self.inBed = inBed
    }

    enum CodingKeys: String, CodingKey { case state, probability, inBed = "in_bed" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(SleepContextState.self, forKey: .state)
        probability = try c.decodeIfPresent(Double.self, forKey: .probability)
        inBed = try c.decodeIfPresent(Bool.self, forKey: .inBed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(probability, forKey: .probability)
        if inBed { try c.encode(true, forKey: .inBed) }
    }
}

public struct WearContext: Codable, Equatable, Sendable {
    public var state: WearContextState
    /// 1 = trustworthy contact, 0 = no usable signal. Quiet IMU is never treated as on-wrist evidence.
    public var validity: Double

    public init(state: WearContextState, validity: Double) {
        self.state = state; self.validity = validity
    }
}

/// Per-head top-class confidence (the head's best non-unknown probability).
public struct ActivityHeadConfidence: Codable, Equatable, Sendable {
    public var posture: Double
    public var locomotion: Double
    public var armBehavior: Double

    public init(posture: Double, locomotion: Double, armBehavior: Double) {
        self.posture = posture; self.locomotion = locomotion; self.armBehavior = armBehavior
    }

    enum CodingKeys: String, CodingKey {
        case posture, locomotion
        case armBehavior = "arm_behavior"
    }
}

/// Short rolling history the decoder reasons over (previous ~15 min), exposed for consumers.
public struct ActivityHistorySummary: Codable, Equatable, Sendable {
    /// Seconds since the wearer was last confidently moving (walking/running …); nil if not seen.
    public var sinceLocomotionS: Int?
    /// Seconds the wearer has been continuously stationary (posterior-weighted); 0 while moving.
    public var stationaryForS: Int
    /// Most recent events inside the history window, oldest first.
    public var recentEvents: [ActivityTransitionEvent]

    public init(sinceLocomotionS: Int?, stationaryForS: Int, recentEvents: [ActivityTransitionEvent]) {
        self.sinceLocomotionS = sinceLocomotionS; self.stationaryForS = stationaryForS
        self.recentEvents = recentEvents
    }

    enum CodingKeys: String, CodingKey {
        case sinceLocomotionS = "since_locomotion_s", stationaryForS = "stationary_for_s"
        case recentEvents = "recent_events"
    }
}

/// Which input sources contributed in the last ~30 s (a missing sensor is reported, never faked).
public struct ActivityEvidenceSummary: Codable, Equatable, Sendable {
    public var imu: Bool
    public var encoder: Bool
    public var dynAccel: Bool
    public var gravity: Bool
    public var steps: Bool
    public var heartRate: Bool
    public var sleep: Bool
    /// Weighted share of the evidence the model would ideally have, in [0, 1].
    public var coverage: Double

    public init(imu: Bool, encoder: Bool, dynAccel: Bool, gravity: Bool, steps: Bool,
                heartRate: Bool, sleep: Bool, coverage: Double) {
        self.imu = imu; self.encoder = encoder; self.dynAccel = dynAccel; self.gravity = gravity
        self.steps = steps; self.heartRate = heartRate; self.sleep = sleep; self.coverage = coverage
    }

    enum CodingKeys: String, CodingKey {
        case imu, encoder, steps, sleep, coverage
        case dynAccel = "dyn_accel", gravity, heartRate = "hr"
    }
}

/// The structured, probabilistic activity state published about every 5 s.
///
/// The JSON keys `posture`, `locomotion`, `arm_behavior`, `intensity`, `transition`,
/// `overall_confidence` and `display_context` are the canonical payload; everything else is
/// provenance and context. `display_context` is a DERIVED view of the heads — consumers must not
/// treat it as ground truth or key logic on it.
public struct ActivityContextState: Codable, Equatable, Sendable {
    /// Publish time (unix seconds). The state describes the evidence up to and including this second.
    public var ts: Int
    public var posture: HeadProbabilities<PostureClass>
    public var locomotion: HeadProbabilities<LocomotionClass>
    public var armBehavior: HeadProbabilities<ArmBehaviorClass>
    /// Continuous movement intensity in [0, 1] (log-scaled wrist acceleration); nil without motion data.
    public var intensity: Double?
    /// A recent event (within the hold window) or nil.
    public var transition: ActivityTransitionEvent?
    public var sleep: SleepContext
    public var wear: WearContext
    public var overallConfidence: Double
    /// Spread of the belief (normalized entropy blended with `unknown` mass), in [0, 1].
    public var overallUncertainty: Double
    public var headConfidence: ActivityHeadConfidence
    /// Stable composite label derived from the heads, or nil when the evidence does not support one.
    public var displayContext: String?
    public var history: ActivityHistorySummary
    public var evidence: ActivityEvidenceSummary
    public var versions: ActivityStateVersions

    public init(ts: Int,
                posture: HeadProbabilities<PostureClass>,
                locomotion: HeadProbabilities<LocomotionClass>,
                armBehavior: HeadProbabilities<ArmBehaviorClass>,
                intensity: Double?,
                transition: ActivityTransitionEvent?,
                sleep: SleepContext,
                wear: WearContext,
                overallConfidence: Double,
                overallUncertainty: Double,
                headConfidence: ActivityHeadConfidence,
                displayContext: String?,
                history: ActivityHistorySummary,
                evidence: ActivityEvidenceSummary,
                versions: ActivityStateVersions) {
        self.ts = ts; self.posture = posture; self.locomotion = locomotion
        self.armBehavior = armBehavior; self.intensity = intensity; self.transition = transition
        self.sleep = sleep; self.wear = wear
        self.overallConfidence = overallConfidence; self.overallUncertainty = overallUncertainty
        self.headConfidence = headConfidence; self.displayContext = displayContext
        self.history = history; self.evidence = evidence; self.versions = versions
    }

    enum CodingKeys: String, CodingKey {
        case ts, posture, locomotion
        case armBehavior = "arm_behavior"
        case intensity, transition, sleep, wear
        case overallConfidence = "overall_confidence"
        case overallUncertainty = "overall_uncertainty"
        case headConfidence = "head_confidence"
        case displayContext = "display_context"
        case history, evidence, versions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(posture, forKey: .posture)
        try c.encode(locomotion, forKey: .locomotion)
        try c.encode(armBehavior, forKey: .armBehavior)
        // `intensity` / `transition` / `display_context` are written as explicit nulls so the key set
        // is stable for consumers that index into the JSON.
        if let intensity { try c.encode((intensity * 1000).rounded() / 1000, forKey: .intensity) }
        else { try c.encodeNil(forKey: .intensity) }
        if let transition { try c.encode(transition, forKey: .transition) }
        else { try c.encodeNil(forKey: .transition) }
        try c.encode(sleep, forKey: .sleep)
        try c.encode(wear, forKey: .wear)
        try c.encode((overallConfidence * 1000).rounded() / 1000, forKey: .overallConfidence)
        try c.encode((overallUncertainty * 1000).rounded() / 1000, forKey: .overallUncertainty)
        try c.encode(headConfidence, forKey: .headConfidence)
        if let displayContext { try c.encode(displayContext, forKey: .displayContext) }
        else { try c.encodeNil(forKey: .displayContext) }
        try c.encode(history, forKey: .history)
        try c.encode(evidence, forKey: .evidence)
        try c.encode(versions, forKey: .versions)
    }
}
