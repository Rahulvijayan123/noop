import Foundation
import CZstd
import StrandAnalytics

/// Lane 6: activity context (C6).
///
/// Claims `activity_context_jobs` through the fenced
/// `claim_activity_context_v2` / `renew_activity_context_v2` /
/// `fail_activity_context_v2` / `publish_activity_context_v2` RPCs (C10), then
/// for one job:
///   1. resolves each verified input object's `object_key` from
///      `object_manifests` and downloads the exact bytes from B2;
///   2. verifies the DECODED sha256 against the job's recorded digest
///      (mismatch is a deterministic failure — bounded backoff, dead-letter);
///   3. zstd-decompresses (existing `VerificationLane.zstdDecompress`) and
///      decodes the NPB1 rawImuSession records (`Npb1ImuDecoder`);
///   4. reconstructs the per-second timeline (sample time = ts + i/100) and
///      splits contiguous runs at >1 s gaps / clock resets (never fills);
///   5. renews the lease around each run's inference and sends the run to the
///      persistent Python service (`ActivityPythonService`, C10 serve
///      protocol); model loading/inference NEVER runs inside a Postgres
///      transaction;
///   6. builds the C10 `activity_context` JSON through the SHARED
///      `StrandAnalytics.ActivityContextPolicy` / `ActivityContextJoin`
///      (window predictions + the day's sleep sessions and workout records
///      from `public.sessions`) — the same temporal fold the app runs, so
///      server and phone cannot diverge (docs/ARCHITECTURE.md §4);
///   7. publishes through the fenced `publish_activity_context_v2` in one
///      short transaction; a NULL result is never success and the lease is
///      released through the renew+fail pair (mirrors `ScoringLane.swift:
///      323-337,368-380`);
///   8. after commit, re-dirties the affected scoring day(s) at coalesced
///      cadence via `public.scoring_dirty_span` (worker-schema §3.3, route 2).
///
/// ActivityContext v2 rides along (`ActivityContextDays`): after inference the
/// same windows, their IMU features and the day's stored heart-rate, gravity,
/// step, sleep, workout and wear streams go through the shared probabilistic
/// decoder, and the day document is written by the fenced
/// `publish_activity_context_day` RPC inside the step-7 transaction, before the
/// v1 publish. It is best effort: any failure of it is counted and skipped, so
/// the v1 epochs, the scoring invalidation and job completion are exactly what
/// they were without it. `FRWHOOP_ACTIVITY_CONTEXT_V2=0` switches it off.
///
/// Stream days (`streams-activity-1` jobs) cover every other day: raw IMU is uploaded for only a few
/// sessions, but heart rate, gravity, steps and wear events are stored for every day the strap was
/// worn. `enqueue_activity_stream_days` turns completed scoring work into one job per (owner, device,
/// UTC day); the lane claims those through `claim_activity_stream_day`, decodes the stored streams with
/// no encoder windows (the same decoder, the same inputs as the phone's day timeline) and completes the
/// job through `complete_activity_stream_day`, which stores the day document. That path needs neither
/// B2 nor Python, so it keeps running while the model is down (`FRWHOOP_ACTIVITY_IMU=0` runs it alone on a
/// host with no Python). `FRWHOOP_ACTIVITY_STREAMS=0` stops it.
///
/// The claim commits BEFORE inference (a lease, not a transaction), so the
/// long B2/Python work holds no transaction. `model_unavailable` / a dead
/// Python process fail the lane soft: the drain does not claim while the
/// model is down, jobs are not dead-lettered instantly, the reason is
/// recorded, and every other lane is untouched.
struct ActivityLane {
    let db: PostgresClient
    let storage: B2Storage
    let service: ActivityPythonService
    var leaseSeconds: Int = 300
    var maxFailures: Int = 8
    var publishAttempts: Int = 3
    /// Process raw-IMU jobs (needs the Python service and, for HART, its model). A host without them
    /// turns this off and still stores stream days.
    var imuJobsEnabled: Bool = true
    /// Build and store the ActivityContext v2 day document next to the v1 epochs.
    var contextDaysEnabled: Bool = true
    /// Build and store a day document for every UTC day that has stored measurements (stream days).
    var streamDaysEnabled: Bool = true
    /// Stream-day jobs processed per wake.
    var streamDayBudget: Int = 4
    /// Inertia-1 motion heads (shadow / candidate), or nil when off (`FRWHOOP_INERTIA_ENABLED`). Never part of
    /// the readiness gate; its failures never fail a job (`ActivityMotionHeads.swift`).
    var inertia: InertiaStage? = nil
    /// Extra seconds before/after a run sent to Python for resample filter
    /// state (C10 serve protocol: up to 3).
    static let boundarySeconds = 3
    /// Bounded body per serve request (seconds). The request line is
    /// ~1603 B per base64 second, so the service's 64 MiB request cap admits
    /// ~11.6 h of contiguous seconds in ONE request; a full-day contiguous run
    /// would exceed it and fail `requestTooLarge` -> dead-letter (audit P1-2).
    /// Chunks of 3600 s keep every request far below the cap while the serve
    /// protocol bounds head/tail to 3 s each.
    static let maxRequestBodySeconds = 3600
    /// Model/preprocessing versions serve reports when no HART manifest is
    /// configured (baseline classifier: `default_manifest(model_version:
    /// "baseline-v0")`, `preprocessing_version` = package "1.0.0"). These are
    /// the fallbacks when the child has not reported yet — never a hard-coded
    /// 'hart-activity-1', which matches no manifest and no DB fingerprint
    /// constant (audit P1-3/P3-6).
    static let baselineModelVersion = "baseline-v0"
    static let baselinePreprocessingVersion = "1.0.0"

    struct Stats {
        var claimed = 0
        var completed = 0
        var failed = 0
        /// Claims the queue had already moved past (newer revision, or another
        /// worker won). Nothing published, no failure recorded.
        var superseded = 0
        /// Publish returned NULL (stale lease / moved revision / disabled).
        var notCompleted = 0
        /// Deterministic failures settled through `fail_activity_context_v2`.
        var failuresPersisted = 0
        /// Failures that could not be settled; the lease expiry recovers them.
        var failuresUnsettled = 0
        /// Soft failures while the model was unavailable.
        var modelUnavailable = 0
        var windowsInferred = 0
        /// ActivityContext v2 day documents stored.
        var contextDaysPublished = 0
        /// Day documents not stored because building or writing them failed (the v1 publish was
        /// unaffected). A migration that was not applied shows up here.
        var contextDayFailures = 0
        var lastContextDayError: String?
        /// Stream-day jobs created or refreshed by `enqueue_activity_stream_days`.
        var streamDaysEnqueued = 0
        var streamDaysClaimed = 0
        /// Stream-day documents stored.
        var streamDaysPublished = 0
        /// Stream-day jobs completed because the day held nothing to describe.
        var streamDaysEmpty = 0
        /// Stream-day claims the queue had already moved past (nothing written, no failure recorded).
        var streamDaysSuperseded = 0
        /// Stream-day jobs that failed and were settled with backoff (dead-letter at the queue's cap).
        var streamDayFailures = 0
        var lastStreamDayError: String?
        /// Inertia (only moves when the stage is configured). Failures are counted per chunk or per job start
        /// and never reach the HART path.
        var inertiaJobs = 0
        var inertiaChunks = 0
        var inertiaWindows = 0
        var inertiaFailures = 0
        /// Jobs where the Inertia model was not available (ping said so, or the child would not start).
        var inertiaUnavailable = 0
        var lastInertiaError: String?
        var lastInertiaErrorKind: String?
        var inertiaShadowStored = 0
        var inertiaShadowFailures = 0
        var lastInertiaShadowError: String?
        var inertiaCandidateDocuments = 0
        var inertiaCandidateWithheld = 0
        var lastInertiaWithheldReason: String?
        var lastError: String?
        var lastErrorKind: String?
        var lastActivityAt: Date?
    }
    var stats = Stats()
    var consecutiveFailures = 0
    /// Throttle for the drain loop's reconcile call (once a minute is plenty:
    /// the RPC is idempotent and the trigger covers the common path).
    var lastReconcileAt: Date?
    static let reconcileIntervalSeconds: TimeInterval = 60
    /// The reconcile call and its lookback. The parameter is bound as text and cast by Postgres, so it
    /// must be a bare interval literal: a quoted `'7 days'::interval` is not one and made every call fail.
    static let reconcileSQL = "SELECT public.reconcile_activity_context($1::interval)::text"
    static let reconcileLookback = "7 days"
    /// Stream days are re-derived from scoring completions; checking every couple of minutes keeps a live
    /// day fresh without scanning the scoring table on every idle wake.
    var lastStreamEnqueueAt: Date?
    static let streamEnqueueIntervalSeconds: TimeInterval = 120
    static let streamLookback = "36 hours"
    static let streamBackfillPerCall = 25
    static let streamMinRebuildInterval = "10 minutes"
    static let streamEnqueueSQL = "SELECT public.enqueue_activity_stream_days($1::interval,$2::integer,$3::interval)::text"
    /// A stream-day source that errors at claim time (the migration is not applied yet, say) is left
    /// alone for this long, without affecting the raw-IMU path.
    var streamBackoffUntil: Date?
    static let streamBackoffSeconds: TimeInterval = 60

    enum ActivityError: Error, CustomStringConvertible {
        /// A deterministic input violation: bounded retry through the fail
        /// RPC (dead-letter at the queue's cap) is the honest settlement.
        case deterministic(String)
        /// Transient (missing object, model down): settle with backoff.
        case retryable(String)

        var description: String {
            switch self {
            case .deterministic(let detail): return "activity_deterministic: \(detail)"
            case .retryable(let detail): return "activity_retryable: \(detail)"
            }
        }
    }

    private enum Cycle {
        case empty
        case completed
        case superseded
        case failed
    }

    struct ActivityJob {
        var userId: String
        var deviceId: String
        var day: String
        var algorithmVersion: String
        var objectIds: [String]
        var digests: [String]
        var fingerprint: String
        var inputRevision: Int64
        var leaseToken: String
    }

    /// A contiguous run of seconds [start, end) with no gaps and no clock
    /// resets. Equatable so the split logic is directly unit-testable.
    struct Run: Equatable {
        var start: Int64
        var end: Int64
    }

    /// Sorted unique second timestamps with their 600 i16 axis-major columns
    /// laid out contiguously (full-day jobs hold ~103 MB of i16, so the
    /// timeline stays flat rather than one array per second).
    struct ImuTimeline {
        var seconds: [Int64] = []
        var columns: [Int16] = []
        var count: Int { seconds.count }
        func columnOffset(index: Int) -> Int { index * Npb1ImuDecoder.columnsPerRecord }
    }

    // MARK: - Drain

    /// One wake: the raw-IMU jobs first (they need the model), then the stream days (they do not, so a
    /// missing model or Python never holds them back).
    mutating func drain(budget: Int) {
        if imuJobsEnabled { drainImuJobs(budget: budget) }
        if streamDaysEnabled { drainStreamDays(budget: streamDayBudget) }
    }

    private mutating func drainImuJobs(budget: Int) {
        for _ in 0..<max(1, budget) {
            do {
                try db.ensureConnected()
            } catch {
                record(error)
                return
            }
            // Model must be loaded before any claim: when the Python child is
            // down or reports model_missing the lane fails SOFT (no claiming,
            // heartbeat records the reason, jobs are not dead-lettered).
            do {
                try ensureServiceReady()
            } catch {
                stats.modelUnavailable += 1
                stats.lastError = "model_unavailable: \(error)"
                stats.lastErrorKind = "model_unavailable"
                return
            }
            // Reconcile missed enqueue events (idempotent, bounded to the
            // last 7 days by the RPC): a trigger race or a pre-trigger
            // verification can leave a verified rawImuSession object without
            // its activity job. Throttled to once per reconcileInterval —
            // the scan is not free, and the drain loop spins about once a
            // second when idle. Best effort: a transient failure must not
            // block claiming.
            if let last = lastReconcileAt,
               Date().timeIntervalSince(last) < Self.reconcileIntervalSeconds {
            } else {
                lastReconcileAt = Date()
                _ = try? db.callFunctionForJSON(Self.reconcileSQL, [Self.reconcileLookback])
            }
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
                }
            } catch let e as PostgresClient.Error where e.kind == .connectionLost {
                record(e)
                return
            } catch {
                stats.failed += 1
                record(error)
                consecutiveFailures += 1
                if consecutiveFailures >= maxFailures { return }
            }
        }
    }

    private mutating func record(_ error: Error) {
        stats.lastError = String(describing: error).prefix(2000).description
        stats.lastErrorKind = (error as? PostgresClient.Error)?.kind.rawValue
            ?? ((error as? ActivityError) == nil ? "other" : nil)
        if stats.lastErrorKind == nil {
            stats.lastErrorKind = "other"
        }
    }

    /// The Python child must be running with the model loaded. Pings on first
    /// use and after a restart; a dead or model-less child throws.
    private mutating func ensureServiceReady() throws {
        try service.ensureStarted()
        if !service.modelAvailable {
            let ping = try service.ping()
            guard ping.modelAvailable else {
                throw ActivityError.retryable("model_unavailable: \(ping.modelStatus)")
            }
        }
    }

    // MARK: - Stream days

    /// The stream-day half of a wake (internal so a scratch database can drive it without Python or B2).
    mutating func drainStreamDays(budget: Int) {
        if let until = streamBackoffUntil, Date() < until { return }
        do {
            try db.ensureConnected()
        } catch {
            record(error)
            return
        }
        enqueueStreamDaysIfDue()
        for _ in 0..<max(1, budget) {
            do {
                switch try streamCycle() {
                case .empty:
                    return
                case .completed:
                    stats.lastActivityAt = Date()
                case .superseded, .failed:
                    break
                }
            } catch let e as PostgresClient.Error where e.kind == .connectionLost {
                record(e)
                return
            } catch {
                // The claim itself failed (the stream-day migration is not applied, a grant is missing):
                // say so once and leave the stream source alone for a while. The raw-IMU path is separate.
                let why = ActivityContextDays.safeReason(error)
                noteStreamDayFailure(why)
                stats.lastError = "stream_days_claim: \(why)"
                stats.lastErrorKind = "stream_days"
                streamBackoffUntil = Date().addingTimeInterval(Self.streamBackoffSeconds)
                return
            }
        }
    }

    /// Create or refresh stream-day jobs from the scoring work completed since the last look. Best effort
    /// and idempotent: a failed call is noted and retried on the next interval.
    mutating func enqueueStreamDaysIfDue() {
        if let last = lastStreamEnqueueAt,
           Date().timeIntervalSince(last) < Self.streamEnqueueIntervalSeconds { return }
        lastStreamEnqueueAt = Date()
        do {
            let out = try db.callFunctionForJSON(
                Self.streamEnqueueSQL,
                [Self.streamLookback, String(Self.streamBackfillPerCall), Self.streamMinRebuildInterval])
            stats.streamDaysEnqueued += Int(out ?? "") ?? 0
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            record(e)
        } catch {
            noteStreamDayFailure(ActivityContextDays.safeReason(error))
        }
    }

    /// Claim and process one stream-day job. Job-level failures are settled here (bounded backoff,
    /// dead-letter at the queue's cap); only a failed claim or a lost connection propagates.
    private mutating func streamCycle() throws -> Cycle {
        let rows = try db.query("select * from public.claim_activity_stream_day($1::integer)",
                                [String(leaseSeconds)])
        guard let r = rows.first else { return .empty }
        stats.streamDaysClaimed += 1
        guard let job = Self.parseStreamJob(r) else {
            if let token = r["lease_token"], !token.isEmpty, let rev = Int64(r["input_revision"] ?? "") {
                stats.streamDayFailures += 1
                try settleFailure(token: token, revision: rev,
                                  error: ActivityError.deterministic("malformed_job_row"))
            }
            return .failed
        }
        do {
            switch try processStreamDay(job: job, started: Date()) {
            case .stored:
                stats.streamDaysPublished += 1
                return .completed
            case .empty:
                stats.streamDaysEmpty += 1
                return .completed
            case .fenced:
                stats.streamDaysSuperseded += 1
                stats.notCompleted += 1
                try? releaseLease(job: job)
                return .superseded
            }
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            stats.failuresUnsettled += 1
            throw e  // lease expiry hands the job back to the queue
        } catch {
            let kind = (error as? PostgresClient.Error)?.kind ?? .other
            if kind == .serialization || kind == .stale {
                stats.streamDaysSuperseded += 1
                return .superseded
            }
            stats.streamDayFailures += 1
            noteStreamDayFailure(ActivityContextDays.safeReason(error))
            do {
                try settleFailure(job: job, error: error)
            } catch {
                stats.failuresUnsettled += 1
            }
            return .failed
        }
    }

    /// Decode one UTC day from the stored measurements and complete the job. Reads and decodes outside any
    /// transaction; the only write is the one fenced completion at the end.
    private mutating func processStreamDay(job: ActivityJob,
                                           started: Date) throws -> ActivityContextDays.StreamDayOutcome {
        guard let dayBounds = Self.utcDayBounds(job.day) else {
            throw ActivityError.deterministic("invalid_job_day \(job.day)")
        }
        guard try renewLease(job: job) else {
            throw PostgresClient.Error(message: "activity lease lost before the stream day decode",
                                       sqlstate: "55000", kind: .stale)
        }
        let nights = try loadPublishedNights(user: job.userId, device: job.deviceId,
                                             dayStart: dayBounds.start, dayEnd: dayBounds.end)
        let exercise = try loadIntervals(kindClause: "kind in ('workout','manual_workout')",
                                         user: job.userId, device: job.deviceId,
                                         dayStart: dayBounds.start, dayEnd: dayBounds.end)
        let streams = try ActivityContextDays.loadStreams(
            db: db, userId: job.userId, deviceId: job.deviceId,
            dayStart: dayBounds.start, dayEnd: dayBounds.end)
        let built = try ActivityContextDays.buildStreamDay(
            day: job.day, dayBounds: dayBounds, streams: streams,
            sleep: ActivityContextDays.asleepSpans(nights), inBed: nights.map { (start: $0.start, end: $0.end) },
            exercise: exercise, now: Int(Date().timeIntervalSince1970))
        guard try renewLease(job: job) else {
            throw PostgresClient.Error(message: "activity lease lost before the stream day completion",
                                       sqlstate: "55000", kind: .stale)
        }
        return try ActivityContextDays.completeStreamDay(
            db: db, token: job.leaseToken, revision: job.inputRevision, payload: built?.payloadText,
            durationMS: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// A claimed stream-day row. Unlike a raw-IMU job it has no input objects: its inputs are the stored
    /// measurement streams, identified by the day alone.
    static func parseStreamJob(_ r: [String: String]) -> ActivityJob? {
        let uid = r["user_id"] ?? ""
        let dev = r["device_id"] ?? ""
        let day = r["day"] ?? ""
        let tok = r["lease_token"] ?? ""
        guard !uid.isEmpty, !dev.isEmpty, !day.isEmpty, !tok.isEmpty,
              let revision = Int64(r["input_revision"] ?? ""), revision > 0,
              (r["algorithm_version"] ?? "") == ActivityContextDays.streamsAlgorithmVersion else { return nil }
        return ActivityJob(userId: uid, deviceId: dev, day: day,
                           algorithmVersion: ActivityContextDays.streamsAlgorithmVersion,
                           objectIds: [], digests: [], fingerprint: r["fingerprint"] ?? "",
                           inputRevision: revision, leaseToken: tok)
    }

    /// Count a stream-day problem and say why on stderr, once per distinct reason.
    private mutating func noteStreamDayFailure(_ why: String) {
        if stats.lastStreamDayError != why {
            FileHandle.standardError.write(
                ("frwhoop-worker: activity stream day: \(why)\n").data(using: .utf8)!)
        }
        stats.lastStreamDayError = why
    }

    // MARK: - One job

    private mutating func cycle() throws -> Cycle {
        // The claim runs as its own implicit transaction (FOR UPDATE SKIP
        // LOCKED + lease grant) and COMMITS before inference: the long
        // B2/Python work must never hold a transaction.
        let rows = try db.query(
            "select * from public.claim_activity_context_v2($1::integer)",
            [String(leaseSeconds)])
        guard let r = rows.first else { return .empty }
        guard let job = Self.parseJob(r) else {
            // A claim we cannot interpret (corrupt row). Settle it
            // deterministically so it cannot be re-claimed forever:
            // bounded backoff -> dead-letter at the queue cap.
            if let token = r["lease_token"], !token.isEmpty,
               let rev = Int64(r["input_revision"] ?? "") {
                stats.failed += 1
                try settleFailure(token: token, revision: rev,
                                  error: ActivityError.deterministic("malformed_job_row"))
            }
            return .failed
        }
        let started = Date()
        do {
            let published = try process(job: job, started: started)
            return published ? .completed : .superseded
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            stats.failuresUnsettled += 1
            throw e  // lease expiry hands the job back to the queue
        } catch {
            let kind = (error as? PostgresClient.Error)?.kind ?? .other
            if kind == .serialization || kind == .stale {
                // A concurrent writer won the race; the queue owns the newer
                // revision. Never record a failure against this job.
                return .superseded
            }
            do {
                try settleFailure(job: job, error: error)
            } catch {
                stats.failuresUnsettled += 1
            }
            return .failed
        }
    }

    /// Full job processing. Returns true when the fenced publish committed.
    private mutating func process(job: ActivityJob, started: Date) throws -> Bool {
        guard let dayBounds = Self.utcDayBounds(job.day) else {
            throw ActivityError.deterministic("invalid_job_day \(job.day)")
        }

        // 1. Resolve each verified input object's storage key.
        var objects: [(id: String, digest: String, key: String)] = []
        guard job.objectIds.count == job.digests.count else {
            throw ActivityError.deterministic("job_digest_count_mismatch")
        }
        for (id, digest) in zip(job.objectIds, job.digests) {
            let rows = try db.query("""
                select object_key, status, durability_receipt->>'state' as receipt_state
                from public.object_manifests
                where id = $1::uuid and user_id = $2::uuid and device_id = $3::uuid
                """, [id, job.userId, job.deviceId])
            guard let r = rows.first,
                  let key = r["object_key"], !key.isEmpty,
                  r["status"] == "ready",
                  r["receipt_state"] == "verified_indexed" else {
                throw ActivityError.retryable("input_not_ready: object \(id)")
            }
            objects.append((id, digest, key))
        }
        guard !objects.isEmpty else {
            throw ActivityError.deterministic("job_has_no_input_objects")
        }

        // 2. Download, verify the decoded digest, decompress, decode NPB1.
        // The lease is renewed BEFORE each object's download: a long B2
        // download/decode phase can outlive the 300 s lease, and an expired
        // lease makes the later publish return NULL — a wasted full-day
        // recompute (audit P3-4).
        let records = try Self.loadObjects(
            objects: objects,
            renew: { try self.renewLease(job: job) },
            download: { key in try storage.download(objectKey: key) })

        // 3. Timeline + contiguous runs (never fill gaps).
        let timeline = try Self.buildTimeline(records: records)
        guard !timeline.seconds.isEmpty else {
            throw ActivityError.deterministic("no_imu_seconds")
        }
        let runs = Self.splitRuns(seconds: timeline.seconds)

        // 4. The published nights + workout records for the day's epochs.
        let nights = try loadPublishedNights(user: job.userId, device: job.deviceId,
                                             dayStart: dayBounds.start, dayEnd: dayBounds.end)
        let asleep = ActivityContextDays.asleepSpans(nights)
        let inBed = nights.map { (start: $0.start, end: $0.end) }
        let exercise = try loadIntervals(kindClause: "kind in ('workout','manual_workout')",
                                         user: job.userId, device: job.deviceId,
                                         dayStart: dayBounds.start, dayEnd: dayBounds.end)

        // 4b. Wear evidence (G3/G7): WRIST_ON/OFF rows from noop_events feed the shared fold so
        // epochs carry an EVIDENCED wear_state (unknown where no event covers) instead of the
        // policy's all-unknown default. Deterministic; quiet IMU is never on-wrist evidence.
        let wearEvents = try loadWearEvents(user: job.userId, device: job.deviceId,
                                            dayStart: dayBounds.start, dayEnd: dayBounds.end)
        let wearIntervals = Self.wearIntervals(fromEvents: wearEvents,
                                               from: dayBounds.start, to: dayBounds.end)

        // 5. Inference per run, outside any transaction, lease renewed around
        //    the long work. Windows are collected per run and folded ONCE
        //    through the shared policy in step 6 (see
        //    `ActivityLane.activityDocument` for why the fold is one call).
        // Lazily, one run's chunks at a time: a full day's base64 columns are never all in memory at once.
        let requests = runs.lazy.flatMap { Self.runRequests(timeline: timeline, run: $0) }
        let db = self.db, token = job.leaseToken, lease = leaseSeconds
        let inferred = try Self.inferChunks(
            requests, service: service, inertia: inertia,
            versions: Self.resolvedVersions(reportedModel: service.reportedModelVersion,
                                            reportedPreprocessing: service.reportedPreprocessingVersion),
            stats: &stats,
            renew: {
                isTrue(try db.callFunctionForJSON(
                    "SELECT public.renew_activity_context_v2($1::uuid, $2::integer)::text",
                    [token, String(lease)]))
            })
        let windows = inferred.windows
        let versions = inferred.versions

        // 6. Build the C10 document from the SHARED StrandAnalytics policy
        //    and join (`ActivityContextPolicy` + `ActivityContextJoin`) — the
        //    exact temporal fold the app runs, so server and phone compute
        //    identical epochs/summary/contexts.
        let dataThrough = timeline.seconds.max().map { Int($0) + 1 } ?? dayBounds.start
        var doc = try Self.activityDocument(
            windows: windows,
            sleepIntervals: asleep,
            exerciseIntervals: exercise,
            dayStart: dayBounds.start, dayEnd: dayBounds.end,
            inputRevision: job.inputRevision,
            modelVersion: versions.model,
            preprocessingVersion: versions.preprocessing,
            dataThrough: dataThrough,
            wearIntervals: wearIntervals)
        // The publish RPC validates `p_payload ->> 'day'` against the job's
        // day (20261003120000_activity_context.sql), so the C10 document is
        // stamped with the job day before it is sealed.
        let payloadText = try Self.dayStampedJSONText(doc: &doc, day: job.day)

        // 6b. ActivityContext v2: the same windows plus their IMU features and the day's stored
        //     streams through the shared probabilistic decoder. Best effort — see the type comment.
        let context = try buildContextDayAndInput(
            job: job, dayBounds: dayBounds, windows: windows, versions: versions,
            asleep: asleep, inBed: inBed, exercise: exercise)

        // 6c. Inertia shadow row (and candidate comparison): built from what 6b decoded, never changing it.
        let motionHeads = motionHeadsPayload(job: job, collector: inferred.motionHeads, context: context)
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)

        // 7–8. Fenced publish, then the scoring re-dirty.
        return try publishDay(job: job, payloadText: payloadText, dayDocument: context.built,
                              durationMS: durationMS, dayBounds: dayBounds, motionHeads: motionHeads)
    }

    /// What step 5 produced: the HART windows and versions exactly as before, plus the Inertia collector.
    struct ChunkInference {
        var windows: [ActivityPythonService.WindowPrediction] = []
        var versions: (model: String, preprocessing: String)
        var motionHeads = MotionHeadsCollector()
    }

    /// Step 5 for a job's chunks. One request per bounded body chunk (audit P1-2): a contiguous run longer
    /// than maxRequestBodySeconds is split at second boundaries and each chunk carries its own head/tail
    /// filter state. serve.py emits windows only inside the chunk's [start_ts, end_ts), so no window is
    /// duplicated in the single day fold; the only loss is the protocol's single 4-s straddle per interior
    /// boundary.
    ///
    /// For each chunk: renew the lease, HART infer (a failure ends the job exactly as before), then — only when
    /// an Inertia stage is configured and was ready at the start of the job — the Inertia infer for the same
    /// chunk, whose every failure is absorbed and counted. The HART windows, versions and DB calls are the same
    /// with or without Inertia.
    static func inferChunks<Requests: Sequence>(
        _ requests: Requests, service: ActivityPythonService,
        inertia: InertiaStage?, versions start: (model: String, preprocessing: String),
        stats: inout Stats, renew: () throws -> Bool) throws -> ChunkInference
        where Requests.Element == ActivityPythonService.RunRequest {
        var out = ChunkInference(versions: start)
        var inertiaReady = false
        if let inertia {
            stats.inertiaJobs += 1
            if let down = inertia.begin() {
                stats.inertiaUnavailable += 1
                out.motionHeads.stopped = down.kind
                noteInertiaFailure(&stats, kind: down.kind, message: down.message)
            } else {
                inertiaReady = true
            }
        }
        for request in requests {
            let renewed = try renew()
            guard renewed else {
                throw PostgresClient.Error(message: "activity lease lost during inference",
                                           sqlstate: "55000", kind: .stale)
            }
            let result = try service.infer(run: request)
            guard result.ok else {
                let kind = result.errorKind ?? "inference"
                if kind == "model_missing" {
                    stats.modelUnavailable += 1
                    throw ActivityError.retryable("model_unavailable: \(result.error ?? "")")
                }
                throw ActivityError.retryable("inference_\(kind): \(result.error ?? "")")
            }
            if let mv = result.modelVersion, !mv.isEmpty { out.versions.model = mv }
            if let pv = result.preprocessingVersion, !pv.isEmpty { out.versions.preprocessing = pv }
            out.windows.append(contentsOf: ActivityContextDays.windowsWithCompatibleFeatures(result))
            stats.windowsInferred += result.windows.count

            // Inertia for the same chunk. Isolated: nothing below can throw.
            guard inertiaReady, let inertia, out.motionHeads.stopped == nil else { continue }
            out.motionHeads.chunks += 1
            stats.inertiaChunks += 1
            switch inertia.infer(request) {
            case .ok(let response):
                if let first = out.motionHeads.responses.first, first.bundle != response.bundle {
                    out.motionHeads.failedChunks += 1
                    out.motionHeads.failureKinds["bundle_changed", default: 0] += 1
                    out.motionHeads.stopped = "bundle_changed"
                    stats.inertiaFailures += 1
                    noteInertiaFailure(&stats, kind: "bundle_changed", message: "the bundle changed during a job")
                    continue
                }
                out.motionHeads.responses.append(response)
                stats.inertiaWindows += response.windows.count
            case .failed(let kind, let message, let stop):
                out.motionHeads.failedChunks += 1
                out.motionHeads.failureKinds[kind, default: 0] += 1
                if stop { out.motionHeads.stopped = kind }
                stats.inertiaFailures += 1
                noteInertiaFailure(&stats, kind: kind, message: message)
            }
        }
        return out
    }

    /// Record an Inertia failure and say why on stderr, once per distinct kind in a row.
    static func noteInertiaFailure(_ stats: inout Stats, kind: String, message: String) {
        if stats.lastInertiaErrorKind != kind {
            FileHandle.standardError.write(
                ("frwhoop-worker: inertia \(kind) (HART path unaffected): \(message)\n").data(using: .utf8)!)
        }
        stats.lastInertiaErrorKind = kind
        stats.lastInertiaError = String("\(kind): \(message)".prefix(240))
    }

    /// The Inertia shadow payload for this job (and, in candidate mode, the comparison decode), or nil when
    /// Inertia is off or produced nothing valid. Never throws: a failure here is counted and skipped.
    mutating func motionHeadsPayload(job: ActivityJob, collector: MotionHeadsCollector,
                                     context: ContextDayBuild) -> String? {
        guard let inertia, let heads = collector.trackInput else { return nil }
        let candidate = ActivityMotionHeadsDays.candidate(mode: inertia.mode, heads: heads, input: context.input,
                                                         generatedAt: context.generatedAt)
        switch candidate {
        case .notRequested: break
        case .withheld(let why):
            stats.inertiaCandidateWithheld += 1
            stats.lastInertiaWithheldReason = why
        case .document:
            stats.inertiaCandidateDocuments += 1
        }
        do {
            return try ActivityMotionHeadsDays.payload(day: job.day, mode: inertia.mode, collector: collector,
                                                      candidate: candidate)
        } catch {
            stats.inertiaShadowFailures += 1
            stats.lastInertiaShadowError = ActivityContextDays.safeReason(error)
            return nil
        }
    }

    /// Steps 7–8 as a unit (internal so a scratch database can exercise it without B2 or Python).
    ///
    /// 7. Fenced publish in one short transaction. NULL is never success. The ActivityContext v2 day
    ///    document, when there is one, is written first under a savepoint: it shares the v1 publish's
    ///    fence and commits or rolls back with it, but a rejection of it never reaches the v1 publish.
    /// 8. After commit, the coalesced re-dirty of the affected scoring day(s) (worker-schema §3.3
    ///    route 2). Best effort: the next cycle handles a transient failure.
    ///
    /// Returns true when the v1 publish committed.
    ///
    /// `motionHeads` (the Inertia shadow row) is written after the v2 document and before the v1 publish, under
    /// its own savepoint and its own fenced RPC: it needs the live lease (the v1 publish releases it), it
    /// commits only with the v1 epochs, and a rejection of it never reaches either publish.
    mutating func publishDay(job: ActivityJob, payloadText: String,
                             dayDocument: ActivityContextDays.Built?, durationMS: Int,
                             dayBounds: (start: Int, end: Int), motionHeads: String? = nil) throws -> Bool {
        try db.beginTransaction(.readCommitted)
        do {
            var dayStored = false
            if let dayDocument {
                switch try ActivityContextDays.publish(
                    db: db, token: job.leaseToken, revision: job.inputRevision,
                    payload: dayDocument.payloadText) {
                case .stored:
                    dayStored = true
                case .fenced:
                    break
                case .rejected(let why):
                    noteContextDayFailure(why)
                }
            }
            var motionHeadsStored = false
            if let motionHeads {
                switch try ActivityMotionHeadsDays.publish(
                    db: db, token: job.leaseToken, revision: job.inputRevision, payload: motionHeads) {
                case .stored:
                    motionHeadsStored = true
                case .fenced:
                    break
                case .rejected(let why):
                    stats.inertiaShadowFailures += 1
                    if stats.lastInertiaShadowError != why {
                        FileHandle.standardError.write(
                            ("frwhoop-worker: inertia shadow row skipped (publishes unaffected): \(why)\n")
                                .data(using: .utf8)!)
                    }
                    stats.lastInertiaShadowError = why
                }
            }
            let publishJSON = try db.callFunctionForJSONRaw(
                "SELECT public.publish_activity_context_v2($1::uuid,$2::bigint,$3::jsonb,$4::bigint)::text",
                [job.leaseToken, String(job.inputRevision), payloadText, String(durationMS)])
            let revision = Int64(publishJSON ?? "")
            if let revision, revision > 0 {
                try db.commitTransaction()
                if dayStored { stats.contextDaysPublished += 1 }
                if motionHeadsStored { stats.inertiaShadowStored += 1 }
                _ = try? db.callFunctionForJSON(
                    "SELECT public.scoring_dirty_span($1::uuid,$2::uuid,$3::bigint,$4::bigint)::text",
                    [job.userId, job.deviceId, String(dayBounds.start), String(dayBounds.end)])
                return true
            }
            db.rollbackTransaction()
            stats.notCompleted += 1
            try releaseLease(job: job)
            return false
        } catch {
            db.rollbackTransaction()
            throw error
        }
    }

    /// The ActivityContext v2 day document for this job, or nil when v2 is switched off or building it
    /// failed. Reads the day's streams and decodes outside any transaction. Only a lost lease or a lost
    /// connection is allowed to end the job; every other failure is counted and the v1 publish proceeds.
    mutating func buildContextDay(
        job: ActivityJob, dayBounds: (start: Int, end: Int),
        windows: [ActivityPythonService.WindowPrediction],
        versions: (model: String, preprocessing: String),
        asleep: [(start: Int, end: Int)],
        inBed: [(start: Int, end: Int)] = [],
        exercise: [(start: Int, end: Int)]) throws -> ActivityContextDays.Built? {
        try buildContextDayAndInput(job: job, dayBounds: dayBounds, windows: windows, versions: versions,
                                    asleep: asleep, inBed: inBed, exercise: exercise).built
    }

    /// The v2 day document and the decoder input it was built from (the Inertia candidate decodes the same
    /// input a second time).
    struct ContextDayBuild {
        var built: ActivityContextDays.Built?
        var input: ActivityContextTrackInput?
        var generatedAt: Int
    }

    mutating func buildContextDayAndInput(
        job: ActivityJob, dayBounds: (start: Int, end: Int),
        windows: [ActivityPythonService.WindowPrediction],
        versions: (model: String, preprocessing: String),
        asleep: [(start: Int, end: Int)],
        inBed: [(start: Int, end: Int)] = [],
        exercise: [(start: Int, end: Int)]) throws -> ContextDayBuild {
        let started = Int(Date().timeIntervalSince1970)
        guard contextDaysEnabled else { return ContextDayBuild(built: nil, input: nil, generatedAt: started) }
        var builtInput: ActivityContextTrackInput?
        var generatedAt = started
        do {
            guard try renewLease(job: job) else {
                throw PostgresClient.Error(message: "activity lease lost before the context decode",
                                           sqlstate: "55000", kind: .stale)
            }
            let streams = try ActivityContextDays.loadStreams(
                db: db, userId: job.userId, deviceId: job.deviceId,
                dayStart: dayBounds.start, dayEnd: dayBounds.end)
            let now = Int(Date().timeIntervalSince1970)
            let input = ActivityContextDays.trackInput(
                windows: windows, streams: streams, sleep: asleep, inBed: inBed, exercise: exercise,
                dayStart: dayBounds.start, dayEnd: dayBounds.end, horizon: now,
                encoderVersion: versions.model)
            builtInput = input
            generatedAt = now
            let built = try ActivityContextDays.build(
                input: input, day: job.day, modelVersion: versions.model,
                preprocessingVersion: versions.preprocessing, generatedAt: now)
            return ContextDayBuild(built: built, input: input, generatedAt: now)
        } catch let e as PostgresClient.Error where e.kind == .connectionLost || e.kind == .stale {
            throw e
        } catch {
            noteContextDayFailure(ActivityContextDays.safeReason(error))
            return ContextDayBuild(built: nil, input: builtInput, generatedAt: generatedAt)
        }
    }

    /// Count a skipped v2 day and say why on stderr, once per distinct reason: a migration that was not
    /// applied would otherwise repeat the same line for every job.
    private mutating func noteContextDayFailure(_ why: String) {
        stats.contextDayFailures += 1
        if stats.lastContextDayError != why {
            FileHandle.standardError.write(
                ("frwhoop-worker: activity context v2 day skipped (v1 publish unaffected): \(why)\n")
                    .data(using: .utf8)!)
        }
        stats.lastContextDayError = why
    }

    /// Persist the failure through the fenced contract in its own committed
    /// transaction. `connectionLost` is handled by the caller (lease expiry).
    private mutating func settleFailure(job: ActivityJob, error: Error) throws {
        try settleFailure(token: job.leaseToken, revision: job.inputRevision, error: error)
    }

    private mutating func settleFailure(token: String, revision: Int64, error: Error) throws {
        let message = String((error as? PostgresClient.Error)?.kind.rawValue
            ?? "activity".description)
        let detail = String(describing: error).prefix(2000)
        // `fail_activity_context_v2` returns void: it either ran (bounded
        // backoff / dead-letter or clean release) or threw (unreachable DB,
        // lease already moved). No throw == the failure is durably accounted
        // for; the RPC itself truncates last_error to 2000 chars.
        do {
            _ = try db.callFunctionForJSON(
                "SELECT public.fail_activity_context_v2($1::uuid,$2::bigint,$3::text)::text",
                [token, String(revision), "activity_\(message): \(detail)"])
            stats.failuresPersisted += 1
        } catch {
            stats.failuresUnsettled += 1
        }
    }

    /// Release a lease whose publication did not complete (there is no bare
    /// release RPC): renew to confirm the lease is still ours, then fail with
    /// the CLAIMED revision. The fenced fail RPC
    /// (`fail_activity_context_v2`, 20261003120000_activity_context.sql)
    /// treats a revision MISMATCH (the queue moved past us — a newer object
    /// arrived mid-inference) as a CLEAN release: counters reset, no backoff,
    /// no dead-letter. An UNCHANGED revision counts one honest backoff.
    /// Passing the row's CURRENT revision instead recorded a failure + backoff
    /// against a revision that was never processed (audit P2-2, reproduced
    /// live: after one supersede, consecutive_failures=1 and not_before pushed
    /// forward despite the "clean release" comment).
    private mutating func releaseLease(job: ActivityJob) throws {
        let renewed = isTrue(try db.callFunctionForJSON(
            "SELECT public.renew_activity_context_v2($1::uuid, $2::integer)::text",
            [job.leaseToken, String(leaseSeconds)]))
        guard renewed else { return }
        let failure = Self.releaseFailure(claimedRevision: job.inputRevision)
        _ = try db.callFunctionForJSON(
            "SELECT public.fail_activity_context_v2($1::uuid, $2::bigint, $3::text)::text",
            [job.leaseToken, String(failure.revision), failure.error])
    }

    /// The `fail_activity_context_v2` call for a lease released without a
    /// completed publish. `p_revision` is ALWAYS the claimed revision: when
    /// the queue has moved past us the RPC sees a mismatch and releases the
    /// lease cleanly (no failure accounting, no backoff — audit P2-2); when
    /// nothing changed it counts one honest backoff. The current row revision
    /// is never passed, so a never-processed revision is never failed.
    static func releaseFailure(claimedRevision: Int64) -> (revision: Int64, error: String) {
        (claimedRevision,
         "activity_publish_not_completed:claimed_revision=\(claimedRevision)")
    }

    // MARK: - Lease renew (injected so the per-object placement is testable)

    /// Renew the claimed job's lease; false when the lease is no longer ours
    /// (expired or moved). Called around long work: before every B2 object
    /// download (audit P3-4) and before every run's inference.
    private func renewLease(job: ActivityJob) throws -> Bool {
        isTrue(try db.callFunctionForJSON(
            "SELECT public.renew_activity_context_v2($1::uuid, $2::integer)::text",
            [job.leaseToken, String(leaseSeconds)]))
    }

    // MARK: - Input loading

    /// Download, digest-verify and NPB1-decode every verified input object.
    /// The lease is renewed BEFORE each object's download — a long B2
    /// download/decode phase must not outlive the lease (audit P3-4) — and a
    /// lost lease aborts deterministically as `.stale` (the queue owns the
    /// job again; nothing is failed). `renew`/`download` are injected so the
    /// per-object renewal placement is unit-testable without a database or
    /// B2.
    static func loadObjects(objects: [(id: String, digest: String, key: String)],
                            renew: () throws -> Bool,
                            download: (String) throws -> Data) throws -> [Npb1ImuDecoder.Record] {
        var records: [Npb1ImuDecoder.Record] = []
        for object in objects {
            let renewed = try renew()
            guard renewed else {
                throw PostgresClient.Error(message: "activity lease lost during download",
                                           sqlstate: "55000", kind: .stale)
            }
            let wire: Data
            do {
                wire = try download(object.key)
            } catch {
                if VerificationLane.isMissingObject(error) {
                    throw ActivityError.retryable("object_missing: \(object.id)")
                }
                throw ActivityError.retryable("object_download_failed: \(object.id): \(error)")
            }
            let decoded = try VerificationLane.zstdDecompress(wire)
            let actual = sha256Hex(decoded)
            guard actual == object.digest else {
                throw ActivityError.deterministic(
                    "digest_mismatch: object \(object.id) expected \(object.digest) got \(actual)")
            }
            records.append(contentsOf: try Npb1ImuDecoder.decode(decoded))
        }
        return records
    }

    /// The nights that can overlap `[dayStart, dayEnd)`, as the scoring lane last published them: every
    /// sleep session in the newest snapshot of each local day from the day before the UTC day to the day
    /// after (a night is filed under its local wake day). Naps included, as the app's own lane does. The
    /// newest revision per day is picked from the read index first, so only those payloads are read: a busy
    /// day holds hundreds of revisions.
    ///
    /// `public.sessions` was the source once; the current scoring lane publishes nights only inside
    /// `scoring_snapshots_v2`, so that table stopped receiving sleep and every stream day decoded as if
    /// the wearer never slept. Stream-day jobs are queued off scoring completions for the neighbouring
    /// days, so a newly published night re-dirties the day that reads it.
    private func loadPublishedNights(user: String, device: String,
                                     dayStart: Int, dayEnd: Int) throws -> [ActivityContextDays.Night] {
        let rows = try db.query("""
            with newest as (
              select max(result_revision) as rr
                from public.scoring_snapshots_v2
               where user_id=$1::uuid and device_id=$2::uuid
                 and day between ($3::timestamptz at time zone 'UTC')::date - 1
                             and ($4::timestamptz at time zone 'UTC')::date + 1
               group by day)
            select distinct on (night->>'start_at', night->>'end_at')
                   extract(epoch from (night->>'start_at')::timestamptz)::bigint as s,
                   extract(epoch from (night->>'end_at')::timestamptz)::bigint as e,
                   (night->'stages')::text as stages
              from newest join public.scoring_snapshots_v2 snap on snap.result_revision = newest.rr
             cross join lateral jsonb_array_elements(
                 case when jsonb_typeof(snap.payload->'sleep') = 'array' then snap.payload->'sleep'
                      else '[]'::jsonb end) as night
             where (night->>'start_at')::timestamptz < $4::timestamptz
               and (night->>'end_at')::timestamptz > $3::timestamptz
            """, [user, device, Self.isoUTC(dayStart), Self.isoUTC(dayEnd)])
        return rows.compactMap { r in
            guard let s = Int(r["s"] ?? ""), let e = Int(r["e"] ?? ""), e > s else { return nil }
            return ActivityContextDays.Night(start: s, end: e, stagesJSON: r["stages"])
        }
    }

    private func loadIntervals(kindClause: String, user: String, device: String,
                               dayStart: Int, dayEnd: Int) throws -> [(start: Int, end: Int)] {
        let rows = try db.query("""
            select extract(epoch from start_at)::bigint as s, extract(epoch from end_at)::bigint as e
            from public.sessions
            where user_id=$1::uuid and device_id=$2::uuid and \(kindClause)
              and start_at < $4::timestamptz and end_at > $3::timestamptz
            """, [user, device, Self.isoUTC(dayStart), Self.isoUTC(dayEnd)])
        return rows.compactMap { r in
            guard let s = Int(r["s"] ?? ""), let e = Int(r["e"] ?? "") else { return nil }
            return (start: s, end: e)
        }
    }

    /// WRIST_ON/WRIST_OFF event rows (`noop_events`) inside `[dayStart, dayEnd)`, for the wear fold.
    /// Only events within the day count: a stale pre-day OFF cannot paint the day start off-body.
    private func loadWearEvents(user: String, device: String,
                                dayStart: Int, dayEnd: Int) throws -> [(ts: Int, kind: String)] {
        let rows = try db.query("""
            select ts::text, kind from public.noop_events
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
              and (left(kind, 9) = 'WRIST_OFF' or left(kind, 8) = 'WRIST_ON')
            order by ts asc, kind asc
            """, [user, device, String(dayStart), String(dayEnd)])
        return rows.compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let kind = r["kind"], !kind.isEmpty else { return nil }
            return (ts: ts, kind: kind)
        }
    }

    /// Reconstruct half-open `WearInterval`s from WRIST event rows over `[from, to)`. Deterministic
    /// and duplicate/out-of-order safe (events are sorted; an ON while on or OFF while off is
    /// coalesced). A WRIST_ON asserts worn from its ts; a WRIST_OFF asserts off-body from its ts; the
    /// state flips at the next opposite event; an open tail extends to `to`. Gaps carry no interval,
    /// so the shared policy defaults those epochs to `.unknown` — absence of evidence is never a
    /// guessed state. Only events inside `[from, to)` are considered.
    static func wearIntervals(fromEvents events: [(ts: Int, kind: String)],
                              from: Int, to: Int) -> [WearInterval] {
        guard to > from else { return [] }
        let wear = events
            .filter { $0.ts >= from && $0.ts < to }
            .filter { $0.kind.hasPrefix("WRIST_ON") || $0.kind.hasPrefix("WRIST_OFF") }
            .sorted { lhs, rhs in
                // Deterministic tie-break at equal timestamps (audit-g34-g7-context F7): WRIST_OFF
                // sorts before WRIST_ON so an OFF+ON pair at the same second yields "on from then",
                // matching AnalyticsEngine.offWristIntervals. Swift's sort is not contractually
                // stable, so the secondary key is what makes the reconstruction reproducible.
                if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
                return lhs.kind.hasPrefix("WRIST_OFF") && rhs.kind.hasPrefix("WRIST_ON")
            }
        var out: [WearInterval] = []
        var state: WearState? = nil
        var spanStart = from
        for e in wear {
            let on = e.kind.hasPrefix("WRIST_ON")
            let next: WearState = on ? .onWrist : .offWrist
            if state == next { continue }
            if let current = state, e.ts > spanStart {
                out.append(WearInterval(start: spanStart, end: e.ts, wear: current))
            }
            state = next
            spanStart = e.ts
        }
        if let current = state, to > spanStart {
            out.append(WearInterval(start: spanStart, end: to, wear: current))
        }
        return out
    }

    // MARK: - Job row parsing

    static func parseJob(_ r: [String: String]) -> ActivityJob? {
        let uid = r["user_id"] ?? ""
        let dev = r["device_id"] ?? ""
        let day = r["day"] ?? ""
        let revText = r["input_revision"] ?? ""
        let tok = r["lease_token"] ?? ""
        let fingerprint = r["fingerprint"] ?? ""
        let objects = parsePGArray(r["input_object_ids"])
        let digests = parsePGArray(r["input_digests"])
        guard !uid.isEmpty, !dev.isEmpty, !day.isEmpty, !revText.isEmpty, !tok.isEmpty,
              !objects.isEmpty, !digests.isEmpty else { return nil }
        return ActivityJob(
            userId: uid, deviceId: dev, day: day,
            algorithmVersion: r["algorithm_version"] ?? "hart-activity-1",
            objectIds: objects, digests: digests,
            fingerprint: fingerprint,
            inputRevision: Int64(revText) ?? 0,
            leaseToken: tok)
    }

    /// Parse a Postgres array literal like `{a,b,c}` (elements may be quoted,
    /// with `\"` and `\\` escapes inside quotes). An empty literal `{}` is
    /// an empty array, not `[""]`.
    static func parsePGArray(_ text: String?) -> [String] {
        guard let text, text.count >= 2, text.first == "{", text.last == "}" else { return [] }
        let chars = Array(text.dropFirst().dropLast())
        guard !chars.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\\" && i + 1 < chars.count {
                    current.append(chars[i + 1])  // `\"` -> `"`, `\\` -> `\`
                    i += 2
                    continue
                } else if c == "\"" {
                    inQuotes = false
                } else {
                    current.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",":
                    out.append(current)
                    current = ""
                default: current.append(c)
                }
            }
            i += 1
        }
        out.append(current)
        return out
    }

    // MARK: - Timeline (pure, unit-tested)

    /// Merge records into a sorted unique per-second timeline. Conflicting
    /// duplicates (same second, different columns) are a deterministic input
    /// error — the object lane rejects those upstream, but a corrupt object
    /// must never silently win.
    static func buildTimeline(records: [Npb1ImuDecoder.Record]) throws -> ImuTimeline {
        var byTs: [Int64: Data] = [:]
        for record in records {
            guard record.columns.count == Npb1ImuDecoder.columnsPerRecord else {
                throw ActivityError.deterministic(
                    "record_column_count \(record.columns.count) for ts \(record.ts)")
            }
            let data = columnsData(record.columns)
            if let existing = byTs[record.ts] {
                guard existing == data else {
                    throw ActivityError.deterministic("conflicting_duplicate_second \(record.ts)")
                }
            } else {
                byTs[record.ts] = data
            }
        }
        let keys = byTs.keys.sorted()
        var timeline = ImuTimeline()
        timeline.seconds = keys
        var flat = [Int16]()
        flat.reserveCapacity(keys.count * Npb1ImuDecoder.columnsPerRecord)
        for ts in keys {
            let data = byTs[ts]!
            for c in 0..<Npb1ImuDecoder.columnsPerRecord {
                let lo = data[data.startIndex + c * 2]
                let hi = data[data.startIndex + c * 2 + 1]
                flat.append(Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8)))
            }
        }
        timeline.columns = flat
        return timeline
    }

    /// Split sorted unique seconds into contiguous runs [start, end). A run
    /// breaks when the next second is not exactly prev+1 (>1 s gap) or the
    /// clock resets (ts <= prev). Never fills.
    static func splitRuns(seconds: [Int64]) -> [Run] {
        var runs: [Run] = []
        guard let first = seconds.first else { return runs }
        var runStart = first
        var prev = first
        for s in seconds.dropFirst() {
            if s - prev > 1 || s <= prev {
                runs.append(Run(start: runStart, end: prev + 1))
                runStart = s
            }
            prev = s
        }
        runs.append(Run(start: runStart, end: prev + 1))
        return runs
    }

    /// Build the C10 serve-protocol requests for one contiguous run, splitting
    /// runs longer than `maxBodySeconds` into bounded body chunks at second
    /// boundaries (audit P1-2: a full-day contiguous run would otherwise build
    /// one request whose JSON line exceeds the service's 64 MiB cap and fail
    /// `requestTooLarge` -> dead-letter). Each chunk's body is `[start, end)`;
    /// serve.py emits windows only inside that body range, so no window is
    /// ever duplicated. The one 4-s window straddling a boundary has data in
    /// two chunks and is dropped by both (serve's full-containment rule —
    /// verified empirically); that single straddle per interior boundary is
    /// the only coverage loss the protocol allows.
    static func runRequests(timeline: ImuTimeline, run: Run,
                            maxBodySeconds: Int = ActivityLane.maxRequestBodySeconds)
        -> [ActivityPythonService.RunRequest] {
        guard maxBodySeconds > 0 else { return [] }
        var requests: [ActivityPythonService.RunRequest] = []
        var chunkStart = run.start
        while chunkStart < run.end {
            let chunkEnd = min(chunkStart + Int64(maxBodySeconds), run.end)
            requests.append(runRequest(timeline: timeline,
                                       run: Run(start: chunkStart, end: chunkEnd)))
            chunkStart = chunkEnd
        }
        return requests
    }

    /// Build the C10 serve-protocol request for one body chunk. `head_b64`/
    /// `tail_b64` carry up to three seconds before start / after end from the
    /// merged timeline for resample filter state; they are empty when the
    /// chunk is at the data edge (the Python side crops transients then) and
    /// never cross a data gap (audit P3-5: boundary seconds are never
    /// fabricated).
    static func runRequest(timeline: ImuTimeline,
                           run: Run) -> ActivityPythonService.RunRequest {
        var columnsB64: [String] = []
        if let startIndex = lowerBound(timeline.seconds, run.start) {
            var index = startIndex
            var t = run.start
            while t < run.end {
                if index < timeline.seconds.count, timeline.seconds[index] == t {
                    columnsB64.append(base64Columns(timeline, index: index))
                    index += 1
                }
                t += 1
            }
        }
        let head = headBoundary(timeline: timeline, runStart: run.start)
        let tail = tailBoundary(timeline: timeline, runEnd: run.end)
        return ActivityPythonService.RunRequest(
            startTs: Int(run.start), endTs: Int(run.end),
            columnsB64: columnsB64, headB64: head, tailB64: tail)
    }

    /// Up to `boundarySeconds` seconds immediately before `runStart` that
    /// actually exist AND are contiguous with the run edge (runStart-1,
    /// runStart-2, ...). A missing second ends the chain: boundary context is
    /// never fabricated across a gap (audit P3-5), so a chunk abutting a gap
    /// carries no head.
    static func headBoundary(timeline: ImuTimeline, runStart: Int64) -> [String] {
        var out: [String] = []
        var expected = runStart - 1
        while out.count < Self.boundarySeconds {
            guard let idx = exactIndex(timeline.seconds, expected), timeline.seconds[idx] == expected else { break }
            out.append(base64Columns(timeline, index: idx))
            expected -= 1
        }
        return out
    }

    /// Up to `boundarySeconds` seconds immediately after `runEnd` that
    /// actually exist AND are contiguous with the run edge (runEnd,
    /// runEnd+1, ...). A missing second ends the chain: boundary context is
    /// never fabricated across a gap (audit P3-5), so a chunk abutting a gap
    /// carries no tail.
    static func tailBoundary(timeline: ImuTimeline, runEnd: Int64) -> [String] {
        var out: [String] = []
        var expected = runEnd
        while out.count < Self.boundarySeconds {
            guard let idx = exactIndex(timeline.seconds, expected), timeline.seconds[idx] == expected else { break }
            out.append(base64Columns(timeline, index: idx))
            expected += 1
        }
        return out
    }

    /// Index of `target` in a sorted `values` array, or nil when absent.
    static func exactIndex(_ values: [Int64], _ target: Int64) -> Int? {
        guard let lo = lowerBound(values, target), lo < values.count, values[lo] == target else {
            return nil
        }
        return lo
    }

    private static func base64Columns(_ timeline: ImuTimeline, index: Int) -> String {
        let base = index * Npb1ImuDecoder.columnsPerRecord
        let data = timeline.columns.withUnsafeBytes { raw in
            Data(raw[base * 2..<(base + Npb1ImuDecoder.columnsPerRecord) * 2])
        }
        return data.base64EncodedString()
    }

    /// First index whose value >= target; nil when all values < target.
    static func lowerBound(_ values: [Int64], _ target: Int64) -> Int? {
        var lo = 0
        var hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo < values.count ? lo : nil
    }

    private static func columnsData(_ columns: [Int16]) -> Data {
        columns.withUnsafeBytes { Data($0) }
    }

    // MARK: - C10 document build (SHARED StrandAnalytics policy)

    /// Resolve the model/preprocessing versions stamped into the C10 document.
    /// The child's reported versions (from ping/infer) win; the fallbacks
    /// match what serve reports for the baseline manifest (`baseline-v0` /
    /// `1.0.0`) — never a hard-coded 'hart-activity-1', which matches no
    /// manifest and no DB fingerprint constant (audit P1-3/P3-6). The HART
    /// path always reports from the loaded manifest, so a healthy HART child
    /// stamps the true manifest versions.
    static func resolvedVersions(reportedModel: String?,
                                 reportedPreprocessing: String?)
        -> (model: String, preprocessing: String) {
        let model = (reportedModel?.isEmpty == false) ? reportedModel! : baselineModelVersion
        let preprocessing = (reportedPreprocessing?.isEmpty == false)
            ? reportedPreprocessing! : baselinePreprocessingVersion
        return (model, preprocessing)
    }

    /// Map one Python service window to the shared `ActivityWindowPrediction`
    /// (ActivityContextTypes.swift:139 — init `startTs`/`endTs` are Int
    /// seconds, `label` is the ontology `MotionLabel`). The serve protocol's
    /// Double seconds are integral, so the mapping truncates; an unexpected
    /// label string votes `unknown` (abstain) rather than crashing the lane.
    static func sharedWindow(_ w: ActivityPythonService.WindowPrediction) -> ActivityWindowPrediction {
        ActivityWindowPrediction(
            startTs: Int(w.start), endTs: Int(w.end),
            label: MotionLabel(rawValue: w.label) ?? .unknown,
            probs: w.probs, baseline: w.baseline)
    }

    /// Clip a model window to `[dayStart, dayEnd)`; nil when it no longer
    /// overlaps the day. The shared policy does NOT clip (it drops windows
    /// outside `[runStart, runEnd)`), but `publish_activity_context_v2`
    /// validates every epoch inside the job day
    /// (20261003120000_activity_context.sql), so boundary-straddling windows
    /// are clipped exactly like the pre-swap worker builder did.
    static func clippedSharedWindow(_ w: ActivityPythonService.WindowPrediction,
                                    dayStart: Int, dayEnd: Int) -> ActivityWindowPrediction? {
        let s = max(Int(w.start), dayStart)
        let e = min(Int(w.end), dayEnd)
        guard e > s else { return nil }
        return ActivityWindowPrediction(
            startTs: s, endTs: e,
            label: MotionLabel(rawValue: w.label) ?? .unknown,
            probs: w.probs, baseline: w.baseline)
    }

    /// Map a `public.sessions` sleep interval to a minimal shared
    /// `SleepSession` (init at SleepStager.swift:43-70). Only `start`/`end`
    /// carry evidence: the sessions table has no stage segments, so the
    /// session is a plain in-bed span (`stages: []`, no wake segments,
    /// `efficiency: 1.0`, no HR fields). The policy then marks epochs
    /// overlapping the span `asleep` and everything else `unknown` —
    /// stillness alone never sets sleep.
    static func sleepSession(from interval: (start: Int, end: Int)) -> SleepSession {
        SleepSession(start: interval.start, end: interval.end,
                     efficiency: 1.0, stages: [],
                     restingHR: nil, avgHRV: nil)
    }

    /// Map a `public.sessions` workout interval to a minimal shared
    /// `ExerciseSession` (init at WorkoutDetector.swift:49-84). Only
    /// `start`/`end` carry evidence; the intensity fields are zeroed/nil
    /// placeholders. The policy reads only `start`/`end` for the exercise
    /// tri-state (`true` on overlap, `unknown` otherwise — absence is never
    /// `false`).
    static func exerciseSession(from interval: (start: Int, end: Int)) -> ExerciseSession {
        ExerciseSession(start: interval.start, end: interval.end,
                        avgHR: 0, peakHR: 0, strain: nil,
                        durationS: Double(max(0, interval.end - interval.start)),
                        zoneTimePct: [:], avgHRRPct: nil, hrmax: nil,
                        hrmaxSource: "unknown", caloriesKcal: nil, caloriesKJ: nil)
    }

    /// 15-min HRV slot starts over `[dayStart, dayEnd)` that have at least one
    /// overlapping epoch (C10 `contexts.hrv_slots`; slots with no activity are
    /// omitted, matching the pre-swap builder).
    static func hrvSlotStarts(dayStart: Int, dayEnd: Int,
                              epochs: [ActivityEpoch]) -> [Int] {
        var slots: [Int] = []
        var slot = dayStart
        while slot < dayEnd {
            let end = min(slot + 900, dayEnd)
            if epochs.contains(where: { $0.startTs < end && $0.endTs > slot }) {
                slots.append(slot)
            }
            slot = end
        }
        return slots
    }

    /// Build the C10 `daily.activity_context` document from the lane's model
    /// windows through the SHARED policy/join.
    ///
    /// The temporal fold is ONE `ActivityContextPolicy.buildEpochs` call over
    /// the whole day span — not one per run. A per-run fold could hand the
    /// SAME 30-s UTC bucket to two runs when a short data gap falls inside a
    /// bucket boundary, which would duplicate `start_ts` in the grid and
    /// violate the `activity_context_epochs` PK
    /// (user_id, device_id, start_ts, fingerprint) the publish RPC inserts
    /// into. The policy's own gap-split (`gapResetSeconds = 4`) resets the
    /// hysteresis history at data gaps exactly where the shared semantics
    /// say gaps live, and this is the same single-fold the app runs, so
    /// server and phone compute identical results. Windows are clipped to
    /// the day first so no epoch can fall outside the job day the publish
    /// RPC validates.
    static func activityDocument(windows: [ActivityPythonService.WindowPrediction],
                                 sleepIntervals: [(start: Int, end: Int)],
                                 exerciseIntervals: [(start: Int, end: Int)],
                                 dayStart: Int, dayEnd: Int,
                                 inputRevision: Int64,
                                 modelVersion: String,
                                 preprocessingVersion: String,
                                 dataThrough: Int,
                                 wearIntervals: [WearInterval] = []) throws -> [String: Any] {
        let sleepSessions = sleepIntervals.map { Self.sleepSession(from: $0) }
        let exerciseSessions = exerciseIntervals.map { Self.exerciseSession(from: $0) }
        let shared = windows.compactMap {
            Self.clippedSharedWindow($0, dayStart: dayStart, dayEnd: dayEnd)
        }
        let build = ActivityContextPolicy.buildEpochs(
            windows: shared,
            runStart: dayStart, runEnd: dayEnd,
            exerciseSessions: exerciseSessions,
            sleepSessions: sleepSessions,
            wearIntervals: wearIntervals)
        return try activityDocument(epochs: build.epochs,
                                    sleepIntervals: sleepIntervals,
                                    dayStart: dayStart, dayEnd: dayEnd,
                                    inputRevision: inputRevision,
                                    modelVersion: modelVersion,
                                    preprocessingVersion: preprocessingVersion,
                                    dataThrough: dataThrough)
    }

    /// Assemble and encode the C10 document from a computed epoch grid.
    /// Also used by the scoring lane's stored-row rebuild (DayScoring.swift
    /// `attachActivityContext`), so the live lane and the scoring snapshot
    /// share one assembly path. Encode via the shared `ActivityContextDocument`
    /// Codable (exact C10 keys) then to a plain dictionary.
    ///
    /// `hrvSlots` (when non-nil) pins the `contexts.hrv_slots` to exactly
    /// those 15-min slot starts — the scoring attach path passes only slots
    /// with a PUBLISHED HRV point, so a slot with activity epochs but no HRV
    /// result is never emitted (audit P3-2; C10 payload bloat). The live lane
    /// (nil) keeps the epoch-overlap heuristic. An empty array emits no
    /// hrv_slots.
    static func activityDocument(epochs: [ActivityEpoch],
                                 sleepIntervals: [(start: Int, end: Int)],
                                 dayStart: Int, dayEnd: Int,
                                 inputRevision: Int64,
                                 modelVersion: String,
                                 preprocessingVersion: String,
                                 dataThrough: Int,
                                 hrvSlots: [Int]? = nil,
                                 ontologyVersion: String = "v1") throws -> [String: Any] {
        let summary = ActivityContextPolicy.daySummary(epochs: epochs)
        let (status, reasons) = ActivityContextPolicy.snapshotStatus(epochs: epochs)
        let slots = hrvSlots ?? Self.hrvSlotStarts(dayStart: dayStart, dayEnd: dayEnd, epochs: epochs)
        let hrv = ActivityContextJoin.hrvSlotContexts(slots: slots, epochs: epochs)
        let clipped = sleepIntervals.compactMap { iv -> (start: Int, end: Int)? in
            let s = max(iv.start, dayStart)
            let e = min(iv.end, dayEnd)
            return e > s ? (start: s, end: e) : nil
        }
        let sleepCtx = ActivityContextJoin.sleepSessionContexts(
            sessions: clipped, epochs: epochs)
        let contexts = ActivityContexts(hrvSlots: hrv, sleepSessions: sleepCtx)
        let document = ActivityContextDocument(
            schemaVersion: 1, ontologyVersion: ontologyVersion,
            modelVersion: modelVersion, preprocessingVersion: preprocessingVersion,
            inputRevision: Int(inputRevision),
            dataThrough: Self.isoUTC(dataThrough),
            status: status, reasons: reasons,
            epochs: epochs, summary: summary, contexts: contexts)
        let data = try JSONEncoder().encode(document)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ActivityError.deterministic("activity_document_encode_failed")
        }
        return obj
    }

    /// Stamp the C10 document with the job day (the publish RPC validates
    /// `p_payload ->> 'day'` against the job's day) and serialize with sorted
    /// keys. Shared so the day-key contract is testable without a DB.
    static func dayStampedJSONText(doc: inout [String: Any], day: String) throws -> String {
        doc["day"] = day
        return try jsonText(doc)
    }

    // MARK: - Day bounds

    /// UTC day bounds for a `YYYY-MM-DD` job day (epochs are UTC).
    static func utcDayBounds(_ day: String) -> (start: Int, end: Int)? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return nil }
        let start = Int(d.timeIntervalSince1970)
        return (start, start + 86_400)
    }

    static func isoUTC(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
