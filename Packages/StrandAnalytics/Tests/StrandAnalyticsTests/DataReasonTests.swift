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

/// Observed quality reasons from the strap's own record stream (audit 2026-10-09, B-quality).
final class WatchdogRecordIndexQualityTests: XCTestCase {
    func testRecordIndexGapSeparatesNotRecordingFromTransportLoss() {
        let now = 1_790_000_000 - 1_790_000_000 % 60
        let feed = Watchdog.syntheticFeed(now: now, hr: 70, hrv: 50, temp: 33.5, resp: 14, motion: 0.02)
        guard case .success(var w) = WatchdogWindowBuilder.build(feed) else { return XCTFail("window") }
        // HR missing for minutes 10–19 of the window.
        for i in 10..<20 { w.hr[i] = nil }
        var q = WatchdogQualityFeed.synthetic(for: w)
        for i in 10..<20 { q.hrSecondsByMinute[w.startUnix + i * 60] = 0 }
        // Records every second except a paused stretch (index +1 across 10 minutes) …
        var idx = 1000
        for t in stride(from: w.startUnix, to: w.startUnix + 10 * 60, by: 1) { q.v18RecordIndex[t] = idx; idx += 1 }
        for t in stride(from: w.startUnix + 20 * 60, to: now, by: 1) { q.v18RecordIndex[t] = idx; idx += 1 }
        w.quality = q
        let paused = WatchdogSignalQuality.assess(window: w)
        XCTAssertEqual(paused[14].onBody, .off)
        XCTAssertTrue(paused[14].reasons.contains("strap_not_recording"))
        XCTAssertEqual(DataReason.fromWatchdogQuality(paused[14].reasons).first?.code, "strap_not_recording")
        // … versus records lost in transport (index jumps by the gap): wear stays unknown, the gap is named.
        var q2 = q
        q2.v18RecordIndex = [:]
        idx = 1000
        for t in stride(from: w.startUnix, to: now, by: 1) {
            if t < w.startUnix + 10 * 60 || t >= w.startUnix + 20 * 60 { q2.v18RecordIndex[t] = idx }
            idx += 1
        }
        w.quality = q2
        let lost = WatchdogSignalQuality.assess(window: w)
        XCTAssertNotEqual(lost[14].onBody, .off)
        XCTAssertTrue(lost[14].reasons.contains("transport_gap"))
    }
}
