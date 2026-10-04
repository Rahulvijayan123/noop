import XCTest
@testable import frwhoop_worker

/// Pure tests for the day attestation (G2-attestation item 2 / spec 4.4):
/// the v2 scoring pass writes a compact, versioned per-day record AFTER a
/// successful snapshot publish, with identity/time, real stream counts, real
/// projection completion, and explicit `not_measured` markers everywhere the
/// pass cannot observe — never a fabricated continuity verdict.
final class DayAttestationTests: XCTestCase {

    private func claim(day: String = "2026-09-20", revision: Int64 = 7,
                       tz: String = "America/Los_Angeles") -> DayScorer.Claim {
        DayScorer.Claim(userId: "11111111-1111-4111-8111-111111111111",
                        deviceId: "33333333-3333-4333-8333-333333333333",
                        day: day, timezoneId: tz, inputRevision: revision,
                        leaseToken: "44444444-4444-4444-8444-444444444444",
                        runId: "55555555-5555-4555-8555-555555555555", measurementRevision: 0)
    }

    private func snapshot(status: String = "available",
                          coverage: [String: Any] = ["hr": ["received": 2100], "rr": ["received": 90000]]) -> [String: Any] {
        ["status": status, "coverage": coverage, "dataThrough": "2026-09-20T12:00:00Z"]
    }

    func testAttestationCarriesIdentityAndTime() {
        // A DST spring-forward day (23 h) so the bounds assertion is meaningful.
        let c = claim(day: "2026-03-08", revision: 7, tz: "America/Los_Angeles")
        let a = DayScorer.dayAttestation(claim: c, snapshot: snapshot(), resultRevision: 42, algorithmVersion: "frwhoop-server-1")
        let identity = a["identity"] as? [String: Any]
        XCTAssertEqual(identity?["user_id"] as? String, c.userId)
        XCTAssertEqual(identity?["device_id"] as? String, c.deviceId)
        XCTAssertEqual(identity?["day"] as? String, "2026-03-08")
        XCTAssertEqual(identity?["timezone_id"] as? String, "America/Los_Angeles")
        XCTAssertEqual(identity?["calendar_policy_version"] as? String, "job-calendar-1")
        XCTAssertEqual(identity?["input_revision"] as? Int64, 7)
        XCTAssertEqual(identity?["algorithm_version"] as? String, "frwhoop-server-1")
        // Bounds are calendar-correct local midnights, never dayStart + 86400.
        let start = identity?["day_start_unix"] as? Int ?? 0
        let end = identity?["day_end_unix"] as? Int ?? 0
        XCTAssertGreaterThan(end, start)
        XCTAssertNotEqual(end - start, 86_400, "day bounds must be calendar-correct, not fixed 86400")
    }

    func testAttestationDSTDayBoundsAreCalendarCorrect() {
        // 2026-03-08 is a 23 h DST spring-forward day in America/Los_Angeles.
        let c = claim(day: "2026-03-08", revision: 1, tz: "America/Los_Angeles")
        let a = DayScorer.dayAttestation(claim: c, snapshot: snapshot(), resultRevision: 1, algorithmVersion: "frwhoop-server-1")
        let identity = a["identity"] as? [String: Any]
        let start = identity?["day_start_unix"] as? Int ?? 0
        let end = identity?["day_end_unix"] as? Int ?? 0
        XCTAssertEqual(end - start, 23 * 3_600, "spring-forward day must be 23 h")
    }

    func testAttestationReportsRealStatusAndStreamCounts() {
        let c = claim()
        let cov: [String: Any] = ["hr": ["received": 2100], "rr": ["received": 90000],
                                  "nightWindow": ["start": "x", "end": "y"]]
        let a = DayScorer.dayAttestation(claim: c, snapshot: snapshot(status: "partial", coverage: cov),
                                         resultRevision: 5, algorithmVersion: "frwhoop-server-1")
        XCTAssertEqual(a["status"] as? String, "partial")
        XCTAssertEqual(a["dataThrough"] as? String, "2026-09-20T12:00:00Z")
        let acq = a["acquisition"] as? [String: Any]
        let streams = acq?["streams"] as? [String: Any]
        XCTAssertEqual((streams?["hr"] as? [String: Any])?["received"] as? Int, 2100)
        XCTAssertEqual((streams?["rr"] as? [String: Any])?["received"] as? Int, 90000)
    }

    func testAttestationMarksEverythingThePassCannotObserveAsNotMeasured() {
        let c = claim()
        let a = DayScorer.dayAttestation(claim: c, snapshot: snapshot(), resultRevision: 3, algorithmVersion: "frwhoop-server-1")
        let acq = a["acquisition"] as? [String: Any]
        for key in ["coverage_durations", "rejected", "duplicates", "missing_intervals",
                    "largest_gap_s", "off_body_s", "unknown_s"] {
            XCTAssertEqual(acq?[key] as? String, "not_measured", "\(key) must be not_measured")
        }
        let handoff = a["handoff"] as? [String: Any]
        for key in ["phone_watermarks", "durably_accepted_ids", "worker_backlog"] {
            XCTAssertEqual(handoff?[key] as? String, "not_measured", "\(key) must be not_measured")
        }
        let archive = a["archive"] as? [String: Any]
        for key in ["manifest_refs", "hash_verification", "last_archived_event"] {
            XCTAssertEqual(archive?[key] as? String, "not_measured", "\(key) must be not_measured")
        }
        let context = a["context"] as? [String: Any]
        for key in ["wear", "placement", "source_arbitration"] {
            XCTAssertEqual(context?[key] as? String, "not_measured", "\(key) must be not_measured")
        }
    }

    func testAttestationProjectionCompletionIsFactualAfterPublish() {
        let c = claim(revision: 7)
        let a = DayScorer.dayAttestation(claim: c, snapshot: snapshot(), resultRevision: 42, algorithmVersion: "frwhoop-server-1")
        let projection = a["projection"] as? [String: Any]
        XCTAssertEqual(projection?["input_revision"] as? Int64, 7)
        XCTAssertEqual(projection?["completed"] as? Bool, true)
        XCTAssertEqual(projection?["snapshot_result_revision"] as? Int64, 42)
        XCTAssertEqual(projection?["algorithm_version"] as? String, "frwhoop-server-1")
    }

    func testAttestationStatusNeverFabricatesContinuity() {
        // status must travel as the SCORING status (available/partial/no_data),
        // never as a continuity verdict like complete/degraded.
        let c = claim()
        let a = DayScorer.dayAttestation(claim: c, snapshot: snapshot(status: "no_data"),
                                         resultRevision: 1, algorithmVersion: "frwhoop-server-1")
        XCTAssertEqual(a["status"] as? String, "no_data")
        XCTAssertNotEqual(a["status"] as? String, "complete")
    }

    func testAttestationWriteUsesTheFencedRpc() {
        XCTAssertTrue(ScoringLane.dayAttestationSQL.contains("public.publish_day_attestation_v1($1::uuid,$2::uuid,$3::date,$4::bigint,$5::text,$6::jsonb)"))
        XCTAssertTrue(ScoringLane.dayAttestationSQL.contains("$4::bigint"))
    }

    // MARK: - Quiet-day timezone chain (audit-g2-durability P2, closure zone mismatch)

    /// The closure sweep enqueues a quiet day from profiles.timezone; the worker's
    /// resolveTimezone must hand that zone to the claim so the attestation identity
    /// uses the same zone. Pin the SQL's profile fallback (it must appear BEFORE the
    /// UTC fallback so a non-UTC quiet day is not attested with UTC bounds).
    func testResolveTimezoneSQLFallsBackToProfileBeforeUTC() {
        let sql = ScoringLane.resolveTimezoneSQL
        XCTAssertTrue(sql.contains("from public.profiles p where p.id=$1::uuid"),
                      "profile timezone fallback must be present")
        let profilePos = sql.range(of: "public.profiles")?.lowerBound
        let utcPos = sql.range(of: "'UTC'")?.lowerBound
        XCTAssertNotNil(profilePos)
        XCTAssertNotNil(utcPos)
        XCTAssertLessThan(profilePos!, utcPos!, "profile fallback must precede the UTC fallback")
        // The profile zone must be validated against pg_timezone_names (a garbage
        // zone would fail the snapshot contract's timezone check).
        XCTAssertTrue(sql.contains("pg_timezone_names n"), "profile zone must be validated")
    }

    /// A quiet non-UTC day (claim zone resolved to America/New_York): the
    /// attestation day bounds must be the zone-correct window (23 h on the 2026
    /// spring-forward day), never a fixed 86,400 block.
    func testAttestationNonUTCQuietDayBounds() throws {
        let c = DayScorer.Claim(userId: "11111111-1111-4111-8111-111111111111",
                                deviceId: "33333333-3333-4333-8333-333333333333",
                                day: "2026-03-08", timezoneId: "America/New_York",
                                inputRevision: 3, leaseToken: "44444444-4444-4444-8444-444444444444",
                                runId: "55555555-5555-4555-8555-555555555555", measurementRevision: 0)
        let a = DayScorer.dayAttestation(claim: c, snapshot: snapshot(status: "no_data"),
                                         resultRevision: 1, algorithmVersion: "frwhoop-server-1")
        let identity = a["identity"] as? [String: Any]
        let start = identity?["day_start_unix"] as? Int ?? 0
        let end = identity?["day_end_unix"] as? Int ?? 0
        XCTAssertEqual(end - start, 23 * 3_600, "non-UTC quiet-day bounds must be zone-correct (23 h)")
        XCTAssertEqual(identity?["timezone_id"] as? String, "America/New_York")
    }
}
