import XCTest
@testable import StrandAnalytics

/// Replays `Tools/ActivityContext/fixtures/hsmm_golden.json` (the Python port's golden, generated from the
/// Swift decoder at hsmm-1.5) through today's Swift decoder. The hsmm-1.6 changes only act on inputs those
/// IMU-only scenarios never carry (HART fine probabilities, ElderNet windows, a gravity-driven shift
/// strength beside the transition expert), so both the Swift decoder and the Python port must still
/// reproduce every checkpoint to 1e-9.
final class ActivityHsmmGoldenParityTests: XCTestCase {

    private static let golden = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/ActivityContext/fixtures/hsmm_golden.json")

    private func d(_ x: Any?) -> Double? { (x as? NSNumber)?.doubleValue }

    func testSwiftDecoderStillReproducesThePythonPortGolden() throws {
        guard let data = try? Data(contentsOf: Self.golden) else { throw XCTSkip("golden fixture not present") }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let scenarios = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
        XCTAssertFalse(scenarios.isEmpty)
        for sc in scenarios {
            let name = sc["name"] as? String ?? "?"
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
            let track = ActivityContextTrackBuilder.build(input)

            let wantEvents = sc["events"] as? [[String: Any]] ?? []
            XCTAssertEqual(track.events.count, wantEvents.count, "\(name): event count")
            for (g, w) in zip(track.events, wantEvents) {
                XCTAssertEqual(g.kind.rawValue, w["kind"] as? String, name)
                XCTAssertEqual(g.ts, w["ts"] as? Int, name)
                XCTAssertEqual(g.probability, d(w["prob"]) ?? -1, accuracy: 1e-9, name)
            }
            let byTs = Dictionary(track.states.map { ($0.ts, $0) }, uniquingKeysWith: { $1 })
            for w in sc["states"] as? [[String: Any]] ?? [] {
                let ts = w["ts"] as! Int
                guard let s = byTs[ts] else { XCTFail("\(name): checkpoint \(ts) not published"); continue }
                func check<C>(_ head: HeadProbabilities<C>, _ key: String) {
                    for (k, v) in w[key] as? [String: Any] ?? [:] {
                        let c = C(rawValue: k)!
                        XCTAssertEqual(head[c], d(v)!, accuracy: 1e-9, "\(name)@\(ts) \(key)[\(k)]")
                    }
                }
                check(s.posture, "posture")
                check(s.locomotion, "locomotion")
                check(s.armBehavior, "arm_behavior")
                XCTAssertEqual(s.overallConfidence, d(w["overall_confidence"])!, accuracy: 1e-9, "\(name)@\(ts)")
                XCTAssertEqual(s.overallUncertainty, d(w["overall_uncertainty"])!, accuracy: 1e-9, "\(name)@\(ts)")
            }
        }
    }
}
