import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// Stream days against a real Postgres: completed scoring work → `enqueue_activity_stream_days` → the
/// lane's claim → the decoder on the stored measurements → `complete_activity_stream_day` → the read
/// surface a downstream job queries. No Python and no B2: this path needs neither, which is the point.
///
/// Needs a scratch Postgres with the activity migrations applied, the third one included
/// (`20261003140000_activity_context_stream_days.sql`): set FRWHOOP_TEST_DB_URL, e.g.
/// `postgresql://user@localhost:5432/scratch` (skipped otherwise). Every test makes its own user and device
/// and deletes them afterwards; deleting the user cascades to everything the test wrote. The lane claims
/// whatever stream day is due, so run against a database without other owners' pending stream jobs.
final class ActivityStreamDaysDatabaseTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture {
        let db: PostgresClient
        let user: String
        let device: String
        /// The UTC day before today: a finished day whose scoring completed, with the day after it
        /// (today) and the day before it as the neighbours the dependency rule also builds.
        let dayStart: Int
        var dayEnd: Int { dayStart + 86_400 }
        var day: String { ActivityStreamDaysDatabaseTests.dayText(dayStart) }
    }

    static func dayText(_ start: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(start)))
    }

    private func connect() throws -> PostgresClient {
        guard let url = ProcessInfo.processInfo.environment["FRWHOOP_TEST_DB_URL"], !url.isEmpty else {
            throw XCTSkip("set FRWHOOP_TEST_DB_URL to a scratch Postgres with the activity migrations applied")
        }
        return try PostgresClient(options: PostgresOptions(
            connectionString: url, sslMode: "disable", sslRootCert: nil,
            applicationName: "frwhoop-worker-tests", allowInsecure: true,
            connectTimeoutSeconds: 5, reconnectDeadlineSeconds: 5,
            statementTimeoutMS: 60_000, idleTransactionTimeoutMS: 60_000))
    }

    private func makeFixture() throws -> Fixture {
        let db = try connect()
        let present = try db.query("""
            select (to_regprocedure('public.claim_activity_stream_day(integer)') is not null
                and to_regclass('public.activity_context_runs') is not null) as present
            """, [])
        guard present.first?["present"] == "t" else {
            throw XCTSkip("apply 20261003140000_activity_context_stream_days.sql to the scratch database")
        }
        let user = UUID().uuidString.lowercased()
        let device = UUID().uuidString.lowercased()
        try db.exec("insert into auth.users(id) values ('\(user)')")
        try db.exec("insert into public.devices(id,user_id,source_kind) values ('\(device)','\(user)','noop_push')")
        addTeardownBlock {
            db.rollbackTransaction()
            try? db.exec("delete from auth.users where id = '\(user)'")
        }
        let today = Int(Date().timeIntervalSince1970) / 86_400 * 86_400
        return Fixture(db: db, user: user, device: device, dayStart: today - 86_400)
    }

    private func jsonText(_ rows: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }

    /// Stores the simulated streams (and wear events) the way the ingest path does. `since` stores only
    /// the rows from that second on (data arriving later).
    private func seed(_ f: Fixture, sim: DaySim, since: Int = Int.min,
                      events: [(ts: Int, kind: String)] = []) throws {
        let source = UUID().uuidString.lowercased()
        let ids = [f.user, f.device, source]
        _ = try f.db.query("""
            insert into public.noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
            select $1::uuid,$2::uuid,$3::uuid,(r->>'ts')::bigint,(r->>'bpm')::integer,$3::uuid
            from jsonb_array_elements($4::jsonb) r
            """, ids + [try jsonText(sim.hr.filter { $0.ts >= since }.map { ["ts": $0.ts, "bpm": $0.bpm] })])
        _ = try f.db.query("""
            insert into public.noop_gravity_samples(user_id,device_id,source_id,ts,x,y,z,"dynAccel",batch_id)
            select $1::uuid,$2::uuid,$3::uuid,(r->>'ts')::bigint,(r->>'x')::double precision,
                   (r->>'y')::double precision,(r->>'z')::double precision,(r->>'dyn')::double precision,$3::uuid
            from jsonb_array_elements($4::jsonb) r
            """, ids + [try jsonText(sim.gravity.filter { $0.ts >= since }.map {
                ["ts": $0.ts, "x": $0.x, "y": $0.y, "z": $0.z, "dyn": $0.dynAccel ?? NSNull()]
            })])
        _ = try f.db.query("""
            insert into public.noop_step_samples(user_id,device_id,source_id,ts,counter,"activityClass",batch_id)
            select $1::uuid,$2::uuid,$3::uuid,(r->>'ts')::bigint,(r->>'counter')::integer,
                   (r->>'cls')::integer,$3::uuid
            from jsonb_array_elements($4::jsonb) r
            """, ids + [try jsonText(sim.steps.filter { $0.ts >= since }.map {
                ["ts": $0.ts, "counter": $0.counter, "cls": $0.activityClass ?? NSNull()]
            })])
        if !events.isEmpty {
            _ = try f.db.query("""
                insert into public.noop_events(user_id,device_id,source_id,ts,kind,"payloadJSON",batch_id)
                select $1::uuid,$2::uuid,$3::uuid,(r->>'ts')::bigint,r->>'kind','{}',$3::uuid
                from jsonb_array_elements($4::jsonb) r
                """, ids + [try jsonText(events.map { ["ts": $0.ts, "kind": $0.kind] })])
        }
    }

    /// The scoring service finished work for the fixture's day: the signal stream days are built from.
    private func completeScoring(_ f: Fixture, revision: Int = 1) throws {
        _ = try f.db.query("""
            insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,
                                               completed_revision,last_completed_at)
            values ($1::uuid,$2::uuid,$3::date,'frwhoop-server-1',$4::bigint,$4::bigint,clock_timestamp())
            on conflict (user_id,device_id,day,algorithm_version) do update set
              input_revision = excluded.input_revision, completed_revision = excluded.completed_revision,
              last_completed_at = clock_timestamp()
            """, [f.user, f.device, f.day, String(revision)])
    }

    private func makeLane(_ db: PostgresClient) -> ActivityLane {
        ActivityLane(
            db: db,
            storage: B2Storage(keyID: "unused", applicationKey: "unused", bucket: "unused"),
            service: ActivityPythonService(config: ActivityPythonService.Config(
                pythonBin: "/nonexistent/python", activityHome: FileManager.default.currentDirectoryPath,
                modelDir: nil, serveArgs: [], requestTimeoutSeconds: 1,
                maxRequestBytes: 1_024, maxResponseLineBytes: 1_024, restartCap: 1, restartCooldownSeconds: 1)),
            leaseSeconds: 300)
    }

    private func dayDocs(_ f: Fixture) throws -> String {
        try scalar(f, "select count(*)::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid")
    }

    /// A walking stretch between two sitting ones around midday, with the strap off for a while.
    private func middayStreams(_ f: Fixture) -> (sim: DaySim, events: [(ts: Int, kind: String)], walkStart: Int) {
        var sim = DaySim(start: f.dayStart + 12 * 3_600)
        sim.still(240)
        let walkStart = sim.ts
        sim.walk(150)
        sim.still(240)
        sim.gap(600)
        sim.still(120)
        let events = [(ts: f.dayStart + 12 * 3_600 + 630, kind: "WRIST_OFF(10)"),
                      (ts: f.dayStart + 12 * 3_600 + 1_230, kind: "WRIST_ON(11)")]
        return (sim, events, walkStart)
    }

    private func scalar(_ f: Fixture, _ sql: String) throws -> String {
        try f.db.query(sql, [f.user, f.device]).first?.values.first ?? ""
    }

    private func streamJobs(_ f: Fixture) throws -> [[String: String]] {
        try f.db.query("""
            select day::text as day, input_revision::text as rev, completed_revision::text as done,
                   (lease_token is null)::text as free, consecutive_failures::text as failures
            from public.activity_context_jobs
            where user_id=$1::uuid and device_id=$2::uuid and algorithm_version='streams-activity-1'
            order by day
            """, [f.user, f.device])
    }

    // MARK: - The happy path

    func testAStoredDayBecomesAStreamDocumentWithoutPythonOrStorage() throws {
        let f = try makeFixture()
        let (sim, events, walkStart) = middayStreams(f)
        try seed(f, sim: sim, events: events)
        try completeScoring(f)
        let scoringWorkBefore = try scalar(f, "select count(*)::text from public.scoring_work_items where user_id=$1::uuid and device_id=$2::uuid")
        var lane = makeLane(f.db)

        lane.drainStreamDays(budget: 20)

        // Three UTC days depend on the one scoring day; only the one with measurements gets a document.
        let jobs = try streamJobs(f)
        XCTAssertEqual(jobs.count, 3, "\(jobs)")
        XCTAssertTrue(jobs.allSatisfy { $0["done"] == $0["rev"] && $0["free"] == "true" && $0["failures"] == "0" }, "\(jobs)")
        XCTAssertGreaterThanOrEqual(lane.stats.streamDaysEnqueued, 3)
        XCTAssertGreaterThanOrEqual(lane.stats.streamDaysPublished, 1)
        XCTAssertGreaterThanOrEqual(lane.stats.streamDaysEmpty, 2)
        XCTAssertEqual(lane.stats.streamDayFailures, 0, lane.stats.lastStreamDayError ?? "")
        XCTAssertNil(lane.stats.lastStreamDayError)

        let docs = try f.db.query("""
            select day::text as day, algorithm_version, encoder_id, model_version, preprocessing_version,
                   run_count::text as run_count, event_count::text as event_count, observed_s::text as observed_s,
                   (document ? 'snapshot')::text as has_snapshot, job_fingerprint
            from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device])
        XCTAssertEqual(docs.count, 1, "the neighbouring days hold no measurements: \(docs)")
        let doc = try XCTUnwrap(docs.first)
        XCTAssertEqual(doc["day"], f.day)
        XCTAssertEqual(doc["algorithm_version"], ActivityContextDays.streamsAlgorithmVersion)
        XCTAssertEqual(doc["encoder_id"], "", "no encoder ran")
        XCTAssertEqual(doc["model_version"], ActivityContextDays.streamsModelVersion)
        XCTAssertEqual(doc["preprocessing_version"], ActivityContextDays.streamsPreprocessingVersion)
        XCTAssertGreaterThan(Int(doc["run_count"] ?? "") ?? 0, 0)
        XCTAssertGreaterThan(Int(doc["observed_s"] ?? "") ?? 0, 0)
        XCTAssertEqual(doc["has_snapshot"], "false")

        // Nothing else was written: no v1 epochs, and the scorer's work queue is as it was.
        XCTAssertEqual(try scalar(f, "select count(*)::text from public.activity_context_epochs where user_id=$1::uuid and device_id=$2::uuid"), "0")
        XCTAssertEqual(try scalar(f, "select count(*)::text from public.scoring_work_items where user_id=$1::uuid and device_id=$2::uuid"),
                       scoringWorkBefore, "publishing a stream day must not invalidate any scoring")

        // The read surface: exact seconds, labels and confidence, one row per run.
        let rows = try f.db.query("""
            select start_ts::text as s, end_ts::text as e, display_context, confidence::text as confidence,
                   uncertainty::text as uncertainty, wear_state, sleep_state, source_rank::text as rank
            from public.activity_context_runs where user_id=$1::uuid and device_id=$2::uuid order by start_ts
            """, [f.user, f.device])
        XCTAssertEqual(rows.count, Int(doc["run_count"] ?? ""))
        var previousEnd = f.dayStart
        for row in rows {
            let s = try XCTUnwrap(Int(row["s"] ?? "")), e = try XCTUnwrap(Int(row["e"] ?? ""))
            XCTAssertGreaterThanOrEqual(s, previousEnd, "runs must not overlap")
            XCTAssertGreaterThan(e, s)
            XCTAssertLessThanOrEqual(e, f.dayEnd)
            previousEnd = e
            let confidence = try XCTUnwrap(Double(row["confidence"] ?? ""))
            XCTAssertTrue((0...1).contains(confidence))
            XCTAssertEqual(row["rank"], "2")
        }
        let labels = Set(rows.compactMap { $0["display_context"] }.filter { !$0.isEmpty })
        XCTAssertTrue(labels.contains("Walking") || labels.contains("Brisk walking"), "\(labels)")
        XCTAssertTrue(labels.contains("Off wrist"), "the WRIST_OFF/WRIST_ON pair must reach the decoder: \(labels)")

        // Asking what the user was doing at a stored measurement's exact second.
        let midWalk = walkStart + 75
        let at = try f.db.query("""
            select display_context, algorithm_version, start_ts::text as s, end_ts::text as e
            from public.activity_context_at($1::uuid,$2::uuid,$3::bigint)
            """, [f.user, f.device, String(midWalk)])
        XCTAssertEqual(at.count, 1)
        XCTAssertTrue(["Walking", "Brisk walking"].contains(at.first?["display_context"] ?? ""), "\(at)")
        XCTAssertLessThanOrEqual(Int(at.first?["s"] ?? "") ?? .max, midWalk)
        XCTAssertGreaterThan(Int(at.first?["e"] ?? "") ?? .min, midWalk)

        // And labelling every stored heart-rate sample by joining on its timestamp.
        let labelled = try f.db.query("""
            select count(*)::text as total, count(r.display_context)::text as labelled
            from public.noop_hr_samples h
            left join public.activity_context_runs r
              on r.user_id = h.user_id and r.device_id = h.device_id
             and r.day = (to_timestamp(h.ts) at time zone 'UTC')::date and h.ts >= r.start_ts and h.ts < r.end_ts
            where h.user_id=$1::uuid and h.device_id=$2::uuid
            """, [f.user, f.device])
        let total = Double(labelled.first?["total"] ?? "") ?? 0
        let covered = Double(labelled.first?["labelled"] ?? "") ?? -1
        XCTAssertEqual(Int(total), sim.hr.count)
        XCTAssertGreaterThan(covered / max(total, 1), 0.9, "nearly every stored measurement has a state: \(labelled)")

        let transitions = try f.db.query("""
            select ts::text as ts, kind, probability::text as probability
            from public.activity_context_transitions where user_id=$1::uuid and device_id=$2::uuid order by ts
            """, [f.user, f.device])
        XCTAssertEqual(transitions.count, Int(doc["event_count"] ?? ""))
        for t in transitions {
            let ts = try XCTUnwrap(Int(t["ts"] ?? ""))
            XCTAssertTrue((f.dayStart...f.dayEnd).contains(ts))
            XCTAssertTrue((0...1).contains(try XCTUnwrap(Double(t["probability"] ?? ""))))
        }
    }

    func testAnUnchangedDayIsNotRebuiltAndNewScoringWorkRefreshesIt() throws {
        let f = try makeFixture()
        let (sim, events, _) = middayStreams(f)
        try seed(f, sim: sim, events: events)
        try completeScoring(f)
        var lane = makeLane(f.db)
        lane.drainStreamDays(budget: 20)
        let first = try scalar(f, "select result_revision::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid")
        let firstObserved = Int(try scalar(f, "select observed_s::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid")) ?? 0
        XCTAssertFalse(first.isEmpty)
        let claimedBefore = lane.stats.streamDaysClaimed

        // Nothing changed: the next look enqueues nothing and claims nothing.
        lane.lastStreamEnqueueAt = nil
        lane.drainStreamDays(budget: 20)
        XCTAssertEqual(lane.stats.streamDaysClaimed, claimedBefore, "an unchanged day must not be rebuilt")

        // More data arrives and the scorer finishes another revision: the day is rebuilt, one document.
        var later = DaySim(start: sim.ts)
        later.still(300)
        try seed(f, sim: later)
        try completeScoring(f, revision: 2)
        lane.lastStreamEnqueueAt = nil
        lane.enqueueStreamDaysIfDue()

        // The rebuild spacing holds: a day built a moment ago is not claimable again at once.
        lane.drainStreamDays(budget: 20)
        XCTAssertEqual(lane.stats.streamDaysClaimed, claimedBefore, "rebuilds are spaced out")
        XCTAssertTrue(try streamJobs(f).contains { $0["done"] != $0["rev"] }, "the day is marked as needing a rebuild")

        // Ten minutes later (fast-forwarded), it is rebuilt.
        _ = try f.db.query("""
            update public.activity_context_jobs set not_before = clock_timestamp()
            where user_id=$1::uuid and device_id=$2::uuid and algorithm_version='streams-activity-1'
            """, [f.user, f.device])
        lane.drainStreamDays(budget: 20)

        XCTAssertGreaterThan(lane.stats.streamDaysClaimed, claimedBefore)
        XCTAssertTrue(try streamJobs(f).allSatisfy { $0["done"] == $0["rev"] }, "every job is caught up again")
        XCTAssertEqual(try dayDocs(f), "1")
        let second = try scalar(f, "select result_revision::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid")
        XCTAssertGreaterThan(Int(second) ?? 0, Int(first) ?? Int.max)
        let secondObserved = Int(try scalar(f, "select observed_s::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid")) ?? 0
        XCTAssertGreaterThan(secondObserved, firstObserved, "the new minutes are in the refreshed document")
        XCTAssertEqual(lane.stats.streamDayFailures, 0, lane.stats.lastStreamDayError ?? "")
    }

    func testADayWithScoringButNoMeasurementsCompletesWithoutADocumentAndStaysDone() throws {
        let f = try makeFixture()
        try completeScoring(f)
        var lane = makeLane(f.db)
        lane.drainStreamDays(budget: 20)

        let jobs = try streamJobs(f)
        XCTAssertEqual(jobs.count, 3)
        XCTAssertTrue(jobs.allSatisfy { $0["done"] == $0["rev"] }, "\(jobs)")
        XCTAssertGreaterThanOrEqual(lane.stats.streamDaysEmpty, 3)
        XCTAssertEqual(lane.stats.streamDaysPublished, 0)
        XCTAssertEqual(try dayDocs(f), "0")

        let claimed = lane.stats.streamDaysClaimed
        lane.lastStreamEnqueueAt = nil
        lane.drainStreamDays(budget: 20)
        XCTAssertEqual(lane.stats.streamDaysClaimed, claimed, "an empty day is not retried until its scoring changes")
    }

    func testStreamDaysDoNotWaitForThePythonModel() throws {
        let f = try makeFixture()
        let (sim, events, _) = middayStreams(f)
        try seed(f, sim: sim, events: events)
        try completeScoring(f)
        var lane = makeLane(f.db)
        // `drain` runs the raw-IMU half first; with no Python it reports the model unavailable and
        // claims nothing there, and the stream half still does its work.
        lane.drain(budget: 1)
        XCTAssertEqual(lane.stats.modelUnavailable, 1)
        XCTAssertEqual(lane.stats.claimed, 0)
        XCTAssertGreaterThanOrEqual(lane.stats.streamDaysPublished, 1)
        XCTAssertEqual(try dayDocs(f), "1")
    }

    func testAHostWithoutPythonCanRunStreamDaysAlone() throws {
        let f = try makeFixture()
        let (sim, events, _) = middayStreams(f)
        try seed(f, sim: sim, events: events)
        try completeScoring(f)
        var lane = makeLane(f.db)
        lane.imuJobsEnabled = false
        lane.drain(budget: 1)
        XCTAssertEqual(lane.stats.modelUnavailable, 0, "the raw-IMU half never looked for a model")
        XCTAssertNil(lane.stats.lastError)
        XCTAssertNil(lane.stats.lastErrorKind)
        XCTAssertGreaterThanOrEqual(lane.stats.streamDaysPublished, 1)
        XCTAssertEqual(try dayDocs(f), "1")
    }

    func testTurningStreamsOffLeavesTheStreamQueueAlone() throws {
        let f = try makeFixture()
        let (sim, events, _) = middayStreams(f)
        try seed(f, sim: sim, events: events)
        try completeScoring(f)
        var lane = makeLane(f.db)
        lane.streamDaysEnabled = false
        lane.drain(budget: 1)
        XCTAssertEqual(lane.stats.streamDaysClaimed, 0)
        XCTAssertEqual(lane.stats.streamDaysEnqueued, 0)
        XCTAssertEqual(try streamJobs(f).count, 0)
    }

    // MARK: - A database without the migration

    func testAMissingClaimFunctionOnlyPausesTheStreamSource() throws {
        let f = try makeFixture()
        var lane = makeLane(f.db)

        // DDL is transactional: drop the function inside a transaction we roll back, which is what a
        // database that never had the migration looks like to the worker.
        try f.db.beginTransaction()
        defer { f.db.rollbackTransaction() }
        try f.db.exec("drop function public.claim_activity_stream_day(integer)")
        lane.drainStreamDays(budget: 3)

        XCTAssertNotNil(lane.streamBackoffUntil, "a failing claim backs the source off")
        XCTAssertEqual(lane.stats.lastErrorKind, "stream_days")
        XCTAssertTrue(lane.stats.lastError?.contains("stream_days_claim") == true, lane.stats.lastError ?? "nil")
        XCTAssertTrue(lane.stats.lastStreamDayError?.contains("claim_activity_stream_day") == true,
                      lane.stats.lastStreamDayError ?? "nil")
        XCTAssertEqual(lane.stats.streamDaysClaimed, 0)

        // While backed off the source is left alone: no second claim attempt, no second error.
        let before = lane.stats.lastStreamDayError
        lane.drainStreamDays(budget: 3)
        XCTAssertEqual(lane.stats.lastStreamDayError, before)
    }

    // MARK: - The reconcile call

    func testTheReconcileCallTheLaneMakesIsAValidCall() throws {
        let f = try makeFixture()
        // The call the lane issues once a minute must parse and run; before the lookback was a bare
        // interval literal it failed on every call and the `try?` around it hid that.
        XCTAssertNoThrow(try f.db.callFunctionForJSON(ActivityLane.reconcileSQL, [ActivityLane.reconcileLookback]))
        XCTAssertThrowsError(try f.db.callFunctionForJSON(ActivityLane.reconcileSQL, ["'7 days'::interval"]),
                             "the quoted form is not an interval literal")
    }
}