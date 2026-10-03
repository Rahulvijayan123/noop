import XCTest
@testable import frwhoop_worker

/// The legacy scoring queue is served before v2, and an upload revokes any legacy claim for its owner. While a
/// phone streams uploads every few seconds the lane therefore used to spend most of its time on legacy day
/// computations that could only be discarded, and v2 snapshots (which the app reads) came minutes apart.
final class LegacyClaimGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ user: String, _ device: String = "d1", _ day: String = "2026-10-02",
                     quiet: String, waited: Int = 5) -> [String: String] {
        ["user_id": user, "device_id": device, "day": day, "quiet": quiet, "waited_seconds": String(waited)]
    }

    private func partition(_ rows: [[String: String]], lastClaimed: [String: Date] = [:],
                           maxDefer: Int = 1800) -> (ready: [ScoringLane.LegacyCandidate], deferred: Int) {
        ScoringLane.partitionLegacyCandidates(rows, now: now, maxDeferSeconds: maxDefer, lastClaimed: lastClaimed)
    }

    func testQuietOwnersAreReadyInQueueOrderAndBusyOnesAreCounted() {
        let (ready, deferred) = partition([
            row("busy", quiet: "f"),
            row("quiet-a", "d2", quiet: "t"),
            row("busy", "d1", "2026-10-03", quiet: "f"),
            row("quiet-b", "d3", "2026-10-01", quiet: "true"),
        ])
        XCTAssertEqual(ready, [
            ScoringLane.LegacyCandidate(user: "quiet-a", device: "d2", day: "2026-10-02"),
            ScoringLane.LegacyCandidate(user: "quiet-b", device: "d3", day: "2026-10-01"),
        ])
        XCTAssertEqual(deferred, 2)
    }

    func testAnOwnerWhoIsStillUploadingYieldsNothingToClaim() {
        let (ready, deferred) = partition([
            row("busy", quiet: "f"),
            row("busy", "d1", "2026-10-03", quiet: "f"),
        ])
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(deferred, 2)
    }

    /// `next_attempt_at` never advances while an item keeps being re-queued, so an item can look ancient even if
    /// it was tried a minute ago. The cap has to come from this process's own record of the last attempt.
    func testAnItemThatHasWaitedTooLongIsClaimedOnceThenLeftAlone() {
        let stale = row("busy", quiet: "f", waited: 4000)
        let candidate = ScoringLane.LegacyCandidate(user: "busy", device: "d1", day: "2026-10-02")

        XCTAssertEqual(partition([stale]).ready, [candidate], "never tried by this process: forced")

        let justTried = [candidate.key: now.addingTimeInterval(-60)]
        let retried = partition([stale], lastClaimed: justTried)
        XCTAssertTrue(retried.ready.isEmpty, "tried a minute ago: deferred again")
        XCTAssertEqual(retried.deferred, 1)

        let longAgo = [candidate.key: now.addingTimeInterval(-1801)]
        XCTAssertEqual(partition([stale], lastClaimed: longAgo).ready, [candidate], "tried longer ago than the cap")
    }

    func testAnItemThatHasNotWaitedLongEnoughIsNotForced() {
        let (ready, deferred) = partition([row("busy", quiet: "f", waited: 1799)])
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(deferred, 1)
    }

    func testIncompleteRowsAreIgnoredRatherThanClaimed() {
        let (ready, deferred) = partition([
            ["user_id": "", "device_id": "d1", "day": "2026-10-02", "quiet": "t"],
            ["user_id": "u", "device_id": "d1", "quiet": "t"],
            ["user_id": "u", "device_id": "d1", "day": "2026-10-02"],
        ])
        XCTAssertTrue(ready.isEmpty, "a row without a key, or without an explicit quiet flag, is never claimed")
        XCTAssertEqual(deferred, 1, "a missing flag counts as busy, not as quiet")
    }

    func testNoRowsMeansNothingDeferred() {
        let (ready, deferred) = partition([])
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(deferred, 0)
    }

    /// `clock_timestamp()` is volatile, so a bound written with it cannot be used as an index condition and the
    /// receipt probe scanned the owner's whole history (~200 ms against 0.05 ms). Keep the probe on `now()`.
    func testUploadProbeUsesAStableClockSoTheIndexCanBeUsed() {
        let sql = ScoringLane.legacyCandidatesSQL
        guard let start = sql.range(of: "from public.noop_upload_receipts u"),
              let end = sql.range(of: "as quiet") else { return XCTFail("probe missing") }
        let probe = String(sql[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(probe.contains("u.accepted_at > now()"), "probe: \(probe)")
        XCTAssertFalse(probe.contains("clock_timestamp()"), "probe: \(probe)")
    }

    func testCandidateQueryMirrorsTheClaimFunctionsEligibility() {
        let sql = ScoringLane.legacyCandidatesSQL
        for fragment in [
            "w.done_at is null",
            "w.next_attempt_at <= clock_timestamp()",
            "w.lease_expires_at is null or w.lease_expires_at <= clock_timestamp()",
            "w.failure_revision <> w.input_revision or w.consecutive_failures < $1::integer",
            "d.is_active",
            "noop_account_retirements",
            "order by w.next_attempt_at, w.dirty_at, w.user_id, w.device_id, w.day",
        ] {
            XCTAssertTrue(sql.contains(fragment), "missing eligibility fragment: \(fragment)")
        }
    }

    /// The query is sent with exactly two parameters; a placeholder beyond them would fail at bind time.
    func testCandidateQueryUsesExactlyTheTwoParametersTheLaneSends() {
        let sql = ScoringLane.legacyCandidatesSQL
        XCTAssertTrue(sql.contains("$1::integer"))
        XCTAssertTrue(sql.contains("$2::integer"))
        XCTAssertFalse(sql.contains("$3"))
    }

    /// The quiet window has to outlast one upload gap while the app is open (about 2.5 s) and be short enough
    /// that a phone that uploads once a minute is served between uploads; the cap bounds legacy lag.
    func testDefaultsAreSaneAndTheQuietWindowIsLongerThanAnUploadGap() {
        XCTAssertEqual(ScoringLane.defaultLegacyQuietSeconds, 20)
        XCTAssertEqual(ScoringLane.defaultLegacyMaxDeferSeconds, 1800)
        XCTAssertGreaterThan(ScoringLane.defaultLegacyQuietSeconds, 10)
        XCTAssertLessThan(ScoringLane.defaultLegacyQuietSeconds, 60)
        XCTAssertGreaterThan(ScoringLane.defaultLegacyMaxDeferSeconds, ScoringLane.defaultLegacyQuietSeconds)
    }
}
