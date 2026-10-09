import XCTest
import StrandAnalytics
@testable import frwhoop_worker

/// The RecGym exercise windows against a real Postgres: written by `publish_activity_exercise_windows` inside the same
/// transaction as the unchanged v2 day document and v1 publish, under its own savepoint.
///
/// Needs a scratch Postgres with the activity migrations and `20261009160000_activity_exercise_windows.sql` applied
/// (the pipeline database: supabase/tests/e2e/pipeline_db.sh): set FRWHOOP_TEST_DB_URL (skipped otherwise, and when
/// the table is missing). Every test makes its own user and device and deletes them afterwards.
final class ActivityExerciseWindowsDatabaseTests: XCTestCase {

    private let dayStart = 1_789_430_400          // 2026-09-15 00:00:00 UTC
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"
    private let model = "hart-activity-1"
    private let preprocessing = "activity-preprocess-1"
    private let pin = "7f0c4adf066bb842eeb0c114e765fd3cf1ca3a7ca6ef6cf5344f5f142651f5d9"

    private struct Fixture {
        let db: PostgresClient
        let user: String
        let device: String
    }

    private func makeFixture() throws -> Fixture {
        guard let url = ProcessInfo.processInfo.environment["FRWHOOP_TEST_DB_URL"], !url.isEmpty else {
            throw XCTSkip("set FRWHOOP_TEST_DB_URL to a scratch Postgres with the activity migrations applied")
        }
        let db = try PostgresClient(options: PostgresOptions(
            connectionString: url, sslMode: "disable", sslRootCert: nil,
            applicationName: "frwhoop-worker-tests", allowInsecure: true,
            connectTimeoutSeconds: 5, reconnectDeadlineSeconds: 5,
            statementTimeoutMS: 60_000, idleTransactionTimeoutMS: 60_000))
        let present = try db.query(
            "select (to_regclass('public.activity_exercise_windows') is not null "
            + "and to_regclass('public.activity_context_days') is not null) as present", [])
        guard present.first?["present"] == "t" else {
            throw XCTSkip("apply 20261009160000_activity_exercise_windows.sql (and the activity migrations) to the scratch database")
        }
        let user = UUID().uuidString.lowercased()
        let device = UUID().uuidString.lowercased()
        try db.exec("insert into auth.users(id) values ('\(user)')")
        try db.exec("insert into public.devices(id,user_id,source_kind) values ('\(device)','\(user)','noop_push')")
        addTeardownBlock {
            db.rollbackTransaction()
            try db.deleteFixtureOwners([user])
        }
        return Fixture(db: db, user: user, device: device)
    }

    private func claimJob(_ f: Fixture, fingerprint letter: Character) throws -> ActivityLane.ActivityJob {
        let fp = String(repeating: letter, count: 64)
        _ = try f.db.callFunctionForJSON("""
            select public.enqueue_activity_context($1::uuid,$2::uuid,$3::date,
              array['d0000000-0000-4000-8000-0000000000e1'::uuid], array[$4::text],$4::text,
              $5::text,$6::text,'v1')::text
            """, [f.user, f.device, day, fp, model, preprocessing])
        let rows = try f.db.query("select * from public.claim_activity_context_v2(300)", [])
        let job = try XCTUnwrap(ActivityLane.parseJob(try XCTUnwrap(rows.first)))
        XCTAssertEqual(job.userId, f.user, "the scratch database holds another user's activity job; use a clean one")
        return job
    }

    /// A lane with an exercise stage whose child is never started (the payload is built from a synthetic collector).
    private func makeLane(_ db: PostgresClient) -> ActivityLane {
        let unused = ActivityPythonService(config: ActivityPythonService.Config(
            pythonBin: "/usr/bin/python3", activityHome: FileManager.default.currentDirectoryPath,
            modelDir: nil, serveArgs: [], requestTimeoutSeconds: 1,
            maxRequestBytes: 1_024, maxResponseLineBytes: 1_024, restartCap: 1, restartCooldownSeconds: 1))
        var lane = ActivityLane(db: db, storage: B2Storage(keyID: "unused", applicationKey: "unused", bucket: "unused"),
                                service: unused, leaseSeconds: 300)
        lane.exercise = ExerciseStage(service: unused)
        return lane
    }

    private func sim() -> DaySim {
        var s = DaySim(start: dayStart + 12 * 3_600)
        s.still(200); s.walk(150); s.still(200)
        return s
    }

    private func v1Payload(_ job: ActivityLane.ActivityJob, windows: [ActivityPythonService.WindowPrediction],
                           dataThrough: Int) throws -> String {
        var doc = try ActivityLane.activityDocument(
            windows: windows, sleepIntervals: [], exerciseIntervals: [],
            dayStart: dayStart, dayEnd: dayEnd, inputRevision: job.inputRevision,
            modelVersion: model, preprocessingVersion: preprocessing, dataThrough: dataThrough)
        return try ActivityLane.dayStampedJSONText(doc: &doc, day: job.day)
    }

    /// One answered 120-s chunk at noon: windows every 2 s, BenchPress-heavy on multiples of 8 s, Null-heavy otherwise.
    private func collector(start: Int, key: String = "k1") -> ExerciseCollector {
        let bench = [0.01, 0.01, 0.86, 0.01, 0.01, 0.03, 0.01, 0.01, 0.01, 0.02, 0.01, 0.01]
        let null = [0.004, 0.001, 0.002, 0.003, 0.0, 0.98, 0.0, 0.0, 0.002, 0.003, 0.002, 0.003]
        let windows = stride(from: start + 2, through: start + 114, by: 2).map {
            ExerciseWindow(start: $0, end: $0 + 4, probabilities: $0 % 8 == 0 ? bench : null,
                           inputSHA256: String(repeating: String($0 % 10), count: 64))
        }
        var c = ExerciseCollector()
        c.answered = [.init(start: start, end: start + 120, key: key, response: ExerciseResponse(
            model: ExerciseModelInfo(modelId: ExerciseWire.modelId, modelVersion: "recgym-cnn-transformer-e085ac0",
                                     weightsSHA256: pin, scalerVersion: "recgym-wrist-imu-scaler-1",
                                     preprocessingVersion: "recgym-prep-1"),
            windows: windows, droppedNonfinite: 0))]
        c.chunks = 1
        return c
    }

    private func count(_ f: Fixture, _ extra: String = "true") throws -> Int {
        Int(try f.db.query("select count(*)::text as n from public.activity_exercise_windows "
                           + "where user_id=$1::uuid and device_id=$2::uuid and \(extra)",
                           [f.user, f.device]).first?["n"] ?? "") ?? -1
    }

    // MARK: - Tests

    func testWindowsAreStoredBesideUnchangedV1AndV2PublishesAndOnlyThenMarkedPublished() throws {
        let f = try makeFixture()
        let s = sim()
        let job = try claimJob(f, fingerprint: "a")
        var lane = makeLane(f.db)
        let stage = try XCTUnwrap(lane.exercise)
        let built = try XCTUnwrap(try lane.buildContextDay(job: job, dayBounds: (dayStart, dayEnd), windows: s.windows,
                                                           versions: (model, preprocessing), asleep: [], exercise: []))
        let payload = try XCTUnwrap(try ActivityExerciseWindows.payload(
            day: job.day, dayBounds: (dayStart, dayEnd), device: job.deviceId, inputRevision: job.inputRevision,
            collector: collector(start: dayStart + 12 * 3_600), stage: stage))
        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                            dayDocument: built, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            exerciseWindows: payload)
        XCTAssertTrue(published)
        XCTAssertEqual(lane.stats.exerciseStored, 1)
        XCTAssertEqual(lane.stats.exerciseWindowsStored, 57)
        XCTAssertEqual(try count(f), 57)
        XCTAssertEqual(try count(f, "top_class = 'BenchPress' and abs(top_p - 0.86) < 1e-6"), 14)
        XCTAssertEqual(try count(f, "top_class = 'Null' and abs(p_null - 0.98) < 1e-6"), 43)
        XCTAssertEqual(try count(f, "release_mode = 'shadow' and placement is null and not placement_supported "
                                 + "and placement_reason = 'placement_unknown'"), 57, "undeclared placement")
        XCTAssertEqual(try count(f, "day = '\(day)'::date and input_revision = \(job.inputRevision) "
                                 + "and job_fingerprint = '\(job.fingerprint)'"), 57, "job lineage")
        XCTAssertEqual(stage.published.value(ExerciseStage.publishedKey(device: job.deviceId, key: "k1")), true,
                       "marked published after the commit")
        // The HART publishes went through unchanged.
        XCTAssertEqual(try f.db.query("select count(*)::text as n from public.activity_context_days where user_id=$1::uuid",
                                      [f.user]).first?["n"], "1")
        XCTAssertEqual(try f.db.query("select completed_revision::text as r from public.activity_context_jobs "
                                      + "where user_id=$1::uuid", [f.user]).first?["r"], String(job.inputRevision))
    }

    func testThePublishFunctionRecordsTheDeclaredUpperArmAsUnsupported() throws {
        let f = try makeFixture()
        try f.db.exec("""
            insert into public.placement_intervals(owner, device_id, placement, effective_start)
            values ('\(f.user)', '\(f.device)', 'bicep', to_timestamp(\(dayStart)))
            """)
        let job = try claimJob(f, fingerprint: "b")
        let lane = makeLane(f.db)
        let payload = try XCTUnwrap(try ActivityExerciseWindows.payload(
            day: job.day, dayBounds: (dayStart, dayEnd), device: job.deviceId, inputRevision: job.inputRevision,
            collector: collector(start: dayStart + 12 * 3_600), stage: try XCTUnwrap(lane.exercise)))
        guard case .stored = try ActivityExerciseWindows.publish(db: f.db, token: job.leaseToken,
                                                                 revision: job.inputRevision, payload: payload.text)
        else { return XCTFail("the payload must be stored") }
        XCTAssertEqual(try count(f, "placement = 'bicep' and not placement_supported "
                                 + "and placement_reason = 'placement_unsupported'"), 57)
    }

    func testAFencedOrRefusedPublishWritesNothingAndLeavesTheTransactionUsable() throws {
        let f = try makeFixture()
        let s = sim()
        let job = try claimJob(f, fingerprint: "c")
        var lane = makeLane(f.db)
        let stage = try XCTUnwrap(lane.exercise)
        let good = try XCTUnwrap(try ActivityExerciseWindows.payload(
            day: job.day, dayBounds: (dayStart, dayEnd), device: job.deviceId, inputRevision: job.inputRevision,
            collector: collector(start: dayStart + 12 * 3_600, key: "k2"), stage: stage))
        XCTAssertEqual(try ActivityExerciseWindows.publish(db: f.db, token: job.leaseToken,
                                                           revision: job.inputRevision + 1, payload: good.text), .fenced)
        // An authority block that claims more than shadow is refused by the database, whatever the worker sends.
        var tampered = good
        tampered.text = good.text.replacingOccurrences(of: "\"release_mode\":\"shadow\"", with: "\"release_mode\":\"candidate\"")
        XCTAssertNotEqual(tampered.text, good.text)
        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                            dayDocument: nil, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            exerciseWindows: tampered)
        XCTAssertTrue(published, "the v1 publish commits although the exercise payload was refused")
        XCTAssertEqual(lane.stats.exerciseRejected, 1)
        XCTAssertTrue(lane.stats.lastExercisePublishError?.contains("invalid_exercise_windows_authority") ?? false,
                      lane.stats.lastExercisePublishError ?? "")
        XCTAssertEqual(try count(f), 0)
        XCTAssertNil(stage.published.value(ExerciseStage.publishedKey(device: job.deviceId, key: "k2")),
                     "nothing is marked published")
    }

    func testRetentionDeletesOldWindowsOnly() throws {
        let f = try makeFixture()
        let job = try claimJob(f, fingerprint: "d")
        let lane = makeLane(f.db)
        let payload = try XCTUnwrap(try ActivityExerciseWindows.payload(
            day: job.day, dayBounds: (dayStart, dayEnd), device: job.deviceId, inputRevision: job.inputRevision,
            collector: collector(start: dayStart + 12 * 3_600), stage: try XCTUnwrap(lane.exercise)))
        _ = try ActivityExerciseWindows.publish(db: f.db, token: job.leaseToken, revision: job.inputRevision,
                                                payload: payload.text)
        XCTAssertEqual(try count(f), 57)
        // 2026-09-15 is within 3650 days and older than one day.
        XCTAssertGreaterThanOrEqual(try ActivityExerciseWindows.prune(db: f.db, keepDays: 3650), 0)
        XCTAssertEqual(try count(f), 57, "inside the retention: kept")
        XCTAssertGreaterThanOrEqual(try ActivityExerciseWindows.prune(db: f.db, keepDays: 1, maxRows: 1_000_000), 57)
        XCTAssertEqual(try count(f), 0)
    }
}
