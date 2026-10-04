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
}
