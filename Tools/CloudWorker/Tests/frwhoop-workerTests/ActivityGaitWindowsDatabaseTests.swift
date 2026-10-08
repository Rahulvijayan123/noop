import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The ElderNet shadow row against a real Postgres: written by `publish_activity_gait_windows_day` inside the same
/// transaction as the unchanged v2 day document and v1 publish, under its own savepoint.
///
/// Needs a scratch Postgres with the activity migrations and `20261006090000_activity_gait_windows.sql` applied: set
/// FRWHOOP_TEST_DB_URL (skipped otherwise, and skipped when the table is missing). Every test makes its own user and
/// device and deletes them afterwards.
final class ActivityGaitWindowsDatabaseTests: XCTestCase {

    private let dayStart = 1_789_430_400          // 2026-09-15 00:00:00 UTC
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"
    private let model = "hart-activity-1"
    private let preprocessing = "activity-preprocess-1"
    private let version = "eldernet-437a38b"

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
            "select (to_regclass('public.activity_gait_windows_days') is not null "
            + "and to_regclass('public.activity_context_days') is not null) as present", [])
        guard present.first?["present"] == "t" else {
            throw XCTSkip("apply 20261006090000_activity_gait_windows.sql (and the activity migrations) to the scratch database")
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
              array['d0000000-0000-4000-8000-0000000000d1'::uuid], array[$4::text],$4::text,
              $5::text,$6::text,'v1')::text
            """, [f.user, f.device, day, fp, model, preprocessing])
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

    private func gaitModel() -> GaitQualityModelInfo {
        var weights: [String: String] = [:]
        for (i, h) in GaitQualityWire.weightNames.enumerated() { weights[h] = String(repeating: "\(i)", count: 64) }
        return GaitQualityModelInfo(modelVersion: version, weights: weights,
                                    upstreamCommit: "437a38bcc69f42717fe73c1f7dbea7e1f7a50d23", hopS: 5,
                                    calibration: ["gait_prob": GaitQualityCalibrationEntry(method: "temperature", fit: "val",
                                                                                            parameters: ["T": 1.0])],
                                    gaitThreshold: 0.5)
    }

    /// A synthetic `gait-quality-1` day: gait through the walk of `sim()`, non-gait / pre-filtered elsewhere.
    private func collector(start: Int) -> GaitQualityCollector {
        let walkFrom = start + 200, walkTo = walkFrom + 150
        let windows = stride(from: start, to: start + 540, by: 5).map { s -> GaitQualityWindow in
            if s >= walkFrom && s + 10 <= walkTo {
                return GaitQualityWindow(startTs: s, endTs: s + 10, gaitProb: 0.95, isGait: true, speedMps: 1.2,
                                         cadenceSpm: 110, strideM: 1.3, regularity: 0.8, steps: 18)
            }
            return s % 10 == 0 ? GaitQualityWindow(startTs: s, endTs: s + 10, gaitProb: 0, isGait: false, prefiltered: true)
                : GaitQualityWindow(startTs: s, endTs: s + 10, gaitProb: 0.1, isGait: false)
        }
        var c = GaitQualityCollector()
        c.responses = [GaitQualityResponse(model: gaitModel(), windows: windows)]
        c.chunks = 1
        return c
    }

    private func count(_ f: Fixture, _ table: String) throws -> Int {
        Int(try f.db.query("select count(*)::text as n from public.\(table) where user_id=$1::uuid and device_id=$2::uuid",
                           [f.user, f.device]).first?["n"] ?? "") ?? -1
    }

    // MARK: - Tests

    func testTheShadowRowIsStoredBesideUnchangedV1AndV2Publishes() throws {
        let f = try makeFixture()
        let s = sim()
        let job = try claimJob(f, fingerprint: "a")
        var lane = makeLane(f.db)
        let built = try XCTUnwrap(try lane.buildContextDay(job: job, dayBounds: (dayStart, dayEnd), windows: s.windows,
                                                           versions: (model, preprocessing), asleep: [], exercise: []))
        let shadow = try XCTUnwrap(try ActivityGaitWindowsDays.payload(
            day: job.day, mode: .shadow, collector: collector(start: dayStart + 12 * 3_600), candidate: .notRequested,
            attachment: GaitQualityTrackReport()))
        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                            dayDocument: built, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            gaitWindows: shadow)
        XCTAssertTrue(published)
        XCTAssertEqual(lane.stats.eldernetShadowStored, 1)
        XCTAssertEqual(lane.stats.eldernetShadowFailures, 0, lane.stats.lastElderNetShadowError ?? "")
        XCTAssertEqual(lane.stats.contextDaysPublished, 1)
        XCTAssertEqual(try count(f, "activity_gait_windows_days"), 1)
        XCTAssertEqual(try count(f, "activity_context_days"), 1)
        XCTAssertGreaterThan(try count(f, "activity_context_epochs"), 0)
        let row = try XCTUnwrap(try f.db.query("""
            select mode, model_version, weights_digest, n_windows::text, n_gait::text, n_prefiltered::text,
                   input_revision::text, jsonb_array_length(windows->'gp')::text as w, windows->>'format' as format,
                   (candidate_document is null)::text as no_doc, (summary->'track_report' is not null)::text as has_report
            from public.activity_gait_windows_days where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device]).first)
        XCTAssertEqual(row["mode"], "shadow")
        XCTAssertEqual(row["model_version"], version)
        XCTAssertEqual(row["weights_digest"], gaitModel().weightsDigest, "the SQL digest is the decoder's")
        XCTAssertEqual(row["n_windows"], "108")
        XCTAssertEqual(row["w"], "108")
        XCTAssertEqual(row["format"], "gait-windows-1")
        XCTAssertEqual(row["no_doc"], "true")
        XCTAssertEqual(row["has_report"], "true")
        XCTAssertEqual(row["input_revision"], String(job.inputRevision))
        // The stored v2 document is exactly the payload the lane built: the shadow row never touched it.
        let stored = try XCTUnwrap(try f.db.query("""
            select (document = ($3::jsonb)->'document')::text as same, (document->'versions' ? 'gait_quality')::text as stamped
            from public.activity_context_days where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device, built.payloadText]).first)
        XCTAssertEqual(stored["same"], "true")
        XCTAssertEqual(stored["stamped"], "false")
    }

    func testARejectedShadowRowNeverBlocksThePublishes() throws {
        let f = try makeFixture()
        let s = sim()
        let job = try claimJob(f, fingerprint: "b")
        var lane = makeLane(f.db)
        let built = try lane.buildContextDay(job: job, dayBounds: (dayStart, dayEnd), windows: s.windows,
                                             versions: (model, preprocessing), asleep: [], exercise: [])
        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                            dayDocument: built, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            gaitWindows: "{\"day\":\"\(day)\",\"schema\":\"gait-quality-0\"}")
        XCTAssertTrue(published, "v1 publishes regardless")
        XCTAssertEqual(lane.stats.contextDaysPublished, 1, "and so does v2")
        XCTAssertEqual(lane.stats.eldernetShadowStored, 0)
        XCTAssertEqual(lane.stats.eldernetShadowFailures, 1)
        XCTAssertTrue(lane.stats.lastElderNetShadowError?.contains("invalid_gait_windows") == true,
                      lane.stats.lastElderNetShadowError ?? "nil")
        XCTAssertEqual(try count(f, "activity_gait_windows_days"), 0)
        XCTAssertEqual(try count(f, "activity_context_days"), 1)
        XCTAssertGreaterThan(try count(f, "activity_context_epochs"), 0)
        XCTAssertFalse(f.db.isInTransaction)
    }

    func testAMissingShadowRpcOnlyCostsTheShadowRow() throws {
        let f = try makeFixture()
        let job = try claimJob(f, fingerprint: "c")
        let db = f.db
        try db.beginTransaction()
        defer { db.rollbackTransaction() }
        try db.exec("drop function public.publish_activity_gait_windows_day(uuid, bigint, jsonb)")
        let outcome = try ActivityGaitWindowsDays.publish(db: db, token: job.leaseToken, revision: job.inputRevision,
                                                          payload: "{}")
        guard case .rejected(let why) = outcome else { return XCTFail("expected a rejection, got \(outcome)") }
        XCTAssertTrue(why.contains("does not exist"), why)
        XCTAssertTrue(db.isInTransaction)
        XCTAssertEqual(try db.query("select 1 as one", []).first?["one"], "1",
                       "the transaction that carries the publishes must still accept statements")
    }

    func testACandidateComparisonIsStoredOnlyInTheShadowTable() throws {
        let f = try makeFixture()
        let s = sim()
        let job = try claimJob(f, fingerprint: "d")
        var lane = makeLane(f.db)
        let context = try lane.buildContextDayAndInput(job: job, dayBounds: (dayStart, dayEnd), windows: s.windows,
                                                       versions: (model, preprocessing), asleep: [], exercise: [])
        let gait = try XCTUnwrap(collector(start: dayStart + 12 * 3_600).trackInput)
        let candidate = ActivityGaitWindowsDays.candidate(mode: .candidate, gait: gait, input: context.input,
                                                          generatedAt: context.generatedAt, expectedModelVersion: version,
                                                          expectedWeightsDigest: gaitModel().weightsDigest, gaitPrior: 0.2)
        guard case .document = candidate else { return XCTFail("expected a comparison document, got \(candidate)") }
        let payload = try XCTUnwrap(try ActivityGaitWindowsDays.payload(
            day: job.day, mode: .candidate, collector: collector(start: dayStart + 12 * 3_600), candidate: candidate,
            gaitPrior: 0.2))
        XCTAssertTrue(try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                          dayDocument: context.built, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                          gaitWindows: payload))
        XCTAssertEqual(lane.stats.eldernetShadowStored, 1, lane.stats.lastElderNetShadowError ?? "")
        let row = try XCTUnwrap(try f.db.query("""
            select mode, (candidate_document->'versions'->>'gait_quality') as stamp, withheld_reason,
                   (summary->>'gait_prior') as prior,
                   (select count(*) from jsonb_array_elements(candidate_document->'runs') r where r ? 'gait')::text as gait_runs
            from public.activity_gait_windows_days where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device]).first)
        XCTAssertEqual(row["mode"], "candidate")
        XCTAssertTrue(row["stamp"]?.hasPrefix("eldernet:\(version):") ?? false, row["stamp"] ?? "nil")
        XCTAssertEqual(row["withheld_reason"], "", "NULL (the client reads NULL as empty)")
        XCTAssertEqual(row["prior"], "0.2")
        XCTAssertGreaterThan(Int(row["gait_runs"] ?? "") ?? 0, 0, "the comparison's runs carry the reported gait block")
        XCTAssertEqual(try f.db.query("""
            select count(*)::text as n from public.activity_context_days
            where user_id=$1::uuid and device_id=$2::uuid and document->'versions' ? 'gait_quality'
            """, [f.user, f.device]).first?["n"], "0", "the published document never carries ElderNet evidence")
    }

    /// A shadow row the fenced RPC refuses (the lease moved on) is counted, and nothing is written.
    func testAFencedShadowRowIsCounted() throws {
        let f = try makeFixture()
        let s = sim()
        var job = try claimJob(f, fingerprint: "e")
        var lane = makeLane(f.db)
        let shadow = try XCTUnwrap(try ActivityGaitWindowsDays.payload(
            day: job.day, mode: .shadow, collector: collector(start: dayStart + 12 * 3_600), candidate: .notRequested))
        job.leaseToken = UUID().uuidString.lowercased()          // a token the queue does not know: fenced
        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                            dayDocument: nil, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            gaitWindows: shadow)
        XCTAssertFalse(published)
        XCTAssertEqual(lane.stats.eldernetShadowFenced, 1)
        XCTAssertEqual(lane.stats.eldernetShadowStored, 0)
        XCTAssertEqual(lane.stats.eldernetShadowFailures, 0, "fenced is not a failure")
        XCTAssertEqual(try count(f, "activity_gait_windows_days"), 0)
    }

    /// Inertia and ElderNet rows in one publish: each under its own savepoint, both stored, the v1 completion intact.
    func testInertiaAndElderNetRowsPublishTogether() throws {
        let f = try makeFixture()
        let s = sim()
        let job = try claimJob(f, fingerprint: "f")
        var lane = makeLane(f.db)
        let built = try lane.buildContextDay(job: job, dayBounds: (dayStart, dayEnd), windows: s.windows,
                                             versions: (model, preprocessing), asleep: [], exercise: [])
        let gait = try XCTUnwrap(try ActivityGaitWindowsDays.payload(
            day: job.day, mode: .shadow, collector: collector(start: dayStart + 12 * 3_600), candidate: .notRequested))
        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                            dayDocument: built, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            motionHeads: "{\"day\":\"\(day)\",\"schema\":\"motion-heads-0\"}",
                                            gaitWindows: gait)
        XCTAssertTrue(published)
        XCTAssertEqual(lane.stats.inertiaShadowFailures, 1, "a rejected Inertia row …")
        XCTAssertEqual(lane.stats.eldernetShadowStored, 1, "… never costs the ElderNet row")
        XCTAssertEqual(try count(f, "activity_gait_windows_days"), 1)
    }

    /// Retention. Rows computed more than 30 days ago are deleted (in bounded batches); newer rows stay; the lane
    /// calls it on its own cadence while ElderNet is on.
    func testRetentionPrunesOnlyOldRowsOnTheLaneCadence() throws {
        let f = try makeFixture()
        let job = try claimJob(f, fingerprint: "9")
        let payload = try XCTUnwrap(try ActivityGaitWindowsDays.payload(
            day: job.day, mode: .shadow, collector: collector(start: dayStart + 12 * 3_600), candidate: .notRequested))
        guard case .stored = try ActivityGaitWindowsDays.publish(db: f.db, token: job.leaseToken,
                                                                 revision: job.inputRevision, payload: payload) else {
            return XCTFail("the shadow row must publish")
        }
        XCTAssertEqual(try count(f, "activity_gait_windows_days"), 1)
        _ = try ActivityGaitWindowsDays.prune(db: f.db)
        XCTAssertEqual(try count(f, "activity_gait_windows_days"), 1)
        try f.db.exec("update public.activity_gait_windows_days set computed_at = now() - interval '31 days' "
                      + "where user_id = '\(f.user)'")
        var lane = makeLane(f.db)
        lane.eldernet = ElderNetStage(service: ActivityPythonService(config: ActivityPythonService.Config(
            pythonBin: "/usr/bin/python3", activityHome: FileManager.default.currentDirectoryPath, modelDir: nil,
            serveArgs: [], requestTimeoutSeconds: 1, maxRequestBytes: 1_024, maxResponseLineBytes: 1_024,
            restartCap: 1, restartCooldownSeconds: 1)), mode: .shadow)
        let now = Date()
        lane.pruneGaitWindowsIfDue(now: now)
        XCTAssertEqual(lane.stats.eldernetPruneFailures, 0, lane.stats.lastElderNetPruneError ?? "")
        XCTAssertGreaterThanOrEqual(lane.stats.eldernetRowsPruned, 1)
        XCTAssertEqual(try count(f, "activity_gait_windows_days"), 0)
        lane.lastGaitWindowsPruneAt = now
        let before = lane.stats.eldernetRowsPruned
        lane.pruneGaitWindowsIfDue(now: now.addingTimeInterval(60))
        XCTAssertEqual(lane.stats.eldernetRowsPruned, before, "throttled")
        XCTAssertThrowsError(try ActivityGaitWindowsDays.prune(db: f.db, keepDays: 0))
        XCTAssertThrowsError(try ActivityGaitWindowsDays.prune(db: f.db, keepDays: 30, maxRows: 0))
        // Without ElderNet the lane never prunes.
        var plain = makeLane(f.db)
        plain.pruneGaitWindowsIfDue(now: now)
        XCTAssertNil(plain.lastGaitWindowsPruneAt)
    }
}
