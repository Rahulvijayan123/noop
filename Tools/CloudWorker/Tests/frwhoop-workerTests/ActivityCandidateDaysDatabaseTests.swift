import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import frwhoop_worker

/// The joint candidate row and the expert rows' release columns against a real Postgres: written in the same
/// transaction as the unchanged v2 day document and v1 publish, each under its own savepoint.
///
/// Needs a scratch Postgres with the activity migrations and `20261008100000_activity_release_authority.sql` applied:
/// set FRWHOOP_TEST_DB_URL (skipped otherwise, and skipped when the table is missing). Every test makes its own user
/// and device and deletes them afterwards.
final class ActivityCandidateDaysDatabaseTests: XCTestCase {

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
            "select (to_regclass('public.activity_candidate_days') is not null "
            + "and to_regclass('public.activity_gait_windows_days') is not null) as present", [])
        guard present.first?["present"] == "t" else {
            throw XCTSkip("apply 20261008100000_activity_release_authority.sql (and the activity migrations)")
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

    private func idleService() -> ActivityPythonService {
        ActivityPythonService(config: ActivityPythonService.Config(
            pythonBin: "/usr/bin/python3", activityHome: FileManager.default.currentDirectoryPath,
            modelDir: nil, serveArgs: [], requestTimeoutSeconds: 1,
            maxRequestBytes: 1_024, maxResponseLineBytes: 1_024, restartCap: 1, restartCooldownSeconds: 1))
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

    /// ElderNet in candidate mode, pinned to the synthetic model (the child is never started).
    private func makeLane(_ db: PostgresClient) -> ActivityLane {
        ActivityLane(
            db: db, storage: B2Storage(keyID: "unused", applicationKey: "unused", bucket: "unused"),
            service: idleService(), leaseSeconds: 300,
            eldernet: ElderNetStage(service: idleService(), mode: .candidate, expectedModelVersion: version,
                                    expectedWeightsDigest: gaitModel().weightsDigest, gaitPrior: 0.2))
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

    private func collector(start: Int) -> GaitQualityCollector {
        let walkFrom = start + 200, walkTo = walkFrom + 150
        let windows = stride(from: start, to: start + 540, by: 5).map { s -> GaitQualityWindow in
            if s >= walkFrom && s + 10 <= walkTo {
                return GaitQualityWindow(startTs: s, endTs: s + 10, gaitProb: 0.95, isGait: true, speedMps: 1.2,
                                         cadenceSpm: 110, strideM: 1.3, regularity: 0.8, steps: 18)
            }
            return GaitQualityWindow(startTs: s, endTs: s + 10, gaitProb: 0.1, isGait: false)
        }
        var c = GaitQualityCollector()
        c.responses = [GaitQualityResponse(model: gaitModel(), windows: windows)]
        c.chunks = 1
        return c
    }

    func testTheJointCandidateIsStoredBesideUnchangedPublishesAndTheRowsCarryTheirRelease() throws {
        let f = try makeFixture()
        let s = sim()
        let job = try claimJob(f, fingerprint: "e")
        var lane = makeLane(f.db)
        let stage = try XCTUnwrap(lane.eldernet)
        let gaitCollector = collector(start: dayStart + 12 * 3_600)
        let selection = ActivityCandidateDays.selection(day: job.day, inputRevision: job.inputRevision,
                                                        gait: gaitCollector.trackInput, eldernet: stage,
                                                        heads: nil, inertia: nil)
        XCTAssertEqual(selection.use(of: .gaitQuality), .candidate)
        let context = try lane.buildContextDayAndInput(job: job, dayBounds: (dayStart, dayEnd), windows: s.windows,
                                                       versions: (model, preprocessing), asleep: [], exercise: [],
                                                       selection: selection)
        // The published document is HART's alone (ActivityAuthorityReplayTests proves the bytes).
        XCTAssertNil(try XCTUnwrap(context.built?.document).versions.gaitQuality)
        let gaitRow = ActivityLane.gaitWindowsRow(day: job.day, eldernet: stage, collector: gaitCollector,
                                                  context: context, stats: &lane.stats)
        XCTAssertTrue(lane.storesCandidateDays)
        let candidateDay = try XCTUnwrap(ActivityLane.candidateDayPayload(
            day: job.day, inputRevision: job.inputRevision, context: context, motionCandidate: nil,
            gaitCandidate: gaitRow.candidate, stats: &lane.stats))
        XCTAssertTrue(try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                          dayDocument: context.built, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                          gaitWindows: gaitRow.payload, candidateDay: candidateDay))
        XCTAssertEqual(lane.stats.candidateDaysStored, 1, lane.stats.lastCandidateDayError ?? "")
        XCTAssertEqual(lane.stats.eldernetShadowStored, 1, lane.stats.lastElderNetShadowError ?? "")

        let candidate = try XCTUnwrap(try f.db.query("""
            select policy, selection_digest, input_revision::text as rev, withheld_reason,
                   joint_document->'versions'->>'gait_quality' as stamp,
                   (select string_agg(k, ',' order by k) from jsonb_object_keys(arms) k) as arms
            from public.activity_candidate_days where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device]).first)
        XCTAssertEqual(candidate["policy"], ActivityExpertSelection.policy)
        XCTAssertEqual(candidate["selection_digest"], selection.digest)
        XCTAssertEqual(candidate["rev"], String(job.inputRevision))
        XCTAssertTrue(candidate["stamp"]?.hasPrefix("eldernet:\(version):") ?? false, candidate["stamp"] ?? "nil")
        XCTAssertEqual(candidate["arms"], "hart,hart+gait_quality,joint")

        let gait = try XCTUnwrap(try f.db.query("""
            select mode, release_mode, authority->>'use' as use, authority->>'input_revision' as rev,
                   authority->>'pinned_weights_digest' as pin
            from public.activity_gait_windows_days where user_id=$1::uuid and device_id=$2::uuid
            """, [f.user, f.device]).first)
        XCTAssertEqual(gait["mode"], "candidate")
        XCTAssertEqual(gait["release_mode"], "candidate")
        XCTAssertEqual(gait["use"], "candidate")
        XCTAssertEqual(gait["rev"], String(job.inputRevision))
        XCTAssertEqual(gait["pin"], gaitModel().weightsDigest)
        XCTAssertEqual(try f.db.query("""
            select count(*)::text as n from public.activity_context_days
            where user_id=$1::uuid and device_id=$2::uuid and document->'versions' ? 'gait_quality'
            """, [f.user, f.device]).first?["n"], "0", "the published document never carries ElderNet evidence")
    }

    /// A shadow-only lane stores no joint candidate, and its expert row reads as shadow.
    func testShadowModeStoresNoCandidateDay() throws {
        let f = try makeFixture()
        var lane = ActivityLane(
            db: f.db, storage: B2Storage(keyID: "unused", applicationKey: "unused", bucket: "unused"),
            service: idleService(), leaseSeconds: 300,
            eldernet: ElderNetStage(service: idleService(), mode: .shadow))
        XCTAssertFalse(lane.storesCandidateDays)
        let s = sim()
        let job = try claimJob(f, fingerprint: "f")
        let stage = try XCTUnwrap(lane.eldernet)
        let gaitCollector = collector(start: dayStart + 12 * 3_600)
        let selection = ActivityCandidateDays.selection(day: job.day, inputRevision: job.inputRevision,
                                                        gait: gaitCollector.trackInput, eldernet: stage,
                                                        heads: nil, inertia: nil)
        let context = try lane.buildContextDayAndInput(job: job, dayBounds: (dayStart, dayEnd), windows: s.windows,
                                                       versions: (model, preprocessing), asleep: [], exercise: [],
                                                       selection: selection)
        let gaitRow = ActivityLane.gaitWindowsRow(day: job.day, eldernet: stage, collector: gaitCollector,
                                                  context: context, stats: &lane.stats)
        XCTAssertTrue(try lane.publishDay(job: job, payloadText: try v1Payload(job, windows: s.windows, dataThrough: s.ts),
                                          dayDocument: context.built, durationMS: 5, dayBounds: (dayStart, dayEnd),
                                          gaitWindows: gaitRow.payload))
        XCTAssertEqual(try f.db.query("select release_mode, authority->>'use' as use from public.activity_gait_windows_days "
                                      + "where user_id=$1::uuid", [f.user]).first?["release_mode"], "shadow")
        XCTAssertEqual(try f.db.query("select count(*)::text as n from public.activity_candidate_days where user_id=$1::uuid",
                                      [f.user]).first?["n"], "0")
    }
}
