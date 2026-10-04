import XCTest
@testable import frwhoop_worker

/// Pure tests for zone-aware midnight closure (G2-attestation item 3 / spec 4.5).
///
/// Boundary math documentation: the AUTHORITATIVE computation lives in SQL —
/// `scoring_enqueue_due_day_closure` uses Postgres `AT TIME ZONE` on
/// `pg_timezone_names` (the same DST-correct calendar arithmetic as
/// `scoring_day_segments`). The worker hook is a single statement; these tests
/// pin (a) the statement shape, (b) the Swift mirror helper
/// (`DayScorer.closureDue`, which combines with the already-tested calendar-correct
/// `DayScorer.dayStartUnix` for the local-midnight term), and (c) the default
/// throttle, so the sweep cannot flood the DB.
final class DayClosureTests: XCTestCase {

    // MARK: - Boundary predicate (mirrors Postgres AT TIME ZONE + settle window)

    func testClosureDueExactlyAtMidnightPlusSettle() {
        // The boundary passes the instant nowUnix reaches midnight + settle.
        XCTAssertFalse(DayScorer.closureDue(yesterdayLocalMidnightUnix: 1_000, nowUnix: 1_000 + 599, settleSeconds: 600))
        XCTAssertTrue(DayScorer.closureDue(yesterdayLocalMidnightUnix: 1_000, nowUnix: 1_000 + 600, settleSeconds: 600))
        XCTAssertTrue(DayScorer.closureDue(yesterdayLocalMidnightUnix: 1_000, nowUnix: 1_000 + 3_600, settleSeconds: 600))
    }

    func testClosureDueRequiresSettledLocalMidnight() {
        // A zero settle window means "due the instant local midnight passes".
        XCTAssertFalse(DayScorer.closureDue(yesterdayLocalMidnightUnix: 1_000, nowUnix: 999, settleSeconds: 0))
        XCTAssertTrue(DayScorer.closureDue(yesterdayLocalMidnightUnix: 1_000, nowUnix: 1_000, settleSeconds: 0))
    }

    func testLocalMidnightTermIsCalendarCorrectForDST() {
        // America/Los_Angeles: 2026-03-08 is a 23 h spring-forward day.
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let start = try! XCTUnwrap(DayScorer.dayStartUnix("2026-03-08", tz: la))
        let end = DayScorer.nextDayStartUnix(after: start, tz: la)
        XCTAssertEqual(end - start, 23 * 3_600)
        // A quiet day is due one settle window after the NEXT local midnight.
        let now = end + 600
        XCTAssertTrue(DayScorer.closureDue(yesterdayLocalMidnightUnix: end, nowUnix: now, settleSeconds: 600))
    }

    // MARK: - Sweep statement shape

    func testSweepCallsTheDueClosureRpcWithBoundedArguments() {
        XCTAssertTrue(ScoringLane.dayClosureSweepSQL.contains("public.scoring_enqueue_due_day_closure($1::integer, $2::text, $3::integer)"))
        XCTAssertTrue(ScoringLane.dayClosureSweepSQL.contains("$1::integer"))
        XCTAssertTrue(ScoringLane.dayClosureSweepSQL.contains("$3::integer"))
    }

    // MARK: - Throttle defaults

    func testSweepDefaultsAreBounded() {
        XCTAssertGreaterThan(ScoringLane.defaultDayClosureSweepIntervalSeconds, 0)
        XCTAssertLessThanOrEqual(ScoringLane.defaultDayClosureSweepIntervalSeconds, 300)
    }
}
