import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The ActivityContext v2 stage against a real Postgres: stored streams → the shared decoder → the
/// document the `publish_activity_context_day` RPC validates and stores, in the same transaction as the
/// unchanged v1 publish.
///
/// Needs a scratch Postgres that has the activity migrations applied (the v1 one and
/// `20261003130000_activity_context_days.sql`): set FRWHOOP_TEST_DB_URL, e.g.
/// `postgresql://user@localhost:5432/scratch` (skipped otherwise, and skipped when the v2 table is
/// missing). Every test makes its own user and device and deletes them afterwards; deleting the user
/// cascades to everything the test wrote.
final class ActivityContextDaysDatabaseTests: XCTestCase {

    private let dayStart = 1_789_430_400          // 2026-09-15 00:00:00 UTC
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"
    private let model = "hart-activity-1"
    private let preprocessing = "activity-preprocess-1"

    // MARK: - Fixture

    private struct Fixture {
        let db: PostgresClient
        let user: String
        let device: String
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
        let present = try db.query(
            "select (to_regclass('public.activity_context_days') is not null "
            + "and to_regclass('public.activity_context_jobs') is not null) as present", [])
        guard present.first?["present"] == "t" else {
            throw XCTSkip("apply the activity migrations (incl. 20261003130000_activity_context_days.sql) to the scratch database")
        }
        let user = UUID().uuidString.lowercased()
        let device = UUID().uuidString.lowercased()
        try db.exec("insert into auth.users(id) values ('\(user)')")
        try db.exec("insert into public.devices(id,user_id,source_kind) values ('\(device)','\(user)','noop_push')")
        addTeardownBlock {
            db.rollbackTransaction()
            try? db.exec("delete from auth.users where id = '\(user)'")
        }
        return Fixture(db: db, user: user, device: device)
    }

    private func jsonText(_ rows: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
    }

    /// Stores the simulated day's heart rate, gravity and step rows (and any wear events) the way the
    /// ingest path does. `since` stores only the rows from that second on (data arriving later).
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

    private func fingerprint(_ letter: Character) -> String { String(repeating: letter, count: 64) }

    /// Enqueues the day and claims it the way the lane does, returning the leased job.
    private func claimJob(_ f: Fixture, fingerprint fp: String) throws -> ActivityLane.ActivityJob {
        _ = try f.db.callFunctionForJSON("""
            select public.enqueue_activity_context($1::uuid,$2::uuid,$3::date,
              array['d0000000-0000-4000-8000-0000000000d1'::uuid], array[$4::text],$4::text,
              $5::text,$6::text,'v1')::text
            """, [f.user, f.device, day, fp, model, preprocessing])
        let rows = try f.db.query("select * from public.claim_activity_context_v2(300)", [])
        let row = try XCTUnwrap(rows.first, "the freshly enqueued job must be claimable")
        let job = try XCTUnwrap(ActivityLane.parseJob(row))
        XCTAssertEqual(job.userId, f.user, "the scratch database holds another user's activity job; use a clean one")
        XCTAssertEqual(job.day, day)
        return job
    }

    private func makeLane(_ db: PostgresClient) -> ActivityLane {
        ActivityLane(
            db: db,
            storage: B2Storage(keyID: "unused", applicationKey: "unused", bucket: "unused"),
            service: ActivityPythonService(config: ActivityPythonService.Config(
                pythonBin: "/usr/bin/python3", activityHome: FileManager.default.currentDirectoryPath,
                modelDir: nil, serveArgs: [], requestTimeoutSeconds: 1,
                maxRequestBytes: 1_024, maxResponseLineBytes: 1_024, restartCap: 1, restartCooldownSeconds: 1)),
            leaseSeconds: 300)
    }

    /// A walking stretch between two sitting ones around midday, with the strap taken off for a while.
    private func middayStreams() -> (sim: DaySim, events: [(ts: Int, kind: String)]) {
        var sim = DaySim(start: dayStart + 12 * 3_600)
        sim.still(240)
        sim.walk(150)
        sim.still(240)
        sim.gap(600)
        sim.still(120)
        let events = [(ts: dayStart + 12 * 3_600 + 630, kind: "WRIST_OFF(10)"),
                      (ts: dayStart + 12 * 3_600 + 1_230, kind: "WRIST_ON(11)")]
        return (sim, events)
    }

    /// The v1 payload for the same windows, built the way `process` builds it.
    private func v1Payload(_ job: ActivityLane.ActivityJob, windows: [ActivityPythonService.WindowPrediction],
                           dataThrough: Int) throws -> String {
        var doc = try ActivityLane.activityDocument(
            windows: windows, sleepIntervals: [], exerciseIntervals: [],
            dayStart: dayStart, dayEnd: dayEnd, inputRevision: job.inputRevision,
            modelVersion: model, preprocessingVersion: preprocessing, dataThrough: dataThrough)
        return try ActivityLane.dayStampedJSONText(doc: &doc, day: job.day)
    }

    private func scalar(_ f: Fixture, _ sql: String) throws -> String {
        try f.db.query(sql, [f.user, f.device]).first?.values.first ?? ""
    }

    private func dayRows(_ f: Fixture) throws -> Int {
        Int(try scalar(f, "select count(*)::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid")) ?? -1
    }

    private func epochRows(_ f: Fixture) throws -> Int {
        Int(try scalar(f, "select count(*)::text from public.activity_context_epochs where user_id=$1::uuid and device_id=$2::uuid")) ?? -1
    }

    private func completedRevision(_ f: Fixture) throws -> String {
        try scalar(f, "select completed_revision::text from public.activity_context_jobs where user_id=$1::uuid and device_id=$2::uuid")
    }

    // MARK: - The happy path

    func testTheSwiftBuiltDocumentIsStoredBesideTheV1Epochs() throws {
        let f = try makeFixture()
        let (sim, events) = middayStreams()
        try seed(f, sim: sim, events: events)
        let job = try claimJob(f, fingerprint: fingerprint("a"))
        var lane = makeLane(f.db)

        let built = try XCTUnwrap(try lane.buildContextDay(
            job: job, dayBounds: (dayStart, dayEnd), windows: sim.windows,
            versions: (model, preprocessing), asleep: [], exercise: []))
        XCTAssertEqual(lane.stats.contextDayFailures, 0)
        XCTAssertGreaterThan(built.runs, 0)

        let published = try lane.publishDay(
            job: job, payloadText: try v1Payload(job, windows: sim.windows, dataThrough: sim.ts),
            dayDocument: built, durationMS: 12, dayBounds: (dayStart, dayEnd))
        XCTAssertTrue(published)
        XCTAssertEqual(lane.stats.contextDaysPublished, 1)
        XCTAssertEqual(lane.stats.contextDayFailures, 0, lane.stats.lastContextDayError ?? "")

        XCTAssertEqual(try dayRows(f), 1)
        let row = try XCTUnwrap(try f.db.query("""
            select schema_version::text, ontology_version, decoder_version, feature_schema, encoder_id,
                   encoder_version, model_version, preprocessing_version, input_revision::text, run_count::text,
                   observed_s::text, publish_interval_s::text, algorithm_version, day::text,
                   jsonb_array_length(document->'runs')::text as doc_runs,
                   (document->>'day_start') as day_start, (document->>'sleep_known_outside') as known,
                   (document ? 'snapshot')::text as has_snapshot, job_fingerprint
            from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device]).first)
        XCTAssertEqual(row["schema_version"], String(ActivityContextVersions.schema))
        XCTAssertEqual(row["ontology_version"], ActivityContextVersions.ontology)
        XCTAssertEqual(row["decoder_version"], ActivityContextVersions.decoder)
        XCTAssertEqual(row["feature_schema"], ActivityContextVersions.featureSchema)
        XCTAssertEqual(row["encoder_id"], "hart")
        XCTAssertEqual(row["encoder_version"], model)
        XCTAssertEqual(row["model_version"], model)
        XCTAssertEqual(row["preprocessing_version"], preprocessing)
        XCTAssertEqual(row["input_revision"], String(job.inputRevision))
        XCTAssertEqual(row["run_count"], String(built.runs))
        XCTAssertEqual(row["doc_runs"], String(built.runs))
        XCTAssertEqual(row["observed_s"], String(built.observedSeconds))
        XCTAssertEqual(row["day"], day)
        XCTAssertEqual(row["day_start"], String(dayStart))
        // The job day ended long before `now`, so its waking hours are awake, exactly as the stream day decodes
        // them (audit D1-02: the raw-IMU decode used to leave every finished day "unknown" forever).
        XCTAssertEqual(row["known"], "true")
        XCTAssertEqual(row["has_snapshot"], "false")
        XCTAssertEqual(row["job_fingerprint"], fingerprint("a"))

        // The stored document carries what the decoder saw: the walk, and the time the strap was off.
        let labels = try f.db.query("""
            select r->>'display_context' as label, count(*)::text as n
            from public.activity_context_days d, jsonb_array_elements(d.document->'runs') r
            where d.user_id=$1::uuid and d.device_id=$2::uuid group by 1
            """, [f.user, f.device]).reduce(into: [String: Int]()) { $0[$1["label"] ?? ""] = Int($1["n"] ?? "") }
        XCTAssertTrue(labels.keys.contains { $0 == "Walking" || $0 == "Brisk walking" }, "\(labels)")
        XCTAssertNotNil(labels["Off wrist"], "the WRIST_OFF/WRIST_ON pair must reach the decoder: \(labels)")

        // The v1 publish is what completed the job and wrote the epochs, exactly as without v2.
        XCTAssertEqual(try completedRevision(f), String(job.inputRevision))
        XCTAssertGreaterThan(try epochRows(f), 0)
    }

    // MARK: - v2 can never hurt v1

    func testARejectedDayDocumentNeverBlocksTheV1Publish() throws {
        let f = try makeFixture()
        let (sim, _) = middayStreams()
        let job = try claimJob(f, fingerprint: fingerprint("b"))
        var lane = makeLane(f.db)

        let malformed = ActivityContextDays.Built(
            payloadText: "{\"day\":\"\(day)\",\"document\":{\"schema_version\":2}}",
            runs: 0, events: 0, observedSeconds: 0)
        let published = try lane.publishDay(
            job: job, payloadText: try v1Payload(job, windows: sim.windows, dataThrough: sim.ts),
            dayDocument: malformed, durationMS: 1, dayBounds: (dayStart, dayEnd))

        XCTAssertTrue(published, "the v1 epochs are published regardless")
        XCTAssertEqual(lane.stats.contextDaysPublished, 0)
        XCTAssertEqual(lane.stats.contextDayFailures, 1)
        XCTAssertTrue(lane.stats.lastContextDayError?.contains("invalid_activity_day") == true,
                      lane.stats.lastContextDayError ?? "nil")
        XCTAssertEqual(try dayRows(f), 0)
        XCTAssertEqual(try completedRevision(f), String(job.inputRevision))
        XCTAssertGreaterThan(try epochRows(f), 0)
        XCTAssertFalse(f.db.isInTransaction)
    }

    func testAMissingRpcOnlyCostsTheDayDocument() throws {
        let f = try makeFixture()
        let job = try claimJob(f, fingerprint: fingerprint("c"))
        let db = f.db

        // DDL is transactional: drop the function inside a transaction we roll back, which is what a
        // database that never had the migration looks like to the worker.
        try db.beginTransaction()
        defer { db.rollbackTransaction() }
        try db.exec("drop function public.publish_activity_context_day(uuid, bigint, jsonb)")
        let outcome = try ActivityContextDays.publish(
            db: db, token: job.leaseToken, revision: job.inputRevision,
            payload: "{\"day\":\"\(day)\",\"document\":{}}")
        guard case .rejected(let why) = outcome else { return XCTFail("expected a rejection, got \(outcome)") }
        XCTAssertTrue(why.contains("does not exist"), why)
        XCTAssertTrue(db.isInTransaction)
        XCTAssertEqual(try db.query("select 1 as one", []).first?["one"], "1",
                       "the transaction that carries the v1 publish must still accept statements")
    }

    func testAFailingV1PublishRollsTheDayDocumentBackWithIt() throws {
        let f = try makeFixture()
        let (sim, events) = middayStreams()
        try seed(f, sim: sim, events: events)
        let job = try claimJob(f, fingerprint: fingerprint("d"))
        var lane = makeLane(f.db)
        let built = try XCTUnwrap(try lane.buildContextDay(
            job: job, dayBounds: (dayStart, dayEnd), windows: sim.windows,
            versions: (model, preprocessing), asleep: [], exercise: []))

        // The v1 payload is garbage, so the v1 publish raises after the v2 row was written in the same
        // transaction.
        XCTAssertThrowsError(try lane.publishDay(
            job: job, payloadText: "{}", dayDocument: built, durationMS: 1, dayBounds: (dayStart, dayEnd)))
        XCTAssertFalse(f.db.isInTransaction)
        XCTAssertEqual(try dayRows(f), 0, "no half-published pair")
        XCTAssertEqual(try epochRows(f), 0)
        XCTAssertEqual(try completedRevision(f), "0", "the job was not completed")
        XCTAssertEqual(lane.stats.contextDaysPublished, 0)
    }

    func testAStaleRevisionFencesBothPublishes() throws {
        let f = try makeFixture()
        let (sim, events) = middayStreams()
        try seed(f, sim: sim, events: events)
        let job = try claimJob(f, fingerprint: fingerprint("e"))
        var lane = makeLane(f.db)
        let built = try XCTUnwrap(try lane.buildContextDay(
            job: job, dayBounds: (dayStart, dayEnd), windows: sim.windows,
            versions: (model, preprocessing), asleep: [], exercise: []))

        // New input arrived while this run was computing: the queue is at revision 2 now.
        _ = try f.db.callFunctionForJSON("""
            select public.enqueue_activity_context($1::uuid,$2::uuid,$3::date,
              array['d0000000-0000-4000-8000-0000000000d1'::uuid], array[$4::text],$4::text,
              $5::text,$6::text,'v1')::text
            """, [f.user, f.device, day, fingerprint("f"), model, preprocessing])

        let published = try lane.publishDay(
            job: job, payloadText: try v1Payload(job, windows: sim.windows, dataThrough: sim.ts),
            dayDocument: built, durationMS: 1, dayBounds: (dayStart, dayEnd))
        XCTAssertFalse(published)
        XCTAssertEqual(lane.stats.notCompleted, 1)
        XCTAssertEqual(lane.stats.contextDaysPublished, 0)
        XCTAssertEqual(lane.stats.contextDayFailures, 0, "being fenced out is not a failure")
        XCTAssertEqual(try dayRows(f), 0)
        XCTAssertEqual(try epochRows(f), 0)
    }

    func testTurningV2OffLeavesTheV1PathUntouched() throws {
        let f = try makeFixture()
        let (sim, events) = middayStreams()
        try seed(f, sim: sim, events: events)
        let job = try claimJob(f, fingerprint: fingerprint("a"))
        var lane = makeLane(f.db)
        lane.contextDaysEnabled = false

        let built = try lane.buildContextDay(
            job: job, dayBounds: (dayStart, dayEnd), windows: sim.windows,
            versions: (model, preprocessing), asleep: [], exercise: [])
        XCTAssertNil(built)
        let published = try lane.publishDay(
            job: job, payloadText: try v1Payload(job, windows: sim.windows, dataThrough: sim.ts),
            dayDocument: built, durationMS: 1, dayBounds: (dayStart, dayEnd))
        XCTAssertTrue(published)
        XCTAssertEqual(try dayRows(f), 0)
        XCTAssertGreaterThan(try epochRows(f), 0)
        XCTAssertEqual(lane.stats.contextDayFailures, 0)
    }

    // MARK: - Recompute

    func testANewerRevisionReplacesTheStoredDay() throws {
        let f = try makeFixture()
        let (sim, events) = middayStreams()
        try seed(f, sim: sim, events: events)
        var lane = makeLane(f.db)

        let first = try claimJob(f, fingerprint: fingerprint("a"))
        let firstBuilt = try XCTUnwrap(try lane.buildContextDay(
            job: first, dayBounds: (dayStart, dayEnd), windows: sim.windows,
            versions: (model, preprocessing), asleep: [], exercise: []))
        XCTAssertTrue(try lane.publishDay(
            job: first, payloadText: try v1Payload(first, windows: sim.windows, dataThrough: sim.ts),
            dayDocument: firstBuilt, durationMS: 1, dayBounds: (dayStart, dayEnd)))
        let firstResult = try scalar(f, "select result_revision::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid")

        // More data for the same day: a new fingerprint bumps the revision and the job runs again.
        var later = sim
        later.still(300)
        try seed(f, sim: later, since: sim.ts)
        let second = try claimJob(f, fingerprint: fingerprint("b"))
        XCTAssertEqual(second.inputRevision, first.inputRevision + 1)
        let secondBuilt = try XCTUnwrap(try lane.buildContextDay(
            job: second, dayBounds: (dayStart, dayEnd), windows: later.windows,
            versions: (model, preprocessing), asleep: [], exercise: []))
        XCTAssertGreaterThan(secondBuilt.observedSeconds, firstBuilt.observedSeconds)
        XCTAssertTrue(try lane.publishDay(
            job: second, payloadText: try v1Payload(second, windows: later.windows, dataThrough: later.ts),
            dayDocument: secondBuilt, durationMS: 1, dayBounds: (dayStart, dayEnd)))

        XCTAssertEqual(try dayRows(f), 1, "one document per device and day")
        XCTAssertEqual(try scalar(f, "select input_revision::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid"),
                       String(second.inputRevision))
        XCTAssertEqual(try scalar(f, "select observed_s::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid"),
                       String(secondBuilt.observedSeconds))
        let secondResult = try scalar(f, "select result_revision::text from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid")
        XCTAssertGreaterThan(Int(secondResult) ?? 0, Int(firstResult) ?? Int.max)
        XCTAssertEqual(lane.stats.contextDaysPublished, 2)
    }

    // MARK: - Every document shape the builder can produce is accepted

    /// The Swift encoder and the SQL validator are written apart; this is where they meet. Each shape is
    /// published inside a transaction that is rolled back, against one leased job.
    func testEveryDocumentShapeTheBuilderProducesPassesTheRpcValidation() throws {
        let f = try makeFixture()
        let job = try claimJob(f, fingerprint: fingerprint("a"))
        let db = f.db

        func input(_ sim: DaySim, events: [WhoopEvent] = [], sleep: [(start: Int, end: Int)] = [],
                   exercise: [(start: Int, end: Int, sport: String)] = []) -> ActivityContextTrackInput {
            var streams = sim.streams
            streams.events = events
            return ActivityContextDays.trackInput(
                windows: sim.windows, streams: streams, sleep: sleep, exercise: exercise,
                dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: model)
        }

        var shapes: [(name: String, input: ActivityContextTrackInput)] = []
        shapes.append(("no data at all", input(DaySim(start: dayStart))))

        var first = DaySim(start: dayStart)
        first.still(20)
        shapes.append(("data from the first second", input(first)))

        var lastSecond = DaySim(start: dayEnd - 30)
        lastSecond.still(30)
        shapes.append(("data to the last second", input(lastSecond)))

        var lateTick = DaySim(start: dayEnd - 130)
        lateTick.still(100); lateTick.gap(26); lateTick.still(4)
        shapes.append(("late publish tick right before midnight", input(lateTick)))

        var baseline = DaySim(start: dayStart + 40_000)
        baseline.baseline = true
        baseline.still(200); baseline.walk(100)
        shapes.append(("heuristic baseline windows", input(baseline)))

        var noFeatures = DaySim(start: dayStart + 41_000)
        noFeatures.still(100); noFeatures.walk(100)
        var noFeaturesInput = input(noFeatures)
        noFeaturesInput.imuWindows = []
        shapes.append(("no IMU features", noFeaturesInput))

        var streamsOnly = DaySim(start: dayStart + 42_000)
        streamsOnly.still(100); streamsOnly.walk(100)
        var streamsOnlyInput = input(streamsOnly)
        streamsOnlyInput.encoderWindows = []
        streamsOnlyInput.imuWindows = []
        shapes.append(("stored streams only", streamsOnlyInput))

        var worn = DaySim(start: dayStart + 43_000)
        worn.still(300)
        shapes.append(("sleep, workout and wrist-off context", input(
            worn,
            events: [WhoopEvent(ts: dayStart + 43_100, kind: "WRIST_OFF(10)", payload: [:]),
                     WhoopEvent(ts: dayStart + 43_200, kind: "WRIST_ON(11)", payload: [:])],
            sleep: [(start: dayStart + 42_900, end: dayStart + 43_150)],
            exercise: [(start: dayStart + 43_250, end: dayStart + 43_300, sport: "cycling")])))

        shapes.append(("a strap off for the whole day", input(
            DaySim(start: dayStart),
            events: [WhoopEvent(ts: dayStart - 600, kind: "WRIST_OFF(10)", payload: [:])])))

        try db.beginTransaction()
        defer { db.rollbackTransaction() }
        for shape in shapes {
            let built = try ActivityContextDays.build(
                input: shape.input, day: day, modelVersion: model, preprocessingVersion: preprocessing,
                generatedAt: 1_789_500_000)
            let outcome = try ActivityContextDays.publish(
                db: db, token: job.leaseToken, revision: job.inputRevision, payload: built.payloadText)
            guard case .stored = outcome else {
                return XCTFail("\(shape.name): \(outcome)")
            }
        }
        XCTAssertTrue(db.isInTransaction)
    }
}
