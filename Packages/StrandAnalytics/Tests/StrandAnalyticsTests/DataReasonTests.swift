import XCTest
@testable import StrandAnalytics

/// The Swift reason table must equal contracts/reason-codes.json (the edge function, SQL registry and Python mirror
/// are pinned to the same file by their own tests).
final class DataReasonTests: XCTestCase {
    private func contract() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/reason-codes.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testTableEqualsContract() throws {
        let c = try contract()
        XCTAssertEqual(c["version"] as? String, DataReasonCatalog.version)
        let codes = try XCTUnwrap(c["codes"] as? [[String: Any]])
        XCTAssertEqual(codes.count, DataReasonCatalog.codes.count)
        for (j, s) in zip(codes, DataReasonCatalog.codes) {
            XCTAssertEqual(j["code"] as? String, s.code)
            XCTAssertEqual(j["family"] as? String, s.family)
            XCTAssertEqual(j["default_certainty"] as? String, s.defaultCertainty.rawValue)
            XCTAssertEqual(j["effect"] as? String, s.effect.rawValue)
        }
        let legacy = try XCTUnwrap(c["legacy"] as? [String: [String: [String: String]]])
        XCTAssertEqual(Set(legacy.keys), Set(DataReasonCatalog.legacy.keys))
        for (vocab, m) in legacy {
            XCTAssertEqual(Set(m.keys), Set(DataReasonCatalog.legacy[vocab]?.keys.map { $0 } ?? []), vocab)
            for (k, v) in m {
                let s = try XCTUnwrap(DataReasonCatalog.legacy[vocab]?[k])
                XCTAssertEqual(v["code"], s.code, "\(vocab).\(k)")
                XCTAssertEqual(v["certainty"], s.certainty.rawValue, "\(vocab).\(k)")
                XCTAssertEqual(v["subcode"], s.subcode, "\(vocab).\(k)")
                XCTAssertNotNil(DataReasonCatalog.byCode[s.code], "\(vocab).\(k) maps to an unknown code")
            }
        }
    }

    func testEveryWatchdogQualityReasonTheAssessorEmitsIsMappedOrInformational() {
        // Informational evidence notes that are not causes.
        let informational: Set<String> = ["beat_coverage_only", "motion_from_occupancy"]
        let emitted = ["wrist_off_event", "optical_baseline_zero", "charging", "strap_reset_unrecovered", "hr_absent",
                       "skin_temp_unconfirmed", "rr_pileup", "optical_saturation", "contact_not_detected",
                       "optical_sentinel", "motion_mode_optics", "beat_coverage_low", "beat_overcount",
                       "hr_in_motion_unverified", "optical_sentinel_at_rest", "no_signal_metadata", "no_motion_sample"]
        for r in emitted where !informational.contains(r) {
            XCTAssertNotNil(DataReason.from(vocabulary: "watchdog_quality", legacy: r), r)
        }
        // An inferred cause is never reported as confirmed.
        XCTAssertEqual(DataReason.from(vocabulary: "watchdog_quality", legacy: "motion_mode_optics")?.certainty, .inferred)
        XCTAssertEqual(DataReason.from(vocabulary: "watchdog_quality", legacy: "wrist_off_event")?.certainty, .confirmed)
    }
}
