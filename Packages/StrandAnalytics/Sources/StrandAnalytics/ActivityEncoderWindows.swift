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
// Readers drop any window they cannot parse instead of rejecting the document.

public struct ActivityEncoderWindowSet: Equatable, Sendable {
    public static let format = "hart-windows-1"
    /// `imu-feat-1` keys, in the order `f` rows use.
    public static let featureKeys = ["accel_rms_g", "gyro_rms_dps", "jerk_rms", "cadence_hz",
                                     "cadence_strength", "orientation_change_deg"]
    /// Multiplier applied before rounding each feature to an integer (5, 3, 5, 3, 4 and 2 decimals).
    public static let featureScale: [Double] = [100_000, 1_000, 100_000, 1_000, 10_000, 100]
    /// Two-day documents hold at most this many windows (a 2 s hop over a whole day is 43,200).
    public static let maxWindows = 100_000

    /// "hart" or "baseline" (the heuristic classifier, whose scores are not calibrated).
    public var encoderId: String
    public var encoderVersion: String
    public var windows: [ActivityWindowPrediction]
    public var features: [ImuWindowFeatures]

    public init(encoderId: String, encoderVersion: String,
                windows: [ActivityWindowPrediction], features: [ImuWindowFeatures] = []) {
        self.encoderId = encoderId; self.encoderVersion = encoderVersion
        self.windows = windows; self.features = features
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
        var p: [[Int]] = [], fRows: [Any] = []
        s.reserveCapacity(sorted.count); e.reserveCapacity(sorted.count)
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
        }
        return ["format": Self.format, "t0": dayStart, "labels": labels, "features": Self.featureKeys,
                "feature_scale": Self.featureScale, "s": s, "e": e, "l": l, "p": p, "b": b, "f": fRows]
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
        let accelI = column("accel_rms_g"), gyroI = column("gyro_rms_dps"), jerkI = column("jerk_rms")
        let cadenceI = column("cadence_hz"), strengthI = column("cadence_strength")
        let orientI = column("orientation_change_deg")

        var windows: [ActivityWindowPrediction] = [], features: [ImuWindowFeatures] = []
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
            guard let fr = f[i] as? [Any] else { continue }
            func value(_ index: Int?) -> Double? {
                guard let index, index < fr.count, let raw = double(fr[index]) else { return nil }
                return raw / scales[index]
            }
            guard let accel = value(accelI), let gyro = value(gyroI), let jerk = value(jerkI),
                  let strength = value(strengthI) else { continue }
            features.append(ImuWindowFeatures(startTs: startTs, endTs: endTs, accelRmsG: accel, gyroRmsDps: gyro,
                                              jerkRms: jerk, cadenceHz: value(cadenceI), cadenceStrength: strength,
                                              orientationChangeDeg: value(orientI)))
        }
        return ActivityEncoderWindowSet(encoderId: encoderId, encoderVersion: encoderVersion,
                                        windows: windows, features: features)
    }

    /// Windows (and their features) that END inside `[from, to)`: the decoder keys a window by its end
    /// second, so this is the set a day `[from, to)` would use.
    public func clipped(from: Int, to: Int) -> ActivityEncoderWindowSet {
        var copy = self
        copy.windows = windows.filter { $0.endTs >= from && $0.endTs < to }
        copy.features = features.filter { $0.endTs >= from && $0.endTs < to }
        return copy
    }

    /// Union of sets from neighbouring UTC days (a local day spans two). The first set's identity wins when
    /// they differ; a window both carry is kept once.
    public static func merged(_ sets: [ActivityEncoderWindowSet]) -> ActivityEncoderWindowSet? {
        guard let first = sets.first else { return nil }
        var seen = Set<String>(), seenFeatures = Set<String>()
        var windows: [ActivityWindowPrediction] = [], features: [ImuWindowFeatures] = []
        for set in sets {
            for w in set.windows where seen.insert("\(w.startTs)-\(w.endTs)").inserted { windows.append(w) }
            for f in set.features where seenFeatures.insert("\(f.startTs)-\(f.endTs)").inserted { features.append(f) }
        }
        windows.sort { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        features.sort { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
        return ActivityEncoderWindowSet(encoderId: first.encoderId, encoderVersion: first.encoderVersion,
                                        windows: windows, features: features)
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
