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
}
