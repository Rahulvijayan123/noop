
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// frwhoop-worker: hosted compute worker for the FRWHOOP pipeline.
//
// Environment (no compiled-in secrets):
//   FRWHOOP_DB_URL               direct Postgres connection string
//   FRWHOOP_B2_KEY_ID            object storage application key id
//   FRWHOOP_B2_APPLICATION_KEY   object storage application key
//   FRWHOOP_B2_BUCKET            bucket name (default FRWHOOP)
//   FRWHOOP_INGEST_SECRET        internal ingest secret for engine_* calls
//   FRWHOOP_WORKER_NAME          heartbeat identity (default frwhoop-worker-2)
//   FRWHOOP_SOURCE_REVISION      deployed code revision (git sha)
//   FRWHOOP_PROJECTION_BUDGET    projection objects per wake (default 8)
//   FRWHOOP_SCORING_BUDGET       scoring days per wake (default 4)
//   FRWHOOP_POLL_INTERVAL_MS     idle poll interval (default 1000)
//   FRWHOOP_HEARTBEAT_INTERVAL_MS heartbeat interval (default 15000)

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
    let pollIntervalMS: Int
    let heartbeatIntervalMS: Int

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
        self.pollIntervalMS = Int(environment["FRWHOOP_POLL_INTERVAL_MS"] ?? "1000") ?? 1000
        self.heartbeatIntervalMS = Int(environment["FRWHOOP_HEARTBEAT_INTERVAL_MS"] ?? "15000") ?? 15000
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

let db: PostgresClient
let storage: B2Storage
do {
    db = try PostgresClient(connectionString: config.dbURL)
    storage = B2Storage(keyID: config.b2KeyID, applicationKey: config.b2ApplicationKey, bucket: config.b2Bucket)
} catch {
    FileHandle.standardError.write("frwhoop-worker: startup failed: \(error)\n".data(using: .utf8)!)
    exit(3)
}

var running = true
signal(SIGTERM) { _ in running = false }
signal(SIGINT) { _ in running = false }

var projection = ProjectionLane(db: db, storage: storage)
var scoring = ScoringLane(db: db, scorer: DayScorer(db: db), ingestSecret: config.ingestSecret)
var archive = ArchiveLane(db: db, storage: storage)
var lastHeartbeat = Date.distantPast

func heartbeat(final: Bool = false) {
    do {
        let meta: String = """
        {
          "source_revision": "\(config.sourceRevision)",
          "projection": {"claimed": \(projection.stats.claimed), "completed": \(projection.stats.completed), "failed": \(projection.stats.failed)},
          "scoring": {"claimed": \(scoring.stats.claimed), "completed": \(scoring.stats.completed), "failed": \(scoring.stats.failed)},
          "archive": {"uploaded": \(archive.stats.uploaded), "failed": \(archive.stats.failed)}
        }
        """
        try db.exec("""
        INSERT INTO public.scoring_service_heartbeats (id, version, started_at, last_poll_at, last_error, meta)
        VALUES (1, '\(config.workerName)', now(), now(), NULL, '\(meta)')
        ON CONFLICT (id) DO UPDATE SET last_poll_at = now(), last_error = EXCLUDED.last_error, meta = EXCLUDED.meta
        """)
    } catch {
        FileHandle.standardError.write("frwhoop-worker: heartbeat failed: \(error)\n".data(using: .utf8)!)
    }
}

FileHandle.standardOutput.write("frwhoop-worker: started name=\(config.workerName) revision=\(config.sourceRevision)\n".data(using: .utf8)!)

while running {
    var didWork = false

    let projBefore = projection.stats.claimed
    projection.drain(budget: config.projectionBudget)
    if projection.stats.claimed > projBefore { didWork = true }
    if let err = projection.stats.lastError {
        FileHandle.standardOutput.write("frwhoop-worker: projection last error: \(err)\n".data(using: .utf8)!)
    }

    let scoreBefore = scoring.stats.completed
    scoring.drain(budget: config.scoringBudget)
    if scoring.stats.completed > scoreBefore { didWork = true }
    if let err = scoring.stats.lastError {
        FileHandle.standardOutput.write("frwhoop-worker: scoring last error: \(err)\n".data(using: .utf8)!)
    }

    let archBefore = archive.stats.uploaded
    archive.drain(budget: config.projectionBudget)
    if archive.stats.uploaded > archBefore { didWork = true }
    if let err = archive.stats.lastError {
        FileHandle.standardOutput.write("frwhoop-worker: archive last error: \(err)\n".data(using: .utf8)!)
    }

    if Date().timeIntervalSince(lastHeartbeat) >= Double(config.heartbeatIntervalMS) / 1000.0 {
        heartbeat()
        lastHeartbeat = Date()
    }

    if !didWork {
        Thread.sleep(forTimeInterval: Double(config.pollIntervalMS) / 1000.0)
    }
}

heartbeat(final: true)
FileHandle.standardOutput.write("frwhoop-worker: stopped\n".data(using: .utf8)!)
exit(0)
