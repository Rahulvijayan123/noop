
import Foundation

/// Lane 3: day scoring (fenced snapshot contract).
///
/// One day = one REPEATABLE READ transaction: `scoring_legacy_claim_one`
/// records the txid; inputs load through the same snapshot; 
/// `scoring_legacy_seal_snapshot` stamps the capture; the computed result
/// publishes through `engine_publish_legacy_fenced` (upserts
/// `server_daily_scores` + `server_sleep_nights`, snapshots into
/// `server_physiology_results`, queues the derived archive); the lease
/// finishes with `scoring_legacy_finish_work`.
///
/// The v2 queue (`claim_scoring_v2` + `publish_scoring_snapshot_v2`) publishes
/// the same computed result through the snapshot contract.
struct ScoringLane {
    let db: PostgresClient
    let scorer: DayScorer
    let ingestSecret: String

    struct Stats {
        var claimed = 0
        var completed = 0
        var failed = 0
        var lastScoreAt: Date?
        var lastError: String?
    }
    var stats = Stats()

    mutating func drain(budget: Int) {
        for _ in 0..<max(1, budget) {
            do {
                if try scoreOneFleet() {
                    stats.claimed += 1
                    stats.completed += 1
                    stats.lastScoreAt = Date()
                } else if try scoreOneV2() {
                    stats.claimed += 1
                    stats.completed += 1
                    stats.lastScoreAt = Date()
                } else {
                    return
                }
            } catch {
                stats.failed += 1
                stats.lastError = String(describing: error)
                return
            }
        }
    }

    /// Path A (legacy fleet queue). Returns true when one work item was fully processed.
    private mutating func scoreOneFleet() throws -> Bool {
        let cycle = try db.withRepeatableRead { () throws -> Bool in
            guard let claim = try legacyClaim() else { return false }
            let started = Date()
            do {
                // Inputs load through the same repeatable-read snapshot the
                // claim recorded; the seal stamps it as captured.
                let payloads = try scorer.scoreAndBuildPayloads(claim: claim)
                try seal(claim: claim)
                let legacyData = try jsonText(payloads.legacy)
                try db.exec("SELECT set_config('request.jwt.claims', '{\"role\":\"service_role\"}', true)")
                _ = try db.callFunctionForJSONRaw(
                    "SELECT public.engine_publish_legacy_fenced($1::text, $2::jsonb)::text",
                    [ingestSecret, legacyData])
                let durationMS = Int(Date().timeIntervalSince(started) * 1000)
                _ = try db.callFunctionForJSONRaw(
                    "SELECT public.scoring_legacy_finish_work($1::uuid,$2::uuid,$3::date,$4::bigint,$5::uuid,$6::uuid,'done',$7::integer,NULL)::text",
                    [claim.userId, claim.deviceId, claim.day, String(claim.inputRevision),
                     claim.leaseToken, claim.runId, String(durationMS)])
                return true
            } catch {
                let message = String(describing: error).prefix(2000)
                _ = try? db.callFunctionForJSONRaw(
                    "SELECT public.scoring_legacy_finish_work($1::uuid,$2::uuid,$3::date,$4::bigint,$5::uuid,$6::uuid,'failed',NULL,$7::text)::text",
                    [claim.userId, claim.deviceId, claim.day, String(claim.inputRevision),
                     claim.leaseToken, claim.runId, String(message)])
                throw error
            }
        }
        return cycle
    }

    private func legacyClaim() throws -> DayScorer.Claim? {
        let rows = try db.query("select * from public.scoring_legacy_claim_one(300, 8)", [])
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

    private func seal(claim: DayScorer.Claim) throws {
        try db.exec("""
        SELECT public.scoring_legacy_seal_snapshot(
            '\(claim.userId)'::uuid, '\(claim.deviceId)'::uuid, '\(claim.day)'::date,
            \(claim.inputRevision), '\(claim.leaseToken)'::uuid, '\(claim.runId)'::uuid)
        """)
    }

    /// Path B (v2 snapshot queue). Returns true when one job was processed.
    private mutating func scoreOneV2() throws -> Bool {
        // The v2 publish path runs in its own transaction (no txid fence).
        let rows = try db.query("select * from public.claim_scoring_v2('frwhoop-server-1', 300)", [])
        guard let r = rows.first else { return false }
        let uid = r["user_id"] ?? ""
        let dev = r["device_id"] ?? ""
        let day = r["day"] ?? ""
        let revText = r["input_revision"] ?? ""
        let tok = r["lease_token"] ?? ""
        guard !uid.isEmpty, !dev.isEmpty, !day.isEmpty, !revText.isEmpty, !tok.isEmpty else {
            return false
        }
        let tzRows = try db.query("""
            select coalesce(timezone_id,'UTC') tz from public.physiology_work_items
            where user_id=$1::uuid and device_id=$2::uuid and day=$3::date limit 1
            """, [uid, dev, day])
        let tzRow = tzRows.first?["tz"] ?? ""
        let tz = tzRow.isEmpty ? "UTC" : tzRow
        let runId = UUID().uuidString.lowercased()
        let claim = DayScorer.Claim(
            userId: uid, deviceId: dev, day: day, timezoneId: tz,
            inputRevision: Int64(revText) ?? 0, leaseToken: tok, runId: runId,
            measurementRevision: 0
        )
        let started = Date()
        let payloads = try scorer.scoreAndBuildPayloads(claim: claim)
        let snapshotData = try jsonText(payloads.snapshot)
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)
        _ = try db.callFunctionForJSON(
            "SELECT public.publish_scoring_snapshot_v2($1::uuid,$2::bigint,$3::jsonb,$4::bigint)::text",
            [tok, revText, snapshotData, String(durationMS)])
        return true
    }
}

func jsonText(_ obj: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    guard let s = String(data: data, encoding: .utf8) else {
        throw WorkerError.malformed("payload encoding failed")
    }
    return s
}
