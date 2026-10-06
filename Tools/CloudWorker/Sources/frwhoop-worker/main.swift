import Foundation
import CCrypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// frwhoop-worker: hosted compute worker for the FRWHOOP pipeline.
//
// Environment (no compiled-in secrets):
//   FRWHOOP_DB_URL               direct Postgres connection string
//   FRWHOOP_DB_SSLMODE           TLS mode (default verify-full; verify-ca allowed)
//   FRWHOOP_DB_SSLROOTCERT       CA bundle path (default: the Supabase project CA)
//   FRWHOOP_ALLOW_INSECURE_DB    "1" disables the TLS requirement (development only)
//   FRWHOOP_B2_KEY_ID            object storage application key id
//   FRWHOOP_B2_APPLICATION_KEY   object storage application key
//   FRWHOOP_B2_BUCKET            bucket name (default FRWHOOP)
//   FRWHOOP_INGEST_SECRET        internal ingest secret for engine_* calls
//   FRWHOOP_WORKER_NAME          heartbeat identity (default frwhoop-worker-2)
//   FRWHOOP_SOURCE_REVISION      deployed code revision (git sha)
//   FRWHOOP_PROJECTION_BUDGET    projection objects per wake (default 8)
//   FRWHOOP_SCORING_BUDGET       scoring days per wake (default 4)
//   FRWHOOP_ARCHIVE_BUDGET       archive jobs per wake (default 8)
//   FRWHOOP_VERIFY_BUDGET        verification debt items per wake (default 4)
//   FRWHOOP_RECONCILE_BUDGET     pending-object arrival reconciliations per wake (default 4)
//   FRWHOOP_ACTIVITY_ENABLED     "1" runs the activity lane (default OFF; lane only
//                                runs when enabled AND not disabled via DISABLE_LANES)
//   FRWHOOP_ACTIVITY_BUDGET      activity jobs per wake (default 2)
//   FRWHOOP_ACTIVITY_PYTHON      python interpreter for the activity service (default python3)
//   FRWHOOP_ACTIVITY_HOME        Tools/ActivityContext package root on the host
//   FRWHOOP_ACTIVITY_MODEL_DIR   model directory passed to the service (optional)
//   FRWHOOP_ACTIVITY_TIMEOUT_SECONDS  per-inference timeout for the python child (default 60)
//   FRWHOOP_ACTIVITY_LEASE_SECONDS    activity job lease length (default 300)
//   FRWHOOP_ACTIVITY_CONTEXT_V2  "0" stops the lane from also building and storing the ActivityContext v2
//                                day document (default ON when the activity lane is on; a database
//                                without public.activity_context_days just counts the skip)
//   FRWHOOP_ACTIVITY_STREAMS     "0" stops the lane from building a day document for every UTC day that has
//                                stored measurements (stream days; default ON when the activity lane is on;
//                                needs 20261003140000_activity_context_stream_days.sql, otherwise the lane
//                                notes the error once and retries every minute)
//   FRWHOOP_ACTIVITY_STREAM_BUDGET    stream-day jobs per wake (default 4)
//   FRWHOOP_ACTIVITY_IMU         "0" skips the raw-IMU jobs (no Python child, no model) and runs only the stream
//                                days; for a host that has neither (default ON)
//   FRWHOOP_INERTIA_ENABLED      1/true/yes/on also asks a SECOND Python child (`activity_context.inertia.serve`)
//                                for Inertia-1 motion heads on every raw-IMU chunk (default OFF; an unrecognised
//                                value keeps it off and is logged). Never gates claiming; any failure is counted
//                                and the HART path continues
//   FRWHOOP_INERTIA_MODE         shadow (default: store the heads in activity_motion_heads_days) | candidate
//                                (also store a second, Inertia-evidence decode of the day beside them; never
//                                published)
//   FRWHOOP_INERTIA_BUNDLE_DIR   head bundle directory (required when enabled)
//   FRWHOOP_INERTIA_BUNDLE_SHA256 the pinned bundle_sha256 (required in candidate mode; enforced in shadow mode
//                                when set): a child serving any other bundle is refused for the job, and it is
//                                passed to the child as --expect-bundle-sha256
//   FRWHOOP_INERTIA_CHECKPOINT   encoder checkpoint, passed as --checkpoint and INERTIA1_CKPT_PATH (optional)
//   FRWHOOP_INERTIA_PYTHON       interpreter for the Inertia child (default: FRWHOOP_ACTIVITY_PYTHON)
//   FRWHOOP_INERTIA_TIMEOUT_SECONDS per-request timeout of the Inertia child (default 60, clamped to a third of
//                                FRWHOOP_ACTIVITY_LEASE_SECONDS); the child gets --timeout 5 s below it
//   FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW 1/true/yes/on passes --allow-standin-shadow (default OFF; shadow mode
//                                only): exercises the shadow lane on real data with a stand-in encoder, whose
//                                rows are stored as encoder_kind standin and never feed the decoder
//   FRWHOOP_DISABLE_LANES        comma-separated lanes to skip (projection,scoring,archive,verify,activity);
//                                "series" keeps scoring but stops building and writing the dense intraday series
//   FRWHOOP_LEGACY_QUIET_SECONDS legacy-queue items wait until their owner has not uploaded for this long
//                                (default 20; 0 claims them immediately, as the queue did originally)
//   FRWHOOP_LEGACY_MAX_DEFER_SECONDS a legacy item is claimed regardless once it has waited this long (default 1800)
//   FRWHOOP_V2_INPUT_GATE_SECONDS the v2 scoring lane polls this long for its owner's scoring-input gate before
//                                claiming a job, so it takes locks in the order uploads do (default 10; 0 claims
//                                first, as the lane did originally)
//   FRWHOOP_POLL_INTERVAL_MS     idle poll interval (default 1000)
//   FRWHOOP_HEARTBEAT_INTERVAL_MS heartbeat interval (default 15000)
//   FRWHOOP_MAX_RUNTIME_SECONDS  exit after N seconds (0 = run forever; for scripted tests)
//
// Candidate (shadow/active) inference sidecar — OPTIONAL, and OFF by default:
//   FRWHOOP_INFERENCE_URL        loopback base URL of the inference sidecar
//                                (e.g. http://127.0.0.1:8787). UNSET OR EMPTY =
//                                the candidate lane is fully off: no client is
//                                built, no HTTP call is made, no extra SQL runs,
//                                and the canonical scoring path is unchanged.
//                                A non-loopback host is REFUSED at startup.
//   FRWHOOP_INFERENCE_TIMEOUT_MS sidecar request deadline (default 25000; keep it
//                                STRICTLY ABOVE the sidecar's own budget, which
//                                deploy/inference.env.example sets to 20000, so the
//                                sidecar's withheld/timeout verdict is the one that
//                                arrives instead of a client-side timeout)
//   FRWHOOP_INFERENCE_BUDGET     candidate runs per drain (default 2)
//   FRWHOOP_INFERENCE_ALLOW_NON_LOOPBACK  "1" allows a non-loopback host
//                                (tests / an explicitly approved private network)
//
// F7: every lane owns its own Postgres connection and runs on its own thread, so a
// slow object-storage wait in the archive lane cannot delay fresh scoring, and the
// heartbeat runs on the main thread independently of any lane's I/O. Each lane
// keeps its own budget. The heartbeat records the worker/process identity, the
// deployed revision, per-lane status and error, and the age of the oldest eligible
// queue item, and it distinguishes a blocked database from an empty poll.

setvbuf(stdout, nil, _IOLBF, 0)

struct WorkerConfig {
    let dbURL: String
    let b2KeyID: String
    let b2ApplicationKey: String
    let b2Bucket: String
    let ingestSecret: String
    let workerName: String
    let sourceRevision: String
    let projectionBudget: Int
    let scoringBudget: Int
    let archiveBudget: Int
    let verifyBudget: Int
    let reconcileBudget: Int
    let activityEnabled: Bool
    let activityBudget: Int
    let activityPython: String
    let activityHome: String
    let activityModelDir: String?
    let activityTimeoutSeconds: Double
    let activityLeaseSeconds: Int
    let activityContextV2: Bool
    let activityImu: Bool
    let activityStreams: Bool
    let activityStreamBudget: Int
    let inertia: InertiaSettings
    let disabledLanes: Set<String>
    let legacyQuietSeconds: Int
    let legacyMaxDeferSeconds: Int
    let v2InputGateSeconds: Int
    let pollIntervalMS: Int
    let heartbeatIntervalMS: Int
    let maxRuntimeSeconds: Double
    /// Loopback sidecar base URL. nil (or empty) means the candidate lane is OFF.
    let inferenceURL: String?
    let inferenceTimeoutMS: Int
    let inferenceBudget: Int

    /// True only when a sidecar URL is configured.
    var inferenceEnabled: Bool { inferenceURL != nil }

    init(environment: [String: String]) throws {
        guard let dbURL = environment["FRWHOOP_DB_URL"], !dbURL.isEmpty else {
            throw WorkerError.malformed("FRWHOOP_DB_URL is required")
        }
        guard let keyID = environment["FRWHOOP_B2_KEY_ID"], !keyID.isEmpty,
              let appKey = environment["FRWHOOP_B2_APPLICATION_KEY"], !appKey.isEmpty else {
            throw WorkerError.malformed("FRWHOOP_B2_KEY_ID and FRWHOOP_B2_APPLICATION_KEY are required")
        }
        guard let secret = environment["FRWHOOP_INGEST_SECRET"], !secret.isEmpty else {
            throw WorkerError.malformed("FRWHOOP_INGEST_SECRET is required")
        }
        self.dbURL = dbURL
        self.b2KeyID = keyID
        self.b2ApplicationKey = appKey
        self.b2Bucket = environment["FRWHOOP_B2_BUCKET"] ?? "FRWHOOP"
        self.ingestSecret = secret
        self.workerName = environment["FRWHOOP_WORKER_NAME"] ?? "frwhoop-worker-2"
        self.sourceRevision = environment["FRWHOOP_SOURCE_REVISION"] ?? "unknown"
        self.projectionBudget = Int(environment["FRWHOOP_PROJECTION_BUDGET"] ?? "8") ?? 8
        self.scoringBudget = Int(environment["FRWHOOP_SCORING_BUDGET"] ?? "4") ?? 4
        self.archiveBudget = Int(environment["FRWHOOP_ARCHIVE_BUDGET"] ?? "8") ?? 8
        self.verifyBudget = Int(environment["FRWHOOP_VERIFY_BUDGET"] ?? "4") ?? 4
        self.reconcileBudget = Int(environment["FRWHOOP_RECONCILE_BUDGET"] ?? "4") ?? 4
        // The activity lane is OFF by default: it only runs when explicitly
        // enabled (FRWHOOP_ACTIVITY_ENABLED=1) AND not disabled below.
        self.activityEnabled = (environment["FRWHOOP_ACTIVITY_ENABLED"] ?? "") == "1"
        self.activityBudget = Int(environment["FRWHOOP_ACTIVITY_BUDGET"] ?? "2") ?? 2
        self.activityPython = environment["FRWHOOP_ACTIVITY_PYTHON"] ?? "python3"
        self.activityHome = environment["FRWHOOP_ACTIVITY_HOME"]
            ?? FileManager.default.currentDirectoryPath + "/Tools/ActivityContext"
        self.activityModelDir = environment["FRWHOOP_ACTIVITY_MODEL_DIR"]
            .flatMap { $0.isEmpty ? nil : $0 }
        self.activityTimeoutSeconds = Double(environment["FRWHOOP_ACTIVITY_TIMEOUT_SECONDS"] ?? "60") ?? 60
        self.activityLeaseSeconds = Int(environment["FRWHOOP_ACTIVITY_LEASE_SECONDS"] ?? "300") ?? 300
        self.activityContextV2 = (environment["FRWHOOP_ACTIVITY_CONTEXT_V2"] ?? "1") != "0"
        self.activityImu = (environment["FRWHOOP_ACTIVITY_IMU"] ?? "1") != "0"
        self.activityStreams = (environment["FRWHOOP_ACTIVITY_STREAMS"] ?? "1") != "0"
        self.activityStreamBudget = max(1, Int(environment["FRWHOOP_ACTIVITY_STREAM_BUDGET"] ?? "4") ?? 4)
        self.inertia = InertiaSettings.fromEnvironment(environment, activityPython: self.activityPython,
                                                       leaseSeconds: self.activityLeaseSeconds)
        self.disabledLanes = Set(
            (environment["FRWHOOP_DISABLE_LANES"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })
        self.legacyQuietSeconds = max(0, Int(environment["FRWHOOP_LEGACY_QUIET_SECONDS"] ?? "")
            ?? ScoringLane.defaultLegacyQuietSeconds)
        self.legacyMaxDeferSeconds = max(1, Int(environment["FRWHOOP_LEGACY_MAX_DEFER_SECONDS"] ?? "")
            ?? ScoringLane.defaultLegacyMaxDeferSeconds)
        self.v2InputGateSeconds = max(0, Int(environment["FRWHOOP_V2_INPUT_GATE_SECONDS"] ?? "")
            ?? ScoringLane.defaultV2InputGateSeconds)
        self.pollIntervalMS = Int(environment["FRWHOOP_POLL_INTERVAL_MS"] ?? "1000") ?? 1000
        self.heartbeatIntervalMS = Int(environment["FRWHOOP_HEARTBEAT_INTERVAL_MS"] ?? "15000") ?? 15000
        self.maxRuntimeSeconds = Double(environment["FRWHOOP_MAX_RUNTIME_SECONDS"] ?? "0") ?? 0
        // An empty or absent URL is the OFF switch for the whole candidate lane:
        // nothing is constructed and nothing is called.
        let inferenceRaw = (environment["FRWHOOP_INFERENCE_URL"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.inferenceURL = inferenceRaw.isEmpty ? nil : inferenceRaw
        self.inferenceTimeoutMS = Int(environment["FRWHOOP_INFERENCE_TIMEOUT_MS"] ?? "")
            ?? InferenceClient.defaultTimeoutMS
        self.inferenceBudget = Int(environment["FRWHOOP_INFERENCE_BUDGET"] ?? "") ?? 2
    }
}

let env = ProcessInfo.processInfo.environment
let config: WorkerConfig
do {
    config = try WorkerConfig(environment: env)
} catch {
    FileHandle.standardError.write("frwhoop-worker: configuration error: \(error)\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - Startup connections
//
// Each lane gets its OWN connection: that is what makes the lanes independent, and
// it keeps the heartbeat able to report a blocked database while a lane is stalled.
let dbOptions: PostgresOptions
let dbHeartbeat: PostgresClient
let dbProjection: PostgresClient
let dbScoring: PostgresClient
let dbArchive: PostgresClient
let dbVerify: PostgresClient
let dbActivity: PostgresClient
let storage: B2Storage
do {
    dbOptions = try PostgresOptions.fromEnvironment(env)
    dbHeartbeat = try PostgresClient(options: dbOptions)
    dbProjection = try PostgresClient(options: dbOptions)
    dbScoring = try PostgresClient(options: dbOptions)
    dbArchive = try PostgresClient(options: dbOptions)
    dbVerify = try PostgresClient(options: dbOptions)
    dbActivity = try PostgresClient(options: dbOptions)
    storage = B2Storage(keyID: config.b2KeyID, applicationKey: config.b2ApplicationKey, bucket: config.b2Bucket)
} catch {
    FileHandle.standardError.write("frwhoop-worker: startup failed: \(error)\n".data(using: .utf8)!)
    exit(3)
}

let startupLine = "frwhoop-worker: started name=\(config.workerName) revision=\(config.sourceRevision) "
    + "sslmode=\(dbOptions.sslMode) sslrootcert=\(dbOptions.sslRootCert ?? "(system store)")\n"
FileHandle.standardOutput.write(startupLine.data(using: .utf8)!)

// MARK: - Shutdown
//
// The signal handler only writes one word (async-signal-safe). The main loop turns
// that into a lock-protected flag the lane threads can read.
private var terminationRequested: Int32 = 0
signal(SIGTERM) { _ in terminationRequested = 1 }
signal(SIGINT) { _ in terminationRequested = 1 }

final class ShutdownFlag {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
let shutdown = ShutdownFlag()

// MARK: - Lane status shared with the heartbeat

struct LaneSnapshot {
    var name: String
    var enabled: Bool
    var counters: [String: Int] = [:]
    var lastError: String?
    var lastErrorKind: String?
    var lastActivityAt: Date?
    /// True when the lane could not reach the database on its last cycle.
    var dbBlocked = false
}

final class LaneState {
    private let lock = NSLock()
    private var snapshot: LaneSnapshot
    init(_ snapshot: LaneSnapshot) { self.snapshot = snapshot }
    func update(_ body: (inout LaneSnapshot) -> Void) {
        lock.lock(); body(&snapshot); lock.unlock()
    }
    func read() -> LaneSnapshot {
        lock.lock(); defer { lock.unlock() }; return snapshot
    }
}

func laneEnabled(_ name: String) -> Bool { !config.disabledLanes.contains(name) }

let projectionState = LaneState(LaneSnapshot(name: "projection", enabled: laneEnabled("projection")))
let scoringState = LaneState(LaneSnapshot(name: "scoring", enabled: laneEnabled("scoring")))
let archiveState = LaneState(LaneSnapshot(name: "archive", enabled: laneEnabled("archive")))
let verifyState = LaneState(LaneSnapshot(name: "verify", enabled: laneEnabled("verify")))
// The activity lane is opt-in: it must be enabled by FRWHOOP_ACTIVITY_ENABLED
// AND not disabled via FRWHOOP_DISABLE_LANES. A disabled/unenabled activity
// lane must not affect any other lane, so it is simply never started.
let activityState = LaneState(LaneSnapshot(
    name: "activity",
    enabled: config.activityEnabled && laneEnabled("activity")))

let startedAt = Date()
let processInstanceID = UUID().uuidString.lowercased()

/// A stable per-worker UUID so a worker's health row is the same row across
/// restarts, while `process_instance_id` distinguishes this process.
func stableInstanceUUID(_ name: String) -> String {
    var digest = [UInt8](repeating: 0, count: 32)
    let bytes = Array(Data(("frwhoop-worker-instance:" + name).utf8))
    bytes.withUnsafeBytes { ptr in
        _ = SHA256(ptr.baseAddress, ptr.count, &digest)
    }
    var b = Array(digest[0..<16])
    b[6] = (b[6] & 0x0F) | 0x50
    b[8] = (b[8] & 0x3F) | 0x80
    let hex = b.map { String(format: "%02x", $0) }.joined()
    func slice(_ from: Int, _ to: Int) -> String {
        let start = hex.index(hex.startIndex, offsetBy: from)
        let end = hex.index(hex.startIndex, offsetBy: to)
        return String(hex[start..<end])
    }
    return "\(slice(0,8))-\(slice(8,12))-\(slice(12,16))-\(slice(16,20))-\(slice(20,32))"
}
let workerInstanceID = stableInstanceUUID(config.workerName)

/// `physiology_worker_heartbeats.source_revision` is CHECKed against
/// `^[0-9a-f]{40}$`, so a placeholder revision must still be a 40-hex string.
func normalizedRevision(_ revision: String) -> String {
    let lower = revision.lowercased()
    if lower.count == 40, lower.allSatisfy({ $0.isHexDigit }) { return lower }
    var digest = [UInt8](repeating: 0, count: 32)
    let bytes = Array(Data(("frwhoop-worker-revision:" + revision).utf8))
    bytes.withUnsafeBytes { ptr in
        _ = SHA256(ptr.baseAddress, ptr.count, &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined().prefix(40).description
}
let deployedRevision = normalizedRevision(config.sourceRevision)

/// `physiology_worker_heartbeats.last_error` is CHECKed against
/// `^[A-Za-z][A-Za-z0-9_.:-]{0,127}$`: no spaces, no parentheses, bounded length.
func sanitizedHealthError(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    var out = ""
    for scalar in text.unicodeScalars {
        let c = Character(scalar)
        if c.isLetter || c.isNumber || c == "." || c == "_" || c == ":" || c == "-" {
            out.append(c)
        } else if c == " " {
            out.append("_")
        }
        if out.count >= 127 { break }
    }
    guard let first = out.first, first.isLetter else { return nil }
    return out
}

// MARK: - Lane threads

/// Run one lane forever on its own thread and connection. `cycle` returns true
/// when it did work (so the lane can skip the idle sleep).
func runLane(_ state: LaneState,
             cycle: @escaping () throws -> Bool,
             ensureConnected: @escaping () throws -> Void) {
    let idle = Double(config.pollIntervalMS) / 1000.0
    while !shutdown.isSet {
        do {
            try ensureConnected()
            state.update { $0.dbBlocked = false }
        } catch {
            state.update {
                $0.dbBlocked = true
                $0.lastError = String(describing: error).prefix(2000).description
                $0.lastErrorKind = (error as? PostgresClient.Error)?.kind.rawValue ?? "other"
            }
            Thread.sleep(forTimeInterval: min(5.0, idle))
            continue
        }
        let didWork: Bool
        do {
            didWork = try cycle()
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            state.update {
                $0.dbBlocked = true
                $0.lastError = String(describing: e).prefix(2000).description
                $0.lastErrorKind = e.kind.rawValue
            }
            Thread.sleep(forTimeInterval: min(5.0, idle))
            continue
        } catch {
            state.update {
                $0.lastError = String(describing: error).prefix(2000).description
                $0.lastErrorKind = (error as? PostgresClient.Error)?.kind.rawValue ?? "other"
            }
            Thread.sleep(forTimeInterval: idle)
            continue
        }
        if !didWork { Thread.sleep(forTimeInterval: idle) }
    }
}

var projection = ProjectionLane(db: dbProjection, storage: storage)
var scoring = ScoringLane(db: dbScoring, scorer: DayScorer(db: dbScoring), ingestSecret: config.ingestSecret,
                          publishesSeries: laneEnabled("series"),
                          legacyQuietSeconds: config.legacyQuietSeconds,
                          legacyMaxDeferSeconds: config.legacyMaxDeferSeconds,
                          v2InputGateSeconds: config.v2InputGateSeconds)
var archive = ArchiveLane(db: dbArchive, storage: storage)
var verify = VerificationLane(db: dbVerify, storage: storage)
var activity = ActivityLane(
    db: dbActivity, storage: storage,
    service: ActivityPythonService(config: ActivityPythonService.Config(
        pythonBin: config.activityPython,
        activityHome: config.activityHome,
        modelDir: config.activityModelDir,
        serveArgs: ActivityPythonService.Config.serveArgs(modelDir: config.activityModelDir),
        requestTimeoutSeconds: config.activityTimeoutSeconds,
        maxRequestBytes: 64 * 1024 * 1024,
        maxResponseLineBytes: 16 * 1024 * 1024,
        restartCap: 8,
        restartCooldownSeconds: 30)),
    leaseSeconds: config.activityLeaseSeconds,
    imuJobsEnabled: config.activityImu,
    contextDaysEnabled: config.activityContextV2,
    streamDaysEnabled: config.activityStreams,
    streamDayBudget: config.activityStreamBudget,
    inertia: config.inertia.serviceConfig(activityHome: config.activityHome).map {
        InertiaStage(service: ActivityPythonService(config: $0), mode: config.inertia.mode,
                     expectedBundleSHA256: config.inertia.bundleSHA256)
    })
for warning in config.inertia.warnings {
    FileHandle.standardError.write("frwhoop-worker: inertia: \(warning)\n".data(using: .utf8)!)
}
if let why = config.inertia.configurationError {
    FileHandle.standardError.write("frwhoop-worker: inertia stays off: \(why)\n".data(using: .utf8)!)
} else if config.inertia.enabled {
    FileHandle.standardError.write(
        ("frwhoop-worker: inertia \(config.inertia.mode.rawValue) enabled (bundle \(config.inertia.bundleDir ?? "-"), "
            + "pinned \(config.inertia.bundleSHA256 ?? "no")\(config.inertia.allowStandInShadow ? ", stand-in shadow" : ""), "
            + "timeout \(config.inertia.timeoutSeconds) s)\n").data(using: .utf8)!)
}

// MARK: - Candidate (shadow/active) inference lane wiring
//
// The candidate lane is OPTIONAL and OFF unless FRWHOOP_INFERENCE_URL is set.
// When it is set, the URL is validated as loopback here: a non-loopback host is
// refused (the sidecar must never be reachable off-host), and the refusal is
// reported through the heartbeat rather than crashing the worker — scoring,
// archiving and the heartbeat must keep running with candidates unavailable.
let inferenceClient: InferenceClient?
var inferenceConfigError: String?
if let rawURL = config.inferenceURL {
    do {
        let allowNonLoopback = (env[InferenceEndpoint.allowNonLoopbackEnvKey] ?? "") == "1"
        let url = try InferenceEndpoint.parse(rawURL, allowNonLoopback: allowNonLoopback)
        inferenceClient = InferenceClient(baseURL: url, timeoutMS: config.inferenceTimeoutMS)
    } catch {
        inferenceClient = nil
        inferenceConfigError = String(describing: error)
        FileHandle.standardError.write(
            "frwhoop-worker: candidate inference lane disabled: \(error)\n".data(using: .utf8)!)
    }
} else {
    inferenceClient = nil
}

if let inferenceClient {
    scoring.candidate = CandidateStage(client: inferenceClient,
                                       store: PostgresCandidateStore(db: dbScoring))
    scoring.candidateBudget = config.inferenceBudget
    FileHandle.standardOutput.write(
        ("frwhoop-worker: candidate inference lane enabled url=\(inferenceClient.baseURL.absoluteString) "
         + "timeout_ms=\(inferenceClient.timeoutMS) budget=\(config.inferenceBudget)\n")
            .data(using: .utf8)!)
} else if inferenceConfigError == nil {
    FileHandle.standardOutput.write(
        "frwhoop-worker: candidate inference lane off (FRWHOOP_INFERENCE_URL unset)\n"
            .data(using: .utf8)!)
}

let laneQueue = DispatchQueue(label: "frwhoop.lanes", attributes: .concurrent)

if laneEnabled("projection") {
    laneQueue.async {
        runLane(projectionState, cycle: {
            let before = projection.stats.completed
            projection.drain(budget: config.projectionBudget)
            projectionState.update {
                $0.counters = [
                    "claimed": projection.stats.claimed,
                    "completed": projection.stats.completed,
                    "failed": projection.stats.failed,
                ]
                $0.lastError = projection.stats.lastError
                $0.lastActivityAt = projection.stats.lastCompletedAt
            }
            return projection.stats.completed > before
        }, ensureConnected: { try dbProjection.ensureConnected() })
    }
}

if laneEnabled("scoring") {
    laneQueue.async {
        runLane(scoringState, cycle: {
            let before = scoring.stats.completed + scoring.stats.superseded
            scoring.drain(budget: config.scoringBudget)
            scoringState.update {
                var counters: [String: Int] = [
                    "claimed": scoring.stats.claimed,
                    "completed": scoring.stats.completed,
                    "failed": scoring.stats.failed,
                    "superseded": scoring.stats.superseded,
                    "not_completed": scoring.stats.notCompleted,
                    "legacy_deferred": scoring.stats.legacyDeferred,
                    "gate_taken": scoring.stats.gateTaken,
                    "gate_wait_ms": scoring.stats.gateWaitMillis,
                    "gate_skipped": scoring.stats.gateSkipped,
                    "failures_persisted": scoring.stats.failuresPersisted,
                    "failures_unsettled": scoring.stats.failuresUnsettled,
                    "series_published": scoring.stats.seriesPublished,
                    "series_rows_written": scoring.stats.seriesRowsWritten,
                    "series_skipped": scoring.stats.seriesSkipped,
                    "series_failed": scoring.stats.seriesFailed,
                ]
                // Candidate counters appear ONLY when the lane is on, so an
                // off-mode heartbeat payload is unchanged.
                if let candidate = scoring.candidate?.stats {
                    counters["candidate_runs"] = candidate.runs
                    counters["candidate_calls"] = candidate.calls
                    counters["candidate_ok"] = candidate.ok
                    counters["candidate_withheld"] = candidate.withheld
                    counters["candidate_recorded"] = candidate.recorded
                    counters["candidate_duplicates"] = candidate.duplicates
                    counters["candidate_write_failures"] = candidate.writeFailures
                    counters["candidate_skipped_stale_debt"] = candidate.skippedStaleDebt
                    counters["candidate_skipped_deleted_user"] = candidate.skippedDeletedUser
                    counters["candidate_skipped_no_input"] = candidate.skippedNoInput
                    counters["candidate_skipped_budget"] = candidate.skippedBudget
                    counters["candidate_skipped_deadline"] = candidate.skippedDeadline
                    counters["active_promotions_deferred"] = scoring.stats.activePromotionsDeferred
                }
                $0.counters = counters
                $0.lastError = scoring.stats.lastError
                $0.lastErrorKind = scoring.stats.lastErrorKind?.rawValue
                $0.lastActivityAt = scoring.stats.lastScoreAt
            }
            return (scoring.stats.completed + scoring.stats.superseded) > before
        }, ensureConnected: { try dbScoring.ensureConnected() })
    }
}

if laneEnabled("archive") {
    laneQueue.async {
        runLane(archiveState, cycle: {
            let before = archive.stats.uploaded
            archive.drain(budget: config.archiveBudget)
            archiveState.update {
                $0.counters = [
                    "uploaded": archive.stats.uploaded,
                    "not_completed": archive.stats.notCompleted,
                    "lease_lost": archive.stats.leaseLost,
                    "failed": archive.stats.failed,
                ]
                $0.lastError = archive.stats.lastError
                $0.lastErrorKind = archive.stats.lastErrorKind?.rawValue
            }
            return archive.stats.uploaded > before
        }, ensureConnected: { try dbArchive.ensureConnected() })
    }
}

if laneEnabled("verify") {
    laneQueue.async {
        runLane(verifyState, cycle: {
            let before = verify.stats.completed
            verify.drain(budget: config.verifyBudget)
            verifyState.update {
                $0.counters = [
                    "claimed": verify.stats.claimed,
                    "completed": verify.stats.completed,
                    "failed": verify.stats.failed,
                ]
                $0.lastError = verify.stats.lastError
                $0.lastActivityAt = verify.stats.lastCompletedAt
            }
            return verify.stats.completed > before
        }, ensureConnected: { try dbVerify.ensureConnected() })
    }
}

if activityState.read().enabled {
    laneQueue.async {
        runLane(activityState, cycle: {
            let before = activity.stats.completed + activity.stats.superseded
                + activity.stats.streamDaysPublished + activity.stats.streamDaysEmpty
                + activity.stats.streamDaysSuperseded
            activity.drain(budget: config.activityBudget)
            activityState.update {
                $0.counters = [
                    "claimed": activity.stats.claimed,
                    "completed": activity.stats.completed,
                    "failed": activity.stats.failed,
                    "superseded": activity.stats.superseded,
                    "not_completed": activity.stats.notCompleted,
                    "failures_persisted": activity.stats.failuresPersisted,
                    "failures_unsettled": activity.stats.failuresUnsettled,
                    "model_unavailable": activity.stats.modelUnavailable,
                    "windows_inferred": activity.stats.windowsInferred,
                    "context_days_published": activity.stats.contextDaysPublished,
                    "context_day_failures": activity.stats.contextDayFailures,
                    "stream_days_enqueued": activity.stats.streamDaysEnqueued,
                    "stream_days_claimed": activity.stats.streamDaysClaimed,
                    "stream_days_published": activity.stats.streamDaysPublished,
                    "stream_days_empty": activity.stats.streamDaysEmpty,
                    "stream_days_superseded": activity.stats.streamDaysSuperseded,
                    "stream_day_failures": activity.stats.streamDayFailures,
                ]
                // Only with Inertia on, so the heartbeat of a worker without it is unchanged.
                if activity.inertia != nil {
                    $0.counters["inertia_jobs"] = activity.stats.inertiaJobs
                    $0.counters["inertia_chunks"] = activity.stats.inertiaChunks
                    $0.counters["inertia_windows"] = activity.stats.inertiaWindows
                    $0.counters["inertia_failures"] = activity.stats.inertiaFailures
                    $0.counters["inertia_unavailable"] = activity.stats.inertiaUnavailable
                    $0.counters["inertia_shadow_stored"] = activity.stats.inertiaShadowStored
                    $0.counters["inertia_shadow_failures"] = activity.stats.inertiaShadowFailures
                    $0.counters["inertia_candidate_documents"] = activity.stats.inertiaCandidateDocuments
                    $0.counters["inertia_candidate_withheld"] = activity.stats.inertiaCandidateWithheld
                    $0.counters["inertia_shadow_fenced"] = activity.stats.inertiaShadowFenced
                    $0.counters["inertia_bundle_refused"] = activity.stats.inertiaBundleRefused
                    $0.counters["inertia_windows_attached"] = activity.stats.inertiaWindowsAttached
                    $0.counters["inertia_windows_dropped"] = activity.stats.inertiaWindowsDropped
                    $0.counters["inertia_posture_omitted"] = activity.stats.inertiaPostureOmitted
                    $0.counters["inertia_rows_pruned"] = activity.stats.inertiaRowsPruned
                    $0.counters["inertia_prune_failures"] = activity.stats.inertiaPruneFailures
                }
                $0.lastError = activity.stats.lastError
                $0.lastErrorKind = activity.stats.lastErrorKind
                $0.lastActivityAt = activity.stats.lastActivityAt
            }
            return (activity.stats.completed + activity.stats.superseded
                + activity.stats.streamDaysPublished + activity.stats.streamDaysEmpty
                + activity.stats.streamDaysSuperseded) > before
        }, ensureConnected: { try dbActivity.ensureConnected() })
    }
}

// MARK: - Heartbeat

/// Cached sidecar readiness for the heartbeat payload.
///
/// Readiness polling is BOUNDED and CACHED: the probe uses a short deadline
/// (<= 2.5 s by default) and at most one probe per `ttl` (30 s), so a stalled
/// sidecar can never delay the worker's own liveness proof. Only the main thread
/// touches this object (the heartbeat runs there), so no lock is needed.
final class InferenceReadiness {
    private var checkedAt: Date?
    private var ready = false
    private var providers: [String: Any] = [:]
    private var lastError: String?
    private var lastCheckMS = 0

    func refresh(client: InferenceClient, ttl: TimeInterval) {
        if let checkedAt, Date().timeIntervalSince(checkedAt) < ttl { return }
        let started = Date()
        do {
            let health = try client.healthz()
            ready = health.ready
            var map: [String: Any] = [:]
            for (name, provider) in health.providers ?? [:] {
                var entry: [String: Any] = ["ready": provider.ready]
                if let version = provider.version { entry["version"] = version }
                if let reason = provider.reason { entry["reason"] = reason }
                map[name] = entry
            }
            providers = map
            lastError = nil
        } catch {
            // A readiness probe failure is not a worker failure: it only means the
            // candidate lane cannot compute right now.
            ready = false
            providers = [:]
            lastError = String(describing: error).prefix(300).description
        }
        lastCheckMS = Int(Date().timeIntervalSince(started) * 1000)
        checkedAt = Date()
    }

    func payload() -> [String: Any] {
        var out: [String: Any] = ["ready": ready, "providers": providers, "check_ms": lastCheckMS]
        if let checkedAt { out["checked_at"] = ISO8601DateFormatter().string(from: checkedAt) }
        if let lastError { out["last_error"] = lastError }
        return out
    }
}

let inferenceReadiness = InferenceReadiness()

/// The `inference` member of the heartbeat meta.
///
/// * candidate lane off (URL unset) -> JSON `null`, which is the documented
///   "off" encoding for this field;
/// * candidate lane on -> readiness plus per-lane candidate counters;
/// * a configured-but-refused URL -> `enabled:false` plus `config_error`, so a
///   misconfiguration is visible in monitoring instead of looking like "off".
func inferenceHeartbeatMeta() -> Any {
    guard let inferenceClient else {
        if let inferenceConfigError {
            return ["enabled": false, "config_error": inferenceConfigError] as [String: Any]
        }
        return NSNull()
    }
    inferenceReadiness.refresh(client: inferenceClient, ttl: 30)
    var entry = inferenceReadiness.payload()
    entry["enabled"] = true
    entry["url"] = inferenceClient.baseURL.absoluteString
    entry["timeout_ms"] = inferenceClient.timeoutMS
    entry["budget"] = config.inferenceBudget
    if let stats = scoring.candidate?.stats {
        entry["candidate"] = [
            "runs": stats.runs,
            "calls": stats.calls,
            "ok": stats.ok,
            "withheld": stats.withheld,
            "errors": stats.errors,
            "recorded": stats.recorded,
            "duplicates": stats.duplicates,
            "write_failures": stats.writeFailures,
            "skipped_off": stats.skippedOff,
            "skipped_stale_debt": stats.skippedStaleDebt,
            "skipped_deleted_user": stats.skippedDeletedUser,
            "skipped_no_input": stats.skippedNoInput,
            "skipped_budget": stats.skippedBudget,
            "skipped_deadline": stats.skippedDeadline,
            "active_substitutions": stats.activeSubstitutions,
            "active_promotions_deferred": scoring.stats.activePromotionsDeferred,
        ] as [String: Any]
        if let lastError = stats.lastError { entry["candidate_last_error"] = String(lastError.prefix(300)) }
        if let provider = stats.lastProviderId { entry["candidate_last_provider"] = provider }
        if let reason = stats.lastWithheldReason { entry["candidate_last_withheld_reason"] = reason }
    }
    return entry
}

/// Compose the heartbeat queue-age query. Aggregate only: no user data.
///
/// The activity entry is a STATIC reference to `public.activity_context_jobs`,
/// which fails the WHOLE query at parse time when the table does not exist
/// yet (deploy order: worker first, migration later) — a `to_regclass` guard
/// in a WHERE clause cannot help because Postgres resolves relation names
/// during analysis. The caller probes `to_regclass` and includes the entry
/// only when the table is present, so the heartbeat stays green pre/post
/// migration (audit P3-1).
///
/// The SQL fragments are LOCAL constants inside this function, never module
/// globals: globals in an executable target's main.swift are initialized by
/// that target's `main`, so a test bundle that never runs `main` reads
/// uninitialized storage (crash/garbage). Keeping the composition pure makes
/// the pre/post-migration behavior directly unit-testable.
func queueAgeQuery(includeActivity: Bool) -> String {
    let base = """
with q as (
  select 'scoring_legacy' as lane, count(*) as n, min(w.next_attempt_at) as oldest
    from public.scoring_work_items w
    join public.devices d on d.id = w.device_id and d.user_id = w.user_id and d.is_active
   where w.done_at is null and w.next_attempt_at <= now()
     and (w.lease_expires_at is null or w.lease_expires_at <= now())
  union all
  select 'scoring_v2', count(*), min(j.not_before)
    from public.scoring_jobs_v2 j
   where j.completed_revision < j.input_revision and not j.dead_letter
     and j.not_before <= now() and (j.lease_until is null or j.lease_until <= now())
     -- Same gates the claim applies (audit P1-7): invalidation-blocked and
     -- disabled-algorithm rows are SUPPRESSED, not claimable, so they must
     -- not count as backlog here (the previous predicate reported a false
     -- 8.2-day backlog while every row was invalidation-suppressed).
     and exists(select 1 from public.scoring_algorithms_v2 a
                  where a.algorithm_version = j.algorithm_version and a.enabled)
     and not exists(select 1 from public.scoring_invalidations_v2 i
                  where i.user_id = j.user_id and i.device_id = j.device_id
                    and i.algorithm_version = j.algorithm_version
                    and j.day between i.next_day and i.through_day)
  union all
  select 'projection', count(*), min(p.not_before)
    from public.noop_projection_debt p
    join public.object_manifests o on o.id = p.object_id
   where p.state = 'pending' and p.not_before <= now()
     and (p.lease_until is null or p.lease_until <= now())
     and o.status in ('ready','verified') and o.durability_receipt->>'state' = 'verified_indexed'
  union all
  select 'archive_outbox', count(*), min(a.next_attempt_at)
    from public.physiology_archive_outbox a
   where a.status in ('pending','retry','uploading') and a.next_attempt_at <= now()
     and (a.lease_expires_at is null or a.lease_expires_at <= now())
  union all
  select 'archive_v2', count(*), min(s.not_before)
    from public.scoring_archive_jobs_v2 s
   where s.completed_at is null and not s.dead_letter and s.not_before <= now()
     and (s.lease_until is null or s.lease_until <= now())
  union all
  select 'verification', count(*), min(v.next_attempt_at)
    from public.noop_object_verification_debt v
   where v.state in ('pending','retry','leased') and v.next_attempt_at <= now()
     and (v.state <> 'leased' or v.lease_until <= now())
"""
    let activity = """
  union all
  -- Activity jobs: same eligibility gates the claim applies (not
  -- dead-lettered, not_before reached, lease expired, completed < input
  -- revision).
  select 'activity', count(*), min(j.not_before)
    from public.activity_context_jobs j
   where j.completed_revision < j.input_revision and not j.dead_letter
     and j.not_before <= now() and (j.lease_until is null or j.lease_until <= now())
"""
    let closing = """
)
select lane, n::text as n,
       case when oldest is null then ''
            else greatest(0, extract(epoch from (now() - oldest))::bigint)::text end as age_seconds
  from q
"""
    return base + (includeActivity ? activity : "") + closing
}


struct QueueAge {
    var counts: [String: Int] = [:]
    var ages: [String: Int] = [:]
    var oldestSeconds: Int?
}

func queueAge() throws -> QueueAge {
    // Pre-migration (deploy order: worker first, migration later) the
    // activity tables do not exist; a static reference to them would fail the
    // whole heartbeat query at parse time. Probe to_regclass and append the
    // activity entry only when the table is present (audit P3-1).
    let activityTablePresent = (try? dbHeartbeat.query(
        "select to_regclass('public.activity_context_jobs') is not null as present", []))?
        .first?["present"] == "t"
    let rows = try dbHeartbeat.query(queueAgeQuery(includeActivity: activityTablePresent), [])
    var out = QueueAge()
    for row in rows {
        let lane = row["lane"] ?? ""
        guard !lane.isEmpty else { continue }
        out.counts[lane] = Int(row["n"] ?? "") ?? 0
        if let age = Int(row["age_seconds"] ?? "") {
            out.ages[lane] = age
            out.oldestSeconds = max(out.oldestSeconds ?? 0, age)
        }
    }
    return out
}

/// What the worker as a whole is doing, so "no work" is never confused with
/// "cannot reach the database".
func pollState(_ lanes: [LaneSnapshot], queue: QueueAge?, dbError: String?) -> String {
    if dbError != nil { return "db_blocked" }
    if lanes.contains(where: { $0.dbBlocked }) { return "db_blocked" }
    if lanes.allSatisfy({ !$0.enabled }) { return "disabled" }
    if let queue, queue.counts.values.reduce(0, +) > 0 { return "working" }
    return "idle"
}

var lastHeartbeat = Date.distantPast
var heartbeatFailures = 0

func heartbeat(final: Bool = false) {
    let lanes = [projectionState.read(), scoringState.read(), archiveState.read(),
                 verifyState.read(), activityState.read()]
    var dbError: String?
    var queue: QueueAge?
    do {
        try dbHeartbeat.ensureConnected()
        queue = try queueAge()
    } catch {
        dbError = String(describing: error)
    }

    let laneJSON: [[String: Any]] = lanes.map { lane in
        var entry: [String: Any] = [
            "name": lane.name,
            "enabled": lane.enabled,
            "db_blocked": lane.dbBlocked,
            "counters": lane.counters,
        ]
        if let err = lane.lastError { entry["last_error"] = String(err.prefix(400)) }
        if let kind = lane.lastErrorKind { entry["last_error_kind"] = kind }
        if let at = lane.lastActivityAt {
            entry["last_activity_at"] = ISO8601DateFormatter().string(from: at)
        }
        return entry
    }
    let firstLaneError = lanes.compactMap { $0.lastError }.first

    var meta: [String: Any] = [
        "worker_name": config.workerName,
        "worker_instance_id": workerInstanceID,
        "process_instance_id": processInstanceID,
        "pid": ProcessInfo.processInfo.processIdentifier,
        "host": ProcessInfo.processInfo.hostName,
        "source_revision": config.sourceRevision,
        "deployed_revision": deployedRevision,
        "started_at": ISO8601DateFormatter().string(from: startedAt),
        "uptime_seconds": Int(Date().timeIntervalSince(startedAt)),
        "poll_state": pollState(lanes, queue: queue, dbError: dbError),
        "lanes": laneJSON,
        "budgets": [
            "projection": config.projectionBudget,
            "scoring": config.scoringBudget,
            "archive": config.archiveBudget,
            "verify": config.verifyBudget,
            "reconcile": config.reconcileBudget,
            "activity": config.activityBudget,
        ],
        "db": dbHeartbeat.connectionFacts(),
        // Inference readiness: JSON null when the candidate lane is off.
        "inference": inferenceHeartbeatMeta(),
        "shutdown_requested": shutdown.isSet,
        "final": final,
    ]
    if let queue {
        meta["queue"] = ["eligible_counts": queue.counts, "oldest_eligible_seconds": queue.ages]
        if let oldest = queue.oldestSeconds { meta["oldest_eligible_seconds"] = oldest }
    }
    if let dbError { meta["db_error"] = String(dbError.prefix(600)) }

    let metaText: String
    if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        metaText = text
    } else {
        metaText = "{\"error\":\"meta encoding failed\"}"
    }

    // Backwards-compatible singleton row: monitoring already reads id = 1.
    // `version` carries the instance name and `meta` carries the full per-lane,
    // per-instance detail. (A truly per-instance row in this table is impossible:
    // the deployed table has CHECK (id = 1). The per-instance identity lives in
    // physiology_worker_heartbeats, written below.)
    do {
        _ = try dbHeartbeat.query("""
            INSERT INTO public.scoring_service_heartbeats
              (id, version, started_at, last_poll_at, last_score_at, last_error, meta)
            VALUES (1, $1::text, clock_timestamp(), clock_timestamp(), NULLIF($2::text,'')::timestamptz, $3::text, $4::jsonb)
            ON CONFLICT (id) DO UPDATE SET
              last_poll_at = EXCLUDED.last_poll_at,
              last_score_at = COALESCE(EXCLUDED.last_score_at, public.scoring_service_heartbeats.last_score_at),
              last_error = EXCLUDED.last_error,
              meta = EXCLUDED.meta
            """, [
                config.workerName,
                scoring.stats.lastScoreAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                firstLaneError.map { String($0.prefix(1000)) } ?? "",
                metaText,
            ])
    } catch {
        FileHandle.standardError.write("frwhoop-worker: heartbeat (singleton) failed: \(error)\n".data(using: .utf8)!)
    }

    // Per-instance health row. This table is the per-worker one; its CHECK
    // constraints bound the revision to 40 hex chars and the error to a short
    // identifier-shaped string, so both are normalized above.
    do {
        _ = try dbHeartbeat.query("""
            INSERT INTO public.physiology_worker_heartbeats
              (worker_instance_id, process_instance_id, source_revision, algorithm_version,
               started_at, last_poll_at, last_score_at, last_error)
            VALUES ($1::uuid, $2::uuid, $3::text, $4::text, $7::timestamptz, clock_timestamp(),
                    NULLIF($5::text,'')::timestamptz, NULLIF($6::text,''))
            ON CONFLICT (worker_instance_id, process_instance_id) DO UPDATE SET
              source_revision = EXCLUDED.source_revision,
              last_poll_at = EXCLUDED.last_poll_at,
              last_score_at = COALESCE(EXCLUDED.last_score_at, public.physiology_worker_heartbeats.last_score_at),
              last_error = EXCLUDED.last_error
            """, [
                workerInstanceID,
                processInstanceID,
                deployedRevision,
                "frwhoop-server-1",
                scoring.stats.lastScoreAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                sanitizedHealthError(firstLaneError ?? dbError) ?? "",  // '' -> NULL below
                // The table CHECKs last_score_at >= started_at on the proposed row, before the conflict
                // path runs. A started_at of "now" made every heartbeat after the first score fail, so
                // the process start (whole seconds, never later than a score) is what must be sent.
                ISO8601DateFormatter().string(from: startedAt),
            ])
    } catch {
        FileHandle.standardError.write("frwhoop-worker: heartbeat (per-instance) failed: \(error)\n".data(using: .utf8)!)
    }

    if let err = firstLaneError {
        FileHandle.standardOutput.write("frwhoop-worker: lane error: \(err)\n".data(using: .utf8)!)
    }
    if let dbError {
        FileHandle.standardError.write("frwhoop-worker: database unreachable: \(dbError)\n".data(using: .utf8)!)
    }
    if final {
        FileHandle.standardOutput.write("frwhoop-worker: final heartbeat written\n".data(using: .utf8)!)
    }
}

// MARK: - Main loop (heartbeat only; lanes run on their own threads)

let heartbeatInterval = Double(config.heartbeatIntervalMS) / 1000.0
let runtimeLimit = config.maxRuntimeSeconds > 0 ? config.maxRuntimeSeconds : nil

while true {
    if terminationRequested != 0 { shutdown.set() }
    if let limit = runtimeLimit, Date().timeIntervalSince(startedAt) >= limit {
        FileHandle.standardOutput.write("frwhoop-worker: runtime limit reached\n".data(using: .utf8)!)
        shutdown.set()
    }
    if shutdown.isSet { break }

    if Date().timeIntervalSince(lastHeartbeat) >= heartbeatInterval || lastHeartbeat == Date.distantPast {
        heartbeat()
        lastHeartbeat = Date()
        // The heartbeat is the worker's own liveness proof. If it cannot reach the
        // database for four intervals in a row, exit so systemd restarts us with a
        // clean process (the lanes' leases make a restart safe).
        if dbHeartbeat.isConnected {
            heartbeatFailures = 0
        } else {
            heartbeatFailures += 1
            if heartbeatFailures >= 4 {
                FileHandle.standardError.write(
                    "frwhoop-worker: database unreachable for \(heartbeatFailures) heartbeat intervals; exiting for systemd restart\n"
                        .data(using: .utf8)!)
                exit(4)
            }
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
}

// Give the lanes a moment to finish their current transaction, then write the
// final heartbeat (the lanes check `shutdown` between cycles).
Thread.sleep(forTimeInterval: 0.2)
heartbeat(final: true)
FileHandle.standardOutput.write("frwhoop-worker: stopped\n".data(using: .utf8)!)
exit(0)
