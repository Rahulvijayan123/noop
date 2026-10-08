import Foundation
import StrandAnalytics

// ActivityMotionHeads.swift — Inertia-1 motion heads on the server, SHADOW FIRST (Tools/ActivityContext/INERTIA1.md
// §8, spec §24 stages 1–2).
//
// A second, separate Python process (`python -m activity_context.inertia.serve`, its own timeout, restart cap
// and response cap) is asked for `motion-heads-1` windows for the same IMU chunks the HART service just
// inferred. It is never part of the lane's readiness gate and nothing it does can fail a job:
//
//   • every Inertia failure (model missing, timeout, crash, malformed or invalid output, NaN) is classified,
//     counted and logged once per distinct reason, and the HART path continues untouched;
//   • a transport failure (timeout, crash, launch failure, restart cooldown), `model_missing`, a pin refusal or a
//     failure that would repeat on every chunk (an unknown schema, a malformed response, invalid probabilities, an
//     output too large) stops Inertia for the rest of that job, so a broken model costs at most one timeout per job;
//     only a NaN line costs a single chunk. Inertia also has a per-job time budget
//     (FRWHOOP_INERTIA_JOB_BUDGET_SECONDS): once its calls in a job have used it, it is stopped for that job;
//   • the shadow output (provenance + compact per-window predictions + OOD counts) is written to its OWN table
//     (`activity_motion_heads_days`) through its own fenced RPC under a savepoint, so a rejection or a missing
//     migration never reaches the v1 / v2 publishes in the same transaction;
//   • candidate mode additionally decodes the day a second time with Inertia as decoder evidence — only for a
//     pinned `inertia1` / `actinet` encoder whose bundle tier is at least `candidate`, otherwise the withheld reason is
//     stored — and keeps that comparison document beside the shadow row. It is never written to
//     `activity_context_days` / `activity_context_epochs`: the published HART documents are byte-identical
//     whether Inertia is enabled or not.

/// FRWHOOP_INERTIA_* settings. Off unless `FRWHOOP_INERTIA_ENABLED` is on and a bundle directory is configured.
struct InertiaSettings: Equatable {
    enum Mode: String, Equatable {
        case shadow, candidate
    }

    var enabled: Bool
    var mode: Mode
    var bundleDir: String?
    var checkpoint: String?
    var python: String
    /// Worker-side per-request timeout, already clamped to at most a third of the job lease.
    var timeoutSeconds: Double
    /// The bundle digest the deployment pins (FRWHOOP_INERTIA_BUNDLE_SHA256). Required in candidate mode;
    /// enforced in shadow mode when set. A served bundle with another digest turns Inertia off for the job.
    var bundleSHA256: String? = nil
    /// FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW: let the serve process load a stand-in encoder (shadow mode only).
    /// Its rows are stored with `encoder_kind = standin` and can never feed the decoder.
    var allowStandInShadow: Bool = false
    /// Why Inertia stays off although it was asked for (a missing bundle dir, an unknown mode or value …).
    var configurationError: String?
    /// Settings that were adjusted rather than refused (a clamped timeout); logged once at start-up.
    var warnings: [String] = []
    /// Wall-clock seconds Inertia may spend in one job (its readiness check and every chunk call together)
    /// before it is stopped for the rest of that job (`job_time_budget`). FRWHOOP_INERTIA_JOB_BUDGET_SECONDS.
    var jobBudgetSeconds: Double = InertiaSettings.defaultJobBudgetSeconds
    /// FRWHOOP_INERTIA_THREADS: torch CPU threads of the serve process (`--threads`, 1…16; default: serve's 1).
    var threads: Int? = nil

    static let serveModule = ["-m", "activity_context.inertia.serve"]
    static let defaultTimeoutSeconds = 60.0
    /// Ten request timeouts: well above a normal day's chunks, far below a day of slow-but-not-failing ones.
    static let defaultJobBudgetSeconds = 600.0

    /// A positive, finite number of seconds from `raw`, or nil.
    static func parseSeconds(_ raw: String) -> Double? {
        guard let t = Double(raw), t.isFinite, t > 0 else { return nil }
        return t
    }

    /// "1", "true", "yes", "on" (any case) → true; "0", "false", "no", "off" → false; anything else nil.
    static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    /// The serve process's own `--timeout`: strictly below the worker's, so the child's structured `timeout`
    /// answer arrives before the worker gives up on the line and restarts the process. Worker − 5 s while that
    /// leaves at least 5 s, otherwise 5 s (worker 5…10 s), otherwise half the worker timeout.
    static func serveTimeoutSeconds(workerTimeout t: Double) -> Double {
        if t - 5 >= 5 { return t - 5 }
        if t > 5 { return 5 }
        return t / 2
    }

    /// FRWHOOP_INERTIA_ENABLED (1/true/yes/on, default off), FRWHOOP_INERTIA_MODE (shadow | candidate, default
    /// shadow), FRWHOOP_INERTIA_BUNDLE_DIR (required when on), FRWHOOP_INERTIA_BUNDLE_SHA256 (the pinned
    /// bundle digest; required in candidate mode), FRWHOOP_INERTIA_CHECKPOINT (passed as --checkpoint and
    /// INERTIA1_CKPT_PATH), FRWHOOP_INERTIA_PYTHON (default: the activity python), FRWHOOP_INERTIA_TIMEOUT_SECONDS
    /// (default 60, clamped to at most `leaseSeconds / 3`), FRWHOOP_INERTIA_JOB_BUDGET_SECONDS (default 600),
    /// FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW (1/true/yes/on, default off; shadow mode only), FRWHOOP_INERTIA_THREADS
    /// (1…16, passed as --threads; default the serve process's 1). A setting that cannot be honoured switches Inertia off with a reason; it
    /// never stops the worker. An unrecognised boolean is a configuration error, never silently "off".
    static func fromEnvironment(_ env: [String: String], activityPython: String = "python3",
                                leaseSeconds: Int = 300) -> InertiaSettings {
        func value(_ key: String) -> String? {
            env[key].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        var errors: [String] = []
        func flag(_ key: String) -> Bool {
            guard let raw = value(key) else { return false }
            guard let b = parseBool(raw) else {
                errors.append("unknown \(key) value \(raw) (use 1/true/yes/on or 0/false/no/off)")
                return false
            }
            return b
        }
        let asked = flag("FRWHOOP_INERTIA_ENABLED")
        let allowStandIn = flag("FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW")
        var warnings: [String] = []
        var timeout = InertiaSettings.defaultTimeoutSeconds
        if let raw = value("FRWHOOP_INERTIA_TIMEOUT_SECONDS") {
            if let t = parseSeconds(raw) { timeout = t }
            else { errors.append("invalid FRWHOOP_INERTIA_TIMEOUT_SECONDS \(raw)") }
        }
        var jobBudget = InertiaSettings.defaultJobBudgetSeconds
        if let raw = value("FRWHOOP_INERTIA_JOB_BUDGET_SECONDS") {
            if let t = parseSeconds(raw) { jobBudget = t }
            else { errors.append("invalid FRWHOOP_INERTIA_JOB_BUDGET_SECONDS \(raw)") }
        }
        // A request may never outlive a third of the job lease: the lease is renewed before each Inertia call,
        // and one stuck child must not be able to let it expire.
        let cap = Double(max(1, leaseSeconds)) / 3
        if timeout > cap {
            warnings.append("FRWHOOP_INERTIA_TIMEOUT_SECONDS \(timeout) clamped to \(cap) (a third of the \(leaseSeconds) s lease)")
            timeout = cap
        }
        var settings = InertiaSettings(
            enabled: asked, mode: .shadow, bundleDir: value("FRWHOOP_INERTIA_BUNDLE_DIR"),
            checkpoint: value("FRWHOOP_INERTIA_CHECKPOINT"),
            python: value("FRWHOOP_INERTIA_PYTHON") ?? activityPython,
            timeoutSeconds: timeout,
            allowStandInShadow: allowStandIn,
            configurationError: nil, warnings: warnings, jobBudgetSeconds: jobBudget)
        if let raw = value("FRWHOOP_INERTIA_MODE") {
            if let mode = Mode(rawValue: raw.lowercased()) { settings.mode = mode }
            else { errors.append("unknown FRWHOOP_INERTIA_MODE \(raw)") }
        }
        if let raw = value("FRWHOOP_INERTIA_THREADS") {
            if let n = Int(raw), (1...16).contains(n) { settings.threads = n }
            else { errors.append("invalid FRWHOOP_INERTIA_THREADS \(raw) (1…16)") }
        }
        if let raw = value("FRWHOOP_INERTIA_BUNDLE_SHA256") {
            let sha = raw.lowercased()
            if isHex64(sha) { settings.bundleSHA256 = sha }
            else { errors.append("FRWHOOP_INERTIA_BUNDLE_SHA256 must be 64 hex characters") }
        }
        if asked, errors.isEmpty {
            if settings.bundleDir == nil {
                errors.append("FRWHOOP_INERTIA_BUNDLE_DIR is required")
            } else if settings.mode == .candidate, settings.bundleSHA256 == nil {
                errors.append("FRWHOOP_INERTIA_BUNDLE_SHA256 is required in candidate mode")
            } else if settings.mode == .candidate, settings.allowStandInShadow {
                errors.append("FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW is for shadow mode only")
            }
        }
        settings.configurationError = errors.first
        if settings.configurationError != nil { settings.enabled = false }
        return settings
    }

    static func serveArgs(bundleDir: String, checkpoint: String?, timeoutSeconds: Double? = nil,
                          expectBundleSHA256: String? = nil, allowStandInShadow: Bool = false,
                          threads: Int? = nil) -> [String] {
        var args = serveModule + ["--bundle", bundleDir]
        if let checkpoint { args += ["--checkpoint", checkpoint] }
        if let timeoutSeconds { args += ["--timeout", formatSeconds(timeoutSeconds)] }
        if let threads { args += ["--threads", String(threads)] }
        if let expectBundleSHA256 { args += ["--expect-bundle-sha256", expectBundleSHA256] }
        if allowStandInShadow { args += ["--allow-standin-shadow"] }
        return args
    }

    static func isHex64(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func formatSeconds(_ s: Double) -> String {
        s == s.rounded() && abs(s) < 1e9 ? String(Int64(s)) : String(format: "%.3f", s)
    }

    /// The service config of the Inertia child. Its own process, timeout, restart cap and response cap.
    func serviceConfig(activityHome: String) -> ActivityPythonService.Config? {
        guard enabled, let bundleDir else { return nil }
        var env: [String: String] = [:]
        if let checkpoint { env["INERTIA1_CKPT_PATH"] = checkpoint }
        return ActivityPythonService.Config(
            pythonBin: python, activityHome: activityHome, modelDir: nil,
            serveArgs: Self.serveArgs(bundleDir: bundleDir, checkpoint: checkpoint,
                                      timeoutSeconds: Self.serveTimeoutSeconds(workerTimeout: timeoutSeconds),
                                      expectBundleSHA256: bundleSHA256,
                                      allowStandInShadow: allowStandInShadow && mode == .shadow,
                                      threads: threads),
            requestTimeoutSeconds: timeoutSeconds,
            maxRequestBytes: 64 * 1024 * 1024,
            maxResponseLineBytes: 16 * 1024 * 1024,
            restartCap: 4,
            restartCooldownSeconds: 120,
            extraEnvironment: env,
            keepsRawLines: true)
    }
}

/// The Inertia windows gathered for one job, chunk by chunk.
struct MotionHeadsCollector {
    var responses: [MotionHeadsResponse] = []
    var chunks = 0
    var failedChunks = 0
    var failureKinds: [String: Int] = [:]
    /// Set when Inertia was skipped or stopped for the rest of the job (the kind that stopped it).
    var stopped: String?

    var isEmpty: Bool { responses.isEmpty }

    /// One day's windows from one bundle, or nil (nothing valid, or the bundle changed between chunks).
    var trackInput: MotionHeadsTrackInput? { MotionHeadsTrackInput(responses: responses) }
}

/// The Inertia service and what to do with it. Stateless apart from the service (a class); the lane keeps
/// the counters.
struct InertiaStage {
    let service: ActivityPythonService
    let mode: InertiaSettings.Mode
    /// The pinned bundle digest (FRWHOOP_INERTIA_BUNDLE_SHA256), or nil when not pinned (shadow only).
    var expectedBundleSHA256: String? = nil
    /// Wall-clock seconds this stage may spend per job (`InertiaSettings.jobBudgetSeconds`).
    var jobBudgetSeconds: Double = InertiaSettings.defaultJobBudgetSeconds

    enum Outcome: Equatable {
        case ok(MotionHeadsResponse)
        /// `stop` = do not ask again during this job.
        case failed(kind: String, message: String, stop: Bool)
    }

    /// The kind every pin refusal is counted under.
    static let bundleMismatchKind = "bundle_mismatch"

    /// Readiness at the start of a job: start the child if needed and ping it unless it is known to be up.
    /// nil = ready, otherwise the kind that keeps Inertia off for this job. Never throws. A pinned stage also
    /// refuses a child that reports another `bundle_sha256` (or none).
    func begin() -> (kind: String, message: String)? {
        do {
            try service.ensureStarted()
            var available = service.modelAvailable
            var ping: ActivityPythonService.PingStatus?
            if !available {
                ping = try service.ping()
                available = ping?.modelAvailable ?? false
            }
            // The pin first: a child that refused to load because its bundle is not the pinned one (the serve
            // process's own --expect-bundle-sha256 check) is a pin refusal, not a missing model.
            if let expected = expectedBundleSHA256 {
                let served = service.lastPingDetails["bundle_sha256"]
                if let served, served != expected {
                    return (Self.bundleMismatchKind, "served bundle \(served), pinned \(expected)")
                }
                if available, served == nil {
                    return (Self.bundleMismatchKind, "served bundle unknown, pinned \(expected)")
                }
            }
            guard available else {
                return ("model_unavailable", "\(ping?.modelStatus ?? "unknown"): \(ping?.error ?? "")")
            }
            return nil
        } catch {
            return Self.classify(error)
        }
    }

    /// Infer one chunk. Never throws: every failure comes back classified. A response from any bundle other
    /// than the pinned one is refused and stops Inertia for the job.
    func infer(_ request: ActivityPythonService.RunRequest) -> Outcome {
        do {
            let (object, line) = try service.inferRaw(run: request)
            let data: Data
            if let line { data = line }
            else { data = try JSONSerialization.data(withJSONObject: object) }
            let response = try MotionHeadsResponse.decode(data)
            if let expected = expectedBundleSHA256, response.bundle.bundleSha256 != expected {
                return .failed(kind: Self.bundleMismatchKind,
                               message: "served bundle \(response.bundle.bundleSha256), pinned \(expected)", stop: true)
            }
            return .ok(response)
        } catch let e as MotionHeadsResponseError {
            // A service error stops by its kind; a response the decoder refused stops unless only this chunk's
            // numbers were bad (`nonfinite`, `malformed_json`: a NaN token): the rest would repeat on every chunk.
            return .failed(kind: e.kind, message: String(String(describing: e).prefix(240)),
                           stop: Self.stoppingServiceKinds.contains(e.kind))
        } catch {
            let c = Self.classify(error)
            // A line that named the request but did not parse (a NaN token) came from a healthy child: only that
            // chunk is lost. Every other transport failure (timeout, crash, oversized line …) stops Inertia for
            // the job, so a broken child costs at most one timeout.
            if case ActivityPythonService.ServiceError.malformedResponse(let detail) = error,
               detail == "unparseable response line" {
                return .failed(kind: c.kind, message: c.message, stop: false)
            }
            return .failed(kind: c.kind, message: c.message, stop: true)
        }
    }

    /// Failure kinds that will not clear within a job: ask no more chunks. The service's own kinds
    /// (`model_missing`, `timeout`, the mismatches, `malformed`: the request itself, `output_too_large`: the same
    /// chunk sizes all day) and the decoder's refusals that would repeat on every chunk (`schema`, `malformed`,
    /// `invalid_probabilities`). Not `nonfinite` / `malformed_json` (a NaN line costs one chunk) nor `internal`.
    static let stoppingServiceKinds: Set<String> = ["model_missing", "timeout", "checkpoint_mismatch", "config_mismatch",
                                                    "bundle_mismatch", "malformed", "output_too_large", "schema",
                                                    "invalid_probabilities"]

    static func classify(_ error: Error) -> (kind: String, message: String) {
        let message = String(String(describing: error).prefix(240))
        guard let e = error as? ActivityPythonService.ServiceError else { return ("internal", message) }
        switch e {
        case .timeout: return ("timeout", message)
        case .processDied: return ("crash", message)
        case .launchFailed: return ("launch_failed", message)
        case .restartCapExceeded, .restartCooldown: return ("restart_cooldown", message)
        case .requestTooLarge: return ("request_too_large", message)
        case .responseTooLarge: return ("output_too_large", message)
        case .malformedResponse(let detail):
            return (detail.contains("exceeds") ? "output_too_large" : "malformed_json", message)
        case .inferFailed(let kind, _): return (kind, message)
        case .modelUnavailable: return ("model_unavailable", message)
        }
    }
}

/// The shadow row (and candidate comparison) for one job.
enum ActivityMotionHeadsDays {

    /// The columnar `windows` (`mh-col-1`) above this are not stored (the summary says so); the row itself stays
    /// useful. A full day at a 5-s hop is about 470 KB, so a day per bundle stays at or under ~0.5 MB.
    static let maxWindowsBytes = 512 * 1024
    static let windowsFormat = "mh-col-1"
    /// Rows whose `computed_at` is older than this are deleted by `prune_activity_motion_heads_days`, which the
    /// lane calls while Inertia is on (`ActivityLane.pruneMotionHeadsIfDue`).
    static let retentionDays = 30
    static let pruneBatchRows = 10_000
    static let pruneSQL = "SELECT public.prune_activity_motion_heads_days($1::integer, $2::integer)::text"

    enum Candidate {
        /// Shadow mode: no second decode.
        case notRequested
        case withheld(String)
        /// The comparison document, and how its decode attached and used the windows.
        case document(ActivityContextDayDocument, MotionHeadsTrackReport?)
    }

    enum PublishOutcome: Equatable {
        case stored(revision: Int64)
        case fenced
        case rejected(String)
    }

    /// One head over the day's windows: per window the index of its top class in the head's supported-class
    /// order (`summary.class_order`, ties to the earlier class) and that class's probability in whole percent;
    /// -1 / 0 for a window that does not carry the head.
    struct HeadColumns: Encodable, Equatable {
        var i: [Int]
        var p: [Int]
    }

    /// The day's windows, columnar and in small integers (`mh-col-1`). `s0` is the first window start, `ds[k]`
    /// the start minus the previous one (0 first), every window is `w` seconds long; `x[k]` is 1 for an OOD
    /// window; `mi[k]` the movement intensity in percent (-1 absent). Every array has `n` entries.
    struct CompactWindows: Encodable, Equatable {
        var format = ActivityMotionHeadsDays.windowsFormat
        var n: Int
        var w: Int
        var s0: Int?
        var ds: [Int]
        var x: [Int]
        var mi: [Int]
        var heads: [String: HeadColumns]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(format, forKey: .format); try c.encode(n, forKey: .n); try c.encode(w, forKey: .w)
            if let s0 { try c.encode(s0, forKey: .s0) } else { try c.encodeNil(forKey: .s0) }
            try c.encode(ds, forKey: .ds); try c.encode(x, forKey: .x); try c.encode(mi, forKey: .mi)
            try c.encode(heads, forKey: .heads)
        }

        enum CodingKeys: String, CodingKey { case format, n, w, s0, ds, x, mi, heads }
    }

    /// A probability (or intensity) in whole percent, -1 when absent. The only Double → Int conversion here:
    /// clamped to [0, 1] first, so it can never trap.
    static func percent(_ x: Double?) -> Int {
        guard let x, x.isFinite else { return -1 }
        return Int((min(1, max(0, x)) * 100).rounded())
    }

    static func compact(_ windows: [MotionHeadsWindow], bundle: MotionHeadsBundleInfo,
                        order: [MotionHead: [String]]) -> CompactWindows {
        var ds: [Int] = [], x: [Int] = [], mi: [Int] = []
        ds.reserveCapacity(windows.count); x.reserveCapacity(windows.count); mi.reserveCapacity(windows.count)
        var columns: [MotionHead: HeadColumns] = [:]
        let carried = MotionHead.allCases.filter { !(order[$0] ?? []).isEmpty }
        for head in carried { columns[head] = HeadColumns(i: [], p: []) }
        var previous: Int?
        for win in windows {
            ds.append(previous.map { win.startTs - $0 } ?? 0)
            previous = win.startTs
            x.append(win.isOOD ? 1 : 0)
            mi.append(percent(win.movementIntensity))
            for head in carried {
                var best: (Int, Double)?
                if let probs = win.probabilities(head) {
                    for (k, cls) in (order[head] ?? []).enumerated() {
                        let p = probs[cls] ?? 0
                        if best == nil || p > best!.1 { best = (k, p) }
                    }
                }
                columns[head]!.i.append(best?.0 ?? -1)
                columns[head]!.p.append(best.map { percent($0.1) } ?? 0)
            }
        }
        var heads: [String: HeadColumns] = [:]
        for (head, c) in columns { heads[head.rawValue] = c }
        return CompactWindows(n: windows.count, w: bundle.windowS, s0: windows.first?.startTs, ds: ds, x: x, mi: mi,
                              heads: heads)
    }

    struct Summary: Encodable {
        var nWindows: Int
        var nOOD: Int
        var nDroppedNonfinite: Int
        var nChunks: Int
        var nFailedChunks: Int
        var failureKinds: [String: Int]
        var stopped: String?
        var classOrder: [String: [String]]
        var meanMovementIntensity: Double?
        /// Windows whose top class is each class (non-OOD windows only).
        var topClassWindows: [String: [String: Int]]
        /// Windows whose event probability is at least 0.5, per event (non-OOD windows only).
        var transitionEvents: [String: Int]
        var windowsOmitted: Bool
        var candidateStamp: String?
        /// How the windows met the day's observed seconds: the candidate decode's report in candidate mode, a
        /// dry-run attachment otherwise (attached / dropped counts; the decoder-side counters stay 0). nil when
        /// there was no decoder input to attach to (ActivityContext v2 off).
        var trackReport: MotionHeadsTrackReport?

        enum CodingKeys: String, CodingKey {
            case nWindows = "n_windows", nOOD = "n_ood", nDroppedNonfinite = "n_dropped_nonfinite"
            case nChunks = "n_chunks", nFailedChunks = "n_failed_chunks", failureKinds = "failure_kinds"
            case stopped, classOrder = "class_order", meanMovementIntensity = "mean_movement_intensity"
            case topClassWindows = "top_class_windows", transitionEvents = "transition_events"
            case windowsOmitted = "windows_omitted", candidateStamp = "candidate_stamp"
            case trackReport = "track_report"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(nWindows, forKey: .nWindows); try c.encode(nOOD, forKey: .nOOD)
            try c.encode(nDroppedNonfinite, forKey: .nDroppedNonfinite)
            try c.encode(nChunks, forKey: .nChunks); try c.encode(nFailedChunks, forKey: .nFailedChunks)
            try c.encode(failureKinds, forKey: .failureKinds)
            if let stopped { try c.encode(stopped, forKey: .stopped) } else { try c.encodeNil(forKey: .stopped) }
            try c.encode(classOrder, forKey: .classOrder)
            if let m = meanMovementIntensity { try c.encode(m, forKey: .meanMovementIntensity) }
            else { try c.encodeNil(forKey: .meanMovementIntensity) }
            try c.encode(topClassWindows, forKey: .topClassWindows)
            try c.encode(transitionEvents, forKey: .transitionEvents)
            try c.encode(windowsOmitted, forKey: .windowsOmitted)
            if let s = candidateStamp { try c.encode(s, forKey: .candidateStamp) } else { try c.encodeNil(forKey: .candidateStamp) }
            if let r = trackReport { try c.encode(r, forKey: .trackReport) } else { try c.encodeNil(forKey: .trackReport) }
        }
    }

    struct Payload: Encodable {
        var day: String
        var mode: String
        var schema = MotionHeadsWire.schema
        var bundle: MotionHeadsBundleInfo
        var summary: Summary
        var windows: CompactWindows?
        var withheldReason: String?
        var candidateDocument: ActivityContextDayDocument?

        enum CodingKeys: String, CodingKey {
            case day, mode, schema, bundle, summary, windows
            case withheldReason = "withheld_reason", candidateDocument = "candidate_document"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(day, forKey: .day); try c.encode(mode, forKey: .mode); try c.encode(schema, forKey: .schema)
            try c.encode(bundle, forKey: .bundle); try c.encode(summary, forKey: .summary)
            if let windows { try c.encode(windows, forKey: .windows) } else { try c.encodeNil(forKey: .windows) }
            if let withheldReason { try c.encode(withheldReason, forKey: .withheldReason) }
            else { try c.encodeNil(forKey: .withheldReason) }
            if let candidateDocument { try c.encode(candidateDocument, forKey: .candidateDocument) }
            else { try c.encodeNil(forKey: .candidateDocument) }
        }
    }

    static func rounded(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }

    /// The candidate comparison for one day: the same input the published v2 document was decoded from, plus
    /// the Inertia windows, decoded with Inertia as candidate evidence. Refused bundles are withheld, and so is
    /// everything when the deployment has not pinned the bundle digest (candidate mode requires the pin).
    /// `config` and `lookback` are the published document's (`ContextDayBuild.config` / `.lookback`: the wearer's
    /// reference as of the day and the warm-up half hour), so the comparison differs from it only by the expert.
    static func candidate(mode: InertiaSettings.Mode, heads: MotionHeadsTrackInput,
                          input: ActivityContextTrackInput?, generatedAt: Int,
                          expectedBundleSHA256: String?, config base: ActivityDecoderConfig = ActivityDecoderConfig(),
                          lookback: ActivityContextTrackInput? = nil) -> Candidate {
        guard mode == .candidate else { return .notRequested }
        guard let expectedBundleSHA256 else { return .withheld("bundle_sha256_not_pinned") }
        // The candidate defaults (INERTIA1.md §7).
        let evidence = MotionHeadsEvidenceConfig(mode: .candidate, bundle: heads.bundle,
                                                 expectedBundleSHA256: expectedBundleSHA256)
        if let why = evidence.evidenceRefusal { return .withheld(why) }
        guard var input else { return .withheld("context_days_disabled") }
        input.motionHeads = heads
        var config = base
        config.motionHeads = evidence
        let built = ActivityContextDays.dayDocumentAndReport(input: input, generatedAt: generatedAt, config: config,
                                                             lookback: lookback)
        // A comparison must name the evidence that shaped it; a decode the evidence never reached is withheld.
        guard built.document.versions.motionHeads != nil else {
            return .withheld(built.report?.refusal ?? "motion_heads_not_accepted")
        }
        return .document(built.document, built.report)
    }

    /// The RPC payload (sorted keys), or nil when no chunk produced a valid response. `attachment` is the
    /// dry-run attachment report used when there is no candidate decode (see `Summary.trackReport`).
    static func payload(day: String, mode: InertiaSettings.Mode, collector: MotionHeadsCollector,
                        candidate: Candidate, attachment: MotionHeadsTrackReport? = nil) throws -> String? {
        guard let heads = collector.trackInput else { return nil }
        let bundle = heads.bundle
        let order: [MotionHead: [String]] = Dictionary(uniqueKeysWithValues: MotionHead.allCases.map {
            ($0, bundle.heads[$0]?.supportedClasses ?? [])
        })
        var top: [String: [String: Int]] = [:]
        var events: [String: Int] = [:]
        var intensitySum = 0.0, intensityN = 0, ood = 0
        for w in heads.windows {
            if w.isOOD { ood += 1 } else {
                for head in [MotionHead.posture, .locomotion, .armBehavior] {
                    guard let probs = w.probabilities(head), let classes = order[head] else { continue }
                    var best: (String, Double)?
                    for c in classes { let p = probs[c] ?? 0; if best == nil || p > best!.1 { best = (c, p) } }
                    if let best { top[head.rawValue, default: [:]][best.0, default: 0] += 1 }
                }
                for (event, p) in (w.transition ?? [:]) where p >= 0.5 { events[event, default: 0] += 1 }
            }
            if let mi = w.movementIntensity { intensitySum += mi; intensityN += 1 }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let columnar = compact(heads.windows, bundle: bundle, order: order)
        let windows: CompactWindows? = try encoder.encode(columnar).count > maxWindowsBytes ? nil : columnar

        var withheld: String?, document: ActivityContextDayDocument?, stamp: String?
        var report = attachment
        switch candidate {
        case .notRequested: break
        case .withheld(let why): withheld = why
        case .document(let d, let r): document = d; stamp = d.versions.motionHeads; report = r ?? attachment
        }
        let summary = Summary(
            nWindows: heads.windows.count, nOOD: ood,
            nDroppedNonfinite: collector.responses.reduce(0) { $0 + $1.droppedNonfinite },
            nChunks: collector.chunks, nFailedChunks: collector.failedChunks, failureKinds: collector.failureKinds,
            stopped: collector.stopped,
            classOrder: Dictionary(uniqueKeysWithValues: order.map { ($0.key.rawValue, $0.value) }),
            meanMovementIntensity: intensityN > 0 ? rounded(intensitySum / Double(intensityN)) : nil,
            topClassWindows: top, transitionEvents: events, windowsOmitted: windows == nil, candidateStamp: stamp,
            trackReport: report)
        let payload = Payload(day: day, mode: mode.rawValue, bundle: bundle, summary: summary, windows: windows,
                              withheldReason: withheld, candidateDocument: document)
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkerError.malformed("motion heads payload encoding failed")
        }
        return text
    }

    /// Write the shadow row through its fenced RPC. Runs under a savepoint when a transaction is open, so a
    /// rejection (or a database without the migration) leaves the transaction usable for the publishes
    /// around it. Only a lost connection propagates.
    static func publish(db: PostgresClient, token: String, revision: Int64, payload: String) throws -> PublishOutcome {
        do {
            let out = try db.isolatingFailures {
                try db.callFunctionForJSONRaw(
                    "SELECT public.publish_activity_motion_heads_day($1::uuid,$2::bigint,$3::jsonb)::text",
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
