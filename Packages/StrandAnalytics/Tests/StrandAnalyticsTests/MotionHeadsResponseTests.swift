import XCTest
@testable import StrandAnalytics

/// The `motion-heads-1` wire format (INERTIA1.md §6): what the strict decoder accepts, and that everything
/// else is refused as a whole with a typed error.
final class MotionHeadsResponseTests: XCTestCase {

    private let classesP = MotionHead.posture.classOrder
    private let classesL = MotionHead.locomotion.classOrder
    private let classesA = MotionHead.armBehavior.classOrder

    private func validWindows(_ bundle: MotionHeadsBundleInfo, count: Int = 3) -> [MotionHeadsWindow] {
        (0..<count).map { i in
            MotionHeadsKit.window(endingAt: 1_758_000_010 + i * bundle.hopS, windowS: bundle.windowS,
                                  posture: MotionHeadsKit.peaked(classesP, "seated_likely", 0.7),
                                  locomotion: MotionHeadsKit.peaked(classesL, "stationary", 0.8),
                                  arm: MotionHeadsKit.peaked(classesA, "desk_like", 0.5),
                                  transition: ["sit_to_stand_like": 0.1, "stand_to_sit_like": 0.02, "lying_down_like": 0.01,
                                               "getting_up_like": 0.01, "walk_start": 0.3, "walk_stop": 0.05,
                                               "run_start": 0.0, "run_stop": 0.0])
        }
    }

    private func decode(_ mutate: (inout [String: Any]) -> Void) throws -> MotionHeadsResponse {
        let bundle = MotionHeadsKit.bundle()
        return try MotionHeadsResponse.decode(MotionHeadsKit.responseJSON(bundle, validWindows(bundle), mutate: mutate))
    }

    private func assertRefused(_ expected: MotionHeadsResponseError? = nil, kind: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ mutate: (inout [String: Any]) -> Void) {
        do {
            _ = try decode(mutate)
            XCTFail("expected the response to be refused", file: file, line: line)
        } catch let e as MotionHeadsResponseError {
            if let expected { XCTAssertEqual(e, expected, file: file, line: line) }
            if let kind { XCTAssertEqual(e.kind, kind, "\(e)", file: file, line: line) }
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
        }
    }

    private func mutateWindow(_ i: Int, _ body: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        return { obj in
            var windows = obj["windows"] as! [[String: Any]]
            body(&windows[i])
            obj["windows"] = windows
        }
    }

    // MARK: - Accepted

    func testAValidResponseDecodesWithEveryField() throws {
        let bundle = MotionHeadsKit.bundle()
        let windows = validWindows(bundle)
        let r = try MotionHeadsResponse.decode(MotionHeadsKit.responseJSON(bundle, windows))
        XCTAssertEqual(r.bundle, bundle)
        XCTAssertEqual(r.windows, windows)
        XCTAssertEqual(r.droppedNonfinite, 0)
        XCTAssertEqual(r.durationMs, 3)
        XCTAssertEqual(r.bundle.bundle12, String(MotionHeadsKit.bundleSha.prefix(12)))
    }

    func testTheTransitionHeadIsMultiLabelAndNeedNotSumToOne() throws {
        let r = try decode(mutateWindow(0) { w in
            w["transition"] = ["sit_to_stand_like": 0.9, "stand_to_sit_like": 0.9, "lying_down_like": 0.9,
                               "getting_up_like": 0.9, "walk_start": 0.9, "walk_stop": 0.9, "run_start": 0.9,
                               "run_stop": 0.9]
        })
        XCTAssertEqual(r.windows[0].transition?["walk_start"], 0.9)
    }

    func testAHeadMayBeAbsentFromAWindow() throws {
        let r = try decode(mutateWindow(1) { w in w.removeValue(forKey: "posture"); w["arm_behavior"] = NSNull() })
        XCTAssertNil(r.windows[1].posture)
        XCTAssertNil(r.windows[1].armBehavior)
        XCTAssertNotNil(r.windows[1].locomotion)
    }

    func testAHeadWithNoSupportedClassIsOmittedNotMalformed() throws {
        var heads = MotionHeadsKit.bundle().heads
        heads[.posture] = MotionHeadSpec(classOrder: MotionHead.posture.classOrder, prior: [:], status: [:])
        let bundle = MotionHeadsKit.bundle(heads: heads)
        var windows = validWindows(bundle)
        for i in windows.indices { windows[i].posture = nil }
        let r = try MotionHeadsResponse.decode(MotionHeadsKit.responseJSON(bundle, windows))
        XCTAssertTrue(r.bundle.heads[.posture]!.supportedClasses.isEmpty)
        // …but a window may not carry a head the bundle does not support.
        windows[0].posture = MotionHeadsKit.peaked(classesP, "recumbent", 0.7)
        XCTAssertThrowsError(try MotionHeadsResponse.decode(MotionHeadsKit.responseJSON(bundle, windows)))
    }

    func testCoversAndMergeIntoRoundTrip() throws {
        let supported = ["stationary", "walking", "running", "stairs", "cycling", "vehicle_motion", "other"]
        let spec = MotionHeadsKit.spec(.locomotion, supported: supported, status: ["stairs": .abstain],
                                       mergeInto: ["stairs": "walking"], covers: ["walking": ["walking", "brisk_walking"]])
        var heads = MotionHeadsKit.bundle().heads
        heads[.locomotion] = spec
        let bundle = MotionHeadsKit.bundle(heads: heads)
        var windows = validWindows(bundle)
        for i in windows.indices { windows[i].locomotion = MotionHeadsKit.peaked(supported, "walking", 0.6) }
        let r = try MotionHeadsResponse.decode(MotionHeadsKit.responseJSON(bundle, windows))
        XCTAssertEqual(r.bundle.heads[.locomotion]?.covers["walking"], ["walking", "brisk_walking"])
        XCTAssertEqual(r.bundle.heads[.locomotion]?.mergeInto["stairs"], "walking")
    }

    func testIntegralFloatTimestampsAreAccepted() throws {
        let r = try decode(mutateWindow(0) { w in
            w["s"] = 1_758_000_000.0
            w["e"] = 1_758_000_010.0
        })
        XCTAssertEqual(r.windows[0].startTs, 1_758_000_000)
    }

    // MARK: - Refused

    func testAnUnknownSchemaIsRefused() {
        assertRefused(.unknownSchema("motion-heads-2"), kind: "schema") { $0["schema"] = "motion-heads-2" }
        assertRefused(.unknownSchema(nil)) { $0.removeValue(forKey: "schema") }
    }

    func testAServiceErrorIsSurfacedWithItsKind() {
        let line = Data(#"{"id":"x","ok":false,"kind":"model_missing","error":"no checkpoint"}"#.utf8)
        XCTAssertThrowsError(try MotionHeadsResponse.decode(line)) { error in
            XCTAssertEqual(error as? MotionHeadsResponseError, .serviceError(kind: "model_missing", message: "no checkpoint"))
            XCTAssertEqual((error as? MotionHeadsResponseError)?.kind, "model_missing")
        }
    }

    func testUnknownClassAndHeadKeysAreRefused() {
        assertRefused(.unknownClass(head: "posture", cls: "kneeling")) { obj in
            var windows = obj["windows"] as! [[String: Any]]
            var p = windows[0]["posture"] as! [String: Any]
            p["kneeling"] = 0.0
            windows[0]["posture"] = p
            obj["windows"] = windows
        }
        assertRefused(.unknownHead("gait")) { obj in
            var b = obj["bundle"] as! [String: Any]
            var heads = b["heads"] as! [String: Any]
            heads["gait"] = heads["posture"]
            b["heads"] = heads
            obj["bundle"] = b
        }
        assertRefused(.unknownField("windows[2].posture_v2")) { obj in
            var windows = obj["windows"] as! [[String: Any]]
            windows[2]["posture_v2"] = [:]
            obj["windows"] = windows
        }
    }

    func testAClassOrderThatDiffersFromTheContractIsRefused() {
        assertRefused(.classOrderMismatch(head: "locomotion")) { obj in
            var b = obj["bundle"] as! [String: Any]
            var heads = b["heads"] as! [String: Any]
            var loco = heads["locomotion"] as! [String: Any]
            loco["class_order"] = Array(MotionHead.locomotion.classOrder.reversed())
            heads["locomotion"] = loco
            b["heads"] = heads
            obj["bundle"] = b
        }
    }

    func testNaNAndInfinityAreRefused() throws {
        let bundle = MotionHeadsKit.bundle()
        let text = String(decoding: try MotionHeadsKit.responseJSON(bundle, validWindows(bundle)), as: UTF8.self)
        // Python's json.dumps writes NaN / Infinity tokens; they are not JSON.
        let nan = text.replacingOccurrences(of: "\"movement_intensity\":0.2", with: "\"movement_intensity\":NaN")
        XCTAssertNotEqual(nan, text)
        XCTAssertThrowsError(try MotionHeadsResponse.decode(Data(nan.utf8))) { error in
            XCTAssertEqual(error as? MotionHeadsResponseError, .notJSON(nonfinite: true))
            XCTAssertEqual((error as? MotionHeadsResponseError)?.kind, "nonfinite")
        }
        let inf = text.replacingOccurrences(of: "\"ood_score\":0.4", with: "\"ood_score\":-Infinity")
        XCTAssertThrowsError(try MotionHeadsResponse.decode(Data(inf.utf8)))
        XCTAssertThrowsError(try MotionHeadsResponse.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? MotionHeadsResponseError, .notJSON(nonfinite: false))
        }
    }

    func testProbabilitiesMustBeInRangeAndSumToOne() {
        assertRefused(kind: "invalid_probabilities", mutateWindow(0) { w in
            var p = w["posture"] as! [String: Any]
            p["recumbent"] = -0.01
            w["posture"] = p
        })
        assertRefused(kind: "invalid_probabilities", mutateWindow(1) { w in
            var p = w["locomotion"] as! [String: Any]
            p["stationary"] = 1.5
            w["locomotion"] = p
        })
        assertRefused(kind: "invalid_probabilities", mutateWindow(2) { w in
            var p = w["arm_behavior"] as! [String: Any]
            p["quiet"] = (p["quiet"] as! Double) + 0.01
            w["arm_behavior"] = p
        })
        // A supported class missing from the window is not a zero-probability claim: refused.
        assertRefused(kind: "invalid_probabilities", mutateWindow(0) { w in
            var p = w["posture"] as! [String: Any]
            p.removeValue(forKey: "postural_transition")
            w["posture"] = p
        })
        assertRefused(kind: "invalid_probabilities", mutateWindow(0) { w in w["movement_intensity"] = 1.2 })
    }

    func testSixDecimalRoundingPassesTheSumCheckButARealDeficitDoesNot() throws {
        // The service rounds every probability to 6 decimals: a distribution may miss 1 by a few 1e-7.
        let r = try decode(mutateWindow(0) { w in
            w["arm_behavior"] = ["quiet": 0.001926, "desk_like": 0.80278, "fidgeting": 0.182617, "repetitive_hand_motion": 0.0,
                                 "active_gesturing": 0.006926, "exercise_motion": 0.005752, "other": 0.000000]
        })
        XCTAssertEqual(r.windows[0].armBehavior?["desk_like"], 0.80278)
        assertRefused(kind: "invalid_probabilities", mutateWindow(0) { w in
            w["arm_behavior"] = ["quiet": 0.1, "desk_like": 0.8, "fidgeting": 0.0999, "repetitive_hand_motion": 0.0,
                                 "active_gesturing": 0.0, "exercise_motion": 0.0, "other": 0.0]
        })
    }

    func testTypesAreNotCoerced() {
        assertRefused(.wrongType("windows[0].is_ood")) { obj in
            var windows = obj["windows"] as! [[String: Any]]
            windows[0]["is_ood"] = 0
            obj["windows"] = windows
        }
        assertRefused(.wrongType("windows[1].posture.recumbent")) { obj in
            var windows = obj["windows"] as! [[String: Any]]
            var p = windows[1]["posture"] as! [String: Any]
            p["recumbent"] = "0.25"
            windows[1]["posture"] = p
            obj["windows"] = windows
        }
    }

    func testWindowTimingMustMatchTheBundle() {
        assertRefused(.invalidWindowTiming(index: 0), mutateWindow(0) { w in w["e"] = (w["s"] as! Int) + 7 })
        assertRefused(.invalidWindowTiming(index: 1)) { obj in
            var windows = obj["windows"] as! [[String: Any]]
            windows[1] = windows[0]
            obj["windows"] = windows
        }
    }

    func testProvenanceFieldsAreChecked() {
        assertRefused(.invalidValue("encoder_kind")) { $0["encoder_kind"] = "inertia2" }
        // An inertia1 claim needs a real id and a checkpoint digest.
        assertRefused(.invalidValue("encoder_kind")) { $0["encoder_id"] = "standin:handcrafted-stats-v1" }
        assertRefused(.invalidValue("encoder_kind")) { $0["checkpoint_sha256"] = NSNull() }
        assertRefused(.invalidValue("bundle_sha256")) { $0["bundle_sha256"] = "abc" }
        assertRefused(.invalidValue("preprocessing_version")) { $0["preprocessing_version"] = "inertia-prep-2" }
        assertRefused(.invalidValue("evidence_tier_max")) { $0["evidence_tier_max"] = "gold" }
        assertRefused(.invalidValue("hop_s")) { $0["hop_s"] = 7 }
        assertRefused(.invalidValue("window_s")) { $0["window_s"] = 20 }
    }

    func testMergeRulesMustBeConsistent() {
        func setLoco(_ obj: inout [String: Any], _ body: (inout [String: Any]) -> Void) {
            var b = obj["bundle"] as! [String: Any]
            var heads = b["heads"] as! [String: Any]
            var loco = heads["locomotion"] as! [String: Any]
            body(&loco)
            heads["locomotion"] = loco
            b["heads"] = heads
            obj["bundle"] = b
        }
        // Only an abstained class may be merged.
        assertRefused(.invalidMerge(head: "locomotion", cls: "stairs")) { obj in
            setLoco(&obj) { $0["merge_into"] = ["stairs": "walking"] }
        }
        // No cycles, and the chain must end at a usable class.
        assertRefused(.invalidMerge(head: "locomotion", cls: "stairs")) { obj in
            setLoco(&obj) { loco in
                var st = loco["status"] as! [String: Any]
                st["stairs"] = "abstain"; st["walking"] = "abstain"
                loco["status"] = st
                loco["merge_into"] = ["stairs": "walking", "walking": "stairs"]
            }
        }
        // A covering class may not cover another supported class.
        assertRefused(.invalidCovers(head: "locomotion", cls: "walking")) { obj in
            setLoco(&obj) { $0["covers"] = ["walking": ["walking", "brisk_walking"]] }
        }
    }

    // MARK: - Codable forms

    func testWindowAndBundleCodableRoundTrip() throws {
        let bundle = MotionHeadsKit.bundle(kind: .standin, tier: .shadow)
        let data = try JSONEncoder().encode(bundle)
        XCTAssertEqual(try JSONDecoder().decode(MotionHeadsBundleInfo.self, from: data), bundle)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["checkpoint_sha256"] is NSNull, "the wire layout carries an explicit null")
        XCTAssertNotNil((json["bundle"] as? [String: Any])?["heads"])

        let w = validWindows(MotionHeadsKit.bundle())[1]
        let wd = try JSONEncoder().encode(w)
        XCTAssertEqual(try JSONDecoder().decode(MotionHeadsWindow.self, from: wd), w)
        let wj = try XCTUnwrap(JSONSerialization.jsonObject(with: wd) as? [String: Any])
        XCTAssertEqual(Set(wj.keys), ["s", "e", "posture", "locomotion", "arm_behavior", "transition",
                                      "movement_intensity", "ood_score", "is_ood"])
        // Absent heads are omitted, not written as null.
        let bare = MotionHeadsWindow(startTs: 1, endTs: 11, isOOD: true)
        let bj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any])
        XCTAssertEqual(Set(bj.keys), ["s", "e", "is_ood"])
    }

    func testOldDocumentsWithoutTheNewFieldsStillDecode() throws {
        // A snapshot and a state written before motion heads existed (no `motion_heads`, no feature-window keys).
        var sim = ActivitySim()
        sim.desk(60)
        var d = ActivityContextDecoder()
        let states = d.run(sim.observations)
        let snapData = try JSONEncoder().encode(d.snapshot())
        let snapText = String(decoding: snapData, as: UTF8.self)
        XCTAssertFalse(snapText.contains("motion_heads"))
        XCTAssertFalse(snapText.contains("motionHeads"))
        let restored = try JSONDecoder().decode(ActivityDecoderSnapshot.self, from: snapData)
        XCTAssertEqual(restored, d.snapshot())
        XCTAssertNil(restored.versions.motionHeads)
        let stateData = try JSONEncoder().encode(try XCTUnwrap(states.last))
        XCTAssertFalse(String(decoding: stateData, as: UTF8.self).contains("motion_heads"))
        XCTAssertNil(try JSONDecoder().decode(ActivityContextState.self, from: stateData).versions.motionHeads)
        // The decoder config without the new key decodes too.
        let cfg = try JSONEncoder().encode(ActivityDecoderConfig())
        XCTAssertFalse(String(decoding: cfg, as: UTF8.self).contains("motionHeads"))
        XCTAssertNil(try JSONDecoder().decode(ActivityDecoderConfig.self, from: cfg).motionHeads)
    }

    // MARK: - Integer conversions never trap (G-1)

    /// Every number that becomes an Int (duration_ms, n_dropped_nonfinite, window_s, hop_s, s, e) is refused,
    /// never converted, when it is huge (a bare `Int(1e19)` traps), negative, non-integral or not a number.
    func testHugeNegativeNonIntegralAndNonNumericIntegersAreRefusedNotTrapped() {
        // duration_ms: informational, but still exactly the contract.
        for bad in [1e19, 9.3e18, 1e300, 9e15] as [Double] {
            assertRefused(.invalidValue("duration_ms")) { $0["duration_ms"] = bad }
        }
        assertRefused(.invalidValue("duration_ms")) { $0["duration_ms"] = -1 }
        assertRefused(.invalidValue("duration_ms")) { $0["duration_ms"] = 12.5 }
        assertRefused(.wrongType("duration_ms")) { $0["duration_ms"] = "NaN" }
        assertRefused(.wrongType("duration_ms")) { $0["duration_ms"] = "12" }
        assertRefused(.wrongType("duration_ms")) { $0["duration_ms"] = true }
        // Other top-level integers.
        assertRefused(.invalidValue("n_dropped_nonfinite")) { $0["n_dropped_nonfinite"] = 1e19 }
        assertRefused(.invalidValue("window_s")) { $0["window_s"] = 1e19 }
        assertRefused(.invalidValue("hop_s")) { $0["hop_s"] = -1e300 }
        // Window times: huge, negative, non-integral, strings.
        assertRefused(.invalidValue("windows[0].s"), mutateWindow(0) { w in w["s"] = 1e19; w["e"] = 1e19 + 10 })
        assertRefused(.invalidValue("windows[0].s"), mutateWindow(0) { w in w["s"] = 1e300 })
        assertRefused(.invalidValue("windows[0].e"), mutateWindow(0) { w in w["e"] = 9.3e18 })
        assertRefused(.invalidValue("windows[0].s"), mutateWindow(0) { w in w["s"] = -1e19 })
        assertRefused(.invalidWindowTiming(index: 0), mutateWindow(0) { w in w["s"] = -10; w["e"] = 0 })
        assertRefused(.invalidValue("windows[0].s"), mutateWindow(0) { w in w["s"] = 1_758_000_000.5 })
        assertRefused(.wrongType("windows[0].s"), mutateWindow(0) { w in w["s"] = "1758000000" })
        assertRefused(.wrongType("windows[0].e"), mutateWindow(0) { w in w["e"] = "NaN" })
        assertRefused(.wrongType("windows[0].s"), mutateWindow(0) { w in w["s"] = "Infinity" })
        // A literal NaN / Infinity token is not JSON at all.
        let bundle = MotionHeadsKit.bundle()
        for token in ["NaN", "Infinity", "-Infinity"] {
            var text = String(decoding: try! MotionHeadsKit.responseJSON(bundle, validWindows(bundle)), as: UTF8.self)
            text = text.replacingOccurrences(of: "\"duration_ms\":3", with: "\"duration_ms\":\(token)")
            XCTAssertThrowsError(try MotionHeadsResponse.decode(Data(text.utf8)), token) { error in
                XCTAssertEqual(error as? MotionHeadsResponseError, .notJSON(nonfinite: true), token)
            }
        }
        // The largest accepted value is exact and in range.
        XCTAssertEqual(try decode { $0["duration_ms"] = 8_999_999_999_999_998.0 }.durationMs, 8_999_999_999_999_998)
        XCTAssertNil(try decode { $0["duration_ms"] = NSNull() }.durationMs)
    }

    /// The Codable path of a window refuses the same huge / broken times instead of trapping.
    func testTheWindowCodablePathRefusesWhatTheWireRefuses() throws {
        func decodeWindow(_ text: String) throws -> MotionHeadsWindow {
            try JSONDecoder().decode(MotionHeadsWindow.self, from: Data(text.utf8))
        }
        XCTAssertNoThrow(try decodeWindow(#"{"s":100,"e":110,"is_ood":false}"#))
        for bad in [#"{"s":1e19,"e":1.0000000000000000001e19,"is_ood":false}"#,
                    #"{"s":100.5,"e":110.5,"is_ood":false}"#,
                    #"{"s":-10,"e":0,"is_ood":false}"#,
                    #"{"s":100,"e":107,"is_ood":false}"#,                     // not an allowed window length
                    #"{"s":"100","e":110,"is_ood":false}"#,
                    #"{"s":100,"e":110}"#,                                    // is_ood is required
                    #"{"s":100,"e":110,"is_ood":1}"#,                         // a number is not a boolean
                    #"{"s":100,"e":110,"is_ood":false,"extra":1}"#,
                    #"{"s":100,"e":110,"is_ood":false,"posture":{"kneeling":0.5}}"#,
                    #"{"s":100,"e":110,"is_ood":false,"posture":{"recumbent":1.5}}"#,
                    #"{"s":100,"e":110,"is_ood":false,"movement_intensity":2}"#] {
            XCTAssertThrowsError(try decodeWindow(bad), bad) { XCTAssertTrue($0 is DecodingError, "\($0)") }
        }
        // The bundle-dependent checks are `validate(against:)`.
        let bundle = MotionHeadsKit.bundle()
        let ok = validWindows(bundle)[0]
        XCTAssertNoThrow(try ok.validate(against: bundle))
        var short = ok
        short.locomotion?.removeValue(forKey: "stairs")
        XCTAssertThrowsError(try short.validate(against: bundle)) {
            XCTAssertEqual($0 as? MotionHeadsResponseError, .supportMismatch(head: "locomotion", window: 0))
        }
        var long = ok
        long.endTs = long.startTs + 30
        XCTAssertThrowsError(try long.validate(against: bundle)) {
            XCTAssertEqual($0 as? MotionHeadsResponseError, .invalidWindowTiming(index: 0))
        }
    }

    // MARK: - The Codable bundle path is the wire decoder (S-5)

    func testTheBundleCodablePathRunsTheWireValidation() throws {
        let good = try JSONEncoder().encode(MotionHeadsKit.bundle())
        XCTAssertNoThrow(try JSONDecoder().decode(MotionHeadsBundleInfo.self, from: good))
        func mutated(_ body: (inout [String: Any]) -> Void) throws -> Data {
            var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
            body(&obj)
            return try JSONSerialization.data(withJSONObject: obj)
        }
        let refused: [(String, (inout [String: Any]) -> Void)] = [
            ("an inertia1 kind with a standin: id", { $0["encoder_id"] = "standin:handcrafted-stats-v1" }),
            ("a standin kind with an inertia-1/ id", { $0["encoder_kind"] = "standin"; $0["checkpoint_sha256"] = NSNull() }),
            ("an inertia1 kind without a checkpoint", { $0["checkpoint_sha256"] = NSNull() }),
            ("a short digest", { $0["bundle_sha256"] = "abc" }),
            ("another preprocessing", { $0["preprocessing_version"] = "inertia-prep-2" }),
            ("a hop the contract does not allow", { $0["hop_s"] = 7 }),
            ("a huge window", { $0["window_s"] = 1e19 }),
            ("an unknown head", { obj in
                var b = obj["bundle"] as! [String: Any]
                var heads = b["heads"] as! [String: Any]
                heads["gait"] = heads["posture"]
                b["heads"] = heads
                obj["bundle"] = b
            }),
            ("a prior that does not sum to 1", { obj in
                var b = obj["bundle"] as! [String: Any]
                var heads = b["heads"] as! [String: Any]
                var p = heads["posture"] as! [String: Any]
                var prior = p["prior"] as! [String: Any]
                prior["recumbent"] = 0.9
                p["prior"] = prior
                heads["posture"] = p
                b["heads"] = heads
                obj["bundle"] = b
            }),
            ("a measured rho outside [0, 1]", { obj in
                var b = obj["bundle"] as! [String: Any]
                b["fusion"] = ["rho_hart": 1.5]
                obj["bundle"] = b
            }),
        ]
        for (label, body) in refused {
            XCTAssertThrowsError(try JSONDecoder().decode(MotionHeadsBundleInfo.self, from: try mutated(body)), label) {
                XCTAssertTrue($0 is DecodingError, "\(label): \($0)")
            }
        }
        // The same refusal reaches every Codable consumer: a decoder config, a replay header.
        var config = ActivityDecoderConfig()
        config.motionHeads = MotionHeadsEvidenceConfig.candidate(bundle: MotionHeadsKit.bundle())
        var cfgObj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        var mh = try XCTUnwrap(cfgObj["motionHeads"] as? [String: Any])
        var b = try XCTUnwrap(mh["bundle"] as? [String: Any])
        b["encoder_id"] = "standin:handcrafted-stats-v1"
        mh["bundle"] = b
        cfgObj["motionHeads"] = mh
        XCTAssertThrowsError(try JSONDecoder().decode(ActivityDecoderConfig.self,
                                                      from: JSONSerialization.data(withJSONObject: cfgObj)))
        let header = #"{"format":"nara-activity-replay-1","motion_heads":{"bundle":"#
            + String(decoding: try mutated { $0["encoder_id"] = "standin:handcrafted-stats-v1" }, as: UTF8.self) + "}}"
        XCTAssertThrowsError(try ActivityReplay.parse(Data(header.utf8)))
    }

    func testTheBundleMayCarryAMeasuredRho() throws {
        var bundle = MotionHeadsKit.bundle()
        bundle.fusion = MotionHeadsFusionInfo(rhoHart: 0.61)
        let r = try MotionHeadsResponse.decode(MotionHeadsKit.responseJSON(bundle, validWindows(bundle)))
        XCTAssertEqual(r.bundle.fusion?.rhoHart, 0.61)
        XCTAssertEqual(try JSONDecoder().decode(MotionHeadsBundleInfo.self, from: JSONEncoder().encode(bundle)), bundle)
        // Without it the encoded bundle is unchanged (no `fusion` key).
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(MotionHeadsKit.bundle()))
                                  as? [String: Any])
        XCTAssertNil((plain["bundle"] as? [String: Any])?["fusion"])
        assertRefused(.wrongType("bundle.fusion")) { obj in
            var b = obj["bundle"] as! [String: Any]
            b["fusion"] = 0.61
            obj["bundle"] = b
        }
        assertRefused(.invalidValue("bundle.fusion.rho_hart")) { obj in
            var b = obj["bundle"] as! [String: Any]
            b["fusion"] = ["rho_hart": -0.1]
            obj["bundle"] = b
        }
    }

    /// `decoder_evidence` (per head) is read when present, must be a boolean, and leaves the encoded bundle
    /// unchanged when absent.
    func testDecoderEvidenceIsParsedWhenPresent() throws {
        func withFlag(_ value: Any) -> (inout [String: Any]) -> Void {
            { obj in
                var b = obj["bundle"] as! [String: Any]
                var heads = b["heads"] as! [String: Any]
                var loco = heads["locomotion"] as! [String: Any]
                loco["decoder_evidence"] = value
                heads["locomotion"] = loco
                b["heads"] = heads
                obj["bundle"] = b
            }
        }
        let bundle = MotionHeadsKit.bundle()
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: MotionHeadsKit.responseJSON(bundle, validWindows(bundle)))
                                as? [String: Any])
        withFlag(false)(&obj)
        let r = try MotionHeadsResponse.decode(JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(r.bundle.heads[.locomotion]?.decoderEvidence, false)
        XCTAssertNil(r.bundle.heads[.posture]?.decoderEvidence)
        assertRefused(.wrongType("locomotion.decoder_evidence"), withFlag("no"))
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(MotionHeadsKit.bundle()))
                                  as? [String: Any])
        let heads = (plain["bundle"] as? [String: Any])?["heads"] as? [String: Any]
        XCTAssertNil((heads?["locomotion"] as? [String: Any])?["decoder_evidence"])
    }
}
