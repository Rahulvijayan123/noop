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
//   • a transport failure (timeout, crash, launch failure, restart cooldown) or `model_missing` stops Inertia
//     for the rest of that job, so a broken model costs at most one timeout per job;
//   • the shadow output (provenance + compact per-window predictions + OOD counts) is written to its OWN table
//     (`activity_motion_heads_days`) through its own fenced RPC under a savepoint, so a rejection or a missing
//     migration never reaches the v1 / v2 publishes in the same transaction;
//   • candidate mode additionally decodes the day a second time with Inertia as decoder evidence — only for a
//     real `inertia1` encoder whose bundle tier is at least `candidate`, otherwise the withheld reason is
//     stored — and keeps that comparison document beside the shadow row. It is never written to
//     `activity_context_days` / `activity_context_epochs`: the published HART documents are byte-identical
//     whether Inertia is enabled or not.

/// FRWHOOP_INERTIA_* settings. Off unless `FRWHOOP_INERTIA_ENABLED=1` and a bundle directory is configured.
struct InertiaSettings: Equatable {
    enum Mode: String, Equatable {
        case shadow, candidate
    }

    var enabled: Bool
    var mode: Mode
    var bundleDir: String?
    var checkpoint: String?
    var python: String
    var timeoutSeconds: Double
    /// Why Inertia stays off although it was asked for (a missing bundle dir, an unknown mode).
    var configurationError: String?

    static let serveModule = ["-m", "activity_context.inertia.serve"]

    /// FRWHOOP_INERTIA_ENABLED ("1" = on, default off), FRWHOOP_INERTIA_MODE (shadow | candidate, default
    /// shadow), FRWHOOP_INERTIA_BUNDLE_DIR (required when on), FRWHOOP_INERTIA_CHECKPOINT (passed as
    /// --checkpoint and INERTIA1_CKPT_PATH), FRWHOOP_INERTIA_PYTHON (default: the activity python),
    /// FRWHOOP_INERTIA_TIMEOUT_SECONDS (default 60). A setting that cannot be honoured switches Inertia off
    /// with a reason; it never stops the worker.
    static func fromEnvironment(_ env: [String: String], activityPython: String = "python3") -> InertiaSettings {
        func value(_ key: String) -> String? {
            env[key].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let asked = value("FRWHOOP_INERTIA_ENABLED") == "1"
        var settings = InertiaSettings(
            enabled: asked, mode: .shadow, bundleDir: value("FRWHOOP_INERTIA_BUNDLE_DIR"),
            checkpoint: value("FRWHOOP_INERTIA_CHECKPOINT"),
            python: value("FRWHOOP_INERTIA_PYTHON") ?? activityPython,
            timeoutSeconds: Double(value("FRWHOOP_INERTIA_TIMEOUT_SECONDS") ?? "60").flatMap { $0 > 0 ? $0 : nil } ?? 60,
            configurationError: nil)
        if let raw = value("FRWHOOP_INERTIA_MODE") {
            if let mode = Mode(rawValue: raw.lowercased()) { settings.mode = mode }
            else { settings.configurationError = "unknown FRWHOOP_INERTIA_MODE \(raw)" }
        }
        if asked, settings.bundleDir == nil, settings.configurationError == nil {
            settings.configurationError = "FRWHOOP_INERTIA_BUNDLE_DIR is required"
        }
        if settings.configurationError != nil { settings.enabled = false }
        return settings
    }

    static func serveArgs(bundleDir: String, checkpoint: String?) -> [String] {
        var args = serveModule + ["--bundle", bundleDir]
        if let checkpoint { args += ["--checkpoint", checkpoint] }
        return args
    }

    /// The service config of the Inertia child. Its own process, timeout, restart cap and response cap.
    func serviceConfig(activityHome: String) -> ActivityPythonService.Config? {
        guard enabled, let bundleDir else { return nil }
        var env: [String: String] = [:]
        if let checkpoint { env["INERTIA1_CKPT_PATH"] = checkpoint }
        return ActivityPythonService.Config(
            pythonBin: python, activityHome: activityHome, modelDir: nil,
            serveArgs: Self.serveArgs(bundleDir: bundleDir, checkpoint: checkpoint),
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

    enum Outcome: Equatable {
        case ok(MotionHeadsResponse)
        /// `stop` = do not ask again during this job.
        case failed(kind: String, message: String, stop: Bool)
    }

    /// Readiness at the start of a job: start the child if needed and ping it unless it is known to be up.
    /// nil = ready, otherwise the kind that keeps Inertia off for this job. Never throws.
    func begin() -> (kind: String, message: String)? {
        do {
            try service.ensureStarted()
            if !service.modelAvailable {
                let ping = try service.ping()
                guard ping.modelAvailable else {
                    return ("model_unavailable", "\(ping.modelStatus): \(ping.error ?? "")")
                }
            }
            return nil
        } catch {
            return Self.classify(error)
        }
    }

    /// Infer one chunk. Never throws: every failure comes back classified.
    func infer(_ request: ActivityPythonService.RunRequest) -> Outcome {
        do {
            let (object, line) = try service.inferRaw(run: request)
            let data: Data
            if let line { data = line }
            else { data = try JSONSerialization.data(withJSONObject: object) }
            return .ok(try MotionHeadsResponse.decode(data))
        } catch let e as MotionHeadsResponseError {
            let stop: Bool
            if case .serviceError(let kind, _) = e { stop = Self.stoppingServiceKinds.contains(kind) } else { stop = false }
            return .failed(kind: e.kind, message: String(String(describing: e).prefix(240)), stop: stop)
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

    /// Service error kinds that will not clear within a job: ask no more chunks.
    static let stoppingServiceKinds: Set<String> = ["model_missing", "timeout", "checkpoint_mismatch", "config_mismatch"]

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

    /// Encoded `windows` above this are not stored (the summary says so); the row itself stays useful.
    static let maxWindowsBytes = 6 * 1024 * 1024

    enum Candidate {
        /// Shadow mode: no second decode.
        case notRequested
        case withheld(String)
        case document(ActivityContextDayDocument)
    }

    enum PublishOutcome: Equatable {
        case stored(revision: Int64)
        case fenced
        case rejected(String)
    }

    /// One window, compact: probabilities as arrays in the bundle's supported-class order (`class_order` in
    /// the summary), rounded to 4 decimals; null for a head the window does not carry.
    struct CompactWindow: Encodable {
        var s: Int
        var e: Int
        var p: [Double]?
        var l: [Double]?
        var a: [Double]?
        var t: [Double]?
        var mi: Double?
        var ood: Double?
        var x: Bool

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(s, forKey: .s); try c.encode(e, forKey: .e)
            for (key, v) in [(CodingKeys.p, p), (.l, l), (.a, a), (.t, t)] {
                if let v { try c.encode(v, forKey: key) } else { try c.encodeNil(forKey: key) }
            }
            if let mi { try c.encode(mi, forKey: .mi) } else { try c.encodeNil(forKey: .mi) }
            if let ood { try c.encode(ood, forKey: .ood) } else { try c.encodeNil(forKey: .ood) }
            try c.encode(x, forKey: .x)
        }

        enum CodingKeys: String, CodingKey { case s, e, p, l, a, t, mi, ood, x }
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

        enum CodingKeys: String, CodingKey {
            case nWindows = "n_windows", nOOD = "n_ood", nDroppedNonfinite = "n_dropped_nonfinite"
            case nChunks = "n_chunks", nFailedChunks = "n_failed_chunks", failureKinds = "failure_kinds"
            case stopped, classOrder = "class_order", meanMovementIntensity = "mean_movement_intensity"
            case topClassWindows = "top_class_windows", transitionEvents = "transition_events"
            case windowsOmitted = "windows_omitted", candidateStamp = "candidate_stamp"
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
        }
    }

    struct Payload: Encodable {
        var day: String
        var mode: String
        var schema = MotionHeadsWire.schema
        var bundle: MotionHeadsBundleInfo
        var summary: Summary
        var windows: [CompactWindow]?
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
    /// the Inertia windows, decoded with Inertia as candidate evidence. Refused bundles are withheld.
    static func candidate(mode: InertiaSettings.Mode, heads: MotionHeadsTrackInput,
                          input: ActivityContextTrackInput?, generatedAt: Int) -> Candidate {
        guard mode == .candidate else { return .notRequested }
        let evidence = MotionHeadsEvidenceConfig.candidate(bundle: heads.bundle)
        if let why = evidence.evidenceRefusal { return .withheld(why) }
        guard var input else { return .withheld("context_days_disabled") }
        input.motionHeads = heads
        var config = ActivityDecoderConfig()
        config.motionHeads = evidence
        return .document(ActivityContextDays.dayDocument(input: input, generatedAt: generatedAt, config: config))
    }

    /// The RPC payload (sorted keys), or nil when no chunk produced a valid response.
    static func payload(day: String, mode: InertiaSettings.Mode, collector: MotionHeadsCollector,
                        candidate: Candidate) throws -> String? {
        guard let heads = collector.trackInput else { return nil }
        let bundle = heads.bundle
        let order: [MotionHead: [String]] = Dictionary(uniqueKeysWithValues: MotionHead.allCases.map {
            ($0, bundle.heads[$0]?.supportedClasses ?? [])
        })
        func array(_ head: MotionHead, _ w: MotionHeadsWindow) -> [Double]? {
            guard let probs = w.probabilities(head), let classes = order[head], !classes.isEmpty else { return nil }
            return classes.map { rounded(probs[$0] ?? 0) }
        }
        var top: [String: [String: Int]] = [:]
        var events: [String: Int] = [:]
        var intensitySum = 0.0, intensityN = 0, ood = 0
        let compact: [CompactWindow] = heads.windows.map { w in
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
            return CompactWindow(s: w.startTs, e: w.endTs, p: array(.posture, w), l: array(.locomotion, w),
                                 a: array(.armBehavior, w), t: array(.transition, w),
                                 mi: w.movementIntensity.map(rounded), ood: w.oodScore.map(rounded), x: w.isOOD)
        }
        var windows: [CompactWindow]? = compact
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if try encoder.encode(compact).count > maxWindowsBytes { windows = nil }

        var withheld: String?, document: ActivityContextDayDocument?, stamp: String?
        switch candidate {
        case .notRequested: break
        case .withheld(let why): withheld = why
        case .document(let d): document = d; stamp = d.versions.motionHeads
        }
        let summary = Summary(
            nWindows: heads.windows.count, nOOD: ood,
            nDroppedNonfinite: collector.responses.reduce(0) { $0 + $1.droppedNonfinite },
            nChunks: collector.chunks, nFailedChunks: collector.failedChunks, failureKinds: collector.failureKinds,
            stopped: collector.stopped,
            classOrder: Dictionary(uniqueKeysWithValues: order.map { ($0.key.rawValue, $0.value) }),
            meanMovementIntensity: intensityN > 0 ? rounded(intensitySum / Double(intensityN)) : nil,
            topClassWindows: top, transitionEvents: events, windowsOmitted: windows == nil, candidateStamp: stamp)
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
}
