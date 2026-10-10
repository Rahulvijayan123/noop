import XCTest
import WhoopStore
@testable import StrandAnalytics

/// The phenotype-signature engine compares heart rate and HRV with the person's Layer 1 v2 context-strata references
/// (Tools/PersonalEventDetection/personal_events/layer1_context.py), so a minute counts as unusual by how far it is
/// from the same baseline the Watchdog draws. This pins that port to this code: the cases are invented interval
/// tapes (Tools/PersonalEventDetection/scripts/make_layer1_context_cases.py), the expected results are what
/// `ContextMaterializer.observations`, `evaluate` (as of each day, from the days before it),
/// `WatchdogLiveReferences.lookup` and `WatchdogExpectation.track` give for them, and
/// Tools/PersonalEventDetection/tests/test_layer1_context.py checks the port against the same file. A change to the
/// materializer, Layer 1 or the Watchdog expectation fails here first: re-record with
/// `LAYER1_CONTEXT_RECORD=1 swift test --filter LayerOneContextMirrorTests`, then update the port until its test passes.
final class LayerOneContextMirrorTests: XCTestCase {
    static let series: [LBSeries] = [
        .sleepHR, .awakeRestHR, .awakeRestHRVLn, .awakeSupineHR, .awakeSupineHRVLn, .awakeSeatedHR,
        .awakeSeatedHRVLn, .awakeUprightHR, .awakeUprightHRVLn, .walkingHR, .exerciseSessionHR, .exerciseRecoveryHR,
    ]
    static let kinds: [(WatchdogMinuteContextKind, LBPosture?)] = [
        (.asleep, nil), (.awakeStill, nil), (.awakeStill, .supine), (.awakeStill, .seated), (.awakeStill, .upright),
        (.walking, nil), (.active, nil), (.exerciseSession, nil), (.recovery, nil), (.unknown, nil),
    ]

    private static var dataDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/PersonalEventDetection/tests/data")
    }

    func testRecordOrCompareTheContextMirrorCases() throws {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.dataDir.appendingPathComponent("layer1_context_cases.json"))) as? [String: Any])
        let cases = try XCTUnwrap(input["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 3)
        var actual: [String: Any] = [:]
        for c in cases {
            actual[try XCTUnwrap(c["name"] as? String)] = try Self.result(for: c)
        }
        let url = Self.dataDir.appendingPathComponent("layer1_context_expected.json")
        if ProcessInfo.processInfo.environment["LAYER1_CONTEXT_RECORD"] == "1" {
            let document: [String: Any] = [
                "about": "Recorded by Packages/StrandAnalytics/Tests/StrandAnalyticsTests/LayerOneContextMirrorTests "
                    + "(ContextMaterializer.observations + LongitudinalBaseline.evaluate + WatchdogLiveReferences."
                    + "lookup + WatchdogExpectation.track) for the cases in layer1_context_cases.json.",
                "param_set": LongitudinalBaseline.V2.paramSet,
                "materializer": LongitudinalBaseline.ContextMaterializer.version,
                "expected": actual,
            ]
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                .write(to: url)
            return
        }
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(recorded["param_set"] as? String, LongitudinalBaseline.V2.paramSet,
                       "Layer 1's param set changed: re-record and update the port")
        XCTAssertEqual(recorded["materializer"] as? String, LongitudinalBaseline.ContextMaterializer.version,
                       "the materializer changed: re-record and update the port")
        let expected = try XCTUnwrap(recorded["expected"] as? [String: Any])
        XCTAssertEqual(Set(expected.keys), Set(actual.keys), "the cases changed: re-record")
        for (name, value) in actual {
            assertSame(value, expected[name], at: name)
        }
    }

    // MARK: - One case

    private static func row(_ a: [Any]) -> ActivityContextIntervalRow {
        func int(_ i: Int) -> Int { (a[i] as! NSNumber).intValue }
        func dbl(_ i: Int) -> Double { (a[i] as! NSNumber).doubleValue }
        func optDbl(_ i: Int) -> Double? { (a[i] as? NSNumber)?.doubleValue }
        func optStr(_ i: Int) -> String? { i < a.count ? a[i] as? String : nil }
        return ActivityContextIntervalRow(
            startTs: int(0), endTs: int(1), activityClass: a[2] as! String, confidence: dbl(3),
            evidenceQuality: dbl(4), posture: optStr(5), locomotion: optStr(6), armBehavior: optStr(17),
            sleepState: a[7] as! String, wearState: a[8] as! String, intensity: optDbl(9), hrSamples: int(10),
            hrMean: optDbl(11), rmssd: optDbl(12), rrBeats: int(13), rrDiffSqSumMs2: dbl(14), rrDiffCount: int(15),
            detail: optStr(16))
    }

    private static func json(_ x: Double?) -> Any { x.map { $0 as Any } ?? NSNull() }

    private static func result(for c: [String: Any]) throws -> [String: Any] {
        let tz = try XCTUnwrap((c["tz_offset_s"] as? NSNumber)?.intValue)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: tz))
        let rows = try XCTUnwrap(c["rows"] as? [[Any]]).map(row)
        let observations = LongitudinalBaseline.ContextMaterializer.observations(rows: rows, calendar: calendar)

        var obsOut: [String: Any] = [:]
        for (series, list) in observations {
            obsOut[series.rawValue] = list.map { o -> [Any] in
                [o.day, json(o.value), o.qualityStatus.rawValue, json(o.coverage), json(o.withinDayScale)]
            }
        }

        let asOfDays = try XCTUnwrap(c["as_of"] as? [NSNumber]).map(\.intValue)
        let minuteRows = try XCTUnwrap(c["minutes"] as? [[Any]])
        var evalOut: [String: Any] = [:]
        var refOut: [String: Any] = [:]
        var trackOut: [String: Any] = [:]
        for day in asOfDays {
            let iso = LongitudinalBaseline.isoFromEpochDay(day)
            // As of `day`, from the days before it (the engine never lets a day's own value into its reference).
            let evals = series.map { s in
                LongitudinalBaseline.evaluate(asOf: iso, series: s,
                                              observations: (observations[s] ?? []).filter { $0.day < iso })
            }
            var perSeries: [String: Any] = [:]
            for ev in evals {
                let copy = ev.copyLong
                let status: String
                if let _ = copy, !ev.stale {
                    status = ev.establishedLong ? "established" : "provisional"
                } else {
                    status = "none"
                }
                perSeries[ev.series.rawValue] = [
                    "n_long": ev.nLong, "show_long": ev.showLong, "established_long": ev.establishedLong,
                    "stale": ev.stale, "maturity": ev.maturity.rawValue, "status": status,
                    "center": json(copy?.center), "spread": json(copy?.spread),
                    "predictive_spread": json(copy?.predictiveSpread), "n_eff": json(copy?.nEff),
                    "within_day_scale_long": json(ev.withinDayScaleLong),
                ] as [String: Any]
            }
            evalOut[String(day)] = perSeries

            var refs: [String: Any] = [:]
            for (kind, posture) in kinds {
                for channel in ["HR", "HRV"] {
                    let key = "\(channel)|\(kind.rawValue)|\(posture?.rawValue ?? "-")"
                    if let r = WatchdogLiveReferences.lookup(evals, kind: kind, posture: posture, channel: channel) {
                        refs[key] = ["series": r.series.rawValue, "center": r.center, "scale": r.scale,
                                     "within_known": r.withinDayKnown] as [String: Any]
                    } else {
                        refs[key] = NSNull()
                    }
                }
            }
            refOut[String(day)] = refs

            let context: [WatchdogMinuteContext] = minuteRows
                .filter { ($0[6] as! NSNumber).intValue == day }
                .map { m in
                    WatchdogMinuteContext(
                        minuteUnix: (m[0] as! NSNumber).intValue,
                        kind: WatchdogMinuteContextKind(rawValue: m[1] as! String)!,
                        posture: (m[2] as? String).flatMap(LBPosture.init(rawValue:)),
                        sinceEffortS: (m[3] as? NSNumber)?.intValue, sinceWalkingS: (m[4] as? NSNumber)?.intValue,
                        recentTransition: (m[5] as! NSNumber).boolValue,
                        settling: (m[7] as! NSNumber).boolValue)
                }
            var perChannel: [String: Any] = [:]
            for channel in ["HR", "HRV"] {
                let t = WatchdogExpectation.track(channel: channel, context: context, evaluations: evals)
                perChannel[channel] = (0..<context.count).map { i -> [Any] in
                    [json(t.center[i]), json(t.scale[i]), t.series[i].map { $0.rawValue as Any } ?? NSNull()]
                }
            }
            trackOut[String(day)] = perChannel
        }
        return ["observations": obsOut, "evaluations": evalOut, "references": refOut, "track": trackOut]
    }

    /// Numbers within 1e-9 (relative), everything else exactly; a JSON boolean is never a number.
    private func assertSame(_ actual: Any?, _ expected: Any?, at path: String) {
        switch (actual, expected) {
        case let (a as [String: Any], e as [String: Any]):
            XCTAssertEqual(Set(a.keys), Set(e.keys), path)
            for (key, value) in a { assertSame(value, e[key], at: "\(path).\(key)") }
        case let (a as [Any], e as [Any]):
            XCTAssertEqual(a.count, e.count, path)
            for (i, (x, y)) in zip(a, e).enumerated() { assertSame(x, y, at: "\(path)[\(i)]") }
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
