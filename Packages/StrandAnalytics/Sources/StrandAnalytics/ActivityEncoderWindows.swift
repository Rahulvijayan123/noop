import Foundation

// ActivityEncoderWindows.swift — the motion encoder's per-window output for one UTC day, in the compact
// `hart-windows-1` form the server stores (`activity_encoder_windows`) and the phone reads back.
//
// The raw-IMU lane runs HART over 4 s windows of the 100 Hz IMU (resampled to 30 Hz). The decoder consumes
// those windows as `ActivityWindowPrediction` (class probabilities) plus `ImuWindowFeatures` (encoder-
// independent motion facts), keyed by their end second. This type carries exactly that, so the phone's
// decoder and the server's decode the same evidence.
//
// Layout (parallel arrays, one element per window, times relative to the UTC day start `t0`):
//   labels   ontology labels; `l` indexes it and `p` follows its order
//   s, e     window start / end, seconds after t0
//   l        index of the window's (post-abstention) label
//   p        probability per label, per mille (integers keep the document small and exact)
//   b        1 when the heuristic baseline, not the trained model, produced the window
//   f        the window's features in `features` order, each scaled by `feature_scale` and rounded, or null
//            when the window carried none; a feature the window could not compute is null inside the row
//
// The learned raw-IMU transition expert's output is ADDITIVE over this layout (absent from documents
// written before it existed, and read as absent by readers that do not know it):
//   t        the window's transition-class probabilities, per mille, in `transition_class_order`
//            (none, sit_to_stand, stand_to_sit, lie_down, get_up), or null when the window has none
//   t_schema "transition-1"
//   t_v      the transition model's version; t_pv its preprocessing schema
// HART's fine-grained activity distribution, also additive and aligned with the windows:
//   h        per-mille probability per `h_labels` activity, or null when the window has none
//   h_schema "wisdm-act-1"; h_labels the activity names (`HartFineActivities.names` when written here)
// The optional ElderNet gait expert has its own 10 s windows on its own hop, so its columns are a separate
// parallel block (`g_s.count` windows, not `s.count`):
//   g_schema "gait-quality-1"; g_v the model version
//   g_s, g_e window start / end, seconds after t0
//   g_p      gait probability, per mille
//   g_f      flags: 1 = is gait, 2 = pre-filtered (static)
//   g_q      [cadence spm ×10, speed m/s ×1000, stride m ×1000, regularity ×1000, steps ×10] on gait windows
//            (each entry null when that head is missing), null otherwise
// Measured stand-ups / sit-downs (`ActivityVerticalShift`, hsmm-2.0) are another additive block, one entry per shift:
//   v_schema "vertical-shift-1"; v_v the detector version
//   v_s, v_e  the shift's movement start / end, seconds after t0
//   v_dh      net vertical displacement of the strap, millimetres (> 0 up)
//   v_q       measurement quality, per mille
//   v_vp      signed peak vertical velocity, mm/s, or null (vshift-2)
//   v_k       candidate kind: 1 burst, 2 onset, or null (vshift-2)
// Readers drop any window they cannot parse (transition rows included) instead of rejecting the document.

/// One window's output of the learned raw-IMU transition expert (optional, additive over
/// `hart-windows-1`). The expert classifies a 4-s window into `none` or one of the four transitions
/// the HSMM can be in; the decoder consumes these as `TransitionEncoderEvidence`, keyed by end second
/// like the motion-encoder windows.
public struct ActivityTransitionWindow: Equatable, Sendable {
    public var startTs: Int
    public var endTs: Int
    /// Canonical class probabilities, in `ActivityEncoderWindowSet.transitionClassOrder` order:
    /// none, sit_to_stand, stand_to_sit, lie_down, get_up.
    public var probabilities: [Double]
    public var modelVersion: String
    public var preprocessingVersion: String
    /// The expert abstained (its own unknown / below its confidence bar).
    public var abstained: Bool

    public init(startTs: Int, endTs: Int, probabilities: [Double], modelVersion: String,
                preprocessingVersion: String, abstained: Bool = false) {
        self.startTs = startTs; self.endTs = endTs; self.probabilities = probabilities
        self.modelVersion = modelVersion; self.preprocessingVersion = preprocessingVersion
        self.abstained = abstained
    }
}

public struct ActivityEncoderWindowSet: Equatable, Sendable {
    public static let format = "hart-windows-1"
    /// `transition-1`: the learned transition expert's optional per-window output (`t` rows).
    public static let transitionSchema = "transition-1"
    /// Canonical class order of the optional `t` rows. Never reorder or rename: persisted artifacts pin it.
    public static let transitionClassOrder = ["none", "sit_to_stand", "stand_to_sit", "lie_down", "get_up"]
    /// `imu-feat-2` keys, in the order `f` rows use.
    public static let featureKeys = ["accel_rms_g", "gyro_rms_dps", "jerk_rms_gps", "cadence_hz",
                                     "cadence_strength", "orientation_change_deg"]
    /// `imu-feat-1` documents name jerk `jerk_rms`, in g per sample of the 30 Hz resampled stream; × this
    /// rate gives the `imu-feat-2` g/s.
    static let legacyJerkSampleRateHz = 30.0
    /// Multiplier applied before rounding each feature to an integer (5, 3, 4, 3, 4 and 2 decimals).
    public static let featureScale: [Double] = [100_000, 1_000, 10_000, 1_000, 10_000, 100]
    /// Two-day documents hold at most this many windows (a 2 s hop over a whole day is 43,200).
    public static let maxWindows = 100_000

    /// "hart" or "baseline" (the heuristic classifier, whose scores are not calibrated).
    public var encoderId: String
    public var encoderVersion: String
    public var windows: [ActivityWindowPrediction]
    public var features: [ImuWindowFeatures]
    /// Optional learned raw-IMU transition-expert output, one entry per window that has it (additive: a
    /// set without it reads and writes exactly as before the expert existed).
    public var transitions: [ActivityTransitionWindow]
    /// Optional ElderNet gait-expert windows (their own 10 s grid; additive like `transitions`).
    public var gaitWindows: [ActivityGaitWindow]
    /// Optional measured stand-ups / sit-downs (additive like `transitions`).
    public var verticalShifts: [ActivityVerticalShiftEvidence] = []

    public static let verticalShiftSchema = "vertical-shift-1"
    public static let fineSchema = HartFineActivities.schema
    public static let gaitSchema = GaitExpert.schema
    static let gaitQualityScale: [Double] = [10, 1_000, 1_000, 1_000, 10]

    public init(encoderId: String, encoderVersion: String,
                windows: [ActivityWindowPrediction], features: [ImuWindowFeatures] = [],
                transitions: [ActivityTransitionWindow] = [], gaitWindows: [ActivityGaitWindow] = []) {
        self.encoderId = encoderId; self.encoderVersion = encoderVersion
        self.windows = windows; self.features = features; self.transitions = transitions
        self.gaitWindows = gaitWindows
    }

    public var isEmpty: Bool { windows.isEmpty }

    /// The `hart-windows-1` object for the UTC day starting at `dayStart` (JSONSerialization-ready).
    public func jsonObject(dayStart: Int) -> [String: Any] {
        let sorted = windows.sorted { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        var labels = MotionLabel.allCases.map(\.rawValue)
        let extra = Set(sorted.flatMap { $0.probs.keys }).subtracting(labels).sorted()
        labels += extra
        let labelIndex = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        var featureAt: [String: ImuWindowFeatures] = [:]
        for f in features { featureAt["\(f.startTs)-\(f.endTs)"] = f }

        var s: [Int] = [], e: [Int] = [], l: [Int] = [], b: [Int] = []
        var p: [[Int]] = [], fRows: [Any] = [], tRows: [Any] = [], hRows: [Any] = []
        let fineNames = HartFineActivities.names
        let hasFine = sorted.contains { $0.fineProbs != nil }
        s.reserveCapacity(sorted.count); e.reserveCapacity(sorted.count)
        var transitionAt: [String: ActivityTransitionWindow] = [:]
        for t in transitions { transitionAt["\(t.startTs)-\(t.endTs)"] = t }
        for w in sorted {
            s.append(w.startTs - dayStart)
            e.append(w.endTs - dayStart)
            l.append(labelIndex[w.label.rawValue] ?? labelIndex[MotionLabel.unknown.rawValue]!)
            p.append(labels.map { label in
                let value = w.probs[label] ?? 0
                return value.isFinite ? Int((min(1, max(0, value)) * 1000).rounded()) : 0
            })
            b.append(w.baseline ? 1 : 0)
            if let f = featureAt["\(w.startTs)-\(w.endTs)"] {
                let values: [Double?] = [f.accelRmsG, f.gyroRmsDps, f.jerkRms, f.cadenceHz, f.cadenceStrength,
                                         f.orientationChangeDeg]
                fRows.append(zip(values, Self.featureScale).map { value, scale -> Any in
                    guard let value, value.isFinite, abs(value * scale) < 1e15 else { return NSNull() }
                    return Int((value * scale).rounded())
                })
            } else {
                fRows.append(NSNull())
            }
            // An abstained window is written as no row: the server context day skips abstained evidence, and
            // a reader of the stored set must too, so both paths decode the same seconds identically.
            if let t = transitionAt["\(w.startTs)-\(w.endTs)"], !t.abstained {
                var row: [Int] = []
                row.reserveCapacity(Self.transitionClassOrder.count)
                for i in 0..<Self.transitionClassOrder.count {
                    let value = i < t.probabilities.count ? t.probabilities[i] : 0
                    row.append(value.isFinite ? Int((min(1, max(0, value)) * 1000).rounded()) : 0)
                }
                tRows.append(row)
            } else {
                tRows.append(NSNull())
            }
            if hasFine {
                if let fine = w.fineProbs {
                    hRows.append(fineNames.map { name -> Int in
                        let value = fine[name] ?? 0
                        return value.isFinite ? Int((min(1, max(0, value)) * 1000).rounded()) : 0
                    })
                } else {
                    hRows.append(NSNull())
                }
            }
        }
        var doc: [String: Any] = ["format": Self.format, "t0": dayStart, "labels": labels,
                                  "features": Self.featureKeys, "feature_scale": Self.featureScale,
                                  "s": s, "e": e, "l": l, "p": p, "b": b, "f": fRows]
        if hasFine {
            doc["h_schema"] = Self.fineSchema
            doc["h_labels"] = fineNames
            doc["h"] = hRows
        }
        if !gaitWindows.isEmpty {
            let gw = gaitWindows.sorted { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
            doc["g_schema"] = Self.gaitSchema
            doc["g_v"] = gw.first?.modelVersion ?? ""
            doc["g_s"] = gw.map { $0.startTs - dayStart }
            doc["g_e"] = gw.map { $0.endTs - dayStart }
            doc["g_p"] = gw.map { $0.gaitProb.isFinite ? Int((min(1, max(0, $0.gaitProb)) * 1000).rounded()) : 0 }
            doc["g_f"] = gw.map { ($0.isGait ? 1 : 0) | ($0.prefiltered ? 2 : 0) }
            doc["g_q"] = gw.map { w -> Any in
                guard w.isGait else { return NSNull() }
                let values: [Double?] = [w.cadenceSpm, w.speedMps, w.strideM, w.regularity, w.steps]
                return zip(values, Self.gaitQualityScale).map { value, scale -> Any in
                    guard let value, value.isFinite, abs(value * scale) < 1e15 else { return NSNull() }
                    return Int((value * scale).rounded())
                }
            }
        }
        if !verticalShifts.isEmpty {
            let vs = verticalShifts.sorted { ($0.startTs, $0.ts) < ($1.startTs, $1.ts) }
            doc["v_schema"] = Self.verticalShiftSchema
            doc["v_v"] = vs.first?.version ?? ActivityVerticalShift.version
            doc["v_s"] = vs.map { $0.startTs - dayStart }
            doc["v_e"] = vs.map { $0.ts - dayStart }
            doc["v_dh"] = vs.map { $0.displacementM.isFinite ? Int(($0.displacementM * 1000).rounded()) : 0 }
            doc["v_q"] = vs.map { $0.quality.isFinite ? Int((min(1, max(0, $0.quality)) * 1000).rounded()) : 0 }
            doc["v_vp"] = vs.map { v -> Any in
                guard let p = v.peakVelocity, p.isFinite, abs(p) < 100 else { return NSNull() }
                return Int((p * 1000).rounded())
            }
            doc["v_k"] = vs.map { v -> Any in v.kind == "burst" ? 1 as Any : (v.kind == "onset" ? 2 as Any : NSNull() as Any) }
        }
        // The transition-expert columns are written only when the set carries transition output, so a
        // day without the expert serializes exactly as it did before the columns existed.
        if !transitions.isEmpty {
            doc["t_schema"] = Self.transitionSchema
            doc["t_v"] = transitions.first?.modelVersion ?? ""
            doc["t_pv"] = transitions.first?.preprocessingVersion ?? ""
            doc["t"] = tRows
        }
        return doc
    }

    /// Parse a `hart-windows-1` object. nil when it is not one at all; windows that do not parse are left out.
    public static func decode(_ object: Any?, encoderId: String, encoderVersion: String) -> ActivityEncoderWindowSet? {
        guard let doc = object as? [String: Any], doc["format"] as? String == format,
              let t0 = int(doc["t0"]), let labels = doc["labels"] as? [String],
              let s = doc["s"] as? [Any], let e = doc["e"] as? [Any], let l = doc["l"] as? [Any],
              let p = doc["p"] as? [Any], let b = doc["b"] as? [Any], let f = doc["f"] as? [Any],
              s.count <= maxWindows, [e.count, l.count, p.count, b.count, f.count].allSatisfy({ $0 == s.count })
        else { return nil }
        let keys = doc["features"] as? [String] ?? featureKeys
        let scales = (doc["feature_scale"] as? [Any])?.compactMap(double) ?? featureScale
        func column(_ key: String) -> Int? {
            guard let i = keys.firstIndex(of: key), i < scales.count, scales[i] > 0 else { return nil }
            return i
        }
        let legacyJerkI = column("jerk_rms")
        let jerkI = column("jerk_rms_gps") ?? legacyJerkI
        let jerkScale = jerkI != nil && jerkI == legacyJerkI ? legacyJerkSampleRateHz : 1
        let accelI = column("accel_rms_g"), gyroI = column("gyro_rms_dps")
        let cadenceI = column("cadence_hz"), strengthI = column("cadence_strength")
        let orientI = column("orientation_change_deg")

        // Optional transition-expert rows. Present only when the document carries them (`t_schema` says
        // which schema); a doc without them reads as it always did, and a `t` that does not line up with
        // the windows is ignored rather than fatal.
        var transitionRows: [Any]? = nil
        var transitionModelVersion = ""
        var transitionPreprocessingVersion = ""
        if doc["t_schema"] as? String == transitionSchema, let rows = doc["t"] as? [Any],
           rows.count == s.count {
            transitionRows = rows
            transitionModelVersion = doc["t_v"] as? String ?? ""
            transitionPreprocessingVersion = doc["t_pv"] as? String ?? ""
        }
        var fineRows: [Any]? = nil
        var fineLabels: [String] = []
        if doc["h_schema"] as? String == fineSchema, let rows = doc["h"] as? [Any], rows.count == s.count,
           let names = doc["h_labels"] as? [String], !names.isEmpty {
            fineRows = rows
            fineLabels = names
        }

        var windows: [ActivityWindowPrediction] = [], features: [ImuWindowFeatures] = []
        var transitions: [ActivityTransitionWindow] = []
        windows.reserveCapacity(s.count)
        for i in 0..<s.count {
            guard let start = int(s[i]), let end = int(e[i]), end > start, end - start <= 3_600,
                  let li = int(l[i]), li >= 0, li < labels.count,
                  let row = p[i] as? [Any], row.count == labels.count else { continue }
            var probs: [String: Double] = [:]
            var valid = true
            for (k, value) in zip(labels, row) {
                guard let perMille = double(value), perMille >= 0, perMille <= 1000 else { valid = false; break }
                if perMille > 0 { probs[k] = perMille / 1000 }
            }
            guard valid else { continue }
            let startTs = t0 + start, endTs = t0 + end
            var fine: [String: Double]? = nil
            if let rows = fineRows, let row = rows[i] as? [Any], row.count == fineLabels.count {
                var parsed: [String: Double] = [:]
                var fineValid = true
                for (k, value) in zip(fineLabels, row) {
                    guard let perMille = double(value), perMille >= 0, perMille <= 1000 else { fineValid = false; break }
                    if perMille > 0 { parsed[k] = perMille / 1000 }
                }
                if fineValid, !parsed.isEmpty { fine = parsed }
            }
            windows.append(ActivityWindowPrediction(
                startTs: startTs, endTs: endTs, label: MotionLabel(rawValue: labels[li]) ?? .unknown,
                probs: probs, baseline: int(b[i]) == 1, fineProbs: fine))
            if let rows = transitionRows, let row = rows[i] as? [Any],
               row.count == transitionClassOrder.count {
                var tProbs: [Double] = []
                var tValid = true
                for value in row {
                    guard let perMille = double(value), perMille >= 0, perMille <= 1000 else { tValid = false; break }
                    tProbs.append(perMille / 1000)
                }
                if tValid {
                    transitions.append(ActivityTransitionWindow(startTs: startTs, endTs: endTs,
                        probabilities: tProbs, modelVersion: transitionModelVersion,
                        preprocessingVersion: transitionPreprocessingVersion))
                }
            }
            guard let fr = f[i] as? [Any] else { continue }
            func value(_ index: Int?) -> Double? {
                guard let index, index < fr.count, let raw = double(fr[index]) else { return nil }
                return raw / scales[index]
            }
            guard let accel = value(accelI), let gyro = value(gyroI), let jerk = value(jerkI),
                  let strength = value(strengthI) else { continue }
            features.append(ImuWindowFeatures(startTs: startTs, endTs: endTs, accelRmsG: accel, gyroRmsDps: gyro,
                                              jerkRms: jerk * jerkScale, cadenceHz: value(cadenceI), cadenceStrength: strength,
                                              orientationChangeDeg: value(orientI)))
        }
        var set = ActivityEncoderWindowSet(encoderId: encoderId, encoderVersion: encoderVersion,
                                           windows: windows, features: features, transitions: transitions,
                                           gaitWindows: decodeGait(doc, t0: t0))
        set.verticalShifts = decodeVerticalShifts(doc, t0: t0)
        return set
    }

    /// The optional `v_*` block; misaligned columns are ignored, an implausible row is left out.
    private static func decodeVerticalShifts(_ doc: [String: Any], t0: Int) -> [ActivityVerticalShiftEvidence] {
        guard doc["v_schema"] as? String == verticalShiftSchema,
              let vs = doc["v_s"] as? [Any], let ve = doc["v_e"] as? [Any], let dh = doc["v_dh"] as? [Any],
              let vq = doc["v_q"] as? [Any], vs.count <= maxWindows,
              [ve.count, dh.count, vq.count].allSatisfy({ $0 == vs.count }) else { return [] }
        let version = doc["v_v"] as? String ?? ActivityVerticalShift.version
        let vp = (doc["v_vp"] as? [Any]).flatMap { $0.count == vs.count ? $0 : nil }
        let vk = (doc["v_k"] as? [Any]).flatMap { $0.count == vs.count ? $0 : nil }
        var out: [ActivityVerticalShiftEvidence] = []
        for i in 0..<vs.count {
            guard let start = int(vs[i]), let end = int(ve[i]), end >= start, end - start <= 60,
                  let mm = double(dh[i]), abs(mm) <= 3_000, let q = double(vq[i]), q >= 0, q <= 1000 else { continue }
            let peak = vp.flatMap { double($0[i]) }.map { $0 / 1000 }
            let kind = vk.flatMap { int($0[i]) }.map { $0 == 1 ? "burst" : ($0 == 2 ? "onset" : "other") }
            out.append(ActivityVerticalShiftEvidence(ts: t0 + end, startTs: t0 + start, displacementM: mm / 1000,
                                                     quality: q / 1000, version: version, peakVelocity: peak, kind: kind))
        }
        return out
    }

    /// The optional `g_*` block; a block whose columns do not line up is ignored, a row that does not parse
    /// is left out.
    private static func decodeGait(_ doc: [String: Any], t0: Int) -> [ActivityGaitWindow] {
        guard doc["g_schema"] as? String == gaitSchema,
              let gs = doc["g_s"] as? [Any], let ge = doc["g_e"] as? [Any], let gp = doc["g_p"] as? [Any],
              let gf = doc["g_f"] as? [Any], gs.count <= maxWindows,
              [ge.count, gp.count, gf.count].allSatisfy({ $0 == gs.count }) else { return [] }
        let gq = doc["g_q"] as? [Any]
        let version = doc["g_v"] as? String ?? ""
        var out: [ActivityGaitWindow] = []
        for i in 0..<gs.count {
            guard let start = int(gs[i]), let end = int(ge[i]), end > start, end - start <= 3_600,
                  let perMille = double(gp[i]), perMille >= 0, perMille <= 1000,
                  let flags = int(gf[i]), (0...3).contains(flags) else { continue }
            var w = ActivityGaitWindow(startTs: t0 + start, endTs: t0 + end, gaitProb: perMille / 1000,
                                       isGait: flags & 1 != 0, prefiltered: flags & 2 != 0, modelVersion: version)
            if w.isGait, let gq, gq.count == gs.count, let row = gq[i] as? [Any], row.count == gaitQualityScale.count {
                func value(_ k: Int) -> Double? { double(row[k]).map { $0 / gaitQualityScale[k] } }
                w.cadenceSpm = value(0); w.speedMps = value(1); w.strideM = value(2)
                w.regularity = value(3); w.steps = value(4)
            }
            out.append(w)
        }
        return out
    }

    /// Windows (and their features and transition rows) that END inside `[from, to)`: the decoder keys a
    /// window by its end second, so this is the set a day `[from, to)` would use.
    public func clipped(from: Int, to: Int) -> ActivityEncoderWindowSet {
        var copy = self
        copy.windows = windows.filter { $0.endTs >= from && $0.endTs < to }
        copy.features = features.filter { $0.endTs >= from && $0.endTs < to }
        copy.transitions = transitions.filter { $0.endTs >= from && $0.endTs < to }
        copy.gaitWindows = gaitWindows.filter { $0.endTs >= from && $0.endTs < to }
        copy.verticalShifts = verticalShifts.filter { $0.ts >= from && $0.ts < to }
        return copy
    }

    /// Union of sets from neighbouring UTC days (a local day spans two). The first set's identity wins when
    /// they differ; a window both carry is kept once (transition rows with it).
    public static func merged(_ sets: [ActivityEncoderWindowSet]) -> ActivityEncoderWindowSet? {
        guard let first = sets.first else { return nil }
        var seen = Set<String>(), seenFeatures = Set<String>(), seenTransitions = Set<String>()
        var seenGait = Set<String>(), seenShifts = Set<String>()
        var shifts: [ActivityVerticalShiftEvidence] = []
        var windows: [ActivityWindowPrediction] = [], features: [ImuWindowFeatures] = []
        var transitions: [ActivityTransitionWindow] = [], gaitWindows: [ActivityGaitWindow] = []
        for set in sets {
            for w in set.windows where seen.insert("\(w.startTs)-\(w.endTs)").inserted { windows.append(w) }
            for f in set.features where seenFeatures.insert("\(f.startTs)-\(f.endTs)").inserted { features.append(f) }
            for t in set.transitions where seenTransitions.insert("\(t.startTs)-\(t.endTs)").inserted { transitions.append(t) }
            for g in set.gaitWindows where seenGait.insert("\(g.startTs)-\(g.endTs)").inserted { gaitWindows.append(g) }
            for v in set.verticalShifts where seenShifts.insert("\(v.startTs)-\(v.ts)").inserted { shifts.append(v) }
        }
        windows.sort { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        features.sort { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        transitions.sort { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        gaitWindows.sort { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        var merged = ActivityEncoderWindowSet(encoderId: first.encoderId, encoderVersion: first.encoderVersion,
                                              windows: windows, features: features, transitions: transitions,
                                              gaitWindows: gaitWindows)
        merged.verticalShifts = shifts.sorted { ($0.startTs, $0.ts) < ($1.startTs, $1.ts) }
        return merged
    }

    /// JSON numbers arrive as `NSNumber` on Darwin and as Swift numbers on Linux; both are read here.
    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as Int: return Double(v)
        case let v as Double: return v.isFinite ? v : nil
        case let v as NSNumber:
            let d = v.doubleValue
            return d.isFinite ? d : nil
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        guard let d = double(value), d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }
}
