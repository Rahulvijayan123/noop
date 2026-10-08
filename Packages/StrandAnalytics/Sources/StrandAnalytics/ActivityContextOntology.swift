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
    /// 1.6: sitting and standing are separate display kinds, and a fresh, confident change-of-position event
    /// lets the label follow without the display hold (a 15 s stand shows).
    /// 1.7: specialist fusion. HART's fine 18-activity distribution replaces the folded four-label channel
    /// when present (body and arm likelihoods, and the stairs / exercise gates), and the posture-shift
    /// heuristic is discounted while the learned transition expert speaks. An in-process ElderNet gait
    /// channel (`f.gait`) exists for hosts that run ElderNet inside the activity service; it stands down
    /// whenever the gait-quality channel (`f.gaitQuality`) is present, so ElderNet is never counted twice.
    /// 1.8: posture honesty. The seated / upright / recumbent split is bounded by a decaying memory of real
    /// posture evidence (the dwell prior governs persistence only, so a quiet wrist reads "stationary" rather
    /// than confident sitting or standing); a held absolute forearm-orientation channel; direction-aware
    /// transition modes; in-bed awake favours recumbent rest; the transition expert no longer loses to a quiet
    /// heuristic or erases a seen shift with a weak "none"; abstained encoder windows never open a specialist
    /// gate; a logged workout counts once; data gaps of 20–120 s flatten the belief; a pulseless, implausibly
    /// still strap reads unknown.
    /// 1.9: posture confidence follows agreement, not presence. A sitting / standing / restless claim is capped
    /// at the wrist-only ceiling unless the learned posture memory (HART's fine sit / stand rows, Inertia's
    /// posture head, an adopted personal profile) leans the same way (`ActivityEvidenceSummary.learnedPosture`),
    /// and then at a softer ceiling, never lifted; "Sitting, restless" / "Standing, restless" carry the mass of
    /// the posture they name rather than seated + upright; the four postural-transition modes share one
    /// heart-rate level (lying down was 0.15 against 0.20), so the rate cannot pick the path into a posture.
    public static let decoder = "hsmm-1.9"
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
    /// Inertia-1 motion-head evidence that shaped the state (`inertia-1:<bundle12>:<cfgtag>`). Written only
    /// when that evidence was active, so a state decoded without it encodes exactly the keys it always did.
    public var motionHeads: String?
    /// ElderNet gait evidence that shaped the state (`eldernet:<model_version>:<weights12>:<cfgtag>`). Written
    /// only when that channel was active, so a state decoded without it encodes exactly the keys it always did.
    public var gaitQuality: String?

    public init(schema: Int = ActivityContextVersions.schema,
                ontology: String = ActivityContextVersions.ontology,
                decoder: String = ActivityContextVersions.decoder,
                featureSchema: String = ActivityContextVersions.featureSchema,
                encoderId: String? = nil, encoderVersion: String? = nil, motionHeads: String? = nil,
                gaitQuality: String? = nil) {
        self.schema = schema; self.ontology = ontology; self.decoder = decoder
        self.featureSchema = featureSchema
        self.encoderId = encoderId; self.encoderVersion = encoderVersion
        self.motionHeads = motionHeads
        self.gaitQuality = gaitQuality
    }

    enum CodingKeys: String, CodingKey {
        case schema, ontology, decoder
        case featureSchema = "feature_schema"
        case encoderId = "encoder", encoderVersion = "encoder_version"
        case motionHeads = "motion_heads"
        case gaitQuality = "gait_quality"
    }
}

/// A flagged event with the probability that it really happened and when it was first flagged.
public struct ActivityTransitionEvent: Codable, Equatable, Sendable {
    public var kind: ActivityTransitionKind
    /// The highest probability the decoder gave the event while it lasted (a persisted event keeps it, whatever
    /// a display filter later shows).
    public var probability: Double
    /// Unix seconds when the decoder first flagged the event (the detection time).
    public var ts: Int
    /// Unix seconds the change began, as far as the decoder's own belief shows: the second the transition
    /// modes' mass (a postural event) or the moving mass (walk / run start) first rose toward the event, or the
    /// second after the moving mass last stood at half (walk / run stop). At most `ActivityTransitionEvent.
    /// maxOnsetLeadS` before `ts`, and never after it. Causal: it uses nothing later than `ts`. nil when not
    /// known (events written before the field existed, or a decode resumed from such a snapshot).
    public var onsetTs: Int?
    /// What flagged the event: `hsmm` (the decoder's own belief), or `transition_expert` when the learned
    /// raw-IMU transition expert was speaking (confident, not abstained) while the event's excursion was open.
    /// nil on events written before the field existed.
    public var source: String?

    /// Longest back-dating of `onsetTs` before the detection second.
    public static let maxOnsetLeadS = 10
    public static let sourceDecoder = "hsmm"
    public static let sourceTransitionExpert = "transition_expert"

    public init(kind: ActivityTransitionKind, probability: Double, ts: Int, onsetTs: Int? = nil,
                source: String? = nil) {
        self.kind = kind; self.probability = probability; self.ts = ts
        self.onsetTs = onsetTs; self.source = source
    }

    enum CodingKeys: String, CodingKey {
        // Written only when known (synthesized `encodeIfPresent`), so an event without them encodes as before.
        case kind, probability, ts, onsetTs = "onset_ts", source
    }

    /// A change of position (sit / stand / lie / get up), as opposed to starting or stopping a walk or run.
    public var isPostural: Bool {
        switch kind {
        case .sitToStandLike, .standToSitLike, .lyingDownLike, .gettingUpLike: return true
        case .walkStart, .walkStop, .runStart, .runStop: return false
        }
    }

    /// Whether `other` is the same flagged event (a newer reading of it). A postural event is one excursion,
    /// identified by its detection second whatever direction it came to name (its kind may resolve after it
    /// was first flagged); a walk / run event is identified by kind and second.
    public func isSameEvent(as other: ActivityTransitionEvent) -> Bool { identity == other.identity }

    /// The key `isSameEvent` compares.
    var identity: String { isPostural ? "postural@\(ts)" : "\(kind.rawValue)@\(ts)" }

    /// `events` with `newer` folded in, in time order: a newer reading of a listed event updates it (its kind,
    /// onset and source are the newer reading's, its probability the higher of the two), anything else is added.
    /// The one merge rule every harvest uses (fresh decode, chunked decode, resumed day), so all three agree.
    public static func merging(_ events: [ActivityTransitionEvent], _ newer: [ActivityTransitionEvent])
        -> [ActivityTransitionEvent] {
        var out = events
        for e in newer {
            if let i = out.lastIndex(where: { $0.isSameEvent(as: e) }) {
                let p = max(out[i].probability, e.probability)
                out[i] = e
                out[i].probability = p
            } else {
                out.append(e)
            }
        }
        // Stable: equal seconds keep their flagging order.
        return out.enumerated().sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }.map(\.element)
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
    /// Specialist experts that spoke at this second: HART's fine activity distribution, the learned
    /// transition expert (not abstaining), the ElderNet gait expert. `true` or absent (nil), so a state
    /// without them encodes exactly as before they existed.
    public var hartFine: Bool?
    public var transitionExpert: Bool?
    public var gaitExpert: Bool?
    /// The stationary posture the decoder's LEARNED posture memory leans toward at this second (hsmm-1.9):
    /// `.seatedLikely` or `.uprightStationary` when HART's fine sit / stand rows, Inertia's posture head or an
    /// adopted personal profile have, over the recent past, favoured that posture by at least
    /// `ActivityContextModel.learnedPostureAgreementLogOdds`; nil otherwise (no learned source, or one that is
    /// undecided). Wrist cues (arm pattern, held forearm angle, a shift's direction) never set it, and neither
    /// does the transition expert. `ActivityClassifier` lets a posture claim above the wrist-only ceiling only
    /// when this AGREES with the posture claimed. Absent from the JSON when nil.
    public var learnedPosture: PostureClass?

    public init(imu: Bool, encoder: Bool, dynAccel: Bool, gravity: Bool, steps: Bool,
                heartRate: Bool, sleep: Bool, coverage: Double,
                hartFine: Bool? = nil, transitionExpert: Bool? = nil, gaitExpert: Bool? = nil,
                learnedPosture: PostureClass? = nil) {
        self.imu = imu; self.encoder = encoder; self.dynAccel = dynAccel; self.gravity = gravity
        self.steps = steps; self.heartRate = heartRate; self.sleep = sleep; self.coverage = coverage
        self.hartFine = hartFine; self.transitionExpert = transitionExpert; self.gaitExpert = gaitExpert
        self.learnedPosture = learnedPosture
    }

    /// Names of the experts behind this evidence, in a fixed order (provenance for runs and consumers).
    public var experts: [String] {
        var out: [String] = []
        if encoder { out.append(hartFine == true ? "hart_fine" : "encoder") }
        if transitionExpert == true { out.append("transition") }
        if gaitExpert == true { out.append("eldernet") }
        return out
    }

    enum CodingKeys: String, CodingKey {
        case imu, encoder, steps, sleep, coverage
        case dynAccel = "dyn_accel", gravity, heartRate = "hr"
        case hartFine = "hart_fine", transitionExpert = "transition_expert", gaitExpert = "gait_expert"
        case learnedPosture = "learned_posture"
    }
}

/// The structured, probabilistic activity state published about every 5 s.
///
/// The JSON keys `posture`, `locomotion`, `arm_behavior`, `intensity`, `transition`,
/// `overall_confidence` and `display_context` are the canonical payload; everything else is
/// provenance and context. `display_context` is a DERIVED view of the heads — consumers must not
/// treat it as ground truth or key logic on it.
/// The in-process ElderNet gait expert's reading of the last 10 s of wrist gait (REPORTED as measured; the
/// decoder fused `probability` as evidence, the quality heads are information only). Present only when a host
/// runs ElderNet inside the activity service and the gait-quality channel did not speak; the deployed
/// gait-quality channel reports through `ActivityContextState.gait` instead.
public struct ActivityGaitReading: Codable, Equatable, Sendable {
    public var probability: Double
    public var isGait: Bool
    public var cadenceSpm: Double?
    public var speedMps: Double?
    /// Seconds since the window ended.
    public var ageS: Int
    public var model: String

    public init(probability: Double, isGait: Bool, cadenceSpm: Double? = nil, speedMps: Double? = nil,
                ageS: Int, model: String) {
        self.probability = probability; self.isGait = isGait; self.cadenceSpm = cadenceSpm
        self.speedMps = speedMps; self.ageS = ageS; self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case probability = "gait_prob", isGait = "is_gait", cadenceSpm = "cadence_spm", speedMps = "speed_mps"
        case ageS = "age_s", model
    }
}

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
    /// ElderNet's metrics over the current walking stretch (reported, not evidence), present only while the
    /// gait channel is active, the posterior is on the gait modes and ElderNet detects gait. Omitted otherwise.
    public var gait: ActivityGaitSummary?
    /// The in-process ElderNet gait expert's current reading (absent unless that expert ran).
    public var gaitReading: ActivityGaitReading?

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
                versions: ActivityStateVersions,
                gait: ActivityGaitSummary? = nil,
                gaitReading: ActivityGaitReading? = nil) {
        self.ts = ts; self.posture = posture; self.locomotion = locomotion
        self.armBehavior = armBehavior; self.intensity = intensity; self.transition = transition
        self.sleep = sleep; self.wear = wear
        self.overallConfidence = overallConfidence; self.overallUncertainty = overallUncertainty
        self.headConfidence = headConfidence; self.displayContext = displayContext
        self.history = history; self.evidence = evidence; self.versions = versions
        self.gait = gait
        self.gaitReading = gaitReading
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
        case gait
        case gaitReading = "gait_reading"
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
        // Optional block: written only when present, so a state without it encodes the keys it always did.
        if let gait { try c.encode(gait, forKey: .gait) }
        try c.encodeIfPresent(gaitReading, forKey: .gaitReading)
    }
}
