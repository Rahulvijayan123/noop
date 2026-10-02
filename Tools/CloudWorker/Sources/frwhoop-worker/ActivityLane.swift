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
    /// Extra seconds before/after a run sent to Python for resample filter
    /// state (C10 serve protocol: up to 3).
    static let boundarySeconds = 3

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
        var lastError: String?
        var lastErrorKind: String?
        var lastActivityAt: Date?
    }
    var stats = Stats()
    var consecutiveFailures = 0

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

    private struct ActivityJob {
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

    mutating func drain(budget: Int) {
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
        var records: [Npb1ImuDecoder.Record] = []
        for object in objects {
            let wire: Data
            do {
                wire = try storage.download(objectKey: object.key)
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

        // 3. Timeline + contiguous runs (never fill gaps).
        let timeline = try Self.buildTimeline(records: records)
        guard !timeline.seconds.isEmpty else {
            throw ActivityError.deterministic("no_imu_seconds")
        }
        let runs = Self.splitRuns(seconds: timeline.seconds)

        // 4. Existing sleep sessions + workout records for the day's epochs.
        let asleep = try loadIntervals(kindClause: "kind = 'sleep'",
                                       user: job.userId, device: job.deviceId,
                                       dayStart: dayBounds.start, dayEnd: dayBounds.end)
        let exercise = try loadIntervals(kindClause: "kind in ('workout','manual_workout')",
                                         user: job.userId, device: job.deviceId,
                                         dayStart: dayBounds.start, dayEnd: dayBounds.end)

        // 5. Inference per run, outside any transaction, lease renewed around
        //    the long work. Windows are collected per run and folded ONCE
        //    through the shared policy in step 6 (see
        //    `ActivityLane.activityDocument` for why the fold is one call).
        var windows: [ActivityPythonService.WindowPrediction] = []
        var modelVersion = service.reportedModelVersion ?? "hart-activity-1"
        var preprocessingVersion = service.reportedPreprocessingVersion ?? "activity-preprocess-1"
        for run in runs {
            let renewed = isTrue(try db.callFunctionForJSON(
                "SELECT public.renew_activity_context_v2($1::uuid, $2::integer)::text",
                [job.leaseToken, String(leaseSeconds)]))
            guard renewed else {
                throw PostgresClient.Error(message: "activity lease lost during inference",
                                           sqlstate: "55000", kind: .stale)
            }
            let request = Self.runRequest(timeline: timeline, run: run)
            let result = try service.infer(run: request)
            guard result.ok else {
                let kind = result.errorKind ?? "inference"
                if kind == "model_missing" {
                    stats.modelUnavailable += 1
                    throw ActivityError.retryable("model_unavailable: \(result.error ?? "")")
                }
                throw ActivityError.retryable("inference_\(kind): \(result.error ?? "")")
            }
            if let mv = result.modelVersion, !mv.isEmpty { modelVersion = mv }
            if let pv = result.preprocessingVersion, !pv.isEmpty { preprocessingVersion = pv }
            windows.append(contentsOf: result.windows)
            stats.windowsInferred += result.windows.count
        }

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
            modelVersion: modelVersion,
            preprocessingVersion: preprocessingVersion,
            dataThrough: dataThrough)
        // The publish RPC validates `p_payload ->> 'day'` against the job's
        // day (20261003120000_activity_context.sql), so the C10 document is
        // stamped with the job day before it is sealed.
        let payloadText = try Self.dayStampedJSONText(doc: &doc, day: job.day)
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)

        // 7. Fenced publish in one short transaction. NULL is never success.
        try db.beginTransaction(.readCommitted)
        do {
            let publishJSON = try db.callFunctionForJSONRaw(
                "SELECT public.publish_activity_context_v2($1::uuid,$2::bigint,$3::jsonb,$4::bigint)::text",
                [job.leaseToken, String(job.inputRevision), payloadText, String(durationMS)])
            let revision = Int64(publishJSON ?? "")
            if let revision, revision > 0 {
                try db.commitTransaction()
                // 8. Coalesced re-dirty of the affected scoring day(s), after
                //    commit (worker-schema §3.3 route 2). Best effort: the
                //    next cycle handles a transient failure.
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
    /// the row's CURRENT revision so an unchanged revision counts one honest
    /// backoff and a moved revision resets the counters (the clean release).
    private mutating func releaseLease(job: ActivityJob) throws {
        let renewed = isTrue(try db.callFunctionForJSON(
            "SELECT public.renew_activity_context_v2($1::uuid, $2::integer)::text",
            [job.leaseToken, String(leaseSeconds)]))
        guard renewed else { return }
        let rows = try db.query(
            "select input_revision::text as rev from public.activity_context_jobs where lease_token=$1::uuid",
            [job.leaseToken])
        guard let current = rows.first?["rev"], !current.isEmpty else { return }
        _ = try db.callFunctionForJSON(
            "SELECT public.fail_activity_context_v2($1::uuid, $2::bigint, $3::text)::text",
            [job.leaseToken, current,
             "activity_publish_not_completed:claimed_revision=\(job.inputRevision)"])
    }

    // MARK: - Input loading

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

    // MARK: - Job row parsing

    private static func parseJob(_ r: [String: String]) -> ActivityJob? {
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

    /// Build the C10 serve-protocol request for one run. `head_b64`/`tail_b64`
    /// carry up to three seconds before start / after end from the merged
    /// timeline for resample filter state; they are empty when the run is at
    /// the data edge (the Python side crops transients then).
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
        let head = boundarySeconds(timeline: timeline, from: run.start - Int64(Self.boundarySeconds), to: run.start)
        let tail = boundarySeconds(timeline: timeline, from: run.end, to: run.end + Int64(Self.boundarySeconds))
        return ActivityPythonService.RunRequest(
            startTs: Int(run.start), endTs: Int(run.end),
            columnsB64: columnsB64, headB64: head, tailB64: tail)
    }

    /// Up to `boundarySeconds` seconds of [from, to) present in the timeline,
    /// chronological.
    static func boundarySeconds(timeline: ImuTimeline, from: Int64, to: Int64) -> [String] {
        var out: [String] = []
        guard let index = lowerBound(timeline.seconds, from) else { return out }
        var i = index
        while i < timeline.seconds.count, timeline.seconds[i] < to {
            out.append(base64Columns(timeline, index: i))
            i += 1
        }
        return out
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
                                 dataThrough: Int) throws -> [String: Any] {
        let sleepSessions = sleepIntervals.map { Self.sleepSession(from: $0) }
        let exerciseSessions = exerciseIntervals.map { Self.exerciseSession(from: $0) }
        let shared = windows.compactMap {
            Self.clippedSharedWindow($0, dayStart: dayStart, dayEnd: dayEnd)
        }
        let build = ActivityContextPolicy.buildEpochs(
            windows: shared,
            runStart: dayStart, runEnd: dayEnd,
            exerciseSessions: exerciseSessions,
            sleepSessions: sleepSessions)
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
    static func activityDocument(epochs: [ActivityEpoch],
                                 sleepIntervals: [(start: Int, end: Int)],
                                 dayStart: Int, dayEnd: Int,
                                 inputRevision: Int64,
                                 modelVersion: String,
                                 preprocessingVersion: String,
                                 dataThrough: Int,
                                 ontologyVersion: String = "v1") throws -> [String: Any] {
        let summary = ActivityContextPolicy.daySummary(epochs: epochs)
        let (status, reasons) = ActivityContextPolicy.snapshotStatus(epochs: epochs)
        let hrv = ActivityContextJoin.hrvSlotContexts(
            slots: Self.hrvSlotStarts(dayStart: dayStart, dayEnd: dayEnd, epochs: epochs),
            epochs: epochs)
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
