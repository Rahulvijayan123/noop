import Foundation

// ActivityContextEvidence.swift — model-agnostic inputs to the ActivityContext decoder, and the
// causal feature window that turns a stream of per-second observations into decoder features.
//
// The decoder never sees HART specifically. A short-window motion encoder (HART today, Inertia-1 or
// anything else later) is reduced to `MotionEncoderOutput`: class probabilities over the coarse
// vocabulary, an identity/version, and an optional embedding that is carried but not consumed. Swapping
// the encoder changes nothing downstream.
//
// 100 Hz IMU capture is preserved upstream (raw files + the Python service). What reaches here is the
// compact `ImuWindowFeatures` per 4-s window plus the always-on ~1 Hz strap streams (dynAccel, gravity,
// step counter, HR). Any of those can be missing; a missing source narrows what the decoder can claim
// and is reported in the output, it is never imputed.

// MARK: - Encoder / IMU window inputs

/// Compact features of one 4-s (typically) window of the 100 Hz IMU, computed where the raw samples
/// live (the Python service, or `ImuFeatureExtractor` on device). Versioned by
/// `ActivityContextVersions.featureSchema` — imu-feat-2 (2026): the one cross-runtime contract.
public struct ImuWindowFeatures: Codable, Equatable, Sendable {
    public var startTs: Int
    public var endTs: Int
    /// RMS of gravity-removed acceleration magnitude, g.
    public var accelRmsG: Double
    /// RMS gyroscope magnitude, deg/s (imu-feat-2: true RMS in both runtimes; imu-feat-1's Swift
    /// mean-under-an-RMS-name is obsolete, WS-04-F01). Rate-invariant like any RMS; unlike the
    /// per-second jerk it carries no bandwidth caveat — magnitude RMS is exact across rates.
    public var gyroRmsDps: Double
    /// RMS first difference of acceleration magnitude × sample rate, g PER SECOND (imu-feat-2,
    /// WS-04-F02). Rate-invariant up to the documented bandwidth residual (≤5% clean, ≤10% noise).
    /// The Swift label is kept as `jerkRms` for source compatibility with the server adapter
    /// (ActivityContextDays); the wire key below is the unambiguous `jerk_rms_gps`.
    public var jerkRms: Double
    /// Dominant rhythmic frequency in the 0.8–3.5 Hz band, Hz; nil when no peak clears the strength
    /// bar. Widened from 1.2–3.5 to be honest for slow gait; HART's 4-s input contract is unchanged
    /// and slow-gait recognition still needs ~8 s windows (WS-04-F03).
    public var cadenceHz: Double?
    /// Normalized strength 0…1 of that rhythmic peak.
    public var cadenceStrength: Double
    /// Angle between the mean gravity direction of the window's first and second halves, degrees.
    /// The half-window centers are 2 s apart in a 4 s window, so this is a ~2-s-horizon change
    /// (WS-04-F04). The decoder substitutes it for the 5-s `net5` only when the gravity stream is
    /// absent — a documented 0.4× scale; decoder semantics are unchanged.
    public var orientationChangeDeg: Double?

    public init(startTs: Int, endTs: Int, accelRmsG: Double, gyroRmsDps: Double, jerkRms: Double,
                cadenceHz: Double?, cadenceStrength: Double, orientationChangeDeg: Double? = nil) {
        self.startTs = startTs; self.endTs = endTs
        self.accelRmsG = accelRmsG; self.gyroRmsDps = gyroRmsDps; self.jerkRms = jerkRms
        self.cadenceHz = cadenceHz; self.cadenceStrength = cadenceStrength
        self.orientationChangeDeg = orientationChangeDeg
    }

    /// Adapts on-device `ImuFeatureExtractor` output for a window — identity mapping onto the
    /// imu-feat-2 fields (imu-feat-1 aliased mean→RMS here; that alias is gone, WS-04-F01).
    public init(startTs: Int, endTs: Int, features: ImuActivityFeatures, orientationChangeDeg: Double? = nil) {
        self.init(startTs: startTs, endTs: endTs, accelRmsG: features.accelEnergyG,
                  gyroRmsDps: features.gyroRmsDps, jerkRms: features.jerkRmsGps,
                  cadenceHz: features.cadenceHz, cadenceStrength: features.cadenceStrength,
                  orientationChangeDeg: orientationChangeDeg)
    }

    enum CodingKeys: String, CodingKey {
        case startTs = "s", endTs = "e"
        case accelRmsG = "accel_rms_g", gyroRmsDps = "gyro_rms_dps", jerkRms = "jerk_rms_gps"
        case cadenceHz = "cadence_hz", cadenceStrength = "cadence_strength"
        case orientationChangeDeg = "orientation_change_deg"
    }
}

/// One window of a short-window motion encoder, in a model-agnostic shape.
public struct MotionEncoderOutput: Codable, Equatable, Sendable {
    /// "hart", "baseline", "inertia-1" … — only used for provenance and weighting.
    public var encoderId: String
    public var encoderVersion: String
    public var startTs: Int
    public var endTs: Int
    /// Class probabilities keyed by label raw value. The v1 head gives `stationary`, `walking`,
    /// `running`, `other_movement`; a richer encoder may add `stairs`, `cycling`, `vehicle_motion` …
    public var classProbs: [String: Double]
    /// True only when the encoder's scores come from an explicit, versioned calibration artifact
    /// (A01). It is carried on the wire from the serve response's `calibrated` field, which is
    /// derived from the manifest's `calibration` section — never inferred from encoder identity
    /// or the `baseline` flag. There is no fitted artifact today, so this is false everywhere.
    public var calibrated: Bool
    /// The encoder itself abstained (its own `unknown` / below its confidence bar).
    public var abstained: Bool
    /// Optional pooled embedding, carried for offline benchmarking; the decoder does not use it.
    public var embedding: [Float]?
    /// HART's full per-activity distribution (`wisdm-act-1`). When present the decoder reads it instead
    /// of `classProbs` (which is the same softmax folded into four labels), never both.
    public var fineProbs: [String: Double]?

    public init(encoderId: String, encoderVersion: String, startTs: Int, endTs: Int,
                classProbs: [String: Double], calibrated: Bool, abstained: Bool,
                embedding: [Float]? = nil, fineProbs: [String: Double]? = nil) {
        self.encoderId = encoderId; self.encoderVersion = encoderVersion
        self.startTs = startTs; self.endTs = endTs; self.classProbs = classProbs
        self.calibrated = calibrated; self.abstained = abstained; self.embedding = embedding
        self.fineProbs = fineProbs
    }

    /// Wraps a v1 window prediction (HART or baseline) without changing it.
    ///
    /// A01: `calibrated` comes from the prediction's own wire field (the serve response's
    /// per-window `calibrated`, derived from the manifest's calibration artifact) unless a
    /// caller overrides it. It is never derived from the `baseline` heuristic flag — model
    /// identity is not calibration provenance, and no fitted calibration artifact exists
    /// today, so every real decoded window is honestly uncalibrated (weight 0.6 in
    /// `ActivityContextModel`).
    public init(prediction: ActivityWindowPrediction, encoderId: String? = nil, encoderVersion: String,
                calibrated: Bool? = nil) {
        self.init(encoderId: encoderId ?? (prediction.baseline ? "baseline" : "hart"),
                  encoderVersion: encoderVersion,
                  startTs: prediction.startTs, endTs: prediction.endTs,
                  classProbs: prediction.probs,
                  calibrated: calibrated ?? prediction.calibrated,
                  abstained: prediction.label == .unknown,
                  fineProbs: prediction.fineProbs)
    }

    /// Older persisted encoder windows predate `calibrated` (A01) and decode as uncalibrated —
    /// a missing key never fails a stored snapshot and never reads as calibrated. (Snapshots
    /// from older decoder versions are still re-decoded by the `hsmm` version check.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        encoderId = try c.decode(String.self, forKey: .encoderId)
        encoderVersion = try c.decode(String.self, forKey: .encoderVersion)
        startTs = try c.decode(Int.self, forKey: .startTs)
        endTs = try c.decode(Int.self, forKey: .endTs)
        classProbs = try c.decode([String: Double].self, forKey: .classProbs)
        calibrated = try c.decodeIfPresent(Bool.self, forKey: .calibrated) ?? false
        abstained = try c.decodeIfPresent(Bool.self, forKey: .abstained) ?? false
        embedding = try c.decodeIfPresent([Float].self, forKey: .embedding)
        fineProbs = try c.decodeIfPresent([String: Double].self, forKey: .fineProbs)
    }
}

/// One window's output of the learned raw-IMU transition expert (see `Tools/ActivityContext`), in a
/// model-agnostic shape like `MotionEncoderOutput`. The expert classifies a 4-s window into five
/// canonical classes — `none` (no posture change) and the four transitions the HSMM can be in — and is
/// carried through the feature window as `ActivityFeatures.transition`.
///
/// The decoder consumes only the five class probabilities and `abstained` (see channel 4b in
/// `ActivityContextModel.score`). `confidence`, `modelVersion` and `preprocessingVersion` are
/// provenance, carried but not consumed, so swapping the expert (or its feature schema) changes
/// nothing downstream. Absent evidence skips the channel entirely — the day decodes exactly as it did
/// before the expert existed.
public struct TransitionEncoderEvidence: Codable, Equatable, Sendable {
    /// Canonical class probabilities (the expert's own calibration).
    public var none: Double
    public var sitToStand: Double
    public var standToSit: Double
    public var lieDown: Double
    public var getUp: Double
    /// The expert's confidence in its output; provenance only, not consumed by the decoder.
    public var confidence: Double
    public var modelVersion: String
    public var preprocessingVersion: String
    /// The expert abstained (its own unknown / below its confidence bar): the channel is skipped and
    /// the no-model fallback (channel 3b) stays in charge.
    public var abstained: Bool

    public init(none: Double, sitToStand: Double, standToSit: Double, lieDown: Double, getUp: Double,
                confidence: Double, modelVersion: String, preprocessingVersion: String,
                abstained: Bool = false) {
        self.none = none; self.sitToStand = sitToStand; self.standToSit = standToSit
        self.lieDown = lieDown; self.getUp = getUp; self.confidence = confidence
        self.modelVersion = modelVersion; self.preprocessingVersion = preprocessingVersion
        self.abstained = abstained
    }

    enum CodingKeys: String, CodingKey {
        case none, confidence, abstained
        case sitToStand = "sit_to_stand", standToSit = "stand_to_sit"
        case lieDown = "lie_down", getUp = "get_up"
        case modelVersion = "model_version", preprocessingVersion = "preprocessing_version"
    }
}

// MARK: - Per-second observation

/// Whether the strap is on the wrist. Quiet IMU is never on-wrist evidence; contact (a valid pulse) or
/// an explicit device event is.
public enum WearEvidence: String, Codable, Equatable, Sendable {
    case onWrist, offWrist, unknown
}

public enum SleepEvidence: String, Codable, Equatable, Sendable {
    case asleep, awake, unknown
}

/// What kind of effort a logged workout covers, as far as its sport name says. The decoder uses it to
/// decide which specialist modes the workout can *explain*: a logged run is no evidence of cycling, and a
/// logged ride is no evidence of stair-climbing.
public enum WorkoutKind: String, Codable, Equatable, Sendable {
    /// A workout covers the time but its sport is not known (or not recognised): behaves like the
    /// pre-`hsmm-1.2` boolean.
    case unspecified
    case running, walking, cycling
    /// Any other sport (strength, rowing, HIIT, court sports …).
    case other

    /// Sport names are free text (a strap's own labels, the manual picker, Apple Health and activity-file
    /// imports), so they are matched by whole word: "Ab crunches" is not a run, "Spinal mobility" is not a
    /// spin class and "Bikram yoga" is not a bike ride. CamelCase identifiers ("MountainBiking") are split
    /// into their words first.
    public init(sport: String?) {
        let words = WorkoutKind.words(in: sport ?? "")
        if words.isEmpty { self = .unspecified }
        else if words.contains(where: { $0.hasPrefix("cycl") || WorkoutKind.cyclingWords.contains($0) }) { self = .cycling }
        else if words.contains(where: { WorkoutKind.runningWords.contains($0) }) { self = .running }
        else if words.contains(where: { $0.hasPrefix("walk") || $0.hasPrefix("hik") || WorkoutKind.ruckingWords.contains($0) }) { self = .walking }
        else if words.contains("treadmill") { self = .running }
        else { self = .other }
    }

    private static let cyclingWords: Set<String> = ["bike", "bikes", "biking", "biker", "ebike", "spin", "spinning", "peloton"]
    private static let runningWords: Set<String> = ["run", "runs", "running", "runner", "jog", "jogging", "jogger", "marathon", "parkrun"]
    private static let ruckingWords: Set<String> = ["ruck", "rucks", "rucking"]

    private static func words(in sport: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLowercase = false
        for character in sport {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
                previousWasLowercase = false
                continue
            }
            if character.isUppercase, previousWasLowercase, !current.isEmpty {
                words.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previousWasLowercase = character.isLowercase
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }
}

/// Everything the decoder is told about one second. All sensor fields are optional on purpose.
public struct ActivityObservation: Equatable, Sendable {
    /// Unix seconds; the second this observation closes.
    public var ts: Int
    /// The strap's own gravity-removed acceleration magnitude, g (≈1 Hz).
    public var dynAccelG: Double?
    /// Gravity vector in g (any scale; only its direction is used).
    public var gravity: [Double]?
    /// Step-counter ticks gained since the previous second; nil when there is no step sample.
    public var stepTicks: Int?
    /// Strap activity class for this second: 0 still, 1 walk, 2 run.
    public var strapClass: Int?
    public var hrBpm: Int?
    /// A new IMU window that completed at or before `ts` (carried until superseded).
    public var imu: ImuWindowFeatures?
    /// A new encoder window that completed at or before `ts`.
    public var encoder: MotionEncoderOutput?
    /// A new learned transition-expert window that completed at or before `ts` (optional; absent means
    /// the expert did not speak for this second, which is exactly the pre-expert behaviour).
    public var transition: TransitionEncoderEvidence?
    /// A new ElderNet gait window that completed at or before `ts` (optional, like `transition`).
    public var gait: GaitExpertEvidence?
    public var wear: WearEvidence
    /// Staged sleep: `.asleep` only on a night's sleep epochs. Lying awake inside the night is `.awake`.
    public var sleep: SleepEvidence
    /// Inside a detected night's in-bed window, whether or not asleep.
    public var inBed: Bool
    /// A logged workout covers this second.
    public var loggedWorkout: Bool
    /// What the covering workout is (meaningful only while `loggedWorkout`).
    public var workoutKind: WorkoutKind
    /// A new Inertia-1 motion-heads window attached to this second (carried until superseded or older than
    /// the bundle's hop). A separate channel from `encoder`; ignored unless `ActivityDecoderConfig.motionHeads`
    /// accepts its bundle. It never creates an observation second of its own.
    public var motionHeads: MotionHeadsWindow?
    /// A new ElderNet gait-quality window attached to this second (carried until superseded or older than the
    /// model's hop). Its own channel, never `encoder` and never `motionHeads`; ignored unless
    /// `ActivityDecoderConfig.gaitQuality` accepts its model. It never creates an observation second of its own.
    public var gaitQuality: GaitQualityWindow?

    public init(ts: Int, dynAccelG: Double? = nil, gravity: [Double]? = nil, stepTicks: Int? = nil,
                strapClass: Int? = nil, hrBpm: Int? = nil, imu: ImuWindowFeatures? = nil,
                encoder: MotionEncoderOutput? = nil, transition: TransitionEncoderEvidence? = nil,
                gait: GaitExpertEvidence? = nil,
                wear: WearEvidence = .unknown,
                sleep: SleepEvidence = .unknown, inBed: Bool = false, loggedWorkout: Bool = false,
                workoutKind: WorkoutKind = .unspecified, motionHeads: MotionHeadsWindow? = nil,
                gaitQuality: GaitQualityWindow? = nil) {
        self.ts = ts; self.dynAccelG = dynAccelG; self.gravity = gravity; self.stepTicks = stepTicks
        self.strapClass = strapClass; self.hrBpm = hrBpm; self.imu = imu; self.encoder = encoder
        self.transition = transition; self.gait = gait
        self.wear = wear; self.sleep = sleep; self.inBed = inBed; self.loggedWorkout = loggedWorkout
        self.workoutKind = workoutKind; self.motionHeads = motionHeads; self.gaitQuality = gaitQuality
    }
}

// MARK: - Intensity scale

/// Continuous movement intensity on a log scale: 5 mg → 0, 1.5 g → 1. The anchors come from this
/// strap's own data (resting wrist ≈ 7 mg, walking median ≈ 135 mg, running median ≈ 400 mg).
public enum ActivityIntensity {
    public static let floorG = 0.005
    public static let ceilingG = 1.5

    public static func scale(g: Double) -> Double {
        guard g.isFinite, g > 0 else { return 0 }
        let lo = log10(floorG), hi = log10(ceilingG)
        return min(1, max(0, (log10(g) - lo) / (hi - lo)))
    }
}

// MARK: - Feature window

/// Features derived from the trailing window at one decoder step. Every field is optional: absence means
/// the source was not available, and the observation model skips that channel instead of guessing.
struct ActivityFeatures: Equatable {
    var ts: Int
    // Movement intensity (0…1, log scale) over trailing windows.
    var m4: Double?
    var m10: Double?
    var m30: Double?
    /// Median per-second movement over 30 s (needs ≥ 10 samples): what the wrist does most of the time.
    var mMed30: Double?
    /// Strongest 3-s mean in the last 10 s — a burst measure that one stray sample cannot move.
    var mBurst10: Double?
    /// Coefficient of variation (std/mean) of linear acceleration over 30 s: burstiness.
    var cv30: Double?
    // Gait / rhythm.
    var gaitPresence: Double?
    var cadenceSpm: Double?
    var runShare6: Double?
    var rhythm: Double?
    // Orientation (from gravity direction).
    var orientPath10: Double?
    var net5: Double?
    var net30: Double?
    /// Angle between the orientation held ~14–32 s ago and the (stable) orientation of the last 3 s;
    /// nil unless the wrist is currently still and both ends have data. A reach that returns to where it
    /// started scores ~0; a posture change that leaves the wrist somewhere new keeps scoring.
    var shiftNet: Double?
    // Physiology.
    var hr: Double?
    var hrRel: Double?
    /// Trend of heart rate over the last ~3 minutes in bpm per minute (positive = rising); nil without
    /// enough spread-out samples. Read together with `hrRel`: a high rate that is rising or steady is
    /// exertion, a high rate that is falling is recovery.
    var hrSlope: Double?
    // Context.
    var wear: WearEvidence
    var sleep: SleepEvidence
    var loggedWorkout: Bool
    var workoutKind: WorkoutKind
    // Encoder.
    var encoder: MotionEncoderOutput?
    var encoderAgeS: Int?
    // Learned transition expert (optional; absent == channel skipped == pre-expert behaviour).
    var transition: TransitionEncoderEvidence?
    var transitionAgeS: Int?
    // ElderNet gait expert (optional; absent == channel skipped).
    var gait: GaitExpertEvidence?
    var gaitAgeS: Int?
    // Provenance (last 30 s).
    var evidence: ActivityEvidenceSummary
    /// Seconds of data in the trailing 10 s window (warm-up indicator), 0…10.
    var windowFill: Int
    /// The Inertia window that applies at this second (held for the bundle's hop), only while Inertia
    /// evidence is active.
    var motionHeads: MotionHeadsWindow?
    /// The observation's in-bed flag for this second (read only by the Inertia posture channel, which steps
    /// aside on asleep / in-bed seconds).
    var inBed = false
    /// The ElderNet window that applies at this second (held for the model's hop), only while the gait channel
    /// is active.
    var gaitQuality: GaitQualityWindow?
}

/// Causal ring of recent seconds. Codable so a decoder restart resumes with its context intact.
struct ActivityFeatureWindow: Codable, Equatable {

    struct Sample: Codable, Equatable {
        var ts: Int
        var moveG: Double?
        var dynG: Double?
        var ux: Double?
        var uy: Double?
        var uz: Double?
        var ticks: Int?
        var cls: Int?
        var hr: Int?
    }

    /// Keep a little more than the longest feature horizon (30 s).
    static let horizonS = 40

    /// Heart rate is also kept as coarse bucket means so a trend over minutes costs a few integers rather
    /// than minutes of per-second samples.
    struct HRBucket: Codable, Equatable {
        var t0: Int
        var sum: Int
        var n: Int
    }
    static let hrBucketS = 15
    /// Buckets older than this are dropped. The slope reads the last `hrSlopeSpanS` of them.
    static let hrHorizonS = 270
    static let hrSlopeSpanS = 180

    var samples: [Sample] = []
    var hrBuckets: [HRBucket] = []
    var imu: ImuWindowFeatures?
    var encoder: MotionEncoderOutput?
    var transition: TransitionEncoderEvidence?
    var gait: GaitExpertEvidence?
    var lastSleep: SleepEvidence = .unknown
    var lastSleepTs: Int?
    var lastWear: WearEvidence = .unknown
    var lastWorkoutTs: Int?
    var lastWorkoutKind: WorkoutKind = .unspecified
    var lastHrTs: Int?
    var lastHr: Int?
    var imuSeenTs: Int?
    var encoderSeenTs: Int?
    var transitionSeenTs: Int?
    /// The latest Inertia window and the second it was attached to. Only ever set while Inertia evidence is
    /// active, so a decoder without it encodes exactly the keys it always did.
    var motionHeads: MotionHeadsWindow?
    var motionHeadsSeenTs: Int?
    /// The latest ElderNet window and the second it was attached to. Only ever set while the gait channel is
    /// active, so a decoder without it encodes exactly the keys it always did.
    var gaitQuality: GaitQualityWindow?
    var gaitQualitySeenTs: Int?

    init() {}

    /// Snapshots written before the heart-rate buckets existed still decode (the missing fields take their
    /// defaults); `ActivityContextDecoder` then rejects them on the decoder version, so the day is decoded
    /// afresh rather than the file failing to read.
    private enum CodingKeys: String, CodingKey {
        case samples, hrBuckets, imu, encoder, transition, gait, lastSleep, lastSleepTs, lastWear, lastWorkoutTs
        case lastWorkoutKind, lastHrTs, lastHr, imuSeenTs, encoderSeenTs, transitionSeenTs
        case motionHeads, motionHeadsSeenTs
        case gaitQuality, gaitQualitySeenTs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decode([Sample].self, forKey: .samples)
        hrBuckets = try c.decodeIfPresent([HRBucket].self, forKey: .hrBuckets) ?? []
        imu = try c.decodeIfPresent(ImuWindowFeatures.self, forKey: .imu)
        encoder = try c.decodeIfPresent(MotionEncoderOutput.self, forKey: .encoder)
        transition = try c.decodeIfPresent(TransitionEncoderEvidence.self, forKey: .transition)
        gait = try c.decodeIfPresent(GaitExpertEvidence.self, forKey: .gait)
        lastSleep = try c.decode(SleepEvidence.self, forKey: .lastSleep)
        lastSleepTs = try c.decodeIfPresent(Int.self, forKey: .lastSleepTs)
        lastWear = try c.decode(WearEvidence.self, forKey: .lastWear)
        lastWorkoutTs = try c.decodeIfPresent(Int.self, forKey: .lastWorkoutTs)
        lastWorkoutKind = try c.decodeIfPresent(WorkoutKind.self, forKey: .lastWorkoutKind) ?? .unspecified
        lastHrTs = try c.decodeIfPresent(Int.self, forKey: .lastHrTs)
        lastHr = try c.decodeIfPresent(Int.self, forKey: .lastHr)
        imuSeenTs = try c.decodeIfPresent(Int.self, forKey: .imuSeenTs)
        encoderSeenTs = try c.decodeIfPresent(Int.self, forKey: .encoderSeenTs)
        transitionSeenTs = try c.decodeIfPresent(Int.self, forKey: .transitionSeenTs)
        motionHeads = try c.decodeIfPresent(MotionHeadsWindow.self, forKey: .motionHeads)
        motionHeadsSeenTs = try c.decodeIfPresent(Int.self, forKey: .motionHeadsSeenTs)
        gaitQuality = try c.decodeIfPresent(GaitQualityWindow.self, forKey: .gaitQuality)
        gaitQualitySeenTs = try c.decodeIfPresent(Int.self, forKey: .gaitQualitySeenTs)
    }

    mutating func reset() { self = ActivityFeatureWindow() }

    /// Ingest one observation and return the features at its timestamp. `motionHeadsHoldS` is the Inertia
    /// hold (the bundle's hop) while Inertia evidence is active, and 0 otherwise: then a window on the
    /// observation is neither kept nor reported. `gaitQualityHoldS` is the same for ElderNet (the model's hop).
    mutating func push(_ obs: ActivityObservation, restingHR: Double, maxHR: Double,
                       motionHeadsHoldS: Int = 0, gaitQualityHoldS: Int = 0) -> ActivityFeatures {
        if let imu = obs.imu { self.imu = imu; imuSeenTs = obs.ts }
        if let enc = obs.encoder { self.encoder = enc; encoderSeenTs = obs.ts }
        if let trans = obs.transition { self.transition = trans; transitionSeenTs = obs.ts }
        if motionHeadsHoldS > 0, let heads = obs.motionHeads { self.motionHeads = heads; motionHeadsSeenTs = obs.ts }
        if gaitQualityHoldS > 0, let gait = obs.gaitQuality { self.gaitQuality = gait; gaitQualitySeenTs = obs.ts }
        if let g = obs.gait { self.gait = g }
        lastSleep = obs.sleep
        if obs.sleep != .unknown { lastSleepTs = obs.ts }
        lastWear = obs.wear
        if obs.loggedWorkout { lastWorkoutTs = obs.ts; lastWorkoutKind = obs.workoutKind }

        var s = Sample(ts: obs.ts)
        if let d = obs.dynAccelG, d.isFinite, d >= 0 { s.dynG = d; s.moveG = d }
        else if let imu, obs.ts - imu.endTs <= 4, imu.accelRmsG.isFinite { s.moveG = imu.accelRmsG }
        if let g = obs.gravity, g.count >= 3 {
            let n = (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]).squareRoot()
            if n.isFinite, n > 1e-6 { s.ux = g[0] / n; s.uy = g[1] / n; s.uz = g[2] / n }
        }
        s.ticks = obs.stepTicks
        s.cls = obs.strapClass
        if let hr = obs.hrBpm, (30...220).contains(hr) {
            s.hr = hr; lastHr = hr; lastHrTs = obs.ts
            addHeartRate(hr, at: obs.ts)
        }

        if let last = samples.last, last.ts == obs.ts { samples[samples.count - 1] = s }
        else { samples.append(s) }
        let cutoff = obs.ts - Self.horizonS
        if let first = samples.first, first.ts < cutoff { samples.removeAll { $0.ts < cutoff } }

        var f = features(at: obs.ts, restingHR: restingHR, maxHR: maxHR)
        f.inBed = obs.inBed
        // An Inertia window applies each second while it is younger than one hop.
        if motionHeadsHoldS > 0, let heads = motionHeads, let seen = motionHeadsSeenTs,
           obs.ts >= seen, obs.ts - seen < motionHeadsHoldS {
            f.motionHeads = heads
        }
        // So does an ElderNet window.
        if gaitQualityHoldS > 0, let gait = gaitQuality, let seen = gaitQualitySeenTs,
           obs.ts >= seen, obs.ts - seen < gaitQualityHoldS {
            f.gaitQuality = gait
            // One ElderNet voice: the gait-quality channel is the calibrated, budgeted one, so the in-process
            // gait expert stands down on seconds where it speaks (it would count the same network twice).
            f.gait = nil; f.gaitAgeS = nil
            f.evidence.gaitExpert = nil
        }
        return f
    }

    private mutating func addHeartRate(_ hr: Int, at ts: Int) {
        let t0 = ts - ((ts % Self.hrBucketS) + Self.hrBucketS) % Self.hrBucketS
        if let last = hrBuckets.last, last.t0 == t0 {
            hrBuckets[hrBuckets.count - 1].sum += hr
            hrBuckets[hrBuckets.count - 1].n += 1
        } else if let last = hrBuckets.last, last.t0 > t0 {
            // An out-of-order second never rewrites history; the feature window is causal.
            return
        } else {
            hrBuckets.append(HRBucket(t0: t0, sum: hr, n: 1))
        }
        let cutoff = ts - Self.hrHorizonS
        if let first = hrBuckets.first, first.t0 < cutoff { hrBuckets.removeAll { $0.t0 < cutoff } }
    }

    /// Least-squares slope (bpm per minute) of the bucket means over the last `hrSlopeSpanS`. Needs at
    /// least five buckets of three-plus samples spread over a minute or more: a trend of a handful of
    /// seconds is noise, and silence (no HR) is not a flat trend.
    private func hrSlope(at now: Int) -> Double? {
        let lo = now - Self.hrSlopeSpanS
        var pts: [(t: Double, y: Double)] = []
        for b in hrBuckets where b.n >= 3 {
            let centre = b.t0 + Self.hrBucketS / 2
            if centre > lo, centre <= now { pts.append((Double(centre), Double(b.sum) / Double(b.n))) }
        }
        guard pts.count >= 5, let first = pts.first, let last = pts.last, last.t - first.t >= 60 else { return nil }
        let n = Double(pts.count)
        let mt = pts.reduce(0) { $0 + $1.t } / n, my = pts.reduce(0) { $0 + $1.y } / n
        var sxy = 0.0, sxx = 0.0
        for p in pts { sxy += (p.t - mt) * (p.y - my); sxx += (p.t - mt) * (p.t - mt) }
        guard sxx > 0 else { return nil }
        return max(-20, min(20, sxy / sxx * 60))
    }

    private func slice(_ now: Int, _ seconds: Int) -> ArraySlice<Sample> {
        // Samples are appended in time order; walk back from the end.
        var i = samples.count
        while i > 0, samples[i - 1].ts > now - seconds { i -= 1 }
        return samples[i...]
    }

    private func meanMove(_ sl: ArraySlice<Sample>) -> Double? {
        var sum = 0.0, n = 0
        for s in sl { if let g = s.moveG { sum += g; n += 1 } }
        return n > 0 ? sum / Double(n) : nil
    }

    private func angle(_ a: Sample, _ b: Sample) -> Double? {
        guard let ax = a.ux, let ay = a.uy, let az = a.uz, let bx = b.ux, let by = b.uy, let bz = b.uz else { return nil }
        let d = min(1, max(-1, ax * bx + ay * by + az * bz))
        return acos(d) * 180 / .pi
    }

    private func features(at now: Int, restingHR: Double, maxHR: Double) -> ActivityFeatures {
        let w4 = slice(now, 4), w10 = slice(now, 10), w30 = slice(now, 30), w6 = slice(now, 6)

        func scaled(_ g: Double?) -> Double? { g.map(ActivityIntensity.scale(g:)) }
        let m4 = scaled(meanMove(w4)), m10 = scaled(meanMove(w10)), m30 = scaled(meanMove(w30))

        // Burst: the strongest 3-s mean inside the last 10 s.
        var burstG: Double? = nil
        let moves = w10.compactMap { s -> (Int, Double)? in s.moveG.map { (s.ts, $0) } }
        if moves.count >= 3 {
            for i in 0..<moves.count {
                let lo = moves[i].0
                var sum = 0.0, n = 0
                for j in i..<moves.count where moves[j].0 < lo + 3 { sum += moves[j].1; n += 1 }
                if n >= 2 { burstG = max(burstG ?? 0, sum / Double(n)) }
            }
        }

        // Burstiness over 30 s on linear acceleration.
        var cv: Double? = nil
        let lin = w30.compactMap(\.moveG)
        var med: Double? = nil
        if lin.count >= 10 {
            let sorted = lin.sorted()
            let mid = sorted.count / 2
            med = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        }
        if lin.count >= 15 {
            let mean = lin.reduce(0, +) / Double(lin.count)
            if mean > 1e-4 {
                let v = lin.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lin.count)
                cv = v.squareRoot() / mean
            }
        }

        // Gait presence from the step counter (primary) over the last 6 s.
        var gait: Double? = nil, cadence: Double? = nil, runShare: Double? = nil
        var tickSum = 0, tickN = 0, runN = 0, clsN = 0
        for s in w6 {
            if let t = s.ticks { tickSum += t; tickN += 1 }
            if let c = s.cls { clsN += 1; if c == 2 { runN += 1 } }
        }
        if tickN >= 4 {
            let rate = Double(tickSum) / Double(tickN)
            gait = min(1, max(0, (rate - 1.0 / 3.0) / (4.0 / 3.0)))
            cadence = rate * 60
            if clsN > 0 { runShare = Double(runN) / Double(clsN) }
        }

        // IMU rhythm and (when steps are absent) an IMU-derived gait estimate.
        var rhythm: Double? = nil
        var imuLive: ImuWindowFeatures? = nil
        if let imu, now - imu.endTs <= 6 { imuLive = imu; rhythm = imu.cadenceStrength }
        if gait == nil, let imu = imuLive, let hz = imu.cadenceHz, imu.cadenceStrength >= 0.25 {
            gait = min(0.7, max(0, (imu.cadenceStrength - 0.25) / 0.35) * 0.7)
            cadence = hz * 60
        }

        // ElderNet gait window (held for one served hop). Without a step counter, its cadence head — a
        // network trained on wrist gait — replaces the IMU rhythm's dominant-frequency cadence. Its gait
        // probability is its own channel, never folded into `gait` here (that would count it twice).
        var gaitExpert: GaitExpertEvidence? = nil, gaitExpertAge: Int? = nil
        if let g = self.gait, now - g.endTs >= 0, now - g.endTs <= GaitExpert.holdS {
            gaitExpert = g; gaitExpertAge = now - g.endTs
            if tickN < 4, g.isGait, let spm = g.cadenceSpm, spm.isFinite, spm > 0 { cadence = spm }
        }

        // Orientation path / net change from the gravity direction.
        var path: Double? = nil
        var steps = 0.0, stepN = 0
        let g10 = Array(w10)
        if g10.count >= 2 {
            for i in 1..<g10.count where g10[i].ts - g10[i - 1].ts <= 2 {
                if let a = angle(g10[i - 1], g10[i]) { steps += a; stepN += 1 }
            }
            if stepN >= 5 { path = steps / Double(stepN) }
        }
        func net(_ seconds: Int) -> Double? {
            guard let cur = samples.last, cur.ux != nil else { return nil }
            var best: Sample? = nil
            for s in samples where abs((now - s.ts) - seconds) <= 1 && s.ux != nil {
                if best == nil || abs((now - s.ts) - seconds) < abs((now - best!.ts) - seconds) { best = s }
            }
            guard let ref = best else { return nil }
            return angle(ref, cur)
        }
        var net5 = net(5)
        let net30 = net(30)
        if net5 == nil, let imu = imuLive, let oc = imu.orientationChangeDeg { net5 = oc }

        // Held orientation now vs. the orientation before any recent movement burst.
        func meanDirection(_ lo: Int, _ hi: Int) -> (v: [Double], n: Int)? {
            var sx = 0.0, sy = 0.0, sz = 0.0, n = 0
            for s in samples where s.ts > now - hi && s.ts <= now - lo {
                if let x = s.ux, let y = s.uy, let z = s.uz { sx += x; sy += y; sz += z; n += 1 }
            }
            guard n > 0 else { return nil }
            let norm = (sx * sx + sy * sy + sz * sz).squareRoot()
            guard norm > 1e-6 else { return nil }
            return ([sx / norm, sy / norm, sz / norm], n)
        }
        var shiftNet: Double? = nil
        if let cur = meanDirection(0, 3), cur.n >= 2, let base = meanDirection(14, 32), base.n >= 6 {
            // The current end must be settled: the last 3 s may not have rotated much among themselves.
            let recent = samples.filter { $0.ts > now - 3 && $0.ux != nil }
            var settled = true
            if let first = recent.first, let last = recent.last, let a = angle(first, last), a > 20 { settled = false }
            if settled {
                let d = min(1, max(-1, cur.v[0] * base.v[0] + cur.v[1] * base.v[1] + cur.v[2] * base.v[2]))
                shiftNet = acos(d) * 180 / .pi
            }
        }

        // Heart rate.
        var hr: Double? = nil, hrRel: Double? = nil
        if let h = lastHr, let t = lastHrTs, now - t <= 10 {
            hr = Double(h)
            hrRel = min(1.2, max(-0.3, (hr! - restingHR) / max(30, maxHR - restingHR)))
        }

        // Encoder (held for a few seconds, then ignored).
        var enc: MotionEncoderOutput? = nil, encAge: Int? = nil
        if let e = encoder, now - e.endTs <= 6 { enc = e; encAge = max(0, now - e.endTs) }

        // Learned transition expert: held for a few seconds like the encoder, then ignored.
        var trans: TransitionEncoderEvidence? = nil, transAge: Int? = nil
        if let t = transition, let seen = transitionSeenTs, now - seen <= 6 {
            trans = t; transAge = max(0, now - seen)
        }

        // Provenance over the last 30 s.
        let hasDyn = w30.contains { $0.dynG != nil }
        let hasGrav = w30.contains { $0.ux != nil }
        let hasSteps = w30.contains { $0.ticks != nil }
        let hasHr = w30.contains { $0.hr != nil }
        let hasImu = imu.map { now - $0.endTs <= 30 } ?? false
        let hasEnc = encoder.map { now - $0.endTs <= 30 } ?? false
        let hasSleep = lastSleepTs.map { now - $0 <= 30 } ?? false
        let hasMove = w30.contains { $0.moveG != nil }
        var coverage = 0.0
        if hasMove { coverage += 0.35 }
        if hasSteps { coverage += 0.20 }
        if hasEnc { coverage += 0.15 }
        if hasGrav { coverage += 0.10 }
        if hasHr { coverage += 0.10 }
        if hasImu { coverage += 0.05 }
        if hasSleep { coverage += 0.05 }
        var evidence = ActivityEvidenceSummary(imu: hasImu, encoder: hasEnc, dynAccel: hasDyn, gravity: hasGrav,
                                               steps: hasSteps, heartRate: hasHr, sleep: hasSleep, coverage: coverage)
        // Which experts spoke for THIS second (absent = did not), so a state says what it stands on.
        if let e = enc, e.fineProbs.flatMap(HartFineActivities.vector) != nil { evidence.hartFine = true }
        if let t = trans, !t.abstained { evidence.transitionExpert = true }
        if gaitExpert != nil { evidence.gaitExpert = true }

        let workout = lastWorkoutTs.map { now - $0 <= 2 } ?? false
        let slope: Double? = (hr != nil) ? hrSlope(at: now) : nil
        return ActivityFeatures(ts: now, m4: m4, m10: m10, m30: m30, mMed30: scaled(med), mBurst10: scaled(burstG), cv30: cv,
                                gaitPresence: gait, cadenceSpm: cadence, runShare6: runShare, rhythm: rhythm,
                                orientPath10: path, net5: net5, net30: net30, shiftNet: shiftNet, hr: hr, hrRel: hrRel,
                                hrSlope: slope,
                                wear: lastWear, sleep: lastSleep, loggedWorkout: workout,
                                workoutKind: workout ? lastWorkoutKind : .unspecified,
                                encoder: enc, encoderAgeS: encAge,
                                transition: trans, transitionAgeS: transAge,
                                gait: gaitExpert, gaitAgeS: gaitExpertAge,
                                evidence: evidence,
                                windowFill: min(10, w10.count))
    }
}
