import XCTest
@testable import frwhoop_worker

/// The verification lane's heartbeat error is retired by a clean sweep (as the scoring lane's is by a
/// scored day, 282721cae): the heartbeat writes `lastError` on every beat, so a single scan timeout used
/// to read as a lane failing forever. DB-backed (the arrival scan runs real SQL): set FRWHOOP_TEST_DB_URL
/// to a scratch database with the migrations applied (supabase/tests/e2e/pipeline_db.sh); skipped
/// otherwise, and skipped when that database holds pending raw arrivals (the scan must come back empty).
final class VerificationLaneLastErrorTests: XCTestCase {

    private func lane() throws -> VerificationLane {
        guard let url = ProcessInfo.processInfo.environment["FRWHOOP_TEST_DB_URL"], !url.isEmpty else {
            throw XCTSkip("set FRWHOOP_TEST_DB_URL to a scratch Postgres with the migrations applied")
        }
        let db = try PostgresClient(options: PostgresOptions(
            connectionString: url, sslMode: "disable", sslRootCert: nil,
            applicationName: "frwhoop-worker-verify-tests", allowInsecure: true,
            connectTimeoutSeconds: 30, reconnectDeadlineSeconds: 30,
            statementTimeoutMS: 60_000, idleTransactionTimeoutMS: 60_000))
        let pending = try db.query(VerificationLane.candidateSQL(afterCursor: false), ["1"])
        guard pending.isEmpty else { throw XCTSkip("the scratch database holds pending raw arrivals") }
        // Never contacted: an empty scan downloads nothing.
        return VerificationLane(db: db, storage: B2Storage(keyID: "unused", applicationKey: "unused",
                                                           bucket: "unused"))
    }

    func testCleanEmptyScanRetiresAStaleError() throws {
        var subject = try lane()
        subject.stats.failed = 1
        subject.stats.lastError = "reconcile scan: canceling statement due to statement timeout"
        subject.reconcile(budget: 4)
        XCTAssertNil(subject.stats.lastError, "a clean empty scan retires the stale error")
        XCTAssertEqual(subject.stats.failed, 1, "the failure counter keeps its history")
    }

    func testErrorFromTheCurrentSweepSurvivesItsOwnEmptyPage() throws {
        var subject = try lane()
        // A row the lane cannot verify (no owner): recorded as this sweep's error, no download (the
        // best-effort quarantine of an unknown id may replace the message with its own; either counts).
        subject.processCandidate(["id": UUID().uuidString.lowercased()])
        let recorded = try XCTUnwrap(subject.stats.lastError)
        XCTAssertTrue(recorded.contains("row missing identity") || recorded.hasPrefix("quarantine"), recorded)
        // The empty page that closes the sweep keeps it: the failure happened in this sweep.
        subject.reconcile(budget: 4)
        XCTAssertEqual(subject.stats.lastError, recorded)
        // The next sweep is clean (the row is in the negative cache and was not re-tried): retired.
        subject.reconcile(budget: 4)
        XCTAssertNil(subject.stats.lastError)
    }

    func testDrainWithNothingPendingLeavesNoError() throws {
        var subject = try lane()
        subject.stats.lastError = "reconcile scan: canceling statement due to statement timeout"
        subject.drain(budget: 2)
        XCTAssertNil(subject.stats.lastError,
                     "nothing pending on either path: the lane reports no error")
    }
}
