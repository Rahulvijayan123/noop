import XCTest
import WhoopProtocol
@testable import frwhoop_worker

/// The persisted candidate scheduler against a real Postgres: `PostgresCandidatePendingStore` and
/// `PostgresCandidateStore` calling the SQL of `20261002090000_physiology_candidate_providers.sql`
/// and `20261008110000_physiology_candidate_pending.sql`, with a 127.0.0.1 stub sidecar.
///
/// Needs a scratch Postgres with the candidate lane's prerequisite migrations and both files
/// applied, and an empty pending queue (the claim is fleet-wide): set FRWHOOP_TEST_DB_URL (skipped
/// otherwise). Every test makes its own user and device and deletes them afterwards.
final class CandidatePendingDatabaseTests: XCTestCase {

    private let day = "2026-09-20"

    private struct Fixture {
        let db: PostgresClient
        let user: String
        let device: String
    }

    private func makeFixture() throws -> Fixture {
        guard let url = ProcessInfo.processInfo.environment["FRWHOOP_TEST_DB_URL"], !url.isEmpty else {
            throw XCTSkip("set FRWHOOP_TEST_DB_URL to a scratch Postgres with 20261008110000 applied")
        }
        let db = try PostgresClient(options: PostgresOptions(
            connectionString: url, sslMode: "disable", sslRootCert: nil,
            applicationName: "frwhoop-worker-tests", allowInsecure: true,
            connectTimeoutSeconds: 5, reconnectDeadlineSeconds: 5,
            statementTimeoutMS: 60_000, idleTransactionTimeoutMS: 60_000))
        guard PostgresCandidatePendingStore(db: db).isAvailable() else {
            throw XCTSkip("apply 20261008110000_physiology_candidate_pending.sql to the scratch database")
        }
        let others = try db.query("select count(*)::text as n from public.physiology_candidate_pending", [])
        guard others.first?["n"] == "0" else {
            throw XCTSkip("the scratch database holds other pending candidate rows; use a clean one")
        }
        let user = UUID().uuidString.lowercased()
        let device = UUID().uuidString.lowercased()
        try db.exec("insert into auth.users(id) values ('\(user)')")
        try db.exec("insert into public.devices(id,user_id,source_kind) values ('\(device)','\(user)','noop_push')")
        for metric in CandidateStage.metrics {
            try db.exec("""
                insert into public.physiology_provider_overrides(user_id,metric,provider_id,provider_version,
                  config_version,mode) values ('\(user)','\(metric)','prov.v1','1.0.0','cfg-1','shadow')
                """)
        }
        addTeardownBlock {
            db.rollbackTransaction()
            try? db.exec("delete from auth.users where id = '\(user)'")
        }
        return Fixture(db: db, user: user, device: device)
    }

    /// The day's scoring input revision, which both the record RPC and the queue fence on.
    private func setRevision(_ f: Fixture, _ revision: Int64) throws {
        try f.db.exec("""
            insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision)
            values ('\(f.user)','\(f.device)','\(day)','frwhoop-server-1',\(revision))
            on conflict (user_id,device_id,day,algorithm_version) do update set input_revision=excluded.input_revision
            """)
    }

    private func inputs(_ f: Fixture, revision: Int64) -> DayScorer.CandidateInputs {
        let base = CandidatePendingSchedulerTests.inputs(day: day, revision: revision)
        return DayScorer.CandidateInputs(
            userId: f.user, deviceId: f.device, day: day, inputRevision: revision,
            intervalStart: base.intervalStart, intervalEnd: base.intervalEnd,
            claimSealedAt: Date(), status: base.status,
            canonicalAvgHrv: base.canonicalAvgHrv, canonicalSdnn: base.canonicalSdnn,
            profileVersion: base.profileVersion, correctionsVersion: base.correctionsVersion,
            enabledMetrics: base.enabledMetrics, assembled: true,
            hrvBeats: base.hrvBeats, hrvInputRows: base.hrvInputRows,
            hrvTimestampResolution: base.hrvTimestampResolution,
            hrSamples: base.hrSamples, rrRows: base.rrRows,
            sleepWindowStart: base.sleepWindowStart, sleepWindowEnd: base.sleepWindowEnd,
            sleepEdits: [], age: base.age, gender: base.gender)
    }

    private func claim(_ f: Fixture, revision: Int64) -> DayScorer.Claim {
        DayScorer.Claim(userId: f.user, deviceId: f.device, day: day, timezoneId: "UTC",
                        inputRevision: revision, leaseToken: UUID().uuidString.lowercased(),
                        runId: UUID().uuidString.lowercased(), measurementRevision: 0)
    }

    private func pendingRows(_ f: Fixture) throws -> [String: [String: String]] {
        let rows = try f.db.query("""
            select metric, state, coalesce(last_reason,'') as reason, attempts::text as attempts,
                   input_revision::text as rev
              from public.physiology_candidate_pending where user_id=$1::uuid
            """, [f.user])
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["metric"] ?? "", $0) })
    }

    /// Four enabled metrics, budget 1, the day re-scored before every drain: every metric with an
    /// input gets a real candidate row, respiration (no input assembly) settles withheld
    /// `no_input`, and no budget skip is ever settled as done.
    func testBudgetOfOneReachesEveryMetricThroughTheRealQueue() throws {
        let f = try makeFixture()
        let server = CandidatePendingSchedulerTests.echoServer()
        defer { server.stop() }
        let client = InferenceClient(baseURL: URL(string: server.baseURL)!, timeoutMS: 5_000)
        var stage = CandidateStage(client: client, store: PostgresCandidateStore(db: f.db),
                                   pending: PostgresCandidatePendingStore(db: f.db))
        stage.maxDrainSeconds = 20
        for drain in 1...4 {
            let revision = Int64(drain)
            try setRevision(f, revision)
            stage.beginDrain(budget: 1)
            stage.run(claim: claim(f, revision: revision), inputs: inputs(f, revision: revision))
        }
        if let error = stage.stats.lastError {
            XCTAssertFalse(error.contains("pending"), "a pending-store call failed: \(error)")
        }
        let recorded = try f.db.query(
            "select distinct metric from public.physiology_candidate_results where user_id=$1::uuid", [f.user])
        XCTAssertEqual(Set(recorded.compactMap { $0["metric"] }), ["hrv", "sleep_boundary", "sleep_stage"])
        let rows = try pendingRows(f)
        XCTAssertEqual(rows["respiration"]?["state"], "withheld")
        XCTAssertEqual(rows["respiration"]?["reason"], "no_input")
        XCTAssertGreaterThan(stage.stats.skippedBudget, 0)
        XCTAssertEqual(stage.stats.pendingDone, stage.stats.recorded + stage.stats.duplicates)
        let budgetDone = try f.db.query("""
            select count(*)::text as n from public.physiology_candidate_pending
             where user_id=$1::uuid and state='done' and last_reason='budget'
            """, [f.user])
        XCTAssertEqual(budgetDone.first?["n"], "0")

        // Heartbeat stats parse from the real function.
        stage.refreshPendingStats()
        let queue = try XCTUnwrap(stage.stats.pendingQueue)
        XCTAssertEqual(queue.pending, rows.values.filter { $0["state"] == "pending" }.count)
        XCTAssertEqual(stage.schedulingMode, "persisted")
    }

    /// Direct store calls: the claim item parses, a stale revision and a lost lease are refused.
    func testStaleRevisionAndLostLeaseAreRefusedByTheRealSettle() throws {
        let f = try makeFixture()
        let store = PostgresCandidatePendingStore(db: f.db)
        let entry = CandidatePendingEntry(metric: "sleep_stage", providerId: "prov.v1", providerVersion: "1.0.0",
                                          configVersion: "cfg-1", requestedMode: "shadow", hasInput: true)
        try setRevision(f, 1)
        XCTAssertEqual(try store.enqueue(userId: f.user, deviceId: f.device, day: day, inputRevision: 1,
                                         entries: [entry]), 1)
        XCTAssertEqual(try store.enqueue(userId: f.user, deviceId: f.device, day: day, inputRevision: 1,
                                         entries: [entry]), 0, "idempotent")
        XCTAssertEqual(try store.currentRevision(userId: f.user, deviceId: f.device, day: day), 1)

        let first = try XCTUnwrap(try store.claim(owner: "test-worker", leaseSeconds: 60))
        XCTAssertEqual(first.userId, f.user)
        XCTAssertEqual(first.day, day)
        XCTAssertEqual(first.metric, "sleep_stage")
        XCTAssertEqual(first.inputRevision, 1)
        XCTAssertNil(try store.claim(owner: "test-worker", leaseSeconds: 60), "a live lease is not handed out twice")

        // Re-scored at revision 2 while the first run computes.
        try setRevision(f, 2)
        XCTAssertEqual(try store.enqueue(userId: f.user, deviceId: f.device, day: day, inputRevision: 2,
                                         entries: [entry]), 1)
        XCTAssertFalse(try store.settle(first, .done(reason: "recorded", candidateId: nil), maxAttempts: 4),
                       "a stale run cannot settle")
        XCTAssertEqual(try pendingRows(f)["sleep_stage"]?["rev"], "2")
        XCTAssertEqual(try pendingRows(f)["sleep_stage"]?["state"], "pending")

        // Lost lease: claim at revision 2, let the lease lapse, then settle.
        let second = try XCTUnwrap(try store.claim(owner: "test-worker", leaseSeconds: 60))
        XCTAssertEqual(second.inputRevision, 2)
        try f.db.exec("""
            update public.physiology_candidate_pending set lease_until=clock_timestamp()-interval '1 second'
             where user_id='\(f.user)'
            """)
        XCTAssertFalse(try store.settle(second, .done(reason: "recorded", candidateId: nil), maxAttempts: 4),
                       "an expired lease cannot settle")
        let third = try XCTUnwrap(try store.claim(owner: "test-worker", leaseSeconds: 60))
        XCTAssertEqual(third.attempts, 1, "the abandoned run counts")
        XCTAssertEqual(third.lastReason, "lease_expired")
        XCTAssertTrue(try store.settle(third, .retry(reason: "busy", countAttempt: false, retryAfterSeconds: 0),
                                       maxAttempts: 4))
        XCTAssertEqual(try pendingRows(f)["sleep_stage"]?["reason"], "busy")
        XCTAssertEqual(try pendingRows(f)["sleep_stage"]?["attempts"], "1", "busy is not an attempt")

        let stats = try store.stats()
        XCTAssertEqual(stats.pending, 1)
        XCTAssertEqual(stats.byReason["busy"], 1)
        XCTAssertEqual(stats.byMetric["sleep_stage"], 1)
    }
}
