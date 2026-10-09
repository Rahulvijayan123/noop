import Foundation

/// Lane 3: day scoring (fenced snapshot contract).
///
/// One day = one REPEATABLE READ transaction for the claim and the snapshot seal,
/// then a second REPEATABLE READ transaction that loads the inputs, computes,
/// publishes and finishes the work item. The claim and the seal must share a
/// transaction (`scoring_legacy_seal_snapshot` asserts
/// `snapshot_transaction_id = txid_current()` and requires REPEATABLE READ), but
/// they are COMMITTED before the compute starts. That split is what makes F8's
/// failure accounting possible:
///
///   * `scoring_legacy_finish_work` runs `scoring_legacy_begin_publication` on
///     every branch, including `p_outcome='failed'`, and that function raises
///     `40001` unless the row has a sealed snapshot, a live lease and
///     `status='running'`. A failure raised inside the compute transaction would
///     therefore be swallowed (the function catches `serialization_failure` and
///     returns false), the row would stay `running` until the lease expired, and
///     the failure would never be accounted for. Sealing first and settling the
///     failure in a *fresh committed transaction* makes `failed` persist:
///     `consecutive_failures+1`, `status='retry'` (`'exhausted'` at 8),
///     `next_attempt_at = now + min(3600, 5*2^n)`.
///   * A deterministic input failure therefore converges: bounded retries with
///     backoff, then quarantine by the queue's own `exhausted` state. The lane
///     never re-claims a row it could not settle.
///
/// Failure classes are distinguished through `PostgresClient.Error.kind`:
/// `connectionLost` (the database is unreachable, so nothing can be committed and
/// the lease expiry recovers the row), `serialization`/`stale` (retried with
/// jitter because a concurrent writer won the race; the queue owns the newer work
/// if it keeps losing), and `deterministic` (settled as `failed` immediately).
///
/// The v2 queue (`claim_scoring_v2` + `publish_scoring_snapshot_v2`) runs in one
/// REPEATABLE READ transaction so the inputs and the publication share one
/// snapshot, and it PARSES the publish result: `publish_scoring_snapshot_v2`
/// returns NULL when the lease is stale, the revision moved, the algorithm is
/// disabled or an invalidation covers the day, and NULL is never treated as
/// success. A NULL outcome releases the lease through the deployed
/// `renew_scoring_v2` + `fail_scoring_v2` pair (there is no bare release RPC).
struct ScoringLane {
    let db: PostgresClient
    /// `var` so `main.swift` can attach the sleep-feature enrichment sidecar
    /// after the shared `InferenceClient` is built (same post-init wiring the
    /// candidate stage uses; see `scoring.candidate` in main.swift).
    var scorer: DayScorer
    let ingestSecret: String
    var leaseSeconds: Int = 300
    var maxFailures: Int = 8
    /// Publish attempts before a serialization/stale race is given up on.
    var publishAttempts: Int = 3
    var v2AlgorithmVersion: String = "frwhoop-server-1"
    /// Build and publish the dense intraday series after each v2 snapshot. Off via `FRWHOOP_DISABLE_LANES=series`.
    var publishesSeries: Bool = true
    /// Legacy work items whose owner uploaded within this many seconds are left for a quieter moment. The
    /// legacy queue claims an item a couple of seconds after the first arrival and that claim is revoked by the
    /// next arrival, so while a phone streams uploads every few seconds every legacy attempt is a full day
    /// computation that can only be thrown away, and the legacy queue is served before v2. 0 restores the
    /// original behaviour (claim whatever is oldest, immediately).
    var legacyQuietSeconds: Int = ScoringLane.defaultLegacyQuietSeconds
    /// An item that has waited this long is claimed even while uploads continue (at most once per this many
    /// seconds per item), so legacy results cannot lag by more than this plus one computation.
    var legacyMaxDeferSeconds: Int = ScoringLane.defaultLegacyMaxDeferSeconds
    /// When this process last claimed each legacy item, keyed by `LegacyCandidate.key`. The queue cannot supply
    /// this: `next_attempt_at` stays at the first arrival for as long as the item keeps being re-queued, so it
    /// says how long the item has waited, not when it was last tried.
    var legacyLastClaimed: [String: Date] = [:]
    /// How long the v2 lane keeps trying to take its owner's scoring-input gate before it claims without it.
    /// Uploads take that advisory lock exclusively and only then update the job row. A scoring pass used to
    /// claim (lock) the job row first and ask for the shared side of the gate at publication, the opposite
    /// order, so an upload committing during the ~7 s computation deadlocked with the publication: the pass
    /// lost and was recomputed in full, or the upload was killed. Holding the gate from before the claim
    /// restores one lock order. 0 keeps the original order (claim first).
    var v2InputGateSeconds: Int = ScoringLane.defaultV2InputGateSeconds
    /// Zone-aware midnight-closure sweep (G2-attestation item 3): how often the
    /// worker asks the DB for due day-closure work, and how many days one sweep
    /// may enqueue. 0 disables the sweep.
    var dayClosureSweepIntervalSeconds: Int = ScoringLane.defaultDayClosureSweepIntervalSeconds
    var dayClosureBatch: Int = 16
    var dayClosureSettleSeconds: Int = 600
    var lastDayClosureSweep: Date?

    static let defaultDayClosureSweepIntervalSeconds = 60
    static let defaultLegacyQuietSeconds = 20
    static let defaultLegacyMaxDeferSeconds = 1800
    static let defaultV2InputGateSeconds = 10
    static let inputGatePollSeconds = 0.1

    /// The candidate (shadow/active) stage. nil — the shipped default, because
    /// FRWHOOP_INFERENCE_URL is unset — means the lane behaves EXACTLY as before:
    /// no sidecar call, no extra transaction, no extra SQL.
    ///
    /// The stage runs only AFTER the canonical transaction has committed (both the
    /// fleet and the v2 path), never inside it. See CandidateStage.swift for why
    /// that boundary is not negotiable.
    var candidate: CandidateStage?
    /// Candidate runs per drain (`FRWHOOP_INFERENCE_BUDGET`, default 2).
    var candidateBudget: Int = 2

    /// Re-assembles a pending item's inputs when its day is not the one being scored.
    var candidateAssembler: ScoringCandidateAssembler {
        ScoringCandidateAssembler(db: db, scorer: scorer)
    }

    struct Stats {
        var claimed = 0
        var completed = 0
        var failed = 0
        /// Claims the queue had already moved past (a newer revision, or another
        /// worker won). Nothing was published and no failure was recorded.
        var superseded = 0
        /// v2 publications that returned NULL (not complete).
        var notCompleted = 0
        /// Cycles in which the legacy queue had work but every item belonged to an owner who was still
        /// uploading, so the cycle went to v2 instead (see `legacyQuietSeconds`).
        var legacyDeferred = 0
        /// v2 passes that held their owner's input gate from before the claim, and the milliseconds (summed) they
        /// spent polling for it. `gateSkipped` counts passes that gave up polling and claimed without it.
        var gateTaken = 0
        var gateWaitMillis = 0
        var gateSkipped = 0
        /// `scoring_legacy_finish_work(...,'failed',...)` returned true: the
        /// failure is durably accounted for.
        var failuresPersisted = 0
        /// The failure could not be settled (unreachable database, or the lease
        /// moved on). The lease expiry recovers the row.
        var failuresUnsettled = 0
        /// Dense-series writes (`publish_metric_series_v1`) after a committed v2 snapshot. They are derived
        /// data on a side channel: none of these counters, and no series error, changes a day's outcome.
        var seriesPublished = 0
        /// Rows the published series actually changed (upserts plus deletes); unchanged buckets cost nothing.
        var seriesRowsWritten = 0
        /// The database declined: another device is canonical for the day, or the day has no snapshot yet.
        var seriesSkipped = 0
        /// The publish was fenced as superseded: a newer input revision owns the day, so the write
        /// was intentionally refused. Neither a success nor a failure — derived data, next pass repairs.
        var seriesSuperseded = 0
        /// Day attestation (day_completeness) writes after successful v2 publishes. Like the series,
        /// attestation is derived bookkeeping: none of these counters changes a day's outcome.
        var attestationWritten = 0
        var attestationSuperseded = 0
        var attestationSkipped = 0
        var attestationFailed = 0
        /// Zone-aware midnight closure: days enqueued by the due-day sweep, and
        /// sweep failures (never fatal — the sweep is bounded and idempotent).
        var dayClosureEnqueued = 0
        var dayClosureFailed = 0
        var seriesFailed = 0
        var failureKinds: [String: Int] = [:]
        var lastScoreAt: Date?
        var lastError: String?
        var lastErrorKind: PGErrorKind?
        /// `active`-mode promotions this process produced but did NOT publish.
        /// A promotion needs a fresh canonical republish, which is parent-gated
        /// and deliberately not wired in this pass (see ScoringLane.runCandidateStage).
        var activePromotionsDeferred = 0
    }
    var stats = Stats()

    /// Consecutive cycles that ended in an unsettled failure; the lane stops
    /// after `maxFailures` so a systemic fault cannot spin.
    var consecutiveFailures = 0

    mutating func drain(budget: Int) {
        maybeSweepDayClosure()
        // Reset the candidate lane's per-drain run budget. A no-op when the
        // candidate stage is off.
        candidate?.beginDrain(budget: candidateBudget)
        // Queue depth for the heartbeat (throttled inside; no-op without the pending store).
        defer { candidate?.refreshPendingStats() }
        for _ in 0..<max(1, budget) {
            // Reconnect only at this safe boundary: no transaction is open here.
            do {
                try db.ensureConnected()
            } catch {
                record(error)
                return
            }
            do {
                switch try cycle() {
                case .empty:
                    consecutiveFailures = 0
                    // Nothing to score: spend the idle drain on pending candidate work, which
                    // is how a metric the run budget skipped still runs for a day that is not
                    // re-scored. No transaction is open here.
                    if candidate != nil {
                        let assembler = candidateAssembler
                        candidate?.drainBacklog(assembler: assembler)
                    }
                    return
                case .completed:
                    consecutiveFailures = 0
                    clearError()
                    stats.claimed += 1
                    stats.completed += 1
                    stats.lastScoreAt = Date()
                case .superseded:
                    consecutiveFailures = 0
                    clearError()
                    stats.claimed += 1
                    stats.superseded += 1
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

    private enum Cycle {
        case empty
        case completed
        case superseded
    }

    private mutating func cycle() throws -> Cycle {
        if let claim = try claimAndSealFleet() {
            return try runFleet(claim)
        }
        return try runV2()
    }

    private mutating func record(_ error: Error) {
        stats.lastError = String(describing: error).prefix(2000).description
        let kind = (error as? PostgresClient.Error)?.kind ?? .other
        stats.lastErrorKind = kind
        stats.failureKinds[kind.rawValue, default: 0] += 1
    }

    /// The heartbeat writes `lastError` to `scoring_service_heartbeats.last_error` on every beat; a
    /// scored or superseded day must retire it, or one transient failure reads as a lane failing forever.
    private mutating func clearError() {
        stats.lastError = nil
        stats.lastErrorKind = nil
    }

    // MARK: - Path A (legacy fleet queue)

    /// Claim one work item and seal its input snapshot, committed on its own so a
    /// later failure can still be settled through the fenced contract.
    private mutating func claimAndSealFleet() throws -> DayScorer.Claim? {
        try db.beginTransaction(.repeatableRead)
        do {
            guard let claim = try legacyClaim() else {
                db.rollbackTransaction()
                return nil
            }
            try seal(claim)
            try db.commitTransaction()
            return claim
        } catch {
            db.rollbackTransaction()
            throw error
        }
    }

    struct LegacyCandidate: Equatable {
        let user: String
        let device: String
        let day: String

        var key: String { "\(user)|\(device)|\(day)" }
    }

    /// The legacy queue's eligible items, oldest first, each with whether its owner is quiet (has not uploaded
    /// for `$2` seconds) and how long the item has waited. The eligibility predicate is the one
    /// `scoring_legacy_claim_one` applies; the claim function is still what takes the item, so a candidate that
    /// has since been claimed elsewhere simply yields nothing. The cap on deferral is applied in
    /// `partitionLegacyCandidates`, which knows when each item was last tried.
    ///
    /// The upload probe is `now()`-based on purpose: `now()` is stable, so the planner can use it as an index
    /// bound on `(user_id, accepted_at)` (a 0.05 ms probe) where `clock_timestamp()` forced a scan of the
    /// owner's whole receipt history (~200 ms).
    static let legacyCandidatesSQL = """
        select w.user_id::text as user_id, w.device_id::text as device_id, w.day::text as day,
               (not exists (select 1 from public.noop_upload_receipts u
                             where u.user_id = w.user_id
                               and u.accepted_at > now() - make_interval(secs => $2::integer))) as quiet,
               greatest(0, extract(epoch from (now() - w.next_attempt_at)))::bigint as waited_seconds
          from public.scoring_work_items w
          join public.devices d on d.id = w.device_id and d.user_id = w.user_id and d.is_active
         where w.done_at is null
           and w.next_attempt_at <= clock_timestamp()
           and (w.lease_expires_at is null or w.lease_expires_at <= clock_timestamp())
           and (w.failure_revision <> w.input_revision or w.consecutive_failures < $1::integer)
           and not exists (select 1 from public.noop_account_retirements r where r.user_id = w.user_id)
         order by w.next_attempt_at, w.dirty_at, w.user_id, w.device_id, w.day
         limit 32
        """

    /// Split candidate rows into the ones that may be claimed now (in queue order) and a count of the rest.
    /// An item is ready when its owner is quiet, or when it has waited `maxDeferSeconds` and this process has
    /// not tried it within that long (`lastClaimed`), so a phone that never stops uploading still gets a
    /// legacy attempt per item per `maxDeferSeconds` rather than none.
    static func partitionLegacyCandidates(
        _ rows: [[String: String]], now: Date = Date(), maxDeferSeconds: Int = defaultLegacyMaxDeferSeconds,
        lastClaimed: [String: Date] = [:]
    ) -> (ready: [LegacyCandidate], deferred: Int) {
        var ready: [LegacyCandidate] = []
        var deferred = 0
        for r in rows {
            let user = r["user_id"] ?? ""
            let device = r["device_id"] ?? ""
            let day = r["day"] ?? ""
            guard !user.isEmpty, !device.isEmpty, !day.isEmpty else { continue }
            let candidate = LegacyCandidate(user: user, device: device, day: day)
            let waited = Int(r["waited_seconds"] ?? "") ?? 0
            let triedRecently = lastClaimed[candidate.key].map { now.timeIntervalSince($0) < Double(maxDeferSeconds) } ?? false
            if isTrue(r["quiet"]) || (waited >= maxDeferSeconds && !triedRecently) {
                ready.append(candidate)
            } else {
                deferred += 1
            }
        }
        return (ready, deferred)
    }

    /// Candidates tried per cycle. The claim function skips an item whose advisory locks an upload holds, so
    /// the first ready candidate is not always the one that can be taken.
    private static let legacyClaimTries = 8

    private mutating func legacyClaim() throws -> DayScorer.Claim? {
        guard legacyQuietSeconds > 0 else {
            return try legacyClaimRow(
                "select * from public.scoring_legacy_claim_one($1::integer, $2::integer)",
                [String(leaseSeconds), String(maxFailures)])
        }
        let rows = try db.query(ScoringLane.legacyCandidatesSQL, [String(maxFailures), String(legacyQuietSeconds)])
        let now = Date()
        let (ready, deferred) = ScoringLane.partitionLegacyCandidates(
            rows, now: now, maxDeferSeconds: legacyMaxDeferSeconds, lastClaimed: legacyLastClaimed)
        for candidate in ready.prefix(ScoringLane.legacyClaimTries) {
            let claim = try legacyClaimRow(
                "select * from public.scoring_legacy_claim_one($1::integer, $2::integer, $3::uuid, $4::uuid, $5::date)",
                [String(leaseSeconds), String(maxFailures), candidate.user, candidate.device, candidate.day])
            if let claim {
                legacyLastClaimed = legacyLastClaimed.filter { now.timeIntervalSince($0.value) < Double(2 * legacyMaxDeferSeconds) }
                legacyLastClaimed[candidate.key] = now
                return claim
            }
        }
        if ready.isEmpty && deferred > 0 { stats.legacyDeferred += 1 }
        return nil
    }

    private func legacyClaimRow(_ sql: String, _ arguments: [String]) throws -> DayScorer.Claim? {
        let rows = try db.query(sql, arguments)
        guard let r = rows.first else { return nil }
        let uid = r["user_id"] ?? ""
        let dev = r["device_id"] ?? ""
        let day = r["day"] ?? ""
        let revText = r["input_revision"] ?? ""
        let tok = r["lease_token"] ?? ""
        let run = r["run_id"] ?? ""
        guard !uid.isEmpty, !dev.isEmpty, !day.isEmpty, !revText.isEmpty, !tok.isEmpty, !run.isEmpty else {
            return nil
        }
        let tzRow = r["timezone_id"] ?? ""
        let tz = tzRow.isEmpty ? "UTC" : tzRow
        return DayScorer.Claim(
            userId: uid, deviceId: dev, day: day, timezoneId: tz,
            inputRevision: Int64(revText) ?? 0, leaseToken: tok, runId: run,
            measurementRevision: Int64(r["measurement_revision"] ?? "0") ?? 0
        )
    }

    /// Seal the snapshot inside the claim transaction. Parameterized: no value is
    /// ever interpolated into SQL.
    private func seal(_ claim: DayScorer.Claim) throws {
        _ = try db.query("""
            SELECT public.scoring_legacy_seal_snapshot(
                $1::uuid, $2::uuid, $3::date, $4::bigint, $5::uuid, $6::uuid)
            """, [claim.userId, claim.deviceId, claim.day, String(claim.inputRevision),
                  claim.leaseToken, claim.runId])
    }

    private mutating func runFleet(_ claim: DayScorer.Claim) throws -> Cycle {
        var attempt = 0
        while true {
            attempt += 1
            let started = Date()
            do {
                let outcome = try publishAndFinishFleet(claim, started: started)
                guard outcome.finished else { return .superseded }
                // The publish transaction has COMMITTED and is closed. Only now
                // may the candidate stage call the sidecar (CandidateStage.swift).
                runCandidateStage(claim: claim, inputs: outcome.candidates)
                return .completed
            } catch {
                let kind = (error as? PostgresClient.Error)?.kind ?? .other
                if kind == .stale {
                    // The fenced lease moved on: the queue owns the newer work and re-running this claim cannot
                    // succeed (PGErrorKind.stale: never retry the same claim). Each retry is a whole day of
                    // computation, so do not spend one.
                    return .superseded
                }
                if kind == .serialization {
                    // A concurrent writer won the race. Retry with jitter while this claim still stands; once
                    // an upload has revoked it (its lease is cleared) every retry fails the same way. Either
                    // way the queue already owns the newer revision, so do NOT record a failure against this day.
                    if attempt < publishAttempts, (try? claimStillHeld(claim)) == true {
                        jitterSleep(attempt: attempt)
                        continue
                    }
                    return .superseded
                }
                let durationMS = Int(Date().timeIntervalSince(started) * 1000)
                try settleFleetFailure(claim, error: error, durationMS: durationMS)
                throw error
            }
        }
    }

    /// Whether the work item still carries this claim's lease. An upload re-queues the day by clearing it.
    private func claimStillHeld(_ claim: DayScorer.Claim) throws -> Bool {
        let rows = try db.query("""
            select 1 as held from public.scoring_work_items
             where user_id=$1::uuid and device_id=$2::uuid and day=$3::date
               and lease_token=$4::uuid and run_id=$5::uuid
               and status='running' and lease_expires_at > clock_timestamp()
            """, [claim.userId, claim.deviceId, claim.day, claim.leaseToken, claim.runId])
        return !rows.isEmpty
    }

    /// Returns whether the queue accepted the completion, plus the candidate-lane
    /// inputs assembled during scoring. False means the claim was superseded, in
    /// which case the transaction is rolled back so nothing is published for a
    /// claim the queue no longer owns (and no candidate is computed).
    private func publishAndFinishFleet(_ claim: DayScorer.Claim, started: Date)
        throws -> (finished: Bool, candidates: DayScorer.CandidateInputs?) {
        try db.beginTransaction(.repeatableRead)
        do {
            // `candidateLane` gates the candidate input assembly (audit DD-2):
            // with no client there is no selection read and no per-stream work.
            let payloads = try scorer.scoreAndBuildPayloads(claim: claim, buildSeries: false,
                                                    candidateLane: candidate != nil)
            let legacyData = try jsonText(payloads.legacy)
            try db.exec("SELECT set_config('request.jwt.claims', '{\"role\":\"service_role\"}', true)")
            _ = try db.callFunctionForJSONRaw(
                "SELECT public.engine_publish_legacy_fenced($1::text, $2::jsonb)::text",
                [ingestSecret, legacyData])
            let durationMS = Int(Date().timeIntervalSince(started) * 1000)
            let finishJSON = try db.callFunctionForJSONRaw(
                "SELECT public.scoring_legacy_finish_work($1::uuid,$2::uuid,$3::date,$4::bigint,$5::uuid,$6::uuid,'done',$7::integer,NULL)::text",
                [claim.userId, claim.deviceId, claim.day, String(claim.inputRevision),
                 claim.leaseToken, claim.runId, String(durationMS)])
            let finished = isTrue(finishJSON)
            if finished {
                try db.commitTransaction()
            } else {
                db.rollbackTransaction()
            }
            return (finished, finished ? payloads.candidates : nil)
        } catch {
            db.rollbackTransaction()
            throw error
        }
    }

    /// Run the candidate lane for one committed day. Called ONLY after the
    /// canonical transaction has committed and closed, so the sidecar call happens
    /// with no transaction open and the candidate write gets its own fresh one.
    private mutating func runCandidateStage(claim: DayScorer.Claim, inputs: DayScorer.CandidateInputs?) {
        guard let inputs, candidate != nil else { return }
        let assembler = candidateAssembler
        candidate?.run(claim: claim, inputs: inputs, assembler: assembler)
        // ACTIVE PROMOTION SEAM (parent-gated, unreachable while every metric is
        // `off`). An `active` ok result must republish the canonical snapshot to
        // become the canonical value; the transform is implemented and unit-tested
        // (`DayScorer.applyActiveHrvSubstitution`) but the republish is NOT wired
        // here, so this records the deferral instead of silently changing nothing.
        if let substitution = candidate?.lastActiveSubstitution {
            self.stats.activePromotionsDeferred += 1
            FileHandle.standardError.write(
                ("frwhoop-worker: active hrv substitution deferred (provider="
                 + "\(substitution.providerId) value=\(substitution.value) "
                 + "input_sha256=\(substitution.inputSHA256.prefix(12))); canonical republish is parent-gated\n")
                    .data(using: .utf8)!)
        }
    }

    /// Persist the failure through the fenced contract, in its own committed
    /// transaction, and verify the result. Called only after the failed
    /// transaction has been rolled back.
    private mutating func settleFleetFailure(_ claim: DayScorer.Claim, error: Error, durationMS: Int) throws {
        let kind = (error as? PostgresClient.Error)?.kind ?? .other
        if kind == .connectionLost {
            // Nothing can be committed while the database is unreachable; the
            // lease expiry hands the day back to the queue.
            stats.failuresUnsettled += 1
            return
        }
        let message = "\(kind.rawValue): \(String(describing: error))"
        do {
            let result = try db.callFunctionForJSON(
                "SELECT public.scoring_legacy_finish_work($1::uuid,$2::uuid,$3::date,$4::bigint,$5::uuid,$6::uuid,'failed',NULLIF($7,'')::integer,$8::text)::text",
                [claim.userId, claim.deviceId, claim.day, String(claim.inputRevision),
                 claim.leaseToken, claim.runId, String(durationMS), String(message.prefix(2000))])
            if isTrue(result) {
                stats.failuresPersisted += 1
            } else {
                // false = the lease or the input revision moved on. The queue
                // already owns the newer work, so there is nothing to settle.
                stats.failuresUnsettled += 1
            }
        } catch {
            stats.failuresUnsettled += 1
            stats.lastError = "failure settlement failed: \(String(describing: error))"
        }
    }

    // MARK: - Path B (v2 snapshot queue)

    private mutating func runV2() throws -> Cycle {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try runV2Once()
            } catch {
                let kind = (error as? PostgresClient.Error)?.kind ?? .other
                if (kind == .serialization || kind == .stale) && attempt < publishAttempts {
                    jitterSleep(attempt: attempt)
                    continue
                }
                throw error
            }
        }
    }

    /// One v2 job inside a single REPEATABLE READ transaction: the claim, the
    /// input reads and the publication all share one snapshot.
    private mutating func runV2Once() throws -> Cycle {
        var heldGate: String?
        if v2InputGateSeconds > 0 {
            guard let owner = try peekV2Owner() else { return .empty }
            if try takeInputGate(owner: owner) {
                heldGate = owner
            } else {
                stats.gateSkipped += 1
            }
        }
        func dropGate() {
            guard let owner = heldGate else { return }
            heldGate = nil
            releaseInputGate(owner: owner)
        }
        defer { dropGate() }

        try db.beginTransaction(.repeatableRead)
        do {
            let rows = try db.query(
                "select * from public.claim_scoring_v2($1::text, $2::integer)",
                [v2AlgorithmVersion, String(leaseSeconds)])
            guard let r = rows.first else {
                db.rollbackTransaction()
                return .empty
            }
            let uid = r["user_id"] ?? ""
            let dev = r["device_id"] ?? ""
            let day = r["day"] ?? ""
            let revText = r["input_revision"] ?? ""
            let tok = r["lease_token"] ?? ""
            let algorithmVersion = (r["algorithm_version"] ?? "").isEmpty ? v2AlgorithmVersion : r["algorithm_version"]!
            guard !uid.isEmpty, !dev.isEmpty, !day.isEmpty, !revText.isEmpty, !tok.isEmpty else {
                db.rollbackTransaction()
                return .empty
            }
            let tz = try resolveTimezone(userId: uid, deviceId: dev, day: day)
            let claim = DayScorer.Claim(
                userId: uid, deviceId: dev, day: day, timezoneId: tz,
                inputRevision: Int64(revText) ?? 0, leaseToken: tok, runId: UUID().uuidString.lowercased(),
                measurementRevision: 0
            )
            let started = Date()
            // `enrichFeatures: true`: this is the V2 SNAPSHOT path — the only
            // path that publishes the snapshot payload the sleep-features
            // document attaches to (the legacy fleet path discards it).
            let payloads = try scorer.scoreAndBuildPayloads(claim: claim, buildSeries: publishesSeries,
                                                            candidateLane: candidate != nil,
                                                            enrichFeatures: true)
            let snapshotData = try jsonText(payloads.snapshot)
            let durationMS = Int(Date().timeIntervalSince(started) * 1000)
            let publishJSON = try db.callFunctionForJSONRaw(
                "SELECT public.publish_scoring_snapshot_v2($1::uuid,$2::bigint,$3::jsonb,$4::bigint)::text",
                [tok, revText, snapshotData, String(durationMS)])
            let revision = Int64(publishJSON ?? "")
            if let revision, revision > 0 {
                try db.commitTransaction()
                dropGate()
                publishSeries(payloads.series, claim: claim, scoringVersion: algorithmVersion)
                publishAttestation(payloads.snapshot, claim: claim, scoringVersion: algorithmVersion,
                                   resultRevision: revision)
                // The snapshot transaction is committed and closed. The candidate
                // stage may now call the sidecar with no transaction open.
                runCandidateStage(claim: claim, inputs: payloads.candidates)
                return .completed
            }
            // NULL (or a non-positive revision) means the publication did NOT
            // happen: stale lease, moved revision, disabled algorithm, or an
            // invalidation covering the day. Never treat it as success.
            db.rollbackTransaction()
            stats.notCompleted += 1
            try releaseV2Lease(token: tok, claimedRevision: revText, algorithmVersion: algorithmVersion)
            return .superseded
        } catch {
            db.rollbackTransaction()
            throw error
        }
    }

    /// `pg_try_advisory_lock_shared` on the key every upload takes exclusively and `publish_scoring_snapshot_v2`
    /// takes shared (`hashtextextended('scoring-inputs-v2:' || owner, 0)`). Session level, so it outlives the
    /// transaction that opens after it and the transaction's snapshot is taken only once the gate is held.
    /// The fenced dense-series write: carries the claimed input revision ($6) so
    /// the RPC can reject a stale pass (G2-attestation item 4 / T31).
    static let seriesPublishSQL = """
        SELECT public.publish_metric_series_v1($1::uuid,$2::uuid,$3::date,$4::text,$5::jsonb,$6::bigint)::text
        """
    /// The fenced day-attestation write (publish_day_attestation_v1): carries the
    /// claimed input revision ($4) so an older pass cannot overwrite a newer day.
    static let dayAttestationSQL = """
        SELECT public.publish_day_attestation_v1($1::uuid,$2::uuid,$3::date,$4::bigint,$5::text,$6::jsonb)::text
        """
    static let inputGateTrySQL = """
        select pg_try_advisory_lock_shared(hashtextextended('scoring-inputs-v2:' || $1::text, 0))::text as acquired
        """
    static let inputGateReleaseSQL = """
        select pg_advisory_unlock_shared(hashtextextended('scoring-inputs-v2:' || $1::text, 0))::text as released
        """
    /// A dry-run claim: the owner whose job `claim_scoring_v2` would take next. The claim is rolled back, so
    /// no lease is left behind and the cooldown clock is untouched.
    static let v2OwnerProbeSQL = "select user_id::text as user_id from public.claim_scoring_v2($1::text, $2::integer)"

    private func peekV2Owner() throws -> String? {
        try db.beginTransaction(.readCommitted)
        defer { db.rollbackTransaction() }
        let rows = try db.query(ScoringLane.v2OwnerProbeSQL, [v2AlgorithmVersion, String(leaseSeconds)])
        guard let owner = rows.first?["user_id"], !owner.isEmpty else { return nil }
        return owner
    }

    /// Poll for the gate instead of queueing for it. A queued request would sit ahead of every upload that
    /// arrives afterwards, so each of them would wait out the whole computation as well as the queue ahead of
    /// it, and the uploads that wait longest hit the API's statement timeout. Polling only ever takes the gate
    /// at an instant when no upload holds it or waits for it. Returns false when it stays busy for
    /// `v2InputGateSeconds`; the pass then claims without it (the original order), so a phone that never stops
    /// uploading cannot starve scoring.
    private mutating func takeInputGate(owner: String) throws -> Bool {
        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(v2InputGateSeconds))
        while true {
            let rows = try db.query(ScoringLane.inputGateTrySQL, [owner])
            if isTrue(rows.first?["acquired"]) {
                stats.gateTaken += 1
                stats.gateWaitMillis += Int(Date().timeIntervalSince(started) * 1000)
                return true
            }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: ScoringLane.inputGatePollSeconds)
        }
    }

    /// Release the gate once the snapshot transaction is over. Called only after a commit or rollback: inside an
    /// aborted transaction the unlock would fail and the lock would stay held, stalling every upload for the
    /// owner. A closed connection drops its session locks, so a failed unlock here can only mean the
    /// connection is already gone; `pg_advisory_unlock_all` is the backstop for anything else.
    private func releaseInputGate(owner: String) {
        let released = (try? db.query(ScoringLane.inputGateReleaseSQL, [owner]))?.first?["released"]
        if !isTrue(released) {
            _ = try? db.query("select pg_advisory_unlock_all()::text as released", [])
        }
    }

    /// Write the day's dense intraday series. It runs only after the snapshot transaction has committed, as
    /// its own statement, and it never throws:
    ///   * the series is derived data, so a failure here must not fail, retry or delay the day's scoring;
    ///   * it must stay out of the snapshot transaction: that one holds the job-row and scoring-inputs locks
    ///     uploads already deadlock against (docs/BACKEND.md, known issues), and lengthening it makes it worse;
    ///   * every pass recomputes the whole day, so a write that is missed is repaired by the next one.
    /// The database accepts the write only for the day's canonical device (`selected_scoring_device_v2`) and
    /// leaves unchanged buckets untouched. That choice is made on the SCORING algorithm's jobs and snapshots, so
    /// `scoringVersion` is the claimed job's version; the series' own version travels inside the payload.
    /// Classify the `publish_metric_series_v1` reply (pure, unit-tested):
    ///   - `.applied`   — the write happened (`upserted` + `deleted` rows);
    ///   - `.superseded` — the fence rejected the write because a NEWER input
    ///     revision owns the day (T31). Never success, never failure;
    ///   - `.skipped`   — not the day's selected device, or an unparseable reply
    ///     (derived side channel; the next scoring pass repairs it);
    ///   - `.malformed` — the RPC replied with something that is not an object.
    enum SeriesPublishOutcome: Equatable {
        case applied(upserted: Int, deleted: Int)
        case superseded
        case skipped
        case malformed
    }
    static func classifySeriesOutcome(_ replyText: String?) -> SeriesPublishOutcome {
        guard let replyText, !replyText.isEmpty, replyText != "null",
              let data = replyText.data(using: .utf8),
              let outcome = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed
        }
        guard (outcome["applied"] as? Bool) == true else {
            if (outcome["reason"] as? String) == "superseded" { return .superseded }
            return .skipped
        }
        return .applied(upserted: outcome["upserted"] as? Int ?? 0, deleted: outcome["deleted"] as? Int ?? 0)
    }

    /// Write the day's dense intraday series. It runs only after the snapshot transaction has committed, as
    /// its own statement, and it never throws:
    ///   * the series is derived data, so a failure here must not fail, retry or delay the day's scoring;
    ///   * it must stay out of the snapshot transaction: that one holds the job-row and scoring-inputs locks
    ///     uploads already deadlock against (docs/BACKEND.md, known issues), and lengthening it makes it worse;
    ///   * every pass recomputes the whole day, so a write that is missed is repaired by the next one.
    /// The database accepts the write only for the day's canonical device (`selected_scoring_device_v2`) and
    /// only at the input revision this pass CLAIMED (`claim.inputRevision`); a write whose claimed revision is
    /// older than the day's latest one is fenced as superseded and counted separately, never as a failure.
    /// That choice is made on the SCORING algorithm's jobs and snapshots, so `scoringVersion` is the claimed
    /// job's version; the series' own version travels inside the payload.
    private mutating func publishSeries(_ series: [String: Any]?, claim: DayScorer.Claim, scoringVersion: String) {
        guard let series else { return }
        do {
            let reply = try db.callFunctionForJSON(
                ScoringLane.seriesPublishSQL,
                [claim.userId, claim.deviceId, claim.day, scoringVersion, try jsonText(series), String(claim.inputRevision)])
            switch Self.classifySeriesOutcome(reply) {
            case .applied(let upserted, let deleted):
                stats.seriesPublished += 1
                stats.seriesRowsWritten += upserted + deleted
            case .superseded:
                stats.seriesSuperseded += 1
            case .skipped, .malformed:
                stats.seriesSkipped += 1
            }
        } catch {
            stats.seriesFailed += 1
            FileHandle.standardError.write(
                "frwhoop-worker: series publish failed day=\(claim.day) device=\(claim.deviceId.prefix(8)): \(error)\n"
                    .data(using: .utf8)!)
        }
    }

    /// Write the day's compact versioned attestation (day_completeness) after a
    /// successful snapshot publish. Derived bookkeeping, so it never throws and
    /// never fails, retries or delays the day's scoring. The RPC is fenced on
    /// input_revision: an older pass cannot overwrite a newer day's attestation,
    /// and a fenced write is counted as superseded, never as success or failure.
    private mutating func publishAttestation(_ snapshot: [String: Any], claim: DayScorer.Claim,
                                             scoringVersion: String, resultRevision: Int64) {
        let attestation = DayScorer.dayAttestation(claim: claim, snapshot: snapshot,
                                                   resultRevision: resultRevision,
                                                   algorithmVersion: scoringVersion)
        do {
            let reply = try db.callFunctionForJSON(
                ScoringLane.dayAttestationSQL,
                [claim.userId, claim.deviceId, claim.day, String(claim.inputRevision),
                 claim.timezoneId, try jsonText(attestation)])
            switch Self.classifySeriesOutcome(reply) {
            case .applied:
                stats.attestationWritten += 1
            case .superseded:
                stats.attestationSuperseded += 1
            case .skipped, .malformed:
                stats.attestationSkipped += 1
            }
        } catch {
            stats.attestationFailed += 1
            FileHandle.standardError.write(
                "frwhoop-worker: day attestation failed day=\(claim.day) device=\(claim.deviceId.prefix(8)): \(error)\n"
                    .data(using: .utf8)!)
        }
    }

    /// Bounded zone-aware midnight-closure sweep (G2-attestation item 3 / spec 4.5),
    /// throttled to at most one per `dayClosureSweepIntervalSeconds`. The due-days
    /// computation, the v2 enqueue and the pending marker are all inside the SQL
    /// RPC (one transaction, idempotent), so this hook is a single cheap statement
    /// on the existing poll loop — never new cron infrastructure. Failures are
    /// counted and logged; a failed sweep never fails a scoring cycle.
    static let dayClosureSweepSQL = """
        select public.scoring_enqueue_due_day_closure($1::integer, $2::text, $3::integer)::text as n
        """
    private mutating func maybeSweepDayClosure() {
        guard dayClosureSweepIntervalSeconds > 0 else { return }
        let now = Date()
        if let last = lastDayClosureSweep,
           now.timeIntervalSince(last) < TimeInterval(dayClosureSweepIntervalSeconds) {
            return
        }
        lastDayClosureSweep = now
        do {
            let rows = try db.query(ScoringLane.dayClosureSweepSQL,
                                    [String(dayClosureBatch), v2AlgorithmVersion, String(dayClosureSettleSeconds)])
            let n = Int(rows.first?["n"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            if n > 0 { stats.dayClosureEnqueued += n }
        } catch {
            stats.dayClosureFailed += 1
            FileHandle.standardError.write(
                "frwhoop-worker: day closure sweep failed: \(error)\n".data(using: .utf8)!)
        }
    }

    /// `scoring_jobs_v2` carries no timezone. Resolve the claim's zone in order:
    /// legacy work item, physiology work item, then the owner's PROFILE timezone
    /// (the app's phone-local zone authority, contract C2), then UTC (always a
    /// valid `pg_timezone_names` entry, which the snapshot contract requires).
    /// The profile fallback matters for QUIET days created by the closure sweep:
    /// they have no work item, so without it their attestation would use UTC day
    /// bounds even though the closure computed the day in the owner's zone. A
    /// profile zone that is not in `pg_timezone_names` (garbage/legacy) falls
    /// back to UTC rather than failing the snapshot's timezone validation.
    static let resolveTimezoneSQL = """
        select coalesce(
            (select timezone_id from public.scoring_work_items
              where user_id=$1::uuid and device_id=$2::uuid and day=$3::date),
            (select timezone_id from public.physiology_work_items
              where user_id=$1::uuid and device_id=$2::uuid and day=$3::date),
            (select case when exists (select 1 from pg_timezone_names n
                                        where n.name = nullif(btrim(p.timezone), ''))
                         then nullif(btrim(p.timezone), '') end
               from public.profiles p where p.id=$1::uuid),
            'UTC') as tz
        """
    private func resolveTimezone(userId: String, deviceId: String, day: String) throws -> String {
        let rows = try db.query(ScoringLane.resolveTimezoneSQL, [userId, deviceId, day])
        let tz = rows.first?["tz"] ?? ""
        return tz.isEmpty ? "UTC" : tz
    }

    /// Release a v2 lease whose publication did not complete. There is no bare
    /// release RPC, so this uses the deployed pair:
    ///   * `renew_scoring_v2` tells us whether the lease is still ours and alive;
    ///   * `fail_scoring_v2` releases it. Passing the row's CURRENT input_revision
    ///     makes the function count one failure only when the revision is
    ///     unchanged (an honest, bounded retry with backoff and dead-letter at 8);
    ///     when the revision moved it resets the counters, which is the clean
    ///     release this path wants.
    private func releaseV2Lease(token: String, claimedRevision: String, algorithmVersion: String) throws {
        let renewed = isTrue(try db.callFunctionForJSON(
            "SELECT public.renew_scoring_v2($1::uuid, $2::integer)::text",
            [token, String(leaseSeconds)]))
        guard renewed else { return }
        let rows = try db.query(
            "select input_revision::text as rev from public.scoring_jobs_v2 where lease_token=$1::uuid",
            [token])
        guard let current = rows.first?["rev"], !current.isEmpty else { return }
        _ = try db.callFunctionForJSON(
            "SELECT public.fail_scoring_v2($1::uuid, $2::bigint, $3::text)::text",
            [token, current, "v2_publish_not_completed:claimed_revision=\(claimedRevision),algorithm=\(algorithmVersion)"])
    }
}

/// Postgres renders a boolean as `true`/`false`; `t`/`f` also appear when a value
/// is read back through some drivers. Accept both rather than silently treating
/// `false` as success.
func isTrue(_ text: String?) -> Bool {
    switch (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "t", "1": return true
    default: return false
    }
}

/// Capped exponential backoff with jitter, for races that are expected to resolve.
func jitterSleep(attempt: Int) {
    let base = min(2.0, 0.05 * pow(2.0, Double(max(0, attempt - 1))))
    let jittered = base * Double.random(in: 0.5...1.5)
    Thread.sleep(forTimeInterval: jittered)
}

func jsonText(_ obj: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    guard let s = String(data: data, encoding: .utf8) else {
        throw WorkerError.malformed("payload encoding failed")
    }
    return s
}

// MARK: - Candidate input re-assembly (pending work for a day not being scored)

/// `CandidateInputAssembling` over `DayScorer`'s own assembly. The day is loaded and analysed
/// read-only in its own REPEATABLE READ transaction, which is always rolled back: nothing is
/// published, no series or attestation is built, and the sleep-feature sidecar is not called.
/// It runs only with no scoring transaction open (after a publish committed, or on an idle
/// drain), and at most `CandidateStage.reassemblyBudget` times per drain.
struct ScoringCandidateAssembler: CandidateInputAssembling {
    let db: PostgresClient
    let scorer: DayScorer

    func assemble(userId: String, deviceId: String, day: String,
                  inputRevision: Int64) throws -> CandidateAssembly {
        try db.beginTransaction(.repeatableRead)
        defer { db.rollbackTransaction() }
        let rows = try db.query(ScoringLane.resolveTimezoneSQL, [userId, deviceId, day])
        let tz = (rows.first?["tz"]).flatMap { $0.isEmpty ? nil : $0 } ?? "UTC"
        let claim = DayScorer.Claim(userId: userId, deviceId: deviceId, day: day, timezoneId: tz,
                                    inputRevision: inputRevision, leaseToken: "", runId: "",
                                    measurementRevision: 0)
        let scored = try scorer.scoreAndBuildPayloads(claim: claim, buildSeries: false,
                                                      candidateLane: true, enrichFeatures: false)
        return CandidateAssembly(inputs: scored.candidates, timezoneId: tz)
    }
}
