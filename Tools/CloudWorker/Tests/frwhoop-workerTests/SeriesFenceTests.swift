import XCTest
@testable import frwhoop_worker

/// Pure tests for the metric-series input-revision fence (G2-attestation item 4 / T31):
/// the worker passes the revision it CLAIMED to the fenced 6-arg
/// `publish_metric_series_v1`, and the reply classifier treats a fenced write
/// (`reason=superseded`) as superseded — never success, never failure. The RPC
/// itself is tested against the local-PG harness; these tests pin the worker side
/// (the statement shape and the outcome classification).
final class SeriesFenceTests: XCTestCase {

    // MARK: - The publish statement carries the claimed revision

    func testPublishUsesTheFencedSixArgumentRpc() {
        // The statement must call the fenced 6-arg form and bind the claimed revision.
        XCTAssertTrue(ScoringLane.seriesPublishSQL.contains("public.publish_metric_series_v1($1::uuid,$2::uuid,$3::date,$4::text,$5::jsonb,$6::bigint)"))
        XCTAssertTrue(ScoringLane.seriesPublishSQL.contains("$6::bigint"))
        // It must never call the legacy unfenced 5-arg form.
        XCTAssertFalse(ScoringLane.seriesPublishSQL.contains("publish_metric_series_v1($1::uuid,$2::uuid,$3::date,$4::text,$5::jsonb)::text"))
    }

    // MARK: - Reply classification

    func testAppliedReplyIsSuccessWithRowCounts() {
        let reply = #"{"applied":true,"upserted":12,"deleted":3,"metrics":{"steps":{"upserted":12,"deleted":3}}}"#
        XCTAssertEqual(ScoringLane.classifySeriesOutcome(reply), .applied(upserted: 12, deleted: 3))
    }

    func testAppliedWithZeroRowsIsStillSuccess() {
        let reply = #"{"applied":true,"upserted":0,"deleted":0}"#
        XCTAssertEqual(ScoringLane.classifySeriesOutcome(reply), .applied(upserted: 0, deleted: 0))
    }

    func testSupersededReplyIsNeitherSuccessNorFailure() {
        let reply = #"{"applied":false,"reason":"superseded","claimed_input_revision":4,"latest_input_revision":5}"#
        XCTAssertEqual(ScoringLane.classifySeriesOutcome(reply), .superseded)
    }

    func testNotSelectedReplyIsSkipped() {
        let reply = #"{"applied":false,"reason":"not_selected"}"#
        XCTAssertEqual(ScoringLane.classifySeriesOutcome(reply), .skipped)
    }

    func testUnknownNonAppliedReplyIsSkipped() {
        let reply = #"{"applied":false,"reason":"something_else"}"#
        XCTAssertEqual(ScoringLane.classifySeriesOutcome(reply), .skipped)
    }

    func testMalformedRepliesAreNotMisclassified() {
        XCTAssertEqual(ScoringLane.classifySeriesOutcome(nil), .malformed)
        XCTAssertEqual(ScoringLane.classifySeriesOutcome(""), .malformed)
        XCTAssertEqual(ScoringLane.classifySeriesOutcome("null"), .malformed)
        XCTAssertEqual(ScoringLane.classifySeriesOutcome("not json"), .malformed)
        XCTAssertEqual(ScoringLane.classifySeriesOutcome(#"[1,2,3]"#), .malformed)
    }

    func testFencedSupersededIsNotAnAppliedOutcome() {
        // A superseded write must never increment the published/rows-written path.
        let reply = #"{"applied":false,"reason":"superseded"}"#
        let outcome = ScoringLane.classifySeriesOutcome(reply)
        if case .applied = outcome {
            XCTFail("superseded must not classify as applied")
        }
    }
}
