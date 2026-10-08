import XCTest
@testable import StrandAnalytics

/// The server's metric explanations port Layer 1 (Tools/MetricInsight/src/nara_metric_insight/layer1.py) so they
/// call a night in or out of its usual exactly as the Home ring and the Monitor do. This pins the port to this
/// code: the cases are invented tapes (Tools/MetricInsight/scripts/make_layer1_cases.py), the expected results are
/// what `evaluate` and `vitalVerdict` give for them, and Tools/MetricInsight/tests/test_layer1.py checks the port
/// against the same file. A Layer 1 change fails here first: re-record with
/// `LAYER1_MIRROR_RECORD=1 swift test --filter LayerOneServerMirrorTests`, then update the port until its test passes.
final class LayerOneServerMirrorTests: XCTestCase {
    private struct Cases: Decodable { let cases: [Case] }
    private struct Case: Decodable {
        let name: String
        let series: String
        let asOf: String
        let nights: [Night]
        enum CodingKeys: String, CodingKey { case name, series, asOf = "as_of", nights }
    }
    private struct Night: Decodable {
        let day: String
        let value: Double?
        init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            day = try pair.decode(String.self)
            value = try pair.decodeIfPresent(Double.self)
        }
    }

    private static var dataDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/MetricInsight/tests/data")
    }

    func testRecordOrCompareTheServerMirrorCases() throws {
        let input = try Data(contentsOf: Self.dataDir.appendingPathComponent("layer1_cases.json"))
        let cases = try JSONDecoder().decode(Cases.self, from: input).cases
        XCTAssertGreaterThan(cases.count, 10)
        var actual: [String: Any] = [:]
        for c in cases {
            actual[c.name] = try Self.result(for: c)
        }
        let url = Self.dataDir.appendingPathComponent("layer1_expected.json")
        if ProcessInfo.processInfo.environment["LAYER1_MIRROR_RECORD"] == "1" {
            let document: [String: Any] = [
                "about": "Recorded by Packages/StrandAnalytics/Tests/StrandAnalyticsTests/LayerOneServerMirrorTests "
                    + "(LongitudinalBaseline.evaluate + vitalVerdict) for the cases in layer1_cases.json.",
                "param_set": LongitudinalBaseline.V2.paramSet,
                "expected": actual,
            ]
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                .write(to: url)
            return
        }
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(recorded["param_set"] as? String, LongitudinalBaseline.V2.paramSet,
                       "Layer 1's param set changed: re-record and update the server port")
        let expected = try XCTUnwrap(recorded["expected"] as? [String: Any])
        XCTAssertEqual(Set(expected.keys), Set(actual.keys), "the cases changed: re-record")
        for (name, value) in actual {
            assertSame(value, expected[name], at: name)
        }
    }

    private static func result(for c: Case) throws -> [String: Any] {
        let series = try XCTUnwrap(LBSeries(rawValue: c.series))
        let observations = c.nights.map {
            LongitudinalBaseline.observation(day: $0.day, native: $0.value, streamPresent: $0.value != nil,
                                             sleepHrOnly: false, series: series)
        }
        let ev = LongitudinalBaseline.evaluate(asOf: c.asOf, series: series, observations: observations)
        let verdict = LongitudinalBaseline.vitalVerdict(ev)
        func copy(_ snapshot: LBCopySnapshot?) -> Any {
            guard let s = snapshot else { return NSNull() }
            return ["center": s.center, "spread": s.spread, "center_display": s.centerDisplay,
                    "lo": s.bandLoDisplay, "hi": s.bandHiDisplay, "n": s.n, "held": s.held]
        }
        return [
            "today": ev.todayNative ?? NSNull(), "show7": ev.show7, "show_long": ev.showLong,
            "established_long": ev.establishedLong, "stale": ev.stale, "n7": ev.n7, "n_long": ev.nLong,
            "n_learn": ev.nLearn, "trust7": ev.usualTrustPct7, "trust_long": ev.usualTrustPctLong,
            "k_used": ev.kBandUsed, "z7": ev.z7 ?? NSNull(), "z_long": ev.zLong ?? NSNull(),
            "slope_usable": ev.slopeUsable, "regime_shift": ev.regimeShift, "p_change": ev.pChange,
            "expected_long": ev.expectedLong ?? NSNull(), "copy7": copy(ev.copy7), "copy_long": copy(ev.copyLong),
            "verdict": ["state": verdict.state.rawValue, "value": verdict.value ?? NSNull(),
                        "lo": verdict.bandLo ?? NSNull(), "hi": verdict.bandHi ?? NSNull(),
                        "from_week": verdict.fromWeek],
        ]
    }

    /// Numbers within 1e-9 (relative), everything else exactly; a JSON boolean is never a number.
    private func assertSame(_ actual: Any?, _ expected: Any?, at path: String) {
        switch (actual, expected) {
        case let (a as [String: Any], e as [String: Any]):
            XCTAssertEqual(Set(a.keys), Set(e.keys), path)
            for (key, value) in a { assertSame(value, e[key], at: "\(path).\(key)") }
        case let (a as Bool, e as NSNumber) where CFGetTypeID(e) == CFBooleanGetTypeID():
            XCTAssertEqual(a, e.boolValue, path)
        case let (a as String, e as String):
            XCTAssertEqual(a, e, path)
        case (is NSNull, is NSNull):
            break
        case let (a as Int, e as NSNumber) where CFGetTypeID(e) != CFBooleanGetTypeID():
            XCTAssertEqual(Double(a), e.doubleValue, path)
        case let (a as Double, e as NSNumber) where CFGetTypeID(e) != CFBooleanGetTypeID():
            let b = e.doubleValue
            XCTAssertLessThanOrEqual(abs(a - b), 1e-9 * max(1, abs(a), abs(b)), "\(path): \(a) vs \(b)")
        default:
            XCTFail("\(path): \(String(describing: actual)) vs \(String(describing: expected))")
        }
    }
}
