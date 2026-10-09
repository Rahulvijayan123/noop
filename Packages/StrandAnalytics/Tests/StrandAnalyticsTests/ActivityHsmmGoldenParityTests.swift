import XCTest
@testable import StrandAnalytics

/// Replays `Tools/ActivityContext/fixtures/hsmm_golden.json` (the Python port's golden, generated from the
/// Swift decoder at hsmm-1.5) through today's Swift decoder.
///
/// The hsmm-1.6 and 1.7 changes only acted on inputs those IMU-only scenarios never carry, so the Swift
/// decoder reproduced every checkpoint to 1e-9. hsmm-1.8 changes them on purpose: the seated / upright split of
/// a quiet wrist is now bounded by real posture evidence instead of drifting to "seated 0.83" on the dwell prior,
/// the quiet posture-shift heuristic no longer vetoes the transition expert, and a pulseless strap is wear
/// unknown. The Python port (`Tools/ActivityContext/activity_context/hsmm.py`, whose own test pins the fixture at
/// hsmm-1.5) is not ported to 1.8 yet, so strict Swift ↔ Python parity cannot hold until it is.
///
/// Honest regeneration: `testTheParityScenariosReproduceTheirSwiftGolden` replays the SAME scenario inputs and
/// pins today's Swift output in `Goldens/ActivityContext/hsmm_parity_golden.json`, in the fixture's own format
/// (re-record with `ACTIVITY_GOLDEN_RECORD=1`). Porting hsmm-1.8 to Python means making `test_hsmm.py` reproduce
/// that file and copying it over the Tools fixture; this test then compares strictly again (the stamps match).
final class ActivityHsmmGoldenParityTests: XCTestCase {

    private static let golden = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/ActivityContext/fixtures/hsmm_golden.json")

    private static let swiftGolden = ActivityContextGoldenTests.fixtureRoot()
        .appendingPathComponent("hsmm_parity_golden.json")

    private func d(_ x: Any?) -> Double? { (x as? NSNumber)?.doubleValue }

    private func track(_ sc: [String: Any]) -> ActivityContextTrack {
        let imu = (sc["imu_windows"] as? [[String: Any]] ?? []).map { w in
            ImuWindowFeatures(startTs: w["s"] as! Int, endTs: w["e"] as! Int,
                              accelRmsG: d(w["accel_rms_g"])!, gyroRmsDps: d(w["gyro_rms_dps"])!,
                              jerkRms: d(w["jerk_rms"])!, cadenceHz: d(w["cadence_hz"]),
                              cadenceStrength: d(w["cadence_strength"])!,
                              orientationChangeDeg: d(w["orientation_change_deg"]))
        }
        let enc = (sc["encoder_windows"] as? [[String: Any]] ?? []).map { w in
            ActivityWindowPrediction(startTs: w["s"] as! Int, endTs: w["e"] as! Int,
                                     label: MotionLabel(rawValue: w["label"] as! String) ?? .unknown,
                                     probs: (w["probs"] as! [String: Any]).mapValues { d($0)! },
                                     baseline: w["baseline"] as? Bool ?? false,
                                     calibrated: w["calibrated"] as? Bool ?? false)
        }
        let trans = (sc["transition_windows"] as? [[String: Any]] ?? []).map { w in
            ActivityTransitionWindow(startTs: w["s"] as! Int, endTs: w["e"] as! Int,
                                     probabilities: (w["probabilities"] as! [Any]).map { d($0)! },
                                     modelVersion: w["model_version"] as! String,
                                     preprocessingVersion: w["preprocessing_version"] as! String,
                                     abstained: w["abstained"] as? Bool ?? false)
        }
        let input = ActivityContextTrackInput(dayStart: sc["start_ts"] as! Int, dayEnd: sc["end_ts"] as! Int,
                                              encoderWindows: enc, imuWindows: imu, transitionWindows: trans)
        return ActivityContextTrackBuilder.build(input)
    }

    /// Compare one scenario's track with a golden scenario's events and checkpoints, to 1e-9.
    private func assertMatches(_ track: ActivityContextTrack, _ sc: [String: Any], source: String) {
        let name = sc["name"] as? String ?? "?"
        let wantEvents = sc["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(track.events.count, wantEvents.count, "\(source) \(name): event count")
        for (g, w) in zip(track.events, wantEvents) {
            XCTAssertEqual(g.kind.rawValue, w["kind"] as? String, name)
            XCTAssertEqual(g.ts, w["ts"] as? Int, name)
            XCTAssertEqual(g.probability, d(w["prob"]) ?? -1, accuracy: 1e-9, name)
        }
        let byTs = Dictionary(track.states.map { ($0.ts, $0) }, uniquingKeysWith: { $1 })
        for w in sc["states"] as? [[String: Any]] ?? [] {
            let ts = w["ts"] as! Int
            guard let s = byTs[ts] else { XCTFail("\(source) \(name): checkpoint \(ts) not published"); continue }
            func check<C>(_ head: HeadProbabilities<C>, _ key: String) {
                for (k, v) in w[key] as? [String: Any] ?? [:] {
                    let c = C(rawValue: k)!
                    XCTAssertEqual(head[c], d(v)!, accuracy: 1e-9, "\(source) \(name)@\(ts) \(key)[\(k)]")
                }
            }
            check(s.posture, "posture")
            check(s.locomotion, "locomotion")
            check(s.armBehavior, "arm_behavior")
            XCTAssertEqual(s.overallConfidence, d(w["overall_confidence"])!, accuracy: 1e-9, "\(source) \(name)@\(ts)")
            XCTAssertEqual(s.overallUncertainty, d(w["overall_uncertainty"])!, accuracy: 1e-9, "\(source) \(name)@\(ts)")
        }
    }

    private func loadPythonGolden() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.golden) else { throw XCTSkip("golden fixture not present") }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSwiftDecoderStillReproducesThePythonPortGolden() throws {
        let root = try loadPythonGolden()
        let stamp = root["decoder"] as? String
        guard stamp == ActivityContextVersions.decoder else {
            throw XCTSkip("Python port golden is \(stamp ?? "?"), the Swift decoder is \(ActivityContextVersions.decoder): "
                          + "port hsmm.py and regenerate the fixture from Goldens/ActivityContext/hsmm_parity_golden.json "
                          + "(testTheParityScenariosReproduceTheirSwiftGolden pins the Swift side meanwhile)")
        }
        let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
        XCTAssertFalse(scenarios.isEmpty)
        for sc in scenarios { assertMatches(track(sc), sc, source: "python-port golden") }
    }

    /// The parity scenarios through today's decoder, in the Python fixture's format.
    private func regenerate(_ root: [String: Any]) throws -> [String: Any] {
        let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
        var out: [[String: Any]] = []
        for sc in scenarios {
            let t = track(sc)
            var copy = sc
            copy["events"] = t.events.map { ["kind": $0.kind.rawValue, "prob": $0.probability, "ts": $0.ts] as [String: Any] }
            let byTs = Dictionary(t.states.map { ($0.ts, $0) }, uniquingKeysWith: { $1 })
            copy["states"] = (sc["states"] as? [[String: Any]] ?? []).compactMap { w -> [String: Any]? in
                guard let ts = w["ts"] as? Int, let s = byTs[ts] else { return nil }
                func head<C>(_ h: HeadProbabilities<C>) -> [String: Double] {
                    Dictionary(uniqueKeysWithValues: C.allCases.map { ($0.rawValue, h[$0]) })
                }
                var row: [String: Any] = ["ts": ts, "posture": head(s.posture), "locomotion": head(s.locomotion),
                                          "arm_behavior": head(s.armBehavior),
                                          "overall_confidence": s.overallConfidence,
                                          "overall_uncertainty": s.overallUncertainty]
                if let i = s.intensity { row["intensity"] = i }
                if let e = s.transition { row["transition"] = ["kind": e.kind.rawValue, "prob": e.probability, "ts": e.ts] }
                return row
            }
            out.append(copy)
        }
        return ["decoder": ActivityContextVersions.decoder,
                "generator": "ActivityHsmmGoldenParityTests (StrandAnalytics, Swift) from the scenario inputs of "
                    + "Tools/ActivityContext/fixtures/hsmm_golden.json",
                "scenarios": out]
    }

    func testTheParityScenariosReproduceTheirSwiftGolden() throws {
        let root = try loadPythonGolden()
        let fresh = try regenerate(root)
        if ActivityContextGoldenTests.recording {
            let data = try JSONSerialization.data(withJSONObject: fresh, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: Self.swiftGolden, options: .atomic)
            throw XCTSkip("recorded \(Self.swiftGolden.lastPathComponent)")
        }
        let data = try Data(contentsOf: Self.swiftGolden)
        let pinned = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(pinned["decoder"] as? String, ActivityContextVersions.decoder,
                       "re-record the Swift parity golden for a deliberate decoder change")
        let inputs = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
        let want = try XCTUnwrap(pinned["scenarios"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, want.count)
        for (sc, w) in zip(inputs, want) { assertMatches(track(sc), w, source: "swift parity golden") }
    }
}
