import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The Inertia shadow row against a real Postgres: written by `publish_activity_motion_heads_day` inside the
/// same transaction as the unchanged v2 day document and v1 publish, under its own savepoint.
///
/// Needs a scratch Postgres with the activity migrations and `20261005170000_activity_motion_heads.sql`
/// applied: set FRWHOOP_TEST_DB_URL (skipped otherwise, and skipped when the table is missing). Every test
/// makes its own user and device and deletes them afterwards.
final class ActivityMotionHeadsDatabaseTests: XCTestCase {

    private let dayStart = 1_789_430_400          // 2026-09-15 00:00:00 UTC
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"
    private let model = "hart-activity-1"
    private let preprocessing = "activity-preprocess-1"

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
            "select (to_regclass('public.activity_motion_heads_days') is not null "
            + "and to_regclass('public.activity_context_days') is not null) as present", [])
        guard present.first?["present"] == "t" else {
            throw XCTSkip("apply 20261005170000_activity_motion_heads.sql (and the activity migrations) to the scratch database")
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

    /// A synthetic `motion-heads-1` day (a real-encoder claim, so candidate mode can decode with it).
    private func collector(start: Int) -> MotionHeadsCollector {
        func spec(_ head: MotionHead) -> MotionHeadSpec {
            let classes = head.classOrder
            var prior: [String: Double] = [:]
            for c in classes { prior[c] = head.isCategorical ? 1 / Double(classes.count) : 0.05 }
            return MotionHeadSpec(classOrder: classes, prior: prior,
                                  status: Dictionary(uniqueKeysWithValues: classes.map { ($0, .strong) }),
                                  tau: Dictionary(uniqueKeysWithValues: classes.map { ($0, 0.8) }))
        }
        let bundle = MotionHeadsBundleInfo(
            encoderId: "inertia-1/ar_transformer-small/30s@20hz", encoderKind: .inertia1, encoderVersion: "test-1",
            checkpointSha256: String(repeating: "cd", count: 32), headsVersion: "db-test-bundle-1",
            bundleSha256: String(repeating: "ab", count: 32), evidenceTierMax: .candidate, windowS: 30, hopS: 5,
            heads: [.posture: spec(.posture), .locomotion: spec(.locomotion), .armBehavior: spec(.armBehavior)],
            ood: MotionHeadsOODInfo(method: "knn", threshold: 1.2))
        let loco = MotionHead.locomotion.classOrder
        let windows = stride(from: start, to: start + 540, by: 5).map { s in
            MotionHeadsWindow(startTs: s, endTs: s + 30,
                              posture: Dictionary(uniqueKeysWithValues: MotionHead.posture.classOrder.map { ($0, 0.25) }),
                              locomotion: Dictionary(uniqueKeysWithValues: loco.map { ($0, $0 == "stationary" ? 0.65 : 0.05) }),
                              movementIntensity: 0.2, oodScore: 0.3, isOOD: s % 60 == 0)
        }
        var c = MotionHeadsCollector()
        c.responses = [MotionHeadsResponse(bundle: bundle, windows: windows)]
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
        let shadow = try XCTUnwrap(try ActivityMotionHeadsDays.payload(
            day: job.day, mode: .shadow, collector: collector(start: dayStart + 12 * 3_600), candidate: .notRequested,
            attachment: MotionHeadsTrackReport()))
        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                            dayDocument: built, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            motionHeads: shadow)
        XCTAssertTrue(published)
        XCTAssertEqual(lane.stats.inertiaShadowStored, 1)
        XCTAssertEqual(lane.stats.inertiaShadowFailures, 0, lane.stats.lastInertiaShadowError ?? "")
        XCTAssertEqual(lane.stats.contextDaysPublished, 1)
        XCTAssertEqual(try count(f, "activity_motion_heads_days"), 1)
        XCTAssertEqual(try count(f, "activity_context_days"), 1)
        XCTAssertGreaterThan(try count(f, "activity_context_epochs"), 0)
        let row = try XCTUnwrap(try f.db.query("""
            select mode, bundle_id, encoder_kind, n_windows::text, n_ood::text, input_revision::text,
                   jsonb_array_length(windows->'ds')::text as w, windows->>'format' as format,
                   (candidate_document is null)::text as no_doc,
                   (summary->'track_report' is not null)::text as has_report
            from public.activity_motion_heads_days where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device]).first)
        XCTAssertEqual(row["mode"], "shadow")
        XCTAssertEqual(row["bundle_id"], "db-test-bundle-1")
        XCTAssertEqual(row["encoder_kind"], "inertia1")
        XCTAssertEqual(row["n_windows"], "108")
        XCTAssertEqual(row["n_ood"], "9")
        XCTAssertEqual(row["w"], "108")
        XCTAssertEqual(row["format"], "mh-col-1")
        XCTAssertEqual(row["no_doc"], "true")
        XCTAssertEqual(row["has_report"], "true")
        XCTAssertEqual(row["input_revision"], String(job.inputRevision))
        // The stored v2 document is exactly the payload the lane built: the shadow row never touched it.
        let stored = try XCTUnwrap(try f.db.query("""
            select (document = ($3::jsonb)->'document')::text as same, (document->'versions' ? 'motion_heads')::text as stamped
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
                                            motionHeads: "{\"day\":\"\(day)\",\"schema\":\"motion-heads-0\"}")
        XCTAssertTrue(published, "v1 publishes regardless")
        XCTAssertEqual(lane.stats.contextDaysPublished, 1, "and so does v2")
        XCTAssertEqual(lane.stats.inertiaShadowStored, 0)
        XCTAssertEqual(lane.stats.inertiaShadowFailures, 1)
        XCTAssertTrue(lane.stats.lastInertiaShadowError?.contains("invalid_motion_heads") == true,
                      lane.stats.lastInertiaShadowError ?? "nil")
        XCTAssertEqual(try count(f, "activity_motion_heads_days"), 0)
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
        try db.exec("drop function public.publish_activity_motion_heads_day(uuid, bigint, jsonb)")
        let outcome = try ActivityMotionHeadsDays.publish(db: db, token: job.leaseToken, revision: job.inputRevision,
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
        let heads = try XCTUnwrap(collector(start: dayStart + 12 * 3_600).trackInput)
        let candidate = ActivityMotionHeadsDays.candidate(mode: .candidate, heads: heads, input: context.input,
                                                         generatedAt: context.generatedAt,
                                                         expectedBundleSHA256: String(repeating: "ab", count: 32))
        guard case .document = candidate else { return XCTFail("expected a comparison document, got \(candidate)") }
        let payload = try XCTUnwrap(try ActivityMotionHeadsDays.payload(
            day: job.day, mode: .candidate, collector: collector(start: dayStart + 12 * 3_600), candidate: candidate))
        XCTAssertTrue(try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                          dayDocument: context.built, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                          motionHeads: payload))
        XCTAssertEqual(lane.stats.inertiaShadowStored, 1, lane.stats.lastInertiaShadowError ?? "")
        let row = try XCTUnwrap(try f.db.query("""
            select mode, (candidate_document->'versions'->>'motion_heads') as stamp, withheld_reason
            from public.activity_motion_heads_days where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device]).first)
        XCTAssertEqual(row["mode"], "candidate")
        XCTAssertTrue(row["stamp"]?.hasPrefix("inertia-1:") ?? false, row["stamp"] ?? "nil")
        XCTAssertEqual(try f.db.query("""
            select count(*)::text as n from public.activity_context_days
            where user_id=$1::uuid and device_id=$2::uuid and document->'versions' ? 'motion_heads'
            """, [f.user, f.device]).first?["n"], "0", "the published document never carries Inertia evidence")
    }

    // MARK: - Audit fixes

    /// W-7: a shadow row the fenced RPC refuses (the lease moved on) is counted, and nothing is written.
    func testAFencedShadowRowIsCounted() throws {
        let f = try makeFixture()
        let s = sim()
        var job = try claimJob(f, fingerprint: "e")
        var lane = makeLane(f.db)
        let shadow = try XCTUnwrap(try ActivityMotionHeadsDays.payload(
            day: job.day, mode: .shadow, collector: collector(start: dayStart + 12 * 3_600), candidate: .notRequested))
        job.leaseToken = UUID().uuidString.lowercased()          // a token the queue does not know: fenced
        let published = try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                            dayDocument: nil, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                            motionHeads: shadow)
        XCTAssertFalse(published)
        XCTAssertEqual(lane.stats.inertiaShadowFenced, 1)
        XCTAssertEqual(lane.stats.inertiaShadowStored, 0)
        XCTAssertEqual(lane.stats.inertiaShadowFailures, 0, "fenced is not a failure")
        XCTAssertEqual(try count(f, "activity_motion_heads_days"), 0)
    }

    /// G-15: the table itself refuses a candidate document from anything but a real Inertia-1 candidate row.
    func testACandidateDocumentNeedsARealInertiaEncoderAtTheTableLevel() throws {
        let f = try makeFixture()
        let job = try claimJob(f, fingerprint: "f")
        // Through the RPC: a stand-in bundle with a comparison document is refused with a stable message.
        let heads = try XCTUnwrap(collector(start: dayStart + 12 * 3_600).trackInput)
        var standIn = heads.bundle
        standIn.encoderKind = .standin
        standIn.encoderId = "standin:handcrafted-stats-v1"
        standIn.checkpointSha256 = nil
        var c = MotionHeadsCollector()
        c.responses = [MotionHeadsResponse(bundle: standIn, windows: heads.windows)]
        let doc = ActivityContextDays.dayDocument(input: ActivityContextTrackInput(dayStart: dayStart, dayEnd: dayEnd),
                                                  generatedAt: 1)
        var stamped = doc
        stamped.versions.motionHeads = "standin-test:abababababab:01234567"
        let payload = try XCTUnwrap(try ActivityMotionHeadsDays.payload(day: job.day, mode: .candidate, collector: c,
                                                                        candidate: .document(stamped, nil)))
        let outcome = try ActivityMotionHeadsDays.publish(db: f.db, token: job.leaseToken, revision: job.inputRevision,
                                                         payload: payload)
        guard case .rejected(let why) = outcome else { return XCTFail("expected a rejection, got \(outcome)") }
        XCTAssertTrue(why.contains("invalid_motion_heads_candidate"), why)
        // Directly into the table (service role bypassing the RPC): the CHECK refuses it too.
        XCTAssertThrowsError(try f.db.exec("""
            insert into public.activity_motion_heads_days(user_id, device_id, day, bundle_id, mode, algorithm_version,
              encoder_id, encoder_kind, encoder_version, checkpoint_sha256, bundle_sha256, preprocessing_version,
              heads_schema, evidence_tier_max, job_fingerprint, input_revision, window_s, hop_s, n_windows, n_ood,
              n_dropped, withheld_reason, summary, windows, candidate_document, result_revision, computed_at)
            values ('\(f.user)', '\(f.device)', '\(day)', 'x', 'candidate', 'hart-activity-1',
              'standin:handcrafted-stats-v1', 'standin', 'v', null, repeat('a', 64), 'inertia-prep-1',
              'motion-heads-1', 'shadow', repeat('b', 64), 1, 30, 5, 0, 0, 0, null, '{}'::jsonb, null,
              '{"versions": {"motion_heads": "x"}, "runs": []}'::jsonb, 1, now())
            """)) { error in
            XCTAssertTrue(String(describing: error).contains("check"), "\(error)")
        }
        XCTAssertEqual(try count(f, "activity_motion_heads_days"), 0)
    }

    /// W-6: retention. Rows computed more than 30 days ago are deleted (in bounded batches); newer rows stay;
    /// the lane calls it on its own cadence while Inertia is on.
    func testRetentionPrunesOnlyOldRowsOnTheLaneCadence() throws {
        let f = try makeFixture()
        let job = try claimJob(f, fingerprint: "9")
        let payload = try XCTUnwrap(try ActivityMotionHeadsDays.payload(
            day: job.day, mode: .shadow, collector: collector(start: dayStart + 12 * 3_600), candidate: .notRequested))
        guard case .stored = try ActivityMotionHeadsDays.publish(db: f.db, token: job.leaseToken,
                                                                 revision: job.inputRevision, payload: payload) else {
            return XCTFail("the shadow row must publish")
        }
        XCTAssertEqual(try count(f, "activity_motion_heads_days"), 1)
        // Fresh: kept.
        _ = try ActivityMotionHeadsDays.prune(db: f.db)
        XCTAssertEqual(try count(f, "activity_motion_heads_days"), 1)
        // Age it past the retention window: the next prune removes it (and only this fixture's row is touched).
        try f.db.exec("update public.activity_motion_heads_days set computed_at = now() - interval '31 days' "
                      + "where user_id = '\(f.user)'")
        var lane = makeLane(f.db)
        lane.inertia = InertiaStage(service: ActivityPythonService(config: ActivityPythonService.Config(
            pythonBin: "/usr/bin/python3", activityHome: FileManager.default.currentDirectoryPath, modelDir: nil,
            serveArgs: [], requestTimeoutSeconds: 1, maxRequestBytes: 1_024, maxResponseLineBytes: 1_024,
            restartCap: 1, restartCooldownSeconds: 1)), mode: .shadow)
        let now = Date()
        lane.pruneMotionHeadsIfDue(now: now)
        XCTAssertEqual(lane.stats.inertiaPruneFailures, 0, lane.stats.lastInertiaPruneError ?? "")
        XCTAssertGreaterThanOrEqual(lane.stats.inertiaRowsPruned, 1)
        XCTAssertEqual(try count(f, "activity_motion_heads_days"), 0)
        // Throttled: a second call inside the interval does not run.
        lane.lastMotionHeadsPruneAt = now
        let before = lane.stats.inertiaRowsPruned
        lane.pruneMotionHeadsIfDue(now: now.addingTimeInterval(60))
        XCTAssertEqual(lane.stats.inertiaRowsPruned, before)
        XCTAssertEqual(lane.lastMotionHeadsPruneAt, now)
        // Bad arguments are refused by the function, not interpreted.
        XCTAssertThrowsError(try ActivityMotionHeadsDays.prune(db: f.db, keepDays: 0))
        XCTAssertThrowsError(try ActivityMotionHeadsDays.prune(db: f.db, keepDays: 30, maxRows: 0))
    }
}
