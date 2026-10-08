import Foundation
import CZstd
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lane 8: sensor biomarkers (spec-31 §8-9, docs/sensor-biomarkers/CONTRACTS.md §1/4/5).
/// OFF unless `FRWHOOP_SENSOR_BIOMARKERS_ENABLED=1` (wired in main.swift; default OFF).
///
/// One wake:
///   1. presence guard: the queue table and RPCs must exist, otherwise the lane idles and says so
///      (re-probing once a minute, like `ContextLane.checkTables`);
///   2. bounded reconcile (`reconcile_sensor_biomarkers` with the lane's enabled families) once a
///      minute, mirroring `reconcile_activity_context`: newly verified rawImuSession +
///      ppgWaveformSample objects map into affected (owner, device, UTC day) job upserts,
///      idempotent by the deterministic PK;
///   3. up to `budget` jobs: claim (a lease, committed before any long work) -> renew -> resolve
///      the day's verified input objects through W1's `SensorBiomarkerInputs` -> download +
///      digest-verify + decompress -> decode IMU/PPG -> build the bounded sidecar requests
///      (<=5-minute endpoint-owned segments packed under the sidecar's 8 MiB body budget, so a
///      window/pulse is never double-counted at seams) -> `InferenceClient.infer` with metric
///      "sensor_biomarkers" and provider "sensor.biomarkers.v1" per request -> parse the envelope
///      (`status`/`withheld_reason`, `result.stages` family documents) -> merge the per-family
///      stages across requests -> assemble the CONTRACTS.md §3 day document ->
///      `publish_sensor_biomarker_day` (fenced, transactional).
///
/// Settlement mirrors `ActivityLane`/`ContextLane`: a publish that did not apply (NULL: lease lost
/// or revision moved) releases the lease through renew + fail with the CLAIMED revision, which the
/// queue treats as a clean release when the revision moved; a lost lease mid-job is `.stale` and
/// nothing is failed; every other error is settled through `fail_sensor_biomarker_day` with a
/// sanitized one-line reason (bounded backoff, dead-letter at the queue's cap); a lost connection
/// leaves the lease to expire. A sidecar VERDICT (top-level `withheld`/`error`, or a family stage
/// with status `withheld`/`error`) is never a retry: it becomes an explicit withheld family in the
/// published document, exactly as CONTRACTS.md §5 requires ("skip/not-ready optional providers are
/// explicit withheld results, not endless retries"). Only transport/timeout failures
/// (`InferenceClientError`) and missing inputs settle as bounded retries.
///
/// Isolation: own connection, own thread, own lane state. The lane writes nothing but its own RPCs.
/// It never touches scoring, sleep, HRV or the activity lane; with HART disabled the lane runs
/// independently, and with DeepBeat/ParaDigMa missing or timing out, HRV/sleep/scoring stay
/// operational and the unaffected families still publish.
struct SensorBiomarkerLane {
    static let analysisVersion = "sensor-biomarkers/1.0.0"
    static let providerId = "sensor.biomarkers.v1"
    static let labelSpace = "sensor_biomarkers.families/1"

    let db: PostgresClient
    let storage: B2Storage
    let inference: InferenceClient
    /// The job lease length in seconds.
    var leaseSeconds: Int = 300
    /// Dead-letter after this many consecutive failures (the queue's cap).
    var maxFailures: Int = 8
    /// The worker's currently enabled family set (passed to reconcile and to the sidecar).
    var families: [String] = []
    var reconcileIntervalSeconds: TimeInterval = 60
    /// Download seam for tests: the B2 storage's `download` is the production default.
    var downloadObject: ((String) throws -> Data)? = nil

    /// Family keys CONTRACTS.md §2 fixes for v1 (mirrors the SQL family-set check).
    static let familyKeys: Set<String> = [
        "movement", "oscillation", "ppg_quality", "pulse_shape",
        "perfusion_research", "tremor", "arm_swing", "rhythm_shadow",
    ]

    struct Stats {
        var claimed = 0
        var completed = 0
        var failed = 0
        /// Claims the queue had already moved past (newer revision, or another worker won).
        var superseded = 0
        /// Publish returned NULL (stale lease / moved revision / disabled).
        var notCompleted = 0
        var failuresPersisted = 0
        var failuresUnsettled = 0
        /// Wakes that found the queue table or RPCs missing (the lane idles).
        var tablesMissing = 0
        var reconcileRuns = 0
        var reconcileErrors = 0
        /// Claims that failed outright (grant, half-applied migration).
        var claimFailures = 0
        /// Sidecar requests sent.
        var sidecarRequests = 0
        /// Sidecar transport/timeout failures settled as bounded retries.
        var sidecarFailures = 0
        /// Sidecar verdicts (withheld/error) carried into the published document, per family.
        var familiesWithheld = 0
        /// Day documents stored.
        var published = 0
        /// Jobs that published an all-withheld document because no verified input existed.
        var publishedEmpty = 0
        /// Sidecar busy answers (HTTP 429): the job is deferred, never failed and never published.
        var sidecarBusy = 0
        /// Jobs a busy sidecar deferred (their lease shortened to the retry delay).
        var deferredBusy = 0
        /// Families never asked for in a published day because their input modality had no eligible
        /// second; each is published withheld with the coverage reason.
        var familiesWithoutInput = 0
        /// Placement reads that failed; the requests carried an undeclared placement instead.
        var placementReadErrors = 0
        /// PPG record-seconds expected / emitted across published days (input coverage).
        var ppgExpectedSeconds = 0
        var ppgEligibleSeconds = 0
        var lastError: String?
        var lastErrorKind: String?
        var lastActivityAt: Date?

        /// The heartbeat's per-lane counters.
        var counters: [String: Int] {
            [
                "claimed": claimed, "completed": completed, "failed": failed,
                "superseded": superseded, "not_completed": notCompleted,
                "failures_persisted": failuresPersisted, "failures_unsettled": failuresUnsettled,
                "sensor_tables_missing": tablesMissing,
                "reconcile_runs": reconcileRuns, "reconcile_errors": reconcileErrors,
                "claim_failures": claimFailures,
                "sidecar_requests": sidecarRequests, "sidecar_failures": sidecarFailures,
                "families_withheld": familiesWithheld,
                "published": published, "published_empty": publishedEmpty,
                "sidecar_busy": sidecarBusy, "deferred_busy": deferredBusy,
                "families_without_input": familiesWithoutInput,
                "placement_read_errors": placementReadErrors,
                "ppg_expected_seconds": ppgExpectedSeconds, "ppg_eligible_seconds": ppgEligibleSeconds,
            ]
        }
    }
    var stats = Stats()

    var tablesPresent: Bool?
    var tablesCheckedAt: Date?
    /// Whether `placement_intervals` exists (probed once; the lane runs on databases without it).
    var placementTablePresent: Bool?
    var lastReconcileAt: Date?
    var backoffUntil: Date?
    var consecutiveFailures = 0
    /// Last reason written to stderr, so a failure that repeats on every wake is logged once.
    var lastLoggedReason: String?

    enum Cycle {
        case empty
        case completed
        case superseded
        case failed
        /// The sidecar was busy: the job waits for its shortened lease and keeps its failure budget.
        case deferred
    }

    enum SensorBiomarkerError: Error, CustomStringConvertible {
        case deterministic(String)
        case retryable(String)
        /// The sidecar refused admission (HTTP 429 `busy`). Never a result, never a failure.
        case busy

        var description: String {
            switch self {
            case .deterministic(let d): return "sensor_biomarker_deterministic:\(d)"
            case .retryable(let d): return "sensor_biomarker_retryable:\(d)"
            case .busy: return "sensor_biomarker_busy"
            }
        }
    }

    /// Seconds a busy job waits before it can be claimed again (its lease is shortened to this).
    static let busyRetrySeconds = 30

    /// A sidecar busy answer (HTTP 429 `busy`, docs/model-integration/README.md) is admission
    /// backpressure, not a result. The one place that recognises it, so the typed
    /// `InferenceClientError.busy` can replace these generic checks at merge.
    static func isSidecarBusy(_ error: Error) -> Bool {
        if case InferenceClientError.non200(429, _) = error { return true }
        return String(describing: error).hasPrefix("inference_busy")
    }

    /// What the lane measured about itself for the heartbeat (`meta.lanes[].identity`).
    static var identity: [String: String] {
        ["ppg_grid": SensorBiomarkerInputs.ppgGrid.rawValue,
         "ppg_samples_per_second": String(SensorBiomarkerInputs.ppgNativeRateHz),
         "ppg_npb1_formats": "1,2,3",
         "ppg_packet_timing_verified": "false",
         "analysis_version": analysisVersion]
    }

    // MARK: - SQL

    /// The presence guard: the queue table and RPCs must exist (deploy order: the worker may run
    /// before the migration).
    static let tablesPresent = """
        select (to_regclass('public.sensor_biomarker_jobs') is not null
                and to_regclass('public.sensor_biomarker_days') is not null
                and to_regprocedure('public.claim_sensor_biomarker_day(integer)') is not null
                and to_regprocedure('public.publish_sensor_biomarker_day(uuid,bigint,jsonb)') is not null
                and to_regprocedure('public.reconcile_sensor_biomarkers(interval,text[])') is not null)::text
               as present
        """

    /// The claim, plus the columns the lane needs. The claim commits before any long work.
    static let claim = """
        select j.user_id::text as user_id, j.device_id::text as device_id, j.day::text as day,
               j.analysis_version::text as analysis_version, j.fingerprint::text as fingerprint,
               j.input_revision::text as input_revision, j.lease_token::text as lease_token,
               coalesce(array_to_string(j.enabled_families, ','), '') as enabled_families,
               coalesce(array_to_string(j.input_object_ids, ','), '') as input_object_ids,
               coalesce(array_to_string(j.input_digests, ','), '') as input_digests
          from public.claim_sensor_biomarker_day($1::integer) j
        """

    static let renew = "select public.renew_sensor_biomarker_day($1::uuid, $2::integer)::text"
    static let fail = "select public.fail_sensor_biomarker_day($1::uuid, $2::bigint, $3::text)::text"
    /// Returns a non-empty result on success, NULL when the fence rejected the publish.
    static let publish = "select public.publish_sensor_biomarker_day($1::uuid, $2::bigint, $3::jsonb)::text"

    static let reconcile = "select public.reconcile_sensor_biomarkers($1::interval, $2::text[])::text"

    // MARK: - Job row

    struct SensorBiomarkerJob {
        var userId: String
        var deviceId: String
        var day: String
        var analysisVersion: String
        var fingerprint: String
        var inputRevision: Int64
        var leaseToken: String
        var families: [String]
        var objectIds: [String]
        var digests: [String]
    }

    /// Parse the claim row (SQL NULL renders as ""). Nil means the row is corrupt; the caller
    /// settles it deterministically so it cannot be re-claimed forever.
    static func parseJob(_ row: [String: String]) -> SensorBiomarkerJob? {
        guard let userId = row["user_id"], !userId.isEmpty,
              let deviceId = row["device_id"], !deviceId.isEmpty,
              let day = row["day"], !day.isEmpty,
              let analysisVersion = row["analysis_version"], !analysisVersion.isEmpty,
              let fingerprint = row["fingerprint"], fingerprint.count == 64,
              let inputRevision = Int64(row["input_revision"] ?? ""),
              let leaseToken = row["lease_token"], !leaseToken.isEmpty else { return nil }
        let families = (row["enabled_families"] ?? "").split(separator: ",").map(String.init)
        let objectIds = (row["input_object_ids"] ?? "").split(separator: ",").map(String.init)
        let digests = (row["input_digests"] ?? "").split(separator: ",").map(String.init)
        guard objectIds.count == digests.count else { return nil }
        return SensorBiomarkerJob(userId: userId, deviceId: deviceId, day: day,
            analysisVersion: analysisVersion, fingerprint: fingerprint, inputRevision: inputRevision,
            leaseToken: leaseToken, families: families, objectIds: objectIds, digests: digests)
    }

    static func utcDayBounds(_ day: String) -> (start: Int64, end: Int64)? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 0, minute: 0, second: 0)) else { return nil }
        let start = Int64(date.timeIntervalSince1970)
        return (start, start + 86_400)
    }

    static func iso(_ unix: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(unix)).sensorISO()
    }

    static func releaseTier(_ family: String) -> String {
        switch family {
        case "movement", "oscillation", "ppg_quality", "pulse_shape": return "descriptive"
        case "perfusion_research", "tremor", "arm_swing": return "research"
        default: return "shadow"
        }
    }

    static func providerRevision(_ family: String) -> String {
        switch family {
        case "movement", "oscillation": return "imu-biomarkers/1.0.0"
        case "ppg_quality", "pulse_shape", "perfusion_research": return "ppg-biomarkers/1.0.0"
        case "tremor", "arm_swing": return "paradigma/1.0.0"
        case "rhythm_shadow": return "deepbeat/1.0.0"
        default: return ""
        }
    }

    // MARK: - Drain

    /// One wake: up to `budget` jobs, with the presence guard and the bounded reconcile first.
    mutating func drain(budget: Int) {
        if let until = backoffUntil, Date() < until { return }
        do {
            try db.ensureConnected()
        } catch {
            record(error)
            return
        }
        guard checkTables() else { return }
        reconcileIfDue()
        for _ in 0..<max(1, budget) {
            do {
                switch try cycle() {
                case .empty:
                    consecutiveFailures = 0
                    return
                case .completed:
                    consecutiveFailures = 0
                    stats.claimed += 1
                    stats.completed += 1
                    stats.lastActivityAt = Date()
                case .superseded:
                    consecutiveFailures = 0
                    stats.claimed += 1
                    stats.superseded += 1
                case .failed:
                    consecutiveFailures = 0
                    stats.claimed += 1
                    stats.failed += 1
                case .deferred:
                    // A busy sidecar will be busy for the next job too: stop this wake.
                    consecutiveFailures = 0
                    stats.claimed += 1
                    stats.deferredBusy += 1
                    return
                }
            } catch let e as PostgresClient.Error where e.kind == .connectionLost {
                record(e)
                return
            } catch {
                // The claim itself failed (a grant, a migration half applied): back off, say why once.
                stats.claimFailures += 1
                let why = Self.sanitize(error)
                note("sensor claim failed: \(why)")
                stats.lastError = "sensor_biomarker_claim: \(why)"
                stats.lastErrorKind = "sensor_biomarker_claim"
                backoffUntil = Date().addingTimeInterval(Self.claimBackoffSeconds)
                return
            }
        }
    }

    static let claimBackoffSeconds: TimeInterval = 60
    static let tablesProbeIntervalSeconds: TimeInterval = 60
    static let maxErrorLength = 300

    private mutating func note(_ message: String) {
        if message != lastLoggedReason {
            FileHandle.standardError.write("frwhoop-worker: \(message)\n".data(using: .utf8)!)
            lastLoggedReason = message
        }
    }

    private mutating func record(_ error: Error) {
        stats.lastError = String(describing: error).prefix(Self.maxErrorLength).description
        stats.lastErrorKind = (error as? PostgresClient.Error)?.kind.rawValue ?? "other"
    }

    static func sanitize(_ error: Error) -> String {
        String(describing: error).replacingOccurrences(of: "\n", with: " ").prefix(maxErrorLength).description
    }

    /// The deploy-order guard: true when the queue and RPCs exist. Re-probed once a minute while
    /// missing (mirrors `ContextLane.checkTables`).
    mutating func checkTables() -> Bool {
        if tablesPresent == true { return true }
        if let at = tablesCheckedAt, tablesPresent == false,
           Date().timeIntervalSince(at) < Self.tablesProbeIntervalSeconds {
            stats.tablesMissing += 1
            return false
        }
        tablesCheckedAt = Date()
        let present = (try? db.query(Self.tablesPresent, []))?.first?["present"].map(isTrue) ?? false
        tablesPresent = present
        if !present {
            stats.tablesMissing += 1
            stats.lastError = "sensor_tables_missing"
            stats.lastErrorKind = "sensor_tables_missing"
            note("sensor_biomarkers tables are not installed; the lane idles")
        } else if stats.lastErrorKind == "sensor_tables_missing" {
            stats.lastError = nil
            stats.lastErrorKind = nil
        }
        return present
    }

    /// Bounded reconcile (CONTRACTS.md §5): newly verified rawImuSession + ppgWaveformSample objects
    /// map into affected (owner, device, UTC day) job upserts. Idempotent and throttled; a transient
    /// failure must not block claiming.
    mutating func reconcileIfDue() {
        if let last = lastReconcileAt,
           Date().timeIntervalSince(last) < reconcileIntervalSeconds { return }
        lastReconcileAt = Date()
        stats.reconcileRuns += 1
        do {
            _ = try db.callFunctionForJSON(Self.reconcile, [Self.reconcileLookback, familiesList()])
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            record(e)
        } catch {
            stats.reconcileErrors += 1
            note("sensor reconcile failed: \(Self.sanitize(error))")
        }
    }

    static let reconcileLookback = "7 days"

    /// The family list as a Postgres array literal (the reconcile RPC takes `text[]`).
    func familiesList() -> String {
        if families.isEmpty { return "{}" }
        let inner = families.map { $0.contains(",") || $0.contains("\"") ? "\"\($0)\"" : $0 }.joined(separator: ",")
        return "{\(inner)}"
    }

    // MARK: - One job

    private mutating func cycle() throws -> Cycle {
        let rows = try db.query(Self.claim, [String(leaseSeconds)])
        guard let r = rows.first else { return .empty }
        guard let job = Self.parseJob(r) else {
            if let token = r["lease_token"], !token.isEmpty, let rev = Int64(r["input_revision"] ?? "") {
                try settleFailure(token: token, revision: rev, error: SensorBiomarkerError.deterministic("malformed_job_row"))
            }
            return .failed
        }
        do {
            let published = try process(job: job, started: Date())
            return published ? .completed : .superseded
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            stats.failuresUnsettled += 1
            throw e  // the lease expires and the queue hands the job out again
        } catch SensorBiomarkerError.busy {
            deferBusy(job: job)
            return .deferred
        } catch {
            let kind = (error as? PostgresClient.Error)?.kind ?? .other
            if kind == .serialization || kind == .stale {
                // A concurrent writer won the race; the queue owns the newer revision. Never record
                // a failure against this job.
                return .superseded
            }
            let reason = Self.sanitize(error)
            note("sensor job failed: \(reason)")
            stats.lastError = reason
            stats.lastErrorKind = "sensor_job"
            do {
                try settleFailure(job: job, error: error)
            } catch {
                stats.failuresUnsettled += 1
            }
            return .failed
        }
    }

    // MARK: - Job processing

    /// Full job processing. Returns true when the fenced publish committed.
    /// Internal so a scratch database can drive it directly with a manually-claimed token.
    mutating func process(job: SensorBiomarkerJob, started: Date) throws -> Bool {
        guard let dayBounds = Self.utcDayBounds(job.day) else {
            throw SensorBiomarkerError.deterministic("invalid_job_day \(job.day)")
        }

        // 1. Resolve the day's verified input objects through W1's resolver (the same
        //    status=ready + verified_indexed gates as the other lanes).
        guard let resolutionParams = SensorBiomarkerInputs.objectResolutionParams(
            userId: job.userId, deviceId: job.deviceId, day: job.day) else {
            throw SensorBiomarkerError.deterministic("invalid_job_day \(job.day)")
        }
        let objectRows = try db.query(SensorBiomarkerInputs.objectResolutionSQL, resolutionParams)
        let resolved = try SensorBiomarkerInputs.parseObjectRows(objectRows, userId: job.userId, deviceId: job.deviceId)
        let inputRevision = SensorBiomarkerInputs.inputRevision(objects: resolved.all)

        // 2. No verified input at all: publish an explicit all-withheld document (never a retry and
        //    never a fabricated zero). The phone shows "Not enough usable data".
        if resolved.isEmpty {
            return try publishDocument(job: job, dayBounds: dayBounds, started: started,
                                       inputRevision: inputRevision,
                                       families: allWithheldFamilies(job.families))
        }

        // 3. Download + digest-verify + decode each object (W1's decoders verify the decoded digest
        //    and the PPG format against the recorded schema before any decode). The lease is renewed
        //    BEFORE each download so the publish's fence is never hit by a long B2 phase.
        var imuRecords: [Npb1ImuDecoder.Record] = []
        var ppgInputs: [SensorBiomarkerInputs.PpgWaveformInput] = []
        var ppgObjectsByFormat: [String: Int] = [:]
        for object in resolved.all {
            guard try renewLease(job: job) else {
                throw PostgresClient.Error(message: "sensor lease lost during download", sqlstate: "55000", kind: .stale)
            }
            let wire: Data
            do {
                if let download = downloadObject {
                    wire = try download(object.objectKey)
                } else {
                    wire = try storage.download(objectKey: object.objectKey)
                }
            } catch {
                if ContextLane.isMissingObject(error) {
                    throw SensorBiomarkerError.retryable("object_missing: \(object.id)")
                }
                throw SensorBiomarkerError.retryable("object_download_failed: \(object.id): \(error)")
            }
            switch object.objectKind {
            case SensorBiomarkerInputs.kindRawImuSession:
                imuRecords.append(contentsOf: try SensorBiomarkerInputs.decodeImuObject(wire: wire, object: object))
            case SensorBiomarkerInputs.kindPpgWaveformSample:
                let records = try SensorBiomarkerInputs.decodePpgObject(wire: wire, object: object)
                if let format = records.first?.format { ppgObjectsByFormat[String(format), default: 0] += 1 }
                ppgInputs.append(contentsOf: records.map(SensorBiomarkerInputs.PpgWaveformInput.init(wireRecord:)))
            default:
                throw SensorBiomarkerError.deterministic("unsupported_object_kind: \(object.objectKind)")
            }
        }

        // 4. Build the day's timelines/runs (never fill gaps) and the bounded sidecar requests
        //    (W1: <=5-minute endpoint-owned segments packed under the sidecar's 8 MiB body budget).
        let timeline = try SensorBiomarkerInputs.imuTimeline(imuRecords)
        let imuRuns = SensorBiomarkerInputs.imuRuns(timeline)
        let ppgReconstruction = SensorBiomarkerInputs.reconstructPPG(records: ppgInputs)
        let ppgSecondsByTs = Dictionary(uniqueKeysWithValues: ppgReconstruction.seconds.map { ($0.ts, $0) })
        let placement = try loadPlacement(job: job, dayBounds: dayBounds)

        // 5. Per UTC hour, build the CONTRACTS.md §4 requests and call the sidecar. Only one
        //    hour's decoded samples are resident at a time. A request asks only for families whose
        //    input it carries; a family no request could ask for is published withheld with the
        //    coverage reason, and one the responses never report becomes `artifact_unavailable`.
        var stagesByFamily: [String: [SensorBiomarkerFamilyStage]] = [:]
        var sentFamilies = Set<String>()
        var requestCount = 0, imuSegmentsSent = 0, ppgSegmentsSent = 0
        for hourStart in stride(from: dayBounds.start, to: dayBounds.end, by: 3600) {
            let hourEnd = min(hourStart + 3600, dayBounds.end)
            let hourImu = SensorBiomarkerInputs.clip(imuRuns, from: hourStart, to: hourEnd)
            let hourPpg = SensorBiomarkerInputs.clip(ppgReconstruction.runs, from: hourStart, to: hourEnd)
            if hourImu.isEmpty && hourPpg.isEmpty { continue }
            let requests = try SensorBiomarkerInputs.buildRequests(
                imuRuns: hourImu, ppgRuns: hourPpg, imuTimeline: timeline,
                ppgSecondsByTs: ppgSecondsByTs, objects: resolved.all, deviceID: job.deviceId,
                dayUTC: job.day, watchSide: "unknown", deviceOrientation: "unknown",
                families: job.families, placement: placement)
            for built in requests {
                guard try renewLease(job: job) else {
                    throw PostgresClient.Error(message: "sensor lease lost before inference", sqlstate: "55000", kind: .stale)
                }
                let body = try Self.inferenceBody(job: job, built: built)
                let response: InferenceResponse
                do {
                    response = try inference.infer(body: body, metric: "sensor_biomarkers")
                } catch {
                    if Self.isSidecarBusy(error) {
                        stats.sidecarBusy += 1
                        throw SensorBiomarkerError.busy  // deferred: nothing of this job is kept
                    }
                    stats.sidecarFailures += 1
                    throw error  // transport/timeout: bounded retry via settleFailure
                }
                stats.sidecarRequests += 1
                requestCount += 1
                imuSegmentsSent += built.input.imu?.segments.count ?? 0
                ppgSegmentsSent += built.input.ppg?.segments.count ?? 0
                sentFamilies.formUnion(built.input.families)
                let stages = try Self.parseEnvelope(response, families: built.input.families)
                for (family, stage) in stages {
                    stagesByFamily[family, default: []].append(stage)
                }
            }
        }

        let coverage = Self.dayCoverage(dayBounds: dayBounds, timeline: timeline, imuRuns: imuRuns,
                                        ppg: ppgReconstruction, ppgSecondsByTs: ppgSecondsByTs,
                                        imuSegments: imuSegmentsSent, ppgSegments: ppgSegmentsSent)

        // 6. Merge the per-family stages across requests and assemble the day document. Movement
        //    bouts are re-classified once over the day's epoch series so a bout spanning a request
        //    seam is one bout, not two continuations.
        var familiesDoc: [String: JSONValue] = [:]
        var withoutInput: [String: String] = [:]
        for family in job.families {
            if let stages = stagesByFamily[family], !stages.isEmpty {
                var merged = try SensorBiomarkerFamilyStage.merge(stages)
                if family == "movement" {
                    merged = merged.withDayLowMovement(stages: stages, dayStart: Double(dayBounds.start),
                                                       dayEnd: Double(dayBounds.end))
                }
                if merged.status != "ok" { stats.familiesWithheld += 1 }
                familiesDoc[family] = merged.withoutInternalFields().jsonValue
            } else if !sentFamilies.contains(family) {
                // Never asked: its input modality had no eligible second in the day.
                let (reason, counts) = Self.noInputReason(family: family, resolved: resolved, coverage: coverage)
                familiesDoc[family] = SensorBiomarkerFamilyStage.withheld(family: family, reason: reason,
                                                                         reasonCounts: counts).jsonValue
                withoutInput[family] = reason
                stats.familiesWithheld += 1
                stats.familiesWithoutInput += 1
            } else {
                // Asked, but no request reported this family: explicit withheld with a precise reason.
                familiesDoc[family] = SensorBiomarkerFamilyStage.withheld(family: family, reason: "artifact_unavailable").jsonValue
                stats.familiesWithheld += 1
            }
        }
        // 7. Publish transactionally with the fence; a NULL result is never success and the lease
        //    is released through the renew+fail pair.
        let published = try publishDocument(job: job, dayBounds: dayBounds, started: started,
                                            inputRevision: inputRevision, families: familiesDoc,
                                            inputCoverage: Self.inputCoverageDocument(
                                                coverage, ppg: ppgReconstruction, objectsByFormat: ppgObjectsByFormat,
                                                withoutInput: withoutInput, requests: requestCount))
        if published {
            stats.ppgExpectedSeconds += coverage.ppg.expectedSeconds
            stats.ppgEligibleSeconds += coverage.ppg.eligibleSeconds
        }
        return published
    }

    /// The day's actual input coverage (UTC day bounds; objects can reach past them).
    struct DayCoverage {
        let imu: SensorBiomarkerInputs.ModalityCoverage
        let ppg: SensorBiomarkerInputs.ModalityCoverage
    }

    static func dayCoverage(dayBounds: (start: Int64, end: Int64), timeline: ActivityLane.ImuTimeline,
                            imuRuns: [ActivityLane.Run], ppg: SensorBiomarkerInputs.PpgReconstruction,
                            ppgSecondsByTs: [Int64: SensorBiomarkerInputs.PpgSecond],
                            imuSegments: Int, ppgSegments: Int) -> DayCoverage {
        DayCoverage(
            imu: SensorBiomarkerInputs.imuCoverage(timeline: timeline, runs: imuRuns, from: dayBounds.start,
                                                   to: dayBounds.end, segments: imuSegments),
            ppg: SensorBiomarkerInputs.ppgCoverage(secondsByTs: ppgSecondsByTs, runs: ppg.runs,
                                                   from: dayBounds.start, to: dayBounds.end, segments: ppgSegments))
    }

    /// Why a family no request asked for is withheld: no verified object of its modality at all, or
    /// every delivered second withheld (the dominant reason, with the per-reason counts).
    static func noInputReason(family: String, resolved: SensorBiomarkerInputs.ResolvedObjects,
                              coverage: DayCoverage) -> (String, [String: Int]) {
        switch SensorBiomarkerInputs.requiredModality(of: family) {
        case .ppg?:
            if resolved.ppg.isEmpty || coverage.ppg.expectedSeconds == 0 { return ("artifact_unavailable", [:]) }
            return (coverage.ppg.dominantWithheldReason ?? "artifact_unavailable", coverage.ppg.withheld)
        case .imu?, nil:
            return ("artifact_unavailable", [:])
        }
    }

    /// The `input_coverage` member of the day document: what the day's input actually was.
    static func inputCoverageDocument(_ coverage: DayCoverage, ppg: SensorBiomarkerInputs.PpgReconstruction,
                                      objectsByFormat: [String: Int], withoutInput: [String: String],
                                      requests: Int) -> JSONValue {
        var ppgDoc = coverage.ppg.jsonObject()
        ppgDoc["conflicting_duplicate_seconds"] = ppg.conflictingDuplicateSeconds.count
        ppgDoc["superseded_duplicate_seconds"] = ppg.supersededDuplicateSeconds
        ppgDoc["detected_delta_counts"] = Dictionary(uniqueKeysWithValues: ppg.detectedDeltaCounts.map { (String($0.key), $0.value) })
        ppgDoc["seconds_by_format"] = Dictionary(uniqueKeysWithValues: ppg.secondsByFormat.map { (String($0.key), $0.value) })
        ppgDoc["objects_by_format"] = objectsByFormat
        ppgDoc["grid"] = ppg.grid.rawValue
        ppgDoc["samples_per_second"] = ppg.grid.samplesPerRecord
        ppgDoc["packet_timing_verified"] = false
        return JSONValue(any: [
            "imu": coverage.imu.jsonObject(),
            "ppg": ppgDoc,
            "families_without_input": withoutInput,
            "requests": requests,
        ] as [String: Any])
    }

    static let placementPresentSQL = "select (to_regclass('public.placement_intervals') is not null)::text as present"
    /// The owner's recorded placement for the device (and user-level declarations) overlapping the day.
    static let placementSQL = """
        select p.placement as placement, p.source as source, (p.device_id is not null)::text as device_scoped,
               extract(epoch from p.effective_start)::bigint::text as start_ts,
               coalesce(extract(epoch from p.effective_end)::bigint::text, '') as end_ts
          from public.placement_intervals p
         where p.owner = $1::uuid and (p.device_id = $2::uuid or p.device_id is null)
           and p.effective_start < $3::timestamptz
           and (p.effective_end is null or p.effective_end > $4::timestamptz)
         order by p.effective_start, p.id
        """

    static func parsePlacementRows(_ rows: [[String: String]]) -> [SensorBiomarkerInputs.PlacementInterval] {
        rows.compactMap { row in
            guard let placement = row["placement"], !placement.isEmpty, let source = row["source"],
                  let start = Int64(row["start_ts"] ?? "") else { return nil }
            return .init(start: start, end: Int64(row["end_ts"] ?? ""), placement: placement, source: source,
                         deviceScoped: isTrue(row["device_scoped"]))
        }
    }

    /// Recorded placement for the job's day. Optional context: a database without the table, or a
    /// failed read, gives undeclared placement (counted), never a failed job.
    private mutating func loadPlacement(job: SensorBiomarkerJob,
                                        dayBounds: (start: Int64, end: Int64)) throws -> [SensorBiomarkerInputs.PlacementInterval] {
        do {
            if placementTablePresent == nil {
                placementTablePresent = (try db.query(Self.placementPresentSQL, [])).first?["present"].map(isTrue) ?? false
            }
            guard placementTablePresent == true else { return [] }
            let rows = try db.query(Self.placementSQL, [job.userId, job.deviceId,
                                                        Self.iso(dayBounds.end), Self.iso(dayBounds.start)])
            return Self.parsePlacementRows(rows)
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            throw e
        } catch {
            stats.placementReadErrors += 1
            return []
        }
    }

    /// Shorten the claimed lease to the busy retry delay so the job comes back without spending
    /// its failure budget, and hold this lane off for the same time.
    private mutating func deferBusy(job: SensorBiomarkerJob) {
        _ = try? db.callFunctionForJSON(Self.renew, [job.leaseToken, String(Self.busyRetrySeconds)])
        backoffUntil = Date().addingTimeInterval(TimeInterval(Self.busyRetrySeconds))
        note("sensor sidecar busy; job deferred \(Self.busyRetrySeconds)s")
    }

    /// The sidecar requires every context version to be a non-empty string. Sensor biomarkers
    /// read no user profile and no corrections, so those are pinned to "none".
    static func inferenceBody(job: SensorBiomarkerJob,
                              built: SensorBiomarkerInputs.BuiltRequest) throws -> Data {
        let context = InferenceRequest.Context(
            userId: job.userId, deviceId: job.deviceId,
            intervalStartUTC: built.intervalStartUTC, intervalEndUTC: built.intervalEndUTC,
            ianaTimezone: "UTC", profileVersion: "none",
            configVersion: analysisVersion, correctionsVersion: "none")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var body = Data("{\"context\":".utf8)
        body.append(try encoder.encode(context))
        body.append(Data(",\"input\":".utf8))
        body.append(built.inputJSON)
        body.append(Data(",\"metric\":\"sensor_biomarkers\",\"provider\":".utf8))
        body.append(try encoder.encode(InferenceRequest.Provider(providerId: providerId)))
        body.append(Data("}".utf8))
        return body
    }

    /// Build all-withheld families for a day with no usable input.
    mutating func allWithheldFamilies(_ families: [String]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for family in families {
            out[family] = SensorBiomarkerFamilyStage.withheld(family: family, reason: "artifact_unavailable").jsonValue
            stats.familiesWithheld += 1
        }
        return out
    }

    /// Assemble and fenced-publish the day document. Returns true when the publish committed.
    private mutating func publishDocument(job: SensorBiomarkerJob,
                                          dayBounds: (start: Int64, end: Int64),
                                          started: Date, inputRevision: String,
                                          families: [String: JSONValue],
                                          inputCoverage: JSONValue? = nil) throws -> Bool {
        let document = Self.dayDocument(day: job.day, dayBounds: dayBounds, inputRevision: inputRevision,
                                        processedAt: Date(), families: families, inputCoverage: inputCoverage)
        let status = dayBounds.end <= Int64(Date().timeIntervalSince1970) ? "completed" : "provisional"
        let runMs = Int(Date().timeIntervalSince(started) * 1000)
        let payload = try Self.publishPayload(day: job.day, status: status, runMs: runMs, document: document)
        let result = try db.callFunctionForJSON(Self.publish, [job.leaseToken, String(job.inputRevision), payload])
        guard let result, !result.isEmpty else {
            // Fenced: the lease is gone or the revision moved. Release cleanly; the queue owns the
            // newer work. Never a failure.
            try releaseLease(job: job)
            return false
        }
        stats.published += 1
        if families.values.allSatisfy({ stage in
            if case .object(let obj) = stage, obj["status"]?.stringValue != "ok" { return true }
            return false
        }) {
            stats.publishedEmpty += 1
        }
        return true
    }

    // MARK: - Envelope parsing and day document

    /// Parse one sidecar response into per-family stages. A top-level `withheld` or `error` status
    /// (a provider verdict) becomes withheld families with the envelope's reason — the lane never
    /// retries a verdict. A family the response did not report becomes `artifact_unavailable`.
    static func parseEnvelope(_ response: InferenceResponse, families: [String]) throws -> [String: SensorBiomarkerFamilyStage] {
        var out: [String: SensorBiomarkerFamilyStage] = [:]
        if response.status == "withheld", response.withheldReason == "timeout" {
            // A blown request budget is load, not a verdict on the data.
            throw SensorBiomarkerError.retryable("sidecar_timeout")
        }
        if response.status == "withheld" || response.status == "error" {
            let reason = response.withheldReason ?? (response.status == "withheld" ? "provider_withheld" : "provider_error")
            for family in families {
                out[family] = SensorBiomarkerFamilyStage.withheld(family: family, reason: reason)
            }
            return out
        }
        guard response.status == "ok" else {
            throw SensorBiomarkerError.deterministic("unknown_response_status: \(response.status)")
        }
        // The sidecar's envelope carries `stages` as a list of family documents, each naming its
        // `family`; an object keyed by family is accepted too.
        var stages: [(String, JSONValue)] = []
        switch response.result?.stages {
        case .array(let list)?:
            for stageJSON in list {
                guard case .object(let obj) = stageJSON, let family = obj["family"]?.stringValue else {
                    throw SensorBiomarkerError.deterministic("stage_missing_family")
                }
                stages.append((family, stageJSON))
            }
        case .object(let keyed)?:
            stages = keyed.map { ($0.key, $0.value) }
        default:
            throw SensorBiomarkerError.deterministic("missing_result_stages")
        }
        for (family, stageJSON) in stages {
            guard familyKeys.contains(family) else {
                throw SensorBiomarkerError.deterministic("unknown_family: \(family)")
            }
            // A stage for a family this request did not ask for is not one of its results.
            guard families.contains(family) else { continue }
            out[family] = try SensorBiomarkerFamilyStage.parse(family: family, stageJSON)
        }
        return out
    }

    /// Assemble the CONTRACTS.md §3 day document. `input_coverage` (additive) is the day's actual
    /// input: expected vs eligible seconds per modality, withheld seconds by reason, the PPG grid and
    /// formats, and the families no request could ask for.
    static func dayDocument(day: String, dayBounds: (start: Int64, end: Int64), inputRevision: String,
                            processedAt: Date, families: [String: JSONValue],
                            inputCoverage: JSONValue? = nil) -> [String: JSONValue] {
        var doc: [String: JSONValue] = [
            "schema_version": .int(1),
            "analysis_version": .string(analysisVersion),
            "input_revision": .string(inputRevision),
            "interval_start_utc": .string(Self.iso(dayBounds.start)),
            "interval_end_utc": .string(Self.iso(dayBounds.end)),
            "processed_at_utc": .string(processedAt.sensorISO()),
            "families": .object(families),
        ]
        if let inputCoverage { doc["input_coverage"] = inputCoverage }
        _ = day
        return doc
    }

    /// The `publish_sensor_biomarker_day` payload.
    static func publishPayload(day: String, status: String, runMs: Int, document: [String: JSONValue]) throws -> String {
        var modelRevisions: [String: JSONValue] = [:]
        if case .object(let families)? = document["families"] {
            for (family, stage) in families {
                if case .object(let obj) = stage, let rev = obj["provider_revision"]?.stringValue {
                    modelRevisions[family] = .string(rev)
                }
            }
        }
        let payload: [String: JSONValue] = [
            "day": .string(day),
            "status": .string(status),
            "run_ms": .int(runMs),
            "model_revisions": .object(modelRevisions),
            "document": .object(document),
        ]
        let data = try JSONSerialization.data(withJSONObject: JSONValue(any: payload).anyValue, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Settlement

    private mutating func settleFailure(job: SensorBiomarkerJob, error: Error) throws {
        try settleFailure(token: job.leaseToken, revision: job.inputRevision, error: error)
    }

    private mutating func settleFailure(token: String, revision: Int64, error: Error) throws {
        let detail = Self.sanitize(error)
        do {
            _ = try db.callFunctionForJSON(Self.fail, [token, String(revision), "sensor_\(detail)"])
            stats.failuresPersisted += 1
        } catch {
            stats.failuresUnsettled += 1
        }
    }

    /// Release a lease whose publication did not complete (there is no bare release RPC): renew to
    /// confirm the lease is still ours, then fail with the CLAIMED revision. The fenced fail RPC
    /// treats a revision mismatch as a clean release (mirrors `ActivityLane.releaseLease`).
    private mutating func releaseLease(job: SensorBiomarkerJob) throws {
        let renewed = isTrue(try db.callFunctionForJSON(Self.renew, [job.leaseToken, String(leaseSeconds)]))
        guard renewed else { return }
        _ = try db.callFunctionForJSON(Self.fail,
            [job.leaseToken, String(job.inputRevision), "sensor_publish_not_completed:claimed_revision=\(job.inputRevision)"])
    }

    private func renewLease(job: SensorBiomarkerJob) throws -> Bool {
        isTrue(try db.callFunctionForJSON(Self.renew, [job.leaseToken, String(leaseSeconds)]))
    }
}

/// One family's stage from the sidecar (`result.stages[family]`), parsed and merged by the lane.
struct SensorBiomarkerFamilyStage {
    let family: String
    let status: String
    let releaseTier: String
    let providerRevision: String
    let observedSeconds: Double?
    let eligibleSeconds: Double?
    let contactState: String?
    let reason: String?
    let reasonCounts: [String: Int]
    /// The measurements object, preserved verbatim (the contract's stable keys).
    let measurements: JSONValue
    /// Any other stage fields, preserved.
    let extra: [String: JSONValue]

    /// Parse one stage object (CONTRACTS.md §3). A malformed stage is a deterministic error: the
    /// lane must never publish a stage it cannot understand.
    static func parse(family: String, _ value: JSONValue) throws -> SensorBiomarkerFamilyStage {
        guard case .object(let obj) = value else {
            throw SensorBiomarkerLane.SensorBiomarkerError.deterministic("stage_not_object:\(family)")
        }
        guard let status = obj["status"]?.stringValue, ["ok", "withheld", "error"].contains(status) else {
            throw SensorBiomarkerLane.SensorBiomarkerError.deterministic("stage_bad_status:\(family)")
        }
        let releaseTier = obj["release_tier"]?.stringValue ?? "research"
        let providerRevision = obj["provider_revision"]?.stringValue ?? ""
        let measurements = obj["measurements"] ?? .object([:])
        guard case .object = measurements else {
            throw SensorBiomarkerLane.SensorBiomarkerError.deterministic("stage_bad_measurements:\(family)")
        }
        var reasonCounts: [String: Int] = [:]
        if let rc = obj["reason_counts"] {
            guard case .object(let counts) = rc else {
                throw SensorBiomarkerLane.SensorBiomarkerError.deterministic("stage_bad_reason_counts:\(family)")
            }
            for (k, v) in counts {
                if let n = v.intValue { reasonCounts[k] = n }
            }
        }
        let observed = obj["observed_seconds"]?.doubleValue
        let eligible = obj["eligible_seconds"]?.doubleValue
        let contactState = obj["contact_state"]?.stringValue
        let reason = obj["reason"]?.stringValue
        var extra: [String: JSONValue] = [:]
        for (k, v) in obj where !["status", "release_tier", "provider_revision", "measurements",
            "observed_seconds", "eligible_seconds", "contact_state", "reason", "reason_counts"].contains(k) {
            extra[k] = v
        }
        return SensorBiomarkerFamilyStage(family: family, status: status, releaseTier: releaseTier,
            providerRevision: providerRevision, observedSeconds: observed, eligibleSeconds: eligible,
            contactState: contactState, reason: reason, reasonCounts: reasonCounts,
            measurements: measurements, extra: extra)
    }

    /// A family the lane withholds itself (no data, or the sidecar did not report it).
    static func withheld(family: String, reason: String,
                         reasonCounts: [String: Int] = [:]) -> SensorBiomarkerFamilyStage {
        SensorBiomarkerFamilyStage(family: family, status: "withheld",
            releaseTier: SensorBiomarkerLane.releaseTier(family),
            providerRevision: SensorBiomarkerLane.providerRevision(family),
            observedSeconds: nil, eligibleSeconds: nil, contactState: nil, reason: reason,
            reasonCounts: reasonCounts, measurements: .object([:]), extra: [:])
    }

    /// The merged stage over the day's requests. Coverage and reason counts are additive; count and
    /// second measurements are additive; quantile measurements (median/p95/iqr/percent) come from
    /// the request with the largest observed coverage, because a distribution summary cannot be
    /// re-derived from aggregated summaries. A family is `ok` when at least one request produced it;
    /// the withheld `reason` is only set when EVERY request withheld it.
    static func merge(_ stages: [SensorBiomarkerFamilyStage]) throws -> SensorBiomarkerFamilyStage {
        guard let first = stages.first else {
            throw SensorBiomarkerLane.SensorBiomarkerError.deterministic("merge_empty_stages")
        }
        let family = first.family
        let status: String = stages.contains { $0.status == "ok" } ? "ok" : first.status
        var observed = 0.0
        var eligible = 0.0
        var reasonCounts: [String: Int] = [:]
        var contact: String? = nil
        for s in stages {
            observed += s.observedSeconds ?? 0
            eligible += s.eligibleSeconds ?? 0
            if let c = s.contactState, contact == nil { contact = c }
            for (k, v) in s.reasonCounts { reasonCounts[k, default: 0] += v }
        }
        var reason: String? = nil
        if !stages.contains(where: { $0.status == "ok" }) {
            // Every request withheld this family; pick the most common explicit reason.
            var counts: [String: Int] = [:]
            for s in stages { if let r = s.reason { counts[r, default: 0] += 1 } }
            reason = counts.max { $0.value < $1.value }?.key
            if reason == nil { reason = first.reason ?? first.status }
        }
        // The best request for quantile measurements: largest observed coverage, ties to the first.
        let best = stages.enumerated().max { a, b in
            let ca = a.element.observedSeconds ?? 0
            let cb = b.element.observedSeconds ?? 0
            if ca == cb { return a.offset > b.offset }
            return ca < cb
        }!.element
        var mergedMeasurements: [String: JSONValue] = [:]
        var keys: [String] = []
        for s in stages {
            if case .object(let m) = s.measurements {
                for k in m.keys where !keys.contains(k) { keys.append(k) }
            }
        }
        // A family reporting per-configuration blocks carries top-level values only for one known
        // configuration (the sidecar's own rule). Across requests that means one known identity for
        // the whole day; otherwise the top level is never pooled across identities or runs.
        let identities = configurationIdentities(stages)
        let poolsTopLevel = identities == nil || (identities!.count == 1 && !identities!.contains(Self.unknownIdentity))
        if !poolsTopLevel { keys = [] }
        for key in keys {
            if isAdditiveMeasurement(key) || isMaximumMeasurement(key) {
                let additive = isAdditiveMeasurement(key)
                var merged: Double? = nil
                var countSum = 0
                var anyCount = false
                var template: [String: JSONValue]? = nil
                for s in stages {
                    guard case .object(let m) = s.measurements, let entry = m[key] else { continue }
                    let fields: [String: JSONValue]
                    if case .object(let f) = entry { fields = f } else { fields = ["value": entry] }
                    if template == nil { template = fields }
                    if let n = fields["count"]?.doubleValue, n.isFinite, abs(n) < 1e15 {
                        countSum += Int(n)
                        anyCount = true
                    }
                    guard let v = fields["value"]?.doubleValue, v.isFinite else { continue }
                    merged = additive ? (merged ?? 0) + v : max(merged ?? v, v)
                }
                if var fields = template {
                    fields["value"] = merged.map { .double($0) } ?? .null
                    if additive && anyCount { fields["count"] = .int(countSum) }
                    fields["aggregation"] = .string(additive ? "summed-day" : "max-day")
                    mergedMeasurements[key] = .object(fields)
                }
            } else if let pooled = pooledDayQuantile(key: key, stages: stages) {
                // Day-level quantile from the POOLED bounded-bin distribution
                // across every request (spec section 8: day quantiles aggregate
                // over the day's epochs/windows/pulses), never one chunk's value
                // presented as the day's. Falls back to the best-coverage
                // carry below when the stages carry no consistent distribution.
                if case .object(let m) = best.measurements, let v = m[key] {
                    var entry = m
                    if case .object(var fields) = v {
                        fields["value"] = .double(pooled)
                        fields["aggregation"] = .string("pooled-day-bins")
                        entry[key] = .object(fields)
                    } else {
                        entry[key] = .object(["value": .double(pooled),
                                               "aggregation": .string("pooled-day-bins")])
                    }
                    mergedMeasurements[key] = entry[key]
                } else {
                    mergedMeasurements[key] = .object(["value": .double(pooled),
                                                       "aggregation": .string("pooled-day-bins")])
                }
            } else {
                if case .object(let m) = best.measurements, let v = m[key] { mergedMeasurements[key] = v }
            }
        }
        var extra = mergedExtra(stages)
        if !poolsTopLevel {
            extra["pooled_across_configurations"] = .bool(false)
            extra["distributions"] = nil
        }
        if status != "ok", let reason { extra["reason"] = .string(reason) }
        return SensorBiomarkerFamilyStage(family: family, status: status, releaseTier: first.releaseTier,
            providerRevision: first.providerRevision, observedSeconds: observed, eligibleSeconds: eligible,
            contactState: contact, reason: reason, reasonCounts: reasonCounts,
            measurements: .object(mergedMeasurements), extra: extra)
    }

    static let unknownIdentity = "unknown"
    /// Bounds on what the day merge keeps of per-request blocks.
    static let maxMergedRuns = 2_048
    static let maxMergedScoreValues = 20_000

    /// The configuration identities a family's stages report, or nil when none reports blocks.
    static func configurationIdentities(_ stages: [SensorBiomarkerFamilyStage]) -> Set<String>? {
        var found: Set<String>? = nil
        for stage in stages {
            guard case .array(let blocks)? = stage.extra["configurations"] else { continue }
            if found == nil { found = [] }
            for block in blocks {
                guard case .object(let fields) = block else { continue }
                found!.insert(fields["configuration"]?.stringValue ?? Self.unknownIdentity)
            }
        }
        return found
    }

    /// Per-request stage members the day must keep. Per-configuration pulse blocks merge per identity
    /// (counts summed, distribution bins pooled); per-run exposure blocks and rhythm score vectors are
    /// kept from every request in request order, bounded. Every other member keeps the first
    /// request's value, as before.
    static func mergedExtra(_ stages: [SensorBiomarkerFamilyStage]) -> [String: JSONValue] {
        var extra = stages[0].extra
        let blocks = stages.flatMap { stage -> [JSONValue] in
            if case .array(let list)? = stage.extra["configurations"] { return list }
            return []
        }
        if !blocks.isEmpty { extra["configurations"] = .array(mergeConfigurationBlocks(blocks)) }
        let runs = stages.flatMap { stage -> [JSONValue] in
            if case .array(let list)? = stage.extra["runs"] { return list }
            return []
        }
        if !runs.isEmpty {
            extra["runs"] = .array(Array(runs.prefix(maxMergedRuns)))
            if runs.count > maxMergedRuns { extra["runs_truncated"] = .bool(true) }
        }
        let scoreMaps = stages.compactMap { stage -> [String: JSONValue]? in
            if case .object(let map)? = stage.extra["raw_scores"] { return map }
            return nil
        }
        if !scoreMaps.isEmpty {
            var merged: [String: JSONValue] = [:]
            var truncated = false
            for key in Set(scoreMaps.flatMap(\.keys)).sorted() {
                let values = scoreMaps.compactMap { $0[key] }
                if values.allSatisfy({ if case .array = $0 { return true }; return false }) {
                    let joined = values.flatMap { value -> [JSONValue] in
                        if case .array(let list) = value { return list }
                        return []
                    }
                    if joined.count > maxMergedScoreValues { truncated = true }
                    merged[key] = .array(Array(joined.prefix(maxMergedScoreValues)))
                } else {
                    if values.count > 256 { truncated = true }
                    merged[key] = .array(Array(values.prefix(256)))
                }
            }
            extra["raw_scores"] = .object(merged)
            if truncated { extra["raw_scores_truncated"] = .bool(true) }
        }
        return extra
    }

    /// Merge `configurations` blocks across requests. Blocks with the same known identity combine:
    /// `segments`/`accepted`/`eligible_seconds`/`rejected.*` sum, `distributions` pool per key when the
    /// edges agree, quantile measurements are re-derived from the pooled bins and count measurements
    /// sum. An "unknown" identity is never comparable to anything, so those blocks stay separate.
    static func mergeConfigurationBlocks(_ blocks: [JSONValue]) -> [JSONValue] {
        var order: [String] = []
        var groups: [String: [[String: JSONValue]]] = [:]
        var separate: [(Int, JSONValue)] = []
        for (index, block) in blocks.enumerated() {
            guard case .object(let fields) = block,
                  let identity = fields["configuration"]?.stringValue, identity != Self.unknownIdentity else {
                separate.append((index, block)); continue
            }
            if groups[identity] == nil { order.append(identity) }
            groups[identity, default: []].append(fields)
        }
        var out: [JSONValue] = order.map { .object(mergeConfigurationGroup(groups[$0]!)) }
        out.append(contentsOf: separate.map(\.1))
        return out
    }

    static func mergeConfigurationGroup(_ group: [[String: JSONValue]]) -> [String: JSONValue] {
        guard group.count > 1 else { return group[0] }
        var merged = group[0]
        func sum(_ key: String) -> Double { group.reduce(0) { $0 + ($1[key]?.doubleValue ?? 0) } }
        for key in ["segments", "accepted"] where merged[key] != nil { merged[key] = .int(Int(sum(key))) }
        if merged["eligible_seconds"] != nil { merged["eligible_seconds"] = .double(sum("eligible_seconds")) }
        var rejected: [String: Int] = [:]
        for block in group {
            if case .object(let counts)? = block["rejected"] {
                for (k, v) in counts { rejected[k, default: 0] += v.intValue ?? 0 }
            }
        }
        if !rejected.isEmpty { merged["rejected"] = .object(rejected.mapValues { .int($0) }) }

        // Distributions pool per key when every block agrees on the edges.
        var distributionKeys: [String] = []
        var byKey: [String: [DayDistribution]] = [:]
        for block in group {
            guard case .array(let list)? = block["distributions"] else { continue }
            for item in list {
                guard case .object(let b) = item, let key = b["key"]?.stringValue,
                      case .array(let edgeVals)? = b["edges"], case .array(let countVals)? = b["counts"] else { continue }
                let edges = edgeVals.compactMap { $0.doubleValue }, counts = countVals.compactMap { $0.intValue }
                guard edges.count == counts.count + 1, !edges.isEmpty else { continue }
                if byKey[key] == nil { distributionKeys.append(key) }
                byKey[key, default: []].append(DayDistribution(key: key, edges: edges, counts: counts))
            }
        }
        var pooledByKey: [String: DayDistribution] = [:]
        var distributions: [JSONValue] = []
        for key in distributionKeys {
            let found = byKey[key]!
            guard found.allSatisfy({ $0.edges == found[0].edges }) else { continue }
            var counts = [Int](repeating: 0, count: found[0].counts.count)
            for d in found { for (i, c) in d.counts.enumerated() { counts[i] += c } }
            let pooled = DayDistribution(key: key, edges: found[0].edges, counts: counts)
            pooledByKey[key] = pooled
            distributions.append(.object(["key": .string(key), "edges": .array(pooled.edges.map { .double($0) }),
                                          "counts": .array(counts.map { .int($0) }), "n": .int(pooled.n)]))
        }
        if !distributions.isEmpty { merged["distributions"] = .array(distributions) }

        // Measurements: counts sum, quantiles re-derive from pooled bins, anything else comes from the
        // block with the most eligible seconds.
        let best = group.max { ($0["eligible_seconds"]?.doubleValue ?? 0) < ($1["eligible_seconds"]?.doubleValue ?? 0) }!
        var measurements: [String: JSONValue] = [:]
        if case .object(let template)? = best["measurements"] { measurements = template }
        for key in measurements.keys {
            guard case .object(var fields)? = measurements[key] else { continue }
            if key.hasSuffix("_count") {
                var total = 0.0
                for block in group {
                    if case .object(let m)? = block["measurements"], case .object(let f)? = m[key] {
                        total += f["value"]?.doubleValue ?? 0
                    }
                }
                fields["value"] = .double(total)
                fields["count"] = .int(Int(total))
                fields["aggregation"] = .string("summed-day")
            } else if let quantile = quantileFromPooled(key: key, pooled: pooledByKey) {
                fields["value"] = .double(quantile.value)
                fields["count"] = .int(quantile.n)
                fields["aggregation"] = .string("pooled-day-bins")
            } else {
                fields["aggregation"] = .string("best-coverage")
            }
            measurements[key] = .object(fields)
        }
        if !measurements.isEmpty { merged["measurements"] = .object(measurements) }
        return merged
    }

    /// A quantile measurement re-derived from a pooled distribution keyed by its `_median` name.
    static func quantileFromPooled(key: String, pooled: [String: DayDistribution]) -> (value: Double, n: Int)? {
        var base = key, q = 0.5, iqr = false
        if let r = key.range(of: "_p95") { base = key.replacingCharacters(in: r, with: "_median"); q = 0.95 }
        else if let r = key.range(of: "_p25") { base = key.replacingCharacters(in: r, with: "_median"); q = 0.25 }
        else if let r = key.range(of: "_iqr") { base = key.replacingCharacters(in: r, with: "_median"); iqr = true }
        guard base.contains("_median"), let d = pooled[base], d.n > 0 else { return nil }
        if iqr {
            return (quantileFromBins(edges: d.edges, counts: d.counts, n: d.n, q: 0.75)
                    - quantileFromBins(edges: d.edges, counts: d.counts, n: d.n, q: 0.25), d.n)
        }
        return (quantileFromBins(edges: d.edges, counts: d.counts, n: d.n, q: q), d.n)
    }

    /// Request-internal stage fields consumed by the merge; never published.
    static let internalExtraKeys: Set<String> = ["enmo_epochs", "distributions"]

    func withoutInternalFields() -> SensorBiomarkerFamilyStage {
        SensorBiomarkerFamilyStage(family: family, status: status, releaseTier: releaseTier,
            providerRevision: providerRevision, observedSeconds: observedSeconds,
            eligibleSeconds: eligibleSeconds, contactState: contactState, reason: reason,
            reasonCounts: reasonCounts, measurements: measurements,
            extra: extra.filter { !Self.internalExtraKeys.contains($0.key) })
    }

    static let enmoEpochSeconds = 5.0
    static let lowMovementEnterMg = 30.0
    static let lowMovementLeaveMg = 50.0

    struct DayLowMovement: Equatable {
        var lowSeconds = 0.0
        var lowEpochs = 0
        var classifiedSeconds = 0.0
        var unknownEpochs = 0
        var boutDurations: [Double] = []
        var censored = 0
        var continuations = 0
        var transitions = 0
    }

    /// The sidecar's hysteresis and bout rules (`imu.classify_bouts`) over the whole UTC day:
    /// enter < 30 mg, leave >= 50 mg, the middle band keeps the prior state, and any epoch that
    /// does not directly follow its predecessor starts a new run (state unknown, open bout
    /// censored, no transition). A bout touching a day edge is a continuation.
    static func classifyDayLowMovement(epochs: [(start: Double, mg: Double)],
                                       dayStart: Double, dayEnd: Double) -> DayLowMovement {
        var out = DayLowMovement()
        var state = "unknown"
        var prevState: String? = nil
        var prevStart: Double? = nil
        var openBout: Double? = nil
        for (start, mg) in epochs {
            if let p = prevStart, start - p > enmoEpochSeconds + 1e-6 {
                if let bout = openBout {
                    out.boutDurations.append(bout)
                    out.censored += 1
                    openBout = nil
                }
                prevState = nil
                state = "unknown"
            }
            if mg < lowMovementEnterMg { state = "low" } else if mg >= lowMovementLeaveMg { state = "moving" }
            if state == "low" {
                if openBout == nil {
                    openBout = 0
                    if start <= dayStart + 1e-9 { out.continuations += 1 }
                }
                openBout! += enmoEpochSeconds
                out.lowSeconds += enmoEpochSeconds
                out.lowEpochs += 1
            } else {
                if let bout = openBout {
                    out.boutDurations.append(bout)
                    if start + enmoEpochSeconds >= dayEnd - 1e-9 { out.continuations += 1 }
                    openBout = nil
                }
                if prevState == "low" && state == "moving" { out.transitions += 1 }
            }
            if state == "unknown" { out.unknownEpochs += 1 } else { out.classifiedSeconds += enmoEpochSeconds }
            prevState = state
            prevStart = start
        }
        if let bout = openBout {
            out.boutDurations.append(bout)
            if let last = prevStart, last + enmoEpochSeconds >= dayEnd - 1e-9 {
                out.continuations += 1
            } else {
                out.censored += 1
            }
        }
        return out
    }

    /// The merged movement stage with its low-movement summaries re-derived from the day's
    /// concatenated epoch series, so a bout spanning a request seam is one bout and the
    /// fraction/rates cover the whole day. Unchanged when no request was gravity-calibrated.
    func withDayLowMovement(stages: [SensorBiomarkerFamilyStage], dayStart: Double,
                            dayEnd: Double) -> SensorBiomarkerFamilyStage {
        var byStart: [Double: Double] = [:]
        for s in stages where s.status == "ok" && s.extra["calibrated"] == .bool(true) {
            guard case .array(let rows)? = s.extra["enmo_epochs"] else { continue }
            for row in rows {
                guard case .array(let pair) = row, pair.count == 2,
                      let start = pair[0].doubleValue, let mg = pair[1].doubleValue,
                      start.isFinite, mg.isFinite,
                      start >= dayStart, start + Self.enmoEpochSeconds <= dayEnd else { continue }
                byStart[start] = mg
            }
        }
        guard !byStart.isEmpty else { return self }
        let epochs = byStart.sorted { $0.key < $1.key }.map { (start: $0.key, mg: $0.value) }
        let day = Self.classifyDayLowMovement(epochs: epochs, dayStart: dayStart, dayEnd: dayEnd)

        var m: [String: JSONValue] = [:]
        if case .object(let existing) = measurements { m = existing }
        for key in m.keys where key.hasPrefix("low_movement_") || key.hasPrefix("low_to_moving_") {
            m[key] = nil
        }
        func entry(_ value: Double, _ unit: String, count: Int, method: String,
                   denominator: String? = nil) -> JSONValue {
            var fields: [String: JSONValue] = [
                "value": .double(value), "unit": .string(unit), "count": .int(count),
                "method": .string(method), "aggregation": .string("day-classified"),
            ]
            if let denominator { fields["denominator"] = .string(denominator) }
            return .object(fields)
        }
        let bouts = day.boutDurations.count
        if day.classifiedSeconds > 0 {
            let hours = day.classifiedSeconds / 3600
            m["low_movement_seconds"] = entry(day.lowSeconds, "s", count: day.lowEpochs,
                method: "hysteretic low state per epoch", denominator: "classified observed seconds")
            m["low_movement_fraction"] = entry(day.lowSeconds / day.classifiedSeconds, "fraction",
                count: day.lowEpochs, method: "low seconds / classified seconds",
                denominator: "classified observed seconds")
            m["low_movement_bout_count"] = entry(Double(bouts), "count", count: bouts,
                method: "maximal low-state runs across epochs")
            if !day.boutDurations.isEmpty {
                let sorted = day.boutDurations.sorted()
                let mid = sorted.count / 2
                let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
                m["low_movement_bout_median_seconds"] = entry(median, "s", count: bouts,
                    method: "median bout duration")
                m["low_movement_bout_max_seconds"] = entry(sorted.last!, "s", count: bouts,
                    method: "maximum bout duration")
            }
            m["low_to_moving_transition_count"] = entry(Double(day.transitions), "count",
                count: day.transitions, method: "low->moving hysteresis crossings, none across gaps")
            m["low_to_moving_transitions_per_observed_hour"] = entry(Double(day.transitions) / hours,
                "transitions/hour", count: day.transitions,
                method: "transitions / classified observed hours", denominator: "classified observed hours")
            m["low_movement_bouts_per_observed_hour"] = entry(Double(bouts) / hours, "bouts/hour",
                count: bouts,
                method: "DESCRIPTIVE simple count per classified observed hour; NOT a validated GGIR fragmentation score",
                denominator: "classified observed hours")
        }
        var counts = reasonCounts
        counts["censored_bouts"] = day.censored
        counts["continuation_bouts"] = day.continuations
        counts["unknown_state_epochs"] = day.unknownEpochs
        var ext = extra
        ext["low_movement_censored_bout_count"] = .int(day.censored)
        ext["low_movement_continuation_count"] = .int(day.continuations)
        ext["calibrated"] = .bool(true)
        return SensorBiomarkerFamilyStage(family: family, status: status, releaseTier: releaseTier,
            providerRevision: providerRevision, observedSeconds: observedSeconds,
            eligibleSeconds: day.classifiedSeconds, contactState: contactState, reason: reason,
            reasonCounts: counts, measurements: .object(m), extra: ext)
    }

    /// Keys whose values are additive across the day's requests (counts and seconds). Quantile and
    /// rate keys are NOT additive and are pooled from the day's bounded-bin distributions instead
    /// (falling back to the best-coverage request when a stage carries no consistent distribution).
    static func isAdditiveMeasurement(_ key: String) -> Bool {
        (key.hasSuffix("_seconds") || key.hasSuffix("_count")) && !isQuantileOrExtremeMeasurement(key)
    }

    /// Keys that are a per-request maximum (`low_movement_bout_max_seconds`): the day value is the
    /// largest of the requests' values, never their sum.
    static func isMaximumMeasurement(_ key: String) -> Bool {
        key.contains("_max_") || key.hasSuffix("_max")
    }

    private static func isQuantileOrExtremeMeasurement(_ key: String) -> Bool {
        ["_median", "_p25", "_p75", "_p95", "_iqr", "_max", "_min", "_mean"].contains { key.contains($0) }
    }

    /// A mergeable bounded-bin distribution from one stage (`extra.distributions[]`).
    struct DayDistribution {
        let key: String
        let edges: [Double]
        let counts: [Int]
        var n: Int { counts.reduce(0, +) }
    }

    /// The day-level value for one quantile measurement key, pooled from the
    /// stages' bounded-bin distributions (CONTRACTS.md section 8 / spec 8).
    /// Returns nil when the stages carry no distribution for the key or their
    /// edges disagree (the lane then falls back to the best-coverage carry and
    /// never silently mixes edge sets).
    static func pooledDayQuantile(key: String, stages: [SensorBiomarkerFamilyStage]) -> Double? {
        // The distribution block is keyed by the measurement family's median key:
        // enmo_p95_mg/enmo_median_mg, template_similarity_p25/..._median,
        // pulse_amplitude_iqr_au/pulse_amplitude_median_au, ...
        var base = key
        var quantile = 0.5
        var iqr = false
        if let r = key.range(of: "_p95") { base = key.replacingCharacters(in: r, with: "_median"); quantile = 0.95 }
        else if let r = key.range(of: "_p25") { base = key.replacingCharacters(in: r, with: "_median"); quantile = 0.25 }
        else if let r = key.range(of: "_iqr") { base = key.replacingCharacters(in: r, with: "_median"); iqr = true }
        guard base.contains("_median") else { return nil }

        var found: [DayDistribution] = []
        for s in stages where s.status == "ok" {
            guard case .array(let blocks)? = s.extra["distributions"] else { continue }
            for block in blocks {
                guard case .object(let b) = block,
                      b["key"]?.stringValue == base,
                      case .array(let edgeVals)? = b["edges"],
                      case .array(let countVals)? = b["counts"] else { continue }
                let edges = edgeVals.compactMap { $0.doubleValue }
                let counts = countVals.compactMap { $0.intValue }
                if edges.count == counts.count + 1, !edges.isEmpty {
                    found.append(DayDistribution(key: base, edges: edges, counts: counts))
                }
            }
        }
        guard !found.isEmpty else { return nil }
        let edges = found[0].edges
        guard found.allSatisfy({ $0.edges == edges }) else { return nil }
        var counts = [Int](repeating: 0, count: edges.count - 1)
        for d in found {
            for (i, c) in d.counts.enumerated() { counts[i] += c }
        }
        let n = counts.reduce(0, +)
        guard n > 0 else { return nil }
        if iqr {
            let p75 = Self.quantileFromBins(edges: edges, counts: counts, n: n, q: 0.75)
            let p25 = Self.quantileFromBins(edges: edges, counts: counts, n: n, q: 0.25)
            return p75 - p25
        }
        return Self.quantileFromBins(edges: edges, counts: counts, n: n, q: quantile)
    }

    /// A quantile from binned counts: the rank walks the cumulative counts and
    /// interpolates linearly within the occupied bin (bounded-bin resolution,
    /// coarser than a raw-sample quantile and honestly labeled as pooled).
    static func quantileFromBins(edges: [Double], counts: [Int], n: Int, q: Double) -> Double {
        let rank = min(max(q * Double(n), 0), Double(n))
        var cumulative = 0
        for (i, c) in counts.enumerated() {
            let before = cumulative
            cumulative += c
            if c > 0 && Double(cumulative) >= rank {
                let within = (rank - Double(before)) / Double(c)
                return edges[i] + within * (edges[i + 1] - edges[i])
            }
        }
        return edges.last ?? 0
    }

    var jsonValue: JSONValue {
        var obj: [String: JSONValue] = [
            "status": .string(status),
            "release_tier": .string(releaseTier),
            "provider_revision": .string(providerRevision),
            "measurements": measurements,
        ]
        if let observed = observedSeconds { obj["observed_seconds"] = .double(observed) }
        if let eligible = eligibleSeconds { obj["eligible_seconds"] = .double(eligible) }
        if let contactState = contactState { obj["contact_state"] = .string(contactState) }
        if let reason = reason { obj["reason"] = .string(reason) }
        if !reasonCounts.isEmpty {
            obj["reason_counts"] = .object(reasonCounts.mapValues { JSONValue.int($0) })
        }
        for (k, v) in extra { obj[k] = v }
        return .object(obj)
    }
}

// MARK: - Local helpers

extension Date {
    /// Compact UTC ISO-8601 (no fractional seconds, no timezone offset), the form the day document
    /// and the sidecar interval use.
    func sensorISO() -> String {
        ISO8601DateFormatter().string(from: self)
    }
}

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v) where v.rounded() == v && abs(v) < 9e15: return Int(v)
        default: return nil
        }
    }
}
