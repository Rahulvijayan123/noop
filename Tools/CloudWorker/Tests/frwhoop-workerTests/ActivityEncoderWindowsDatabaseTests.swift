import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// HART's windows against a real Postgres: the raw-IMU job stores them in `activity_encoder_windows` in the
/// same fenced transaction as the v1 epochs, and a stream day of the same UTC day decodes with them.
///
/// Needs a scratch Postgres with the activity migrations through `20261005150000_activity_encoder_windows.sql`
/// applied (FRWHOOP_TEST_DB_URL, as for `ActivityContextDaysDatabaseTests`); skipped otherwise.
final class ActivityEncoderWindowsDatabaseTests: XCTestCase {

    private let dayStart = 1_789_430_400          // 2026-09-15 00:00:00 UTC
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"

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
            "select (to_regclass('public.activity_encoder_windows') is not null) as present", [])
        guard present.first?["present"] == "t" else {
            throw XCTSkip("apply 20261005150000_activity_encoder_windows.sql to the scratch database")
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

    private func claimJob(_ f: Fixture, fingerprint letter: Character) throws -> ActivityLane.ActivityJob {
        let fp = String(repeating: letter, count: 64)
        _ = try f.db.callFunctionForJSON("""
            select public.enqueue_activity_context($1::uuid,$2::uuid,$3::date,
              array['d0000000-0000-4000-8000-0000000000d1'::uuid], array[$4::text],$4::text,
              'hart-wisdm-v0','1.0.0','v1')::text
            """, [f.user, f.device, day, fp])
        let rows = try f.db.query("select * from public.claim_activity_context_v2(300)", [])
        let job = try XCTUnwrap(ActivityLane.parseJob(try XCTUnwrap(rows.first)))
        XCTAssertEqual(job.userId, f.user, "the scratch database holds another user's activity job; use a clean one")
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

    private func midday() -> DaySim {
        var sim = DaySim(start: dayStart + 12 * 3_600)
        sim.still(240)
        sim.walk(150)
        sim.still(240)
        return sim
    }

    private func v1Payload(_ job: ActivityLane.ActivityJob, sim: DaySim) throws -> String {
        var doc = try ActivityLane.activityDocument(
            windows: sim.windows, sleepIntervals: [], exerciseIntervals: [],
            dayStart: dayStart, dayEnd: dayEnd, inputRevision: job.inputRevision,
            modelVersion: "hart-wisdm-v0", preprocessingVersion: "1.0.0", dataThrough: sim.ts)
        return try ActivityLane.dayStampedJSONText(doc: &doc, day: job.day)
    }

    private func windowsPayload(_ sim: DaySim) throws -> String {
        let set = ActivityEncoderWindowsStore.windowSet(windows: sim.windows, dayStart: dayStart, dayEnd: dayEnd,
                                                        modelVersion: "hart-wisdm-v0")
        return try ActivityEncoderWindowsStore.payload(set: set, day: day, dayStart: dayStart,
                                                       preprocessingVersion: "1.0.0")
    }

    func testTheJobStoresItsWindowsAndAStreamDayDecodesWithThem() throws {
        let f = try makeFixture()
        let sim = midday()
        XCTAssertFalse(sim.windows.isEmpty)
        let job = try claimJob(f, fingerprint: "a")
        var lane = makeLane(f.db)

        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, sim: sim), dayDocument: nil,
                                            durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            windowsPayload: try windowsPayload(sim))
        XCTAssertTrue(published)
        XCTAssertEqual(lane.stats.windowSetsPublished, 1)
        XCTAssertEqual(lane.stats.windowSetFailures, 0, lane.stats.lastWindowSetError ?? "")

        let row = try XCTUnwrap(try f.db.query("""
            select encoder_id, model_version, preprocessing_version, feature_schema, window_count::text,
                   input_revision::text
            from public.activity_encoder_windows where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device]).first)
        XCTAssertEqual(row["encoder_id"], "hart")
        XCTAssertEqual(row["model_version"], "hart-wisdm-v0")
        XCTAssertEqual(row["preprocessing_version"], "1.0.0")
        XCTAssertEqual(row["feature_schema"], ActivityContextVersions.featureSchema)
        XCTAssertEqual(row["window_count"], String(sim.windows.count))
        XCTAssertEqual(row["input_revision"], String(job.inputRevision))

        // Read back exactly as the stream days read it.
        let stored = try XCTUnwrap(try ActivityEncoderWindowsStore.load(db: f.db, userId: f.user,
                                                                        deviceId: f.device, day: day))
        XCTAssertEqual(stored.encoderId, "hart")
        XCTAssertEqual(stored.windows.map(\.endTs), sim.windows.map { Int($0.end) })
        XCTAssertEqual(stored.windows.map(\.label.rawValue), sim.windows.map(\.label))
        XCTAssertEqual(stored.features.count, sim.windows.count)

        let withHart = try XCTUnwrap(try ActivityContextDays.buildStreamDay(
            day: day, dayBounds: (dayStart, dayEnd), streams: sim.streams, sleep: [], exercise: [],
            now: dayEnd + 86_400, encoder: stored))
        let without = try XCTUnwrap(try ActivityContextDays.buildStreamDay(
            day: day, dayBounds: (dayStart, dayEnd), streams: sim.streams, sleep: [], exercise: [],
            now: dayEnd + 86_400))
        XCTAssertTrue(withHart.payloadText.contains("\"encoder\":\"hart\""), "the stream day names its encoder")
        XCTAssertFalse(without.payloadText.contains("\"encoder\":\"hart\""))
    }

    func testAFencedJobStoresNoWindows() throws {
        let f = try makeFixture()
        let sim = midday()
        let job = try claimJob(f, fingerprint: "b")
        var stale = job
        stale.inputRevision += 1
        var lane = makeLane(f.db)
        let published = try lane.publishDay(job: stale, payloadText: try v1Payload(job, sim: sim), dayDocument: nil,
                                            durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            windowsPayload: try windowsPayload(sim))
        XCTAssertFalse(published)
        XCTAssertEqual(lane.stats.windowSetsPublished, 0)
        XCTAssertNil(try ActivityEncoderWindowsStore.load(db: f.db, userId: f.user, deviceId: f.device, day: day))
    }

    func testARejectedWindowSetLeavesTheV1PublishIntact() throws {
        let f = try makeFixture()
        let sim = midday()
        let job = try claimJob(f, fingerprint: "c")
        var lane = makeLane(f.db)
        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, sim: sim), dayDocument: nil,
                                            durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            windowsPayload: #"{"day":"2026-09-15","windows":{"format":"nope"}}"#)
        XCTAssertTrue(published, "the window set is best effort")
        XCTAssertEqual(lane.stats.windowSetFailures, 1)
        XCTAssertEqual(lane.stats.windowSetsPublished, 0)
        let completed = try f.db.query("""
            select completed_revision::text as c from public.activity_context_jobs
            where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device]).first?["c"]
        XCTAssertEqual(completed, String(job.inputRevision))
    }
}
