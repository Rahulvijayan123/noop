import XCTest
@testable import StrandAnalytics

/// The server's step explanations read a day's ElderNet gait the way the "How you walked" card does
/// (Tools/MetricInsight/src/nara_metric_insight/gait.py). This pins that port to this code: the cases are invented
/// `gait-windows-1` days (Tools/MetricInsight/scripts/make_gait_cases.py), the expected readings are what
/// `GaitWindowColumns` + `WalkingDayReading` give for them, and Tools/MetricInsight/tests/test_gait.py checks the port
/// against the same file. Re-record after a deliberate change with
/// `GAIT_MIRROR_RECORD=1 swift test --filter GaitServerMirrorTests`, then update the port until its test passes.
final class GaitServerMirrorTests: XCTestCase {
    private static var dataDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/MetricInsight/tests/data")
    }

    func testRecordOrCompareTheServerMirrorCases() throws {
        let input = try Data(contentsOf: Self.dataDir.appendingPathComponent("gait_cases.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
        let cases = try XCTUnwrap(document["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 5)
        var actual: [String: Any] = [:]
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let days = (c["days"] as? [Any] ?? []).compactMap { GaitWindowColumns($0) }
            XCTAssertEqual(days.count, (c["days"] as? [Any])?.count, "\(name): every stored day decodes")
            let from = try XCTUnwrap((c["from"] as? NSNumber)?.intValue)
            let to = try XCTUnwrap((c["to"] as? NSNumber)?.intValue)
            actual[name] = Self.result(WalkingDayReading(days: days, from: from, to: to))
        }
        let url = Self.dataDir.appendingPathComponent("gait_expected.json")
        if ProcessInfo.processInfo.environment["GAIT_MIRROR_RECORD"] == "1" {
            let out: [String: Any] = [
                "about": "Recorded by Packages/StrandAnalytics/Tests/StrandAnalyticsTests/GaitServerMirrorTests "
                    + "(GaitWindowColumns + WalkingDayReading) for the cases in gait_cases.json.",
                "expected": actual,
            ]
            try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            return
        }
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let expected = try XCTUnwrap(recorded["expected"] as? [String: Any])
        XCTAssertEqual(Set(expected.keys), Set(actual.keys), "the cases changed: re-record")
        for (name, value) in actual {
            assertSame(value, expected[name], at: name)
        }
    }

    private static func result(_ r: WalkingDayReading) -> [String: Any] {
        func number(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
        return [
            "walking_seconds": r.walkingSeconds, "brisk_seconds": r.briskSeconds, "steps": number(r.steps),
            "cadence_spm": number(r.cadenceSpm), "speed_mps": number(r.speedMps), "stride_m": number(r.strideM),
            "regularity": number(r.regularity), "assessed_windows": r.assessedWindows,
            "cadence_band_seconds": r.cadenceBandSeconds, "hourly_seconds": r.hourlySeconds,
            "typical_speed_mps": number(r.typicalSpeedMps),
            "bouts": r.bouts.map { ["start": $0.start, "end": $0.end, "cadence_spm": number($0.cadenceSpm),
                                    "speed_mps": number($0.speedMps), "steps": $0.steps] as [String: Any] },
        ]
    }

    /// Numbers within 1e-9 (relative), everything else exactly; a JSON boolean is never a number.
    private func assertSame(_ actual: Any?, _ expected: Any?, at path: String) {
        switch (actual, expected) {
        case let (a as [String: Any], e as [String: Any]):
            XCTAssertEqual(Set(a.keys), Set(e.keys), path)
            for (key, value) in a { assertSame(value, e[key], at: "\(path).\(key)") }
        case let (a as [Any], e as [Any]):
            XCTAssertEqual(a.count, e.count, path)
            for (i, pair) in zip(a, e).enumerated() { assertSame(pair.0, pair.1, at: "\(path)[\(i)]") }
        case (is NSNull, is NSNull):
            break
        case let (a as Int, e as NSNumber):
            XCTAssertEqual(Double(a), e.doubleValue, path)
        case let (a as Double, e as NSNumber):
            let b = e.doubleValue
            XCTAssertLessThanOrEqual(abs(a - b), 1e-9 * max(1, abs(a), abs(b)), "\(path): \(a) vs \(b)")
        default:
            XCTFail("\(path): \(String(describing: actual)) vs \(String(describing: expected))")
        }
    }
}
