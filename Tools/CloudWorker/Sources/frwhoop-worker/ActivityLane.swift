import Foundation
import CZstd
import StrandAnalytics
import WhoopProtocol

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
    /// ElderNet gait quality (shadow / candidate), or nil when off (`FRWHOOP_ELDERNET_ENABLED`). Never part of the
    /// readiness gate; its failures never fail a job (`ActivityGaitQuality.swift`).
    var eldernet: ElderNetStage? = nil
    /// RecGym exercise recognition (shadow only), or nil when off (`FRWHOOP_EXERCISE_ENABLED`). Never part of the
    /// readiness gate; its failures never fail a job (`ActivityExerciseWindows.swift`).
    var exercise: ExerciseStage? = nil
    /// Downloaded objects and serve answers kept on this host (see `ActivityLocalCache`); nil turns it off.
    /// Only HART answers are cached: Inertia and ElderNet are asked for every chunk, cached HART or not.
    var cache: ActivityLocalCache? = nil
    /// How often the cache is pruned.
    static let cachePruneIntervalSeconds: TimeInterval = 6 * 3600
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
    /// The kind an expert (Inertia, ElderNet) is stopped under once its calls used up its per-job time budget.
    static let jobTimeBudgetKind = "job_time_budget"
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
        /// Windows taken from the on-host cache instead of the model (a request it had already answered).
        var windowsReused = 0
        /// Objects read from the on-host cache instead of storage.
        var objectsReused = 0
        /// ActivityContext v2 day documents stored.
        var contextDaysPublished = 0
        /// Day documents not stored because building or writing them failed (the v1 publish was
        /// unaffected). A migration that was not applied shows up here.
        var contextDayFailures = 0
        var lastContextDayError: String?
        /// HART window sets stored for the phone (`activity_encoder_windows`), and the ones that were not.
        var windowSetsPublished = 0
        var windowSetFailures = 0
        var lastWindowSetError: String?
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
        /// Shadow rows the fenced RPC refused (NULL: the lease moved on or the revision is stale). Nothing written.
        var inertiaShadowFenced = 0
        /// Jobs (or chunks) refused because the served bundle is not the pinned FRWHOOP_INERTIA_BUNDLE_SHA256.
        var inertiaBundleRefused = 0
        /// Jobs where Inertia was stopped because its calls used up the per-job time budget.
        var inertiaBudgetExhausted = 0
        /// How the stored windows met the day's observed seconds (`summary.track_report`, summed over jobs):
        /// attached, dropped (no observed second, superseded, outside the day), and seconds whose posture term
        /// the candidate decode omitted on the sleep / bed route.
        var inertiaWindowsAttached = 0
        var inertiaWindowsDropped = 0
        var inertiaPostureOmitted = 0
        /// Retention (`prune_activity_motion_heads_days`): rows deleted, and calls that failed.
        var inertiaRowsPruned = 0
        var inertiaPruneFailures = 0
        var lastInertiaPruneError: String?
        /// ElderNet (only moves when the stage is configured). Failures are counted per chunk or per job start and
        /// never reach the HART path.
        var eldernetJobs = 0
        var eldernetChunks = 0
        /// Chunks answered from `ElderNetStage.responses` (counted in `eldernetChunks` too).
        var eldernetChunksReused = 0
        var eldernetWindows = 0
        var eldernetFailures = 0
        /// Jobs where the ElderNet model was not available (ping said so, or the child would not start).
        var eldernetUnavailable = 0
        /// Jobs (or chunks) refused because the served model is not the pinned version / weights digest.
        var eldernetPinRefused = 0
        /// Jobs where ElderNet was stopped because its calls used up the per-job time budget.
        var eldernetBudgetExhausted = 0
        var lastElderNetError: String?
        var lastElderNetErrorKind: String?
        var eldernetShadowStored = 0
        var eldernetShadowFailures = 0
        /// Shadow rows the fenced RPC refused (NULL: the lease moved on or the revision is stale). Nothing written.
        var eldernetShadowFenced = 0
        var lastElderNetShadowError: String?
        var eldernetCandidateDocuments = 0
        var eldernetCandidateWithheld = 0
        var lastElderNetWithheldReason: String?
        /// How the stored windows met the day's observed seconds (`summary.track_report`, summed over jobs).
        var eldernetWindowsAttached = 0
        var eldernetWindowsDropped = 0
        /// Retention (`prune_activity_gait_windows_days`): rows deleted, and calls that failed.
        var eldernetRowsPruned = 0
        var eldernetPruneFailures = 0
        var lastElderNetPruneError: String?
        /// RecGym exercise windows (only move when the stage is configured). Failures are counted per chunk or per
        /// job start and never reach the HART path.
        var exerciseJobs = 0
        var exerciseChunks = 0
        /// Chunks answered from `ExerciseStage.responses` (counted in `exerciseChunks` too).
        var exerciseChunksReused = 0
        /// Chunks whose windows a committed publish of this process already carried: neither asked nor sent again.
        var exerciseChunksAlreadyPublished = 0
        var exerciseWindows = 0
        var exerciseFailures = 0
        var exerciseUnavailable = 0
        var exercisePinRefused = 0
        var exerciseBudgetExhausted = 0
        var lastExerciseError: String?
        var lastExerciseErrorKind: String?
        /// Committed publishes, and the windows they carried.
        var exerciseStored = 0
        var exerciseWindowsStored = 0
        var exerciseFenced = 0
        var exerciseRejected = 0
        var lastExercisePublishError: String?
        var exerciseRowsPruned = 0
        var exercisePruneFailures = 0
        var lastExercisePruneError: String?
        /// The shared release policy (ActivityExpertSelection) per raw-IMU job: jobs it decided for, and jobs whose
        /// published decode some expert channel shaped (only a production-released expert can).
        var expertSelections = 0
        /// Measured stand-ups / sit-downs found in raw IMU (hsmm-2.0).
        var verticalShifts = 0
        var expertCanonicalShaped = 0
        var lastSelectionDigest: String?
        /// The joint candidate rows (`activity_candidate_days`), written only while an expert runs in candidate or
        /// production mode.
        var candidateDaysStored = 0
        var candidateDaysFenced = 0
        var candidateDayFailures = 0
        var candidateJointDocuments = 0
        var candidateJointWithheld = 0
        var lastCandidateWithheldReason: String?
        var lastCandidateDayError: String?
        var candidateRowsPruned = 0
        var candidatePruneFailures = 0
        var lastCandidatePruneError: String?
        /// Days re-queued because another decoder / ontology / feature schema wrote them, and failed calls.
        var versionRederived = 0
        var versionReconcileFailures = 0
        var lastVersionReconcileError: String?
        var lastError: String?
        var lastErrorKind: String?
        var lastActivityAt: Date?
    }
    var stats = Stats()
    var consecutiveFailures = 0
    /// Throttle for the drain loop's reconcile call (once a minute is plenty:
    /// the RPC is idempotent and the trigger covers the common path).
    var lastReconcileAt: Date?
    var lastCachePruneAt: Date?
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
    /// Version registration and the bounded re-derivation of days another decoder wrote. Raw-IMU days are
    /// expensive (download + inference), so fewer of them are re-derived at a time than stream days.
    static let versionReconcileSQL =
        "SELECT public.reconcile_activity_context_versions($1::text,$2::jsonb,$3::integer)::text"
    static let versionReconcileImuLimit = 2
    static let versionReconcileStreamLimit = 8
    /// A stream-day source that errors at claim time (the migration is not applied yet, say) is left
    /// alone for this long, without affecting the raw-IMU path.
    var streamBackoffUntil: Date?
    static let streamBackoffSeconds: TimeInterval = 60
    /// Inertia retention runs on the lane's own cadence (like reconcile / stream enqueue), every few hours.
    var lastMotionHeadsPruneAt: Date?
    static let motionHeadsPruneIntervalSeconds: TimeInterval = 6 * 3600
    /// ElderNet retention, on the same cadence.
    var lastGaitWindowsPruneAt: Date?
    static let gaitWindowsPruneIntervalSeconds: TimeInterval = 6 * 3600
    /// Joint candidate retention, on the same cadence.
    var lastCandidateDaysPruneAt: Date?
    /// Exercise-window retention, on the same cadence.
    var lastExerciseWindowsPruneAt: Date?

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
        pruneCacheIfDue()
        pruneMotionHeadsIfDue()
        pruneGaitWindowsIfDue()
        pruneExerciseWindowsIfDue()
        pruneCandidateDaysIfDue()
    }

    /// True while some expert runs in candidate or production mode: only then is a joint candidate decoded and stored.
    var storesCandidateDays: Bool {
        (inertia.map { $0.mode != .shadow } ?? false) || (eldernet.map { $0.mode != .shadow } ?? false)
    }

    /// Joint candidate retention, while some expert runs in candidate or production mode. Best effort, like the others.
    mutating func pruneCandidateDaysIfDue(now: Date = Date()) {
        guard storesCandidateDays else { return }
        if let last = lastCandidateDaysPruneAt, now.timeIntervalSince(last) < Self.gaitWindowsPruneIntervalSeconds { return }
        lastCandidateDaysPruneAt = now
        do {
            stats.candidateRowsPruned += try ActivityCandidateDays.prune(db: db)
            stats.lastCandidatePruneError = nil
        } catch {
            stats.candidatePruneFailures += 1
            let why = ActivityContextDays.safeReason(error)
            if stats.lastCandidatePruneError != why {
                FileHandle.standardError.write(
                    ("frwhoop-worker: candidate-day retention prune failed (nothing else affected): \(why)\n").data(using: .utf8)!)
            }
            stats.lastCandidatePruneError = why
        }
    }

    /// What the lane's children measured they loaded (`<child>.<key>`, from each ping's `loaded` map and its
    /// `loaded_digest`), the policy version and the last job's selection digest: the heartbeat's
    /// `meta.lanes[].identity`. Empty entries are left out; a child that was never pinged reports nothing.
    var identity: [String: String] {
        Self.identity(service: service, inertia: inertia, eldernet: eldernet, selectionDigest: stats.lastSelectionDigest,
                      exercise: exercise)
    }

    static func identity(service: ActivityPythonService, inertia: InertiaStage?, eldernet: ElderNetStage?,
                         selectionDigest: String?, exercise: ExerciseStage? = nil) -> [String: String] {
        var out = ["expert_policy": ActivityExpertSelection.policy]
        func add(_ name: String, _ service: ActivityPythonService) {
            for (k, v) in service.loadedIdentity { out["\(name).\(k)"] = v }
            if let d = service.loadedDigest { out["\(name).loaded_digest"] = d }
        }
        add("hart", service)
        if let inertia { add("inertia", inertia.service); out["inertia.mode"] = inertia.mode.rawValue }
        if let eldernet { add("eldernet", eldernet.service); out["eldernet.mode"] = eldernet.mode.rawValue }
        if let exercise { add("recgym", exercise.service); out["recgym.mode"] = ActivityReleaseMode.shadow.rawValue }
        if let selectionDigest { out["selection_digest"] = selectionDigest }
        return out
    }

    private mutating func pruneCacheIfDue(now: Date = Date()) {
        guard let cache else { return }
        if let last = lastCachePruneAt, now.timeIntervalSince(last) < Self.cachePruneIntervalSeconds { return }
        lastCachePruneAt = now
        cache.prune(now: now)
    }

    /// Inertia retention: while the stage is configured, delete shadow / candidate rows older than
    /// `ActivityMotionHeadsDays.retentionDays`, at most once per `motionHeadsPruneIntervalSeconds`. Best effort:
    /// a failure (a database without the migration, say) is counted and logged once, never thrown.
    mutating func pruneMotionHeadsIfDue(now: Date = Date()) {
        guard inertia != nil else { return }
        if let last = lastMotionHeadsPruneAt, now.timeIntervalSince(last) < Self.motionHeadsPruneIntervalSeconds { return }
        lastMotionHeadsPruneAt = now
        do {
            stats.inertiaRowsPruned += try ActivityMotionHeadsDays.prune(db: db)
            stats.lastInertiaPruneError = nil
        } catch {
            stats.inertiaPruneFailures += 1
            let why = ActivityContextDays.safeReason(error)
            if stats.lastInertiaPruneError != why {
                FileHandle.standardError.write(
                    ("frwhoop-worker: inertia retention prune failed (nothing else affected): \(why)\n").data(using: .utf8)!)
            }
            stats.lastInertiaPruneError = why
        }
    }

    /// ElderNet retention: while the stage is configured, delete shadow / candidate rows older than
    /// `ActivityGaitWindowsDays.retentionDays`, at most once per `gaitWindowsPruneIntervalSeconds`. Best effort: a
    /// failure (a database without the migration, say) is counted and logged once, never thrown.
    mutating func pruneGaitWindowsIfDue(now: Date = Date()) {
        guard eldernet != nil else { return }
        if let last = lastGaitWindowsPruneAt, now.timeIntervalSince(last) < Self.gaitWindowsPruneIntervalSeconds { return }
        lastGaitWindowsPruneAt = now
        do {
            stats.eldernetRowsPruned += try ActivityGaitWindowsDays.prune(db: db)
            stats.lastElderNetPruneError = nil
        } catch {
            stats.eldernetPruneFailures += 1
            let why = ActivityContextDays.safeReason(error)
            if stats.lastElderNetPruneError != why {
                FileHandle.standardError.write(
                    ("frwhoop-worker: eldernet retention prune failed (nothing else affected): \(why)\n").data(using: .utf8)!)
            }
            stats.lastElderNetPruneError = why
        }
    }

    /// Exercise-window retention: while the stage is configured, delete windows older than its retention, at most
    /// once per `gaitWindowsPruneIntervalSeconds`. Best effort: a failure (a database without the migration, say) is
    /// counted and logged once, never thrown.
    mutating func pruneExerciseWindowsIfDue(now: Date = Date()) {
        guard let exercise else { return }
        if let last = lastExerciseWindowsPruneAt, now.timeIntervalSince(last) < Self.gaitWindowsPruneIntervalSeconds { return }
        lastExerciseWindowsPruneAt = now
        do {
            stats.exerciseRowsPruned += try ActivityExerciseWindows.prune(db: db, keepDays: exercise.retentionDays)
            stats.lastExercisePruneError = nil
        } catch {
            stats.exercisePruneFailures += 1
            let why = ActivityContextDays.safeReason(error)
            if stats.lastExercisePruneError != why {
                FileHandle.standardError.write(
                    ("frwhoop-worker: exercise-window retention prune failed (nothing else affected): \(why)\n").data(using: .utf8)!)
            }
            stats.lastExercisePruneError = why
        }
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
                // Register what this build runs (the HART model / preprocessing the service reported) before
                // the reconcile folds it into the day fingerprints, then re-derive a few stale days. Only once
                // the service has reported its model: a fallback stamp registered now and the real one a moment
                // later would re-fingerprint the recent days twice.
                if service.reportedModelVersion != nil {
                    let resolved = Self.resolvedVersions(reportedModel: service.reportedModelVersion,
                                                         reportedPreprocessing: service.reportedPreprocessingVersion)
                    reconcileVersions(algorithm: "hart-activity-1",
                                      versions: ActivityContextDays.lanesVersions(
                                          model: resolved.model, preprocessing: resolved.preprocessing),
                                      limit: Self.versionReconcileImuLimit)
                }
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
        // Register first, so the enqueue folds this build's versions in; sweep after it, so the sweep (which
        // re-queues any day whose fingerprint is not today's) never takes a day whose scoring just changed
        // from the enqueue and its rebuild spacing.
        let versions = ActivityContextDays.lanesVersions()
        reconcileVersions(algorithm: ActivityContextDays.streamsAlgorithmVersion, versions: versions, limit: 0)
        do {
            let out = try db.callFunctionForJSON(
                Self.streamEnqueueSQL,
                [Self.streamLookback, String(Self.streamBackfillPerCall), Self.streamMinRebuildInterval])
            stats.streamDaysEnqueued += Int(out ?? "") ?? 0
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            record(e)
            return
        } catch {
            noteStreamDayFailure(ActivityContextDays.safeReason(error))
        }
        reconcileVersions(algorithm: ActivityContextDays.streamsAlgorithmVersion, versions: versions,
                          limit: Self.versionReconcileStreamLimit)
    }

    /// Register this build's versions for a lane and re-derive, bounded, the days another decoder wrote
    /// (`reconcile_activity_context_versions`, audit D5-03). Best effort: a database without the migration, or a
    /// transient failure, is counted and retried on the next interval; claiming is never held back.
    mutating func reconcileVersions(algorithm: String, versions: [String: String], limit: Int) {
        do {
            let out = try db.callFunctionForJSON(Self.versionReconcileSQL,
                                                 [algorithm, try ActivityContextDays.versionsJSON(versions), String(limit)])
            stats.versionRederived += Int(out ?? "") ?? 0
            stats.lastVersionReconcileError = nil
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            record(e)
        } catch {
            stats.versionReconcileFailures += 1
            let why = ActivityContextDays.safeReason(error)
            if stats.lastVersionReconcileError != why {
                FileHandle.standardError.write(
                    ("frwhoop-worker: activity version reconcile (\(algorithm)): \(why)\n").data(using: .utf8)!)
            }
            stats.lastVersionReconcileError = why
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
        let (nights, exercise) = try daySpans(userId: job.userId, deviceId: job.deviceId, dayBounds: dayBounds)
        let streams = try ActivityContextDays.loadStreams(
            db: db, userId: job.userId, deviceId: job.deviceId,
            dayStart: dayBounds.start, dayEnd: dayBounds.end, lookback: true)
        let encoder = try ActivityEncoderWindowsStore.load(db: db, userId: job.userId, deviceId: job.deviceId,
                                                           day: job.day)
        let reference = ActivityContextDays.loadDecoderReference(db: db, userId: job.userId, day: job.day,
                                                                    deviceId: job.deviceId)
        let built = try ActivityContextDays.buildStreamDay(
            day: job.day, dayBounds: dayBounds, streams: streams,
            sleep: ActivityContextDays.asleepSpans(nights), inBed: nights.map { (start: $0.start, end: $0.end) },
            exercise: exercise, now: Int(Date().timeIntervalSince1970), encoder: encoder, reference: reference)
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
        var objectsReused = 0
        let records = try Self.loadObjects(
            objects: objects,
            renew: { try self.renewLease(job: job) },
            download: { key in try storage.download(objectKey: key) },
            cache: cache,
            reused: { objectsReused = $0 })
        stats.objectsReused += objectsReused

        // 3. Timeline + contiguous runs (never fill gaps).
        let timeline = try Self.buildTimeline(records: records)
        guard !timeline.seconds.isEmpty else {
            throw ActivityError.deterministic("no_imu_seconds")
        }
        let runs = Self.splitRuns(seconds: timeline.seconds)

        // 4. The published nights + workout records for the day's epochs (and its decode's lookback).
        let (nights, exercise) = try daySpans(userId: job.userId, deviceId: job.deviceId, dayBounds: dayBounds)
        let asleep = ActivityContextDays.asleepSpans(nights)
        let inBed = nights.map { (start: $0.start, end: $0.end) }

        // 4b. Wear evidence (G3/G7): WRIST_ON/OFF rows from noop_events feed the shared fold so
        // epochs carry an EVIDENCED wear_state (unknown where no event covers) instead of the
        // policy's all-unknown default. Deterministic; quiet IMU is never on-wrist evidence.
        let wearEvents = try loadWearEvents(user: job.userId, device: job.deviceId,
                                            dayStart: dayBounds.start, dayEnd: dayBounds.end)
        let wearIntervals = Self.wearIntervals(fromEvents: wearEvents,
                                               from: dayBounds.start, to: dayBounds.end)

        // 4c. Heart-rate stream for the wear-signal-quality fold (feat/wear-signal-quality V1):
        //     the same `noop_hr_samples` rows the context-day/stream-day paths load. HR feeds
        //     `hrPresent` and the `WristWearRecovery` sustained-HR closure of a durable off
        //     interval. RR, skin temperature, v18Aux optical fields and PPG waveforms are NOT
        //     loaded by this lane (no `noop_rr_intervals`/skin-temp/optical projection exists in
        //     the activity day job), so those evidence channels stay nil server-side.
        let hrSamples = try loadHrSamples(user: job.userId, device: job.deviceId,
                                          dayStart: dayBounds.start, dayEnd: dayBounds.end)
        //     The HR stream's upload watermark: an epoch past it has HR that may not be uploaded yet,
        //     so its absence is `awaiting_upload` (unknown), never sensor dropout or off-wrist.
        let hrUploadedThrough = try loadHrUploadedThrough(user: job.userId, device: job.deviceId,
                                                          from: dayBounds.start)

        // 5. Inference per run, outside any transaction, lease renewed around
        //    the long work. Windows are collected per run and folded ONCE
        //    through the shared policy in step 6 (see
        //    `ActivityLane.activityDocument` for why the fold is one call).
        // Lazily, one run's chunks at a time: a full day's base64 columns are never all in memory at once.
        let requests = runs.lazy.flatMap { Self.runRequests(timeline: timeline, run: $0) }
        let db = self.db, token = job.leaseToken, lease = leaseSeconds
        let inferred = try Self.inferChunks(
            requests, service: service, inertia: inertia, eldernet: eldernet, exercise: self.exercise, device: job.deviceId,
            versions: Self.resolvedVersions(reportedModel: service.reportedModelVersion,
                                            reportedPreprocessing: service.reportedPreprocessingVersion),
            cache: cache,
            stats: &stats,
            renew: {
                isTrue(try db.callFunctionForJSON(
                    "SELECT public.renew_activity_context_v2($1::uuid, $2::integer)::text",
                    [token, String(lease)]))
            })
        let windows = inferred.windows
        let versions = inferred.versions
        let transitionVersions = inferred.transitionVersion
        // HART-service ElderNet gait windows (the optional in-process gait expert; its own 10 s grid).
        let expertGaitWindows = inferred.expertGaitWindows

        // 5b. The shared release policy over this job's own expert results (ActivityExpertSelection): every decode
        //     below reads it. Only a production-released source shapes the published v2 decode (step 6b,
        //     `selection.canonical`); shadow and candidate sources never do. The v1 epochs are HART's alone.
        let selection = ActivityCandidateDays.selection(
            day: job.day, inputRevision: job.inputRevision,
            gait: eldernet == nil ? nil : inferred.gaitQuality.trackInput, eldernet: eldernet,
            heads: inertia == nil ? nil : inferred.motionHeads.trackInput, inertia: inertia,
            embedded: expertGaitWindows)
        stats.expertSelections += 1
        if !selection.canonicalChannels.isEmpty { stats.expertCanonicalShaped += 1 }
        stats.lastSelectionDigest = selection.digest

        // 6. Build the C10 document from the SHARED StrandAnalytics policy
        //    and join (`ActivityContextPolicy` + `ActivityContextJoin`) — the
        //    exact temporal fold the app runs, so server and phone compute
        //    identical epochs/summary/contexts.
        let dataThrough = timeline.seconds.max().map { Int($0) + 1 } ?? dayBounds.start
        var doc = try Self.activityDocument(
            windows: windows,
            // The v1 fold reads the day's own spans only, exactly as before the lookback (D2-11) widened them.
            sleepIntervals: asleep.filter { $0.end > dayBounds.start },
            // The v1 epoch fold reads only start/end (ExerciseSession has no sport); the sport
            // goes to the v2 decoder through `buildContextDay` below. audit WS-11-F08.
            exerciseIntervals: exercise.filter { $0.end > dayBounds.start }.map { (start: $0.start, end: $0.end) },
            dayStart: dayBounds.start, dayEnd: dayBounds.end,
            inputRevision: job.inputRevision,
            modelVersion: versions.model,
            preprocessingVersion: versions.preprocessing,
            dataThrough: dataThrough,
            wearIntervals: wearIntervals,
            hrSamples: hrSamples,
            hrUploadedThrough: hrUploadedThrough)
        // The publish RPC validates `p_payload ->> 'day'` against the job's
        // day (20261003120000_activity_context.sql), so the C10 document is
        // stamped with the job day before it is sealed.
        let payloadText = try Self.dayStampedJSONText(doc: &doc, day: job.day)

        // 6b. ActivityContext v2: the same windows plus their IMU features and the day's stored
        //     streams through the shared probabilistic decoder. Best effort — see the type comment.
        // 6a'. Measured stand-ups / sit-downs (hsmm-2.0): the strap's change of height over each still-bounded
        //      movement, from the raw accelerometer and gyroscope (`ActivityVerticalShift`). Evidence for the
        //      decode below and stored with the windows for the phone and the stream days.
        let verticalShifts = Self.verticalShifts(timeline: timeline, runs: runs)
            .filter { $0.ts >= dayBounds.start && $0.ts < dayBounds.end }
        stats.verticalShifts += verticalShifts.count
        var context = try buildContextDayAndInput(
            job: job, dayBounds: dayBounds, windows: windows, versions: versions,
            asleep: asleep, inBed: inBed, exercise: exercise,
            transitionVersion: transitionVersions, gaitWindows: expertGaitWindows, selection: selection,
            verticalShifts: verticalShifts)
        context.loggedWorkouts = try dayLoggedWorkouts(userId: job.userId, deviceId: job.deviceId,
                                                       from: dayBounds.start, to: dayBounds.end)

        // 6c. The windows themselves, for the phone's decoder and the stream days (best effort, like 6b).
        let windowsPayload = encoderWindowsPayload(job: job, dayBounds: dayBounds, windows: windows,
                                                   versions: versions, transitionVersion: transitionVersions,
                                                   gaitWindows: expertGaitWindows, verticalShifts: verticalShifts)

        // 6d. Inertia shadow row (and candidate comparison): built from what 6b decoded, never changing it.
        let motionHeads = inertia.map {
            Self.motionHeadsRow(day: job.day, inertia: $0, collector: inferred.motionHeads, context: context,
                                stats: &stats)
        }
        // 6e. ElderNet shadow row (and candidate comparison), the same way.
        let gaitWindows = eldernet.map {
            Self.gaitWindowsRow(day: job.day, eldernet: $0, collector: inferred.gaitQuality, context: context,
                                stats: &stats)
        }
        // 6f. The joint candidate and its ablations, only while some expert runs in candidate mode.
        let candidateDay = storesCandidateDays
            ? Self.candidateDayPayload(day: job.day, inputRevision: job.inputRevision, context: context,
                                       motionCandidate: motionHeads?.candidate, gaitCandidate: gaitWindows?.candidate,
                                       stats: &stats)
            : nil
        // 6g. RecGym exercise windows (shadow only): the chunks this process has not published yet.
        // (`self.exercise`: `exercise` here is the day's workout records.)
        let exerciseWindows = self.exercise.flatMap {
            Self.exerciseWindowsPayload(job: job, dayBounds: dayBounds, stage: $0, collector: inferred.exercise,
                                        stats: &stats)
        }
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)

        // 7–8. Fenced publish, then the scoring re-dirty.
        return try publishDay(job: job, payloadText: payloadText, dayDocument: context.built,
                              durationMS: durationMS, dayBounds: dayBounds, windowsPayload: windowsPayload,
                              motionHeads: motionHeads?.payload, gaitWindows: gaitWindows?.payload,
                              candidateDay: candidateDay, exerciseWindows: exerciseWindows)
    }

    /// What step 5 produced: the HART windows and versions exactly as before, plus the Inertia and ElderNet
    /// collectors.
    struct ChunkInference {
        var windows: [ActivityPythonService.WindowPrediction] = []
        var versions: (model: String, preprocessing: String)
        /// The transition expert's version ("none" when no expert ran): resolved from the ping, then from
        /// each answer, since the child may report its expert only with the first infer.
        var transitionVersion: String = "none"
        var motionHeads = MotionHeadsCollector()
        var gaitQuality = GaitQualityCollector()
        /// The RecGym exercise child's answers per chunk (shadow only).
        var exercise = ExerciseCollector()
        /// The HART child's own optional ElderNet gait windows (distinct from `gaitQuality`, the standalone
        /// ElderNet service's collector).
        var expertGaitWindows: [ActivityGaitWindow] = []
    }

    /// Step 5 for a job's chunks. One request per bounded body chunk (audit P1-2): a contiguous run longer
    /// than maxRequestBodySeconds is split at second boundaries and each chunk carries its own head/tail
    /// filter state. serve.py emits windows only inside the chunk's [start_ts, end_ts), so no window is
    /// duplicated in the single day fold; the only loss is the protocol's single 4-s straddle per interior
    /// boundary.
    ///
    /// For each chunk: the HART answer — from the on-host `cache` when this host already answered the same
    /// request with the same model (no lease renewal, no model call, counted in `windowsReused`), otherwise
    /// renew the lease and infer (a failure ends the job exactly as before; the answer is stored for next time).
    /// Then — only when an Inertia stage is configured and was ready at the start of the job — renew the lease
    /// again (a lost lease ends the job exactly as it does before the HART call) and the Inertia infer for the
    /// same chunk, whose every failure is absorbed and counted. Inertia answers are never cached, and a chunk
    /// whose HART answer came from the cache is still asked of Inertia, so a day's shadow row is never partial
    /// because HART was cached. The HART windows and versions are the same with or without Inertia; with Inertia
    /// off the DB calls are too.
    ///
    /// ElderNet (`eldernet`) follows the same rule after Inertia: ready-checked once at the start of the job, the
    /// lease renewed before each of its calls, every failure absorbed and counted, never cached, asked for a chunk
    /// whose HART answer came from the cache too.
    ///
    /// Each expert's job-start readiness check (`begin()`: start the child, ping it) is a call like any other: the
    /// lease is renewed right before it (a start-up plus a ping may take up to a request timeout, a third of the
    /// lease), and a lost lease ends the job as it does before HART. With an expert off, nothing changes: no
    /// renewal, no call. Each expert also has a per-job time budget (`jobBudgetSeconds`): the wall time of its
    /// readiness check and of its chunk calls is summed, and once the sum reaches the budget the expert is stopped
    /// for the rest of the job (`job_time_budget`, counted, logged once), so a slow but healthy child cannot hold a
    /// job for a day's worth of request timeouts.
    static func inferChunks<Requests: Sequence>(
        _ requests: Requests, service: ActivityPythonService,
        inertia: InertiaStage?, eldernet: ElderNetStage? = nil, exercise: ExerciseStage? = nil, device: String = "",
        versions start: (model: String, preprocessing: String),
        cache: ActivityLocalCache? = nil,
        stats: inout Stats, renew: () throws -> Bool) throws -> ChunkInference
        where Requests.Element == ActivityPythonService.RunRequest {
        var out = ChunkInference(versions: start)
        out.transitionVersion = resolvedTransitionVersions(reportedTransitionModel: service.reportedTransitionVersion)
        // Answers are cached under the versions the running child reported; before it has reported
        // there is nothing to key them by.
        let cacheable = !(service.reportedModelVersion ?? "").isEmpty
        var inertiaReady = false
        var inertiaSpent = 0.0, eldernetSpent = 0.0, exerciseSpent = 0.0
        if let inertia {
            stats.inertiaJobs += 1
            guard try renew() else {
                throw PostgresClient.Error(message: "activity lease lost during inference",
                                           sqlstate: "55000", kind: .stale)
            }
            let started = Date()
            let down = inertia.begin()
            inertiaSpent += Date().timeIntervalSince(started)
            if let down {
                if down.kind == InertiaStage.bundleMismatchKind { stats.inertiaBundleRefused += 1 }
                else { stats.inertiaUnavailable += 1 }
                out.motionHeads.stopped = down.kind
                noteInertiaFailure(&stats, kind: down.kind, message: down.message)
            } else {
                inertiaReady = true
            }
        }
        var eldernetReady = false
        if let eldernet {
            stats.eldernetJobs += 1
            guard try renew() else {
                throw PostgresClient.Error(message: "activity lease lost during inference",
                                           sqlstate: "55000", kind: .stale)
            }
            let started = Date()
            let down = eldernet.begin()
            eldernetSpent += Date().timeIntervalSince(started)
            if let down {
                if down.kind == ElderNetStage.pinMismatchKind { stats.eldernetPinRefused += 1 }
                else { stats.eldernetUnavailable += 1 }
                out.gaitQuality.stopped = down.kind
                noteElderNetFailure(&stats, kind: down.kind, message: down.message)
            } else {
                eldernetReady = true
            }
        }
        var exerciseReady = false
        if let exercise {
            stats.exerciseJobs += 1
            guard try renew() else {
                throw PostgresClient.Error(message: "activity lease lost during inference",
                                           sqlstate: "55000", kind: .stale)
            }
            let started = Date()
            let down = exercise.begin()
            exerciseSpent += Date().timeIntervalSince(started)
            if let down {
                if down.kind == ExerciseStage.pinMismatchKind { stats.exercisePinRefused += 1 }
                else { stats.exerciseUnavailable += 1 }
                out.exercise.stopped = down.kind
                noteExerciseFailure(&stats, kind: down.kind, message: down.message)
            } else {
                exerciseReady = true
            }
        }
        for request in requests {
            // A request this host has already answered with the same model is not sent again: only
            // the run that grew since the last pass (normally the newest) costs model time.
            // Keyed by the digests of what the child measured it loaded, plus the versions it reports, so changed
            // bytes under a reused version label never reuse an answer. No measured identity: no caching.
            var versions = ["model": out.versions.model, "preprocessing": out.versions.preprocessing]
            versions["transition"] = out.transitionVersion
            if let gait = service.reportedGaitVersion { versions["gait"] = gait }
            let stamp = cacheable ? service.cacheStamp : nil
            let cacheKey = stamp == nil ? nil
                : ActivityLocalCache.inferenceKey(request: request, identity: service.cacheIdentity ?? [:],
                                                  versions: versions)
            if let cacheKey, let cached = cache?.inference(key: cacheKey) {
                out.windows.append(contentsOf: ActivityContextDays.windowsWithCompatibleFeatures(cached))
                out.expertGaitWindows.append(contentsOf: ActivityContextDays.compatibleGaitWindows(cached))
                stats.windowsReused += cached.windows.count
            } else {
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
                if let tv = result.transitionVersion, !tv.isEmpty { out.transitionVersion = tv }
                out.windows.append(contentsOf: ActivityContextDays.windowsWithCompatibleFeatures(result))
                out.expertGaitWindows.append(contentsOf: ActivityContextDays.compatibleGaitWindows(result))
                stats.windowsInferred += result.windows.count
                // Kept only when the process the key names gave this answer (a respawn mid-request, or a reply
                // from another identity, is used for this job but never stored under the old key).
                if let cacheKey, let stamp, result.modelVersion == nil || result.modelVersion == out.versions.model,
                   service.answerMatches(stamp, replyDigest: result.loadedDigest) {
                    cache?.storeInference(result, key: cacheKey)
                }
            }

            // Inertia for the same chunk (whether HART came from the cache or not). Isolated: nothing it does can throw — but the lease is renewed first,
            // fenced exactly like the HART call above, so a slow Inertia child can never outlive the lease.
            if inertiaReady, let inertia, out.motionHeads.stopped == nil, inertiaSpent >= inertia.jobBudgetSeconds {
                out.motionHeads.stopped = Self.jobTimeBudgetKind
                stats.inertiaBudgetExhausted += 1
                noteInertiaFailure(&stats, kind: Self.jobTimeBudgetKind,
                                   message: "\(String(format: "%.1f", inertiaSpent)) s used of the "
                                       + "\(String(format: "%.1f", inertia.jobBudgetSeconds)) s per-job budget")
            }
            if inertiaReady, let inertia, out.motionHeads.stopped == nil {
                guard try renew() else {
                    throw PostgresClient.Error(message: "activity lease lost during inference",
                                               sqlstate: "55000", kind: .stale)
                }
                out.motionHeads.chunks += 1
                stats.inertiaChunks += 1
                let started = Date()
                let outcome = inertia.infer(request)
                inertiaSpent += Date().timeIntervalSince(started)
                switch outcome {
                case .ok(let response):
                    if let first = out.motionHeads.responses.first, first.bundle != response.bundle {
                        out.motionHeads.failedChunks += 1
                        out.motionHeads.failureKinds["bundle_changed", default: 0] += 1
                        out.motionHeads.stopped = "bundle_changed"
                        stats.inertiaFailures += 1
                        noteInertiaFailure(&stats, kind: "bundle_changed", message: "the bundle changed during a job")
                    } else {
                        out.motionHeads.responses.append(response)
                        stats.inertiaWindows += response.windows.count
                    }
                case .failed(let kind, let message, let stop):
                    out.motionHeads.failedChunks += 1
                    out.motionHeads.failureKinds[kind, default: 0] += 1
                    if stop { out.motionHeads.stopped = kind }
                    stats.inertiaFailures += 1
                    if kind == InertiaStage.bundleMismatchKind { stats.inertiaBundleRefused += 1 }
                    noteInertiaFailure(&stats, kind: kind, message: message)
                }
            }

            // ElderNet for the same chunk, the same way (its own lease renewal, nothing it does can throw).
            if eldernetReady, let eldernet, out.gaitQuality.stopped == nil, eldernetSpent >= eldernet.jobBudgetSeconds {
                out.gaitQuality.stopped = Self.jobTimeBudgetKind
                stats.eldernetBudgetExhausted += 1
                noteElderNetFailure(&stats, kind: Self.jobTimeBudgetKind,
                                    message: "\(String(format: "%.1f", eldernetSpent)) s used of the "
                                        + "\(String(format: "%.1f", eldernet.jobBudgetSeconds)) s per-job budget")
            }
            let eldernetStamp = eldernetReady ? eldernet?.service.cacheStamp : nil
            let eldernetKey = eldernetStamp == nil ? nil : eldernet?.cacheKey(request)
            if eldernetReady, let eldernet, out.gaitQuality.stopped == nil, let eldernetKey,
               let cached = eldernet.responses.response(eldernetKey),
               out.gaitQuality.responses.first.map({ $0.model == cached.model }) ?? true {
                out.gaitQuality.chunks += 1
                out.gaitQuality.responses.append(cached)
                stats.eldernetChunks += 1
                stats.eldernetChunksReused += 1
                stats.eldernetWindows += cached.windows.count
            } else if eldernetReady, let eldernet, out.gaitQuality.stopped == nil {
                guard try renew() else {
                    throw PostgresClient.Error(message: "activity lease lost during inference",
                                               sqlstate: "55000", kind: .stale)
                }
                out.gaitQuality.chunks += 1
                stats.eldernetChunks += 1
                let started = Date()
                let outcome = eldernet.infer(request)
                eldernetSpent += Date().timeIntervalSince(started)
                switch outcome {
                case .ok(let response):
                    if let first = out.gaitQuality.responses.first, first.model != response.model {
                        out.gaitQuality.failedChunks += 1
                        out.gaitQuality.failureKinds["model_changed", default: 0] += 1
                        out.gaitQuality.stopped = "model_changed"
                        stats.eldernetFailures += 1
                        noteElderNetFailure(&stats, kind: "model_changed", message: "the model changed during a job")
                    } else {
                        out.gaitQuality.responses.append(response)
                        stats.eldernetWindows += response.windows.count
                        // The same rule as HART's answers: only the process the key names may fill it.
                        if let eldernetKey, let eldernetStamp,
                           eldernet.service.answerMatches(eldernetStamp, replyDigest: nil) {
                            eldernet.responses.store(response, key: eldernetKey)
                        }
                    }
                case .failed(let kind, let message, let stop):
                    out.gaitQuality.failedChunks += 1
                    out.gaitQuality.failureKinds[kind, default: 0] += 1
                    if stop { out.gaitQuality.stopped = kind }
                    stats.eldernetFailures += 1
                    if kind == ElderNetStage.pinMismatchKind { stats.eldernetPinRefused += 1 }
                    noteElderNetFailure(&stats, kind: kind, message: message)
                }
            }

            // RecGym exercise windows for the same chunk, the same way (its own lease renewal, nothing it does can
            // throw). A chunk whose windows this process already published under the same answer key is skipped.
            if exerciseReady, let exercise {
                try inferExerciseChunk(request, stage: exercise, device: device, spent: &exerciseSpent,
                                       collector: &out.exercise, stats: &stats, renew: renew)
            }
        }
        return out
    }

    /// One chunk of the exercise stage (see `inferChunks`). Throws only for a lost lease, like the other stages.
    static func inferExerciseChunk(_ request: ActivityPythonService.RunRequest, stage: ExerciseStage, device: String,
                                   spent: inout Double, collector: inout ExerciseCollector, stats: inout Stats,
                                   renew: () throws -> Bool) throws {
        guard collector.stopped == nil else { return }
        if spent >= stage.jobBudgetSeconds {
            collector.stopped = Self.jobTimeBudgetKind
            stats.exerciseBudgetExhausted += 1
            noteExerciseFailure(&stats, kind: Self.jobTimeBudgetKind,
                                message: "\(String(format: "%.1f", spent)) s used of the "
                                    + "\(String(format: "%.1f", stage.jobBudgetSeconds)) s per-job budget")
            return
        }
        let stamp = stage.service.cacheStamp
        let key = stamp == nil ? nil : stage.cacheKey(request)
        if let key, stage.published.value(ExerciseStage.publishedKey(device: device, key: key)) == true {
            collector.alreadyPublished += 1
            stats.exerciseChunksAlreadyPublished += 1
            return
        }
        collector.chunks += 1
        stats.exerciseChunks += 1
        if let key, let cached = stage.responses.value(key),
           collector.answered.first.map({ $0.response.model == cached.model }) ?? true {
            collector.answered.append(.init(start: request.startTs, end: request.endTs, key: key, response: cached))
            stats.exerciseChunksReused += 1
            stats.exerciseWindows += cached.windows.count
            return
        }
        // A lost lease ends the job exactly as it does before the HART call.
        guard try renew() else {
            throw PostgresClient.Error(message: "activity lease lost during inference", sqlstate: "55000", kind: .stale)
        }
        let started = Date()
        let outcome = stage.infer(request)
        spent += Date().timeIntervalSince(started)
        switch outcome {
        case .ok(let response):
            if let first = collector.answered.first, first.response.model != response.model {
                collector.failedChunks += 1
                collector.failureKinds["model_changed", default: 0] += 1
                collector.stopped = "model_changed"
                stats.exerciseFailures += 1
                noteExerciseFailure(&stats, kind: "model_changed", message: "the model changed during a job")
            } else {
                collector.answered.append(.init(start: request.startTs, end: request.endTs, key: key, response: response))
                stats.exerciseWindows += response.windows.count
                if let key, let stamp, stage.service.answerMatches(stamp, replyDigest: nil) {
                    stage.responses.store(response, key: key)
                }
            }
        case .failed(let kind, let message, let stop):
            collector.failedChunks += 1
            collector.failureKinds[kind, default: 0] += 1
            if stop { collector.stopped = kind }
            stats.exerciseFailures += 1
            if kind == ExerciseStage.pinMismatchKind { stats.exercisePinRefused += 1 }
            noteExerciseFailure(&stats, kind: kind, message: message)
        }
    }

    /// Record an exercise-stage failure and say why on stderr, once per distinct kind in a row.
    static func noteExerciseFailure(_ stats: inout Stats, kind: String, message: String) {
        if stats.lastExerciseErrorKind != kind {
            FileHandle.standardError.write(
                ("frwhoop-worker: exercise \(kind) (HART path unaffected): \(message)\n").data(using: .utf8)!)
        }
        stats.lastExerciseErrorKind = kind
        stats.lastExerciseError = String("\(kind): \(message)".prefix(240))
    }

    /// The exercise payload for this job, or nil (nothing new, or the encoding failed: counted, never thrown).
    static func exerciseWindowsPayload(job: ActivityJob, dayBounds: (start: Int, end: Int), stage: ExerciseStage,
                                       collector: ExerciseCollector, stats: inout Stats) -> ActivityExerciseWindows.Built? {
        do {
            return try ActivityExerciseWindows.payload(day: job.day, dayBounds: dayBounds, device: job.deviceId,
                                                       inputRevision: job.inputRevision, collector: collector,
                                                       stage: stage)
        } catch {
            stats.exerciseRejected += 1
            stats.lastExercisePublishError = ActivityContextDays.safeReason(error)
            return nil
        }
    }

    /// Record an ElderNet failure and say why on stderr, once per distinct kind in a row.
    static func noteElderNetFailure(_ stats: inout Stats, kind: String, message: String) {
        if stats.lastElderNetErrorKind != kind {
            FileHandle.standardError.write(
                ("frwhoop-worker: eldernet \(kind) (HART path unaffected): \(message)\n").data(using: .utf8)!)
        }
        stats.lastElderNetErrorKind = kind
        stats.lastElderNetError = String("\(kind): \(message)".prefix(240))
    }

    /// The ElderNet shadow payload for this job (and, in candidate mode, the comparison decode), or nil when ElderNet
    /// is off or produced nothing valid. Never throws: a failure here is counted and skipped.
    mutating func gaitWindowsPayload(job: ActivityJob, collector: GaitQualityCollector,
                                     context: ContextDayBuild) -> String? {
        guard let eldernet else { return nil }
        return Self.gaitWindowsPayload(day: job.day, eldernet: eldernet, collector: collector, context: context,
                                       stats: &stats)
    }

    /// `gaitWindowsPayload` without the lane (no database involved), so the counters are testable.
    static func gaitWindowsPayload(day: String, eldernet: ElderNetStage, collector: GaitQualityCollector,
                                   context: ContextDayBuild, stats: inout Stats) -> String? {
        gaitWindowsRow(day: day, eldernet: eldernet, collector: collector, context: context, stats: &stats).payload
    }

    /// The ElderNet row's payload and its candidate decode (the joint candidate reuses the document as its
    /// HART + gait-quality arm). The decode and the row's authority block come from the job's selection
    /// (`context.selection`), or from one built from these windows alone when the caller has none.
    static func gaitWindowsRow(day: String, eldernet: ElderNetStage, collector: GaitQualityCollector,
                               context: ContextDayBuild, stats: inout Stats)
        -> (payload: String?, candidate: ActivityGaitWindowsDays.Candidate?) {
        guard let gait = collector.trackInput else { return (nil, nil) }
        let selection = context.selection ?? ActivityCandidateDays.selection(
            day: day, inputRevision: context.inputRevision ?? 0, gait: gait, eldernet: eldernet, heads: nil, inertia: nil)
        let candidate = ActivityGaitWindowsDays.candidate(mode: eldernet.mode, gait: gait, input: context.input,
                                                          generatedAt: context.generatedAt,
                                                          expectedModelVersion: eldernet.expectedModelVersion,
                                                          expectedWeightsDigest: eldernet.expectedWeightsDigest,
                                                          gaitPrior: eldernet.gaitPrior, selection: selection,
                                                          config: context.config, lookback: context.lookback)
        var report: GaitQualityTrackReport?
        switch candidate {
        case .notRequested: break
        case .withheld(let why):
            stats.eldernetCandidateWithheld += 1
            stats.lastElderNetWithheldReason = why
        case .document(_, let r):
            stats.eldernetCandidateDocuments += 1
            report = r
        }
        // Production windows were decoded by the published document itself.
        if report == nil, eldernet.mode == .production { report = context.built?.gaitQuality }
        // Without a candidate decode, a dry-run attachment still says how the windows meet the observed seconds.
        if report == nil, let input = context.input {
            report = ActivityGaitWindowsDays.dryRunAttachment(input: input, gait: gait)
        }
        if let report {
            stats.eldernetWindowsAttached += report.attached
            stats.eldernetWindowsDropped += report.dropped
        }
        do {
            return (try ActivityGaitWindowsDays.payload(day: day, mode: eldernet.mode, collector: collector,
                                                        candidate: candidate, attachment: report,
                                                        gaitPrior: eldernet.gaitPrior,
                                                        authority: context.selection.flatMap {
                                                            ActivityCandidateDays.authority($0, gait: eldernet)
                                                        },
                                                        workouts: LoggedWorkouts.gaitContext(
                                                            workouts: context.loggedWorkouts,
                                                            windows: gait.windows)), candidate)
        } catch {
            stats.eldernetShadowFailures += 1
            stats.lastElderNetShadowError = ActivityContextDays.safeReason(error)
            return (nil, candidate)
        }
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
        guard let inertia else { return nil }
        return Self.motionHeadsPayload(day: job.day, inertia: inertia, collector: collector, context: context,
                                       stats: &stats)
    }

    /// `motionHeadsPayload` without the lane (no database involved), so the counters are testable.
    static func motionHeadsPayload(day: String, inertia: InertiaStage, collector: MotionHeadsCollector,
                                   context: ContextDayBuild, stats: inout Stats) -> String? {
        motionHeadsRow(day: day, inertia: inertia, collector: collector, context: context, stats: &stats).payload
    }

    /// The Inertia row's payload and its candidate decode, the same way as `gaitWindowsRow`.
    static func motionHeadsRow(day: String, inertia: InertiaStage, collector: MotionHeadsCollector,
                               context: ContextDayBuild, stats: inout Stats)
        -> (payload: String?, candidate: ActivityMotionHeadsDays.Candidate?) {
        guard let heads = collector.trackInput else { return (nil, nil) }
        let selection = context.selection ?? ActivityCandidateDays.selection(
            day: day, inputRevision: context.inputRevision ?? 0, gait: nil, eldernet: nil, heads: heads, inertia: inertia)
        let candidate = ActivityMotionHeadsDays.candidate(mode: inertia.mode, heads: heads, input: context.input,
                                                         generatedAt: context.generatedAt,
                                                         expectedBundleSHA256: inertia.expectedBundleSHA256,
                                                         selection: selection,
                                                         config: context.config, lookback: context.lookback)
        var report: MotionHeadsTrackReport?
        switch candidate {
        case .notRequested: break
        case .withheld(let why):
            stats.inertiaCandidateWithheld += 1
            stats.lastInertiaWithheldReason = why
        case .document(_, let r):
            stats.inertiaCandidateDocuments += 1
            report = r
        }
        // Production windows were decoded by the published document itself.
        if report == nil, inertia.mode == .production { report = context.built?.motionHeads }
        // Without a candidate decode, a dry-run attachment still says how the windows meet the observed seconds.
        if report == nil, let input = context.input {
            report = ActivityContextTrackBuilder.attachmentReport(for: input, windows: heads.windows)
        }
        if let report {
            stats.inertiaWindowsAttached += report.attached
            stats.inertiaWindowsDropped += report.dropped
            stats.inertiaPostureOmitted += report.postureOmittedSleep
        }
        do {
            return (try ActivityMotionHeadsDays.payload(day: day, mode: inertia.mode, collector: collector,
                                                       candidate: candidate, attachment: report,
                                                       authority: context.selection.flatMap {
                                                           ActivityCandidateDays.authority($0, motion: inertia)
                                                       }), candidate)
        } catch {
            stats.inertiaShadowFailures += 1
            stats.lastInertiaShadowError = ActivityContextDays.safeReason(error)
            return (nil, candidate)
        }
    }

    /// The joint candidate payload for this job: every candidate arm of the job's selection decoded over the published
    /// decode's own input, config and lookback (the arm of exactly the production channels is the published document
    /// — HART alone while no channel is production — and each single-expert arm is that row's candidate document, so
    /// nothing is decoded twice), or nil when there is no decoder input or no selection. Never throws: a failure is
    /// counted and skipped.
    static func candidateDayPayload(day: String, inputRevision: Int64, context: ContextDayBuild,
                                    motionCandidate: ActivityMotionHeadsDays.Candidate?,
                                    gaitCandidate: ActivityGaitWindowsDays.Candidate?,
                                    stats: inout Stats) -> String? {
        guard let selection = context.selection else { return nil }
        var reuse: [String: ActivityCandidateDays.Reused] = [:]
        if let built = context.built, let published = built.document,
           let arm = selection.candidateArms.first(where: { $0.channels == selection.canonicalChannels }) {
            reuse[arm.name] = ActivityCandidateDays.Reused(document: published, gaitQuality: built.gaitQuality,
                                                           motionHeads: built.motionHeads)
        }
        if case .document(let d, let r)? = motionCandidate {
            reuse["hart+\(ActivityExpertSelection.Channel.motionHeads.rawValue)"] =
                ActivityCandidateDays.Reused(document: d, motionHeads: r)
        }
        if case .document(let d, let r)? = gaitCandidate {
            reuse["hart+\(ActivityExpertSelection.Channel.gaitQuality.rawValue)"] =
                ActivityCandidateDays.Reused(document: d, gaitQuality: r)
        }
        let decoded = ActivityCandidateDays.decode(selection: selection, input: context.input,
                                                   generatedAt: context.generatedAt, base: context.config,
                                                   lookback: context.lookback, reuse: reuse)
        if decoded.joint != nil { stats.candidateJointDocuments += 1 } else {
            stats.candidateJointWithheld += 1
            stats.lastCandidateWithheldReason = decoded.withheldReason
        }
        do {
            return try ActivityCandidateDays.payload(day: day, inputRevision: inputRevision, selection: selection,
                                                     decoded: decoded)
        } catch {
            stats.candidateDayFailures += 1
            stats.lastCandidateDayError = ActivityContextDays.safeReason(error)
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
    /// `windowsPayload` (the HART window set for the phone) is written first, under its own savepoint, like the
    /// v2 document. `motionHeads` (the Inertia shadow row) is written after the v2 document and before the v1
    /// publish, under its own savepoint and its own fenced RPC: it needs the live lease (the v1 publish releases
    /// it), it commits only with the v1 epochs, and a rejection of it never reaches any publish.
    ///
    /// `gaitWindows` (the ElderNet shadow row) follows the Inertia row the same way: its own savepoint and fenced
    /// RPC, before the v1 publish, never able to block it.
    ///
    /// `candidateDay` (the joint candidate row) follows the expert rows the same way: its own savepoint and fenced
    /// RPC, before the v1 publish, never able to block it, and never published.
    mutating func publishDay(job: ActivityJob, payloadText: String,
                             dayDocument: ActivityContextDays.Built?, durationMS: Int,
                             dayBounds: (start: Int, end: Int), windowsPayload: String? = nil,
                             motionHeads: String? = nil, gaitWindows: String? = nil,
                             candidateDay: String? = nil,
                             exerciseWindows: ActivityExerciseWindows.Built? = nil) throws -> Bool {
        try db.beginTransaction(.readCommitted)
        do {
            var windowsStored = false
            if let windowsPayload {
                switch try ActivityEncoderWindowsStore.publish(
                    db: db, token: job.leaseToken, revision: job.inputRevision, payload: windowsPayload) {
                case .stored:
                    windowsStored = true
                case .fenced:
                    break
                case .rejected(let why):
                    noteWindowSetFailure(why)
                }
            }
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
                    stats.inertiaShadowFenced += 1
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
            var gaitStored = false
            if let gaitWindows {
                switch try ActivityGaitWindowsDays.publish(
                    db: db, token: job.leaseToken, revision: job.inputRevision, payload: gaitWindows) {
                case .stored:
                    gaitStored = true
                case .fenced:
                    stats.eldernetShadowFenced += 1
                case .rejected(let why):
                    stats.eldernetShadowFailures += 1
                    if stats.lastElderNetShadowError != why {
                        FileHandle.standardError.write(
                            ("frwhoop-worker: eldernet shadow row skipped (publishes unaffected): \(why)\n")
                                .data(using: .utf8)!)
                    }
                    stats.lastElderNetShadowError = why
                }
            }
            var exerciseStored = false
            if let exerciseWindows {
                switch try ActivityExerciseWindows.publish(
                    db: db, token: job.leaseToken, revision: job.inputRevision, payload: exerciseWindows.text) {
                case .stored:
                    exerciseStored = true
                case .fenced:
                    stats.exerciseFenced += 1
                case .rejected(let why):
                    stats.exerciseRejected += 1
                    if stats.lastExercisePublishError != why {
                        FileHandle.standardError.write(
                            ("frwhoop-worker: exercise windows skipped (publishes unaffected): \(why)\n").data(using: .utf8)!)
                    }
                    stats.lastExercisePublishError = why
                }
            }
            var candidateStored = false
            if let candidateDay {
                switch try ActivityCandidateDays.publish(
                    db: db, token: job.leaseToken, revision: job.inputRevision, payload: candidateDay) {
                case .stored:
                    candidateStored = true
                case .fenced:
                    stats.candidateDaysFenced += 1
                case .rejected(let why):
                    stats.candidateDayFailures += 1
                    if stats.lastCandidateDayError != why {
                        FileHandle.standardError.write(
                            ("frwhoop-worker: candidate day skipped (publishes unaffected): \(why)\n").data(using: .utf8)!)
                    }
                    stats.lastCandidateDayError = why
                }
            }
            let publishJSON = try db.callFunctionForJSONRaw(
                "SELECT public.publish_activity_context_v2($1::uuid,$2::bigint,$3::jsonb,$4::bigint)::text",
                [job.leaseToken, String(job.inputRevision), payloadText, String(durationMS)])
            let revision = Int64(publishJSON ?? "")
            if let revision, revision > 0 {
                try db.commitTransaction()
                if dayStored { stats.contextDaysPublished += 1 }
                if windowsStored { stats.windowSetsPublished += 1 }
                if motionHeadsStored { stats.inertiaShadowStored += 1 }
                if gaitStored { stats.eldernetShadowStored += 1 }
                if candidateStored { stats.candidateDaysStored += 1 }
                if exerciseStored, let exerciseWindows {
                    stats.exerciseStored += 1
                    stats.exerciseWindowsStored += exerciseWindows.windows
                    // Only now (committed) are these chunks published; a rollback above leaves them to the next job.
                    for key in exerciseWindows.publishedKeys { exercise?.published.store(true, key: key) }
                }
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
        exercise: [(start: Int, end: Int, sport: String)],
        transitionVersion: String = "none",
        gaitWindows: [ActivityGaitWindow] = []) throws -> ActivityContextDays.Built? {
        try buildContextDayAndInput(job: job, dayBounds: dayBounds, windows: windows, versions: versions,
                                    asleep: asleep, inBed: inBed, exercise: exercise,
                                    transitionVersion: transitionVersion, gaitWindows: gaitWindows).built
    }

    /// The v2 day document and the decoder input it was built from (the Inertia candidate decodes the same
    /// input a second time).
    struct ContextDayBuild {
        var built: ActivityContextDays.Built?
        var input: ActivityContextTrackInput?
        var generatedAt: Int
        /// The job's release selection (what the published decode used); nil when the caller built none.
        var selection: ActivityExpertSelection? = nil
        var inputRevision: Int64? = nil
        /// The decoder config the published document was decoded with (the wearer's reference as of the day)
        /// and the lookback input that warmed it up, so a comparison decode can start from the same place.
        var config: ActivityDecoderConfig = ActivityDecoderConfig()
        var lookback: ActivityContextTrackInput? = nil
        /// Workout mode's logged workouts in the day, for the expert rows' context (the ElderNet gait row labels its
        /// windows against them). Empty when none was logged or the database predates workout mode.
        var loggedWorkouts: [LoggedWorkout] = []
    }

    mutating func buildContextDayAndInput(
        job: ActivityJob, dayBounds: (start: Int, end: Int),
        windows: [ActivityPythonService.WindowPrediction],
        versions: (model: String, preprocessing: String),
        asleep: [(start: Int, end: Int)],
        inBed: [(start: Int, end: Int)] = [],
        exercise: [(start: Int, end: Int, sport: String)],
        transitionVersion: String = "none",
        gaitWindows: [ActivityGaitWindow] = [],
        selection: ActivityExpertSelection? = nil,
        verticalShifts: [ActivityVerticalShiftEvidence] = []) throws -> ContextDayBuild {
        let started = Int(Date().timeIntervalSince1970)
        // The published decode reads only what the shared release policy lets shape it (no expert source here:
        // the HART-embedded gait windows alone, which are shadow).
        let selection = selection ?? ActivityExpertSelection.select(
            revisions: [job.day: job.inputRevision],
            embeddedGait: gaitWindows.isEmpty ? nil : EmbeddedGaitSource(windows: gaitWindows))
        guard contextDaysEnabled else {
            return ContextDayBuild(built: nil, input: nil, generatedAt: started, selection: selection,
                                   inputRevision: job.inputRevision)
        }
        var builtInput: ActivityContextTrackInput?
        var generatedAt = started
        do {
            guard try renewLease(job: job) else {
                throw PostgresClient.Error(message: "activity lease lost before the context decode",
                                           sqlstate: "55000", kind: .stale)
            }
            // The half hour before the day comes along to warm the decoder up (audit D2-11).
            let loaded = try ActivityContextDays.loadStreams(
                db: db, userId: job.userId, deviceId: job.deviceId,
                dayStart: dayBounds.start, dayEnd: dayBounds.end, lookback: true)
            let (streams, before) = ActivityContextDays.split(loaded, at: dayBounds.start)
            let now = Int(Date().timeIntervalSince1970)
            // A finished day's waking hours are awake, exactly as the stream day decodes them (audit D1-02).
            let known = ActivityContextDays.sleepKnown(now: now, dayEnd: dayBounds.end)
            var input = ActivityContextDays.trackInput(
                windows: windows, streams: streams, sleep: asleep, inBed: inBed, exercise: exercise,
                dayStart: dayBounds.start, dayEnd: dayBounds.end, horizon: now,
                sleepKnownOutsideSessions: known,
                encoderVersion: versions.model,
                transitionVersion: transitionVersion,
                transitionPreprocessingVersion: versions.preprocessing,
                gaitWindows: gaitWindows)
            input.verticalShifts = verticalShifts
            let lookback = ActivityContextDays.lookbackInput(
                windows: windows, streams: before, sleep: asleep, inBed: inBed, exercise: exercise,
                dayStart: dayBounds.start, sleepKnownOutsideSessions: known, encoderVersion: versions.model,
                transitionVersion: transitionVersion, transitionPreprocessingVersion: versions.preprocessing,
                gaitWindows: gaitWindows)
            // The wearer's heart-rate reference as of the day, the way the phone personalizes its decode
            // (audit D1-01 / D5-12), recorded in the document.
            let reference = ActivityContextDays.loadDecoderReference(db: db, userId: job.userId, day: job.day,
                                                                    deviceId: job.deviceId)
            builtInput = input
            generatedAt = now
            let canonical = selection.canonical(input, base: reference.config)
            // The warm-up half hour follows the same release policy as the day it warms up.
            let canonicalLookback = lookback.map { selection.canonical($0, base: reference.config).input }
            let built = try ActivityContextDays.build(
                input: canonical.input, day: job.day, modelVersion: versions.model,
                preprocessingVersion: versions.preprocessing, generatedAt: now, config: canonical.config,
                provenance: reference.provenance(gaitWindows: canonical.input.gaitWindows.count),
                lookback: canonicalLookback)
            return ContextDayBuild(built: built, input: input, generatedAt: now, selection: selection,
                                   inputRevision: job.inputRevision, config: reference.config,
                                   lookback: canonicalLookback)
        } catch let e as PostgresClient.Error where e.kind == .connectionLost || e.kind == .stale {
            throw e
        } catch {
            noteContextDayFailure(ActivityContextDays.safeReason(error))
            return ContextDayBuild(built: nil, input: builtInput, generatedAt: generatedAt, selection: selection,
                                   inputRevision: job.inputRevision)
        }
    }

    /// The `publish_activity_encoder_windows` payload for a job's windows, or nil when encoding failed
    /// (counted; the v1 publish proceeds).
    private mutating func encoderWindowsPayload(job: ActivityJob, dayBounds: (start: Int, end: Int),
                                                windows: [ActivityPythonService.WindowPrediction],
                                                versions: (model: String, preprocessing: String),
                                                transitionVersion: String = "none",
                                                gaitWindows: [ActivityGaitWindow] = [],
                                                verticalShifts: [ActivityVerticalShiftEvidence] = []) -> String? {
        var set = ActivityEncoderWindowsStore.windowSet(windows: windows, dayStart: dayBounds.start,
                                                        dayEnd: dayBounds.end, modelVersion: versions.model,
                                                        transitionVersion: transitionVersion,
                                                        preprocessingVersion: versions.preprocessing,
                                                        gaitWindows: gaitWindows)
        set.verticalShifts = verticalShifts.filter { $0.ts >= dayBounds.start && $0.ts < dayBounds.end }
        do {
            return try ActivityEncoderWindowsStore.payload(set: set, day: job.day, dayStart: dayBounds.start,
                                                           preprocessingVersion: versions.preprocessing)
        } catch {
            noteWindowSetFailure(ActivityContextDays.safeReason(error))
            return nil
        }
    }

    /// Same once-per-reason reporting as a skipped day document.
    private mutating func noteWindowSetFailure(_ why: String) {
        stats.windowSetFailures += 1
        if stats.lastWindowSetError != why {
            FileHandle.standardError.write(
                ("frwhoop-worker: activity windows not stored (v1 publish unaffected): \(why)\n")
                    .data(using: .utf8)!)
        }
        stats.lastWindowSetError = why
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
    ///
    /// `cache` (when set) holds the wire bytes of objects already downloaded. A cached copy is used only
    /// after it decompresses to the job's digest; anything else is dropped and downloaded again, so the
    /// cache can never change what a job reads.
    static func loadObjects(objects: [(id: String, digest: String, key: String)],
                            renew: () throws -> Bool,
                            download: (String) throws -> Data,
                            cache: ActivityLocalCache? = nil,
                            reused: ((Int) -> Void)? = nil) throws -> [Npb1ImuDecoder.Record] {
        var records: [Npb1ImuDecoder.Record] = []
        var reusedCount = 0
        defer { reused?(reusedCount) }
        for object in objects {
            if let wire = cache?.object(digest: object.digest) {
                if let decoded = try? VerificationLane.zstdDecompress(wire), sha256Hex(decoded) == object.digest {
                    records.append(contentsOf: try Npb1ImuDecoder.decode(decoded))
                    reusedCount += 1
                    continue
                }
                cache?.removeObject(digest: object.digest)
            }
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
            cache?.storeObject(wire, digest: object.digest)
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
    /// The published nights and workouts a day's decode reads: every span overlapping the day or the
    /// `ActivityContextDays.lookbackSeconds` before it, so the warm-up decode knows about a night or a workout
    /// that ended just before midnight instead of decoding those minutes as awake and idle (audit D2-11). The
    /// day decode and its fingerprint clip spans to the day themselves.
    /// The exercise list merges workout mode's typed log into the session records (`LoggedWorkouts.merge`), so the
    /// epochs' `exercise_session` and the decoder's workout kind see a logged workout, a running one included.
    func daySpans(userId: String, deviceId: String, dayBounds: (start: Int, end: Int)) throws
        -> (nights: [ActivityContextDays.Night], exercise: [(start: Int, end: Int, sport: String)]) {
        let from = dayBounds.start - ActivityContextDays.lookbackSeconds
        let sessions = try loadWorkouts(user: userId, device: deviceId, dayStart: from, dayEnd: dayBounds.end)
        let logged = try dayLoggedWorkouts(userId: userId, deviceId: deviceId, from: from, to: dayBounds.end)
        return (try loadPublishedNights(user: userId, device: deviceId, dayStart: from, dayEnd: dayBounds.end),
                LoggedWorkouts.merge(sessions: sessions, logged: logged))
    }

    /// Workout mode's logged workouts overlapping `[from, to)` (none on a database without 20261009170000).
    func dayLoggedWorkouts(userId: String, deviceId: String, from: Int, to: Int) throws -> [LoggedWorkout] {
        try LoggedWorkouts.load(db: db, user: userId, device: deviceId, from: from, to: to)
    }

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

    /// Workout intervals for a day, with each row's sport name read from
    /// `sessions.summary ->> 'sport'` — the phone's own name, written verbatim by
    /// the structured-sync upload. The v2 day document passes it through to the
    /// shared decoder's `DayStateWorkout` so the server sees the same `WorkoutKind`
    /// the phone's decoder sees; a row with no sport stays `""`, the same honest
    /// "unspecified" the phone uses when it has none (audit WS-11-F08).
    private func loadWorkouts(user: String, device: String,
                              dayStart: Int, dayEnd: Int) throws -> [(start: Int, end: Int, sport: String)] {
        let rows = try db.query("""
            select extract(epoch from start_at)::bigint as s, extract(epoch from end_at)::bigint as e,
                   coalesce(summary->>'sport', '') as sport
            from public.sessions
            where user_id=$1::uuid and device_id=$2::uuid and kind in ('workout','manual_workout')
              and start_at < $4::timestamptz and end_at > $3::timestamptz
            """, [user, device, Self.isoUTC(dayStart), Self.isoUTC(dayEnd)])
        return rows.compactMap { r in
            guard let s = Int(r["s"] ?? ""), let e = Int(r["e"] ?? "") else { return nil }
            return (start: s, end: e, sport: r["sport"] ?? "")
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

    /// Heart-rate samples for a day job, from the same `noop_hr_samples` rows
    /// `ActivityContextDays.loadStreams` reads (the context-day and stream-day
    /// paths). The raw-IMU day job needs them for the wear-signal-quality fold:
    /// `hrPresent` per epoch and the `WristWearRecovery` sustained-HR closure
    /// of a durable off interval. Missing rows are an empty stream, never an
    /// error.
    private func loadHrSamples(user: String, device: String,
                               dayStart: Int, dayEnd: Int) throws -> [HRSample] {
        let rows = try db.query("""
            select ts::text, bpm::text from public.noop_hr_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint and ts < $4::bigint
            order by ts
            """, [user, device, String(dayStart), String(dayEnd)])
        return rows.compactMap { r in
            guard let ts = Int(r["ts"] ?? ""), let bpm = Int(r["bpm"] ?? "") else { return nil }
            return HRSample(ts: ts, bpm: bpm)
        }
    }

    /// The newest HR second the server holds for the device at or after `from` (the HR stream's upload
    /// watermark), or nil when there is none. A primary-key range probe: max(ts) under (user, device).
    private func loadHrUploadedThrough(user: String, device: String, from: Int) throws -> Int? {
        let rows = try db.query("""
            select max(ts)::text as ts from public.noop_hr_samples
            where user_id=$1::uuid and device_id=$2::uuid and ts >= $3::bigint
            """, [user, device, String(from)])
        return rows.first.flatMap { Int($0["ts"] ?? "") }
    }

    // MARK: - Wear-signal-quality classification (feat/wear-signal-quality V1)

    /// IMU window motion bars for the wear-signal-quality fold. Derived from the lane's real
    /// `imu-feat-1` window facts (`accel_rms_g`, `gyro_rms_dps`) that the Python service returns;
    /// the numbers are CALIBRATE-style placeholders (no labeled WHOOP captures exist yet), chosen
    /// conservatively so only genuinely active wrist motion clears `imuHighMotion` and only a
    /// nearly-still wrist clears `imuQuiet`. An epoch with no overlapping window — or windows
    /// whose features an older serve.py omitted — gets nil motion flags: absence is never evidence.
    static let imuHighMotionGyroRmsDps = 25.0
    static let imuHighMotionAccelRmsG = 2.0
    static let imuQuietGyroRmsDps = 4.0
    static let imuQuietAccelRmsG = 0.25

    /// Per-epoch IMU motion flags from the overlapping encoder windows. `high`/`quiet` are nil when
    /// the epoch has no window or no window carries features; otherwise both are resolved booleans.
    static func epochImuMotion(epochStart: Int, epochEnd: Int,
                               windows: [ActivityPythonService.WindowPrediction]) -> (high: Bool?, quiet: Bool?) {
        let overlapping = windows.filter { $0.start < Double(epochEnd) && $0.end > Double(epochStart) }
        guard !overlapping.isEmpty else { return (nil, nil) }
        var sawFeatures = false
        var high = false
        var quiet = true
        for w in overlapping {
            guard let accel = w.features["accel_rms_g"], let gyro = w.features["gyro_rms_dps"] else { continue }
            sawFeatures = true
            if gyro >= imuHighMotionGyroRmsDps || accel >= imuHighMotionAccelRmsG { high = true }
            if gyro >= imuQuietGyroRmsDps || accel >= imuQuietAccelRmsG { quiet = false }
        }
        guard sawFeatures else { return (nil, nil) }
        return (high, quiet)
    }

    /// Precompute, per durable OFF interval, the timestamp from which the interval counts as
    /// closed by sustained HR (feat/wear-signal-quality V1). Reuses `WristWearRecovery` — the
    /// same sustained-HR reconciliation the phone uses — so the only exit path when a strap
    /// missed its `WRIST_ON` is identical server-side. Recovery is monotonic: once met for an
    /// epoch it stays met for every later epoch in the interval, so this is computed ONCE per
    /// off interval instead of once per epoch (a full-day off interval would otherwise re-scan
    /// the whole HR stream for every one of its 2880 epochs).
    ///
    /// The value is the completion timestamp of the confirming run (first sample at or after
    /// `start + confirmationSeconds`), stored as `completion = ts + 1` so an epoch is closed iff
    /// `epochEnd >= completion` — exactly the causal rule `WristWearRecovery.firstSustainedHR`
    /// applies when it is called with `before: epochEnd`.
    static func recoveryCompletions(wearIntervals: [WearInterval],
                                    hrSamples: [HRSample]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for interval in wearIntervals where interval.wear == .offWrist {
            guard let start = WristWearRecovery.firstSustainedHR(
                hrSamples, after: interval.start, before: interval.end) else { continue }
            let target = start + WristWearRecovery.confirmationSeconds
            // hrSamples is sorted ascending; the confirmed run is contiguous (gaps <= 5 s, valid
            // bpm), so the first valid sample at ts >= target is the confirming sample itself.
            let completion = hrSamples.first {
                $0.ts >= target && $0.ts > interval.start && $0.ts < interval.end
                    && (30...220).contains($0.bpm)
            }?.ts
            if let completion { out[interval.start] = completion + 1 }
        }
        return out
    }

    /// Resolve one epoch's `WearSignalEvidence` from the day job's loaded inputs.
    ///
    /// Offline/replay semantics throughout (the job reconstructs the day after the fact): the
    /// 45-s strap-domain freshness of `liveWrist*Fresh` does not exist server-side, so those stay
    /// nil; `durableOffActive` comes from the reconstructed `WearInterval`s — an off interval is
    /// active until a `WRIST_ON` interval or a sustained-HR run closes it (`recoveryCompletion`
    /// is the precomputed completion for the covering off interval, or nil when it never
    /// recovered). Channels the lane does not load stay nil: RR, skin temperature, v18Aux optical
    /// fields (`opticalBaselineZero`, `strapFlags*`, `contactNotDetected`, `pulseDegraded`),
    /// charging, battery telemetry, RTC-reset and stream-absence evidence. PPG waveform rows are
    /// not stored or loaded by the activity lane, so `ppgSqi` is always nil here (PpgSqi is
    /// computed on the phone, where the v26 waveform exists).
    ///
    /// `hrUploadedThrough` is the upload watermark of the HR stream: the newest `noop_hr_samples` second
    /// the server holds for this device when the job runs (nil: the newest loaded sample). An epoch that
    /// ends after it has HR that may simply not be uploaded yet, so absence there is unknown
    /// (canonical reason `awaiting_upload`, contracts/reason-codes.json), never "HR absent" — which the
    /// engine would read as sensor dropout or off-wrist.
    static func wearSignalEvidence(epochStart: Int, epochEnd: Int,
                                   wearIntervals: [WearInterval],
                                   recoveryCompletion: Int?,
                                   hrSamples: [HRSample],
                                   hrUploadedThrough: Int? = nil,
                                   imuMotion: (high: Bool?, quiet: Bool?) = (nil, nil)) -> WearSignalEvidence {
        var durableOffActive: Bool?
        var sustainedHrRecoveryMet: Bool?
        if let interval = wearIntervals.last(where: { $0.start <= epochStart && $0.end > epochStart }) {
            if interval.wear == .offWrist {
                if let completion = recoveryCompletion, epochEnd >= completion {
                    durableOffActive = false
                    sustainedHrRecoveryMet = true
                } else {
                    durableOffActive = true
                }
            } else {
                // Explicit WRIST_ON interval: any durable OFF before it was closed.
                durableOffActive = false
            }
        }
        // No sample with a plausible bpm in the epoch is a real observation only when the day has an
        // HR stream at all and the epoch lies at or before the stream's upload watermark: an empty stream
        // or a not-yet-uploaded tail stays unknown (`awaiting_upload`), never "HR absent".
        // hrSamples is sorted ascending, so a binary search finds the epoch's first sample.
        var hrPresent: Bool?
        if !hrSamples.isEmpty {
            var lo = 0, hi = hrSamples.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if hrSamples[mid].ts < epochStart { lo = mid + 1 } else { hi = mid }
            }
            var present = false
            var i = lo
            while i < hrSamples.count && hrSamples[i].ts < epochEnd {
                if (30...220).contains(hrSamples[i].bpm) { present = true; break }
                i += 1
            }
            if present {
                hrPresent = true
            } else if !Self.hrAwaitingUpload(epochEnd: epochEnd, hrSamples: hrSamples,
                                             hrUploadedThrough: hrUploadedThrough) {
                hrPresent = false
            }
        }
        return WearSignalEvidence(
            durableOffActive: durableOffActive,
            sustainedHrRecoveryMet: sustainedHrRecoveryMet,
            hrPresent: hrPresent,
            imuHighMotion: imuMotion.high,
            imuQuiet: imuMotion.quiet)
    }

    /// Canonical reason (contracts/reason-codes.json, family pipeline, inferred on the server) for an epoch
    /// whose heart rate is past the HR stream's upload watermark.
    static let hrAwaitingUploadReason = "awaiting_upload"

    /// Whether the epoch `[.., epochEnd)` reaches past the HR upload watermark: its last second is newer
    /// than the newest HR second the server holds (`hrUploadedThrough`, else the newest loaded sample).
    /// With no HR at all there is no watermark and the caller already treats the stream as unknown.
    static func hrAwaitingUpload(epochEnd: Int, hrSamples: [HRSample], hrUploadedThrough: Int?) -> Bool {
        let loaded = hrSamples.last?.ts
        guard let through = [loaded, hrUploadedThrough].compactMap({ $0 }).max() else { return true }
        return epochEnd - 1 > through
    }

    /// Thread one `WearSignalTemporalState` through a day's epochs in time order and classify each
    /// with `WearSignalQualityEngine`, returning epochs with `wearSignal` set. Additive: the
    /// existing three-state `wear` (from the `WearInterval` enrichment) is left UNCHANGED. When no
    /// evidence resolves a state the engine abstains to `.unknown` — absence is never fabricated.
    static func applyWearSignal(epochs: [ActivityEpoch],
                                windows: [ActivityPythonService.WindowPrediction],
                                wearIntervals: [WearInterval],
                                hrSamples: [HRSample],
                                hrUploadedThrough: Int? = nil) -> [ActivityEpoch] {
        guard !epochs.isEmpty else { return epochs }
        let completions = Self.recoveryCompletions(wearIntervals: wearIntervals, hrSamples: hrSamples)
        let ordered = epochs.sorted { $0.startTs < $1.startTs }
        // Windows are scanned with a two-pointer walk (epochs and windows are both time-ordered),
        // so a full-day window set costs one linear pass instead of one scan per epoch.
        let sortedWindows = windows.sorted { $0.start < $1.start }
        var state = WearSignalTemporalState()
        var windowIndex = 0
        return ordered.map { e in
            let s = Double(e.startTs), en = Double(e.endTs)
            while windowIndex < sortedWindows.count
                && Double(sortedWindows[windowIndex].end) <= s { windowIndex += 1 }
            var motion: (high: Bool?, quiet: Bool?) = (nil, nil)
            if windowIndex < sortedWindows.count && sortedWindows[windowIndex].start < en {
                var sawFeatures = false
                var high = false
                var quiet = true
                var j = windowIndex
                while j < sortedWindows.count && sortedWindows[j].start < en {
                    if let accel = sortedWindows[j].features["accel_rms_g"],
                       let gyro = sortedWindows[j].features["gyro_rms_dps"] {
                        sawFeatures = true
                        if gyro >= imuHighMotionGyroRmsDps || accel >= imuHighMotionAccelRmsG { high = true }
                        if gyro >= imuQuietGyroRmsDps || accel >= imuQuietAccelRmsG { quiet = false }
                    }
                    j += 1
                }
                if sawFeatures { motion = (high, quiet) }
            }
            let covering = wearIntervals.last { $0.start <= e.startTs && $0.end > e.startTs }
            let evidence = Self.wearSignalEvidence(
                epochStart: e.startTs, epochEnd: e.endTs,
                wearIntervals: wearIntervals,
                recoveryCompletion: covering.map { completions[$0.start] ?? nil } ?? nil,
                hrSamples: hrSamples, hrUploadedThrough: hrUploadedThrough, imuMotion: motion)
            let result = WearSignalQualityEngine.classify(evidence, state: &state, epochStart: e.startTs)
            // `.unknown` is the engine's abstention (no evidence resolved a state) and is NOT
            // emitted: an absent `wsq` already means "no wear-signal decision" to every consumer,
            // so abstaining stays indistinguishable from a pre-V1 epoch (additive, backward
            // compatible — the C10 key set of an evidence-less day is unchanged).
            let wearSignal: WearSignalState? = result.state == .unknown ? nil : result.state
            return ActivityEpoch(startTs: e.startTs, endTs: e.endTs,
                                 motion: e.motion, posture: e.posture,
                                 exercise: e.exercise, sleepState: e.sleepState,
                                 exertion: e.exertion, wear: e.wear,
                                 wearSignal: wearSignal,
                                 confidence: e.confidence, observedS: e.observedS, validS: e.validS)
        }
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

    /// Measured stand-ups / sit-downs over every contiguous run of raw IMU (`ActivityVerticalShift.detect`), in time
    /// order. Raw columns are the strap's i16 counts: accelerometer 1/4096 g, gyroscope 2000/32768 °/s per LSB.
    static func verticalShifts(timeline: ImuTimeline, runs: [Run]) -> [ActivityVerticalShiftEvidence] {
        guard !timeline.seconds.isEmpty else { return [] }
        var indexOf: [Int64: Int] = [:]
        for (i, s) in timeline.seconds.enumerated() { indexOf[s] = i }
        let n = Npb1ImuDecoder.columnsPerRecord / 6
        let aScale = Whoop5RawImu.accelScale, gScale = Whoop5RawImu.gyroScale
        var out: [ActivityVerticalShiftEvidence] = []
        for run in runs where run.end - run.start >= Int64(ActivityVerticalShift.minRunSeconds) {
            var acc: [ActivityVerticalShift.Sample] = []
            acc.reserveCapacity(Int(run.end - run.start) * n)
            for s in run.start..<run.end {
                guard let i = indexOf[s] else { continue }
                let o = timeline.columnOffset(index: i)
                for k in 0..<n {
                    func col(_ axis: Int) -> Double { Double(timeline.columns[o + axis * n + k]) }
                    acc.append(ActivityVerticalShift.Sample(
                        ax: col(0) * aScale, ay: col(1) * aScale, az: col(2) * aScale,
                        gx: col(3) * gScale, gy: col(4) * gScale, gz: col(5) * gScale))
                }
            }
            out += ActivityVerticalShift.detect(acc, sampleRateHz: Double(n), startTs: Double(run.start))
        }
        return out
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
    /// The optional transition expert's resolved version stamp: an absent report (no
    /// expert loaded) resolves to the documented "none" marker, which every consumer
    /// treats as "no transition evidence" rather than an error.
    static func resolvedTransitionVersions(reportedTransitionModel: String?) -> String {
        (reportedTransitionModel?.isEmpty == false) ? reportedTransitionModel! : "none"
    }

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
            probs: w.probs, baseline: w.baseline, calibrated: w.calibrated)
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
            probs: w.probs, baseline: w.baseline, calibrated: w.calibrated)
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
                                 wearIntervals: [WearInterval] = [],
                                 hrSamples: [HRSample] = [],
                                 hrUploadedThrough: Int? = nil) throws -> [String: Any] {
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
        // Wear-signal-quality classification (feat/wear-signal-quality V1): one temporal state per
        // day job, epochs classified in time order, `epoch.wearSignal` threaded additively on top of
        // the existing three-state `wear` enrichment (which stays untouched).
        let classified = Self.applyWearSignal(
            epochs: build.epochs, windows: windows,
            wearIntervals: wearIntervals, hrSamples: hrSamples, hrUploadedThrough: hrUploadedThrough)
        return try activityDocument(epochs: classified,
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
