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
//   FRWHOOP_CONTEXT_ENABLED      "1" runs the physiology-context lane (default OFF; exactly "1", and the lane
//                                only runs when enabled AND "context" is not in DISABLE_LANES). Needs
//                                20261006050000_physiology_context.sql; without it the lane idles and
//                                reports context_tables_missing
//   FRWHOOP_CONTEXT_BUDGET       context jobs per wake (default 2)
//   FRWHOOP_CONTEXT_LEASE_SECONDS     context job lease length (default 300)
//   FRWHOOP_CONTEXT_ENQUEUE_INTERVAL_SECONDS  seconds between enqueue_physiology_context_days_v1 calls (default 120)
//   FRWHOOP_INERTIA_ENABLED      1/true/yes/on also asks a SECOND Python child (`activity_context.inertia.serve`)
//                                for Inertia-1 motion heads on every raw-IMU chunk (default OFF; an unrecognised
//                                value keeps it off and is logged). Never gates claiming; any failure is counted
//                                and the HART path continues
//   FRWHOOP_INERTIA_MODE         shadow (default: store the heads in activity_motion_heads_days) | candidate
//                                (also store a second, Inertia-evidence decode of the day beside them; never
//                                published) | production (the heads shape the published v2 day document, as far
//                                as the bundle's evidence_tier_max allows; no second decode is stored)
//   FRWHOOP_INERTIA_BUNDLE_DIR   head bundle directory (required when enabled)
//   FRWHOOP_INERTIA_BUNDLE_SHA256 the pinned bundle_sha256 (required in candidate and production mode; enforced in
//                                shadow mode when set): a child serving any other bundle is refused for the job, and it is
//                                passed to the child as --expect-bundle-sha256
//   FRWHOOP_INERTIA_CHECKPOINT   encoder checkpoint, passed as --checkpoint and INERTIA1_CKPT_PATH (optional)
//   FRWHOOP_INERTIA_PYTHON       interpreter for the Inertia child (default: FRWHOOP_ACTIVITY_PYTHON)
//   FRWHOOP_INERTIA_TIMEOUT_SECONDS per-request timeout of the Inertia child (default 60, clamped to a third of
//                                FRWHOOP_ACTIVITY_LEASE_SECONDS); the child gets --timeout 5 s below it
//   FRWHOOP_INERTIA_JOB_BUDGET_SECONDS wall time Inertia may spend per job, readiness check and chunks together
//                                (default 600); once used, Inertia is stopped for that job (job_time_budget)
//   FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW 1/true/yes/on passes --allow-standin-shadow (default OFF; shadow mode
//                                only): exercises the shadow lane on real data with a stand-in encoder, whose
//                                rows are stored as encoder_kind standin and never feed the decoder
//   FRWHOOP_ELDERNET_ENABLED     1/true/yes/on also asks a THIRD Python child (`activity_context.eldernet.serve`)
//                                for ElderNet gait quality on every raw-IMU chunk (default OFF; an unrecognised
//                                value keeps it off and is logged). Never gates claiming; any failure is counted
//                                and the HART path continues (Tools/ActivityContext/ELDERNET.md §6)
//   FRWHOOP_ELDERNET_MODE        shadow (default: store the gait windows in activity_gait_windows_days) |
//                                candidate (also store a second decode of the day with the gait channel beside
//                                them; never published) | production (the gait channel shapes the published v2 day
//                                document; no second decode is stored)
//   FRWHOOP_ELDERNET_WEIGHTS_DIR fetched ElderNet weights, passed as --weights-dir (required when enabled)
//   FRWHOOP_ELDERNET_UPSTREAM_DIR the sha-verified upstream ElderNet source checkout (`python -m
//                                activity_context.eldernet.upstream fetch --dest DIR`), passed as --upstream-dir
//                                (required when enabled; without it the child reports model_missing)
//   FRWHOOP_ELDERNET_MODEL_VERSION / FRWHOOP_ELDERNET_WEIGHTS_SHA256 the pinned model_version and weights digest
//                                (required in candidate and production mode; enforced in shadow mode when set): a
//                                child serving any other model is refused for the job
//   FRWHOOP_ELDERNET_GAIT_PRIOR  π, the mean served gait_prob over the VAL windows the decoder sees (required in
//                                candidate and production mode; 0.085 for the served defaults, GaitQualityEvidenceConfig.defaultGaitPrior)
//   FRWHOOP_ELDERNET_PYTHON      interpreter for the ElderNet child (default: FRWHOOP_ACTIVITY_PYTHON)
//   FRWHOOP_ELDERNET_TIMEOUT_SECONDS per-request timeout of the ElderNet child (default 60, clamped to a third of
//                                FRWHOOP_ACTIVITY_LEASE_SECONDS); the child gets --timeout 5 s below it
//   FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS wall time ElderNet may spend per job, readiness check and chunks together
//                                (default 600); once used, ElderNet is stopped for that job (job_time_budget)
//   FRWHOOP_EXERCISE_ENABLED     1/true/yes/on also asks a FOURTH Python child (`activity_context.recgym.serve`) for
//                                RecGym gym-exercise windows on every raw-IMU chunk, stored in
//                                activity_exercise_windows (default OFF; SHADOW ONLY: no decode, canonical value or
//                                exercise-session rule reads them; Tools/ActivityContext/RECGYM.md §6)
//   FRWHOOP_EXERCISE_WEIGHTS_PATH the staged checkpoint (/opt/frwhoop-models/current/recgym/e085ac0e/
//                                wrist_-_imu_only_best.pt), passed as --weights-path (required when enabled)
//   FRWHOOP_EXERCISE_MODE        shadow (the only value accepted; anything else keeps the head off)
//   FRWHOOP_EXERCISE_MODEL_VERSION / FRWHOOP_EXERCISE_WEIGHTS_SHA256 pins (enforced when set): a child serving
//                                anything else is refused for the job
//   FRWHOOP_EXERCISE_PYTHON / _TIMEOUT_SECONDS / _JOB_BUDGET_SECONDS / _THREADS as ElderNet's (defaults: the activity
//                                python, 60 s clamped to a third of the lease, 300 s, 1 thread)
//   FRWHOOP_EXERCISE_RETENTION_DAYS windows older than this are pruned (default 14)
//   FRWHOOP_SENSOR_BIOMARKERS_ENABLED  "1" runs the sensor-biomarker lane (default OFF; exactly "1", and
//                                the lane only runs when enabled, "sensor" is not in DISABLE_LANES, AND
//                                FRWHOOP_INFERENCE_URL is set). Needs 20261007140000_sensor_biomarkers.sql;
//                                without it the lane idles and reports sensor_tables_missing
//   FRWHOOP_SENSOR_BIOMARKERS_BUDGET  sensor-biomarker jobs per wake (default 2)
//   FRWHOOP_SENSOR_BIOMARKERS_LEASE_SECONDS  sensor-biomarker job lease length (default 300)
//   FRWHOOP_SENSOR_PPG_ENABLED   "1" adds ppg_quality + pulse_shape (default OFF: only push protocol 1.5
//                                ppgWaveformSample objects carry the optical anchor; every older second is
//                                withheld missing_ppg_anchor, see docs/model-integration/ppg-transport.md)
//   FRWHOOP_PARADIGMA_ENABLED    "1" adds tremor + arm_swing to the sensor families (research)
//   FRWHOOP_DEEPBEAT_SHADOW_ENABLED "1" adds rhythm_shadow to the sensor families (shadow, never user-facing)
//   FRWHOOP_SIAMAF_SHADOW_ENABLED    "1" lets the sidecar attach the optional SiamAF shadow adapter to
//                                rhythm_shadow (the family itself needs FRWHOOP_DEEPBEAT_SHADOW_ENABLED)
//   FRWHOOP_PERFUSION_RESEARCH_ENABLED "1" adds perfusion_research to the sensor families (gated research)
//   FRWHOOP_DISABLE_LANES        comma-separated lanes to skip (projection,scoring,archive,verify,activity,context,sensor);
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
//   FRWHOOP_CANDIDATE_SCHEDULER  persisted (default; needs 20261008110000) | memory
//   FRWHOOP_CANDIDATE_MAX_ATTEMPTS / _REASSEMBLY_BUDGET / _LEASE_SECONDS  pending-queue
//                                bounds (defaults 4 / 1 / 300; docs/model-integration/runtime-bounds.md)
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

// `--print-identity` prints what this executable measures about itself (RuntimeIdentity) and exits
// before reading any configuration or opening a connection: deploy/release-host.sh checks a fresh
// build with it before the release can be selected.
if CommandLine.arguments.dropFirst().contains("--print-identity") {
    print(RuntimeIdentity.measure(environment: ProcessInfo.processInfo.environment).jsonText())
    exit(0)
}

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
    /// Physiology-context lane (contracts §7). OFF unless FRWHOOP_CONTEXT_ENABLED is exactly "1".
    let contextEnabled: Bool
    let contextBudget: Int
    let contextLeaseSeconds: Int
    let contextEnqueueIntervalSeconds: Int
    let activityCacheDir: String
    /// Sensor-biomarker lane (spec-31 §8-9). OFF unless FRWHOOP_SENSOR_BIOMARKERS_ENABLED is exactly "1".
    let sensorBiomarkersEnabled: Bool
    /// The enabled family set, sorted (CONTRACTS.md section 1 flags passed through).
    let sensorFamilies: [String]
    let sensorBudget: Int
    let sensorLeaseSeconds: Int
    let inertia: InertiaSettings
    let eldernet: ElderNetSettings
    let exercise: ExerciseSettings
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

    /// The context lane runs only when enabled AND not listed in FRWHOOP_DISABLE_LANES.
    var contextLaneRuns: Bool { contextEnabled && !disabledLanes.contains("context") }

    /// The sensor lane runs only when enabled AND not listed in FRWHOOP_DISABLE_LANES (the
    /// inference URL requirement is checked where the client is built).
    var sensorLaneRuns: Bool { sensorBiomarkersEnabled && !disabledLanes.contains("sensor") }

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
        // The physiology-context lane is OFF by default, like the activity lane: only the exact value "1"
        // turns it on, so "true", "yes" or a typo leave it off.
        self.contextEnabled = (environment["FRWHOOP_CONTEXT_ENABLED"] ?? "") == "1"
        self.contextBudget = max(1, Int(environment["FRWHOOP_CONTEXT_BUDGET"] ?? "") ?? 2)
        self.contextLeaseSeconds = max(30, Int(environment["FRWHOOP_CONTEXT_LEASE_SECONDS"] ?? "") ?? 300)
        self.contextEnqueueIntervalSeconds = max(
            1, Int(environment["FRWHOOP_CONTEXT_ENQUEUE_INTERVAL_SECONDS"] ?? "") ?? 120)
        // The sensor-biomarker lane is OFF by default: only the exact value "1" turns it on, so
        // "true", "yes" or a typo leave it off. The family sub-flags are passed through to the
        // lane's families list (CONTRACTS.md section 1).
        self.sensorBiomarkersEnabled = (environment["FRWHOOP_SENSOR_BIOMARKERS_ENABLED"] ?? "") == "1"
        var sensorFamilies: [String] = []
        if self.sensorBiomarkersEnabled {
            sensorFamilies = ["movement", "oscillation"]
            if (environment["FRWHOOP_SENSOR_PPG_ENABLED"] ?? "") == "1" {
                sensorFamilies.append("ppg_quality")
                sensorFamilies.append("pulse_shape")
            }
            if (environment["FRWHOOP_PERFUSION_RESEARCH_ENABLED"] ?? "") == "1" {
                sensorFamilies.append("perfusion_research")
            }
            if (environment["FRWHOOP_PARADIGMA_ENABLED"] ?? "") == "1" {
                sensorFamilies.append("tremor")
                sensorFamilies.append("arm_swing")
            }
            if (environment["FRWHOOP_DEEPBEAT_SHADOW_ENABLED"] ?? "") == "1" {
                sensorFamilies.append("rhythm_shadow")
            }
            sensorFamilies.sort()
        }
        self.sensorFamilies = sensorFamilies
        self.sensorBudget = max(1, Int(environment["FRWHOOP_SENSOR_BIOMARKERS_BUDGET"] ?? "") ?? 2)
        self.sensorLeaseSeconds = max(30, Int(environment["FRWHOOP_SENSOR_BIOMARKERS_LEASE_SECONDS"] ?? "") ?? 300)
        // On-host cache of downloaded raw-IMU objects and model answers (ActivityLocalCache). Under
        // /var/lib/frwhoop by default, which the unit already lets the worker write; "" turns it off.
        self.activityCacheDir = environment["FRWHOOP_ACTIVITY_CACHE_DIR"] ?? "/var/lib/frwhoop/activity-cache"
        self.inertia = InertiaSettings.fromEnvironment(environment, activityPython: self.activityPython,
                                                       leaseSeconds: self.activityLeaseSeconds)
        self.eldernet = ElderNetSettings.fromEnvironment(environment, activityPython: self.activityPython,
                                                         leaseSeconds: self.activityLeaseSeconds)
        self.exercise = ExerciseSettings.fromEnvironment(environment, activityPython: self.activityPython,
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

// The context lane's connection exists only when the lane runs, and failing to open it never stops the worker:
// the lane then reports itself blocked in the heartbeat and every other lane carries on.
var dbContext: PostgresClient?
var contextStartupError: String?
if config.contextLaneRuns {
    do {
        dbContext = try PostgresClient(options: dbOptions)
    } catch {
        contextStartupError = String(describing: error).prefix(2000).description
        FileHandle.standardError.write(
            "frwhoop-worker: context lane connection failed; the lane stays off: \(error)\n".data(using: .utf8)!)
    }
}

// The sensor lane's connection follows the same rule: it exists only when the lane runs and a
// failure to open it never stops the worker.
var dbSensor: PostgresClient?
var sensorStartupError: String?
if config.sensorLaneRuns {
    do {
        dbSensor = try PostgresClient(options: dbOptions)
    } catch {
        sensorStartupError = String(describing: error).prefix(2000).description
        FileHandle.standardError.write(
            "frwhoop-worker: sensor lane connection failed; the lane stays off: \(error)\n".data(using: .utf8)!)
    }
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
    /// What the lane has actually loaded or is talking to (model and artifact digests, a child's
    /// reported versions), as measured by the lane rather than claimed by configuration. Empty
    /// until the lane has something to report. See docs/model-integration/README.md.
    var identity: [String: String] = [:]
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
// The physiology-context lane is opt-in in the same way (FRWHOOP_CONTEXT_ENABLED=1 and not "context" in
// FRWHOOP_DISABLE_LANES); off, it is never started and opens no connection.
let contextState = LaneState(LaneSnapshot(
    name: "context",
    enabled: config.contextLaneRuns,
    // A context-only startup failure is reported on the lane, never as a blocked database for the worker.
    lastError: contextStartupError,
    lastErrorKind: contextStartupError == nil ? nil : "context_connection"))

let sensorState = LaneState(LaneSnapshot(
    name: "sensor",
    enabled: config.sensorLaneRuns,
    // A sensor-only startup failure is reported on the lane, never as a blocked database for the worker.
    lastError: sensorStartupError,
    lastErrorKind: sensorStartupError == nil ? nil : "sensor_connection"))

let startedAt = Date()
let processInstanceID = UUID().uuidString.lowercased()
// Measured once: the executable's digest and the release it belongs to (heartbeat meta.identity).
let runtimeIdentity = RuntimeIdentity.measure(environment: env)
FileHandle.standardOutput.write(("frwhoop-worker: identity executable_sha256=\(runtimeIdentity.executableSHA256 ?? "unmeasured") "
    + "release=\(runtimeIdentity.release?.releaseID ?? "none") "
    + "matches_release=\(runtimeIdentity.matchesRelease.map { String($0) } ?? "unknown")\n").data(using: .utf8)!)

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
        // Thread caps, and HART's in-process ElderNet off: ElderNet has one route, its own stage below.
        restartCooldownSeconds: 30).hartChild(threads: ActivityPythonService.Config.hartThreads(env))),
    leaseSeconds: config.activityLeaseSeconds,
    imuJobsEnabled: config.activityImu,
    contextDaysEnabled: config.activityContextV2,
    streamDaysEnabled: config.activityStreams,
    streamDayBudget: config.activityStreamBudget,
    inertia: config.inertia.serviceConfig(activityHome: config.activityHome).map {
        InertiaStage(service: ActivityPythonService(config: $0), mode: config.inertia.mode,
                     expectedBundleSHA256: config.inertia.bundleSHA256,
                     jobBudgetSeconds: config.inertia.jobBudgetSeconds)
    },
    eldernet: config.eldernet.serviceConfig(activityHome: config.activityHome).map {
        ElderNetStage(service: ActivityPythonService(config: $0), mode: config.eldernet.mode,
                      expectedModelVersion: config.eldernet.modelVersion,
                      expectedWeightsDigest: config.eldernet.weightsSHA256, gaitPrior: config.eldernet.gaitPrior,
                      jobBudgetSeconds: config.eldernet.jobBudgetSeconds)
    },
    exercise: config.exercise.serviceConfig(activityHome: config.activityHome).map {
        ExerciseStage(service: ActivityPythonService(config: $0), expectedModelVersion: config.exercise.modelVersion,
                      expectedWeightsSHA256: config.exercise.weightsSHA256, jobBudgetSeconds: config.exercise.jobBudgetSeconds,
                      retentionDays: config.exercise.retentionDays)
    },
    cache: config.activityEnabled && config.activityImu ? ActivityLocalCache(path: config.activityCacheDir) : nil)
for warning in config.inertia.warnings {
    FileHandle.standardError.write("frwhoop-worker: inertia: \(warning)\n".data(using: .utf8)!)
}
if let why = config.inertia.configurationError {
    FileHandle.standardError.write("frwhoop-worker: inertia stays off: \(why)\n".data(using: .utf8)!)
} else if config.inertia.enabled {
    FileHandle.standardError.write(
        ("frwhoop-worker: inertia \(config.inertia.mode.rawValue) enabled (bundle \(config.inertia.bundleDir ?? "-"), "
            + "pinned \(config.inertia.bundleSHA256 ?? "no")\(config.inertia.allowStandInShadow ? ", stand-in shadow" : ""), "
            + "timeout \(config.inertia.timeoutSeconds) s, job budget \(config.inertia.jobBudgetSeconds) s)\n").data(using: .utf8)!)
}
for warning in config.eldernet.warnings {
    FileHandle.standardError.write("frwhoop-worker: eldernet: \(warning)\n".data(using: .utf8)!)
}
if let why = config.eldernet.configurationError {
    FileHandle.standardError.write("frwhoop-worker: eldernet stays off: \(why)\n".data(using: .utf8)!)
} else if config.eldernet.enabled {
    FileHandle.standardError.write(
        ("frwhoop-worker: eldernet \(config.eldernet.mode.rawValue) enabled (weights \(config.eldernet.weightsDir ?? "-"), "
            + "upstream \(config.eldernet.upstreamDir ?? "-"), "
            + "pinned \(config.eldernet.modelVersion ?? "no") / \(config.eldernet.weightsSHA256 ?? "no"), "
            + "timeout \(config.eldernet.timeoutSeconds) s, job budget \(config.eldernet.jobBudgetSeconds) s)\n").data(using: .utf8)!)
}
for warning in config.exercise.warnings {
    FileHandle.standardError.write("frwhoop-worker: exercise: \(warning)\n".data(using: .utf8)!)
}
if let why = config.exercise.configurationError {
    FileHandle.standardError.write("frwhoop-worker: exercise stays off: \(why)\n".data(using: .utf8)!)
} else if config.exercise.enabled {
    FileHandle.standardError.write(
        ("frwhoop-worker: exercise shadow enabled (weights \(config.exercise.weightsPath ?? "-"), "
            + "pinned \(config.exercise.modelVersion ?? "no") / \(config.exercise.weightsSHA256 ?? "no"), "
            + "timeout \(config.exercise.timeoutSeconds) s, job budget \(config.exercise.jobBudgetSeconds) s, "
            + "retention \(config.exercise.retentionDays) d)\n").data(using: .utf8)!)
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
    // Persisted fair scheduling (20261008110000); in memory while the migration is absent.
    scoring.candidate?.configurePending(PostgresCandidatePendingStore(db: dbScoring),
                                        environment: ProcessInfo.processInfo.environment,
                                        owner: config.workerName)
    scoring.candidateBudget = config.inferenceBudget
    // Sleep-phenotype enrichment lane: the SAME sidecar, its own dedicated
    // /v1/sleep-features endpoint, with its own bounded budget. A candidate
    // lane failure never disables the enrichment and vice versa: the client is
    // shared, the lanes are independent (spec 7.4 "isolation").
    scoring.scorer.featureEnrichmentClient = inferenceClient
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
                    counters.merge(scoring.candidate?.heartbeatCounters() ?? [:]) { current, _ in current }
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
                    "windows_reused": activity.stats.windowsReused,
                    "window_sets_published": activity.stats.windowSetsPublished,
                    "window_set_failures": activity.stats.windowSetFailures,
                    "objects_reused": activity.stats.objectsReused,
                    "context_days_published": activity.stats.contextDaysPublished,
                    "context_day_failures": activity.stats.contextDayFailures,
                    "stream_days_enqueued": activity.stats.streamDaysEnqueued,
                    "stream_days_claimed": activity.stats.streamDaysClaimed,
                    "stream_days_published": activity.stats.streamDaysPublished,
                    "stream_days_empty": activity.stats.streamDaysEmpty,
                    "stream_days_superseded": activity.stats.streamDaysSuperseded,
                    "stream_day_failures": activity.stats.streamDayFailures,
                    // Version-driven re-derivation (reconcile_activity_context_versions): days re-queued, failed
                    // calls, and whether the last call failed (its reason is on stderr, once per distinct reason).
                    "version_rederived": activity.stats.versionRederived,
                    "version_reconcile_failures": activity.stats.versionReconcileFailures,
                    "version_reconcile_failing": activity.stats.lastVersionReconcileError == nil ? 0 : 1,
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
                    $0.counters["inertia_budget_exhausted"] = activity.stats.inertiaBudgetExhausted
                    $0.counters["inertia_windows_attached"] = activity.stats.inertiaWindowsAttached
                    $0.counters["inertia_windows_dropped"] = activity.stats.inertiaWindowsDropped
                    $0.counters["inertia_posture_omitted"] = activity.stats.inertiaPostureOmitted
                    $0.counters["inertia_rows_pruned"] = activity.stats.inertiaRowsPruned
                    $0.counters["inertia_prune_failures"] = activity.stats.inertiaPruneFailures
                }
                // Only with ElderNet on, likewise.
                if activity.eldernet != nil {
                    $0.counters["eldernet_jobs"] = activity.stats.eldernetJobs
                    $0.counters["eldernet_chunks"] = activity.stats.eldernetChunks
                    $0.counters["eldernet_chunks_reused"] = activity.stats.eldernetChunksReused
                    $0.counters["eldernet_windows"] = activity.stats.eldernetWindows
                    $0.counters["eldernet_failures"] = activity.stats.eldernetFailures
                    $0.counters["eldernet_unavailable"] = activity.stats.eldernetUnavailable
                    $0.counters["eldernet_pin_refused"] = activity.stats.eldernetPinRefused
                    $0.counters["eldernet_budget_exhausted"] = activity.stats.eldernetBudgetExhausted
                    $0.counters["eldernet_shadow_stored"] = activity.stats.eldernetShadowStored
                    $0.counters["eldernet_shadow_failures"] = activity.stats.eldernetShadowFailures
                    $0.counters["eldernet_shadow_fenced"] = activity.stats.eldernetShadowFenced
                    $0.counters["eldernet_candidate_documents"] = activity.stats.eldernetCandidateDocuments
                    $0.counters["eldernet_candidate_withheld"] = activity.stats.eldernetCandidateWithheld
                    $0.counters["eldernet_windows_attached"] = activity.stats.eldernetWindowsAttached
                    $0.counters["eldernet_windows_dropped"] = activity.stats.eldernetWindowsDropped
                    $0.counters["eldernet_rows_pruned"] = activity.stats.eldernetRowsPruned
                    $0.counters["eldernet_prune_failures"] = activity.stats.eldernetPruneFailures
                }
                // Only with the exercise head on, likewise.
                if activity.exercise != nil {
                    $0.counters["exercise_jobs"] = activity.stats.exerciseJobs
                    $0.counters["exercise_chunks"] = activity.stats.exerciseChunks
                    $0.counters["exercise_chunks_reused"] = activity.stats.exerciseChunksReused
                    $0.counters["exercise_chunks_already_published"] = activity.stats.exerciseChunksAlreadyPublished
                    $0.counters["exercise_windows"] = activity.stats.exerciseWindows
                    $0.counters["exercise_failures"] = activity.stats.exerciseFailures
                    $0.counters["exercise_unavailable"] = activity.stats.exerciseUnavailable
                    $0.counters["exercise_pin_refused"] = activity.stats.exercisePinRefused
                    $0.counters["exercise_budget_exhausted"] = activity.stats.exerciseBudgetExhausted
                    $0.counters["exercise_stored"] = activity.stats.exerciseStored
                    $0.counters["exercise_windows_stored"] = activity.stats.exerciseWindowsStored
                    $0.counters["exercise_fenced"] = activity.stats.exerciseFenced
                    $0.counters["exercise_rejected"] = activity.stats.exerciseRejected
                    $0.counters["exercise_rows_pruned"] = activity.stats.exerciseRowsPruned
                    $0.counters["exercise_prune_failures"] = activity.stats.exercisePruneFailures
                }
                if activity.inertia != nil || activity.eldernet != nil {
                    $0.counters["expert_selections"] = activity.stats.expertSelections
                    $0.counters["expert_canonical_shaped"] = activity.stats.expertCanonicalShaped
                }
                // Only while an expert runs in candidate mode, so other heartbeats are unchanged.
                if activity.storesCandidateDays {
                    $0.counters["candidate_days_stored"] = activity.stats.candidateDaysStored
                    $0.counters["candidate_days_fenced"] = activity.stats.candidateDaysFenced
                    $0.counters["candidate_day_failures"] = activity.stats.candidateDayFailures
                    $0.counters["candidate_joint_documents"] = activity.stats.candidateJointDocuments
                    $0.counters["candidate_joint_withheld"] = activity.stats.candidateJointWithheld
                    $0.counters["candidate_rows_pruned"] = activity.stats.candidateRowsPruned
                    $0.counters["candidate_prune_failures"] = activity.stats.candidatePruneFailures
                }
                $0.identity = activity.identity
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

if contextState.read().enabled, let dbContext {
    var context = ContextLane(db: dbContext, workerName: config.workerName,
                              leaseSeconds: config.contextLeaseSeconds,
                              enqueueIntervalSeconds: TimeInterval(config.contextEnqueueIntervalSeconds))
    FileHandle.standardOutput.write(
        ("frwhoop-worker: context lane enabled budget=\(config.contextBudget) "
         + "lease_seconds=\(config.contextLeaseSeconds) "
         + "enqueue_interval_seconds=\(config.contextEnqueueIntervalSeconds)\n").data(using: .utf8)!)
    laneQueue.async {
        runLane(contextState, cycle: {
            func settled() -> Int {
                context.stats.published + context.stats.unchanged + context.stats.failed
                    + context.stats.notCompleted + context.stats.superseded
            }
            let before = settled()
            context.drain(budget: config.contextBudget)
            contextState.update {
                $0.counters = context.stats.counters
                $0.lastError = context.stats.lastError
                $0.lastErrorKind = context.stats.lastErrorKind
                $0.lastActivityAt = context.stats.lastActivityAt
            }
            return settled() > before
        }, ensureConnected: { try dbContext.ensureConnected() })
    }
}

if sensorState.read().enabled, let dbSensor, let inferenceClient {
    var sensor = SensorBiomarkerLane(
        db: dbSensor,
        storage: storage,
        inference: inferenceClient,
        leaseSeconds: config.sensorLeaseSeconds,
        families: config.sensorFamilies)
    FileHandle.standardOutput.write(
        ("frwhoop-worker: sensor biomarkers lane enabled budget=\(config.sensorBudget) "
         + "lease_seconds=\(config.sensorLeaseSeconds) "
         + "families=\(config.sensorFamilies.joined(separator: ","))\n").data(using: .utf8)!)
    laneQueue.async {
        runLane(sensorState, cycle: {
            func settled() -> Int {
                sensor.stats.published + sensor.stats.failed + sensor.stats.superseded
                    + sensor.stats.notCompleted
            }
            let before = settled()
            sensor.drain(budget: config.sensorBudget)
            sensorState.update {
                $0.counters = sensor.stats.counters
                $0.lastError = sensor.stats.lastError
                $0.lastErrorKind = sensor.stats.lastErrorKind
                $0.lastActivityAt = sensor.stats.lastActivityAt
                $0.identity = SensorBiomarkerLane.identity
            }
            return settled() > before
        }, ensureConnected: { try dbSensor.ensureConnected() })
    }
} else if config.sensorBiomarkersEnabled {
    // Enabled but no sidecar URL: the lane cannot run; say so once.
    FileHandle.standardOutput.write(
        "frwhoop-worker: sensor biomarkers lane off (FRWHOOP_INFERENCE_URL unset)\n".data(using: .utf8)!)
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
        if var candidateEntry = entry["candidate"] as? [String: Any], let stage = scoring.candidate {
            candidateEntry.merge(stage.heartbeatMeta()) { current, _ in current }
            entry["candidate"] = candidateEntry
        }
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
func queueAgeQuery(includeActivity: Bool, includeContext: Bool = false, includeSensor: Bool = false) -> String {
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
    let sensor = """
  union all
  select 'sensor', count(*), min(j.not_before)
    from public.sensor_biomarker_jobs j
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
    return base + (includeActivity ? activity : "") + (includeContext ? ContextSQL.queueAgeEntry + "\n" : "")
        + (includeSensor ? sensor : "") + closing
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
    // The context entry follows the same rule, and is added only while the context lane runs, so a backlog
    // nobody drains (lane off) never turns the poll state to "working".
    let contextTablePresent = config.contextLaneRuns && (try? dbHeartbeat.query(
        "select to_regclass('public.physiology_context_jobs') is not null as present", []))?
        .first?["present"] == "t"
    // The sensor entry follows the same rule, and is added only while the sensor lane runs, so a
    // backlog nobody drains (lane off) never turns the poll state to "working".
    let sensorTablePresent = config.sensorLaneRuns && (try? dbHeartbeat.query(
        "select to_regclass('public.sensor_biomarker_jobs') is not null as present", []))?
        .first?["present"] == "t"
    let rows = try dbHeartbeat.query(queueAgeQuery(includeActivity: activityTablePresent,
                                                   includeContext: contextTablePresent,
                                                   includeSensor: sensorTablePresent), [])
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
                 verifyState.read(), activityState.read(), contextState.read(), sensorState.read()]
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
        if !lane.identity.isEmpty { entry["identity"] = lane.identity }
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
            "context": config.contextBudget,
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
    // What this process measured about itself at startup; `source_revision` above is only the claim.
    meta["identity"] = runtimeIdentity.wire

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
