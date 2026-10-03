import XCTest
@testable import frwhoop_worker

/// An upload takes the owner's scoring-input gate (an advisory lock) exclusively and then updates the job row.
/// The v2 scoring lane used to lock the job row at the claim and ask for the shared side of the gate only at
/// publication, so an upload that committed during the computation deadlocked with it. The lane now holds the
/// gate from before the claim. The ordering itself can only be seen against a database; these tests pin what a
/// unit test can: the lock key, which must be the one the database functions use, and the statement shapes.
final class InputGateTests: XCTestCase {

    private let key = "hashtextextended('scoring-inputs-v2:' || $1::text, 0)"

    func testTheGateKeyIsTheOneUploadsAndPublicationLock() {
        XCTAssertTrue(ScoringLane.inputGateTrySQL.contains(key))
        XCTAssertTrue(ScoringLane.inputGateReleaseSQL.contains(key))
    }

    func testTheGateIsSharedAndSessionLevelSoItOutlivesTheTransactionThatFollows() {
        XCTAssertTrue(ScoringLane.inputGateTrySQL.contains("pg_try_advisory_lock_shared"))
        XCTAssertFalse(ScoringLane.inputGateTrySQL.contains("xact"))
        XCTAssertTrue(ScoringLane.inputGateReleaseSQL.contains("pg_advisory_unlock_shared"))
    }

    func testTheGateIsPolledNeverQueuedFor() {
        XCTAssertFalse(ScoringLane.inputGateTrySQL.contains("pg_advisory_lock_shared"))
    }

    func testTheOwnerProbeIsTheClaimItselfAndTakesNoParameterTheClaimDoesNotUse() {
        XCTAssertTrue(ScoringLane.v2OwnerProbeSQL.contains("public.claim_scoring_v2($1::text, $2::integer)"))
        XCTAssertFalse(ScoringLane.v2OwnerProbeSQL.contains("$3"))
        XCTAssertFalse(ScoringLane.v2OwnerProbeSQL.lowercased().contains("publish"))
    }

    func testTheGateStatementsBindExactlyTheOwner() {
        for sql in [ScoringLane.inputGateTrySQL, ScoringLane.inputGateReleaseSQL] {
            XCTAssertTrue(sql.contains("$1"))
            XCTAssertFalse(sql.contains("$2"))
        }
    }

    func testDefaultsKeepThePollShortAndTheWaitBounded() {
        XCTAssertGreaterThan(ScoringLane.defaultV2InputGateSeconds, 0)
        XCTAssertLessThanOrEqual(ScoringLane.defaultV2InputGateSeconds, 30)
        XCTAssertGreaterThan(ScoringLane.inputGatePollSeconds, 0)
        XCTAssertLessThanOrEqual(ScoringLane.inputGatePollSeconds, 0.5)
    }
}
