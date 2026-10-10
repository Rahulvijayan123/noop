import Foundation
import CCrypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Loopback inference sidecar client
//
// The candidate ("shadow") lane calls the Python inference sidecar over
// LOOPBACK HTTP only. The sidecar binds 127.0.0.1 (never 0.0.0.0), so no public
// port is opened and no firewall rule changes are needed (see
// docs/server-physiology-migration and deploy/frwhoop-inference.service).
//
// Contract rules this client enforces, and why:
//
//   * Loopback-only. A non-loopback host is REFUSED at construction unless the
//     explicit test flag FRWHOOP_INFERENCE_ALLOW_NON_LOOPBACK=1 is set. A
//     misconfigured URL must fail loudly, not quietly expose an inference
//     endpoint on the network.
//   * Bounded deadline. URLSession's own `timeoutIntervalForRequest` is set from
//     FRWHOOP_INFERENCE_TIMEOUT_MS (default 25000, above the sidecar's own
//     20000 ms budget so the sidecar's verdict wins the race) and a semaphore backstop adds
//     a hard ceiling, because the existing B2 helper (`URLSession.synchronous`,
//     B2Storage.swift:153-179) waits with no deadline of its own. A hung sidecar
//     must never pin a scoring lane thread: the deadline stays well under the
//     worker's `TimeoutStopSec=90` and the 120 s statement timeout.
//   * Bounded response size. A malformed or hostile body cannot be decoded
//     without limit.
//   * A closed failure taxonomy. Every transport/shape failure maps to one of
//     the machine-readable withheld reasons the candidate contract accepts
//     (`timeout`, `not_ready`, `provider_error`), so the scoring path always
//     settles deterministically instead of retrying without bound.
//   * Backpressure is not a failure. HTTP 429 with error code `busy` (the
//     sidecar could not admit the request; docs/model-integration/README.md)
//     becomes `.busy`, which no caller records as a result: the work stays
//     pending and the caller comes back after `Retry-After`.

/// Withheld reasons the candidate contract accepts (implementation plan,
/// "Shared contracts" -> withheld reasons). The three `isClientFailure` cases are
/// the ones THIS client produces; the rest are provider verdicts carried through
/// from the sidecar response. It mirrors the sidecar's `WithheldReason` enum
/// (Tools/InferenceWorker contract.py) member for member, including the HRV
/// adapter's `unresolved_adjacency` extension: a verdict missing here would be
/// stored as `provider_error`, i.e. as a fault of ours instead of the data's.
/// The SQL whitelist in `physiology_record_candidate_result` lists the same set
/// (20261009140000_candidate_withheld_unresolved_adjacency.sql).
enum CandidateWithheldReason: String, Codable, CaseIterable {
    case blockedInput = "blocked_input"
    case blockedArtifact = "blocked_artifact"
    case blockedLicense = "blocked_license"
    case unverified
    case insufficientCoverage = "insufficient_coverage"
    case artifactFraction = "artifact_fraction"
    case providerError = "provider_error"
    case timeout
    case notReady = "not_ready"
    /// HRV: a burst boundary could not be resolved from observation identity, so
    /// the interval series is withheld rather than spliced (a data verdict).
    case unresolvedAdjacency = "unresolved_adjacency"

    /// True for the reasons the Swift client itself settles (never a provider
    /// verdict). Used by the tests to prove the taxonomy is closed.
    var isClientFailure: Bool {
        switch self {
        case .providerError, .timeout, .notReady: return true
        case .blockedInput, .blockedArtifact, .blockedLicense, .unverified,
             .insufficientCoverage, .artifactFraction, .unresolvedAdjacency: return false
        }
    }
}

/// Every way the sidecar call can fail, with the withheld reason it settles as.
enum InferenceClientError: Error, CustomStringConvertible {
    /// No URL configured: the candidate lane is off and nothing is called.
    case disabled
    /// The configured URL is not loopback (and the test flag is not set).
    case nonLoopbackURL(String)
    /// Connection refused / host unreachable / DNS failure / TLS failure.
    case refused(String)
    /// The deadline elapsed before a response arrived.
    case timeout(String)
    /// HTTP 503: the sidecar is up but the provider is not ready.
    case notReady(String)
    /// HTTP 429 `busy`: the sidecar did not admit the request (every worker busy, or
    /// still warming up). Transient and never a result: nothing was computed, so the
    /// caller leaves the work pending. The detail starts `retry_after_s=N`.
    case busy(String)
    /// Any other non-200 status.
    case non200(Int, String)
    /// The body could not be decoded into the contract shape, or failed
    /// validation (unknown status, non-finite value, oversized body).
    case malformed(String)
    /// Any other transport failure.
    case transport(String)

    /// The machine-readable reason this failure settles as.
    ///
    /// `.busy` maps to `not_ready` only so the switch stays total: no caller ever
    /// records a busy answer (CandidateStage keeps the work pending instead).
    var withheldReason: CandidateWithheldReason {
        switch self {
        case .timeout: return .timeout
        case .notReady, .busy: return .notReady
        case .disabled, .nonLoopbackURL, .refused, .non200, .malformed, .transport:
            return .providerError
        }
    }

    /// True for the sidecar's backpressure answer.
    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }

    /// The `Retry-After` a busy answer carried, in seconds.
    var retryAfterSeconds: Int? {
        guard case .busy(let detail) = self, detail.hasPrefix("retry_after_s=") else { return nil }
        let digits = detail.dropFirst("retry_after_s=".count).prefix { $0.isNumber }
        return Int(digits)
    }

    var description: String {
        switch self {
        case .disabled: return "inference_disabled"
        case .nonLoopbackURL(let h): return "inference_url_not_loopback:\(h)"
        case .refused(let d): return "inference_refused:\(d)"
        case .timeout(let d): return "inference_timeout:\(d)"
        case .notReady(let d): return "inference_not_ready:\(d)"
        case .busy(let d): return "inference_busy:\(d)"
        case .non200(let code, let d): return "inference_http_\(code):\(d)"
        case .malformed(let d): return "inference_malformed:\(d)"
        case .transport(let d): return "inference_transport:\(d)"
        }
    }
}

// MARK: - JSON value

/// A minimal JSON value so metric-specific `input` payloads (built as Swift
/// dictionaries in DayScoring) can be carried inside the `Codable` envelope
/// without losing type information.
indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(any: Any) {
        switch any {
        case let v as JSONValue: self = v
        // A native Swift Bool (its dynamic type is exactly Bool; a JSONSerialization number never is).
        case let v as Bool where type(of: any) == Bool.self: self = .bool(v)
        // JSONSerialization numbers. On Darwin `as Bool` would also match NSNumber 0 and 1, so a
        // histogram edge or a count of 0/1 used to become a boolean; classify the NSNumber itself.
        case let n as NSNumber: self = JSONValue.number(n)
        case let v as Int: self = .int(v)
        case let v as Int64: self = .int(Int(v))
        case let v as Double: self = .double(v)
        case let v as Float: self = .double(Double(v))
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (k, value) in v { out[k] = JSONValue(any: value) }
            self = .object(out)
        case is NSNull: self = .null
        default: self = .null
        }
    }

    /// An NSNumber as the JSON value it was parsed from: a boolean only when it really is one,
    /// an integer when it is integral and fits, a double otherwise.
    static func number(_ n: NSNumber) -> JSONValue {
        if isBoolean(n) { return .bool(n.boolValue) }
        let type = String(cString: n.objCType)
        if ["q", "l", "i", "s", "c", "Q", "L", "I", "S", "C"].contains(type) {
            if type == "Q" || type == "L", n.uint64Value > UInt64(Int.max) { return .double(n.doubleValue) }
            return .int(n.intValue)
        }
        let d = n.doubleValue
        // Integral doubles stay integers, as the `as Int` cast this replaces made them.
        if d.isFinite, d == d.rounded(), abs(d) <= 9_007_199_254_740_992 { return .int(Int(d)) }
        return .double(d)
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        // swift-corelibs-foundation: JSONSerialization makes true/false as NSNumber(value: Bool),
        // whose objCType is "c" (JSON numbers never parse to a char); "B" is the C99 bool code.
        let type = String(cString: n.objCType)
        return type == "c" || type == "B"
        #endif
    }

    /// The `Any` form, for JSONSerialization-based helpers and tests.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.anyValue }
        case .object(let v): return v.mapValues { $0.anyValue }
        }
    }

    /// A number as `Double` when this is a numeric value.
    var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    /// A nested object member, or nil.
    func member(_ key: String) -> JSONValue? {
        if case .object(let obj) = self { return obj[key] }
        return nil
    }

    /// A nested string member, or nil.
    func stringMember(_ key: String) -> String? {
        if case .string(let s) = member(key) ?? .null { return s }
        return nil
    }

    /// Structural equality, with `int`/`double` compared numerically. Written
    /// explicitly rather than synthesized: the enum is recursive, and the mixed
    /// numeric case must compare equal for `1` and `1.0`.
    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)): return Double(a) == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        default: return false
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }
}

// MARK: - Sidecar HTTP contract (Codable)

/// `POST /v1/infer` request. Field names match the plan's Sidecar HTTP contract
/// exactly (snake_case on the wire).
struct InferenceRequest: Codable {
    struct Context: Codable {
        let userId: String
        let deviceId: String
        let intervalStartUTC: String
        let intervalEndUTC: String
        let ianaTimezone: String
        let profileVersion: String?
        let configVersion: String?
        let correctionsVersion: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case deviceId = "device_id"
            case intervalStartUTC = "interval_start_utc"
            case intervalEndUTC = "interval_end_utc"
            case ianaTimezone = "iana_timezone"
            case profileVersion = "profile_version"
            case configVersion = "config_version"
            case correctionsVersion = "corrections_version"
        }

        init(userId: String, deviceId: String, intervalStartUTC: String, intervalEndUTC: String,
             ianaTimezone: String, profileVersion: String? = nil,
             configVersion: String? = nil, correctionsVersion: String? = nil) {
            self.userId = userId
            self.deviceId = deviceId
            self.intervalStartUTC = intervalStartUTC
            self.intervalEndUTC = intervalEndUTC
            self.ianaTimezone = ianaTimezone
            self.profileVersion = profileVersion
            self.configVersion = configVersion
            self.correctionsVersion = correctionsVersion
        }

        /// The contract lists all eight context keys; encode the absent ones as
        /// explicit nulls rather than omitting the key.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(userId, forKey: .userId)
            try c.encode(deviceId, forKey: .deviceId)
            try c.encode(intervalStartUTC, forKey: .intervalStartUTC)
            try c.encode(intervalEndUTC, forKey: .intervalEndUTC)
            try c.encode(ianaTimezone, forKey: .ianaTimezone)
            try c.encode(profileVersion, forKey: .profileVersion)
            try c.encode(configVersion, forKey: .configVersion)
            try c.encode(correctionsVersion, forKey: .correctionsVersion)
        }
    }

    struct Provider: Codable {
        let providerId: String?
        let expectedVersions: [String: String]?

        enum CodingKeys: String, CodingKey {
            case providerId = "provider_id"
            case expectedVersions = "expected_versions"
        }

        init(providerId: String?, expectedVersions: [String: String]? = nil) {
            self.providerId = providerId
            self.expectedVersions = expectedVersions
        }
    }

    let metric: String
    let context: Context
    let input: JSONValue
    let provider: Provider?

    enum CodingKeys: String, CodingKey { case metric, context, input, provider }

    init(metric: String, context: Context, input: JSONValue, provider: Provider? = nil) {
        self.metric = metric
        self.context = context
        self.input = input
        self.provider = provider
    }

    /// The canonical JSON bytes of this request, used for the idempotency digest.
    func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// `POST /v1/infer` response.
struct InferenceResponse: Codable {
    struct Versions: Codable {
        let adapter: String?
        let preprocessing: String?
        let dependency: String?
        let config: String?
        let model: String?
    }

    struct InputEcho: Codable {
        let sha256: String?
        let refs: JSONValue?
    }

    struct Interval: Codable {
        let startUTC: String?
        let endUTC: String?

        enum CodingKeys: String, CodingKey {
            case startUTC = "start_utc"
            case endUTC = "end_utc"
        }
    }

    struct Result: Codable {
        let value: Double?
        let unit: String?
        let stages: JSONValue?
        let labelSpace: String?

        enum CodingKeys: String, CodingKey {
            case value, unit, stages
            case labelSpace = "label_space"
        }
    }

    /// One of `ok` / `withheld` / `error`.
    let status: String
    let metric: String?
    let providerId: String?
    let versions: Versions?
    let input: InputEcho?
    let result: Result?
    let interval: Interval?
    let finalOrProvisional: String?
    let coverage: JSONValue?
    let rawScores: JSONValue?
    let diagnostics: JSONValue?
    let runtimeMs: Int?
    let withheldReasonTopLevel: String?

    enum CodingKeys: String, CodingKey {
        case status, metric, versions, input, result, interval, coverage, diagnostics
        case providerId = "provider_id"
        case finalOrProvisional = "final_or_provisional"
        case rawScores = "raw_scores"
        case runtimeMs = "runtime_ms"
        case withheldReasonTopLevel = "withheld_reason"
    }

    /// The machine-readable withheld reason. The plan fixes the reason VOCABULARY
    /// but not the exact key, so accept the top-level `withheld_reason` first and
    /// then the two shapes the sidecar may use inside `diagnostics`.
    ///
    /// INTEGRATION SEAM (W-A): if the sidecar settles on a different key, add it
    /// here only. Nothing else in the worker reads the raw diagnostics.
    var withheldReason: String? {
        if let v = withheldReasonTopLevel, !v.isEmpty { return v }
        if let d = diagnostics {
            if let v = d.stringMember("withheld_reason"), !v.isEmpty { return v }
            if let v = d.stringMember("reason"), !v.isEmpty { return v }
            if let v = d.stringMember("status_reason"), !v.isEmpty { return v }
        }
        return nil
    }

    var isOK: Bool { status == "ok" }
    var isWithheld: Bool { status == "withheld" }
    var isError: Bool { status == "error" }
}

/// `GET /healthz`.
struct HealthzResponse: Codable {
    struct ProviderHealth: Codable {
        let ready: Bool
        let version: String?
        let reason: String?
    }

    let ready: Bool
    let providers: [String: ProviderHealth]?

    /// Names of the providers currently reporting ready.
    var readyProviderNames: [String] {
        guard let providers else { return [] }
        return providers.filter { $0.value.ready }.keys.sorted()
    }
}

/// `GET /v1/providers` capability manifest. The plan fixes the per-provider
/// FIELDS but not the container shape, so both a list and a provider-keyed object
/// are accepted.
struct ProvidersManifest: Codable {
    struct Capability: Codable {
        let metric: String?
        let providerId: String?
        let versions: JSONValue?
        let requiredSignals: JSONValue?
        let labelSpace: String?
        let behavior: String?
        let eligibility: String?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case metric, versions, behavior, eligibility, reason
            case providerId = "provider_id"
            case requiredSignals = "required_signals"
            case labelSpace = "label_space"
        }
    }

    let providers: [Capability]

    enum CodingKeys: String, CodingKey { case providers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([Capability].self, forKey: .providers) {
            providers = list
            return
        }
        if let byID = try? container.decode([String: Capability].self, forKey: .providers) {
            providers = byID.keys.sorted().map { key in
                let c = byID[key]!
                return Capability(metric: c.metric, providerId: c.providerId ?? key, versions: c.versions,
                                  requiredSignals: c.requiredSignals, labelSpace: c.labelSpace,
                                  behavior: c.behavior, eligibility: c.eligibility, reason: c.reason)
            }
            return
        }
        throw DecodingError.dataCorruptedError(forKey: .providers, in: container,
                                               debugDescription: "providers must be a list or an object")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providers, forKey: .providers)
    }
}

// MARK: - Endpoint policy

/// Loopback-only URL policy. Kept separate from the client so it can be unit
/// tested without opening a socket.
enum InferenceEndpoint {
    /// The only escape hatch, for tests and for a future private-network
    /// deployment that the parent explicitly approves.
    static let allowNonLoopbackEnvKey = "FRWHOOP_INFERENCE_ALLOW_NON_LOOPBACK"

    /// True for `127.0.0.0/8`, `::1` and `localhost`. Anything else is not
    /// loopback and is refused.
    static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if h.isEmpty { return false }
        if h == "localhost" || h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "127",
           parts.allSatisfy({ Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }) {
            return true
        }
        return false
    }

    /// Parse a configured URL, refusing a non-loopback host.
    static func parse(_ raw: String, allowNonLoopback: Bool = false) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InferenceClientError.disabled }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw InferenceClientError.malformed("FRWHOOP_INFERENCE_URL is not an absolute http(s) URL")
        }
        guard let host = url.host, !host.isEmpty else {
            throw InferenceClientError.malformed("FRWHOOP_INFERENCE_URL has no host")
        }
        guard allowNonLoopback || isLoopbackHost(host) else {
            throw InferenceClientError.nonLoopbackURL(host)
        }
        return url
    }
}

// MARK: - Client

/// Synchronous, deadline-bounded client for the loopback inference sidecar.
final class InferenceClient {
    /// Default request deadline: FRWHOOP_INFERENCE_TIMEOUT_MS.
    ///
    /// 25 000 ms, deliberately STRICTLY ABOVE the sidecar's own per-request budget
    /// (deploy/inference.env.example sets `FRWHOOP_REQUEST_TIMEOUT_MS=20000`). If
    /// the two were equal, a request that consumed the sidecar's whole budget would
    /// hit the worker's own request timeout at the same instant, and the worker
    /// would report a client `timeout` instead of carrying the sidecar's
    /// `withheld`/`timeout` verdict and its diagnostics. The semaphore backstop
    /// (`timeoutMS + deadlineSlackMS`) then leaves the sidecar a clear margin.
    static let defaultTimeoutMS = 25_000
    /// Hard cap on a response body, so a malformed body cannot be decoded without bound.
    static let defaultMaxResponseBytes = 4 << 20
    /// Extra slack on the semaphore backstop over URLSession's own request timeout.
    static let deadlineSlackMS = 1_500

    let baseURL: URL
    let timeoutMS: Int
    private let session: URLSession
    private let maxResponseBytes: Int

    /// Build a client from the environment. Returns nil when
    /// FRWHOOP_INFERENCE_URL is absent or empty: the candidate lane is then fully
    /// off and NOTHING is called (byte-identical legacy behaviour).
    static func fromEnvironment(_ env: [String: String]) throws -> InferenceClient? {
        let raw = env["FRWHOOP_INFERENCE_URL"] ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let allowNonLoopback = (env[InferenceEndpoint.allowNonLoopbackEnvKey] ?? "") == "1"
        let url = try InferenceEndpoint.parse(raw, allowNonLoopback: allowNonLoopback)
        let timeoutMS = Int(env["FRWHOOP_INFERENCE_TIMEOUT_MS"] ?? "") ?? defaultTimeoutMS
        return InferenceClient(baseURL: url, timeoutMS: timeoutMS)
    }

    /// `timeoutMS` must be positive; a non-positive value falls back to the default.
    init(baseURL: URL, timeoutMS: Int = InferenceClient.defaultTimeoutMS,
         maxResponseBytes: Int = InferenceClient.defaultMaxResponseBytes) {
        self.baseURL = baseURL
        self.timeoutMS = timeoutMS > 0 ? timeoutMS : InferenceClient.defaultTimeoutMS
        self.maxResponseBytes = maxResponseBytes > 0 ? maxResponseBytes : InferenceClient.defaultMaxResponseBytes
        let cfg = URLSessionConfiguration.ephemeral
        // URLSession's own request timeout is the primary bound; the resource
        // timeout is >= it so a slow-but-progressing body is not cut off early.
        cfg.timeoutIntervalForRequest = Double(self.timeoutMS) / 1000.0
        cfg.timeoutIntervalForResource = Double(self.timeoutMS) / 1000.0 + 10.0
        #if !canImport(FoundationNetworking)
        // Linux's FoundationNetworking exposes this read-only (it never waits), so only Apple sets it.
        cfg.waitsForConnectivity = false
        #endif
        self.session = URLSession(configuration: cfg)
    }

    // MARK: Calls

    /// POST /v1/infer. Throws `InferenceClientError` for the closed failure
    /// taxonomy; returns the decoded response otherwise (including a provider
    /// `withheld` / `error` status, which is a verdict, not a client failure).
    ///
    /// `timeoutMSOverride` lets a caller with a shorter, outer deadline (the
    /// candidate stage's per-drain wall-clock cap) bound this one call without
    /// changing the session's configured timeout. It can only SHORTEN the wait,
    /// never extend it, and the semaphore backstop follows the shortened value, so
    /// a hung sidecar still cannot pin the caller past its own deadline.
    func infer(_ request: InferenceRequest, timeoutMSOverride: Int? = nil) throws -> InferenceResponse {
        let body: Data
        do {
            body = try request.canonicalJSON()
        } catch {
            throw InferenceClientError.malformed("request encoding failed: \(error)")
        }
        return try infer(body: body, metric: request.metric, timeoutMSOverride: timeoutMSOverride)
    }

    /// `POST /v1/infer` with an already-encoded request body (a caller that writes a large
    /// numeric input itself).
    func infer(body: Data, metric: String, timeoutMSOverride: Int? = nil) throws -> InferenceResponse {
        var urlRequest = URLRequest(url: endpoint("/v1/infer"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body
        let budget = timeoutMSOverride.map { max(1, min($0, timeoutMS)) } ?? timeoutMS
        let (data, http) = try send(urlRequest, timeoutMS: budget)
        return try Self.decodeInferenceResponse(data, http: http, expectedMetric: metric)
    }

    /// GET /healthz. Readiness polling uses a shorter deadline than inference so a
    /// stalled sidecar cannot delay the heartbeat.
    func healthz(deadlineMS: Int? = nil) throws -> HealthzResponse {
        let budget = min(deadlineMS ?? min(timeoutMS, 2_500), timeoutMS)
        var urlRequest = URLRequest(url: endpoint("/healthz"))
        urlRequest.httpMethod = "GET"
        let (data, http) = try send(urlRequest, timeoutMS: max(250, budget))
        try Self.checkStatus(http, data: data)
        do {
            return try JSONDecoder().decode(HealthzResponse.self, from: data)
        } catch {
            throw InferenceClientError.malformed("healthz decode failed: \(error)")
        }
    }

    /// POST /v1/sleep-features (the deterministic sleep-phenotype
    /// enrichment; spec 7.1). Not an inference request and NOT a candidate
    /// provider, so the response is returned RAW — the enrichment lane owns
    /// its own typed validation (SleepFeatureEnrichment.validateResponse),
    /// and no InferenceResponse contract applies to it. Same bounded-wait
    /// transport as `/v1/infer`, with a shorter default budget.
    func sleepFeatures(body: Data, timeoutMSOverride: Int? = nil) throws -> Data {
        var urlRequest = URLRequest(url: endpoint("/v1/sleep-features"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body
        let budget = timeoutMSOverride.map { max(250, min($0, timeoutMS)) } ?? timeoutMS
        let (data, http) = try send(urlRequest, timeoutMS: budget)
        try Self.checkStatus(http, data: data)
        guard data.count <= maxResponseBytes else {
            throw InferenceClientError.malformed(
                "sleep-features response body \(data.count) bytes exceeds cap \(maxResponseBytes)")
        }
        return data
    }

    /// GET /v1/providers (capability manifest).
    func providers() throws -> ProvidersManifest {
        var urlRequest = URLRequest(url: endpoint("/v1/providers"))
        urlRequest.httpMethod = "GET"
        let (data, http) = try send(urlRequest, timeoutMS: timeoutMS)
        try Self.checkStatus(http, data: data)
        do {
            return try JSONDecoder().decode(ProvidersManifest.self, from: data)
        } catch {
            throw InferenceClientError.malformed("providers decode failed: \(error)")
        }
    }

    private func endpoint(_ path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = (components?.path ?? "").hasSuffix("/")
            ? String((components?.path ?? "").dropLast())
            : (components?.path ?? "")
        components?.path = basePath + path
        components?.query = nil
        return components?.url ?? baseURL.appendingPathComponent(path)
    }

    // MARK: Transport

    /// One request with a bounded wait. URLSession's request timeout normally
    /// fires first; the semaphore deadline is the hard backstop so a lane thread
    /// can never block without bound.
    private func send(_ request: URLRequest, timeoutMS budgetMS: Int) throws -> (Data, HTTPURLResponse) {
        final class Box: @unchecked Sendable {
            var out: (Data?, URLResponse?, Error?)?
            let lock = NSLock()
            func set(_ v: (Data?, URLResponse?, Error?)) {
                lock.lock(); defer { lock.unlock() }
                out = v
            }
            func get() -> (Data?, URLResponse?, Error?)? {
                lock.lock(); defer { lock.unlock() }
                return out
            }
        }
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        let task = session.dataTask(with: request) { d, r, e in
            box.set((d, r, e))
            sem.signal()
        }
        task.resume()
        let backstop = budgetMS + InferenceClient.deadlineSlackMS
        if sem.wait(timeout: .now() + .milliseconds(backstop)) == .timedOut {
            task.cancel()
            throw InferenceClientError.timeout("no response within \(budgetMS) ms")
        }
        guard let (data, response, error) = box.get() else {
            throw InferenceClientError.transport("no result recorded")
        }
        if let error {
            throw Self.classifyTransport(error, budgetMS: budgetMS)
        }
        guard let http = response as? HTTPURLResponse else {
            throw InferenceClientError.transport("response is not HTTP")
        }
        guard let data else {
            throw InferenceClientError.transport("empty response body")
        }
        guard data.count <= maxResponseBytes else {
            throw InferenceClientError.malformed("response body \(data.count) bytes exceeds cap \(maxResponseBytes)")
        }
        return (data, http)
    }

    static func classifyTransport(_ error: Error, budgetMS: Int) -> InferenceClientError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return .timeout("URLSession timed out after \(budgetMS) ms")
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed, NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted:
                // Nothing is listening (or the name/TLS could not be established):
                // the sidecar is unreachable.
                return .refused("\(ns.code): \(ns.localizedDescription)")
            case NSURLErrorNetworkConnectionLost:
                // The peer went away mid-request: transport, not reachability.
                return .transport("\(ns.code): \(ns.localizedDescription)")
            default:
                return .transport("NSURLError \(ns.code): \(ns.localizedDescription)")
            }
        }
        return .transport(String(describing: error))
    }

    /// HTTP status policy: 200 is the only success; 503 is `not_ready` (the
    /// sidecar is up, the provider is not); 429 with error code `busy` is
    /// backpressure (`.busy`); everything else is `provider_error`.
    static func checkStatus(_ http: HTTPURLResponse, data: Data) throws {
        if http.statusCode == 200 { return }
        let snippet = Self.bodySnippet(data)
        if http.statusCode == 503 {
            throw InferenceClientError.notReady(snippet)
        }
        if http.statusCode == 429, Self.errorCode(data) == "busy" {
            let retryAfter = Self.retryAfterSeconds(http) ?? Self.defaultBusyRetryAfterSeconds
            throw InferenceClientError.busy("retry_after_s=\(retryAfter) \(snippet)")
        }
        throw InferenceClientError.non200(http.statusCode, snippet)
    }

    /// Used when a busy answer carries no usable `Retry-After`.
    static let defaultBusyRetryAfterSeconds = 5

    /// `Retry-After` as whole seconds (the sidecar always sends delta-seconds),
    /// clamped to 1...300 so a hostile header cannot park work for hours.
    static func retryAfterSeconds(_ http: HTTPURLResponse) -> Int? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), let seconds = Int(raw) else { return nil }
        return min(300, max(1, seconds))
    }

    /// `error.code` of a JSON error body, or nil.
    static func errorCode(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data.prefix(64 << 10))) as? [String: Any],
              let error = obj["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }

    static func decodeInferenceResponse(_ data: Data, http: HTTPURLResponse,
                                        expectedMetric: String? = nil) throws -> InferenceResponse {
        try checkStatus(http, data: data)
        let decoded: InferenceResponse
        do {
            decoded = try JSONDecoder().decode(InferenceResponse.self, from: data)
        } catch {
            throw InferenceClientError.malformed("infer decode failed: \(error)")
        }
        let status = decoded.status.lowercased()
        guard status == "ok" || status == "withheld" || status == "error" else {
            throw InferenceClientError.malformed("unknown status '\(decoded.status)'")
        }
        if let expected = expectedMetric, let got = decoded.metric, !got.isEmpty, got != expected {
            throw InferenceClientError.malformed("metric mismatch: asked \(expected), got \(got)")
        }
        if status == "ok" {
            guard let result = decoded.result else {
                throw InferenceClientError.malformed("status ok without a result")
            }
            let hasScalar = result.value != nil
            let hasStages = result.stages != nil
            guard hasScalar || hasStages else {
                throw InferenceClientError.malformed("status ok without value or stages")
            }
            if let value = result.value, !value.isFinite {
                throw InferenceClientError.malformed("non-finite value")
            }
            if hasScalar && !hasStages, (result.unit ?? "").isEmpty {
                throw InferenceClientError.malformed("status ok scalar without a unit")
            }
        }
        if status == "withheld", (decoded.withheldReason ?? "").isEmpty {
            throw InferenceClientError.malformed("status withheld without a reason")
        }
        return decoded
    }

    private static func bodySnippet(_ data: Data) -> String {
        let text = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Digests

    /// sha256 of the canonical (sorted-keys) JSON encoding of the request input
    /// payload. This is the digest the DB uniqueness key and the sidecar's
    /// `input.sha256` both use, so a replay is idempotent by construction.
    static func inputDigest(_ input: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(input)
        return sha256Hex(data)
    }
}
