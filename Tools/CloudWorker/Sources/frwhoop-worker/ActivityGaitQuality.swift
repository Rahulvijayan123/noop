import Foundation
import StrandAnalytics

// ActivityGaitQuality.swift — ElderNet gait quality on the server, SHADOW FIRST (Tools/ActivityContext/ELDERNET.md
// §6).
//
// A third, separate Python process (`python -m activity_context.eldernet.serve --weights-dir <dir> --upstream-dir
// <dir>`, its own timeout, restart cap and response cap) is asked for `gait-quality-1` windows for the same IMU chunks the HART
// service just inferred. It is never part of the lane's readiness gate and nothing it does can fail a job:
//
//   • every ElderNet failure (model missing, a weights or pin mismatch, timeout, crash, malformed or invalid output,
//     NaN) is classified, counted and logged once per distinct reason, and the HART path continues untouched;
//   • a transport failure (timeout, crash, launch failure, restart cooldown), `model_missing`, `weights_mismatch`, a
//     pin refusal or a failure that would repeat on every chunk (an unknown schema, a malformed response, invalid
//     values, an output too large) stops ElderNet for the rest of that job, so a broken model costs at most one
//     timeout per job; only a NaN line costs a single chunk. ElderNet also has a per-job time budget
//     (FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS): once its calls in a job have used it, it is stopped for that job;
//   • the shadow output (provenance + compact per-window gait outputs + counts) is written to its OWN table
//     (`activity_gait_windows_days`) through its own fenced RPC under a savepoint, so a rejection or a missing
//     migration never reaches the v1 / v2 publishes in the same transaction;
//   • candidate mode additionally decodes the day a second time with the ElderNet channel as decoder evidence —
//     only for the pinned model version and weights digest and with the configured gait prior, otherwise the
//     withheld reason is stored — and keeps that comparison document beside the shadow row. In shadow and candidate
//     mode nothing is written to `activity_context_days` / `activity_context_epochs`: the published HART documents
//     are byte-identical whether ElderNet is enabled or not;
//   • production mode has candidate mode's requirements, but its windows shape the published v2 day document
//     through the shared release policy (`ActivityExpertSelection.canonical`), and its row carries no comparison
//     document and no withheld reason. The v1 epochs stay HART's alone.

/// FRWHOOP_ELDERNET_* settings. Off unless `FRWHOOP_ELDERNET_ENABLED` is on and both the weights directory and the
/// upstream source directory are configured.
struct ElderNetSettings: Equatable {
    enum Mode: String, Equatable {
        case shadow, candidate, production

        /// The release the shared policy is asked for.
        var release: ActivityReleaseMode {
            switch self {
            case .shadow: return .shadow
            case .candidate: return .candidate
            case .production: return .production
            }
        }
    }

    var enabled: Bool
    var mode: Mode
    var weightsDir: String?
    /// The sha-verified upstream ElderNet source checkout (FRWHOOP_ELDERNET_UPSTREAM_DIR, passed as
    /// `--upstream-dir`; fetched by an operator with `python -m activity_context.eldernet.upstream fetch --dest DIR`).
    /// The serve process imports upstream's own modules from it; without it the child reports `model_missing`.
    var upstreamDir: String? = nil
    var python: String
    /// Worker-side per-request timeout, already clamped to at most a third of the job lease.
    var timeoutSeconds: Double
    /// The `model_version` the deployment pins (FRWHOOP_ELDERNET_MODEL_VERSION).
    var modelVersion: String? = nil
    /// The weights digest the deployment pins (FRWHOOP_ELDERNET_WEIGHTS_SHA256; `GaitQualityModelInfo.weightsDigest`).
    var weightsSHA256: String? = nil
    /// π for the candidate and production decodes (FRWHOOP_ELDERNET_GAIT_PRIOR): the mean served `gait_prob` over all windows the
    /// decoder sees (ELDERNET.md §5; 0.0849 on Capture-24 VAL at hop 5 with the served defaults).
    var gaitPrior: Double? = nil
    /// Why ElderNet stays off although it was asked for (a missing weights dir, an unknown mode or value …).
    var configurationError: String?
    /// Settings that were adjusted rather than refused (a clamped timeout); logged once at start-up.
    var warnings: [String] = []
    /// Wall-clock seconds ElderNet may spend in one job (its readiness check and every chunk call together)
    /// before it is stopped for the rest of that job (`job_time_budget`). FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS.
    var jobBudgetSeconds: Double = ElderNetSettings.defaultJobBudgetSeconds
    /// FRWHOOP_ELDERNET_THREADS: torch and numerical-library threads of the serve process (1…16, default 1).
    var threads: Int = 1

    static let serveModule = ["-m", "activity_context.eldernet.serve"]
    static let defaultTimeoutSeconds = 60.0
    /// Ten request timeouts: about three times a normal full day at hop 5 (≈ 1.9 ms per window per head), far
    /// below a day of slow-but-not-failing chunks.
    static let defaultJobBudgetSeconds = 600.0

    /// FRWHOOP_ELDERNET_ENABLED (1/true/yes/on, default off; anything unrecognised is a configuration error),
    /// FRWHOOP_ELDERNET_MODE (shadow | candidate | production, default shadow), FRWHOOP_ELDERNET_WEIGHTS_DIR and
    /// FRWHOOP_ELDERNET_UPSTREAM_DIR (both required when on),
    /// FRWHOOP_ELDERNET_PYTHON (default: the activity python), FRWHOOP_ELDERNET_TIMEOUT_SECONDS (default 60, clamped
    /// to at most `leaseSeconds / 3`), FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS (default 600),
    /// FRWHOOP_ELDERNET_MODEL_VERSION and FRWHOOP_ELDERNET_WEIGHTS_SHA256 (the pins; required in candidate and
    /// production mode, enforced in shadow mode when set), FRWHOOP_ELDERNET_GAIT_PRIOR (π in [0.01, 0.99]; required
    /// in candidate and production mode). A setting that cannot be honoured switches ElderNet off with a reason; it
    /// never stops the worker.
    static func fromEnvironment(_ env: [String: String], activityPython: String = "python3",
                                leaseSeconds: Int = 300) -> ElderNetSettings {
        func value(_ key: String) -> String? {
            env[key].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        var errors: [String] = []
        var asked = false
        if let raw = value("FRWHOOP_ELDERNET_ENABLED") {
            if let b = InertiaSettings.parseBool(raw) { asked = b }
            else { errors.append("unknown FRWHOOP_ELDERNET_ENABLED value \(raw) (use 1/true/yes/on or 0/false/no/off)") }
        }
        var warnings: [String] = []
        var timeout = defaultTimeoutSeconds
        if let raw = value("FRWHOOP_ELDERNET_TIMEOUT_SECONDS") {
            if let t = InertiaSettings.parseSeconds(raw) { timeout = t }
            else { errors.append("invalid FRWHOOP_ELDERNET_TIMEOUT_SECONDS \(raw)") }
        }
        var jobBudget = ElderNetSettings.defaultJobBudgetSeconds
        if let raw = value("FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS") {
            if let t = InertiaSettings.parseSeconds(raw) { jobBudget = t }
            else { errors.append("invalid FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS \(raw)") }
        }
        // A request may never outlive a third of the job lease: the lease is renewed before each ElderNet call,
        // and one stuck child must not be able to let it expire.
        let cap = Double(max(1, leaseSeconds)) / 3
        if timeout > cap {
            warnings.append("FRWHOOP_ELDERNET_TIMEOUT_SECONDS \(timeout) clamped to \(cap) (a third of the \(leaseSeconds) s lease)")
            timeout = cap
        }
        var settings = ElderNetSettings(
            enabled: asked, mode: .shadow, weightsDir: value("FRWHOOP_ELDERNET_WEIGHTS_DIR"),
            upstreamDir: value("FRWHOOP_ELDERNET_UPSTREAM_DIR"),
            python: value("FRWHOOP_ELDERNET_PYTHON") ?? activityPython, timeoutSeconds: timeout,
            configurationError: nil, warnings: warnings, jobBudgetSeconds: jobBudget)
        if let raw = value("FRWHOOP_ELDERNET_MODE") {
            if let mode = Mode(rawValue: raw.lowercased()) { settings.mode = mode }
            else { errors.append("unknown FRWHOOP_ELDERNET_MODE \(raw)") }
        }
        if let raw = value("FRWHOOP_ELDERNET_MODEL_VERSION") {
            if isModelVersion(raw) { settings.modelVersion = raw }
            else { errors.append("FRWHOOP_ELDERNET_MODEL_VERSION is not a plain identifier") }
        }
        if let raw = value("FRWHOOP_ELDERNET_WEIGHTS_SHA256") {
            let sha = raw.lowercased()
            if InertiaSettings.isHex64(sha) { settings.weightsSHA256 = sha }
            else { errors.append("FRWHOOP_ELDERNET_WEIGHTS_SHA256 must be 64 hex characters") }
        }
        if let raw = value("FRWHOOP_ELDERNET_THREADS") {
            if let n = Int(raw), (1...16).contains(n) { settings.threads = n }
            else { errors.append("invalid FRWHOOP_ELDERNET_THREADS \(raw) (1…16)") }
        }
        if let raw = value("FRWHOOP_ELDERNET_GAIT_PRIOR") {
            if let p = Double(raw), p.isFinite, GaitQualityEvidenceConfig.gaitPriorBounds.contains(p) { settings.gaitPrior = p }
            else { errors.append("FRWHOOP_ELDERNET_GAIT_PRIOR must be a number in [0.01, 0.99]") }
        }
        if asked, errors.isEmpty {
            if settings.weightsDir == nil {
                errors.append("FRWHOOP_ELDERNET_WEIGHTS_DIR is required")
            } else if settings.upstreamDir == nil {
                errors.append("FRWHOOP_ELDERNET_UPSTREAM_DIR is required (the sha-verified upstream source checkout)")
            } else if settings.mode != .shadow, settings.modelVersion == nil || settings.weightsSHA256 == nil {
                errors.append("FRWHOOP_ELDERNET_MODEL_VERSION and FRWHOOP_ELDERNET_WEIGHTS_SHA256 are required in \(settings.mode.rawValue) mode")
            } else if settings.mode != .shadow, settings.gaitPrior == nil {
                errors.append("FRWHOOP_ELDERNET_GAIT_PRIOR is required in \(settings.mode.rawValue) mode")
            }
        }
        settings.configurationError = errors.first
        if settings.configurationError != nil { settings.enabled = false }
        return settings
    }

    /// The `model_version` shape the decoder and the table accept: `[A-Za-z0-9][A-Za-z0-9._:+-]{0,127}`.
    static func isModelVersion(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard (1...128).contains(bytes.count) else { return false }
        func alnum(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) }
        guard alnum(bytes[0]) else { return false }
        return bytes.allSatisfy { alnum($0) || $0 == 46 || $0 == 95 || $0 == 58 || $0 == 43 || $0 == 45 }
    }

    static func serveArgs(weightsDir: String, upstreamDir: String, timeoutSeconds: Double? = nil,
                          threads: Int? = nil) -> [String] {
        var args = serveModule + ["--weights-dir", weightsDir, "--upstream-dir", upstreamDir]
        if let timeoutSeconds { args += ["--timeout", InertiaSettings.formatSeconds(timeoutSeconds)] }
        if let threads { args += ["--threads", String(threads)] }
        return args
    }

    /// The service config of the ElderNet child. Its own process, timeout, restart cap and response cap.
    func serviceConfig(activityHome: String) -> ActivityPythonService.Config? {
        guard enabled, let weightsDir, let upstreamDir else { return nil }
        return ActivityPythonService.Config(
            pythonBin: python, activityHome: activityHome, modelDir: nil,
            serveArgs: Self.serveArgs(weightsDir: weightsDir, upstreamDir: upstreamDir,
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

/// The ElderNet windows gathered for one job, chunk by chunk.
struct GaitQualityCollector {
    var responses: [GaitQualityResponse] = []
    var chunks = 0
    var failedChunks = 0
    var failureKinds: [String: Int] = [:]
    /// Set when ElderNet was skipped or stopped for the rest of the job (the kind that stopped it).
    var stopped: String?

    var isEmpty: Bool { responses.isEmpty }

    /// One day's windows from one model, or nil (nothing valid, or the model changed between chunks).
    var trackInput: GaitQualityTrackInput? { GaitQualityTrackInput(responses: responses) }
}

/// ElderNet answers by request and pinned model, for this process's lifetime; the oldest go first past `capacity`
/// (a day of hour chunks is 24 entries, a day of short uploads a few hundred).
final class ElderNetResponseCache: @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var entries: [String: GaitQualityResponse] = [:]
    private var order: [String] = []

    init(capacity: Int = 4096) { self.capacity = max(1, capacity) }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func response(_ key: String) -> GaitQualityResponse? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    func store(_ response: GaitQualityResponse, key: String) {
        lock.lock(); defer { lock.unlock() }
        if entries.updateValue(response, forKey: key) == nil { order.append(key) }
        if order.count > capacity {
            let drop = order.count - capacity
            for k in order.prefix(drop) { entries[k] = nil }
            order.removeFirst(drop)
        }
    }
}

/// The ElderNet service and what to do with it. Stateless apart from the service and the answer cache (classes);
/// the lane keeps the counters.
struct ElderNetStage {
    let service: ActivityPythonService
    let mode: ElderNetSettings.Mode
    /// The pins (FRWHOOP_ELDERNET_MODEL_VERSION / _WEIGHTS_SHA256), or nil when not pinned (shadow only).
    var expectedModelVersion: String? = nil
    var expectedWeightsDigest: String? = nil
    /// π for the candidate and production decodes (FRWHOOP_ELDERNET_GAIT_PRIOR).
    var gaitPrior: Double? = nil
    /// Wall-clock seconds this stage may spend per job (`ElderNetSettings.jobBudgetSeconds`).
    var jobBudgetSeconds: Double = ElderNetSettings.defaultJobBudgetSeconds
    /// Answers this process already has. A job re-reads the whole day, and the day's revision moves with every
    /// upload, so without this every claim re-runs every chunk and a job outlives the revision it must publish.
    var responses = ElderNetResponseCache()

    /// The key of `request`'s answer under what the running child measured it loaded (its ping `loaded` map: the
    /// weights digest read from the files, the verified upstream source, the calibration, the code), or nil when
    /// the child reported none (an older serve process): an answer whose bytes cannot be named is never reused.
    func cacheKey(_ request: ActivityPythonService.RunRequest) -> String? {
        guard let identity = service.cacheIdentity else { return nil }
        return ActivityLocalCache.inferenceKey(request: request, identity: identity, versions: ["route": "eldernet"])
    }

    enum Outcome: Equatable {
        case ok(GaitQualityResponse)
        /// `stop` = do not ask again during this job.
        case failed(kind: String, message: String, stop: Bool)
    }

    /// The kind every pin refusal is counted under (the served model is not the one the deployment pinned).
    static let pinMismatchKind = "pin_mismatch"

    /// The weights digest of a ping's `weights` map: the same canonical text `GaitQualityModelInfo.weightsDigest`
    /// hashes (`GaitQualityWire.weightsDigestPrefix`, then `name=sha256\n` per head in name order), hashed with the
    /// worker's own SHA-256. `ActivityElderNetStageTests` pins the two to each other.
    static func weightsDigest(of weights: [String: String]) -> String {
        let text = GaitQualityWire.weightsDigestPrefix + weights.keys.sorted().map { "\($0)=\(weights[$0]!)\n" }.joined()
        return sha256Hex(Data(text.utf8))
    }

    /// One response line through the package's strict decoder (`GaitQualityResponse.init(from:)`, whose errors are
    /// `GaitQualityResponseError`). Text that is not JSON at all fails in `JSONDecoder` first: it is reported as
    /// `.notJSON`, nonfinite when it carries a NaN / Infinity token.
    static func decodeResponse(_ data: Data) throws -> GaitQualityResponse {
        do {
            return try JSONDecoder().decode(GaitQualityResponse.self, from: data)
        } catch is DecodingError {
            let text = String(decoding: data, as: UTF8.self)
            let nonfinite = text.range(of: #"[:\[,]\s*-?(NaN|Infinity)"#, options: .regularExpression) != nil
            throw GaitQualityResponseError.notJSON(nonfinite: nonfinite)
        }
    }

    /// nil when `version` / `digest` are what the deployment pinned, else why not.
    func pinRefusal(version: String?, digest: String?) -> String? {
        if let expected = expectedModelVersion, version != expected {
            return "served model_version \(version ?? "unknown"), pinned \(expected)"
        }
        if let expected = expectedWeightsDigest, digest != expected {
            return "served weights digest \(digest ?? "unknown"), pinned \(expected)"
        }
        return nil
    }

    /// Readiness at the start of a job: start the child if needed and ping it unless it is known to be up. nil =
    /// ready, otherwise the kind that keeps ElderNet off for this job. Never throws. A pinned stage also refuses a
    /// child whose ping reports another model version or weights digest (or none).
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
            if expectedModelVersion != nil || expectedWeightsDigest != nil {
                let version = service.lastPingDetails["model_version"]
                // The digest measured from the weight files when the child reports one; the served map otherwise.
                let digest = service.loadedIdentity["weights_digest"]
                    ?? service.lastPingObjects["weights"].map { Self.weightsDigest(of: $0) }
                if let why = pinRefusal(version: version, digest: digest) { return (Self.pinMismatchKind, why) }
            }
            return nil
        } catch {
            return InertiaStage.classify(error)
        }
    }

    /// Infer one chunk. Never throws: every failure comes back classified. A response from any model other than
    /// the pinned one is refused and stops ElderNet for the job.
    func infer(_ request: ActivityPythonService.RunRequest) -> Outcome {
        do {
            let (object, line) = try service.inferRaw(run: request)
            let data: Data
            if let line { data = line }
            else { data = try JSONSerialization.data(withJSONObject: object) }
            let response = try Self.decodeResponse(data)
            if let why = pinRefusal(version: response.model.modelVersion, digest: response.model.weightsDigest) {
                return .failed(kind: Self.pinMismatchKind, message: why, stop: true)
            }
            return .ok(response)
        } catch let e as GaitQualityResponseError {
            // A service error stops by its kind; a response the decoder refused stops unless only this chunk's
            // numbers were bad (`nonfinite`, `malformed_json`: a NaN token): the rest would repeat on every chunk.
            return .failed(kind: e.kind, message: String(String(describing: e).prefix(240)),
                           stop: Self.stoppingServiceKinds.contains(e.kind))
        } catch {
            let c = InertiaStage.classify(error)
            // A line that named the request but did not parse (a NaN token) came from a healthy child: only that
            // chunk is lost. Every other transport failure stops ElderNet for the job (at most one timeout).
            if case ActivityPythonService.ServiceError.malformedResponse(let detail) = error,
               detail == "unparseable response line" {
                return .failed(kind: c.kind, message: c.message, stop: false)
            }
            return .failed(kind: c.kind, message: c.message, stop: true)
        }
    }

    /// Failure kinds that will not clear within a job: ask no more chunks. The service's own kinds
    /// (`model_missing`, `weights_mismatch`, `timeout`, `malformed`: the request itself, `output_too_large`: the
    /// same chunk sizes all day), a pin refusal, and the decoder's refusals that would repeat on every chunk
    /// (`schema`, `malformed`, `invalid_values`). Not `nonfinite` / `malformed_json` (a NaN line costs one chunk)
    /// nor `internal`.
    static let stoppingServiceKinds: Set<String> = ["model_missing", "weights_mismatch", "timeout", pinMismatchKind,
                                                    "malformed", "output_too_large", "schema", "invalid_values"]
}

/// The shadow row (and candidate comparison) for one job.
enum ActivityGaitWindowsDays {

    /// The columnar `windows` (`gait-windows-1`) above this are not stored (the summary says so); the row itself
    /// stays useful. A full day at a 5-s hop is about 0.45 MB (more only on a day of almost continuous walking).
    static let maxWindowsBytes = 512 * 1024
    static let windowsFormat = "gait-windows-1"
    /// Rows whose `computed_at` is older than this are deleted by `prune_activity_gait_windows_days`, which the
    /// lane calls while ElderNet is on (`ActivityLane.pruneGaitWindowsIfDue`).
    static let retentionDays = 30
    static let pruneBatchRows = 10_000
    static let pruneSQL = "SELECT public.prune_activity_gait_windows_days($1::integer, $2::integer)::text"

    enum Candidate {
        /// Shadow or production mode: no comparison decode.
        case notRequested
        case withheld(String)
        /// The comparison document, and how its decode attached and used the windows.
        case document(ActivityContextDayDocument, GaitQualityTrackReport?)
    }

    enum PublishOutcome: Equatable {
        case stored(revision: Int64)
        case fenced
        case rejected(String)
    }

    /// The day's windows, columnar and in small integers (`gait-windows-1`). `s0` is the first window start,
    /// `ds[k]` the start minus the previous one (0 first), every window is `w` seconds long on an `h`-second hop;
    /// `gp[k]` the gait probability in per mille, `g[k]` 1 for detected gait, `pf[k]` 1 for a pre-filtered window;
    /// on gait windows `sp` speed in cm/s, `cad` cadence in steps/min, `st` stride in cm, `rg` regularity in
    /// percent and `stp` steps × 10, each -1 where absent. Every array has `n` entries.
    struct CompactWindows: Encodable, Equatable {
        var format = ActivityGaitWindowsDays.windowsFormat
        var n: Int
        var w: Int
        var h: Int
        var s0: Int?
        var ds: [Int]
        var gp: [Int]
        var g: [Int]
        var pf: [Int]
        var sp: [Int]
        var cad: [Int]
        var st: [Int]
        var rg: [Int]
        var stp: [Int]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(format, forKey: .format); try c.encode(n, forKey: .n); try c.encode(w, forKey: .w)
            try c.encode(h, forKey: .h)
            if let s0 { try c.encode(s0, forKey: .s0) } else { try c.encodeNil(forKey: .s0) }
            try c.encode(ds, forKey: .ds); try c.encode(gp, forKey: .gp); try c.encode(g, forKey: .g)
            try c.encode(pf, forKey: .pf); try c.encode(sp, forKey: .sp); try c.encode(cad, forKey: .cad)
            try c.encode(st, forKey: .st); try c.encode(rg, forKey: .rg); try c.encode(stp, forKey: .stp)
        }

        enum CodingKeys: String, CodingKey { case format, n, w, h, s0, ds, gp, g, pf, sp, cad, st, rg, stp }
    }

    /// `x` scaled and rounded into a small integer, -1 when absent. The only Double → Int conversion here: the value
    /// is clamped to `range` first, so it can never trap.
    static func scaled(_ x: Double?, _ scale: Double, _ range: ClosedRange<Double>) -> Int {
        guard let x, x.isFinite else { return -1 }
        return Int((min(range.upperBound, max(range.lowerBound, x)) * scale).rounded())
    }

    static func compact(_ windows: [GaitQualityWindow], model: GaitQualityModelInfo) -> CompactWindows {
        var out = CompactWindows(n: windows.count, w: model.windowS, h: model.hopS, s0: windows.first?.startTs,
                                 ds: [], gp: [], g: [], pf: [], sp: [], cad: [], st: [], rg: [], stp: [])
        var previous: Int?
        for win in windows {
            out.ds.append(previous.map { win.startTs - $0 } ?? 0)
            previous = win.startTs
            out.gp.append(scaled(win.gaitProb, 1000, 0...1))
            out.g.append(win.isGait ? 1 : 0)
            out.pf.append(win.prefiltered ? 1 : 0)
            out.sp.append(scaled(win.speedMps, 100, GaitQualityWire.speedRange))
            out.cad.append(scaled(win.cadenceSpm, 1, GaitQualityWire.cadenceRange))
            out.st.append(scaled(win.strideM, 100, GaitQualityWire.strideRange))
            out.rg.append(scaled(win.regularity, 100, GaitQualityWire.regularityRange))
            out.stp.append(scaled(win.steps, 10, GaitQualityWire.stepsRange))
        }
        return out
    }

    struct Summary: Encodable {
        var nWindows: Int
        var nGait: Int
        var nPrefiltered: Int
        var nDroppedNonfinite: Int
        var nChunks: Int
        var nFailedChunks: Int
        var failureKinds: [String: Int]
        var stopped: String?
        var weightsDigest: String
        var meanGaitProb: Double?
        /// ElderNet's own metrics over its gait windows (no decoder involved).
        var gait: ActivityGaitSummary?
        var windowsOmitted: Bool
        var candidateStamp: String?
        var gaitPrior: Double?
        /// How the windows met the day's observed seconds: the candidate decode's report in candidate mode, the
        /// published decode's in production mode when the channel shaped it, a dry-run attachment otherwise. nil when
        /// there was no decoder input to attach to (ActivityContext v2 off).
        var trackReport: GaitQualityTrackReport?
        /// The shared policy's inputs and decision for this row (ActivityExpertAuthority); the migration's trigger
        /// copies it into the row's `authority` column. Left out when the caller has no selection.
        var authority: ActivityExpertAuthority? = nil
        /// Workout mode: each logged workout in the day with its type's attributes, the windows inside it and what
        /// their gait means for the type (docs/context-watchdog/WORKOUTS.md). Left out when none was logged.
        var workouts: [LoggedWorkouts.GaitContext] = []

        enum CodingKeys: String, CodingKey {
            case nWindows = "n_windows", nGait = "n_gait", nPrefiltered = "n_prefiltered"
            case nDroppedNonfinite = "n_dropped_nonfinite", nChunks = "n_chunks", nFailedChunks = "n_failed_chunks"
            case failureKinds = "failure_kinds", stopped, weightsDigest = "weights_digest"
            case meanGaitProb = "mean_gait_prob", gait, windowsOmitted = "windows_omitted"
            case candidateStamp = "candidate_stamp", gaitPrior = "gait_prior", trackReport = "track_report"
            case authority, workouts
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(nWindows, forKey: .nWindows); try c.encode(nGait, forKey: .nGait)
            try c.encode(nPrefiltered, forKey: .nPrefiltered)
            try c.encode(nDroppedNonfinite, forKey: .nDroppedNonfinite)
            try c.encode(nChunks, forKey: .nChunks); try c.encode(nFailedChunks, forKey: .nFailedChunks)
            try c.encode(failureKinds, forKey: .failureKinds)
            if let stopped { try c.encode(stopped, forKey: .stopped) } else { try c.encodeNil(forKey: .stopped) }
            try c.encode(weightsDigest, forKey: .weightsDigest)
            if let m = meanGaitProb { try c.encode(m, forKey: .meanGaitProb) } else { try c.encodeNil(forKey: .meanGaitProb) }
            if let gait { try c.encode(gait, forKey: .gait) } else { try c.encodeNil(forKey: .gait) }
            try c.encode(windowsOmitted, forKey: .windowsOmitted)
            if let s = candidateStamp { try c.encode(s, forKey: .candidateStamp) } else { try c.encodeNil(forKey: .candidateStamp) }
            if let p = gaitPrior { try c.encode(p, forKey: .gaitPrior) } else { try c.encodeNil(forKey: .gaitPrior) }
            if let r = trackReport { try c.encode(r, forKey: .trackReport) } else { try c.encodeNil(forKey: .trackReport) }
            try c.encodeIfPresent(authority, forKey: .authority)
            if !workouts.isEmpty { try c.encode(workouts, forKey: .workouts) }
        }
    }

    struct Payload: Encodable {
        var day: String
        var mode: String
        var schema = GaitQualityWire.schema
        var model: GaitQualityModelInfo
        var weightsDigest: String
        var summary: Summary
        var windows: CompactWindows?
        var withheldReason: String?
        var candidateDocument: ActivityContextDayDocument?

        enum CodingKeys: String, CodingKey {
            case day, mode, schema, model, weightsDigest = "weights_digest", summary, windows
            case withheldReason = "withheld_reason", candidateDocument = "candidate_document"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(day, forKey: .day); try c.encode(mode, forKey: .mode); try c.encode(schema, forKey: .schema)
            try c.encode(model, forKey: .model); try c.encode(weightsDigest, forKey: .weightsDigest)
            try c.encode(summary, forKey: .summary)
            if let windows { try c.encode(windows, forKey: .windows) } else { try c.encodeNil(forKey: .windows) }
            if let withheldReason { try c.encode(withheldReason, forKey: .withheldReason) }
            else { try c.encodeNil(forKey: .withheldReason) }
            if let candidateDocument { try c.encode(candidateDocument, forKey: .candidateDocument) }
            else { try c.encodeNil(forKey: .candidateDocument) }
        }
    }

    static func rounded(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }

    /// How `gait`'s windows meet `input`'s observed seconds without decoding anything: the package's own attachment
    /// (`observationsWithReports`) under a throwaway candidate config that accepts the windows' model. Only the
    /// attach / drop counts are kept (no stamp: no decode happened).
    static func dryRunAttachment(input: ActivityContextTrackInput, gait: GaitQualityTrackInput) -> GaitQualityTrackReport? {
        var withGait = input
        withGait.gaitQuality = gait
        var config = ActivityDecoderConfig()
        config.gaitQuality = GaitQualityEvidenceConfig(mode: .candidate, model: gait.model, gaitPrior: 0.5)
        guard var report = ActivityContextTrackBuilder.observationsWithReports(for: withGait, config: config).gaitQuality
        else { return nil }
        report.stamp = nil
        return report
    }

    /// The candidate comparison for one day: the same input the published v2 document was decoded from, plus the
    /// ElderNet windows, decoded with the gait channel as candidate evidence. Withheld unless the deployment pinned
    /// the model version and weights digest and set the gait prior, and whenever the config refuses the model. Only
    /// candidate mode asks for one: production windows shape the published decode itself.
    ///
    /// The decode itself is the shared policy's (`selection`, the job's own; built here from these windows alone when
    /// nil): HART plus the gait-quality channel exactly, with the config and release the policy built from the row.
    /// `config` and `lookback` are the published document's (`ContextDayBuild.config` / `.lookback`: the wearer's
    /// reference as of the day and the warm-up half hour), so the comparison differs from it only by the expert.
    static func candidate(mode: ElderNetSettings.Mode, gait: GaitQualityTrackInput, input: ActivityContextTrackInput?,
                          generatedAt: Int, expectedModelVersion: String?, expectedWeightsDigest: String?,
                          gaitPrior: Double?, selection: ActivityExpertSelection? = nil,
                          config base: ActivityDecoderConfig = ActivityDecoderConfig(),
                          lookback: ActivityContextTrackInput? = nil) -> Candidate {
        guard mode == .candidate else { return .notRequested }
        guard let expectedModelVersion, let expectedWeightsDigest else { return .withheld("model_not_pinned") }
        guard let gaitPrior else { return .withheld("gait_prior_not_set") }
        let evidence = GaitQualityEvidenceConfig(mode: .candidate, model: gait.model, gaitPrior: gaitPrior,
                                                 expectedModelVersion: expectedModelVersion,
                                                 expectedWeightsDigest: expectedWeightsDigest)
        if let why = evidence.evidenceRefusal { return .withheld(why) }
        guard let input else { return .withheld("context_days_disabled") }
        let selection = selection ?? ActivityExpertSelection.select(gaitQuality: [
            GaitQualitySource(track: gait, releaseMode: .candidate, expectedModelVersion: expectedModelVersion,
                              expectedWeightsDigest: expectedWeightsDigest, gaitPrior: gaitPrior)])
        guard selection.use(of: .gaitQuality) != .none else {
            return .withheld(selection.decision(for: .gaitQuality)?.reason ?? "gait_quality_not_admitted")
        }
        let d = selection.decode(input, base: base, channels: [.gaitQuality])
        let built = ActivityContextDays.dayDocumentAndGaitReport(input: d.input, generatedAt: generatedAt, config: d.config,
                                                                 lookback: lookback)
        // A comparison must name the evidence that shaped it; a decode the evidence never reached is withheld.
        guard built.document.versions.gaitQuality != nil else {
            return .withheld(built.report?.refusal ?? "gait_quality_not_accepted")
        }
        return .document(built.document, built.report)
    }

    /// The RPC payload (sorted keys), or nil when no chunk produced a valid response. `attachment` is the report
    /// used when there is no candidate decode (see `Summary.trackReport`). Only a candidate-mode row carries a
    /// comparison document or a withheld reason; `candidate` is ignored in every other mode.
    static func payload(day: String, mode: ElderNetSettings.Mode, collector: GaitQualityCollector,
                        candidate: Candidate, attachment: GaitQualityTrackReport? = nil,
                        gaitPrior: Double? = nil, authority: ActivityExpertAuthority? = nil,
                        workouts: [LoggedWorkouts.GaitContext] = []) throws -> String? {
        guard let gait = collector.trackInput else { return nil }
        let model = gait.model
        var probSum = 0.0
        var totals: ActivityGaitSummary?
        let stepShare = Double(model.hopS) / Double(max(1, model.windowS))
        for w in gait.windows {
            probSum += w.gaitProb
            guard w.isGait else { continue }
            let one = ActivityGaitSummary(since: w.startTs, windows: 1, gaitProbability: w.gaitProb, speedMps: w.speedMps,
                                          cadenceSpm: w.cadenceSpm, strideM: w.strideM, regularity: w.regularity,
                                          steps: w.steps.map { $0 * stepShare }, provenance: "eldernet:\(model.modelVersion)")
            totals = totals.map { $0.combined(with: one) } ?? one
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let columnar = compact(gait.windows, model: model)
        let windows: CompactWindows? = try encoder.encode(columnar).count > maxWindowsBytes ? nil : columnar

        var withheld: String?, document: ActivityContextDayDocument?, stamp: String?
        var report = attachment
        switch mode == .candidate ? candidate : .notRequested {
        case .notRequested: break
        case .withheld(let why): withheld = why
        case .document(let d, let r): document = d; stamp = d.versions.gaitQuality; report = r ?? attachment
        }
        let summary = Summary(
            nWindows: gait.windows.count, nGait: gait.windows.filter(\.isGait).count,
            nPrefiltered: gait.windows.filter(\.prefiltered).count,
            nDroppedNonfinite: collector.responses.reduce(0) { $0 + $1.droppedNonfinite },
            nChunks: collector.chunks, nFailedChunks: collector.failedChunks, failureKinds: collector.failureKinds,
            stopped: collector.stopped, weightsDigest: model.weightsDigest,
            meanGaitProb: gait.windows.isEmpty ? nil : rounded(probSum / Double(gait.windows.count)),
            gait: totals, windowsOmitted: windows == nil, candidateStamp: stamp,
            gaitPrior: mode != .shadow ? gaitPrior : nil, trackReport: report, authority: authority,
            workouts: workouts)
        let payload = Payload(day: day, mode: mode.rawValue, model: model, weightsDigest: model.weightsDigest,
                              summary: summary, windows: windows, withheldReason: withheld, candidateDocument: document)
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkerError.malformed("gait windows payload encoding failed")
        }
        return text
    }

    /// Write the shadow row through its fenced RPC. Runs under a savepoint when a transaction is open, so a rejection
    /// (or a database without the migration) leaves the transaction usable for the publishes around it. Only a lost
    /// connection propagates.
    static func publish(db: PostgresClient, token: String, revision: Int64, payload: String) throws -> PublishOutcome {
        do {
            let out = try db.isolatingFailures {
                try db.callFunctionForJSONRaw(
                    "SELECT public.publish_activity_gait_windows_day($1::uuid,$2::bigint,$3::jsonb)::text",
                    [token, String(revision), payload])
            }
            if let stored = Int64(out ?? ""), stored > 0 { return .stored(revision: stored) }
            return .fenced
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            throw e
        } catch {
            return .rejected(ActivityContextDays.safeReason(error))
        }
    }

    /// Retention: delete rows computed more than `keepDays` ago (at most `maxRows` per call). Returns the number
    /// deleted. Outside any transaction; the caller counts and logs a failure and carries on.
    static func prune(db: PostgresClient, keepDays: Int = retentionDays, maxRows: Int = pruneBatchRows) throws -> Int {
        let out = try db.callFunctionForJSONRaw(pruneSQL, [String(keepDays), String(maxRows)])
        return Int(out ?? "") ?? 0
    }
}
