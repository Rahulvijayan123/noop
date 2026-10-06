import XCTest
@testable import StrandAnalytics

/// The `gait-quality-1` wire decoder (ELDERNET.md §4): everything it accepts, everything it refuses, and that
/// every Codable path refuses the same things.
final class GaitQualityResponseTests: XCTestCase {

    private typealias E = GaitQualityResponseError

    private func good(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let m = GaitKit.model()
        let windows = [GaitKit.prefiltered(endingAt: 1_758_000_010), GaitKit.window(endingAt: 1_758_000_015, p: 0.2),
                       GaitKit.window(endingAt: 1_758_000_020, p: 0.93)]
        return try GaitKit.responseJSON(m, windows, mutate: mutate)
    }

    /// Mutate the first window object of a valid response.
    private func window(_ index: Int = 2, _ mutate: @escaping (inout [String: Any]) -> Void) throws -> Data {
        try good { obj in
            var ws = obj["windows"] as! [[String: Any]]
            mutate(&ws[index])
            obj["windows"] = ws
        }
    }

    private func refuses(_ data: Data, _ expected: E? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GaitQualityResponse.decode(data), file: file, line: line) { error in
            guard let expected else { return }
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }

    // MARK: - Accepted

    func testAValidResponseDecodesWithEveryField() throws {
        let r = try GaitQualityResponse.decode(try good())
        XCTAssertEqual(r.model, GaitKit.model())
        XCTAssertEqual(r.windows.count, 3)
        XCTAssertTrue(r.windows[0].prefiltered)
        XCTAssertFalse(r.windows[0].isGait)
        XCTAssertNil(r.windows[1].speedMps, "metrics only on gait windows")
        XCTAssertEqual(r.windows[2].speedMps, 1.2)
        XCTAssertEqual(r.windows[2].cadenceSpm, 108)
        XCTAssertEqual(r.windows[2].strideM, 1.3)
        XCTAssertEqual(r.windows[2].regularity, 0.8)
        XCTAssertEqual(r.windows[2].steps, 18)
        XCTAssertEqual(r.durationMs, 4)
        XCTAssertEqual(r.droppedNonfinite, 0)
    }

    func testTheSyntheticFixtureDecodesAndItsDigestMatchesPython() throws {
        let r = try GaitQualityResponse.decode(try GaitKit.syntheticFixture())
        XCTAssertEqual(r.model.modelVersion, "eldernet-437a38b")
        XCTAssertEqual(r.model.hopS, 5)
        XCTAssertEqual(r.model.calibration?["gait_prob"], GaitQualityCalibrationEntry(method: "temperature", fit: "val",
                                                                                       parameters: ["T": 1.0]))
        XCTAssertEqual(r.windows.count, 22)
        XCTAssertEqual(r.droppedNonfinite, 1)
        XCTAssertEqual(r.windows.filter(\.prefiltered).count, 4)
        XCTAssertEqual(r.windows.filter(\.isGait).count, 15)
        XCTAssertFalse(r.windows[16].isGait, "0.499999 is below the threshold")
        XCTAssertTrue(r.windows[17].isGait, "0.5 is at it")
        // hashlib.sha256 of the same canonical text (computed when the fixture was written).
        XCTAssertEqual(r.model.weightsDigest, "ca315e4db4a253a6a23f38c3c2dfb8590a253d22e65642e46d242dad89aa593a")
        XCTAssertEqual(r.model.weights12, "ca315e4db4a2")
    }

    func testAnUncalibratedResponseAndAnAbsentPrefilterFlagAreAccepted() throws {
        let r = try GaitQualityResponse.decode(try good { obj in
            obj["calibration"] = NSNull()
            var ws = obj["windows"] as! [[String: Any]]
            ws[1]["prefiltered"] = false
            obj["windows"] = ws
        })
        XCTAssertNil(r.model.calibration)
        XCTAssertFalse(r.windows[1].prefiltered)
    }

    func testIntegralFloatTimesAreAccepted() throws {
        let r = try GaitQualityResponse.decode(try window { w in
            w["s"] = 1_758_000_010.0; w["e"] = 1_758_000_020.0
        })
        XCTAssertEqual(r.windows[2].startTs, 1_758_000_010)
    }

    func testAProbabilityWithinTheRoundingToleranceOfTheThresholdMayFallEitherWay() throws {
        XCTAssertNoThrow(try GaitQualityResponse.decode(try window { w in w["gait_prob"] = 0.4999995 }))
        let below = try window(1) { w in w["gait_prob"] = 0.5000005 }
        XCTAssertNoThrow(try GaitQualityResponse.decode(below))
    }

    // MARK: - Refused

    func testServiceErrorsAreSurfacedWithTheirKind() {
        for kind in ["malformed", "model_missing", "weights_mismatch", "timeout", "internal", "output_too_large"] {
            let data = Data(#"{"id":"x","ok":false,"kind":"\#(kind)","error":"boom"}"#.utf8)
            XCTAssertThrowsError(try GaitQualityResponse.decode(data)) { error in
                XCTAssertEqual(error as? E, .serviceError(kind: kind, message: "boom"))
                XCTAssertEqual((error as? E)?.kind, kind)
            }
        }
    }

    func testTheSchemaAndTheModelIdentityAreChecked() throws {
        refuses(try good { $0["schema"] = "gait-quality-2" }, .unknownSchema("gait-quality-2"))
        refuses(try good { $0.removeValue(forKey: "schema") }, .unknownSchema(nil))
        refuses(try good { $0["model_id"] = "hart" }, .invalidValue("model_id"))
        refuses(try good { $0["model_version"] = "" }, .invalidValue("model_version"))
        refuses(try good { $0["model_version"] = "bad version" }, .invalidValue("model_version"))
        refuses(try good { $0["upstream_commit"] = "437a38bcz" }, .invalidValue("upstream_commit"))
        refuses(try good { $0["preprocessing_version"] = "eldernet-prep-2" }, .invalidValue("preprocessing_version"))
        refuses(try good { $0["window_s"] = 30 }, .invalidValue("window_s"))
        refuses(try good { $0["hop_s"] = 7 }, .invalidValue("hop_s"))
        refuses(try good { $0["gait_threshold"] = 1.0 }, .outOfRange("gait_threshold"))
        refuses(try good { $0.removeValue(forKey: "gait_threshold") }, .missingField("gait_threshold"))
    }

    func testWeightsMustBeKnownHeadsWithSha256Digests() throws {
        refuses(try good { obj in
            var w = obj["weights"] as! [String: Any]; w["gait_mood"] = String(repeating: "a", count: 64); obj["weights"] = w
        }, .unknownField("weights.gait_mood"))
        refuses(try good { obj in
            var w = obj["weights"] as! [String: Any]; w["cadence"] = "abc"; obj["weights"] = w
        }, .invalidValue("weights.cadence"))
        refuses(try good { obj in
            var w = obj["weights"] as! [String: Any]; w["cadence"] = String(repeating: "A", count: 64); obj["weights"] = w
        }, .invalidValue("weights.cadence"))
        refuses(try good { obj in
            var w = obj["weights"] as! [String: Any]; w.removeValue(forKey: "gait_detection"); obj["weights"] = w
        }, .missingField("weights.gait_detection"))
        refuses(try good { $0["weights"] = "x" }, .wrongType("weights"))
    }

    func testCalibrationIsKnownOutputsWithNumericParameters() throws {
        refuses(try good { $0["calibration"] = ["speed": ["method": "temperature", "fit": "val", "T": 1.0]] },
                .unknownField("calibration.speed"))
        refuses(try good { $0["calibration"] = ["gait_prob": ["method": "temperature", "fit": "val", "T": "1"]] },
                .wrongType("calibration.gait_prob.T"))
        refuses(try good { $0["calibration"] = ["gait_prob": ["fit": "val"]] }, .missingField("method"))
        refuses(try good { $0["calibration"] = [1, 2] }, .wrongType("calibration"))
    }

    func testUnknownWindowKeysAreRefused() throws {
        refuses(try window { $0["mood"] = 1 }, .unknownField("windows[2].mood"))
    }

    func testNaNAndInfinityAreRefused() throws {
        let text = String(decoding: try good(), as: UTF8.self).replacingOccurrences(of: "\"gait_prob\":0.93",
                                                                                     with: "\"gait_prob\":NaN")
        XCTAssertTrue(text.contains("NaN"))
        XCTAssertThrowsError(try GaitQualityResponse.decode(Data(text.utf8))) { error in
            XCTAssertEqual(error as? E, .notJSON(nonfinite: true))
            XCTAssertEqual((error as? E)?.kind, "nonfinite")
        }
        let inf = String(decoding: try good(), as: UTF8.self).replacingOccurrences(of: "\"speed_mps\":1.2",
                                                                                    with: "\"speed_mps\":Infinity")
        XCTAssertThrowsError(try GaitQualityResponse.decode(Data(inf.utf8)))
        XCTAssertThrowsError(try GaitQualityResponse.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? E, .notJSON(nonfinite: false))
        }
    }

    func testProbabilitiesAndMetricsMustBeInTheirRanges() throws {
        refuses(try window { $0["gait_prob"] = 1.2 }, .outOfRange("windows[2].gait_prob"))
        refuses(try window { $0["gait_prob"] = -0.1 }, .outOfRange("windows[2].gait_prob"))
        refuses(try window { $0["speed_mps"] = 2.5 }, .outOfRange("windows[2].speed_mps"))
        refuses(try window { $0["cadence_spm"] = 151 }, .outOfRange("windows[2].cadence_spm"))
        refuses(try window { $0["stride_m"] = -0.1 }, .outOfRange("windows[2].stride_m"))
        refuses(try window { $0["regularity"] = 1.01 }, .outOfRange("windows[2].regularity"))
        refuses(try window { $0["steps"] = 51 }, .outOfRange("windows[2].steps"))
        XCTAssertEqual(E.outOfRange("x").kind, "invalid_values")
    }

    func testMetricsAppearOnlyOnGaitWindows() throws {
        refuses(try window(1) { $0["cadence_spm"] = 100 }, .metricsOnNonGaitWindow(index: 1))
        refuses(try window(0) { $0["steps"] = 3 }, .metricsOnNonGaitWindow(index: 0))
        // Absent is not zero: a gait window may carry no metric at all, and null means absent.
        let r = try GaitQualityResponse.decode(try window { w in
            for k in ["speed_mps", "cadence_spm", "stride_m", "regularity", "steps"] { w[k] = NSNull() }
        })
        XCTAssertFalse(r.windows[2].hasMetrics)
    }

    func testIsGaitMustAgreeWithTheThresholdAndThePrefilter() throws {
        refuses(try window { $0["is_gait"] = false; for k in ["speed_mps", "cadence_spm", "stride_m", "regularity", "steps"] { $0.removeValue(forKey: k) } },
                .inconsistentGaitFlag(index: 2))
        refuses(try window(1) { $0["is_gait"] = true }, .inconsistentGaitFlag(index: 1))
        refuses(try window(0) { $0["gait_prob"] = 0.2 }, .inconsistentGaitFlag(index: 0))
        refuses(try window(0) { $0["is_gait"] = true }, .inconsistentGaitFlag(index: 0))
        // A threshold of 0.9 makes a 0.93 window gait and a 0.2 window non-gait still, but 0.6 + is_gait not.
        refuses(try good { obj in
            obj["gait_threshold"] = 0.95
        }, .inconsistentGaitFlag(index: 2))
    }

    func testWindowTimingIsChecked() throws {
        refuses(try window { $0["e"] = ($0["s"] as! Int) + 30 }, .invalidWindowTiming(index: 2))
        refuses(try window { $0["s"] = -5; $0["e"] = 5 }, .invalidWindowTiming(index: 2))
        refuses(try good { obj in
            var ws = obj["windows"] as! [[String: Any]]
            ws.swapAt(1, 2)
            obj["windows"] = ws
        }, .invalidWindowTiming(index: 2))
    }

    func testHugeNegativeNonIntegralAndNonNumericIntegersAreRefusedNotTrapped() throws {
        for bad in [1e19, -1e19, 9.3e18, 1_758_000_010.5] as [Double] {
            refuses(try window { $0["s"] = bad; $0["e"] = bad + 10 })
        }
        refuses(try window { $0["s"] = "1758000010" }, .wrongType("windows[2].s"))
        refuses(try good { $0["duration_ms"] = 1e300 }, .invalidValue("duration_ms"))
        refuses(try good { $0["duration_ms"] = -1 }, .invalidValue("duration_ms"))
        refuses(try good { $0["n_dropped_nonfinite"] = 2.5 }, .invalidValue("n_dropped_nonfinite"))
        refuses(try good { $0["hop_s"] = 5.5 }, .invalidValue("hop_s"))
    }

    func testTypesAreNotCoerced() throws {
        refuses(try window { $0["is_gait"] = 1 }, .wrongType("windows[2].is_gait"))
        refuses(try window { $0["gait_prob"] = "0.93" }, .wrongType("windows[2].gait_prob"))
        refuses(try window(0) { $0["prefiltered"] = "yes" }, .wrongType("windows[0].prefiltered"))
        refuses(try good { $0["ok"] = 1 }, .missingField("ok"))
        refuses(try good { $0["windows"] = [:] as [String: Any] }, .wrongType("windows"))
        refuses(Data("[1,2]".utf8), .notAnObject)
    }

    // MARK: - Codable paths

    func testWindowAndModelCodableRoundTrip() throws {
        let r = try GaitQualityResponse.decode(try GaitKit.syntheticFixture())
        let e = JSONEncoder()
        for w in r.windows {
            XCTAssertEqual(try JSONDecoder().decode(GaitQualityWindow.self, from: e.encode(w)), w)
        }
        XCTAssertEqual(try JSONDecoder().decode(GaitQualityModelInfo.self, from: e.encode(r.model)), r.model)
        // The model's encoding is the response layout: a response rebuilt from it decodes to the same thing.
        let rebuilt = try GaitQualityResponse.decode(try GaitKit.responseJSON(r.model, r.windows))
        XCTAssertEqual(rebuilt.model, r.model)
        XCTAssertEqual(rebuilt.windows, r.windows)
        // A non-gait window's encoding has no metric keys and no prefiltered flag.
        let text = String(decoding: try e.encode(GaitKit.window(endingAt: 100, p: 0.1)), as: UTF8.self)
        XCTAssertFalse(text.contains("speed_mps"))
        XCTAssertFalse(text.contains("prefiltered"))
    }

    func testTheWindowCodablePathRefusesWhatTheWireRefuses() throws {
        func refused(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try JSONDecoder().decode(GaitQualityWindow.self, from: Data(json.utf8)), file: file, line: line)
        }
        refused(#"{"s":0,"e":10,"gait_prob":0.2,"is_gait":false,"speed_mps":1.0}"#)
        refused(#"{"s":0,"e":10,"gait_prob":0.2,"is_gait":false,"mood":1}"#)
        refused(#"{"s":0,"e":30,"gait_prob":0.2,"is_gait":false}"#)
        refused(#"{"s":1e19,"e":1e19,"gait_prob":0.2,"is_gait":false}"#)
        refused(#"{"s":0,"e":10,"gait_prob":1.5,"is_gait":true}"#)
        refused(#"{"s":0,"e":10,"gait_prob":0.3,"is_gait":false,"prefiltered":true}"#)
        refused(#"{"s":0,"e":10,"gait_prob":0.9,"is_gait":true,"cadence_spm":200}"#)
        XCTAssertNoThrow(try JSONDecoder().decode(GaitQualityWindow.self,
                                                  from: Data(#"{"s":0,"e":10,"gait_prob":0.9,"is_gait":true}"#.utf8)))
    }

    func testTheModelCodablePathRunsTheWireValidation() throws {
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GaitKit.model())) as! [String: Any]
        func refused(_ mutate: (inout [String: Any]) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
            var copy = obj
            mutate(&copy)
            XCTAssertThrowsError(try JSONDecoder().decode(GaitQualityModelInfo.self,
                                                          from: JSONSerialization.data(withJSONObject: copy)),
                                 file: file, line: line)
        }
        try refused { $0["model_id"] = "inertia" }
        try refused { $0["hop_s"] = 30 }
        try refused { $0["weights"] = ["gait_speed": String(repeating: "a", count: 64)] }
        try refused { $0["preprocessing_version"] = "inertia-prep-1" }
        obj["calibration"] = ["gait_prob": ["method": "platt", "fit": "val", "a": 1.2, "b": -0.3]]
        let m = try JSONDecoder().decode(GaitQualityModelInfo.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(m.calibration?["gait_prob"]?.parameters, ["a": 1.2, "b": -0.3])
        XCTAssertEqual(try JSONDecoder().decode(GaitQualityModelInfo.self, from: JSONEncoder().encode(m)), m)
    }

    // MARK: - Digest

    func testSha256MatchesTheStandardVectors() {
        XCTAssertEqual(GaitSHA256.hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(GaitSHA256.hex(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(GaitSHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Exactly one block of padding boundary (55 and 56 bytes) and a multi-block message.
        XCTAssertEqual(GaitSHA256.hex(Array(String(repeating: "a", count: 1000).utf8)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testTheWeightsDigestCoversEveryHeadAndOnlyTheWeights() {
        let m = GaitKit.model()
        XCTAssertTrue(m.weightsCanonicalText.hasPrefix("eldernet-weights-1\ncadence="))
        XCTAssertEqual(m.weightsDigest.count, 64)
        var other = m
        other.weights["step_count"] = String(repeating: "0", count: 64)
        XCTAssertNotEqual(other.weightsDigest, m.weightsDigest, "any head's weights change the digest")
        var sameWeights = m
        sameWeights.hopS = 10
        sameWeights.modelVersion = "eldernet-other"
        XCTAssertEqual(sameWeights.weightsDigest, m.weightsDigest, "the digest is the weights only")
    }
}
