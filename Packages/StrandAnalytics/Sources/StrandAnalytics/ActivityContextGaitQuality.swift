import Foundation

// ActivityContextGaitQuality.swift — ElderNet gait quality: the `gait-quality-1` wire format, its strict decoder,
// and the config that decides whether (and how strongly) the ActivityContext decoder may use it. The contract is
// `Tools/ActivityContext/ELDERNET.md` (§4 wire format, §5 decoder, §6 worker); change it first.
//
// ElderNet (Brand et al. 2026, `yonbrand/gait-quality`) is an ADDITIONAL expert beside HART and the (dormant)
// Inertia heads, never a replacement and never averaged with either: its gait-detection probability enters the
// decoder as its own tempered channel (`ActivityContextGaitQualityFusion.swift`). Its quality metrics (speed,
// cadence, stride length, regularity, steps) are REPORTED, not evidence, in v1. It never rides on
// `MotionEncoderOutput` / `classProbs` (HART's slot) or on `ActivityObservation.motionHeads` (Inertia's).
//
// Off by default. With `ActivityDecoderConfig.gaitQuality == nil` (or a config that refuses the model) the
// decoder's states, snapshot JSON, `cacheTag` and `ActivityStateVersions` are byte-identical to a build without
// this file.

// MARK: - Wire constants

public enum GaitQualityWire {
    /// Response schema of `python -m activity_context.eldernet.serve`.
    public static let schema = "gait-quality-1"
    public static let modelId = "eldernet"
    /// The only preprocessing this decoder understands (`eldernet-prep-1`, ELDERNET.md §2).
    public static let preprocessingVersion = "eldernet-prep-1"
    /// 10-s windows at 30 Hz: fixed by the ElderNet architecture.
    public static let windowS = 10
    /// Hops the decoder accepts (upstream `window_overlap_sec`; never longer than a window).
    public static let allowedHopS: Set<Int> = [1, 2, 5, 10]
    /// The six fine-tuned heads, as `weights` keys. `gait_detection` is the only one ever used as evidence.
    public static let weightNames: [String] = ["gait_detection", "gait_speed", "gait_length", "cadence",
                                               "regularity", "step_count"]
    /// The heads a `calibration` block may calibrate.
    public static let calibratedOutputs: Set<String> = ["gait_prob"]
    /// Upstream clip ranges of the quality metrics (§4). `steps` is per 10-s window; its bound is twice what the
    /// upstream cadence ceiling (150 steps/min) can produce in 10 s, so a correct window never reaches it.
    public static let speedRange: ClosedRange<Double> = 0...2
    public static let cadenceRange: ClosedRange<Double> = 0...150
    public static let strideRange: ClosedRange<Double> = 0...2
    public static let regularityRange: ClosedRange<Double> = 0...1
    public static let stepsRange: ClosedRange<Double> = 0...50
    /// `is_gait` must agree with `gait_prob ≥ gait_threshold`; the service rounds `gait_prob` to 6 decimals, so a
    /// probability within this of the threshold may fall on either side.
    public static let thresholdTolerance = 1e-6
    /// Prefix of the canonical text whose SHA-256 is the weights digest (`GaitQualityModelInfo.weightsDigest`).
    public static let weightsDigestPrefix = "eldernet-weights-1\n"
}

// MARK: - Window

/// One `gait-quality-1` window: ElderNet's gait-detection probability for a 10-s window and, on detected gait
/// only, its quality metrics (absent ≠ 0).
///
/// Carried on `ActivityObservation.gaitQuality` and held in the decoder's feature window (so it is part of the
/// resumable snapshot when, and only when, the gait channel is active).
public struct GaitQualityWindow: Codable, Equatable, Sendable {
    /// Window start / end, unix seconds (`e = s + 10`).
    public var startTs: Int
    public var endTs: Int
    /// The detection head's probability (calibrated when the response carries a `calibration`).
    public var gaitProb: Double
    /// `gait_prob ≥ gait_threshold` after the static pre-filter.
    public var isGait: Bool
    /// The window was below the static variance ceiling (`gait_prob` 0, `is_gait` false).
    public var prefiltered: Bool
    /// m/s, 0–2. Only on `is_gait` windows.
    public var speedMps: Double?
    /// steps/min, 0–150. Only on `is_gait` windows.
    public var cadenceSpm: Double?
    /// m, 0–2. Only on `is_gait` windows.
    public var strideM: Double?
    /// 0–1. Only on `is_gait` windows.
    public var regularity: Double?
    /// Steps in the 10-s window. Only on `is_gait` windows.
    public var steps: Double?

    public init(startTs: Int, endTs: Int, gaitProb: Double, isGait: Bool, prefiltered: Bool = false,
                speedMps: Double? = nil, cadenceSpm: Double? = nil, strideM: Double? = nil,
                regularity: Double? = nil, steps: Double? = nil) {
        self.startTs = startTs; self.endTs = endTs; self.gaitProb = gaitProb; self.isGait = isGait
        self.prefiltered = prefiltered; self.speedMps = speedMps; self.cadenceSpm = cadenceSpm
        self.strideM = strideM; self.regularity = regularity; self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case startTs = "s", endTs = "e", gaitProb = "gait_prob", isGait = "is_gait", prefiltered
        case speedMps = "speed_mps", cadenceSpm = "cadence_spm", strideM = "stride_m", regularity, steps
    }

    /// Strict decode: the same structural checks as `GaitQualityResponse.decode` applies to a window (known keys
    /// only, integral times, a 10-s window, a finite probability in [0, 1], `is_gait` present, metrics in their
    /// ranges and only on gait windows, a consistent pre-filter flag). The threshold check needs the model:
    /// `validate(against:index:)`. A replay record or a snapshot can never carry a window the wire would refuse.
    public init(from decoder: Decoder) throws {
        let json = try MotionHeadsJSON(from: decoder)
        do {
            self = try GaitQualityResponse.parseWindowStructure(json, index: 0)
        } catch let e as GaitQualityResponseError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: e.description))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startTs, forKey: .startTs)
        try c.encode(endTs, forKey: .endTs)
        try c.encode(gaitProb, forKey: .gaitProb)
        try c.encode(isGait, forKey: .isGait)
        if prefiltered { try c.encode(true, forKey: .prefiltered) }
        try c.encodeIfPresent(speedMps, forKey: .speedMps)
        try c.encodeIfPresent(cadenceSpm, forKey: .cadenceSpm)
        try c.encodeIfPresent(strideM, forKey: .strideM)
        try c.encodeIfPresent(regularity, forKey: .regularity)
        try c.encodeIfPresent(steps, forKey: .steps)
    }

    /// The checks of `GaitQualityResponse.decode` that need the model: the window length and the agreement of
    /// `is_gait` with `gait_prob ≥ gait_threshold` (a pre-filtered window is non-gait whatever the threshold).
    public func validate(against model: GaitQualityModelInfo, index i: Int = 0) throws {
        guard endTs - startTs == model.windowS else { throw GaitQualityResponseError.invalidWindowTiming(index: i) }
        guard !prefiltered else { return }
        let t = model.gaitThreshold, tol = GaitQualityWire.thresholdTolerance
        if isGait && gaitProb < t - tol { throw GaitQualityResponseError.inconsistentGaitFlag(index: i) }
        if !isGait && gaitProb >= t + tol { throw GaitQualityResponseError.inconsistentGaitFlag(index: i) }
    }

    /// True when the window carries any quality metric.
    public var hasMetrics: Bool {
        speedMps != nil || cadenceSpm != nil || strideM != nil || regularity != nil || steps != nil
    }
}

// MARK: - Model info

/// One calibrated output (`calibration.<output>`): the method, where it was fit, and its numeric parameters.
public struct GaitQualityCalibrationEntry: Equatable, Sendable {
    public var method: String
    /// Where the calibration was fit (`val`: VAL subjects only).
    public var fit: String
    /// Numeric parameters (`T` for temperature scaling, …), by wire key.
    public var parameters: [String: Double]

    public init(method: String, fit: String, parameters: [String: Double] = [:]) {
        self.method = method; self.fit = fit; self.parameters = parameters
    }
}

/// Provenance and calibration of the model that produced a response (everything in a `gait-quality-1` response
/// except the windows and the request framing). Its Codable form is the response's own layout, so a replay
/// header or a stored config can carry a response verbatim minus `windows`.
public struct GaitQualityModelInfo: Codable, Equatable, Sendable {
    public var modelId: String
    /// e.g. `eldernet-437a38b`.
    public var modelVersion: String
    /// sha256 per fine-tuned head (`GaitQualityWire.weightNames`), as served.
    public var weights: [String: String]
    public var upstreamCommit: String
    public var preprocessingVersion: String
    public var windowS: Int
    public var hopS: Int
    /// nil = uncalibrated outputs (upstream as is).
    public var calibration: [String: GaitQualityCalibrationEntry]?
    public var gaitThreshold: Double

    public init(modelId: String = GaitQualityWire.modelId, modelVersion: String, weights: [String: String],
                upstreamCommit: String, preprocessingVersion: String = GaitQualityWire.preprocessingVersion,
                windowS: Int = GaitQualityWire.windowS, hopS: Int,
                calibration: [String: GaitQualityCalibrationEntry]? = nil, gaitThreshold: Double = 0.5) {
        self.modelId = modelId; self.modelVersion = modelVersion; self.weights = weights
        self.upstreamCommit = upstreamCommit; self.preprocessingVersion = preprocessingVersion
        self.windowS = windowS; self.hopS = hopS; self.calibration = calibration; self.gaitThreshold = gaitThreshold
    }

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id", modelVersion = "model_version", weights, upstreamCommit = "upstream_commit"
        case preprocessingVersion = "preprocessing_version", windowS = "window_s", hopS = "hop_s", calibration
        case gaitThreshold = "gait_threshold"
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Strict decode: exactly the validation `GaitQualityResponse.decode` applies to the response's provenance
    /// (`parseModel`), so a replay header or a stored config refuses what the wire decoder refuses.
    public init(from decoder: Decoder) throws {
        let json = try MotionHeadsJSON(from: decoder)
        guard case .object(let obj) = json else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: GaitQualityResponseError.notAnObject.description))
        }
        do {
            self = try GaitQualityResponse.parseModel(obj)
        } catch let e as GaitQualityResponseError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: e.description))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelId, forKey: .modelId)
        try c.encode(modelVersion, forKey: .modelVersion)
        try c.encode(weights, forKey: .weights)
        try c.encode(upstreamCommit, forKey: .upstreamCommit)
        try c.encode(preprocessingVersion, forKey: .preprocessingVersion)
        try c.encode(windowS, forKey: .windowS)
        try c.encode(hopS, forKey: .hopS)
        if let calibration {
            var outer = c.nestedContainer(keyedBy: DynamicKey.self, forKey: .calibration)
            for name in calibration.keys.sorted() {
                guard let entry = calibration[name] else { continue }
                var inner = outer.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: name))
                try inner.encode(entry.method, forKey: DynamicKey(stringValue: "method"))
                try inner.encode(entry.fit, forKey: DynamicKey(stringValue: "fit"))
                for key in entry.parameters.keys.sorted() {
                    try inner.encode(entry.parameters[key]!, forKey: DynamicKey(stringValue: key))
                }
            }
        } else {
            try c.encodeNil(forKey: .calibration)
        }
        try c.encode(gaitThreshold, forKey: .gaitThreshold)
    }

    /// The canonical text whose SHA-256 is `weightsDigest`: the prefix, then `name=sha256\n` per served head in
    /// sorted name order. (Python: `hashlib.sha256(("eldernet-weights-1\n" + "".join(f"{k}={v}\n" for k, v in
    /// sorted(weights.items()))).encode()).hexdigest()`.)
    public var weightsCanonicalText: String {
        GaitQualityWire.weightsDigestPrefix + weights.keys.sorted().map { "\($0)=\(weights[$0]!)\n" }.joined()
    }

    /// One digest over every served head's weights: what a deployment pins (`FRWHOOP_ELDERNET_WEIGHTS_SHA256`).
    public var weightsDigest: String { GaitSHA256.hex(Array(weightsCanonicalText.utf8)) }

    /// First 12 hex characters of `weightsDigest`, used in provenance stamps and cache tags.
    public var weights12: String { String(weightsDigest.prefix(12)) }
}

// MARK: - Response

/// A validated `gait-quality-1` infer response.
public struct GaitQualityResponse: Equatable, Sendable {
    public var model: GaitQualityModelInfo
    public var windows: [GaitQualityWindow]
    /// Windows the service omitted because an output was nonfinite.
    public var droppedNonfinite: Int
    public var durationMs: Int?

    public init(model: GaitQualityModelInfo, windows: [GaitQualityWindow], droppedNonfinite: Int = 0,
                durationMs: Int? = nil) {
        self.model = model; self.windows = windows
        self.droppedNonfinite = droppedNonfinite; self.durationMs = durationMs
    }
}

/// Why a response was refused. Every malformed response is refused as a whole, never partly accepted.
public enum GaitQualityResponseError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not parseable JSON. `nonfinite` is true when the text carries a NaN / Infinity token.
    case notJSON(nonfinite: Bool)
    case notAnObject
    /// The service answered `ok:false` (malformed, model_missing, weights_mismatch, timeout …).
    case serviceError(kind: String, message: String)
    case unknownSchema(String?)
    case missingField(String)
    case wrongType(String)
    case invalidValue(String)
    case unknownField(String)
    case nonFinite(String)
    case outOfRange(String)
    /// A quality metric on a window that is not gait (metrics exist only on detected gait).
    case metricsOnNonGaitWindow(index: Int)
    /// `is_gait` disagrees with `gait_prob` and the threshold, or a pre-filtered window claims gait.
    case inconsistentGaitFlag(index: Int)
    case invalidWindowTiming(index: Int)

    /// A short machine-readable failure kind for counters and logs.
    public var kind: String {
        switch self {
        case .notJSON(let nonfinite): return nonfinite ? "nonfinite" : "malformed_json"
        case .serviceError(let kind, _): return kind
        case .unknownSchema: return "schema"
        case .nonFinite: return "nonfinite"
        case .outOfRange, .metricsOnNonGaitWindow, .inconsistentGaitFlag: return "invalid_values"
        default: return "malformed"
        }
    }

    public var description: String {
        switch self {
        case .notJSON(let n): return "gait quality response is not JSON\(n ? " (NaN/Infinity token)" : "")"
        case .notAnObject: return "gait quality response is not a JSON object"
        case .serviceError(let kind, let message): return "gait quality service error (\(kind)): \(message)"
        case .unknownSchema(let s): return "unknown gait quality schema \(s ?? "nil")"
        case .missingField(let f): return "missing field \(f)"
        case .wrongType(let f): return "wrong type for \(f)"
        case .invalidValue(let f): return "invalid value for \(f)"
        case .unknownField(let f): return "unknown field \(f)"
        case .nonFinite(let f): return "nonfinite value in \(f)"
        case .outOfRange(let f): return "value out of range in \(f)"
        case .metricsOnNonGaitWindow(let i): return "window \(i) carries gait metrics but is not gait"
        case .inconsistentGaitFlag(let i): return "window \(i) has an is_gait flag that disagrees with its gait_prob"
        case .invalidWindowTiming(let i): return "window \(i) has invalid timing"
        }
    }
}

extension GaitQualityResponse {

    /// Decode and validate one `gait-quality-1` infer response line. Throws `GaitQualityResponseError` for
    /// anything that is not exactly the contract: an unknown schema, model id, weight name or window key, a
    /// nonfinite or out-of-range number, a non-integral time, metrics on a non-gait window, an `is_gait` flag that
    /// disagrees with the threshold, windows out of order.
    public static func decode(_ data: Data) throws -> GaitQualityResponse {
        let root: MotionHeadsJSON
        do {
            root = try JSONDecoder().decode(MotionHeadsJSON.self, from: data)
        } catch {
            let text = String(decoding: data, as: UTF8.self)
            let nonfinite = text.range(of: #"[:\[,]\s*-?(NaN|Infinity)"#, options: .regularExpression) != nil
            throw GaitQualityResponseError.notJSON(nonfinite: nonfinite)
        }
        guard case .object(let obj) = root else { throw GaitQualityResponseError.notAnObject }
        return try parse(obj)
    }

    static func parse(_ obj: [String: MotionHeadsJSON]) throws -> GaitQualityResponse {
        typealias E = GaitQualityResponseError
        if case .bool(false)? = obj["ok"] {
            var kind = "internal", message = ""
            if case .string(let k)? = obj["kind"] { kind = k }
            if case .string(let m)? = obj["error"] { message = m }
            throw E.serviceError(kind: kind, message: message)
        }
        guard case .bool(true)? = obj["ok"] else { throw E.missingField("ok") }
        guard case .string(let schema)? = obj["schema"] else {
            if obj["schema"] == nil { throw E.unknownSchema(nil) }
            throw E.wrongType("schema")
        }
        guard schema == GaitQualityWire.schema else { throw E.unknownSchema(schema) }

        let model = try parseModel(obj)
        guard case .array(let rawWindows)? = obj["windows"] else {
            throw obj["windows"] == nil ? E.missingField("windows") : E.wrongType("windows")
        }
        var windows: [GaitQualityWindow] = []
        windows.reserveCapacity(rawWindows.count)
        var previousStart: Int?
        for (i, raw) in rawWindows.enumerated() {
            let w = try parseWindowStructure(raw, index: i)
            try w.validate(against: model, index: i)
            if let p = previousStart, w.startTs <= p { throw E.invalidWindowTiming(index: i) }
            previousStart = w.startTs
            windows.append(w)
        }
        // Every number that becomes an Int goes through `integer` (integral, |x| < 9e15, `Int(exactly:)`): a bare
        // `Int(d)` traps for d ≥ 2^63, and a service bug must cost a refused response, never the worker.
        var dropped = 0
        if let raw = obj["n_dropped_nonfinite"], raw != .null {
            dropped = try integer(raw, "n_dropped_nonfinite")
            guard dropped >= 0 else { throw E.invalidValue("n_dropped_nonfinite") }
        }
        var duration: Int?
        if let raw = obj["duration_ms"], raw != .null {
            let d = try integer(raw, "duration_ms")
            guard d >= 0 else { throw E.invalidValue("duration_ms") }
            duration = d
        }
        return GaitQualityResponse(model: model, windows: windows, droppedNonfinite: dropped, durationMs: duration)
    }

    // MARK: Field helpers

    static func string(_ obj: [String: MotionHeadsJSON], _ key: String) throws -> String {
        guard let v = obj[key] else { throw GaitQualityResponseError.missingField(key) }
        guard case .string(let s) = v else { throw GaitQualityResponseError.wrongType(key) }
        return s
    }

    static func number(_ v: MotionHeadsJSON, _ field: String) throws -> Double {
        guard case .number(let d) = v else { throw GaitQualityResponseError.wrongType(field) }
        guard d.isFinite else { throw GaitQualityResponseError.nonFinite(field) }
        return d
    }

    /// The only Double → Int conversion on the gait path. Refuses a non-integral value and anything at or beyond
    /// 9e15 (below 2^53, so every accepted value is exact; far below 2^63, so nothing can trap).
    static func integer(_ v: MotionHeadsJSON, _ field: String) throws -> Int {
        let d = try number(v, field)
        guard abs(d) < 9e15, d == d.rounded(), let i = Int(exactly: d) else {
            throw GaitQualityResponseError.invalidValue(field)
        }
        return i
    }

    static func isHex(_ s: String, count: ClosedRange<Int>) -> Bool {
        count.contains(s.utf8.count) && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// A plain identifier: `[A-Za-z0-9][A-Za-z0-9._:+-]{0,127}` (it lands in stamps, cache tags and a primary key).
    static func isIdentifier(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard (1...128).contains(bytes.count) else { return false }
        func alnum(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) }
        guard alnum(bytes[0]) else { return false }
        return bytes.allSatisfy { alnum($0) || $0 == 46 || $0 == 95 || $0 == 58 || $0 == 43 || $0 == 45 }
    }

    // MARK: Model

    static func parseModel(_ obj: [String: MotionHeadsJSON]) throws -> GaitQualityModelInfo {
        typealias E = GaitQualityResponseError
        let modelId = try string(obj, "model_id")
        guard modelId == GaitQualityWire.modelId else { throw E.invalidValue("model_id") }
        let modelVersion = try string(obj, "model_version")
        guard isIdentifier(modelVersion) else { throw E.invalidValue("model_version") }

        guard case .object(let rawWeights)? = obj["weights"] else {
            throw obj["weights"] == nil ? E.missingField("weights") : E.wrongType("weights")
        }
        let known = Set(GaitQualityWire.weightNames)
        var weights: [String: String] = [:]
        for name in rawWeights.keys.sorted() {
            guard known.contains(name) else { throw E.unknownField("weights.\(name)") }
            guard case .string(let sha)? = rawWeights[name] else { throw E.wrongType("weights.\(name)") }
            guard isHex(sha, count: 64...64) else { throw E.invalidValue("weights.\(name)") }
            weights[name] = sha
        }
        // The detection head is the one the decoder may use: a response without its digest names no model.
        guard weights["gait_detection"] != nil else { throw E.missingField("weights.gait_detection") }

        let commit = try string(obj, "upstream_commit")
        guard isHex(commit, count: 7...40) else { throw E.invalidValue("upstream_commit") }
        let preprocessing = try string(obj, "preprocessing_version")
        guard preprocessing == GaitQualityWire.preprocessingVersion else { throw E.invalidValue("preprocessing_version") }
        guard let rawWindowS = obj["window_s"] else { throw E.missingField("window_s") }
        guard let rawHopS = obj["hop_s"] else { throw E.missingField("hop_s") }
        let windowS = try integer(rawWindowS, "window_s"), hopS = try integer(rawHopS, "hop_s")
        guard windowS == GaitQualityWire.windowS else { throw E.invalidValue("window_s") }
        guard GaitQualityWire.allowedHopS.contains(hopS), hopS <= windowS else { throw E.invalidValue("hop_s") }

        var calibration: [String: GaitQualityCalibrationEntry]?
        switch obj["calibration"] {
        case .none, .some(.null): calibration = nil
        case .some(.object(let raw)):
            var out: [String: GaitQualityCalibrationEntry] = [:]
            for name in raw.keys.sorted() {
                guard GaitQualityWire.calibratedOutputs.contains(name) else { throw E.unknownField("calibration.\(name)") }
                guard case .object(let entry)? = raw[name] else { throw E.wrongType("calibration.\(name)") }
                let method = try string(entry, "method")
                let fit = try string(entry, "fit")
                guard !method.isEmpty, !fit.isEmpty else { throw E.invalidValue("calibration.\(name)") }
                var parameters: [String: Double] = [:]
                for key in entry.keys.sorted() where key != "method" && key != "fit" {
                    // Every other key is a numeric parameter of the method (`T`, …); nothing else is understood.
                    parameters[key] = try number(entry[key]!, "calibration.\(name).\(key)")
                }
                out[name] = GaitQualityCalibrationEntry(method: method, fit: fit, parameters: parameters)
            }
            calibration = out
        default: throw E.wrongType("calibration")
        }

        guard let rawThreshold = obj["gait_threshold"] else { throw E.missingField("gait_threshold") }
        let threshold = try number(rawThreshold, "gait_threshold")
        guard threshold > 0, threshold < 1 else { throw E.outOfRange("gait_threshold") }
        return GaitQualityModelInfo(modelId: modelId, modelVersion: modelVersion, weights: weights,
                                    upstreamCommit: commit, preprocessingVersion: preprocessing, windowS: windowS,
                                    hopS: hopS, calibration: calibration, gaitThreshold: threshold)
    }

    // MARK: Window

    static let windowKeys: Set<String> = ["s", "e", "gait_prob", "is_gait", "prefiltered", "speed_mps",
                                          "cadence_spm", "stride_m", "regularity", "steps"]

    static let metricKeys: [(key: String, range: ClosedRange<Double>)] = [
        ("speed_mps", GaitQualityWire.speedRange), ("cadence_spm", GaitQualityWire.cadenceRange),
        ("stride_m", GaitQualityWire.strideRange), ("regularity", GaitQualityWire.regularityRange),
        ("steps", GaitQualityWire.stepsRange),
    ]

    /// Everything about one window that does not need the model (shared with `GaitQualityWindow`'s Codable path):
    /// an object with known keys only, integral `s`/`e` (`integer`, so no conversion can trap) with `s ≥ 0` and a
    /// 10-s length, a finite `gait_prob` in [0, 1], a boolean `is_gait`, a pre-filtered window that is a non-gait
    /// 0, and metrics that are finite, in range and only on gait windows.
    static func parseWindowStructure(_ raw: MotionHeadsJSON, index i: Int) throws -> GaitQualityWindow {
        typealias E = GaitQualityResponseError
        guard case .object(let w) = raw else { throw E.wrongType("windows[\(i)]") }
        for key in w.keys.sorted() where !windowKeys.contains(key) { throw E.unknownField("windows[\(i)].\(key)") }
        guard let rs = w["s"], let re = w["e"] else { throw E.missingField("windows[\(i)].s/e") }
        let s = try integer(rs, "windows[\(i)].s"), e = try integer(re, "windows[\(i)].e")
        guard s >= 0, e - s == GaitQualityWire.windowS else { throw E.invalidWindowTiming(index: i) }
        guard let rp = w["gait_prob"] else { throw E.missingField("windows[\(i)].gait_prob") }
        let p = try number(rp, "windows[\(i)].gait_prob")
        guard p >= 0, p <= 1 + 1e-9 else { throw E.outOfRange("windows[\(i)].gait_prob") }
        guard case .bool(let isGait)? = w["is_gait"] else {
            throw w["is_gait"] == nil ? E.missingField("windows[\(i)].is_gait") : E.wrongType("windows[\(i)].is_gait")
        }
        var prefiltered = false
        switch w["prefiltered"] {
        case .none, .some(.null): prefiltered = false
        case .some(.bool(let b)): prefiltered = b
        default: throw E.wrongType("windows[\(i)].prefiltered")
        }
        if prefiltered, isGait || p != 0 { throw E.inconsistentGaitFlag(index: i) }
        var out = GaitQualityWindow(startTs: s, endTs: e, gaitProb: min(1, p), isGait: isGait, prefiltered: prefiltered)
        for (key, range) in metricKeys {
            guard let v = w[key], v != .null else { continue }
            let x = try number(v, "windows[\(i)].\(key)")
            guard range.contains(x) else { throw E.outOfRange("windows[\(i)].\(key)") }
            guard isGait else { throw E.metricsOnNonGaitWindow(index: i) }
            switch key {
            case "speed_mps": out.speedMps = x
            case "cadence_spm": out.cadenceSpm = x
            case "stride_m": out.strideM = x
            case "regularity": out.regularity = x
            default: out.steps = x
            }
        }
        return out
    }
}

// MARK: - Track input

/// ElderNet windows for one decode, with the model that produced them.
public struct GaitQualityTrackInput: Equatable, Sendable {
    public var model: GaitQualityModelInfo
    public var windows: [GaitQualityWindow]

    public init(model: GaitQualityModelInfo, windows: [GaitQualityWindow]) {
        self.model = model; self.windows = windows
    }

    /// Merge validated responses for one day (chunks of one job). Every response must come from the same model;
    /// windows are kept in time order and a window start seen twice is kept once (the first).
    public init?(responses: [GaitQualityResponse]) {
        guard let first = responses.first else { return nil }
        var windows: [GaitQualityWindow] = []
        var starts: Set<Int> = []
        for r in responses {
            guard r.model == first.model else { return nil }
            for w in r.windows where starts.insert(w.startTs).inserted { windows.append(w) }
        }
        windows.sort { $0.startTs < $1.startTs }
        self.init(model: first.model, windows: windows)
    }
}

/// How the ElderNet windows of one decode were used (or why not). Reported on `ActivityContextTrack`.
public struct GaitQualityTrackReport: Codable, Equatable, Sendable {
    /// Provenance stamp when the gait channel was active (`eldernet:<model_version>:<weights12>:<cfgtag>`).
    public var stamp: String?
    /// Why the windows were not used (nil when they were).
    public var refusal: String?
    public var windowsIn: Int = 0
    public var attached: Int = 0
    /// No observed second in `[e, e + 2]` (ElderNet never creates an observation second).
    public var droppedNoObservation: Int = 0
    /// Another window attached to the same second later.
    public var droppedSuperseded: Int = 0
    /// The window ends outside the decoded range.
    public var droppedOutOfRange: Int = 0
    /// Decoder side: windows ingested, gait and pre-filtered windows among them.
    public var windowsIngested: Int = 0
    public var gaitWindows: Int = 0
    public var prefilteredWindows: Int = 0
    /// Seconds the gait term entered the score.
    public var evidenceSeconds: Int = 0
    /// Seconds the shared accelerometer budget (Inertia's pull first) cut the gait or brisk term on some mode.
    public var budgetLimitedSeconds: Int = 0
    /// The walk-vs-brisk rule on seconds with a held gait window carrying its metric: which side it favoured
    /// (logged whether or not its weight is above 0), and the seconds it was actually applied.
    public var briskFavouredSeconds: Int = 0
    public var walkFavouredSeconds: Int = 0
    public var briskAppliedSeconds: Int = 0
    /// Published states that carried a `gait` block.
    public var gaitBlockStates: Int = 0

    public init(stamp: String? = nil, refusal: String? = nil) {
        self.stamp = stamp; self.refusal = refusal
    }

    enum CodingKeys: String, CodingKey {
        case stamp, refusal
        case windowsIn = "windows_in", attached
        case droppedNoObservation = "dropped_no_observation", droppedSuperseded = "dropped_superseded"
        case droppedOutOfRange = "dropped_out_of_range", windowsIngested = "windows_ingested"
        case gaitWindows = "gait_windows", prefilteredWindows = "prefiltered_windows"
        case evidenceSeconds = "evidence_seconds", budgetLimitedSeconds = "budget_limited_seconds"
        case briskFavouredSeconds = "brisk_favoured_seconds", walkFavouredSeconds = "walk_favoured_seconds"
        case briskAppliedSeconds = "brisk_applied_seconds", gaitBlockStates = "gait_block_states"
    }

    /// Windows that reached the track input but never an observed second.
    public var dropped: Int { droppedNoObservation + droppedSuperseded + droppedOutOfRange }

    /// Two consecutive decodes of one stream (a resumed track): counts add, provenance must agree.
    func merged(with next: GaitQualityTrackReport) -> GaitQualityTrackReport {
        var out = self
        out.stamp = stamp ?? next.stamp
        out.refusal = refusal ?? next.refusal
        out.windowsIn += next.windowsIn; out.attached += next.attached
        out.droppedNoObservation += next.droppedNoObservation; out.droppedSuperseded += next.droppedSuperseded
        out.droppedOutOfRange += next.droppedOutOfRange; out.windowsIngested += next.windowsIngested
        out.gaitWindows += next.gaitWindows; out.prefilteredWindows += next.prefilteredWindows
        out.evidenceSeconds += next.evidenceSeconds; out.budgetLimitedSeconds += next.budgetLimitedSeconds
        out.briskFavouredSeconds += next.briskFavouredSeconds; out.walkFavouredSeconds += next.walkFavouredSeconds
        out.briskAppliedSeconds += next.briskAppliedSeconds; out.gaitBlockStates += next.gaitBlockStates
        return out
    }
}

// MARK: - Evidence config

/// Whether and how strongly the decoder uses ElderNet. `ActivityDecoderConfig.gaitQuality == nil` is OFF.
///
/// Weights are per-second channel weights in the same units as the decoder's other channels (HART's encoder
/// channel is 0.8) and are tempered by `evidenceTemperature` like every channel. The gait term is discounted for
/// redundancy with HART and with Inertia's locomotion head (all three read the same wrist accelerometer) and,
/// with the walk-vs-brisk split, shares one per-second, per-mode accelerometer budget with every Inertia term. No
/// weight or budget may exceed `hardCeiling`. A config outside its bounds is refused (`validate()` throws, and a
/// decoder given one runs exactly as with the channel off).
public struct GaitQualityEvidenceConfig: Codable, Equatable, Sendable {

    public enum Mode: String, Codable, Sendable {
        /// Windows are computed and stored elsewhere; the decoder never sees them.
        case shadow
        /// The gait channel enters the decoder (a second, comparison decode; never the published one).
        case candidate
        /// The gait channel enters the published decode. Needs both pins (model version and weights digest).
        case production
    }

    /// Which ElderNet metric splits walk from brisk walk.
    public enum BriskRule: String, Codable, Sendable {
        case cadence, speed
    }

    public var mode: Mode
    /// The model the windows come from (provenance, threshold, hop, calibration).
    public var model: GaitQualityModelInfo
    /// π: gait prevalence of the set the deployment's `gait_prob` calibration was fit on (VAL subjects). The
    /// likelihood ratio is q/π for gait and (1 − q)/(1 − π) for non-gait, so a window that says q = π is neutral.
    public var gaitPrior: Double
    public var gaitWeight: Double
    /// The walk-vs-brisk split. 0 (the default) = computed and logged, never applied, until validation supports it.
    public var briskWeight: Double
    public var briskRule: BriskRule
    /// Brisk walking from about this cadence (100 steps/min, the usual moderate-intensity walking cadence) …
    public var briskCadenceSpm: Double
    /// … or this speed (1.34 m/s ≈ 3 mph) when `briskRule == .speed`.
    public var briskSpeedMps: Double
    /// Gait weight × (1 − ρ) on seconds where HART's encoder channel also speaks.
    public var hartRedundancy: Double
    /// Gait (and brisk) weight × (1 − ρ) on seconds where an Inertia locomotion term is active.
    public var inertiaRedundancy: Double
    /// Shared accelerometer budget (weight units): per second and per mode, the gait and brisk terms get only
    /// the room left under `accelerometerBudget · ln 10` after every Inertia term (locomotion, posture, gate).
    public var accelerometerBudget: Double
    /// The `model_version` the deployment pinned (`FRWHOOP_ELDERNET_MODEL_VERSION`); any other is refused.
    public var expectedModelVersion: String?
    /// The weights digest the deployment pinned (`FRWHOOP_ELDERNET_WEIGHTS_SHA256`); any other is refused.
    public var expectedWeightsDigest: String?

    /// No weight or budget may exceed this.
    public static let hardCeiling = 0.8
    public static let defaultGaitWeight = 0.25
    public static let defaultBriskCadenceSpm = 100.0
    public static let defaultBriskSpeedMps = 1.34
    /// Not measured for ElderNet yet: the Inertia locomotion default (itself above the measured HART ρ̂ = 0.61),
    /// as the conservative placeholder until the replay measures ElderNet's own overlap.
    public static let defaultHartRedundancy = 0.65
    public static let defaultInertiaRedundancy = 0.65
    /// The same as Inertia's body budget (`MotionHeadsEvidenceConfig.defaultBodyBudget`).
    public static let defaultAccelerometerBudget = 0.5
    public static let gaitPriorBounds: ClosedRange<Double> = 0.01...0.99
    public static let briskCadenceBounds: ClosedRange<Double> = 60...150
    public static let briskSpeedBounds: ClosedRange<Double> = 0.5...2

    public init(mode: Mode, model: GaitQualityModelInfo, gaitPrior: Double,
                gaitWeight: Double = GaitQualityEvidenceConfig.defaultGaitWeight,
                briskWeight: Double = 0, briskRule: BriskRule = .cadence,
                briskCadenceSpm: Double = GaitQualityEvidenceConfig.defaultBriskCadenceSpm,
                briskSpeedMps: Double = GaitQualityEvidenceConfig.defaultBriskSpeedMps,
                hartRedundancy: Double = GaitQualityEvidenceConfig.defaultHartRedundancy,
                inertiaRedundancy: Double = GaitQualityEvidenceConfig.defaultInertiaRedundancy,
                accelerometerBudget: Double = GaitQualityEvidenceConfig.defaultAccelerometerBudget,
                expectedModelVersion: String? = nil, expectedWeightsDigest: String? = nil) {
        self.mode = mode; self.model = model; self.gaitPrior = gaitPrior
        self.gaitWeight = gaitWeight; self.briskWeight = briskWeight; self.briskRule = briskRule
        self.briskCadenceSpm = briskCadenceSpm; self.briskSpeedMps = briskSpeedMps
        self.hartRedundancy = hartRedundancy; self.inertiaRedundancy = inertiaRedundancy
        self.accelerometerBudget = accelerometerBudget
        self.expectedModelVersion = expectedModelVersion; self.expectedWeightsDigest = expectedWeightsDigest
    }

    /// The candidate defaults (ELDERNET.md §5).
    public static func candidate(model: GaitQualityModelInfo, gaitPrior: Double,
                                 expectedModelVersion: String? = nil,
                                 expectedWeightsDigest: String? = nil) -> GaitQualityEvidenceConfig {
        GaitQualityEvidenceConfig(mode: .candidate, model: model, gaitPrior: gaitPrior,
                                  expectedModelVersion: expectedModelVersion,
                                  expectedWeightsDigest: expectedWeightsDigest)
    }

    public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
        case nonFinite(String)
        case negative(String)
        case aboveCeiling(String)
        case outOfRange(String)

        public var description: String {
            switch self {
            case .nonFinite(let f): return "\(f) is not finite"
            case .negative(let f): return "\(f) is negative"
            case .aboveCeiling(let f): return "\(f) exceeds the hard ceiling \(GaitQualityEvidenceConfig.hardCeiling)"
            case .outOfRange(let f): return "\(f) is outside its bounds"
            }
        }
    }

    /// Refuse anything outside the documented bounds.
    public func validate() throws {
        let weights: [(String, Double)] = [("gaitWeight", gaitWeight), ("briskWeight", briskWeight),
                                           ("accelerometerBudget", accelerometerBudget)]
        for (name, value) in weights {
            guard value.isFinite else { throw ValidationError.nonFinite(name) }
            guard value >= 0 else { throw ValidationError.negative(name) }
            guard value <= Self.hardCeiling else { throw ValidationError.aboveCeiling(name) }
        }
        let bounded: [(String, Double, ClosedRange<Double>)] = [
            ("gaitPrior", gaitPrior, Self.gaitPriorBounds),
            ("hartRedundancy", hartRedundancy, 0...1), ("inertiaRedundancy", inertiaRedundancy, 0...1),
            ("briskCadenceSpm", briskCadenceSpm, Self.briskCadenceBounds),
            ("briskSpeedMps", briskSpeedMps, Self.briskSpeedBounds),
        ]
        for (name, value, range) in bounded {
            guard value.isFinite else { throw ValidationError.nonFinite(name) }
            guard range.contains(value) else { throw ValidationError.outOfRange(name) }
        }
    }

    /// Why this config may not feed the decoder, or nil when it may. Shadow never feeds the decoder; a pinned
    /// deployment uses exactly the model it pinned; production needs both pins.
    public var evidenceRefusal: String? {
        do { try validate() } catch { return "invalid_config: \(error)" }
        if mode == .shadow { return "shadow_mode" }
        if let expected = expectedModelVersion, expected != model.modelVersion { return "model_version_mismatch" }
        if let expected = expectedWeightsDigest, expected != model.weightsDigest { return "weights_digest_mismatch" }
        if mode == .production, expectedModelVersion == nil || expectedWeightsDigest == nil {
            return "production_needs_pins"
        }
        guard model.modelId == GaitQualityWire.modelId else { return "model_id" }
        guard model.preprocessingVersion == GaitQualityWire.preprocessingVersion else { return "preprocessing_mismatch" }
        guard model.windowS == GaitQualityWire.windowS, GaitQualityWire.allowedHopS.contains(model.hopS) else {
            return "invalid_hop"
        }
        return nil
    }

    /// Short digest of everything in the config that changes decoder output (the weights digest excluded: it is
    /// carried beside it). The model version, threshold, hop and calibration are part of it.
    public var configTag: String {
        var calibrationText = "none"
        if let calibration = model.calibration {
            calibrationText = calibration.keys.sorted().map { name -> String in
                let e = calibration[name]!
                return "\(name):\(e.method):\(e.fit):" + e.parameters.keys.sorted().map { "\($0)=\(e.parameters[$0]!)" }
                    .joined(separator: ",")
            }.joined(separator: "|")
        }
        let text = "m=\(mode.rawValue);g=\(gaitWeight);b=\(briskWeight);br=\(briskRule.rawValue)"
            + ";bc=\(briskCadenceSpm);bs=\(briskSpeedMps);pi=\(gaitPrior);rh=\(hartRedundancy)"
            + ";ri=\(inertiaRedundancy);ab=\(accelerometerBudget);h=\(model.hopS);w=\(model.windowS)"
            + ";thr=\(model.gaitThreshold);mv=\(model.modelVersion);cal=\(calibrationText)"
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hex = String(h, radix: 16)
        return String((String(repeating: "0", count: max(0, 16 - hex.count)) + hex).prefix(8))
    }

    /// The provenance stamp written into `ActivityStateVersions.gaitQuality` when this config is active.
    public var provenanceStamp: String? {
        guard evidenceRefusal == nil else { return nil }
        return "eldernet:\(model.modelVersion):\(model.weights12):\(configTag)"
    }
}

// MARK: - SHA-256 (the weights digest)

/// A small, dependency-free SHA-256 (FIPS 180-4), so the weights digest is the same on every platform the
/// package builds for (the app, the watch and the Linux worker). Only used on short provenance text.
enum GaitSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    static func hex(_ message: [UInt8]) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var m = message
        let bitLength = UInt64(message.count) &* 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for t in 0..<16 {
                let j = chunk + 4 * t
                w[t] = UInt32(m[j]) << 24 | UInt32(m[j + 1]) << 16 | UInt32(m[j + 2]) << 8 | UInt32(m[j + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { word -> String in
            let s = String(word, radix: 16)
            return String(repeating: "0", count: 8 - s.count) + s
        }.joined()
    }
}
