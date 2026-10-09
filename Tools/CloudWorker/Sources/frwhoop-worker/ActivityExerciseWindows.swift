import Foundation
import StrandAnalytics

// ActivityExerciseWindows.swift — RecGym gym-exercise recognition on the server, SHADOW ONLY
// (Tools/ActivityContext/RECGYM.md §6).
//
// A fourth, separate Python process (`python -m activity_context.recgym.serve --weights-path <file>`, its own timeout,
// restart cap and response cap) is asked for `exercise-windows-1` windows (4 s, 2 s hop, twelve RecGym class
// probabilities) for the same IMU chunks the HART service just inferred. It is never part of the lane's readiness
// gate and nothing it does can fail a job:
//
//   • every failure (checkpoint missing or mismatched, a pin refusal, timeout, crash, malformed or invalid output,
//     NaN) is classified, counted and logged once per distinct reason, and the HART path continues untouched; a
//     failure that would repeat stops the head for the rest of the job, and it has a per-job time budget;
//   • the windows are written to their OWN table (`activity_exercise_windows`, one row per window) through their own
//     fenced RPC under a savepoint before the v1 publish, so a rejection or a missing migration never reaches the
//     other publishes in the same transaction;
//   • there is no candidate mode: the head is registered with the release policy as `exercise_recognition`, which no
//     selection source carries (`ActivityExpertAuthority.shadowOnly`), so it shapes no decode, no canonical value and
//     not the exercise-session rule. Its model was trained on a wrist; the owner's strap is on the upper arm, and the
//     publish function records the declared placement and `placement_supported` with every window.
//
// Cost control: a job re-reads the whole day, but a chunk whose request and child are unchanged is answered from
// `responses` (no model call), and a chunk whose windows this process already published (committed) is not sent
// again (`published`). After a restart each day's chunks are sent once; the RPC leaves identical rows untouched.

/// FRWHOOP_EXERCISE_* settings. Off unless `FRWHOOP_EXERCISE_ENABLED` is on and the checkpoint path is configured.
struct ExerciseSettings: Equatable {
    var enabled: Bool
    /// The pinned checkpoint (`wrist_-_imu_only_best.pt`, or a directory holding it), passed as `--weights-path`.
    var weightsPath: String?
    var python: String
    /// Worker-side per-request timeout, already clamped to at most a third of the job lease.
    var timeoutSeconds: Double
    /// The `model_version` the deployment pins (FRWHOOP_EXERCISE_MODEL_VERSION).
    var modelVersion: String? = nil
    /// The checkpoint sha256 the deployment pins (FRWHOOP_EXERCISE_WEIGHTS_SHA256).
    var weightsSHA256: String? = nil
    /// Why the head stays off although it was asked for (a missing path, a mode other than shadow, a bad value …).
    var configurationError: String?
    /// Settings that were adjusted rather than refused (a clamped timeout); logged once at start-up.
    var warnings: [String] = []
    var jobBudgetSeconds: Double = ExerciseSettings.defaultJobBudgetSeconds
    /// FRWHOOP_EXERCISE_THREADS: torch and numerical-library threads of the serve process (1…16, default 1).
    var threads: Int = 1
    /// FRWHOOP_EXERCISE_RETENTION_DAYS: windows older than this are pruned (1…365, default 14).
    var retentionDays: Int = ExerciseSettings.defaultRetentionDays

    static let serveModule = ["-m", "activity_context.recgym.serve"]
    static let defaultTimeoutSeconds = 60.0
    /// A full day is ~43,000 windows: about 24 one-hour chunks of ~1 s each on one thread (RECGYM.md §7).
    static let defaultJobBudgetSeconds = 300.0
    static let defaultRetentionDays = 14

    /// FRWHOOP_EXERCISE_ENABLED (1/true/yes/on, default off; anything unrecognised is a configuration error),
    /// FRWHOOP_EXERCISE_WEIGHTS_PATH (required when on), FRWHOOP_EXERCISE_MODE (only `shadow` is accepted; anything
    /// else is a configuration error, never a lowering), FRWHOOP_EXERCISE_PYTHON (default: the activity python),
    /// FRWHOOP_EXERCISE_TIMEOUT_SECONDS (default 60, clamped to at most `leaseSeconds / 3`),
    /// FRWHOOP_EXERCISE_JOB_BUDGET_SECONDS (default 300), FRWHOOP_EXERCISE_THREADS (1…16),
    /// FRWHOOP_EXERCISE_MODEL_VERSION / FRWHOOP_EXERCISE_WEIGHTS_SHA256 (pins, enforced when set),
    /// FRWHOOP_EXERCISE_RETENTION_DAYS (1…365, default 14). A setting that cannot be honoured switches the head off
    /// with a reason; it never stops the worker.
    static func fromEnvironment(_ env: [String: String], activityPython: String = "python3",
                                leaseSeconds: Int = 300) -> ExerciseSettings {
        func value(_ key: String) -> String? {
            env[key].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        var errors: [String] = []
        var asked = false
        if let raw = value("FRWHOOP_EXERCISE_ENABLED") {
            if let b = InertiaSettings.parseBool(raw) { asked = b }
            else { errors.append("unknown FRWHOOP_EXERCISE_ENABLED value \(raw) (use 1/true/yes/on or 0/false/no/off)") }
        }
        if let raw = value("FRWHOOP_EXERCISE_MODE"), raw.lowercased() != "shadow" {
            errors.append("FRWHOOP_EXERCISE_MODE \(raw) is not supported: the exercise head runs in shadow only")
        }
        var warnings: [String] = []
        var timeout = defaultTimeoutSeconds
        if let raw = value("FRWHOOP_EXERCISE_TIMEOUT_SECONDS") {
            if let t = InertiaSettings.parseSeconds(raw) { timeout = t }
            else { errors.append("invalid FRWHOOP_EXERCISE_TIMEOUT_SECONDS \(raw)") }
        }
        var jobBudget = defaultJobBudgetSeconds
        if let raw = value("FRWHOOP_EXERCISE_JOB_BUDGET_SECONDS") {
            if let t = InertiaSettings.parseSeconds(raw) { jobBudget = t }
            else { errors.append("invalid FRWHOOP_EXERCISE_JOB_BUDGET_SECONDS \(raw)") }
        }
        let cap = Double(max(1, leaseSeconds)) / 3
        if timeout > cap {
            warnings.append("FRWHOOP_EXERCISE_TIMEOUT_SECONDS \(timeout) clamped to \(cap) (a third of the \(leaseSeconds) s lease)")
            timeout = cap
        }
        var settings = ExerciseSettings(
            enabled: asked, weightsPath: value("FRWHOOP_EXERCISE_WEIGHTS_PATH"),
            python: value("FRWHOOP_EXERCISE_PYTHON") ?? activityPython, timeoutSeconds: timeout,
            configurationError: nil, warnings: warnings, jobBudgetSeconds: jobBudget)
        if let raw = value("FRWHOOP_EXERCISE_MODEL_VERSION") {
            if ElderNetSettings.isModelVersion(raw) { settings.modelVersion = raw }
            else { errors.append("FRWHOOP_EXERCISE_MODEL_VERSION is not a plain identifier") }
        }
        if let raw = value("FRWHOOP_EXERCISE_WEIGHTS_SHA256") {
            let sha = raw.lowercased()
            if InertiaSettings.isHex64(sha) { settings.weightsSHA256 = sha }
            else { errors.append("FRWHOOP_EXERCISE_WEIGHTS_SHA256 must be 64 hex characters") }
        }
        if let raw = value("FRWHOOP_EXERCISE_THREADS") {
            if let n = Int(raw), (1...16).contains(n) { settings.threads = n }
            else { errors.append("invalid FRWHOOP_EXERCISE_THREADS \(raw) (1…16)") }
        }
        if let raw = value("FRWHOOP_EXERCISE_RETENTION_DAYS") {
            if let n = Int(raw), (1...365).contains(n) { settings.retentionDays = n }
            else { errors.append("invalid FRWHOOP_EXERCISE_RETENTION_DAYS \(raw) (1…365)") }
        }
        if asked, errors.isEmpty, settings.weightsPath == nil {
            errors.append("FRWHOOP_EXERCISE_WEIGHTS_PATH is required (the staged wrist_-_imu_only_best.pt)")
        }
        settings.configurationError = errors.first
        if settings.configurationError != nil { settings.enabled = false }
        return settings
    }

    static func serveArgs(weightsPath: String, timeoutSeconds: Double? = nil, threads: Int? = nil) -> [String] {
        var args = serveModule + ["--weights-path", weightsPath]
        if let timeoutSeconds { args += ["--timeout", InertiaSettings.formatSeconds(timeoutSeconds)] }
        if let threads { args += ["--threads", String(threads)] }
        return args
    }

    /// The service config of the exercise child. Its own process, timeout, restart cap and response cap.
    func serviceConfig(activityHome: String) -> ActivityPythonService.Config? {
        guard enabled, let weightsPath else { return nil }
        return ActivityPythonService.Config(
            pythonBin: python, activityHome: activityHome, modelDir: nil,
            serveArgs: Self.serveArgs(weightsPath: weightsPath,
                                      timeoutSeconds: InertiaSettings.serveTimeoutSeconds(workerTimeout: timeoutSeconds),
                                      threads: threads),
            requestTimeoutSeconds: timeoutSeconds,
            maxRequestBytes: 64 * 1024 * 1024,
            maxResponseLineBytes: 16 * 1024 * 1024,
            restartCap: 4,
            restartCooldownSeconds: 120,
            keepsRawLines: true,
            numericalThreads: threads)
    }
}

// MARK: - Wire

/// The `exercise-windows-1` contract the worker accepts (activity_context/recgym/runtime.py).
enum ExerciseWire {
    static let schema = "exercise-windows-1"
    static let modelId = "recgym-cnn-transformer"
    static let classes = ["Adductor", "ArmCurl", "BenchPress", "LegCurl", "LegPress", "Null", "Riding",
                          "RopeSkipping", "Running", "Squat", "StairClimber", "Walking"]
    static let nullIndex = 5
    static let windowSeconds = 4
    static let hopSeconds = 2
    /// Probabilities are rounded by the child; a row's sum may drift by a few 1e-6 per class.
    static let sumTolerance = 1e-3
}

enum ExerciseResponseError: Error, CustomStringConvertible {
    /// The child answered `ok: false` (its own kind: model_missing, weights_mismatch, timeout, malformed …).
    case service(kind: String, message: String)
    case schema(String)
    case invalidValues(String)
    case notJSON(nonfinite: Bool)

    var kind: String {
        switch self {
        case .service(let kind, _): return kind
        case .schema: return "schema"
        case .invalidValues: return "invalid_values"
        case .notJSON(let nonfinite): return nonfinite ? "nonfinite" : "malformed_json"
        }
    }

    var description: String {
        switch self {
        case .service(let kind, let message): return "\(kind): \(message)"
        case .schema(let why): return "schema: \(why)"
        case .invalidValues(let why): return "invalid_values: \(why)"
        case .notJSON(let nonfinite): return nonfinite ? "a nonfinite value in the response" : "not JSON"
        }
    }
}

/// One served window: start (even unix second), end (start + 4), the twelve class probabilities in `ExerciseWire.classes`
/// order and the sha256 of the raw seconds it covers.
struct ExerciseWindow: Equatable {
    var start: Int
    var end: Int
    var probabilities: [Double]
    var inputSHA256: String
}

/// What identifies the model that produced a response (and what the deployment pins).
struct ExerciseModelInfo: Encodable, Equatable {
    var modelId: String
    var modelVersion: String
    var weightsSHA256: String
    var scalerVersion: String
    var preprocessingVersion: String
    var classes: [String] = ExerciseWire.classes
    var windowS: Int = ExerciseWire.windowSeconds
    var hopS: Int = ExerciseWire.hopSeconds

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id", modelVersion = "model_version", weightsSHA256 = "weights_sha256"
        case scalerVersion = "scaler_version", preprocessingVersion = "preprocessing_version", classes
        case windowS = "window_s", hopS = "hop_s"
    }
}

/// One `exercise-windows-1` answer, checked strictly: the schema, the model identity, the class order, the window
/// grid and every probability. Anything else is refused (and stops the head for the job).
struct ExerciseResponse: Equatable {
    var model: ExerciseModelInfo
    var windows: [ExerciseWindow]
    var droppedNonfinite: Int

    static func decode(_ data: Data) throws -> ExerciseResponse {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            let text = String(decoding: data, as: UTF8.self)
            let nonfinite = text.range(of: #"[:\[,]\s*-?(NaN|Infinity)"#, options: .regularExpression) != nil
            throw ExerciseResponseError.notJSON(nonfinite: nonfinite)
        }
        guard let obj = parsed as? [String: Any] else { throw ExerciseResponseError.schema("not an object") }
        return try decode(obj)
    }

    static func decode(_ obj: [String: Any]) throws -> ExerciseResponse {
        if (obj["ok"] as? Bool) != true {
            throw ExerciseResponseError.service(kind: (obj["kind"] as? String) ?? "internal",
                                                message: String(((obj["error"] as? String) ?? "").prefix(200)))
        }
        func string(_ key: String) throws -> String {
            guard let s = obj[key] as? String, !s.isEmpty else { throw ExerciseResponseError.schema("missing \(key)") }
            return s
        }
        guard try string("schema") == ExerciseWire.schema else { throw ExerciseResponseError.schema("unknown schema") }
        guard try string("model_id") == ExerciseWire.modelId else { throw ExerciseResponseError.schema("unknown model_id") }
        let version = try string("model_version")
        guard ElderNetSettings.isModelVersion(version) else { throw ExerciseResponseError.schema("model_version") }
        let weights = try string("weights_sha256")
        guard InertiaSettings.isHex64(weights) else { throw ExerciseResponseError.schema("weights_sha256") }
        let scaler = try string("scaler_version"), prep = try string("preprocessing_version")
        guard (obj["classes"] as? [String]) == ExerciseWire.classes else { throw ExerciseResponseError.schema("classes") }
        guard number(obj["window_s"]) == Double(ExerciseWire.windowSeconds),
              number(obj["hop_s"]) == Double(ExerciseWire.hopSeconds)
        else { throw ExerciseResponseError.schema("window grid") }
        guard let rawWindows = obj["windows"] as? [Any] else { throw ExerciseResponseError.schema("windows") }
        var windows: [ExerciseWindow] = []
        windows.reserveCapacity(rawWindows.count)
        var previous: Int?
        for raw in rawWindows {
            guard let w = raw as? [String: Any], let sd = number(w["s"]), let ed = number(w["e"]),
                  let fp = w["input_sha256"] as? String,
                  let p = w["p"] as? [Any] else { throw ExerciseResponseError.schema("window shape") }
            // Checked before any Int conversion (which traps for non-finite or huge values).
            guard sd.isFinite, ed.isFinite, abs(sd) < ActivityPythonService.maxWindowTimeMagnitude,
                  sd == sd.rounded(), ed == sd + Double(ExerciseWire.windowSeconds) else {
                throw ExerciseResponseError.invalidValues("window \(sd)-\(ed) off the 2 s grid")
            }
            let s = Int(sd), e = Int(ed)
            guard s % 2 == 0 else { throw ExerciseResponseError.invalidValues("window \(s) off the 2 s grid") }
            guard InertiaSettings.isHex64(fp) else { throw ExerciseResponseError.invalidValues("input_sha256") }
            let probs = p.compactMap { number($0) }
            guard probs.count == ExerciseWire.classes.count, p.count == probs.count,
                  probs.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  abs(probs.reduce(0, +) - 1) <= ExerciseWire.sumTolerance else {
                throw ExerciseResponseError.invalidValues("probabilities of window \(s)")
            }
            if let previous, s <= previous { throw ExerciseResponseError.invalidValues("windows out of order") }
            previous = s
            windows.append(ExerciseWindow(start: s, end: e, probabilities: probs, inputSHA256: fp))
        }
        return ExerciseResponse(
            model: ExerciseModelInfo(modelId: ExerciseWire.modelId, modelVersion: version, weightsSHA256: weights,
                                     scalerVersion: scaler, preprocessingVersion: prep),
            windows: windows,
            droppedNonfinite: number(obj["n_dropped_nonfinite"]).flatMap { $0.isFinite && $0 >= 0 && $0 < 1e9 ? Int($0) : nil } ?? 0)
    }

    /// A JSON number as Double: what JSONSerialization hands back (bridged on Darwin, Int or Double on Linux) or a
    /// literal built in Swift. Everything else (strings, objects) is nil.
    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}

// MARK: - Stage

/// The windows gathered for one job, chunk by chunk, with the span (and answer key) of every chunk that answered.
struct ExerciseCollector {
    struct Chunk: Equatable {
        var start: Int
        var end: Int
        /// The answer key (nil when the child reported no identity: such a chunk is always published).
        var key: String?
        var response: ExerciseResponse
    }
    var answered: [Chunk] = []
    var chunks = 0
    var failedChunks = 0
    /// Chunks whose windows this process already published (committed) under the same key: not sent again.
    var alreadyPublished = 0
    var failureKinds: [String: Int] = [:]
    /// Set when the head was skipped or stopped for the rest of the job (the kind that stopped it).
    var stopped: String?
}

/// A bounded, thread-safe LRU of keyed values for this process's lifetime (answers, published chunk keys).
final class ExerciseLRU<Value>: @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var entries: [String: Value] = [:]
    private var order: [String] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func value(_ key: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    func store(_ value: Value, key: String) {
        lock.lock(); defer { lock.unlock() }
        if entries.updateValue(value, forKey: key) == nil { order.append(key) }
        if order.count > capacity {
            let drop = order.count - capacity
            for k in order.prefix(drop) { entries[k] = nil }
            order.removeFirst(drop)
        }
    }
}

/// The exercise service and what to do with it. Stateless apart from the service and its two caches (classes); the
/// lane keeps the counters.
struct ExerciseStage {
    let service: ActivityPythonService
    var expectedModelVersion: String? = nil
    var expectedWeightsSHA256: String? = nil
    var jobBudgetSeconds: Double = ExerciseSettings.defaultJobBudgetSeconds
    var retentionDays: Int = ExerciseSettings.defaultRetentionDays
    /// Answers this process already has, by request and measured identity.
    var responses = ExerciseLRU<ExerciseResponse>(capacity: 2048)
    /// `<device>|<answer key>` of chunks whose windows a committed publish carried.
    var published = ExerciseLRU<Bool>(capacity: 20_000)

    static let pinMismatchKind = "pin_mismatch"
    static let route = "recgym"

    /// The key of `request`'s answer under what the running child measured it loaded, or nil when it reported none.
    func cacheKey(_ request: ActivityPythonService.RunRequest) -> String? {
        guard let identity = service.cacheIdentity else { return nil }
        return ActivityLocalCache.inferenceKey(request: request, identity: identity, versions: ["route": Self.route])
    }

    static func publishedKey(device: String, key: String) -> String { "\(device)|\(key)" }

    enum Outcome: Equatable {
        case ok(ExerciseResponse)
        /// `stop` = do not ask again during this job.
        case failed(kind: String, message: String, stop: Bool)
    }

    /// nil when `version` / `digest` are what the deployment pinned, else why not.
    func pinRefusal(version: String?, digest: String?) -> String? {
        if let expected = expectedModelVersion, version != expected {
            return "served model_version \(version ?? "unknown"), pinned \(expected)"
        }
        if let expected = expectedWeightsSHA256, digest != expected {
            return "served checkpoint sha256 \(digest ?? "unknown"), pinned \(expected)"
        }
        return nil
    }

    /// Readiness at the start of a job: start the child if needed and ping it unless it is known to be up. nil =
    /// ready, otherwise the kind that keeps the head off for this job. Never throws. Pins are checked against what
    /// the child measured it loaded (`loaded.weights_sha256`), never against its pinned constant.
    func begin() -> (kind: String, message: String)? {
        do {
            try service.ensureStarted()
            var available = service.modelAvailable
            var ping: ActivityPythonService.PingStatus?
            if !available {
                ping = try service.ping()
                available = ping?.modelAvailable ?? false
            }
            guard available else {
                let status = ping?.modelStatus ?? "unknown"
                return ("model_unavailable", "\(status): \(ping?.error ?? "")")
            }
            if expectedModelVersion != nil || expectedWeightsSHA256 != nil {
                let version = service.lastPingDetails["model_version"]
                let digest = service.loadedIdentity["weights_sha256"]
                if let why = pinRefusal(version: version, digest: digest) { return (Self.pinMismatchKind, why) }
            }
            return nil
        } catch {
            return InertiaStage.classify(error)
        }
    }

    /// Infer one chunk. Never throws: every failure comes back classified.
    func infer(_ request: ActivityPythonService.RunRequest) -> Outcome {
        do {
            let (object, line) = try service.inferRaw(run: request)
            let response: ExerciseResponse
            if let line { response = try ExerciseResponse.decode(line) }
            else { response = try ExerciseResponse.decode(object) }
            if let why = pinRefusal(version: response.model.modelVersion, digest: response.model.weightsSHA256) {
                return .failed(kind: Self.pinMismatchKind, message: why, stop: true)
            }
            return .ok(response)
        } catch let e as ExerciseResponseError {
            return .failed(kind: e.kind, message: String(String(describing: e).prefix(240)),
                           stop: Self.stoppingServiceKinds.contains(e.kind))
        } catch {
            let c = InertiaStage.classify(error)
            if case ActivityPythonService.ServiceError.malformedResponse(let detail) = error,
               detail == "unparseable response line" {
                return .failed(kind: c.kind, message: c.message, stop: false)
            }
            return .failed(kind: c.kind, message: c.message, stop: true)
        }
    }

    /// Failure kinds that will not clear within a job (ask no more chunks): the service's own load and request kinds,
    /// a pin refusal and the decoder's refusals that would repeat on every chunk. Not `nonfinite` / `malformed_json`
    /// (a NaN line costs one chunk) nor `internal`.
    static let stoppingServiceKinds: Set<String> = ["model_missing", "weights_mismatch", "timeout", pinMismatchKind,
                                                    "malformed", "output_too_large", "schema", "invalid_values"]
}

// MARK: - Publication

/// The job's exercise windows for `activity_exercise_windows` (20261009160000).
enum ActivityExerciseWindows {
    static let pruneBatchRows = 50_000
    static let pruneSQL = "SELECT public.prune_activity_exercise_windows($1::integer, $2::integer)::text"
    static let publishSQL = "SELECT public.publish_activity_exercise_windows($1::uuid,$2::bigint,$3::jsonb)::text"

    enum PublishOutcome: Equatable {
        case stored(revision: Int64)
        case fenced
        case rejected(String)
    }

    struct WireWindow: Encodable {
        var s: Int
        var fp: String
        var p: [Double]
    }

    struct Payload: Encodable {
        var day: String
        var schema = ExerciseWire.schema
        var model: ExerciseModelInfo
        var authority: ActivityExpertAuthority
        var spans: [[Int]]
        var windows: [WireWindow]
    }

    struct Built {
        var text: String
        /// `<device>|<key>` of the chunks the payload replaces as a whole (mark them published after the commit).
        var publishedKeys: [String]
        var windows: Int
        var chunks: Int
    }

    /// The payload for the chunks this process has not published yet, clipped to the job's UTC day, or nil when
    /// there is nothing new (every answered chunk already published, or none answered). Chunks answered by another
    /// model than the first are left out (the head was stopped on `model_changed` anyway).
    static func payload(day: String, dayBounds: (start: Int, end: Int), device: String, inputRevision: Int64,
                        collector: ExerciseCollector, stage: ExerciseStage) throws -> Built? {
        guard let model = collector.answered.first?.response.model else { return nil }
        var spans: [[Int]] = []
        var windows: [WireWindow] = []
        var keys: [String] = []
        var seen = Set<Int>()
        for chunk in collector.answered where chunk.response.model == model {
            if let key = chunk.key, stage.published.value(ExerciseStage.publishedKey(device: device, key: key)) == true {
                continue
            }
            let a = max(chunk.start, dayBounds.start), b = min(chunk.end, dayBounds.end)
            guard a < b else { continue }
            spans.append([a, b])
            if let key = chunk.key { keys.append(ExerciseStage.publishedKey(device: device, key: key)) }
            for w in chunk.response.windows where w.start >= a && w.end <= b && seen.insert(w.start).inserted {
                windows.append(WireWindow(s: w.start, fp: w.inputSHA256, p: w.probabilities))
            }
        }
        guard !spans.isEmpty else { return nil }
        windows.sort { $0.s < $1.s }
        let authority = ActivityExpertAuthority.shadowOnly(channel: .exerciseRecognition, inputRevision: inputRevision,
                                                           pinnedModelVersion: stage.expectedModelVersion,
                                                           pinnedWeightsDigest: stage.expectedWeightsSHA256)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(day: day, model: model, authority: authority, spans: spans,
                                              windows: windows))
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkerError.malformed("exercise windows payload encoding failed")
        }
        return Built(text: text, publishedKeys: keys, windows: windows.count, chunks: spans.count)
    }

    /// Write through the fenced RPC. Runs under a savepoint when a transaction is open, so a rejection (or a database
    /// without the migration) leaves the transaction usable for the publishes around it. Only a lost connection
    /// propagates.
    static func publish(db: PostgresClient, token: String, revision: Int64, payload: String) throws -> PublishOutcome {
        do {
            let out = try db.isolatingFailures {
                try db.callFunctionForJSONRaw(publishSQL, [token, String(revision), payload])
            }
            if let stored = Int64(out ?? ""), stored > 0 { return .stored(revision: stored) }
            return .fenced
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            throw e
        } catch {
            return .rejected(ActivityContextDays.safeReason(error))
        }
    }

    /// Retention: delete windows that started more than `keepDays` ago (at most `maxRows` per call). Outside any
    /// transaction; the caller counts and logs a failure and carries on.
    static func prune(db: PostgresClient, keepDays: Int, maxRows: Int = pruneBatchRows) throws -> Int {
        let out = try db.callFunctionForJSONRaw(pruneSQL, [String(keepDays), String(maxRows)])
        return Int(out ?? "") ?? 0
    }
}
