import Foundation

// ActivityContextMotionHeads.swift — Inertia-1 motion-head evidence: the `motion-heads-1` wire format, its
// strict decoder, and the config that decides whether (and how strongly) the ActivityContext decoder may use
// it. The contract is `Tools/ActivityContext/INERTIA1.md` (§6 wire format, §7 decoder); change it first.
//
// Inertia is an ADDITIONAL expert beside HART, never a replacement and never averaged with it: its heads
// enter the decoder as their own tempered channels (`ActivityContextMotionHeadsFusion.swift`). It never
// rides on `MotionEncoderOutput` / `classProbs` (that slot is the short-window encoder's, HART today).
//
// Off by default. With `ActivityDecoderConfig.motionHeads == nil` (or a config that refuses the bundle) the
// decoder's states, snapshot JSON, `cacheTag` and `ActivityStateVersions` are byte-identical to a build
// without this file. Only a bundle from a pinned encoder (`encoder_kind` `inertia1` or `actinet`) with an
// evidence tier of at least `candidate` may be used as evidence; anything else is ignored and reported.

// MARK: - Wire constants

public enum MotionHeadsWire {
    /// Response schema of `python -m activity_context.inertia.serve`.
    public static let schema = "motion-heads-1"
    /// The only preprocessing this decoder understands (`inertia-prep-1`, INERTIA1.md §3).
    public static let preprocessingVersion = "inertia-prep-1"
    /// Window lengths and hops the contract allows.
    public static let allowedWindowS: Set<Int> = [10, 30]
    public static let allowedHopS: Set<Int> = [1, 2, 5, 10, 15, 30]
    /// Tolerance on the sum of a categorical head's window probabilities (posture, locomotion, arm). The
    /// service writes each probability rounded to 6 decimals, so a correct distribution over K ≤ 9 classes
    /// can miss 1 by up to K·5e-7; 1e-5 admits that rounding and nothing a real fault would produce.
    public static let probabilitySumTolerance = 1e-5
    /// Tolerance on the sum of a categorical head's calibration prior (a mean of calibrated distributions).
    public static let priorSumTolerance = 1e-4
}

/// The four classifier heads, in wire-key form. `movement_intensity` is a scalar on the window.
public enum MotionHead: String, CaseIterable, Codable, Sendable {
    case posture
    case locomotion
    case armBehavior = "arm_behavior"
    /// Multi-label event head: independent per-event probabilities, no `none` class, no sum-to-1.
    case transition

    /// The fixed class order of this head (INERTIA1.md §5). `unknown` is never a trained class.
    public var classOrder: [String] {
        switch self {
        case .posture: return ["recumbent", "seated_likely", "upright_stationary", "postural_transition"]
        case .locomotion: return ["stationary", "walking", "brisk_walking", "running", "stairs", "cycling",
                                  "vehicle_motion", "other"]
        case .armBehavior: return ["quiet", "desk_like", "fidgeting", "repetitive_hand_motion",
                                   "active_gesturing", "exercise_motion", "other"]
        case .transition: return ["sit_to_stand_like", "stand_to_sit_like", "lying_down_like", "getting_up_like",
                                  "walk_start", "walk_stop", "run_start", "run_stop"]
        }
    }

    /// True for the heads whose window values are one distribution summing to 1.
    public var isCategorical: Bool { self != .transition }
}

public enum MotionHeadsEncoderKind: String, Codable, Sendable {
    /// A pinned, real Inertia-1 checkpoint (`encoder_id` starts with `inertia-1/`).
    case inertia1
    /// Pinned ActiNet / ssl-wearables harnet30 weights (`encoder_id` starts with `actinet/`, INERTIA1.md §4b).
    case actinet
    /// A stand-in encoder (`standin:` ids): offline / shadow only, never evidence in production.
    case standin
}

extension MotionHeadsEncoderKind {
    /// A pinned checkpoint (inertia1 / actinet) — the only kinds that may feed the decoder.
    public var isPinned: Bool { self != .standin }
}

/// How far the bundle's own evaluation lets it be used. Ordered weakest first.
public enum MotionHeadsEvidenceTier: String, Codable, Sendable, Comparable, CaseIterable {
    case shadow, candidate, production

    private var rank: Int {
        switch self {
        case .shadow: return 0
        case .candidate: return 1
        case .production: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Per-class reliability decided on the validation split.
public enum MotionHeadClassStatus: String, Codable, Sendable {
    case strong, weak, abstain
}

// MARK: - Window

/// One `motion-heads-1` window: calibrated probabilities over each head's SUPPORTED classes only (an absent
/// key is "not supported", never a claim of zero), the scalar intensity head and the OOD verdict.
///
/// Carried on `ActivityObservation.motionHeads` and held in the decoder's feature window (so it is part of the
/// resumable snapshot when, and only when, Inertia evidence is active).
public struct MotionHeadsWindow: Codable, Equatable, Sendable {
    /// Window start / end, unix seconds (`e = s + window_s`).
    public var startTs: Int
    public var endTs: Int
    public var posture: [String: Double]?
    public var locomotion: [String: Double]?
    public var armBehavior: [String: Double]?
    /// Independent per-event probabilities (multi-label). Carried and logged only in v1.
    public var transition: [String: Double]?
    /// 0…1 (`clip(ln(MET)/ln(12), 0, 1)`). Carried and logged only in v1.
    public var movementIntensity: Double?
    public var oodScore: Double?
    /// The window's embedding is unlike the training distribution: every Inertia term is omitted for it.
    public var isOOD: Bool

    public init(startTs: Int, endTs: Int, posture: [String: Double]? = nil, locomotion: [String: Double]? = nil,
                armBehavior: [String: Double]? = nil, transition: [String: Double]? = nil,
                movementIntensity: Double? = nil, oodScore: Double? = nil, isOOD: Bool = false) {
        self.startTs = startTs; self.endTs = endTs
        self.posture = posture; self.locomotion = locomotion; self.armBehavior = armBehavior
        self.transition = transition; self.movementIntensity = movementIntensity
        self.oodScore = oodScore; self.isOOD = isOOD
    }

    enum CodingKeys: String, CodingKey {
        case startTs = "s", endTs = "e"
        case posture, locomotion
        case armBehavior = "arm_behavior"
        case transition
        case movementIntensity = "movement_intensity"
        case oodScore = "ood_score"
        case isOOD = "is_ood"
    }

    /// Strict decode: the same structural checks as `MotionHeadsResponse.decode` applies to a window (known
    /// keys only, integral times, a known window length, known class keys, finite probabilities in [0, 1],
    /// `is_ood` present). The checks that need the bundle (supported classes, sums, `e − s == window_s`) are
    /// `validate(against:index:)`. A replay record or a snapshot can therefore never carry a window the wire
    /// decoder would have refused.
    public init(from decoder: Decoder) throws {
        let json = try MotionHeadsJSON(from: decoder)
        do {
            self = try MotionHeadsResponse.parseWindowStructure(json, index: 0)
        } catch let e as MotionHeadsResponseError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: e.description))
        }
    }

    /// The checks of `MotionHeadsResponse.decode` that need the bundle: the window length, and for every head
    /// the window carries, that the bundle supports it, that it covers exactly the supported classes and (for
    /// a categorical head) that it sums to 1.
    public func validate(against bundle: MotionHeadsBundleInfo, index i: Int = 0) throws {
        typealias E = MotionHeadsResponseError
        guard endTs - startTs == bundle.windowS else { throw E.invalidWindowTiming(index: i) }
        for head in MotionHead.allCases {
            guard let dict = probabilities(head) else { continue }
            guard let spec = bundle.heads[head], !spec.prior.isEmpty else {
                // A window may only carry heads the bundle supports.
                throw E.supportMismatch(head: head.rawValue, window: i)
            }
            guard Set(dict.keys) == Set(spec.prior.keys) else { throw E.supportMismatch(head: head.rawValue, window: i) }
            if head.isCategorical {
                // Summed in class order so the check does not depend on dictionary order.
                let sum = head.classOrder.reduce(0.0) { $0 + (dict[$1] ?? 0) }
                guard abs(sum - 1) <= MotionHeadsWire.probabilitySumTolerance else {
                    throw E.probabilitiesDoNotSumToOne(head: head.rawValue, window: i, sum: sum)
                }
            }
        }
    }

    /// The probabilities of one head (nil when the window does not carry it).
    public func probabilities(_ head: MotionHead) -> [String: Double]? {
        switch head {
        case .posture: return posture
        case .locomotion: return locomotion
        case .armBehavior: return armBehavior
        case .transition: return transition
        }
    }

    mutating func setProbabilities(_ head: MotionHead, _ value: [String: Double]?) {
        switch head {
        case .posture: posture = value
        case .locomotion: locomotion = value
        case .armBehavior: armBehavior = value
        case .transition: transition = value
        }
    }
}

// MARK: - Bundle info

/// What the response says about one head of the bundle: the fixed class order, the calibration-set prior
/// over supported classes, per-class reliability, thresholds and the coarsening rules.
public struct MotionHeadSpec: Codable, Equatable, Sendable {
    public var classOrder: [String]
    /// Calibration-set mean calibrated probability per SUPPORTED class (its keys define support).
    public var prior: [String: Double]
    public var status: [String: MotionHeadClassStatus]
    /// Strong/weak operating threshold per class (validation split).
    public var tau: [String: Double]
    /// Abstained class → the partner it is merged into before it is used.
    public var mergeInto: [String: String]
    /// A supported class that absorbed unsupported ones through set targets lists them (itself included).
    public var covers: [String: [String]]
    /// `false` when the bundle declares the head carries no decoder evidence (its classes collapse to at most
    /// one group after abstention). nil (absent) means the bundle does not say; the decoder still treats a
    /// head that prepares to a single group as inert.
    public var decoderEvidence: Bool?

    public init(classOrder: [String], prior: [String: Double], status: [String: MotionHeadClassStatus],
                tau: [String: Double] = [:], mergeInto: [String: String] = [:], covers: [String: [String]] = [:],
                decoderEvidence: Bool? = nil) {
        self.classOrder = classOrder; self.prior = prior; self.status = status
        self.tau = tau; self.mergeInto = mergeInto; self.covers = covers
        self.decoderEvidence = decoderEvidence
    }

    enum CodingKeys: String, CodingKey {
        case classOrder = "class_order", prior, status, tau
        case mergeInto = "merge_into", covers
        case decoderEvidence = "decoder_evidence"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classOrder = try c.decode([String].self, forKey: .classOrder)
        prior = try c.decode([String: Double].self, forKey: .prior)
        status = try c.decode([String: MotionHeadClassStatus].self, forKey: .status)
        tau = try c.decodeIfPresent([String: Double].self, forKey: .tau) ?? [:]
        mergeInto = try c.decodeIfPresent([String: String].self, forKey: .mergeInto) ?? [:]
        covers = try c.decodeIfPresent([String: [String]].self, forKey: .covers) ?? [:]
        decoderEvidence = try c.decodeIfPresent(Bool.self, forKey: .decoderEvidence)
    }

    /// Supported classes in the fixed class order (never dictionary order).
    public var supportedClasses: [String] { classOrder.filter { prior[$0] != nil } }
}

public struct MotionHeadsOODInfo: Codable, Equatable, Sendable {
    public var method: String
    public var threshold: Double?

    public init(method: String, threshold: Double?) {
        self.method = method; self.threshold = threshold
    }
}

/// Fusion measurements the bundle carries (`bundle.fusion` in the response; optional).
public struct MotionHeadsFusionInfo: Codable, Equatable, Sendable {
    /// ρ̂: the correlation of HART's and this bundle's locomotion residual log-likelihood ratios, measured on
    /// replay (validation split). The decoder never discounts the locomotion channel by LESS than this
    /// (`MotionHeadsEvidenceConfig.effectiveHartRedundancy`).
    public var rhoHart: Double?

    public init(rhoHart: Double?) { self.rhoHart = rhoHart }

    enum CodingKeys: String, CodingKey { case rhoHart = "rho_hart" }
}

/// Provenance and calibration of the head bundle that produced a response (everything in a `motion-heads-1`
/// response except the windows). Its Codable form is the response's own layout, so a replay record can carry
/// a response verbatim minus `windows`.
public struct MotionHeadsBundleInfo: Codable, Equatable, Sendable {
    public var encoderId: String
    public var encoderKind: MotionHeadsEncoderKind
    public var encoderVersion: String
    public var checkpointSha256: String?
    /// The bundle id (`heads_version`).
    public var headsVersion: String
    public var bundleSha256: String
    public var preprocessingVersion: String
    public var evidenceTierMax: MotionHeadsEvidenceTier
    public var windowS: Int
    public var hopS: Int
    public var heads: [MotionHead: MotionHeadSpec]
    public var ood: MotionHeadsOODInfo
    /// Optional fusion measurements (`bundle.fusion`); nil when the bundle carries none.
    public var fusion: MotionHeadsFusionInfo?

    public init(encoderId: String, encoderKind: MotionHeadsEncoderKind, encoderVersion: String,
                checkpointSha256: String?, headsVersion: String, bundleSha256: String,
                preprocessingVersion: String = MotionHeadsWire.preprocessingVersion,
                evidenceTierMax: MotionHeadsEvidenceTier, windowS: Int, hopS: Int,
                heads: [MotionHead: MotionHeadSpec], ood: MotionHeadsOODInfo,
                fusion: MotionHeadsFusionInfo? = nil) {
        self.encoderId = encoderId; self.encoderKind = encoderKind; self.encoderVersion = encoderVersion
        self.checkpointSha256 = checkpointSha256; self.headsVersion = headsVersion
        self.bundleSha256 = bundleSha256; self.preprocessingVersion = preprocessingVersion
        self.evidenceTierMax = evidenceTierMax; self.windowS = windowS; self.hopS = hopS
        self.heads = heads; self.ood = ood; self.fusion = fusion
    }

    enum CodingKeys: String, CodingKey {
        case encoderId = "encoder_id", encoderKind = "encoder_kind", encoderVersion = "encoder_version"
        case checkpointSha256 = "checkpoint_sha256", headsVersion = "heads_version"
        case bundleSha256 = "bundle_sha256", preprocessingVersion = "preprocessing_version"
        case evidenceTierMax = "evidence_tier_max", windowS = "window_s", hopS = "hop_s"
        case bundle
    }

    enum BundleKeys: String, CodingKey { case heads, ood, fusion }

    /// Strict decode: exactly the validation `MotionHeadsResponse.decode` applies to the response's provenance
    /// and bundle block (`parseBundle`), so a replay header, a stored config or any other Codable path refuses
    /// what the wire decoder refuses (an `inertia1` kind with a `standin:` id, an unknown head or class, a
    /// broken merge chain, a prior that does not sum to 1 …).
    public init(from decoder: Decoder) throws {
        let json = try MotionHeadsJSON(from: decoder)
        guard case .object(let obj) = json else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: MotionHeadsResponseError.notAnObject.description))
        }
        do {
            self = try MotionHeadsResponse.parseBundle(obj)
        } catch let e as MotionHeadsResponseError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: e.description))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(encoderId, forKey: .encoderId)
        try c.encode(encoderKind, forKey: .encoderKind)
        try c.encode(encoderVersion, forKey: .encoderVersion)
        if let checkpointSha256 { try c.encode(checkpointSha256, forKey: .checkpointSha256) }
        else { try c.encodeNil(forKey: .checkpointSha256) }
        try c.encode(headsVersion, forKey: .headsVersion)
        try c.encode(bundleSha256, forKey: .bundleSha256)
        try c.encode(preprocessingVersion, forKey: .preprocessingVersion)
        try c.encode(evidenceTierMax, forKey: .evidenceTierMax)
        try c.encode(windowS, forKey: .windowS)
        try c.encode(hopS, forKey: .hopS)
        var b = c.nestedContainer(keyedBy: BundleKeys.self, forKey: .bundle)
        var raw: [String: MotionHeadSpec] = [:]
        for (head, spec) in heads { raw[head.rawValue] = spec }
        try b.encode(raw, forKey: .heads)
        try b.encode(ood, forKey: .ood)
        if let fusion { try b.encode(fusion, forKey: .fusion) }
    }

    /// First 12 hex characters of the bundle digest, used in provenance stamps and cache tags.
    public var bundle12: String { String(bundleSha256.prefix(12)) }
}

// MARK: - Response

/// A validated `motion-heads-1` infer response.
public struct MotionHeadsResponse: Equatable, Sendable {
    public var bundle: MotionHeadsBundleInfo
    public var windows: [MotionHeadsWindow]
    /// Windows the service omitted because their embedding or outputs were nonfinite.
    public var droppedNonfinite: Int
    public var durationMs: Int?

    public init(bundle: MotionHeadsBundleInfo, windows: [MotionHeadsWindow], droppedNonfinite: Int = 0,
                durationMs: Int? = nil) {
        self.bundle = bundle; self.windows = windows
        self.droppedNonfinite = droppedNonfinite; self.durationMs = durationMs
    }
}

/// Why a response was refused. Every malformed response is refused as a whole, never partly accepted.
public enum MotionHeadsResponseError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not parseable JSON. `nonfinite` is true when the text carries a NaN / Infinity token.
    case notJSON(nonfinite: Bool)
    case notAnObject
    /// The service answered `ok:false` (model_missing, timeout, malformed request …).
    case serviceError(kind: String, message: String)
    case unknownSchema(String?)
    case missingField(String)
    case wrongType(String)
    case invalidValue(String)
    case unknownField(String)
    case unknownHead(String)
    case unknownClass(head: String, cls: String)
    case classOrderMismatch(head: String)
    case nonFinite(String)
    case probabilityOutOfRange(String)
    case probabilitiesDoNotSumToOne(head: String, window: Int, sum: Double)
    case supportMismatch(head: String, window: Int)
    case invalidMerge(head: String, cls: String)
    case invalidCovers(head: String, cls: String)
    case invalidWindowTiming(index: Int)

    /// A short machine-readable failure kind for counters and logs.
    public var kind: String {
        switch self {
        case .notJSON(let nonfinite): return nonfinite ? "nonfinite" : "malformed_json"
        case .serviceError(let kind, _): return kind
        case .unknownSchema: return "schema"
        case .nonFinite: return "nonfinite"
        case .probabilityOutOfRange, .probabilitiesDoNotSumToOne, .supportMismatch: return "invalid_probabilities"
        default: return "malformed"
        }
    }

    public var description: String {
        switch self {
        case .notJSON(let n): return "motion heads response is not JSON\(n ? " (NaN/Infinity token)" : "")"
        case .notAnObject: return "motion heads response is not a JSON object"
        case .serviceError(let kind, let message): return "motion heads service error (\(kind)): \(message)"
        case .unknownSchema(let s): return "unknown motion heads schema \(s ?? "nil")"
        case .missingField(let f): return "missing field \(f)"
        case .wrongType(let f): return "wrong type for \(f)"
        case .invalidValue(let f): return "invalid value for \(f)"
        case .unknownField(let f): return "unknown field \(f)"
        case .unknownHead(let h): return "unknown head \(h)"
        case .unknownClass(let h, let c): return "unknown class \(c) in head \(h)"
        case .classOrderMismatch(let h): return "class order of head \(h) differs from the contract"
        case .nonFinite(let f): return "nonfinite value in \(f)"
        case .probabilityOutOfRange(let f): return "probability out of [0, 1] in \(f)"
        case .probabilitiesDoNotSumToOne(let h, let w, let s): return "head \(h) of window \(w) sums to \(s)"
        case .supportMismatch(let h, let w): return "head \(h) of window \(w) does not cover exactly the supported classes"
        case .invalidMerge(let h, let c): return "invalid merge_into for \(c) in head \(h)"
        case .invalidCovers(let h, let c): return "invalid covers for \(c) in head \(h)"
        case .invalidWindowTiming(let i): return "window \(i) has invalid timing"
        }
    }
}

/// A JSON value with numbers and booleans kept apart (a `1` is never read as `true`).
indirect enum MotionHeadsJSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MotionHeadsJSON])
    case object([String: MotionHeadsJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([MotionHeadsJSON].self) { self = .array(a); return }
        self = .object(try c.decode([String: MotionHeadsJSON].self))
    }
}

extension MotionHeadsResponse {

    /// Decode and validate one `motion-heads-1` infer response line. Throws `MotionHeadsResponseError` for
    /// anything that is not exactly the contract: an unknown schema, head or class key, a class order that
    /// differs, a nonfinite or out-of-range number, a categorical head that does not sum to 1, a window that
    /// does not cover exactly the supported classes, an inconsistent merge / covers rule, bad window timing.
    public static func decode(_ data: Data) throws -> MotionHeadsResponse {
        let root: MotionHeadsJSON
        do {
            root = try JSONDecoder().decode(MotionHeadsJSON.self, from: data)
        } catch {
            let text = String(decoding: data, as: UTF8.self)
            let nonfinite = text.range(of: #"[:\[,]\s*-?(NaN|Infinity)"#, options: .regularExpression) != nil
            throw MotionHeadsResponseError.notJSON(nonfinite: nonfinite)
        }
        guard case .object(let obj) = root else { throw MotionHeadsResponseError.notAnObject }
        return try parse(obj)
    }

    static func parse(_ obj: [String: MotionHeadsJSON]) throws -> MotionHeadsResponse {
        typealias E = MotionHeadsResponseError
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
        guard schema == MotionHeadsWire.schema else { throw E.unknownSchema(schema) }

        let bundle = try parseBundle(obj)
        var windows: [MotionHeadsWindow] = []
        guard case .array(let rawWindows)? = obj["windows"] else {
            throw obj["windows"] == nil ? E.missingField("windows") : E.wrongType("windows")
        }
        windows.reserveCapacity(rawWindows.count)
        var previousStart: Int?
        for (i, raw) in rawWindows.enumerated() {
            let w = try parseWindow(raw, index: i, bundle: bundle)
            if let p = previousStart, w.startTs <= p { throw E.invalidWindowTiming(index: i) }
            previousStart = w.startTs
            windows.append(w)
        }
        var dropped = 0
        if let raw = obj["n_dropped_nonfinite"], raw != .null {
            dropped = try integer(raw, "n_dropped_nonfinite")
            guard dropped >= 0 else { throw E.invalidValue("n_dropped_nonfinite") }
        }
        // Every number that becomes an Int goes through `integer` (integral, |x| < 9e15, `Int(exactly:)`): a bare
        // `Int(d)` traps for d ≥ 2^63, and a service bug must cost a refused response, never the worker.
        var duration: Int?
        if let raw = obj["duration_ms"], raw != .null {
            let d = try integer(raw, "duration_ms")
            guard d >= 0 else { throw E.invalidValue("duration_ms") }
            duration = d
        }
        return MotionHeadsResponse(bundle: bundle, windows: windows, droppedNonfinite: dropped, durationMs: duration)
    }

    // MARK: Field helpers

    static func string(_ obj: [String: MotionHeadsJSON], _ key: String) throws -> String {
        guard let v = obj[key] else { throw MotionHeadsResponseError.missingField(key) }
        guard case .string(let s) = v else { throw MotionHeadsResponseError.wrongType(key) }
        return s
    }

    static func number(_ v: MotionHeadsJSON, _ field: String) throws -> Double {
        guard case .number(let d) = v else { throw MotionHeadsResponseError.wrongType(field) }
        guard d.isFinite else { throw MotionHeadsResponseError.nonFinite(field) }
        return d
    }

    /// The only Double → Int conversion on the motion-heads path. Refuses a non-integral value and anything at
    /// or beyond 9e15 (below 2^53, so every accepted value is exact; far below 2^63, so nothing can trap).
    static func integer(_ v: MotionHeadsJSON, _ field: String) throws -> Int {
        let d = try number(v, field)
        guard abs(d) < 9e15, d == d.rounded(), let i = Int(exactly: d) else {
            throw MotionHeadsResponseError.invalidValue(field)
        }
        return i
    }

    static func isHex64(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // MARK: Bundle

    static func parseBundle(_ obj: [String: MotionHeadsJSON]) throws -> MotionHeadsBundleInfo {
        typealias E = MotionHeadsResponseError
        let encoderId = try string(obj, "encoder_id")
        guard !encoderId.isEmpty else { throw E.invalidValue("encoder_id") }
        guard let kind = MotionHeadsEncoderKind(rawValue: try string(obj, "encoder_kind")) else {
            throw E.invalidValue("encoder_kind")
        }
        let encoderVersion = try string(obj, "encoder_version")
        var checkpoint: String?
        switch obj["checkpoint_sha256"] {
        case .none, .some(.null): checkpoint = nil
        case .some(.string(let s)):
            guard isHex64(s) else { throw E.invalidValue("checkpoint_sha256") }
            checkpoint = s
        default: throw E.wrongType("checkpoint_sha256")
        }
        // INERTIA1.md §2: inertia1 / actinet iff an `inertia-1/` / `actinet/` id with a pinned checkpoint;
        // stand-ins are `standin:`.
        switch kind {
        case .inertia1:
            guard encoderId.hasPrefix("inertia-1/"), checkpoint != nil else { throw E.invalidValue("encoder_kind") }
        case .actinet:
            guard encoderId.hasPrefix("actinet/"), checkpoint != nil else { throw E.invalidValue("encoder_kind") }
        case .standin:
            guard encoderId.hasPrefix("standin:") else { throw E.invalidValue("encoder_id") }
        }
        let headsVersion = try string(obj, "heads_version")
        guard !headsVersion.isEmpty else { throw E.invalidValue("heads_version") }
        let bundleSha = try string(obj, "bundle_sha256")
        guard isHex64(bundleSha) else { throw E.invalidValue("bundle_sha256") }
        let preprocessing = try string(obj, "preprocessing_version")
        guard preprocessing == MotionHeadsWire.preprocessingVersion else { throw E.invalidValue("preprocessing_version") }
        guard let tier = MotionHeadsEvidenceTier(rawValue: try string(obj, "evidence_tier_max")) else {
            throw E.invalidValue("evidence_tier_max")
        }
        guard let rawWindowS = obj["window_s"] else { throw E.missingField("window_s") }
        guard let rawHopS = obj["hop_s"] else { throw E.missingField("hop_s") }
        let windowS = try integer(rawWindowS, "window_s"), hopS = try integer(rawHopS, "hop_s")
        guard MotionHeadsWire.allowedWindowS.contains(windowS) else { throw E.invalidValue("window_s") }
        guard MotionHeadsWire.allowedHopS.contains(hopS), hopS <= windowS else { throw E.invalidValue("hop_s") }

        guard case .object(let b)? = obj["bundle"] else {
            throw obj["bundle"] == nil ? E.missingField("bundle") : E.wrongType("bundle")
        }
        guard case .object(let rawHeads)? = b["heads"] else {
            throw b["heads"] == nil ? E.missingField("bundle.heads") : E.wrongType("bundle.heads")
        }
        var heads: [MotionHead: MotionHeadSpec] = [:]
        for key in rawHeads.keys.sorted() {
            guard let head = MotionHead(rawValue: key) else { throw E.unknownHead(key) }
            guard case .object(let spec)? = rawHeads[key] else { throw E.wrongType("bundle.heads.\(key)") }
            heads[head] = try parseSpec(spec, head: head)
        }
        guard case .object(let rawOOD)? = b["ood"] else {
            throw b["ood"] == nil ? E.missingField("bundle.ood") : E.wrongType("bundle.ood")
        }
        let method = try string(rawOOD, "method")
        var threshold: Double?
        if let t = rawOOD["threshold"], t != .null { threshold = try number(t, "bundle.ood.threshold") }
        // Optional fusion measurements. ρ̂ is a correlation used as a discount, so only [0, 1] makes sense.
        var fusion: MotionHeadsFusionInfo?
        switch b["fusion"] {
        case .none, .some(.null): fusion = nil
        case .some(.object(let f)):
            var rho: Double?
            if let r = f["rho_hart"], r != .null {
                let x = try number(r, "bundle.fusion.rho_hart")
                guard (0...1).contains(x) else { throw E.invalidValue("bundle.fusion.rho_hart") }
                rho = x
            }
            fusion = MotionHeadsFusionInfo(rhoHart: rho)
        default: throw E.wrongType("bundle.fusion")
        }
        return MotionHeadsBundleInfo(encoderId: encoderId, encoderKind: kind, encoderVersion: encoderVersion,
                                     checkpointSha256: checkpoint, headsVersion: headsVersion, bundleSha256: bundleSha,
                                     preprocessingVersion: preprocessing, evidenceTierMax: tier,
                                     windowS: windowS, hopS: hopS, heads: heads,
                                     ood: MotionHeadsOODInfo(method: method, threshold: threshold), fusion: fusion)
    }

    static func stringMap(_ v: MotionHeadsJSON?, _ field: String) throws -> [String: MotionHeadsJSON] {
        switch v {
        case .none, .some(.null): return [:]
        case .some(.object(let o)): return o
        default: throw MotionHeadsResponseError.wrongType(field)
        }
    }

    static func parseSpec(_ spec: [String: MotionHeadsJSON], head: MotionHead) throws -> MotionHeadSpec {
        typealias E = MotionHeadsResponseError
        let h = head.rawValue
        guard case .array(let rawOrder)? = spec["class_order"] else {
            throw spec["class_order"] == nil ? E.missingField("\(h).class_order") : E.wrongType("\(h).class_order")
        }
        let order: [String] = try rawOrder.map {
            guard case .string(let s) = $0 else { throw E.wrongType("\(h).class_order") }
            return s
        }
        guard order == head.classOrder else { throw E.classOrderMismatch(head: h) }
        let known = Set(order)

        var prior: [String: Double] = [:]
        let rawPrior = try stringMap(spec["prior"], "\(h).prior")
        for (cls, v) in rawPrior.sorted(by: { $0.key < $1.key }) {
            guard known.contains(cls) else { throw E.unknownClass(head: h, cls: cls) }
            let p = try number(v, "\(h).prior.\(cls)")
            guard p > 0, p <= 1 else { throw E.probabilityOutOfRange("\(h).prior.\(cls)") }
            prior[cls] = p
        }
        if head.isCategorical, !prior.isEmpty {
            let sum = order.reduce(0.0) { $0 + (prior[$1] ?? 0) }
            guard abs(sum - 1) <= MotionHeadsWire.priorSumTolerance else {
                throw E.probabilitiesDoNotSumToOne(head: "\(h).prior", window: -1, sum: sum)
            }
        }
        var status: [String: MotionHeadClassStatus] = [:]
        let rawStatus = try stringMap(spec["status"], "\(h).status")
        for (cls, v) in rawStatus.sorted(by: { $0.key < $1.key }) {
            guard known.contains(cls) else { throw E.unknownClass(head: h, cls: cls) }
            guard case .string(let s) = v, let st = MotionHeadClassStatus(rawValue: s) else {
                throw E.invalidValue("\(h).status.\(cls)")
            }
            status[cls] = st
        }
        guard Set(status.keys) == Set(prior.keys) else { throw E.supportMismatch(head: "\(h).status", window: -1) }
        var tau: [String: Double] = [:]
        let rawTau = try stringMap(spec["tau"], "\(h).tau")
        for (cls, v) in rawTau.sorted(by: { $0.key < $1.key }) {
            guard known.contains(cls) else { throw E.unknownClass(head: h, cls: cls) }
            if v == .null { continue }
            let t = try number(v, "\(h).tau.\(cls)")
            guard (0...1).contains(t) else { throw E.probabilityOutOfRange("\(h).tau.\(cls)") }
            tau[cls] = t
        }
        var merge: [String: String] = [:]
        let rawMerge = try stringMap(spec["merge_into"], "\(h).merge_into")
        for (cls, v) in rawMerge.sorted(by: { $0.key < $1.key }) {
            guard known.contains(cls) else { throw E.unknownClass(head: h, cls: cls) }
            guard case .string(let partner) = v, known.contains(partner) else { throw E.invalidMerge(head: h, cls: cls) }
            guard status[cls] == .abstain, prior[partner] != nil, partner != cls else {
                throw E.invalidMerge(head: h, cls: cls)
            }
            merge[cls] = partner
        }
        // Every chain must end at a supported class that is not itself abstained (no cycles).
        for cls in merge.keys.sorted() {
            var seen: Set<String> = [cls]
            var cur = cls
            while let next = merge[cur] {
                guard !seen.contains(next) else { throw E.invalidMerge(head: h, cls: cls) }
                seen.insert(next)
                cur = next
            }
            guard status[cur] != .abstain else { throw E.invalidMerge(head: h, cls: cls) }
        }
        var covers: [String: [String]] = [:]
        let rawCovers = try stringMap(spec["covers"], "\(h).covers")
        for (cls, v) in rawCovers.sorted(by: { $0.key < $1.key }) {
            guard known.contains(cls) else { throw E.unknownClass(head: h, cls: cls) }
            guard prior[cls] != nil, case .array(let rawList) = v, !rawList.isEmpty else {
                throw E.invalidCovers(head: h, cls: cls)
            }
            var list: [String] = []
            for item in rawList {
                guard case .string(let covered) = item, known.contains(covered) else { throw E.invalidCovers(head: h, cls: cls) }
                // A covering class absorbs UNSUPPORTED classes; covering another supported class would let
                // one probability count twice.
                guard covered == cls || prior[covered] == nil else { throw E.invalidCovers(head: h, cls: cls) }
                list.append(covered)
            }
            covers[cls] = list
        }
        var decoderEvidence: Bool?
        switch spec["decoder_evidence"] {
        case nil, .null?: decoderEvidence = nil
        case .bool(let b)?: decoderEvidence = b
        default: throw E.wrongType("\(h).decoder_evidence")
        }
        return MotionHeadSpec(classOrder: order, prior: prior, status: status, tau: tau, mergeInto: merge, covers: covers,
                              decoderEvidence: decoderEvidence)
    }

    // MARK: Window

    static let windowKeys: Set<String> = ["s", "e", "posture", "locomotion", "arm_behavior", "transition",
                                          "movement_intensity", "ood_score", "is_ood"]

    static func parseWindow(_ raw: MotionHeadsJSON, index i: Int, bundle: MotionHeadsBundleInfo) throws -> MotionHeadsWindow {
        let w = try parseWindowStructure(raw, index: i)
        try w.validate(against: bundle, index: i)
        return w
    }

    /// Everything about one window that does not need the bundle (shared with `MotionHeadsWindow`'s Codable
    /// path): an object with known keys only, integral `s`/`e` (`integer`, so no conversion can trap) with
    /// `s ≥ 0` and an allowed window length, a boolean `is_ood`, known class keys, finite probabilities in
    /// [0, 1], an intensity in [0, 1] and a finite OOD score.
    static func parseWindowStructure(_ raw: MotionHeadsJSON, index i: Int) throws -> MotionHeadsWindow {
        typealias E = MotionHeadsResponseError
        guard case .object(let w) = raw else { throw E.wrongType("windows[\(i)]") }
        for key in w.keys.sorted() where !windowKeys.contains(key) { throw E.unknownField("windows[\(i)].\(key)") }
        guard let rs = w["s"], let re = w["e"] else { throw E.missingField("windows[\(i)].s/e") }
        let s = try integer(rs, "windows[\(i)].s"), e = try integer(re, "windows[\(i)].e")
        guard s >= 0, MotionHeadsWire.allowedWindowS.contains(e - s) else { throw E.invalidWindowTiming(index: i) }
        guard case .bool(let isOOD)? = w["is_ood"] else {
            throw w["is_ood"] == nil ? E.missingField("windows[\(i)].is_ood") : E.wrongType("windows[\(i)].is_ood")
        }
        var out = MotionHeadsWindow(startTs: s, endTs: e, isOOD: isOOD)
        for head in MotionHead.allCases {
            let field = "windows[\(i)].\(head.rawValue)"
            guard let value = w[head.rawValue], value != .null else { continue }
            guard case .object(let probs) = value else { throw E.wrongType(field) }
            let known = Set(head.classOrder)
            var dict: [String: Double] = [:]
            for (cls, v) in probs.sorted(by: { $0.key < $1.key }) {
                guard known.contains(cls) else { throw E.unknownClass(head: head.rawValue, cls: cls) }
                let p = try number(v, "\(field).\(cls)")
                guard p >= 0, p <= 1 + 1e-9 else { throw E.probabilityOutOfRange("\(field).\(cls)") }
                dict[cls] = min(1, p)
            }
            out.setProbabilities(head, dict)
        }
        if let v = w["movement_intensity"], v != .null {
            let x = try number(v, "windows[\(i)].movement_intensity")
            guard (0...1).contains(x) else { throw E.probabilityOutOfRange("windows[\(i)].movement_intensity") }
            out.movementIntensity = x
        }
        if let v = w["ood_score"], v != .null { out.oodScore = try number(v, "windows[\(i)].ood_score") }
        return out
    }
}

// MARK: - Track input

/// Inertia windows for one decode, with the bundle that produced them.
public struct MotionHeadsTrackInput: Equatable, Sendable {
    public var bundle: MotionHeadsBundleInfo
    public var windows: [MotionHeadsWindow]
    /// The release the stored windows carry (`ActivityExpertSelection` sets it from the row): a production config
    /// accepts only production windows, and no config accepts windows recorded as shadow; nil (windows built in
    /// memory, a replay) is accepted by a candidate config only.
    public var releaseMode: ActivityReleaseMode? = nil

    public init(bundle: MotionHeadsBundleInfo, windows: [MotionHeadsWindow]) {
        self.bundle = bundle; self.windows = windows
    }

    /// Merge validated responses for one day (chunks of one job). Every response must come from the same
    /// bundle; windows are kept in time order and a window start seen twice is kept once (the first).
    public init?(responses: [MotionHeadsResponse]) {
        guard let first = responses.first else { return nil }
        var windows: [MotionHeadsWindow] = []
        var starts: Set<Int> = []
        for r in responses {
            guard r.bundle == first.bundle else { return nil }
            for w in r.windows where starts.insert(w.startTs).inserted { windows.append(w) }
        }
        windows.sort { $0.startTs < $1.startTs }
        self.init(bundle: first.bundle, windows: windows)
    }
}

/// How the Inertia windows of one decode were used (or why not). Reported on `ActivityContextTrack`.
public struct MotionHeadsTrackReport: Codable, Equatable, Sendable {
    /// Provenance stamp when Inertia evidence was active (`inertia-1:<bundle12>:<cfgtag>`).
    public var stamp: String?
    /// Why the heads were not used as evidence (nil when they were).
    public var refusal: String?
    public var windowsIn: Int = 0
    public var attached: Int = 0
    /// No observed second in `[e, e + 2]` (Inertia never creates an observation second).
    public var droppedNoObservation: Int = 0
    /// Another window attached to the same second later.
    public var droppedSuperseded: Int = 0
    /// The window ends outside the decoded range.
    public var droppedOutOfRange: Int = 0
    /// Decoder side: windows ingested, OOD windows among them, seconds an Inertia term entered the score,
    /// and seconds a specialist mode was let through by Inertia alone.
    public var windowsIngested: Int = 0
    public var oodWindows: Int = 0
    public var evidenceSeconds: Int = 0
    public var specialistOpenings: Int = 0
    /// Seconds whose Inertia posture term was omitted because the observation said asleep or in bed: the
    /// decoder's own sleep / bed route already speaks there, and the wrist posture head is in practice a
    /// sleep detector, so counting it again would double the same evidence.
    public var postureOmittedSleep: Int = 0

    public init(stamp: String? = nil, refusal: String? = nil) {
        self.stamp = stamp; self.refusal = refusal
    }

    enum CodingKeys: String, CodingKey {
        case stamp, refusal
        case windowsIn = "windows_in", attached
        case droppedNoObservation = "dropped_no_observation", droppedSuperseded = "dropped_superseded"
        case droppedOutOfRange = "dropped_out_of_range", windowsIngested = "windows_ingested"
        case oodWindows = "ood_windows", evidenceSeconds = "evidence_seconds"
        case specialistOpenings = "specialist_openings", postureOmittedSleep = "posture_omitted_sleep"
    }

    /// Windows that reached the track input but never an observed second.
    public var dropped: Int { droppedNoObservation + droppedSuperseded + droppedOutOfRange }

    /// Two consecutive decodes of one stream (a resumed track): counts add, provenance must agree.
    func merged(with next: MotionHeadsTrackReport) -> MotionHeadsTrackReport {
        var out = self
        out.stamp = stamp ?? next.stamp
        out.refusal = refusal ?? next.refusal
        out.windowsIn += next.windowsIn; out.attached += next.attached
        out.droppedNoObservation += next.droppedNoObservation; out.droppedSuperseded += next.droppedSuperseded
        out.droppedOutOfRange += next.droppedOutOfRange; out.windowsIngested += next.windowsIngested
        out.oodWindows += next.oodWindows; out.evidenceSeconds += next.evidenceSeconds
        out.specialistOpenings += next.specialistOpenings
        out.postureOmittedSleep += next.postureOmittedSleep
        return out
    }
}

// MARK: - Evidence config

/// Whether and how strongly the decoder uses Inertia heads. `ActivityDecoderConfig.motionHeads == nil` is OFF.
///
/// Weights are per-second channel weights in the same units as the decoder's other channels (HART's encoder
/// channel is 0.8) and are tempered by `evidenceTemperature` like every channel. The body channels
/// (locomotion + posture + transition) share `bodyBudget`; the arm channel is capped by `armBudget`; no weight
/// or budget may exceed `hardCeiling`. A config outside those bounds is refused (`validate()` throws, and a
/// decoder given one runs exactly as with Inertia off).
public struct MotionHeadsEvidenceConfig: Codable, Equatable, Sendable {

    public enum Mode: String, Codable, Sendable {
        /// Heads are computed and stored elsewhere; the decoder never sees them.
        case shadow
        /// Heads enter the decoder (a second, comparison decode; never the published one).
        case candidate
        /// Heads enter the published decode. Needs a bundle whose tier is `production`.
        case production
    }

    public var mode: Mode
    /// The bundle the windows come from (provenance, calibration prior, class status, thresholds).
    public var bundle: MotionHeadsBundleInfo
    public var locomotionWeight: Double
    public var postureWeight: Double
    public var armWeight: Double
    /// Must be 0 in v1: the transition head is carried and logged, never scored.
    public var transitionWeight: Double
    public var bodyBudget: Double
    public var armBudget: Double
    /// Locomotion weight is multiplied by `1 − effectiveHartRedundancy` on seconds where the HART encoder
    /// channel also speaks. This is the floor the config asks for; the bundle may raise it with a measured ρ̂
    /// (`bundle.fusion.rho_hart`), never lower it.
    public var hartRedundancy: Double
    /// TEST-ONLY. Lets a stand-in (`encoder_kind == "standin"`) or shadow-tier bundle be used as evidence so
    /// unit tests and the offline replay can exercise the channels. Never set by the worker or the app.
    public var allowStandInEvidenceForTesting: Bool
    /// The bundle digest the deployment pinned (`FRWHOOP_INERTIA_BUNDLE_SHA256`). When set, a bundle with any
    /// other `bundle_sha256` is refused (`bundle_sha256_mismatch`). nil = not pinned.
    public var expectedBundleSHA256: String?

    /// No weight or budget may exceed this.
    public static let hardCeiling = 0.8
    public static let defaultLocomotionWeight = 0.25
    public static let defaultPostureWeight = 0.25
    public static let defaultArmWeight = 0.25
    public static let defaultBodyBudget = 0.5
    public static let defaultArmBudget = 0.5
    /// Not below the measured ρ̂ = 0.61 (WISDM validation, residual log-LR correlation between HART and the
    /// Inertia locomotion head): a discount smaller than the measured overlap would count shared evidence twice.
    public static let defaultHartRedundancy = 0.65

    public init(mode: Mode, bundle: MotionHeadsBundleInfo,
                locomotionWeight: Double = MotionHeadsEvidenceConfig.defaultLocomotionWeight,
                postureWeight: Double = MotionHeadsEvidenceConfig.defaultPostureWeight,
                armWeight: Double = MotionHeadsEvidenceConfig.defaultArmWeight,
                transitionWeight: Double = 0,
                bodyBudget: Double = MotionHeadsEvidenceConfig.defaultBodyBudget,
                armBudget: Double = MotionHeadsEvidenceConfig.defaultArmBudget,
                hartRedundancy: Double = MotionHeadsEvidenceConfig.defaultHartRedundancy,
                allowStandInEvidenceForTesting: Bool = false,
                expectedBundleSHA256: String? = nil) {
        self.mode = mode; self.bundle = bundle
        self.locomotionWeight = locomotionWeight; self.postureWeight = postureWeight
        self.armWeight = armWeight; self.transitionWeight = transitionWeight
        self.bodyBudget = bodyBudget; self.armBudget = armBudget; self.hartRedundancy = hartRedundancy
        self.allowStandInEvidenceForTesting = allowStandInEvidenceForTesting
        self.expectedBundleSHA256 = expectedBundleSHA256
    }

    /// The HART redundancy discount actually applied: the larger of the config's and the bundle's measured ρ̂.
    public var effectiveHartRedundancy: Double {
        guard let rho = bundle.fusion?.rhoHart, rho.isFinite, (0...1).contains(rho) else { return hartRedundancy }
        return max(hartRedundancy, rho)
    }

    public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
        case nonFinite(String)
        case negative(String)
        case aboveCeiling(String)
        case redundancyOutOfRange
        case transitionWeightUnsupported

        public var description: String {
            switch self {
            case .nonFinite(let f): return "\(f) is not finite"
            case .negative(let f): return "\(f) is negative"
            case .aboveCeiling(let f): return "\(f) exceeds the hard ceiling \(MotionHeadsEvidenceConfig.hardCeiling)"
            case .redundancyOutOfRange: return "hartRedundancy must be within [0, 1]"
            case .transitionWeightUnsupported: return "transitionWeight must be 0 (the transition head is log-only in v1)"
            }
        }
    }

    /// Refuse anything outside the documented bounds. Budgets are enforced by scaling at use (`effective`).
    public func validate() throws {
        let fields: [(String, Double)] = [
            ("locomotionWeight", locomotionWeight), ("postureWeight", postureWeight), ("armWeight", armWeight),
            ("transitionWeight", transitionWeight), ("bodyBudget", bodyBudget), ("armBudget", armBudget),
        ]
        for (name, value) in fields {
            guard value.isFinite else { throw ValidationError.nonFinite(name) }
            guard value >= 0 else { throw ValidationError.negative(name) }
            guard value <= Self.hardCeiling else { throw ValidationError.aboveCeiling(name) }
        }
        guard hartRedundancy.isFinite, (0...1).contains(hartRedundancy) else { throw ValidationError.redundancyOutOfRange }
        guard transitionWeight == 0 else { throw ValidationError.transitionWeightUnsupported }
    }

    /// Why this config may not feed the decoder, or nil when it may. Shadow never feeds the decoder; a
    /// stand-in encoder or a bundle below the required tier is refused unless the test-only override is set.
    public var evidenceRefusal: String? {
        do { try validate() } catch { return "invalid_config: \(error)" }
        if mode == .shadow { return "shadow_mode" }
        // A pinned deployment uses exactly the bundle it pinned (the test override does not lift this).
        if let expected = expectedBundleSHA256, expected != bundle.bundleSha256 { return "bundle_sha256_mismatch" }
        let required: MotionHeadsEvidenceTier = mode == .production ? .production : .candidate
        if !allowStandInEvidenceForTesting {
            if !bundle.encoderKind.isPinned { return "encoder_kind_\(bundle.encoderKind.rawValue)" }
            if bundle.evidenceTierMax < required { return "evidence_tier_\(bundle.evidenceTierMax.rawValue)" }
        }
        guard bundle.preprocessingVersion == MotionHeadsWire.preprocessingVersion else { return "preprocessing_mismatch" }
        guard MotionHeadsWire.allowedHopS.contains(bundle.hopS) else { return "invalid_hop" }
        return nil
    }

    /// Short digest of everything in the config that changes decoder output (bundle digest excluded: it is
    /// carried beside it).
    public var configTag: String {
        let text = "m=\(mode.rawValue);l=\(locomotionWeight);p=\(postureWeight);a=\(armWeight);t=\(transitionWeight)"
            + ";bb=\(bodyBudget);ab=\(armBudget);rho=\(effectiveHartRedundancy);si=\(allowStandInEvidenceForTesting ? 1 : 0)"
            + ";h=\(bundle.hopS);w=\(bundle.windowS)"
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hex = String(h, radix: 16)
        return String((String(repeating: "0", count: max(0, 16 - hex.count)) + hex).prefix(8))
    }

    /// The provenance stamp written into `ActivityStateVersions.motionHeads` when this config is active.
    /// A stand-in bundle (test override) never claims to be Inertia-1.
    public var provenanceStamp: String? {
        guard evidenceRefusal == nil else { return nil }
        let prefix: String
        switch bundle.encoderKind {
        case .inertia1: prefix = "inertia-1"
        case .actinet: prefix = "actinet"
        case .standin: prefix = "standin-test"
        }
        return "\(prefix):\(bundle.bundle12):\(configTag)"
    }
}
