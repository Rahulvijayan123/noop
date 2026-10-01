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
    let scorer: DayScorer
    let ingestSecret: String
    var leaseSeconds: Int = 300
    var maxFailures: Int = 8
    /// Publish attempts before a serialization/stale race is given up on.
    var publishAttempts: Int = 3
    var v2AlgorithmVersion: String = "frwhoop-server-1"

    struct Stats {
        var claimed = 0
        var completed = 0
        var failed = 0
        /// Claims the queue had already moved past (a newer revision, or another
        /// worker won). Nothing was published and no failure was recorded.
        var superseded = 0
        /// v2 publications that returned NULL (not complete).
        var notCompleted = 0
        /// `scoring_legacy_finish_work(...,'failed',...)` returned true: the
        /// failure is durably accounted for.
        var failuresPersisted = 0
        /// The failure could not be settled (unreachable database, or the lease
        /// moved on). The lease expiry recovers the row.
        var failuresUnsettled = 0
        var failureKinds: [String: Int] = [:]
        var lastScoreAt: Date?
        var lastError: String?
        var lastErrorKind: PGErrorKind?
    }
    var stats = Stats()

    /// Consecutive cycles that ended in an unsettled failure; the lane stops
    /// after `maxFailures` so a systemic fault cannot spin.
    var consecutiveFailures = 0

    mutating func drain(budget: Int) {
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
                    return
                case .completed:
                    consecutiveFailures = 0
                    stats.claimed += 1
                    stats.completed += 1
                    stats.lastScoreAt = Date()
                case .superseded:
                    consecutiveFailures = 0
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

    // MARK: - Path A (legacy fleet queue)

    /// Claim one work item and seal its input snapshot, committed on its own so a
    /// later failure can still be settled through the fenced contract.
    private func claimAndSealFleet() throws -> DayScorer.Claim? {
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

    private func legacyClaim() throws -> DayScorer.Claim? {
        let rows = try db.query(
            "select * from public.scoring_legacy_claim_one($1::integer, $2::integer)",
            [String(leaseSeconds), String(maxFailures)])
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
                let finished = try publishAndFinishFleet(claim, started: started)
                return finished ? .completed : .superseded
            } catch {
                let kind = (error as? PostgresClient.Error)?.kind ?? .other
                if kind == .serialization || kind == .stale {
                    // A concurrent writer won the race. Retry with jitter; if it
                    // keeps losing, the queue already owns the newer revision, so
                    // do NOT record a failure against this day.
                    if attempt < publishAttempts {
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

    /// Returns true when the queue accepted the completion. False means the claim
    /// was superseded, in which case the transaction is rolled back so nothing is
    /// published for a claim the queue no longer owns.
    private func publishAndFinishFleet(_ claim: DayScorer.Claim, started: Date) throws -> Bool {
        try db.beginTransaction(.repeatableRead)
        do {
            let payloads = try scorer.scoreAndBuildPayloads(claim: claim)
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
            return finished
        } catch {
            db.rollbackTransaction()
            throw error
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
            let payloads = try scorer.scoreAndBuildPayloads(claim: claim)
            let snapshotData = try jsonText(payloads.snapshot)
            let durationMS = Int(Date().timeIntervalSince(started) * 1000)
            let publishJSON = try db.callFunctionForJSONRaw(
                "SELECT public.publish_scoring_snapshot_v2($1::uuid,$2::bigint,$3::jsonb,$4::bigint)::text",
                [tok, revText, snapshotData, String(durationMS)])
            let revision = Int64(publishJSON ?? "")
            if let revision, revision > 0 {
                try db.commitTransaction()
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

    /// `scoring_jobs_v2` carries no timezone. Prefer the legacy work item for the
    /// same (user, device, day), then the physiology work item, then UTC (always a
    /// valid `pg_timezone_names` entry, which the snapshot contract requires).
    private func resolveTimezone(userId: String, deviceId: String, day: String) throws -> String {
        let rows = try db.query("""
            select coalesce(
                (select timezone_id from public.scoring_work_items
                  where user_id=$1::uuid and device_id=$2::uuid and day=$3::date),
                (select timezone_id from public.physiology_work_items
                  where user_id=$1::uuid and device_id=$2::uuid and day=$3::date),
                'UTC') as tz
            """, [userId, deviceId, day])
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
