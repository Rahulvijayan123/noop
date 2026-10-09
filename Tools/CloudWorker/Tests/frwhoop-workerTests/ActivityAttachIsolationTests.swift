import XCTest
@testable import frwhoop_worker

/// The activity attach reads run inside scoring's fenced REPEATABLE READ transaction. If the
/// activity tables are missing or unreadable (deploy order, grants), a failed read must not
/// abort that transaction and with it the day's score.
///
/// These need a scratch Postgres: set FRWHOOP_TEST_DB_URL, e.g.
/// postgresql://user@localhost:5432/scratch (skipped otherwise). Nothing is written; every test
/// runs inside a transaction that is rolled back.
final class ActivityAttachIsolationTests: XCTestCase {

    private func client() throws -> PostgresClient {
        guard let url = ProcessInfo.processInfo.environment["FRWHOOP_TEST_DB_URL"], !url.isEmpty else {
            throw XCTSkip("set FRWHOOP_TEST_DB_URL to a scratch Postgres to run the savepoint tests")
        }
        return try PostgresClient(options: PostgresOptions(
            connectionString: url, sslMode: "disable", sslRootCert: nil,
            applicationName: "frwhoop-worker-tests", allowInsecure: true,
            connectTimeoutSeconds: 5, reconnectDeadlineSeconds: 5,
            statementTimeoutMS: 10_000, idleTransactionTimeoutMS: 30_000))
    }

    /// Makes `public.activity_context_epochs` unreadable inside the open (rolled back) transaction,
    /// whether or not the activity migration has been applied to the scratch database.
    private func hideActivityEpochs(_ db: PostgresClient) throws {
        try db.exec("""
            do $$ begin
              if to_regclass('public.activity_context_epochs') is not null then
                alter table public.activity_context_epochs rename to activity_context_epochs_hidden;
              end if;
            end $$
            """)
    }

    private let dayStart = 1_789_430_400
    private let uuid = "00000000-0000-4000-8000-000000000001"

    func testAnUnguardedFailedReadAbortsTheTransaction() throws {
        let db = try client()
        try db.beginTransaction(.repeatableRead)
        defer { db.rollbackTransaction() }
        try hideActivityEpochs(db)

        XCTAssertThrowsError(try db.query("select 1 from public.activity_context_epochs", []))
        XCTAssertThrowsError(try db.query("select 1 as one", [])) { error in
            XCTAssertEqual((error as? PostgresClient.Error)?.kind, .aborted,
                           "this is the failure the savepoint guard exists to prevent")
        }
    }

    func testIsolatedFailedReadLeavesTheTransactionUsable() throws {
        let db = try client()
        try db.beginTransaction(.repeatableRead)
        defer { db.rollbackTransaction() }
        try hideActivityEpochs(db)

        XCTAssertThrowsError(try db.isolatingFailures {
            try db.query("select 1 from public.activity_context_epochs", [])
        })
        XCTAssertTrue(db.isInTransaction)
        XCTAssertEqual(try db.query("select 1 as one", []).first?["one"], "1")
    }

    func testIsolatedSuccessfulReadStillReturnsRows() throws {
        let db = try client()
        try db.beginTransaction(.repeatableRead)
        defer { db.rollbackTransaction() }

        let rows = try db.isolatingFailures { try db.query("select 41 + 1 as answer", []) }
        XCTAssertEqual(rows.first?["answer"], "42")
        XCTAssertEqual(try db.query("select 1 as one", []).first?["one"], "1")
    }

    func testIsolatingFailuresOutsideATransactionJustRuns() throws {
        let db = try client()
        XCTAssertFalse(db.isInTransaction)
        XCTAssertThrowsError(try db.isolatingFailures {
            try db.query("select 1 from public.table_that_does_not_exist_anywhere", [])
        })
        XCTAssertEqual(try db.query("select 1 as one", []).first?["one"], "1")
    }

    func testAttachWithUnreadableActivityTablesLeavesScoringTransactionUsable() throws {
        let db = try client()
        try db.beginTransaction(.repeatableRead)
        defer { db.rollbackTransaction() }
        try hideActivityEpochs(db)

        var daily: [String: Any] = ["steps": 1234]
        DayScorer.attachActivityContext(to: &daily, db: db, userId: uuid, deviceId: uuid,
                                        day: "2026-09-15",
                                        dayStart: dayStart, dayEnd: dayStart + 86_400)

        XCTAssertNil(daily["activity_context"], "absent key == old behaviour")
        XCTAssertEqual(daily["steps"] as? Int, 1234, "the rest of the snapshot is untouched")
        XCTAssertTrue(db.isInTransaction)
        XCTAssertEqual(try db.query("select 1 as one", []).first?["one"], "1",
                       "the scoring transaction must still accept statements")
    }

    /// Stream days share `activity_context_jobs` with the raw-IMU jobs and count revisions of their own. The
    /// document scoring attaches names the revision of the job that produced its epochs, whatever a stream
    /// day's number happens to be.
    func testAttachNamesTheRawImuJobsRevisionEvenWhenAStreamDayJobIsHigher() throws {
        let db = try client()
        try db.beginTransaction(.repeatableRead)
        defer { db.rollbackTransaction() }
        let ready = try db.query("select to_regclass('public.activity_context_jobs') is not null as ok", [])
        guard ready.first?["ok"] == "t" else {
            throw XCTSkip("apply the activity migrations to the scratch database")
        }
        let user = "00000000-0000-4000-8000-0000000000a1"
        let device = "00000000-0000-4000-8000-0000000000a2"
        try db.exec("insert into auth.users(id) values ('\(user)')")
        try db.exec("insert into public.devices(id,user_id,source_kind) values ('\(device)','\(user)','noop_push')")
        let fingerprint = String(repeating: "c", count: 64)
        _ = try db.query("""
            insert into public.activity_context_jobs(user_id,device_id,day,algorithm_version,fingerprint,
                                                     input_revision,completed_revision)
            values ($1::uuid,$2::uuid,'2026-09-15','hart-activity-1',$3,3,3),
                   ($1::uuid,$2::uuid,'2026-09-15','streams-activity-1',$3,9,9)
            """, [user, device, fingerprint])
        _ = try db.query("""
            insert into public.activity_context_epochs(user_id,device_id,day,start_ts,end_ts,motion_label,
                confidence,observed_s,valid_s,model_version,preprocessing_version,ontology_version,
                fingerprint,result_revision,computed_at)
            values ($1::uuid,$2::uuid,'2026-09-15',$4::bigint,$4::bigint + 30,'walking',0.8,30,30,
                    'hart-wisdm-v0','hart-activity-preprocess-v1','v1',$3,1,now())
            """, [user, device, fingerprint, String(dayStart + 3_600)])

        var daily: [String: Any] = [:]
        DayScorer.attachActivityContext(to: &daily, db: db, userId: user, deviceId: device,
                                        day: "2026-09-15",
                                        dayStart: dayStart, dayEnd: dayStart + 86_400)

        let document = try XCTUnwrap(daily["activity_context"] as? [String: Any])
        XCTAssertEqual((document["input_revision"] as? NSNumber)?.int64Value, 3)
    }

    /// A Los Angeles local day [07:00Z D, 07:00Z D+1) is published by two UTC-day jobs, each with its own
    /// revision. Scoring must read the newest publish of EACH UTC day, clipped to the local window, and never
    /// an older lineage of a day (audit D5-01 / D3V-01 / D6-V01). The old reader kept only the single highest
    /// revision in the window, so UTC day D (the local morning and afternoon) vanished.
    func testLocalDayReadsTheNewestPublishOfEveryOverlappingUtcDay() throws {
        let db = try client()
        try db.beginTransaction(.repeatableRead)
        defer { db.rollbackTransaction() }
        let ready = try db.query("select to_regclass('public.activity_context_jobs') is not null as ok", [])
        guard ready.first?["ok"] == "t" else {
            throw XCTSkip("apply the activity migrations to the scratch database")
        }
        let user = "00000000-0000-4000-8000-0000000000b1"
        let device = "00000000-0000-4000-8000-0000000000b2"
        try db.exec("insert into auth.users(id) values ('\(user)')")
        try db.exec("insert into public.devices(id,user_id,source_kind) values ('\(device)','\(user)','noop_push')")
        let utcD = 1_791_244_800          // 2026-10-06T00:00Z
        let utcD1 = utcD + 86_400         // 2026-10-07T00:00Z
        let localStart = utcD + 7 * 3600  // 2026-10-06 00:00 PDT
        let localEnd = localStart + 86_400
        let fpOld = String(repeating: "a", count: 64)
        let fpD = String(repeating: "b", count: 64)
        let fpD1 = String(repeating: "c", count: 64)
        _ = try db.query("""
            insert into public.activity_context_jobs(user_id,device_id,day,algorithm_version,fingerprint,
                                                     input_revision,completed_revision)
            values ($1::uuid,$2::uuid,'2026-10-06','hart-activity-1',$3,5,5),
                   ($1::uuid,$2::uuid,'2026-10-07','hart-activity-1',$4,7,7),
                   ($1::uuid,$2::uuid,'2026-10-06','streams-activity-1',$4,40,40)
            """, [user, device, fpD, fpD1])
        func epoch(_ day: String, _ start: Int, _ fp: String, _ rev: Int, _ label: String) throws {
            _ = try db.query("""
                insert into public.activity_context_epochs(user_id,device_id,day,start_ts,end_ts,motion_label,
                    confidence,observed_s,valid_s,model_version,preprocessing_version,ontology_version,
                    fingerprint,result_revision,computed_at)
                values ($1::uuid,$2::uuid,$3::date,$4::bigint,$4::bigint + 30,$5,0.8,30,30,
                        'hart-wisdm-v0','hart-activity-preprocess-v1','v1',$6,$7::bigint,now())
                """, [user, device, day, String(start), label, fp, String(rev)])
        }
        // UTC day D: an older lineage (rev 10) with a slot the newest publish (rev 20) left out, plus a slot
        // before the local window.
        try epoch("2026-10-06", utcD + 20 * 3600, fpOld, 10, "running")
        try epoch("2026-10-06", utcD + 8 * 3600, fpOld, 10, "running")
        try epoch("2026-10-06", utcD + 3 * 3600, fpD, 20, "walking")
        try epoch("2026-10-06", utcD + 8 * 3600, fpD, 20, "stationary")
        try epoch("2026-10-06", utcD + 12 * 3600, fpD, 20, "walking")
        try epoch("2026-10-06", utcD1 - 30, fpD, 20, "stationary")
        // UTC day D+1 (rev 30, the higher revision): the local evening, plus a slot past the window.
        try epoch("2026-10-07", utcD1, fpD1, 30, "walking")
        try epoch("2026-10-07", localEnd - 30, fpD1, 30, "stationary")
        try epoch("2026-10-07", localEnd + 3600, fpD1, 30, "walking")

        let published = DayScorer.readPublishedActivityEpochs(
            db: db, userId: user, deviceId: device, day: "2026-10-06",
            dayStart: localStart, dayEnd: localEnd)
        XCTAssertEqual(published.epochs.map(\.startTs),
                       [utcD + 8 * 3600, utcD + 12 * 3600, utcD1 - 30, utcD1, localEnd - 30],
                       "both UTC days' newest publishes, clipped to the local window, nothing from rev 10")
        XCTAssertEqual(published.epochs.first?.motion, .stationary, "rev 20 wins its own day")
        XCTAssertEqual(published.lineages.map(\.day), ["2026-10-06", "2026-10-07"])
        XCTAssertEqual(published.lineages.map(\.resultRevision), [20, 30])
        XCTAssertEqual(published.lineages.map(\.epochs), [3, 2])
        XCTAssertEqual(published.epochs.reduce(0) { $0 + ($1.endTs - $1.startTs) }, 5 * 30,
                       "covered seconds are the sum of both days, one epoch per slot")

        var daily: [String: Any] = [:]
        DayScorer.attachActivityContext(to: &daily, db: db, userId: user, deviceId: device,
                                        day: "2026-10-06", dayStart: localStart, dayEnd: localEnd,
                                        published: published)
        let document = try XCTUnwrap(daily["activity_context"] as? [String: Any])
        XCTAssertEqual((document["epochs"] as? [Any])?.count, 5)
        XCTAssertEqual((document["input_revision"] as? NSNumber)?.int64Value, 7,
                       "the raw-IMU jobs of the epochs' UTC days, never the stream-day job")
        let lineages = try XCTUnwrap(document["lineages"] as? [[String: Any]])
        XCTAssertEqual(lineages.compactMap { $0["day"] as? String }, ["2026-10-06", "2026-10-07"])
        XCTAssertEqual(lineages.compactMap { ($0["input_revision"] as? NSNumber)?.int64Value }, [5, 7])
        XCTAssertEqual(lineages.compactMap { $0["fingerprint"] as? String }, [fpD, fpD1])
    }
}
