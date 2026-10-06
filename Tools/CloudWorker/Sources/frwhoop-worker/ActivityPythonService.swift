import Foundation

/// Persistent Python companion for activity inference (spec §5, C10 serve
/// protocol).
///
/// One long-lived subprocess speaks line-delimited JSON over stdin/stdout:
///   request:  {"id":"<uuid>","op":"infer","run":{...},"head_b64":[...],"tail_b64":[...]}
///             {"id":"<uuid>","op":"ping"}   {"id":"<uuid>","op":"shutdown"}
///   response: {"id":"<uuid>","ok":true,"model_version":"...",
///              "preprocessing_version":"...","windows":[...]}
///             {"id":"<uuid>","ok":false,"error":"...","kind":"model_missing|timeout|malformed|..."}
///
/// The process is started once and reused. A crash, a dead pipe or a malformed
/// response restarts it (bounded by `restartCap`, cooled down by
/// `restartCooldownSeconds`). A per-request timeout (default 60 s) kills and
/// restarts the process, because a stuck child must never hold the lane. Model
/// loading happens in the child at startup; the lane pings at start and treats
/// `model_missing` as a soft lane failure (no claim work, heartbeat records the
/// reason).
///
/// Thread-safety: every entry point takes the same lock, and the stdout reader
/// runs on its own thread so a blocked request can never stop the process from
/// being observed as dead.
final class ActivityPythonService {
    struct Config {
        var pythonBin: String
        var activityHome: String
        var modelDir: String?
        /// Arguments used to launch the serve module. Defaults to
        /// `-m activity_context.serve`; tests substitute a stub script path.
        var serveArgs: [String]
        var requestTimeoutSeconds: Double
        var maxRequestBytes: Int
        var maxResponseLineBytes: Int
        var restartCap: Int
        var restartCooldownSeconds: Double
        /// Extra environment for the child (the Inertia service passes `INERTIA1_CKPT_PATH` this way).
        var extraEnvironment: [String: String] = [:]
        /// Keep each response's raw line next to its parsed object (`inferRaw`), and fail a request whose
        /// response line carries its id but is not JSON (a NaN token, say) at once instead of waiting for the
        /// timeout. Off for the HART service, whose behaviour is unchanged.
        var keepsRawLines = false

        /// FRWHOOP_ACTIVITY_PYTHON (default python3), FRWHOOP_ACTIVITY_HOME
        /// (default <cwd>/Tools/ActivityContext), FRWHOOP_ACTIVITY_MODEL_DIR,
        /// FRWHOOP_ACTIVITY_TIMEOUT_SECONDS (default 60),
        /// FRWHOOP_ACTIVITY_RESTART_CAP (default 8).
        static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Config {
            let home = env["FRWHOOP_ACTIVITY_HOME"]
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.currentDirectoryPath + "/Tools/ActivityContext"
            let modelDir = env["FRWHOOP_ACTIVITY_MODEL_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            return Config(
                pythonBin: env["FRWHOOP_ACTIVITY_PYTHON"] ?? "python3",
                activityHome: home,
                modelDir: modelDir,
                serveArgs: serveArgs(modelDir: modelDir),
                requestTimeoutSeconds: Double(env["FRWHOOP_ACTIVITY_TIMEOUT_SECONDS"] ?? "60") ?? 60,
                maxRequestBytes: 64 * 1024 * 1024,
                maxResponseLineBytes: 16 * 1024 * 1024,
                restartCap: Int(env["FRWHOOP_ACTIVITY_RESTART_CAP"] ?? "8") ?? 8,
                restartCooldownSeconds: 30)
        }

        /// Build the `serve` module arguments for the persistent child.
        /// serve.py reads `--manifest`/`--checkpoint` from argv ONLY (never
        /// the environment), so a model dir that is merely placed in the
        /// child's env boots the BASELINE manifest while the lane would stamp
        /// 'hart-activity-1' — the HART model is then unreachable and the
        /// provenance is wrong (audit P1-3). With a model dir the manifest +
        /// checkpoint are passed explicitly; without one the child loads the
        /// baseline manifest and the lane falls back to the versions serve
        /// reports for baseline.
        static func serveArgs(module: [String] = ["-m", "activity_context.serve"],
                              modelDir: String?) -> [String] {
            guard let modelDir, !modelDir.isEmpty else { return module }
            let manifest = URL(fileURLWithPath: modelDir)
                .appendingPathComponent("manifest.json").path
            return module + ["--manifest", manifest, "--checkpoint", modelDir]
        }
    }

    enum ServiceError: Error, CustomStringConvertible {
        case launchFailed(String)
        case restartCapExceeded
        case restartCooldown
        case requestTooLarge(Int)
        case responseTooLarge
        case timeout(String)
        case processDied
        case malformedResponse(String)
        case inferFailed(kind: String, message: String)
        case modelUnavailable(String)

        var description: String {
            switch self {
            case .launchFailed(let detail): return "activity python launch failed: \(detail)"
            case .restartCapExceeded: return "activity python restart cap exceeded"
            case .restartCooldown: return "activity python restart cooling down"
            case .requestTooLarge(let n): return "activity python request \(n) bytes exceeds cap"
            case .responseTooLarge: return "activity python response line exceeds cap"
            case .timeout(let op): return "activity python \(op) timed out"
            case .processDied: return "activity python process died"
            case .malformedResponse(let detail): return "activity python malformed response: \(detail)"
            case .inferFailed(let kind, let message): return "activity infer failed (\(kind)): \(message)"
            case .modelUnavailable(let detail): return "activity model unavailable: \(detail)"
            }
        }
    }

    struct PingStatus {
        var ok: Bool
        var modelAvailable: Bool
        var modelStatus: String
        var modelVersion: String?
        var preprocessingVersion: String?
        var error: String?
        /// Other string fields of the ping (the Inertia service reports encoder_id, encoder_kind,
        /// heads_version, bundle_sha256, evidence_tier_max …), for logs and the heartbeat.
        var details: [String: String] = [:]
        /// Object fields of the ping whose values are all strings (the ElderNet service reports its
        /// `weights` {head: sha256} map this way).
        var objects: [String: [String: String]] = [:]
    }

    struct WindowPrediction {
        var start: Double
        var end: Double
        var label: String
        var probs: [String: Double]
        var baseline: Bool
        /// Encoder-independent IMU facts for the window (`imu-feat-1`: accel_rms_g, gyro_rms_dps,
        /// jerk_rms, cadence_hz, cadence_strength, orientation_change_deg). A key is absent when the
        /// service sent null for it or did not send `feat` at all (an older serve.py).
        var features: [String: Double] = [:]
    }

    struct InferResult {
        var ok: Bool
        var modelVersion: String?
        var preprocessingVersion: String?
        var windows: [WindowPrediction]
        var error: String?
        var errorKind: String?
        /// `feature_schema` the service stamped on the window features (nil from an older serve.py).
        var featureSchema: String? = nil
    }

    /// One run request per C10 serve protocol. `columnsB64` is one base64
    /// string per second (1200 bytes of 600 i16 LE axis-major), index i = second
    /// `startTs + i`. `headB64`/`tailB64` are up to three extra seconds before
    /// start / after end for resample filter state.
    struct RunRequest {
        var startTs: Int
        var endTs: Int
        var columnsB64: [String]
        var headB64: [String]
        var tailB64: [String]
        /// Extra top-level request fields, merged verbatim. Used by tests to
        /// drive stub behavior (e.g. `sleep_seconds`, `die`); the real
        /// serve.py ignores unknown keys.
        var extra: [String: Any]? = nil
    }

    let config: Config
    /// NSCondition doubles as the state lock and the response-wait primitive:
    /// `wait(until:)` atomically releases it while sleeping, so the stdout
    /// reader can deliver responses while a request waits.
    private let lock = NSCondition()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutPipe: Pipe?
    private var readerThread: Thread?
    private var eofDetected = false
    private var readBuffer = Data()
    private var stderrTail = Data()
    private var responses: [String: [String: Any]] = [:]
    /// Raw response lines by request id (only with `keepsRawLines`).
    private var rawLines: [String: Data] = [:]
    /// Ids of requests waiting for a response (only tracked with `keepsRawLines`).
    private var pendingIds: Set<String> = []
    private var failures: [String: String] = [:]
    private var restartCount = 0
    private var lastRestartAt: Date?
    private(set) var lastPingStatus: PingStatus?
    /// Model/preprocessing versions reported by the child (from the last ping
    /// or infer response); used to stamp the C10 document when the policy seam
    /// builds it.
    private(set) var reportedModelVersion: String?
    private(set) var reportedPreprocessingVersion: String?
    /// Last `echo` object from an infer response (stub diagnostic mirror of
    /// the request shape), used by tests to pin the wire contract.
    private(set) var lastEcho: [String: Any]?
    private var sequence = 0

    /// A child that has exited leaves a pipe nobody reads. The next request line written to it has to come
    /// back as an error (`processDied`, then a respawn), not as SIGPIPE, whose default action ends the whole
    /// worker and every other lane with it. Process-wide; set once before the first child is started.
    private static let ignoreBrokenPipes: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

    init(config: Config) {
        self.config = config
    }

    deinit {
        forceKill()
    }

    // MARK: - Observability

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process != nil && !eofDetected
    }

    /// True when the child reported a loaded model on its last ping.
    var modelAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        guard process != nil, !eofDetected, let ping = lastPingStatus else { return false }
        return ping.ok && ping.modelAvailable
    }

    /// The string fields of the last ping (the Inertia service reports its `bundle_sha256` there).
    var lastPingDetails: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return lastPingStatus?.details ?? [:]
    }

    /// The all-string object fields of the last ping (the ElderNet service reports its `weights` there).
    var lastPingObjects: [String: [String: String]] {
        lock.lock(); defer { lock.unlock() }
        return lastPingStatus?.objects ?? [:]
    }

    var restartCountValue: Int {
        lock.lock(); defer { lock.unlock() }
        return restartCount
    }

    var lastErrorDescription: String? {
        lock.lock(); defer { lock.unlock() }
        return lastPingStatus?.error
    }

    // MARK: - Lifecycle

    /// Spawn (or respawn) the child if it is not running. Bounded by the
    /// restart cap; after the cap, a cooldown must pass before another attempt.
    func ensureStarted() throws {
        lock.lock()
        if process != nil && !eofDetected { lock.unlock(); return }
        if restartCount >= config.restartCap {
            if let last = lastRestartAt, Date().timeIntervalSince(last) < config.restartCooldownSeconds {
                lock.unlock()
                throw ServiceError.restartCooldown
            }
            restartCount = 0  // cooldown elapsed: allow a fresh attempt
        }
        lock.unlock()
        try start()
    }

    private func start() throws {
        lock.lock()
        defer { lock.unlock() }

        let home = URL(fileURLWithPath: config.activityHome)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.path, isDirectory: &isDir), isDir.boolValue else {
            throw ServiceError.launchFailed("FRWHOOP_ACTIVITY_HOME \(config.activityHome) does not exist")
        }

        _ = Self.ignoreBrokenPipes
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.pythonBin)
        proc.arguments = config.serveArgs
        proc.currentDirectoryURL = home
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["FRWHOOP_ACTIVITY_HOME"] = home.path
        if let modelDir = config.modelDir { env["FRWHOOP_ACTIVITY_MODEL_DIR"] = modelDir }
        for (k, v) in config.extraEnvironment { env[k] = v }
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw ServiceError.launchFailed("process run failed: \(error)")
        }

        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe
        self.eofDetected = false
        self.readBuffer = Data()
        self.responses = [:]
        self.rawLines = [:]
        self.failures = [:]
        self.restartCount += 1
        self.lastRestartAt = Date()
        self.lastPingStatus = nil

        let reader = Thread { [weak self] in self?.drainStdout(stdoutPipe.fileHandleForReading) }
        reader.name = "frwhoop.activity.python.stdout"
        reader.start()
        readerThread = reader
        drainStderrInBackground(stderrPipe.fileHandleForReading)
    }

    /// Continuously read the child's stdout, splitting line-delimited JSON and
    /// dispatching by request id. A dead pipe sets `eofDetected`, which makes
    /// the service look stopped so the next call restarts it.
    private func drainStdout(_ handle: FileHandle) {
        while true {
            // `availableData` returns as soon as at least one byte is present;
            // `readData(ofLength:)` would block until the FULL length arrived
            // (a response line is far smaller than the chunk size, so it would
            // only be delivered at EOF).
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF
            lock.lock()
            readBuffer.append(chunk)
            processLinesLocked()
            lock.unlock()
            lock.broadcast()
        }
        lock.lock()
        eofDetected = true
        process = nil
        lock.unlock()
        lock.broadcast()
    }

    /// Parse every complete line currently in `readBuffer`; oversized lines are
    /// recorded as failures and the rest of the line is dropped.
    private func processLinesLocked() {
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<newline]
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard lineData.count <= config.maxResponseLineBytes else {
                // Oversized junk: fail any pending request, do not buffer it.
                failures["*"] = "response line exceeds \(config.maxResponseLineBytes) bytes"
                continue
            }
            guard let line = String(data: lineData, encoding: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let id = obj["id"] as? String, !id.isEmpty else {
                // Non-JSON diagnostics are common on startup; they are not a
                // response. Treat a stray line with no id as harmless unless
                // nothing is pending.
                if config.keepsRawLines, !pendingIds.isEmpty {
                    // A line that names a pending request but does not parse (a NaN token) is that request's
                    // answer: fail it now rather than at the timeout.
                    let text = String(decoding: lineData, as: UTF8.self)
                    for pending in pendingIds where text.contains("\"\(pending)\"") {
                        failures[pending] = "unparseable response line"
                    }
                }
                continue
            }
            responses[id] = obj
            if config.keepsRawLines { rawLines[id] = Data(lineData) }
        }
    }

    /// Drain stderr into a bounded tail so the pipe never fills and the last
    /// diagnostic text is available for reporting.
    private func drainStderrInBackground(_ handle: FileHandle) {
        let thread = Thread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                self.lock.lock()
                self.stderrTail.append(chunk)
                if self.stderrTail.count > 64 * 1024 {
                    self.stderrTail.removeFirst(self.stderrTail.count - 64 * 1024)
                }
                self.lock.unlock()
            }
        }
        thread.name = "frwhoop.activity.python.stderr"
        thread.start()
    }

    // MARK: - Requests

    /// One serialized request/response exchange. Kills and restarts the child
    /// on timeout or a dead pipe.
    func ping() throws -> PingStatus {
        let obj = try roundTrip(["op": "ping"])
        lock.lock()
        let status = Self.parsePing(obj)
        lastPingStatus = status
        // A successful exchange proves the child is healthy: the restart cap
        // counts consecutive respawns since the last healthy ping.
        if status.ok { restartCount = 0 }
        if status.modelVersion != nil { reportedModelVersion = status.modelVersion }
        if status.preprocessingVersion != nil { reportedPreprocessingVersion = status.preprocessingVersion }
        lock.unlock()
        return status
    }

    func infer(run: RunRequest) throws -> InferResult {
        let obj = try roundTrip(Self.inferRequest(run))
        lock.lock()
        defer { lock.unlock() }
        let result = Self.parseInfer(obj)
        if let echo = obj["echo"] as? [String: Any] { lastEcho = echo }
        if result.ok {
            if let mv = result.modelVersion, !mv.isEmpty { reportedModelVersion = mv }
            if let pv = result.preprocessingVersion, !pv.isEmpty { reportedPreprocessingVersion = pv }
            if lastPingStatus == nil || !lastPingStatus!.modelAvailable {
                lastPingStatus = PingStatus(ok: true, modelAvailable: true,
                                            modelStatus: "loaded",
                                            modelVersion: result.modelVersion,
                                            preprocessingVersion: result.preprocessingVersion,
                                            error: nil)
            }
        }
        if !result.ok {
            // Remember model state so the lane can fail soft without another ping.
            if result.errorKind == "model_missing" {
                lastPingStatus = PingStatus(ok: false, modelAvailable: false,
                                            modelStatus: "model_missing", modelVersion: nil,
                                            preprocessingVersion: nil, error: result.error)
            }
        }
        return result
    }

    /// The same infer request as `infer`, answered by a service whose response is not a HART document (the
    /// Inertia motion-heads service): the parsed object and, with `keepsRawLines`, the exact response line
    /// for a strict decoder. Nothing about the response is interpreted here.
    func inferRaw(run: RunRequest) throws -> (object: [String: Any], line: Data?) {
        let request = Self.inferRequest(run)
        let obj = try roundTrip(request)
        lock.lock()
        defer { lock.unlock() }
        if (obj["ok"] as? Bool) == false, (obj["kind"] as? String) == "model_missing", var ping = lastPingStatus {
            ping.modelAvailable = false
            ping.modelStatus = "model_missing"
            lastPingStatus = ping
        }
        return (obj, lastRawLine)
    }

    private var lastRawLine: Data?

    static func inferRequest(_ run: RunRequest) -> [String: Any] {
        // head_b64/tail_b64 are sent in BOTH the top-level C10 shape AND
        // inside `run`: serve.py reads them from `run` (its original and
        // current placement — CONTRACTS put them top-level, and the deployed
        // child reads the run-internal copy), so a worker that only sends the
        // top-level copy would silently lose all boundary filter state (the
        // child would crop ~1 s at every chunk edge and never apply overlap).
        // Sending both makes the worker correct against either serve.py
        // variant; the duplicate payload is at most 6 base64 seconds.
        var request: [String: Any] = [
            "op": "infer",
            "run": [
                "start_ts": run.startTs,
                "end_ts": run.endTs,
                "sample_rate_hz": 100,
                "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"],
                "units": ["accel": "g", "gyro": "deg/s"],
                "columns_b64": run.columnsB64,
                "head_b64": run.headB64,
                "tail_b64": run.tailB64,
            ],
            "head_b64": run.headB64,
            "tail_b64": run.tailB64,
        ]
        if let extra = run.extra {
            for (k, v) in extra { request[k] = v }
        }
        return request
    }

    /// Ask the child to exit and reap it. Best effort: the child may ignore
    /// the shutdown line, so a short grace period precedes SIGTERM.
    func shutdown() {
        lock.lock()
        let proc = process
        let stdin = stdinHandle
        lock.unlock()
        if let stdin, let proc {
            let line = requestLine(["op": "shutdown"]) ?? "{\"op\":\"shutdown\"}\n"
            try? stdin.write(contentsOf: Data(line.utf8))
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        forceKill()
    }

    private func forceKill() {
        lock.lock()
        let proc = process
        process = nil
        eofDetected = true
        lock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning { proc.interrupt() }
        }
        lock.broadcast()
    }

    // MARK: - Wire helpers

    private func roundTrip(_ payload: [String: Any]) throws -> [String: Any] {
        try ensureStarted()
        let id = UUID().uuidString.lowercased()
        var request = payload
        request["id"] = id
        guard let line = requestLine(request) else {
            throw ServiceError.malformedResponse("request serialization failed")
        }
        let lineBytes = line.utf8.count
        guard lineBytes <= config.maxRequestBytes else {
            throw ServiceError.requestTooLarge(lineBytes)
        }
        let deadline = Date().addingTimeInterval(config.requestTimeoutSeconds)
        let opName = payload["op"] as? String ?? "request"
        if config.keepsRawLines {
            lock.lock()
            pendingIds.insert(id)
            lastRawLine = nil
            lock.unlock()
        }
        defer {
            if config.keepsRawLines {
                lock.lock()
                pendingIds.remove(id)
                rawLines.removeValue(forKey: id)
                lock.unlock()
            }
        }

        // Write the request line.
        do {
            if let stdin = stdinHandle {
                try stdin.write(contentsOf: Data(line.utf8))
            } else {
                throw ServiceError.processDied
            }
        } catch {
            markDead()
            throw ServiceError.processDied
        }

        // Wait for the matching id (or a fatal failure) until the deadline.
        // The condition is held across the check + wait: wait() atomically
        // releases it while sleeping and reacquires it when woken, so a
        // woken reader can deliver the response.
        lock.lock()
        while true {
            if let response = responses.removeValue(forKey: id) {
                if config.keepsRawLines { lastRawLine = rawLines.removeValue(forKey: id) }
                lock.unlock()
                return response
            }
            if config.keepsRawLines, let why = failures.removeValue(forKey: id) {
                lock.unlock()
                throw ServiceError.malformedResponse(why)
            }
            if let fatal = failures.removeValue(forKey: "*") {
                lock.unlock()
                restartProcess()
                throw ServiceError.malformedResponse(fatal)
            }
            if eofDetected || process == nil {
                lock.unlock()
                throw ServiceError.processDied
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                lock.unlock()
                restartProcess()
                throw ServiceError.timeout(opName)
            }
            lock.wait(until: Date().addingTimeInterval(min(0.25, remaining)))
        }
    }

    /// Build the single JSON request line for a payload.
    private func requestLine(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text + "\n"
    }

    private func markDead() {
        lock.lock()
        eofDetected = true
        process = nil
        lock.unlock()
        lock.broadcast()
    }

    /// Kill the current child so the next `ensureStarted` respawns it. Used for
    /// timeouts and oversized responses, where the child state is suspect.
    private func restartProcess() {
        lock.lock()
        let proc = process
        process = nil
        eofDetected = true
        lock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning { proc.interrupt() }
        }
        lock.broadcast()
    }

    // MARK: - Parsing

    /// Ping statuses that mean "no model to infer with", even when the ping itself succeeded. serve.py answers
    /// ping `ok:true` with `hart_unavailable` when a HART manifest is present but the model failed to load (torch
    /// missing, bad checkpoint digest), and the Inertia service answers `inertia_unavailable`; every infer would
    /// then return `model_missing`, so the lane must back off before claiming instead of failing (and eventually
    /// dead-lettering) every job.
    ///
    /// (Ping-parse bug: only `model_missing` / `missing` used to count as unavailable, so the lane believed the
    /// model was up, claimed jobs and failed every one of them.) An explicit `model_available: false` also
    /// counts as unavailable, and neither signal can override the other into "available".
    static let unavailableModelStatuses: Set<String> = ["model_missing", "missing", "hart_unavailable",
                                                        "inertia_unavailable", "eldernet_unavailable"]

    static func parsePing(_ obj: [String: Any]) -> PingStatus {
        let ok = (obj["ok"] as? Bool) ?? false
        var modelAvailable = ok
        var modelStatus = "unknown"
        if let raw = obj["model_status"] as? String {
            modelStatus = raw
            if unavailableModelStatuses.contains(raw) { modelAvailable = false }
        }
        if let raw = obj["model_available"] as? Bool, !raw {
            modelAvailable = false
        }
        var details: [String: String] = [:]
        var objects: [String: [String: String]] = [:]
        for (k, v) in obj {
            if let s = v as? String, k != "id", k != "op" { details[k] = s }
            if let d = v as? [String: Any] {
                var strings: [String: String] = [:]
                for (key, value) in d { if let s = value as? String { strings[key] = s } }
                if strings.count == d.count { objects[k] = strings }
            }
        }
        return PingStatus(
            ok: ok,
            modelAvailable: modelAvailable,
            modelStatus: modelStatus,
            modelVersion: obj["model_version"] as? String,
            preprocessingVersion: obj["preprocessing_version"] as? String,
            error: (obj["error"] as? String) ?? (obj["model_error"] as? String),
            details: details, objects: objects)
    }

    /// Window times outside this magnitude are dropped: the lane converts them with `Int(_:)`, which traps for
    /// values at or beyond 2^63 (and for non-finite ones), and no real unix second comes near it.
    static let maxWindowTimeMagnitude = 9e15

    static func parseInfer(_ obj: [String: Any]) -> InferResult {
        let ok = (obj["ok"] as? Bool) ?? false
        var windows: [WindowPrediction] = []
        if let raw = obj["windows"] as? [[String: Any]] {
            for w in raw {
                guard let s = w["s"] as? Double, let e = w["e"] as? Double,
                      s.isFinite, e.isFinite, abs(s) < maxWindowTimeMagnitude, abs(e) < maxWindowTimeMagnitude,
                      let label = w["label"] as? String else { continue }
                var probs: [String: Double] = [:]
                if let rawProbs = w["probs"] as? [String: Any] {
                    for (k, v) in rawProbs {
                        if let d = v as? Double { probs[k] = d }
                    }
                }
                // JSON null (a feature the window could not compute) is NSNull, which does not bridge to
                // Double, so it simply stays absent.
                var features: [String: Double] = [:]
                if let rawFeat = w["feat"] as? [String: Any] {
                    for (k, v) in rawFeat {
                        if let d = v as? Double, d.isFinite { features[k] = d }
                    }
                }
                windows.append(WindowPrediction(start: s, end: e, label: label,
                                                probs: probs, baseline: (w["baseline"] as? Bool) ?? false,
                                                features: features))
            }
        }
        return InferResult(
            ok: ok,
            modelVersion: obj["model_version"] as? String,
            preprocessingVersion: obj["preprocessing_version"] as? String,
            windows: windows,
            error: obj["error"] as? String,
            errorKind: obj["kind"] as? String,
            featureSchema: obj["feature_schema"] as? String)
    }
}
