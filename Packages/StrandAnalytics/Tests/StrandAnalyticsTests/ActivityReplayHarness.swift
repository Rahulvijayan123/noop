import Foundation
@testable import StrandAnalytics

// ActivityReplayHarness.swift — offline replay of recorded per-second evidence through the ActivityContext
// decoder, for the system comparison HART vs Inertia vs ElderNet and their combinations (spec §22–§23).
//
// Replay record format `nara-activity-replay-1` (also documented in Tools/ActivityContext/INERTIA1.md,
// "Replay record format"). JSON Lines, UTF-8, one JSON object per line:
//
//   line 1, the header:
//     {"format": "nara-activity-replay-1",
//      "arms": ["streams", "hart", "inertia", "hart+inertia", "naive_average",
//               "eldernet", "hart+eldernet", "hart+eldernet+inertia"],            optional, default: all eight
//      "decoder": {"resting_hr": 60, "max_hr": 190},                              optional (personalised config)
//      "motion_heads": {                                                          optional; needed by the Inertia arms
//        "bundle": <a motion-heads-1 infer response without "windows" (encoder_id … hop_s, "bundle": {heads, ood})>,
//        "config": {"locomotion": 0.25, "posture": 0.25, "arm": 0.25, "body_budget": 0.5,
//                   "arm_budget": 0.5, "hart_redundancy": 0.65},                  optional, candidate defaults
//        "allow_standin_evidence_for_testing": false},                           a stand-in bundle needs true
//      "gait_quality": {                                                          optional; needed by the ElderNet arms
//        "model": <a gait-quality-1 infer response without "windows" (model_id … gait_threshold)>,
//        "gait_prior": 0.085,                                                     optional: π, the mean served gait_prob
//                                                                                 (default GaitQualityEvidenceConfig.defaultGaitPrior)
//        "config": {"gait": 0.25, "brisk": 0, "brisk_rule": "cadence", "brisk_cadence_spm": 100,
//                   "brisk_speed_mps": 1.34, "hart_redundancy": 0.65, "inertia_redundancy": 0.65,
//                   "accelerometer_budget": 0.5}}}                               optional, candidate defaults
//   (`hart_redundancy` / `inertia_redundancy` are the config ρ; the decode applies max(config ρ, the measured
//   ρ̂ constants in GaitQualityEvidenceConfig), exactly as the worker's candidate decode does.)
//   The bundle goes through exactly the wire decoder's validation (`MotionHeadsBundleInfo` decodes through
//   `MotionHeadsResponse.parseBundle`), and so does every `motion_heads` window (structure on decode, then
//   `validate(against:)` the header's bundle): a record the serve path would have refused is refused here. The
//   same holds for `gait_quality.model` (`GaitQualityResponse.parseModelInfo`: the wire's model checks behind the
//   `GaitQualityWire.modelInfoKeys` whitelist) and every `gait_quality` window.
//   every further line, one observation:
//     {"seq": "<sequence id>", "obs": <ActivityObservationRecord>}
//
// Sequences are decoded independently, in order of first appearance; inside one sequence observations must be
// in strictly increasing `ts` (one per second that has data; Inertia windows ride on an observed second, they
// never create one). `ActivityObservationRecord` mirrors `ActivityObservation` field for field:
//     ts            int, unix seconds (required)
//     dyn           number|null   strap dynAccel, g
//     grav          [x, y, z]|null gravity vector (any scale)
//     steps         int|null      step-counter ticks gained this second
//     strap_class   int|null      0 still, 1 walk, 2 run
//     hr            int|null      bpm
//     imu           {s, e, accel_rms_g, gyro_rms_dps, jerk_rms, cadence_hz|null, cadence_strength,
//                    orientation_change_deg|null}|null   a 4-s imu-feat-1 window completed at or before ts
//     encoder       {id, version, s, e, probs: {label: p}, calibrated: bool, abstained: bool}|null
//                   a HART (or baseline) window completed at or before ts; probs keyed by v1 label
//     motion_heads  a motion-heads-1 window object (s, e, posture, locomotion, arm_behavior, transition,
//                   movement_intensity, ood_score, is_ood)|null
//     gait_quality  a gait-quality-1 window object (s, e, gait_prob, is_gait, prefiltered, speed_mps, cadence_spm,
//                   stride_m, regularity, steps)|null — attached like motion_heads, never a second of its own
//     wear          "onWrist" | "offWrist" | "unknown" (default "unknown")
//     sleep         "asleep" | "awake" | "unknown" (default "unknown")
//     in_bed        bool (default false)
//     workout       bool (default false), workout_kind "unspecified"|"running"|"walking"|"cycling"|"other"
//
// Arms: `streams` drops encoder, imu, motion_heads and gait_quality; `hart` drops motion_heads and gait_quality;
// `inertia` drops encoder and gait_quality and decodes with the motion-heads config; `hart+inertia` drops
// gait_quality; `eldernet` drops encoder and motion_heads and decodes with the gait config; `hart+eldernet` drops
// motion_heads; `hart+eldernet+inertia` keeps everything with both configs. (The five original arms decode
// exactly what they decoded before ElderNet existed.) `naive_average` (gait_quality dropped) is the FORBIDDEN
// baseline kept only as an ablation: the encoder probabilities are replaced by 0.5·HART + 0.5·Inertia
// locomotion mapped to the v1 labels (stationary → stationary; walking, brisk_walking, stairs → walking;
// running → running; cycling, vehicle_motion, other → other_movement), using the latest non-OOD Inertia window
// younger than one hop, and decoded with Inertia off.
//
// Output (`nara-activity-replay-out-1`, one JSON document): per arm, per sequence, the published 5-s states
// (posture / locomotion / arm_behavior probabilities, display label, canonical class and its confidence,
// unknown mass per body head, overall confidence / uncertainty, the event field), every flagged event, and the
// motion-heads report (stamp, refusal, attach / OOD counts) and the gait-quality report; a state that carries the
// reported ElderNet block has it under `gait`.

/// Mirror of `ActivityObservation` (see the format above).
struct ActivityObservationRecord: Codable, Equatable {
    struct Encoder: Codable, Equatable {
        var id: String
        var version: String
        var s: Int
        var e: Int
        var probs: [String: Double]
        var calibrated: Bool
        var abstained: Bool
    }

    var ts: Int
    var dyn: Double?
    var grav: [Double]?
    var steps: Int?
    var strapClass: Int?
    var hr: Int?
    var imu: ImuWindowFeatures?
    var encoder: Encoder?
    var motionHeads: MotionHeadsWindow?
    var gaitQuality: GaitQualityWindow?
    var wear: WearEvidence
    var sleep: SleepEvidence
    var inBed: Bool
    var workout: Bool
    var workoutKind: WorkoutKind

    enum CodingKeys: String, CodingKey {
        case ts, dyn, grav, steps, hr, imu, encoder, wear, sleep, workout
        case strapClass = "strap_class", motionHeads = "motion_heads", inBed = "in_bed", workoutKind = "workout_kind"
        case gaitQuality = "gait_quality"
    }

    init(_ o: ActivityObservation) {
        ts = o.ts; dyn = o.dynAccelG; grav = o.gravity; steps = o.stepTicks; strapClass = o.strapClass; hr = o.hrBpm
        imu = o.imu
        encoder = o.encoder.map { Encoder(id: $0.encoderId, version: $0.encoderVersion, s: $0.startTs, e: $0.endTs,
                                          probs: $0.classProbs, calibrated: $0.calibrated, abstained: $0.abstained) }
        motionHeads = o.motionHeads; gaitQuality = o.gaitQuality; wear = o.wear; sleep = o.sleep; inBed = o.inBed
        workout = o.loggedWorkout; workoutKind = o.workoutKind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(Int.self, forKey: .ts)
        dyn = try c.decodeIfPresent(Double.self, forKey: .dyn)
        grav = try c.decodeIfPresent([Double].self, forKey: .grav)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        strapClass = try c.decodeIfPresent(Int.self, forKey: .strapClass)
        hr = try c.decodeIfPresent(Int.self, forKey: .hr)
        imu = try c.decodeIfPresent(ImuWindowFeatures.self, forKey: .imu)
        encoder = try c.decodeIfPresent(Encoder.self, forKey: .encoder)
        motionHeads = try c.decodeIfPresent(MotionHeadsWindow.self, forKey: .motionHeads)
        gaitQuality = try c.decodeIfPresent(GaitQualityWindow.self, forKey: .gaitQuality)
        wear = try c.decodeIfPresent(WearEvidence.self, forKey: .wear) ?? .unknown
        sleep = try c.decodeIfPresent(SleepEvidence.self, forKey: .sleep) ?? .unknown
        inBed = try c.decodeIfPresent(Bool.self, forKey: .inBed) ?? false
        workout = try c.decodeIfPresent(Bool.self, forKey: .workout) ?? false
        workoutKind = try c.decodeIfPresent(WorkoutKind.self, forKey: .workoutKind) ?? .unspecified
    }

    var observation: ActivityObservation {
        ActivityObservation(
            ts: ts, dynAccelG: dyn, gravity: grav, stepTicks: steps, strapClass: strapClass, hrBpm: hr, imu: imu,
            encoder: encoder.map { MotionEncoderOutput(encoderId: $0.id, encoderVersion: $0.version, startTs: $0.s,
                                                       endTs: $0.e, classProbs: $0.probs, calibrated: $0.calibrated,
                                                       abstained: $0.abstained) },
            wear: wear, sleep: sleep, inBed: inBed, loggedWorkout: workout, workoutKind: workoutKind,
            motionHeads: motionHeads, gaitQuality: gaitQuality)
    }
}

struct ActivityReplayHeader: Codable {
    struct DecoderParams: Codable {
        var restingHR: Double?
        var maxHR: Double?
        enum CodingKeys: String, CodingKey { case restingHR = "resting_hr", maxHR = "max_hr" }
    }
    struct Weights: Codable {
        var locomotion: Double?
        var posture: Double?
        var arm: Double?
        var bodyBudget: Double?
        var armBudget: Double?
        var hartRedundancy: Double?
        enum CodingKeys: String, CodingKey {
            case locomotion, posture, arm
            case bodyBudget = "body_budget", armBudget = "arm_budget", hartRedundancy = "hart_redundancy"
        }
    }
    struct MotionHeads: Codable {
        var bundle: MotionHeadsBundleInfo
        var config: Weights?
        var allowStandIn: Bool?
        enum CodingKeys: String, CodingKey {
            case bundle, config
            case allowStandIn = "allow_standin_evidence_for_testing"
        }
    }

    struct GaitWeights: Codable {
        var gait: Double?
        var brisk: Double?
        var briskRule: GaitQualityEvidenceConfig.BriskRule?
        var briskCadenceSpm: Double?
        var briskSpeedMps: Double?
        var hartRedundancy: Double?
        var inertiaRedundancy: Double?
        var accelerometerBudget: Double?
        enum CodingKeys: String, CodingKey {
            case gait, brisk, briskRule = "brisk_rule", briskCadenceSpm = "brisk_cadence_spm"
            case briskSpeedMps = "brisk_speed_mps", hartRedundancy = "hart_redundancy"
            case inertiaRedundancy = "inertia_redundancy", accelerometerBudget = "accelerometer_budget"
        }
    }
    struct GaitQuality: Codable {
        var model: GaitQualityModelInfo
        /// nil = `GaitQualityEvidenceConfig.defaultGaitPrior`.
        var gaitPrior: Double?
        var config: GaitWeights?
        enum CodingKeys: String, CodingKey { case model, gaitPrior = "gait_prior", config }
    }

    var format: String
    var arms: [String]?
    var decoder: DecoderParams?
    var motionHeads: MotionHeads?
    var gaitQuality: GaitQuality? = nil

    enum CodingKeys: String, CodingKey {
        case format, arms, decoder
        case motionHeads = "motion_heads"
        case gaitQuality = "gait_quality"
    }

    static let formatName = "nara-activity-replay-1"
    static let allArms = ["streams", "hart", "inertia", "hart+inertia", "naive_average",
                          "eldernet", "hart+eldernet", "hart+eldernet+inertia"]
}

struct ActivityReplayLine: Codable {
    var seq: String
    var obs: ActivityObservationRecord
}

enum ActivityReplay {

    struct Input {
        var header: ActivityReplayHeader
        /// Sequences in order of first appearance.
        var sequences: [(id: String, observations: [ActivityObservation])]
    }

    enum Failure: Error, CustomStringConvertible {
        case emptyFile
        case unknownFormat(String)
        case unknownArm(String)
        case line(Int, String)
        case unordered(seq: String, ts: Int)

        var description: String {
            switch self {
            case .emptyFile: return "replay file is empty"
            case .unknownFormat(let f): return "unknown replay format \(f)"
            case .unknownArm(let a): return "unknown arm \(a)"
            case .line(let n, let why): return "line \(n): \(why)"
            case .unordered(let seq, let ts): return "sequence \(seq) is not in strictly increasing ts at \(ts)"
            }
        }
    }

    static func parse(_ data: Data) throws -> Input {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { throw Failure.emptyFile }
        let header: ActivityReplayHeader
        do { header = try JSONDecoder().decode(ActivityReplayHeader.self, from: Data(first.utf8)) }
        catch { throw Failure.line(1, "\(error)") }
        guard header.format == ActivityReplayHeader.formatName else { throw Failure.unknownFormat(header.format) }
        for arm in header.arms ?? [] where !ActivityReplayHeader.allArms.contains(arm) { throw Failure.unknownArm(arm) }
        var order: [String] = []
        var bySeq: [String: [ActivityObservation]] = [:]
        let decoder = JSONDecoder()
        for (i, line) in lines.dropFirst().enumerated() {
            let record: ActivityReplayLine
            do { record = try decoder.decode(ActivityReplayLine.self, from: Data(line.utf8)) }
            catch { throw Failure.line(i + 2, "\(error)") }
            if let w = record.obs.motionHeads {
                // The same bundle checks as the wire decoder (window length, supported heads and classes, sums).
                guard let bundle = header.motionHeads?.bundle else {
                    throw Failure.line(i + 2, "motion_heads window without a header motion_heads.bundle")
                }
                do { try w.validate(against: bundle, index: i) }
                catch { throw Failure.line(i + 2, "\(error)") }
            }
            if let g = record.obs.gaitQuality {
                // The same model checks as the wire decoder (window length, threshold agreement).
                guard let model = header.gaitQuality?.model else {
                    throw Failure.line(i + 2, "gait_quality window without a header gait_quality.model")
                }
                do { try g.validate(against: model, index: i) }
                catch { throw Failure.line(i + 2, "\(error)") }
            }
            if bySeq[record.seq] == nil { order.append(record.seq); bySeq[record.seq] = [] }
            if let last = bySeq[record.seq]!.last, record.obs.ts <= last.ts {
                throw Failure.unordered(seq: record.seq, ts: record.obs.ts)
            }
            bySeq[record.seq]!.append(record.obs.observation)
        }
        return Input(header: header, sequences: order.map { ($0, bySeq[$0]!) })
    }

    /// Records for `observations` as replay lines (the inverse of `parse`, used by the parity test).
    static func encode(header: ActivityReplayHeader, sequences: [(id: String, observations: [ActivityObservation])]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        var out = try e.encode(header)
        for (id, obs) in sequences {
            for o in obs {
                out.append(0x0A)
                out.append(try e.encode(ActivityReplayLine(seq: id, obs: ActivityObservationRecord(o))))
            }
        }
        out.append(0x0A)
        return out
    }

    static func baseConfig(_ header: ActivityReplayHeader) -> ActivityDecoderConfig {
        guard let d = header.decoder else { return ActivityDecoderConfig() }
        return ActivityDecoderConfig.personalized(restingHeartRate: d.restingHR, maxHeartRate: d.maxHR)
    }

    static func inertiaConfig(_ header: ActivityReplayHeader) -> ActivityDecoderConfig? {
        guard let mh = header.motionHeads else { return nil }
        var c = baseConfig(header)
        let w = mh.config
        c.motionHeads = MotionHeadsEvidenceConfig(
            mode: .candidate, bundle: mh.bundle,
            locomotionWeight: w?.locomotion ?? MotionHeadsEvidenceConfig.defaultLocomotionWeight,
            postureWeight: w?.posture ?? MotionHeadsEvidenceConfig.defaultPostureWeight,
            armWeight: w?.arm ?? MotionHeadsEvidenceConfig.defaultArmWeight,
            bodyBudget: w?.bodyBudget ?? MotionHeadsEvidenceConfig.defaultBodyBudget,
            armBudget: w?.armBudget ?? MotionHeadsEvidenceConfig.defaultArmBudget,
            hartRedundancy: w?.hartRedundancy ?? MotionHeadsEvidenceConfig.defaultHartRedundancy,
            allowStandInEvidenceForTesting: mh.allowStandIn ?? false)
        return c
    }

    static func gaitConfig(_ header: ActivityReplayHeader, base: ActivityDecoderConfig) -> ActivityDecoderConfig? {
        guard let g = header.gaitQuality else { return nil }
        var c = base
        let w = g.config
        c.gaitQuality = GaitQualityEvidenceConfig(
            mode: .candidate, model: g.model, gaitPrior: g.gaitPrior ?? GaitQualityEvidenceConfig.defaultGaitPrior,
            gaitWeight: w?.gait ?? GaitQualityEvidenceConfig.defaultGaitWeight,
            briskWeight: w?.brisk ?? 0, briskRule: w?.briskRule ?? .cadence,
            briskCadenceSpm: w?.briskCadenceSpm ?? GaitQualityEvidenceConfig.defaultBriskCadenceSpm,
            briskSpeedMps: w?.briskSpeedMps ?? GaitQualityEvidenceConfig.defaultBriskSpeedMps,
            hartRedundancy: w?.hartRedundancy ?? GaitQualityEvidenceConfig.defaultHartRedundancy,
            inertiaRedundancy: w?.inertiaRedundancy ?? GaitQualityEvidenceConfig.defaultInertiaRedundancy,
            accelerometerBudget: w?.accelerometerBudget ?? GaitQualityEvidenceConfig.defaultAccelerometerBudget)
        return c
    }

    /// Inertia locomotion folded onto the v1 encoder labels (the naive-average ablation only).
    static func v1Labels(_ loco: [String: Double]) -> [String: Double] {
        var out: [String: Double] = ["stationary": 0, "walking": 0, "running": 0, "other_movement": 0]
        for c in MotionHead.locomotion.classOrder {
            guard let p = loco[c] else { continue }
            switch c {
            case "stationary": out["stationary"]! += p
            case "walking", "brisk_walking", "stairs": out["walking"]! += p
            case "running": out["running"]! += p
            default: out["other_movement"]! += p
            }
        }
        return out
    }

    static func naiveAverage(_ obs: [ActivityObservation], holdS: Int) -> [ActivityObservation] {
        var last: (seen: Int, window: MotionHeadsWindow)?
        return obs.map { o in
            var o = o
            if let w = o.motionHeads { last = w.isOOD || w.locomotion == nil ? nil : (o.ts, w) }
            o.motionHeads = nil
            guard let enc = o.encoder, let held = last, o.ts - held.seen < holdS,
                  let loco = held.window.locomotion else { return o }
            let inertia = v1Labels(loco)
            var mix: [String: Double] = [:]
            for k in Set(enc.classProbs.keys).union(inertia.keys).sorted() {
                mix[k] = 0.5 * (enc.classProbs[k] ?? 0) + 0.5 * (inertia[k] ?? 0)
            }
            o.encoder = MotionEncoderOutput(encoderId: enc.encoderId, encoderVersion: enc.encoderVersion,
                                            startTs: enc.startTs, endTs: enc.endTs, classProbs: mix,
                                            calibrated: enc.calibrated, abstained: enc.abstained)
            return o
        }
    }

    /// What one arm decodes, or the reason it cannot run.
    enum ArmPlan {
        case decode([ActivityObservation], ActivityDecoderConfig)
        case refused(String)
    }

    static func arm(_ name: String, _ obs: [ActivityObservation], header: ActivityReplayHeader) -> ArmPlan {
        let base = baseConfig(header)
        // The five original arms never see ElderNet windows (nor a gait config): they decode what they always did.
        let noGait = obs.map { var o = $0; o.gaitQuality = nil; return o }
        switch name {
        case "streams":
            return .decode(noGait.map { var o = $0; o.encoder = nil; o.imu = nil; o.motionHeads = nil; return o }, base)
        case "hart":
            return .decode(noGait.map { var o = $0; o.motionHeads = nil; return o }, base)
        case "inertia", "hart+inertia":
            guard let config = inertiaConfig(header) else { return .refused("no_bundle") }
            if let why = config.motionHeads?.evidenceRefusal { return .refused(why) }
            let arm = name == "inertia" ? noGait.map { var o = $0; o.encoder = nil; return o } : noGait
            return .decode(arm, config)
        case "naive_average":
            guard let mh = header.motionHeads else { return .refused("no_bundle") }
            return .decode(naiveAverage(noGait, holdS: mh.bundle.hopS), base)
        case "eldernet", "hart+eldernet":
            guard let config = gaitConfig(header, base: base) else { return .refused("no_gait_model") }
            if let why = config.gaitQuality?.evidenceRefusal { return .refused(why) }
            let arm = obs.map { o -> ActivityObservation in
                var o = o
                o.motionHeads = nil
                if name == "eldernet" { o.encoder = nil }
                return o
            }
            return .decode(arm, config)
        case "hart+eldernet+inertia":
            guard let inertia = inertiaConfig(header) else { return .refused("no_bundle") }
            if let why = inertia.motionHeads?.evidenceRefusal { return .refused(why) }
            guard let config = gaitConfig(header, base: inertia) else { return .refused("no_gait_model") }
            if let why = config.gaitQuality?.evidenceRefusal { return .refused(why) }
            return .decode(obs, config)
        default:
            return .refused("unknown_arm")
        }
    }

    static func stateRecord(_ s: ActivityContextState) -> [String: Any] {
        func head<C: RawRepresentable & Hashable & CaseIterable & Sendable>(_ h: HeadProbabilities<C>) -> [String: Double]
            where C.RawValue == String {
            var out: [String: Double] = [:]
            for c in C.allCases where h[c] > 0 { out[c.rawValue] = h[c] }
            return out
        }
        let k = ActivityClassifier.classify(state: s)
        var out: [String: Any] = [
            "ts": s.ts, "posture": head(s.posture), "locomotion": head(s.locomotion), "arm_behavior": head(s.armBehavior),
            "display": s.displayContext ?? NSNull(), "class": k.activityClass.rawValue, "class_confidence": k.confidence,
            "unknown": ["posture": s.posture[.unknown], "locomotion": s.locomotion[.unknown],
                        "arm_behavior": s.armBehavior[.unknown]],
            "overall_confidence": s.overallConfidence, "overall_uncertainty": s.overallUncertainty,
        ]
        if let t = s.transition {
            out["transition"] = ["kind": t.kind.rawValue, "probability": t.probability, "ts": t.ts]
        } else {
            out["transition"] = NSNull()
        }
        // Only the ElderNet arms can carry the reported block; every other state record is unchanged.
        if let g = s.gait, let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) {
            out["gait"] = object
        }
        return out
    }

    /// Decode every requested arm of every sequence and return the output document.
    static func run(_ input: Input) throws -> [String: Any] {
        var arms: [String: Any] = [:]
        for name in input.header.arms ?? ActivityReplayHeader.allArms {
            var perSeq: [String: Any] = [:]
            for (id, obs) in input.sequences {
                switch arm(name, obs, header: input.header) {
                case .refused(let why):
                    perSeq[id] = ["refusal": why, "states": [], "events": []] as [String: Any]
                case .decode(let armObs, let config):
                    let track = ActivityContextTrackBuilder.decode(armObs, config: config)
                    var entry: [String: Any] = [
                        "states": track.states.map(stateRecord),
                        "events": track.events.map { ["kind": $0.kind.rawValue, "probability": $0.probability, "ts": $0.ts] },
                        "observed_s": track.observedSeconds,
                        "refusal": NSNull(),
                    ]
                    if let report = track.motionHeads {
                        entry["motion_heads"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
                    }
                    if let report = track.gaitQuality {
                        entry["gait_quality"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
                    }
                    perSeq[id] = entry
                }
            }
            arms[name] = perSeq
        }
        return ["format": "nara-activity-replay-out-1", "arms": arms]
    }
}
