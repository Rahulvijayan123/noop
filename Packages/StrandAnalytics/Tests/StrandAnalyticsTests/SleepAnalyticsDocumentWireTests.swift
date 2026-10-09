import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// SleepAnalyticsDocumentWireTests — the wire contract (spec section 8): snake_case
// keys, explicit null, finite-only leaves, tolerant decode.
final class SleepAnalyticsDocumentWireTests: XCTestCase {
    func testDocumentEncodesWithSnakeCaseWireKeys() throws {
        let start = 1_789_000_000
        let labels = ["wake", "light", "light", "deep", "deep", "light",
                     "rem", "rem", "wake", "light", "light", "wake"]
        let stages = labels.enumerated().map { i, l in
            StageSegment(start: start + i * 30, end: start + (i + 1) * 30, stage: l)
        }
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: start + 360,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30, stages: stages)],
            timezoneId: "Etc/UTC",
            hr: (start..<start + 360).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "sleep-stager-v2-test", inputRevision: 7)
        let doc = SleepAnalyticsV1.compute(input: input, config: .v1)
        let data = try JSONEncoder().encode(doc)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // Top-level spec section 8 keys.
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual(json["algorithm_version"] as? String, "nara-sleep-analytics-2")
        XCTAssertEqual(json["config_version"] as? String, "v2")
        XCTAssertEqual(json["scope"] as? String, "main_night")
        XCTAssertNotNil(json["start_at"])
        XCTAssertNotNil(json["end_at"])
        XCTAssertNotNil(json["fingerprint"])
        XCTAssertEqual(json["stage_source_version"] as? String, "sleep-stager-v2-test")
        XCTAssertEqual(json["native_epoch_resolution_seconds"] as? Int, 30)
        XCTAssertEqual(json["input_revision"] as? Int, 7)
        // Groups present with their spec names.
        let cont = json["continuity"] as! [String: Any]
        XCTAssertNotNil(cont["observed_asleep_seconds"])
        XCTAssertNotNil(cont["observed_waso_seconds"])
        XCTAssertNotNil(cont["rem_latency_from_sleep_onset_seconds"])
        XCTAssertNotNil(cont["sleep_to_wake_transitions_per_asleep_hour"])
        // A metric wrapper on the wire.
        let waso = cont["observed_waso_seconds"] as! [String: Any]
        XCTAssertEqual(waso["unit"] as? String, "s")
        XCTAssertNotNil(waso["status"])
        // Explicit null (marker SOL is missing_marker in Phase 1).
        let marker = cont["sleep_onset_latency_from_marker_seconds"] as! [String: Any]
        XCTAssertNil(marker["value"])
        XCTAssertEqual(marker["reason"] as? String, "missing_marker")
        // No camelCase leakage at the top level.
        XCTAssertNil(json["schemaVersion"])
        // Round-trip decode equality.
        let decoded = try JSONDecoder().decode(SleepAnalyticsDocument.self, from: data)
        XCTAssertEqual(decoded, doc)
        // Fingerprint stability: same input → same fingerprint; bounds change → change.
        let doc2 = SleepAnalyticsV1.compute(input: input, config: .v1)
        XCTAssertEqual(doc2.fingerprint, doc.fingerprint)
    }
}
