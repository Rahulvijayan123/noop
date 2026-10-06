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

    public init(encoderId: String, encoderVersion: String,
                windows: [ActivityWindowPrediction], features: [ImuWindowFeatures] = [],
                transitions: [ActivityTransitionWindow] = []) {
        self.encoderId = encoderId; self.encoderVersion = encoderVersion
        self.windows = windows; self.features = features; self.transitions = transitions
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
        var p: [[Int]] = [], fRows: [Any] = [], tRows: [Any] = []
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
        }
        var doc: [String: Any] = ["format": Self.format, "t0": dayStart, "labels": labels,
                                  "features": Self.featureKeys, "feature_scale": Self.featureScale,
                                  "s": s, "e": e, "l": l, "p": p, "b": b, "f": fRows]
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
            windows.append(ActivityWindowPrediction(
                startTs: startTs, endTs: endTs, label: MotionLabel(rawValue: labels[li]) ?? .unknown,
                probs: probs, baseline: int(b[i]) == 1))
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
        return ActivityEncoderWindowSet(encoderId: encoderId, encoderVersion: encoderVersion,
                                        windows: windows, features: features, transitions: transitions)
    }

    /// Windows (and their features and transition rows) that END inside `[from, to)`: the decoder keys a
    /// window by its end second, so this is the set a day `[from, to)` would use.
    public func clipped(from: Int, to: Int) -> ActivityEncoderWindowSet {
        var copy = self
        copy.windows = windows.filter { $0.endTs >= from && $0.endTs < to }
        copy.features = features.filter { $0.endTs >= from && $0.endTs < to }
        copy.transitions = transitions.filter { $0.endTs >= from && $0.endTs < to }
        return copy
    }

    /// Union of sets from neighbouring UTC days (a local day spans two). The first set's identity wins when
    /// they differ; a window both carry is kept once (transition rows with it).
    public static func merged(_ sets: [ActivityEncoderWindowSet]) -> ActivityEncoderWindowSet? {
        guard let first = sets.first else { return nil }
        var seen = Set<String>(), seenFeatures = Set<String>(), seenTransitions = Set<String>()
        var windows: [ActivityWindowPrediction] = [], features: [ImuWindowFeatures] = []
        var transitions: [ActivityTransitionWindow] = []
        for set in sets {
            for w in set.windows where seen.insert("\(w.startTs)-\(w.endTs)").inserted { windows.append(w) }
            for f in set.features where seenFeatures.insert("\(f.startTs)-\(f.endTs)").inserted { features.append(f) }
            for t in set.transitions where seenTransitions.insert("\(t.startTs)-\(t.endTs)").inserted { transitions.append(t) }
        }
        windows.sort { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        features.sort { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        transitions.sort { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        return ActivityEncoderWindowSet(encoderId: first.encoderId, encoderVersion: first.encoderVersion,
                                        windows: windows, features: features, transitions: transitions)
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
