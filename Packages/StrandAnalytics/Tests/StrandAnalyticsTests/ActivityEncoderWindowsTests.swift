import XCTest
@testable import StrandAnalytics

/// The compact `hart-windows-1` document the server stores HART's per-window output in, and the decoder's
/// handling of encoder windows that arrive after the seconds they describe were already decoded.
final class ActivityEncoderWindowsTests: XCTestCase {

    private let dayStart = 1_791_158_400   // 2026-10-05T00:00:00Z

    private func window(_ start: Int, _ label: MotionLabel, _ probs: [String: Double],
                        baseline: Bool = false) -> ActivityWindowPrediction {
        ActivityWindowPrediction(startTs: dayStart + start, endTs: dayStart + start + 4, label: label,
                                 probs: probs, baseline: baseline)
    }

    private func roundTrip(_ set: ActivityEncoderWindowSet) throws -> ActivityEncoderWindowSet {
        // Through real JSON text, as it travels from the worker to the database to the phone.
        let data = try JSONSerialization.data(withJSONObject: set.jsonObject(dayStart: dayStart))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(ActivityEncoderWindowSet.decode(object, encoderId: set.encoderId,
                                                             encoderVersion: set.encoderVersion))
    }

    func testRoundTripKeepsWindowsProbabilitiesAndFeatures() throws {
        let walk = window(120, .walking, ["walking": 0.912, "stationary": 0.05, "other_movement": 0.038])
        let still = window(122, .unknown, ["stationary": 0.62, "other_movement": 0.38])
        let features = ImuWindowFeatures(startTs: walk.startTs, endTs: walk.endTs, accelRmsG: 0.13542,
                                         gyroRmsDps: 41.25, jerkRms: 0.01234, cadenceHz: 1.833,
                                         cadenceStrength: 0.4521, orientationChangeDeg: nil)
        let set = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "hart-wisdm-v0",
                                           windows: [still, walk], features: [features])
        let back = try roundTrip(set)

        XCTAssertEqual(back.windows.map(\.startTs), [walk.startTs, still.startTs], "sorted by start")
        XCTAssertEqual(back.windows[0].label, .walking)
        XCTAssertEqual(back.windows[0].probs["walking"] ?? 0, 0.912, accuracy: 1e-9)
        XCTAssertEqual(back.windows[0].probs["other_movement"] ?? 0, 0.038, accuracy: 1e-9)
        XCTAssertNil(back.windows[0].probs["running"], "a zero probability is simply absent")
        XCTAssertEqual(back.windows[1].label, .unknown, "an abstaining window stays abstaining")
        XCTAssertFalse(back.windows[0].baseline)

        XCTAssertEqual(back.features.count, 1, "the window without features gets none")
        let f = try XCTUnwrap(back.features.first)
        XCTAssertEqual(f.endTs, walk.endTs)
        XCTAssertEqual(f.accelRmsG, 0.13542, accuracy: 1e-9)
        XCTAssertEqual(f.gyroRmsDps, 41.25, accuracy: 1e-9)
        XCTAssertEqual(f.cadenceHz ?? 0, 1.833, accuracy: 1e-9)
        XCTAssertEqual(f.cadenceStrength, 0.4521, accuracy: 1e-9)
        XCTAssertNil(f.orientationChangeDeg)
    }

    func testLegacyImuFeat1JerkIsReadAsPerSecond() throws {
        // A document from a server still on imu-feat-1 names jerk `jerk_rms`, in g per 30 Hz sample. It must
        // keep its features (not drop them for the missing `jerk_rms_gps` key) and read jerk in g/s.
        let walk = window(120, .walking, ["walking": 1])
        var doc = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "v", windows: [walk])
            .jsonObject(dayStart: dayStart)
        doc["features"] = ["accel_rms_g", "gyro_rms_dps", "jerk_rms", "cadence_hz", "cadence_strength",
                           "orientation_change_deg"]
        doc["feature_scale"] = [100_000, 1_000, 100_000, 1_000, 10_000, 100]
        doc["f"] = [[13542, 41250, 1234, 1833, 4521, NSNull()]]
        let back = try XCTUnwrap(ActivityEncoderWindowSet.decode(doc, encoderId: "hart", encoderVersion: "v"))
        let f = try XCTUnwrap(back.features.first)
        XCTAssertEqual(f.jerkRms, 0.01234 * 30, accuracy: 1e-9)
        XCTAssertEqual(f.accelRmsG, 0.13542, accuracy: 1e-9)
        XCTAssertEqual(ActivityEncoderWindowSet.featureKeys[2], "jerk_rms_gps")
    }

    func testDocumentIsCompact() throws {
        var windows: [ActivityWindowPrediction] = []
        var features: [ImuWindowFeatures] = []
        for i in 0..<1_000 {
            let w = window(i * 2, .stationary, ["stationary": 0.9, "walking": 0.04, "running": 0.01,
                                                "other_movement": 0.05])
            windows.append(w)
            features.append(ImuWindowFeatures(startTs: w.startTs, endTs: w.endTs, accelRmsG: 0.0071,
                                              gyroRmsDps: 1.234, jerkRms: 0.0021, cadenceHz: nil,
                                              cadenceStrength: 0.12, orientationChangeDeg: 1.5))
        }
        let set = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "v", windows: windows,
                                           features: features)
        let bytes = try JSONSerialization.data(withJSONObject: set.jsonObject(dayStart: dayStart)).count
        XCTAssertLessThan(bytes / windows.count, 90, "a whole day of windows must stay a few MB")
    }

    func testUnparseableWindowsAreDroppedNotFatal() throws {
        var doc = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "v",
                                           windows: [window(0, .walking, ["walking": 1]),
                                                     window(10, .running, ["running": 1])])
            .jsonObject(dayStart: dayStart)
        var p = doc["p"] as! [[Int]]
        p[1] = [5000, 0, 0, 0, 0]   // out of range
        doc["p"] = p
        let back = try XCTUnwrap(ActivityEncoderWindowSet.decode(doc, encoderId: "hart", encoderVersion: "v"))
        XCTAssertEqual(back.windows.map(\.label), [.walking])

        doc["format"] = "something-else"
        XCTAssertNil(ActivityEncoderWindowSet.decode(doc, encoderId: "hart", encoderVersion: "v"))
        var short = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "v",
                                             windows: [window(0, .walking, ["walking": 1])])
            .jsonObject(dayStart: dayStart)
        short["e"] = [Int]()
        XCTAssertNil(ActivityEncoderWindowSet.decode(short, encoderId: "hart", encoderVersion: "v"),
                     "arrays that disagree in length are not a document")
    }

    func testClipAndMergeSelectALocalDayFromTwoUtcDays() {
        let a = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "v",
                                         windows: [window(100, .walking, ["walking": 1]),
                                                   window(86_390, .stationary, ["stationary": 1])])
        let b = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "v",
                                         windows: [window(86_390, .stationary, ["stationary": 1]),
                                                   window(90_000, .running, ["running": 1])])
        let merged = ActivityEncoderWindowSet.merged([a, b])!
        XCTAssertEqual(merged.windows.count, 3, "the window both days carry is kept once")
        let local = merged.clipped(from: dayStart + 7 * 3600, to: dayStart + 31 * 3600)
        XCTAssertEqual(local.windows.map(\.label), [.stationary, .running])
    }

    // MARK: Late windows and the stored day

    func testWindowsArrivingForAlreadyDecodedSecondsRedecodeTheDay() throws {
        var sim = ActivitySim()
        sim.desk(300); sim.walk(120); sim.still(60)
        let plain = sim.trackInput()
        let (stored, _) = ActivityContextDayBuilder.update(cached: nil, input: plain, now: 100)

        var withWindows = plain
        withWindows.encoderWindows = stride(from: plain.dayStart + 300, to: plain.dayStart + 420, by: 2).map {
            ActivityWindowPrediction(startTs: $0, endTs: $0 + 4, label: .walking,
                                     probs: ["walking": 0.95, "stationary": 0.05])
        }
        withWindows.encoderId = "hart"
        withWindows.encoderVersion = "hart-wisdm-v0"
        let (updated, how) = ActivityContextDayBuilder.update(cached: stored, input: withWindows, now: 200)
        XCTAssertEqual(how, .recomputed(reason: "context_changed"))
        let (direct, _) = ActivityContextDayBuilder.update(cached: nil, input: withWindows, now: 200)
        XCTAssertEqual(updated.runs, direct.runs)

        // The same windows again change nothing.
        let (again, howAgain) = ActivityContextDayBuilder.update(cached: updated, input: withWindows, now: 300)
        XCTAssertEqual(howAgain, .reused)
        XCTAssertEqual(again.runs, updated.runs)
    }

    func testADayWithoutWindowsKeepsItsStoredFingerprint() {
        var sim = ActivitySim()
        sim.desk(120)
        let input = sim.trackInput()
        XCTAssertFalse(ActivityContextDayBuilder.fingerprint(input, through: nil).isEmpty)
        var withEmpty = input
        withEmpty.encoderWindows = []
        XCTAssertEqual(ActivityContextDayBuilder.fingerprint(withEmpty, through: nil),
                       ActivityContextDayBuilder.fingerprint(input, through: nil))
    }

    func testLateElderNetWindowsChangeTheFingerprintAndNoneLeaveItAsItWas() {
        var sim = ActivitySim()
        sim.walk(120)
        let input = sim.trackInput()
        let config = GaitKit.config()
        func fp(_ i: ActivityContextTrackInput, _ c: ActivityDecoderConfig) -> String {
            ActivityContextDayBuilder.fingerprint(i, through: nil, config: c)
        }
        let plain = ActivityContextDayBuilder.fingerprint(input, through: nil)
        XCTAssertEqual(fp(input, config), plain)
        var empty = input
        empty.gaitQuality = GaitQualityTrackInput(model: GaitKit.model(), windows: [])
        XCTAssertEqual(fp(empty, config), plain)

        var some = input
        let e = input.dayStart + 60
        some.gaitQuality = GaitQualityTrackInput(model: GaitKit.model(), windows: [GaitKit.window(endingAt: e, p: 0.9)])
        // Windows the config does not use leave the fingerprint alone.
        XCTAssertEqual(fp(some, ActivityDecoderConfig()), plain)
        let withGait = fp(some, config)
        XCTAssertNotEqual(withGait, plain)
        var more = some
        more.gaitQuality?.windows.append(GaitKit.window(endingAt: e + 5, p: 0.8))
        XCTAssertNotEqual(fp(more, config), withGait)
        var reordered = more
        reordered.gaitQuality?.windows.reverse()
        XCTAssertEqual(fp(reordered, config), fp(more, config))
    }

    // MARK: Learned transition-expert rows (additive over `hart-windows-1`)

    func testTransitionWindowsRoundTripThroughTheCompactDocument() throws {
        let walk = window(120, .walking, ["walking": 0.912, "stationary": 0.05, "other_movement": 0.038])
        let still = window(122, .unknown, ["stationary": 0.62, "other_movement": 0.38])
        let trans = ActivityTransitionWindow(startTs: walk.startTs, endTs: walk.endTs,
                                             probabilities: [0.08, 0.74, 0.06, 0.04, 0.08],
                                             modelVersion: "transition-test-1",
                                             preprocessingVersion: "transition-feat-1")
        let set = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "hart-wisdm-v0",
                                           windows: [still, walk], transitions: [trans])
        let object = set.jsonObject(dayStart: dayStart)
        XCTAssertEqual(object["t_schema"] as? String, "transition-1")
        XCTAssertEqual(object["t_v"] as? String, "transition-test-1")
        XCTAssertEqual(object["t_pv"] as? String, "transition-feat-1")
        let t = try XCTUnwrap(object["t"] as? [Any])
        XCTAssertEqual(t.count, 2, "one row per window, sorted like the windows")
        // `walk` (120) sorts before `still` (122); only `walk` carries transition output.
        let row = try XCTUnwrap(t[0] as? [Int])
        XCTAssertEqual(row, [80, 740, 60, 40, 80], "per mille in canonical class order")
        XCTAssertTrue(t[1] is NSNull, "the window without transition output carries a null row")

        let back = try roundTrip(set)
        XCTAssertEqual(back.transitions.count, 1)
        let backTrans = try XCTUnwrap(back.transitions.first)
        XCTAssertEqual(backTrans.startTs, walk.startTs)
        XCTAssertEqual(backTrans.endTs, walk.endTs)
        XCTAssertEqual(backTrans.probabilities.map { ($0 * 1000).rounded() / 1000 }, [0.08, 0.74, 0.06, 0.04, 0.08])
        XCTAssertEqual(backTrans.modelVersion, "transition-test-1")
        XCTAssertEqual(backTrans.preprocessingVersion, "transition-feat-1")
        XCTAssertEqual(back.windows.map(\.label), [.walking, .unknown])
    }

    func testDocumentWithoutTransitionRowsReadsExactlyAsBefore() throws {
        let walk = window(120, .walking, ["walking": 0.912, "stationary": 0.05, "other_movement": 0.038])
        let set = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "hart-wisdm-v0",
                                           windows: [walk])
        let object = set.jsonObject(dayStart: dayStart)
        XCTAssertNil(object["t"], "no transitions, no t column")
        XCTAssertNil(object["t_schema"])
        XCTAssertNil(object["t_v"])

        let back = try roundTrip(set)
        XCTAssertTrue(back.transitions.isEmpty)
        XCTAssertEqual(back.windows, set.windows)
        XCTAssertEqual(back.features, set.features)
    }

    func testUnparseableTransitionRowsAreDroppedNotFatal() throws {
        let a = window(0, .walking, ["walking": 1])
        let b = window(10, .running, ["running": 1])
        let c = window(20, .stationary, ["stationary": 1])
        let set = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "v",
                                           windows: [a, b, c],
                                           transitions: [
                                               ActivityTransitionWindow(startTs: a.startTs, endTs: a.endTs,
                                                                        probabilities: [0.9, 0.03, 0.03, 0.02, 0.02],
                                                                        modelVersion: "t", preprocessingVersion: "p"),
                                               ActivityTransitionWindow(startTs: b.startTs, endTs: b.endTs,
                                                                        probabilities: [0.05, 0.9, 0.02, 0.02, 0.01],
                                                                        modelVersion: "t", preprocessingVersion: "p"),
                                               ActivityTransitionWindow(startTs: c.startTs, endTs: c.endTs,
                                                                        probabilities: [0.95, 0.02, 0.01, 0.01, 0.01],
                                                                        modelVersion: "t", preprocessingVersion: "p"),
                                           ])
        var doc = set.jsonObject(dayStart: dayStart)
        var t = doc["t"] as! [Any]
        t[1] = [5000, 0, 0, 0, 0]   // out of range: that row's transition is dropped, not the doc
        doc["t"] = t
        let back = try XCTUnwrap(ActivityEncoderWindowSet.decode(doc, encoderId: "hart", encoderVersion: "v"))
        XCTAssertEqual(back.windows.count, 3, "the window rows survive")
        XCTAssertEqual(back.transitions.map { [$0.startTs, $0.endTs] },
                       [[a.startTs, a.endTs], [c.startTs, c.endTs]],
                       "the malformed row's transition is dropped, the others are kept")

        // A `t` that does not line up with the windows is ignored entirely, never fatal.
        doc["t"] = [0, 1, 2]
        let ragged = try XCTUnwrap(ActivityEncoderWindowSet.decode(doc, encoderId: "hart", encoderVersion: "v"))
        XCTAssertTrue(ragged.transitions.isEmpty)
        XCTAssertEqual(ragged.windows.count, 3)

        // A `t_schema` the reader does not know is ignored, never fatal.
        doc["t_schema"] = "transition-99"
        doc["t"] = t
        let unknownSchema = try XCTUnwrap(ActivityEncoderWindowSet.decode(doc, encoderId: "hart", encoderVersion: "v"))
        XCTAssertTrue(unknownSchema.transitions.isEmpty)
        XCTAssertEqual(unknownSchema.windows.count, 3)
    }

    func testTransitionWindowsAttachToObservationsByEndSecondLikeEncoderWindows() throws {
        var sim = ActivitySim()
        sim.desk(60)
        var input = sim.trackInput()
        let w = ActivityTransitionWindow(startTs: input.dayStart + 20, endTs: input.dayStart + 24,
                                         probabilities: [0.06, 0.85, 0.03, 0.03, 0.03],
                                         modelVersion: "transition-test-1",
                                         preprocessingVersion: "transition-feat-1")
        input.transitionWindows = [w]

        let observations = ActivityContextTrackBuilder.observations(for: input)
        let atEnd = try XCTUnwrap(observations.first { $0.ts == w.endTs }?.transition)
        XCTAssertEqual(atEnd.sitToStand, 0.85, accuracy: 1e-9)
        XCTAssertEqual(atEnd.none, 0.06, accuracy: 1e-9)
        XCTAssertEqual(atEnd.modelVersion, "transition-test-1")
        XCTAssertEqual(atEnd.preprocessingVersion, "transition-feat-1")
        XCTAssertFalse(atEnd.abstained)
        XCTAssertNil(observations.first { $0.ts == w.endTs - 1 }?.transition,
                     "the window attaches at its end second, not before")
    }
}
