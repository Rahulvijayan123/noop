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
//   FRWHOOP_DISABLE_LANES        comma-separated lanes to skip (projection,scoring,archive,verify)
//   FRWHOOP_POLL_INTERVAL_MS     idle poll interval (default 1000)
//   FRWHOOP_HEARTBEAT_INTERVAL_MS heartbeat interval (default 15000)
//   FRWHOOP_MAX_RUNTIME_SECONDS  exit after N seconds (0 = run forever; for scripted tests)
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
    let disabledLanes: Set<String>
    let pollIntervalMS: Int
    let heartbeatIntervalMS: Int
    let maxRuntimeSeconds: Double

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
        self.disabledLanes = Set(
            (environment["FRWHOOP_DISABLE_LANES"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })
        self.pollIntervalMS = Int(environment["FRWHOOP_POLL_INTERVAL_MS"] ?? "1000") ?? 1000
        self.heartbeatIntervalMS = Int(environment["FRWHOOP_HEARTBEAT_INTERVAL_MS"] ?? "15000") ?? 15000
        self.maxRuntimeSeconds = Double(environment["FRWHOOP_MAX_RUNTIME_SECONDS"] ?? "0") ?? 0
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
let storage: B2Storage
do {
    dbOptions = try PostgresOptions.fromEnvironment(env)
    dbHeartbeat = try PostgresClient(options: dbOptions)
    dbProjection = try PostgresClient(options: dbOptions)
    dbScoring = try PostgresClient(options: dbOptions)
    dbArchive = try PostgresClient(options: dbOptions)
    dbVerify = try PostgresClient(options: dbOptions)
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
var scoring = ScoringLane(db: dbScoring, scorer: DayScorer(db: dbScoring), ingestSecret: config.ingestSecret)
var archive = ArchiveLane(db: dbArchive, storage: storage)
var verify = VerificationLane(db: dbVerify, storage: storage)

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
                $0.counters = [
                    "claimed": scoring.stats.claimed,
                    "completed": scoring.stats.completed,
                    "failed": scoring.stats.failed,
                    "superseded": scoring.stats.superseded,
                    "not_completed": scoring.stats.notCompleted,
                    "failures_persisted": scoring.stats.failuresPersisted,
                    "failures_unsettled": scoring.stats.failuresUnsettled,
                ]
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

// MARK: - Heartbeat

/// The age and depth of every claimable queue. Aggregate only: no user data.
let queueAgeSQL = """
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
)
select lane, n::text as n,
       case when oldest is null then ''
            else greatest(0, extract(epoch from (now() - oldest))::bigint)::text end as age_seconds
  from q
"""

struct QueueAge {
    var counts: [String: Int] = [:]
    var ages: [String: Int] = [:]
    var oldestSeconds: Int?
}

func queueAge() throws -> QueueAge {
    let rows = try dbHeartbeat.query(queueAgeSQL, [])
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
    let lanes = [projectionState.read(), scoringState.read(), archiveState.read(), verifyState.read()]
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
        ],
        "db": dbHeartbeat.connectionFacts(),
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
            VALUES ($1::uuid, $2::uuid, $3::text, $4::text, clock_timestamp(), clock_timestamp(),
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
