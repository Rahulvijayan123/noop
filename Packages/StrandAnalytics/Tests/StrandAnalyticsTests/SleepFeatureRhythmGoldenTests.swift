import XCTest
@testable import StrandAnalytics

/// spec-02 rhythm producer -> app roundtrip: the Python sidecar's observed skin-temperature rhythm
/// and rest-activity blocks (golden written by `test_committed_rhythm_golden_matches_the_producer`
/// in Tools/InferenceWorker/tests/test_features_rhythm.py) decode into the app types with every
/// value, status and reason intact. A key rename on either side fails here.
final class SleepFeatureRhythmGoldenTests: XCTestCase {

    private func golden() throws -> (Data, [String: Any]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens/SleepFeatures/spec02_rhythm_blocks.json")
        let data = try Data(contentsOf: url)
        return (data, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    private struct Blocks: Decodable {
        let observedSkinTempRhythm: SleepObservedRhythm
        let restActivityRhythm: SleepRestActivityRhythm
        enum CodingKeys: String, CodingKey {
            case observedSkinTempRhythm = "observed_skin_temp_rhythm"
            case restActivityRhythm = "rest_activity_rhythm"
        }
    }

    func testObservedRhythmDecodesEveryProducedField() throws {
        let (data, raw) = try golden()
        let blocks = try JSONDecoder().decode(Blocks.self, from: data)
        let r = blocks.observedSkinTempRhythm
        let t = try XCTUnwrap(raw["observed_skin_temp_rhythm"] as? [String: Any])
        XCTAssertEqual(r.status, .available)
        XCTAssertEqual(r.methodVersion, "skin-temp-rhythm-1")
        XCTAssertEqual(r.mesorC, t["mesor_c"] as? Double)
        XCTAssertEqual(r.amplitudeC, t["amplitude_c"] as? Double)
        XCTAssertEqual(r.acrophaseH, t["acrophase_h"] as? Double)
        XCTAssertEqual(r.fitQuality, t["fit_quality"] as? Double)
        XCTAssertEqual(r.isValue, t["is"] as? Double)
        XCTAssertEqual(r.iv, t["iv"] as? Double)
        XCTAssertEqual(r.dailyAmplitudeC, t["daily_amplitude_c"] as? Double)
        XCTAssertEqual(r.phaseStabilityH, t["phase_stability_h"] as? Double)
        XCTAssertEqual(r.qualifyingDays, 9)
        XCTAssertEqual(r.daysEvaluated, 9)
        XCTAssertEqual(r.historyRevisionDigest, t["history_revision_digest"] as? String)
        XCTAssertEqual(r.ivDefinition, "consecutive_valid_hour_pairs_across_midnight")
        XCTAssertEqual(r.phaseStatus?.status, .available)
        let cov = try XCTUnwrap(t["coverage"] as? [String: Any])
        XCTAssertEqual(r.coverage?.dayHoursSupported, cov["day_hours_supported"] as? Int)
        XCTAssertEqual(r.coverage?.nightHoursSupported, cov["night_hours_supported"] as? Int)
        XCTAssertEqual(r.coverage?.quadrantsObserved, [true, true, true, true])
        let unc = try XCTUnwrap(t["uncertainty"] as? [String: Any])
        XCTAssertEqual(r.uncertainty?.acrophaseSeH, unc["acrophase_se_h"] as? Double)
        XCTAssertEqual(r.uncertainty?.amplitudeSeC, unc["amplitude_se_c"] as? Double)
        XCTAssertEqual(r.uncertainty?.method, unc["method"] as? String)

        let rel = try XCTUnwrap(r.phaseRelations?.hrMinusTemp)
        let relRaw = try XCTUnwrap((t["phase_relations"] as? [String: Any])?["hr_minus_temp"] as? [String: Any])
        XCTAssertEqual(rel.status, .available)
        XCTAssertEqual(rel.aLabel, "heart_rate_acrophase")
        XCTAssertEqual(rel.aH, relRaw["a_h"] as? Double)
        XCTAssertEqual(rel.bH, relRaw["b_h"] as? Double)
        XCTAssertEqual(rel.differenceH, relRaw["difference_h"] as? Double)
        XCTAssertEqual(rel.supportDays, 9)
        XCTAssertEqual(r.phaseRelations?.sleepMidpointMinusTemp?.status, .available)

        let drift = try XCTUnwrap(r.phaseDrift)
        let driftRaw = try XCTUnwrap(t["phase_drift"] as? [String: Any])
        XCTAssertEqual(drift.status, .available)
        XCTAssertEqual(drift.utcDriftHPerDay, driftRaw["utc_drift_h_per_day"] as? Double)
        XCTAssertEqual(drift.daysUsed, 9)
        XCTAssertEqual(drift.dailyPhases.count, 9)
        XCTAssertEqual(drift.dailyPhases.first?.utcOffsetH, -7)
        XCTAssertEqual(drift.dailyPhases.last?.utcOffsetH, -4)
        XCTAssertEqual(drift.clockChanges.count, 1)
        XCTAssertEqual(drift.clockChanges.first?.kind, "timezone")
        XCTAssertEqual(drift.clockChanges.first?.fromOffsetH, -7)
        XCTAssertEqual(drift.clockChanges.first?.toOffsetH, -4)
        let real = try XCTUnwrap(drift.observedRealignment)
        XCTAssertEqual(real.status, .available)
        XCTAssertEqual(real.clockShiftH, 3)
        XCTAssertEqual(real.daysSinceChange, 4)
        XCTAssertNotNil(real.fractionRealigned)
    }

    func testRestActivityRhythmDecodes() throws {
        let (data, raw) = try golden()
        let ra = try JSONDecoder().decode(Blocks.self, from: data).restActivityRhythm
        let r = try XCTUnwrap(raw["rest_activity_rhythm"] as? [String: Any])
        XCTAssertEqual(ra.status, .available)
        XCTAssertEqual(ra.methodVersion, "rest-activity-1")
        XCTAssertEqual(ra.signal, "gravity_movement_seconds_per_minute")
        XCTAssertEqual(ra.epochSeconds, 3600)
        XCTAssertEqual(ra.isValue, r["is"] as? Double)
        XCTAssertEqual(ra.iv, r["iv"] as? Double)
        XCTAssertEqual(ra.l5, r["l5"] as? Double)
        XCTAssertEqual(ra.m10, r["m10"] as? Double)
        XCTAssertEqual(ra.l5StartH, r["l5_start_h"] as? Double)
        XCTAssertEqual(ra.m10StartH, r["m10_start_h"] as? Double)
        XCTAssertEqual(ra.ra, r["ra"] as? Double)
        XCTAssertEqual(ra.daysUsed, 9)
        XCTAssertEqual(ra.gate, r["gate"] as? String)
    }

    func testUnavailablePhaseStatusDecodes() throws {
        let json = #"{"status":"partial","reasons":["zero_amplitude"],"phase_status":{"status":"unavailable","reasons":["zero_amplitude"]}}"#
        let r = try JSONDecoder().decode(SleepObservedRhythm.self, from: Data(json.utf8))
        XCTAssertEqual(r.status, .partial)
        XCTAssertEqual(r.phaseStatus?.status, .unavailable)
        XCTAssertEqual(r.phaseStatus?.reasons, ["zero_amplitude"])
        XCTAssertNil(r.acrophaseH)
    }
}
