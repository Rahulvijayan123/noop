import XCTest
import WhoopProtocol
@testable import frwhoop_worker

/// DayScoring candidate-input assembly (observation-identity dedup, the exact HRV
/// provider payload) and the ACTIVE-promotion plumbing. All pure: no DB, no HTTP.
final class DayScoringCandidateInputTests: XCTestCase {

    private func beat(_ ts: Int, _ rrMs: Int, channel: RRSourceChannel? = .whoop5Historical,
                      ord: Int? = 0, seq: Int = 0) -> RRInterval {
        RRInterval(ts: ts, rrMs: rrMs, srcChannel: channel, ord: ord, seq: seq)
    }

    private func inputs(_ beats: [RRInterval], inputRows: Int? = nil) -> DayScorer.CandidateInputs {
        let deduped = DayScorer.dedupByObservationIdentity(beats)
        return DayScorer.CandidateInputs(
            userId: "u", deviceId: "d", day: "2026-10-01", inputRevision: 3,
            intervalStart: 1_772_006_400, intervalEnd: 1_772_035_200,
            claimSealedAt: Date(), status: "available",
            canonicalAvgHrv: 48.0, canonicalSdnn: 61.0,
            profileVersion: nil, correctionsVersion: nil,
            hrvBeats: DayScorer.candidateBeats(deduped),
            hrvInputRows: inputRows ?? beats.count,
            hrvTimestampResolution: "whole_seconds")
    }

    // MARK: - Observation-identity dedup

    func testEqualIntervalsInTheSameSecondAreKeptDistinct() {
        // Two GENUINE beats can share a second and an interval; `seq` is the
        // storage identity that separates them (spec section 5).
        let beats = [beat(1_772_006_400, 800, ord: 0, seq: 1),
                     beat(1_772_006_400, 800, ord: 1, seq: 2)]
        let deduped = DayScorer.dedupByObservationIdentity(beats)
        XCTAssertEqual(deduped.count, 2, "same-second equal intervals are different observations")
    }

    func testByteIdenticalRetransmissionCollapses() {
        let beats = [beat(1_772_006_400, 800, ord: 3, seq: 7),
                     beat(1_772_006_400, 800, ord: 3, seq: 7),
                     beat(1_772_006_400, 800, ord: 3, seq: 7)]
        XCTAssertEqual(DayScorer.dedupByObservationIdentity(beats).count, 1)
    }

    func testDifferentChannelOrIntervalOrSecondIsADifferentObservation() {
        let beats = [beat(1_772_006_400, 800, channel: .whoop5Historical, seq: 1),
                     beat(1_772_006_400, 800, channel: .whoop5Standard, seq: 1),
                     beat(1_772_006_400, 812, channel: .whoop5Historical, seq: 1),
                     beat(1_772_006_401, 800, channel: .whoop5Historical, seq: 1)]
        XCTAssertEqual(DayScorer.dedupByObservationIdentity(beats).count, 4)
    }

    func testDedupKeepsTheFirstOccurrenceInOrder() {
        let beats = [beat(10, 800, seq: 1), beat(11, 810, seq: 2), beat(10, 800, seq: 1)]
        let deduped = DayScorer.dedupByObservationIdentity(beats)
        XCTAssertEqual(deduped.map(\.ts), [10, 11])
    }

    // MARK: - Beat ordering and timestamps

    func testBeatsAreOrderedBySecondThenSequenceThenOrdinal() {
        let beats = [beat(1_772_006_401, 800, ord: 0, seq: 0),
                     beat(1_772_006_400, 810, ord: 5, seq: 2),
                     beat(1_772_006_400, 820, ord: 9, seq: 1)]
        let ordered = DayScorer.candidateBeats(beats)
        XCTAssertEqual(ordered.map(\.rrMs), [820, 810, 800])
        XCTAssertEqual(ordered.map(\.ts), [1_772_006_400, 1_772_006_400, 1_772_006_401])
    }

    func testIntervalEndFollowsTheStoreConvention() {
        let ordered = DayScorer.candidateBeats([beat(1_772_006_400, 850, seq: 1)])
        XCTAssertEqual(ordered[0].tsEndSeconds, 1_772_006_400.85, accuracy: 1e-9)
        XCTAssertEqual(ordered[0].ts, 1_772_006_400)
        XCTAssertEqual(ordered[0].rrMs, 850)
        XCTAssertEqual(ordered[0].srcChannel, RRSourceChannel.whoop5Historical.rawValue)
    }

    func testSubSecondReconstructionAccumulatesWithinOneBucket() {
        let beats = [beat(1_772_006_400, 800, ord: 0, seq: 1),
                     beat(1_772_006_400, 900, ord: 1, seq: 2),
                     beat(1_772_006_401, 700, ord: 0, seq: 3)]
        let ordered = DayScorer.candidateBeats(beats)
        XCTAssertEqual(ordered[0].tsEndReconstructedSeconds, 1_772_006_400.8, accuracy: 1e-9)
        XCTAssertEqual(ordered[1].tsEndReconstructedSeconds, 1_772_006_401.7, accuracy: 1e-9)
        // A new second restarts the accumulation from that second's own ts.
        XCTAssertEqual(ordered[2].tsEndReconstructedSeconds, 1_772_006_401.7, accuracy: 1e-9)
    }

    // MARK: - The HRV provider payload

    func testHrvInputCarriesBeatsWindowConfigAndIdentity() throws {
        let subject = inputs([beat(1_772_006_400, 800, ord: 0, seq: 1),
                              beat(1_772_006_400, 800, ord: 1, seq: 2),
                              beat(1_772_006_401, 790, ord: 0, seq: 3)])
        let payload = try XCTUnwrap(subject.input(for: "hrv"))
        guard case .object(let root) = payload else { return XCTFail("input must be an object") }
        guard case .array(let beats)? = root["beats"] else { return XCTFail("beats must be an array") }
        XCTAssertEqual(beats.count, 3)
        guard case .object(let window)? = root["window"] else { return XCTFail("window missing") }
        XCTAssertEqual(window["start_sec"]?.doubleValue, 1_772_006_400)
        XCTAssertEqual(window["end_sec"]?.doubleValue, 1_772_035_200)
        XCTAssertEqual(window["inclusive"], .bool(true))
        XCTAssertEqual(root["timestamp_convention"], .string("interval_end_seconds"))
        XCTAssertEqual(root["timestamp_resolution"], .string("whole_seconds"))
        guard case .object(let identity)? = root["observation_identity"] else {
            return XCTFail("observation_identity missing")
        }
        XCTAssertEqual(identity["input_rows"]?.doubleValue, 3)
        XCTAssertEqual(identity["deduped_rows"]?.doubleValue, 3)
        XCTAssertEqual(identity["bucket_seconds"]?.doubleValue, 1)
    }

    func testHrvConfigDefaultsMatchTheShippedProductionRules() throws {
        let subject = inputs([beat(1_772_006_400, 800, seq: 1)])
        let payload = try XCTUnwrap(subject.input(for: "hrv"))
        guard case .object(let config)? = payload.member("config") else {
            return XCTFail("config missing")
        }
        // Defaults are the shipped code's rules (hrv-neurokit findings 5a/5d), so a
        // shadow comparison is apples-to-apples with the canonical nightly value.
        XCTAssertEqual(config["window_sec"]?.doubleValue, 300)
        XCTAssertEqual(config["min_clean_beats"]?.doubleValue, 20)
        XCTAssertEqual(config["splice_tolerance_s"]?.doubleValue, 3.0)
        XCTAssertEqual(config["rr_min_ms"]?.doubleValue, 300)
        XCTAssertEqual(config["rr_max_ms"]?.doubleValue, 2000)
        XCTAssertEqual(config["malik_threshold"]?.doubleValue, 0.20)
        XCTAssertEqual(config["malik_radius"]?.doubleValue, 2)
        // 1.0 - (ceiling - 1.0) in binary floating point, so compare with a tolerance.
        XCTAssertEqual(try XCTUnwrap(config["coverage_floor"]?.doubleValue), 0.9, accuracy: 1e-9)
        XCTAssertEqual(config["coverage_ceiling"]?.doubleValue, 1.10)
        XCTAssertEqual(config["beat_accuracy_tolerance_s"]?.doubleValue, 0.5)
        XCTAssertEqual(config["beat_accuracy_min_fraction"]?.doubleValue, 0.5)
        XCTAssertEqual(config["max_rejected_fraction"], .null, "the nightly path has no artifact gate")
        XCTAssertEqual(config["aggregation"], .string("mean_over_windows"))
        XCTAssertEqual(config["pooling"], .string("sum_sq_and_pairs"))
    }

    func testObservationIdentityReportsPreAndPostDedupCounts() throws {
        let beats = [beat(1_772_006_400, 800, seq: 1), beat(1_772_006_400, 800, seq: 1),
                     beat(1_772_006_401, 810, seq: 2)]
        let subject = inputs(beats)
        let payload = try XCTUnwrap(subject.input(for: "hrv"))
        XCTAssertEqual(payload.member("observation_identity")?.doubleValue, nil)
        guard case .object(let identity)? = payload.member("observation_identity") else {
            return XCTFail("observation_identity missing")
        }
        XCTAssertEqual(identity["input_rows"]?.doubleValue, 3, "rows read")
        XCTAssertEqual(identity["deduped_rows"]?.doubleValue, 2, "rows the provider receives")
    }

    func testMetricsAreEmptyWithoutBeatsAndUnknownMetricsHaveNoInput() {
        let empty = inputs([])
        XCTAssertTrue(empty.metrics.isEmpty)
        XCTAssertNil(empty.input(for: "hrv"))
        XCTAssertNil(empty.input(for: "sleep_stage"))
        XCTAssertNil(empty.input(for: "respiration"))
        let populated = inputs([beat(1_772_006_400, 800, seq: 1)])
        XCTAssertEqual(populated.metrics, ["hrv"])
        XCTAssertNil(populated.input(for: "sleep_boundary"))
    }

    // MARK: - ACTIVE promotion plumbing

    private func snapshotPayload() -> [String: Any] {
        ["daily": ["hrv_rmssd_ms": 48.0, "sleep_total_min": 420.0],
         "status": "available"]
    }

    private func legacyPayload() -> [String: Any] {
        ["daily_metrics": [["hrv_rmssd_ms": 48.0, "sleep_total_min": 420.0, "day": "2026-10-01"]]]
    }

    func testNoSubstitutionLeavesBothPayloadsUnchanged() {
        let snapshot = snapshotPayload()
        let legacy = legacyPayload()
        let result = DayScorer.applyActiveHrvSubstitution(snapshot: snapshot, legacy: legacy,
                                                          substitution: nil)
        let snapshotDaily = result.snapshot["daily"] as? [String: Any]
        XCTAssertEqual(snapshotDaily?["hrv_rmssd_ms"] as? Double, 48.0)
        XCTAssertNil(snapshotDaily?["hrv_provenance"])
        let legacyDaily = (result.legacy["daily_metrics"] as? [[String: Any]])?.first
        XCTAssertEqual(legacyDaily?["hrv_rmssd_ms"] as? Double, 48.0)
        XCTAssertEqual(legacyDaily?["day"] as? String, "2026-10-01")
    }

    func testActiveSubstitutionReplacesTheValueAndRecordsProvenance() {
        let substitution = CandidateStage.ActiveHrvSubstitution(
            value: 55.5, providerId: "production.runs.v1", providerVersion: "1.0.0",
            adapterVersion: "frwhoop.hrv.rmssd/1", configVersion: "cfg-1",
            inputSHA256: String(repeating: "b", count: 64), mode: "active")
        let result = DayScorer.applyActiveHrvSubstitution(snapshot: snapshotPayload(),
                                                          legacy: legacyPayload(),
                                                          substitution: substitution)
        let snapshotDaily = result.snapshot["daily"] as? [String: Any]
        XCTAssertEqual(snapshotDaily?["hrv_rmssd_ms"] as? Double, 55.5)
        // Every other canonical key is untouched.
        XCTAssertEqual(snapshotDaily?["sleep_total_min"] as? Double, 420.0)
        XCTAssertEqual(result.snapshot["status"] as? String, "available")
        let provenance = snapshotDaily?["hrv_provenance"] as? [String: Any]
        XCTAssertEqual(provenance?["mode"] as? String, "active")
        XCTAssertEqual(provenance?["provider_id"] as? String, "production.runs.v1")
        XCTAssertEqual(provenance?["provider_version"] as? String, "1.0.0")
        XCTAssertEqual(provenance?["adapter_version"] as? String, "frwhoop.hrv.rmssd/1")
        XCTAssertEqual(provenance?["config_version"] as? String, "cfg-1")
        XCTAssertEqual(provenance?["canonical_source"] as? String, "provider")
        XCTAssertEqual(provenance?["fallback"] as? String, "legacy_hrv_analyzer")
        XCTAssertEqual((provenance?["input_sha256"] as? String)?.count, 64)

        let legacyDaily = (result.legacy["daily_metrics"] as? [[String: Any]])?.first
        XCTAssertEqual(legacyDaily?["hrv_rmssd_ms"] as? Double, 55.5)
        XCTAssertEqual(legacyDaily?["sleep_total_min"] as? Double, 420.0)
        XCTAssertEqual(legacyDaily?["day"] as? String, "2026-10-01")
    }

    func testActiveSubstitutionToleratesAnEmptyLegacyDailyList() {
        let substitution = CandidateStage.ActiveHrvSubstitution(
            value: 50.0, providerId: "p", providerVersion: "1", adapterVersion: "a",
            configVersion: "c", inputSHA256: "sha", mode: "active")
        let result = DayScorer.applyActiveHrvSubstitution(snapshot: snapshotPayload(),
                                                          legacy: ["daily_metrics": [[String: Any]]()],
                                                          substitution: substitution)
        XCTAssertEqual((result.snapshot["daily"] as? [String: Any])?["hrv_rmssd_ms"] as? Double, 50.0)
        XCTAssertEqual((result.legacy["daily_metrics"] as? [[String: Any]])?.count, 0)
    }
}
