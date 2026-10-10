import XCTest
@testable import StrandAnalytics

/// The `mh-col-1` reader (`MotionHeadsColumns`) against objects laid out exactly as the worker's
/// `ActivityMotionHeadsDays.compact` writes them (Tools/CloudWorker/Sources/frwhoop-worker/ActivityMotionHeads.swift).
final class MotionHeadsColumnsTests: XCTestCase {

    /// A bundle whose locomotion head supports only some classes, so the class indices are in supported order.
    private func bundle() -> MotionHeadsBundleInfo {
        let loco = ["stationary", "walking", "running", "cycling"]
        return MotionHeadsKit.bundle(kind: .actinet, tier: .production, heads: [
            .posture: MotionHeadsKit.spec(.posture),
            .locomotion: MotionHeadsKit.spec(.locomotion, supported: loco,
                                             prior: ["stationary": 0.6, "walking": 0.25, "running": 0.05, "cycling": 0.1]),
            .armBehavior: MotionHeadsKit.spec(.armBehavior),
            .transition: MotionHeadsKit.spec(.transition),
        ])
    }

    private func windows() -> [MotionHeadsWindow] {
        let loco = ["stationary", "walking", "running", "cycling"]
        return [
            MotionHeadsKit.window(endingAt: 1_000, posture: MotionHeadsKit.peaked(MotionHead.posture.classOrder,
                                                                                  "seated_likely", 0.7),
                                  locomotion: MotionHeadsKit.peaked(loco, "stationary", 0.9),
                                  arm: MotionHeadsKit.peaked(MotionHead.armBehavior.classOrder, "desk_like", 0.55),
                                  transition: Dictionary(uniqueKeysWithValues: MotionHead.transition.classOrder.map {
                                      ($0, $0 == "walk_start" ? 0.62 : 0.01) }),
                                  intensity: 0.12),
            MotionHeadsKit.window(endingAt: 1_005, locomotion: MotionHeadsKit.peaked(loco, "walking", 0.8),
                                  intensity: nil),
            MotionHeadsKit.window(endingAt: 1_015, posture: MotionHeadsKit.peaked(MotionHead.posture.classOrder,
                                                                                  "upright_stationary", 0.5),
                                  locomotion: MotionHeadsKit.peaked(loco, "running", 1.0), intensity: 0.9, ood: true),
        ]
    }

    /// The worker's `compact`, transcribed: per head the supported-class index of the top class (ties to the earlier
    /// class) and its probability in percent, -1 / 0 when the window lacks the head.
    private func compact(_ windows: [MotionHeadsWindow], bundle: MotionHeadsBundleInfo) -> [String: Any] {
        func percent(_ x: Double?) -> Int {
            guard let x, x.isFinite else { return -1 }
            return Int((min(1, max(0, x)) * 100).rounded())
        }
        let carried = MotionHead.allCases.filter { !(bundle.heads[$0]?.supportedClasses ?? []).isEmpty }
        var heads: [String: [String: [Int]]] = [:]
        for head in carried { heads[head.rawValue] = ["i": [], "p": []] }
        var ds: [Int] = [], x: [Int] = [], mi: [Int] = []
        var previous: Int?
        for w in windows {
            ds.append(previous.map { w.startTs - $0 } ?? 0)
            previous = w.startTs
            x.append(w.isOOD ? 1 : 0)
            mi.append(percent(w.movementIntensity))
            for head in carried {
                var best: (Int, Double)?
                if let probs = w.probabilities(head) {
                    for (k, cls) in (bundle.heads[head]?.supportedClasses ?? []).enumerated() {
                        let p = probs[cls] ?? 0
                        if best == nil || p > best!.1 { best = (k, p) }
                    }
                }
                heads[head.rawValue]!["i"]!.append(best?.0 ?? -1)
                heads[head.rawValue]!["p"]!.append(best.map { percent($0.1) } ?? 0)
            }
        }
        return ["format": "mh-col-1", "n": windows.count, "w": bundle.windowS, "s0": windows.first.map { $0.startTs as Any } ?? NSNull(),
                "ds": ds, "x": x, "mi": mi, "heads": heads]
    }

    /// Through JSON text, as the route and the on-disk store carry it.
    private func roundTrip(_ object: [String: Any]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    func testDecodesTheWorkersColumnsIntoValidWindowsWithTheSameTopClasses() throws {
        let b = bundle(), source = windows()
        let columns = try XCTUnwrap(MotionHeadsColumns(try roundTrip(compact(source, bundle: b)), bundle: b))
        XCTAssertEqual(columns.windows.map(\.startTs), source.map(\.startTs))
        XCTAssertEqual(columns.windows.map(\.endTs), source.map(\.endTs))
        XCTAssertEqual(columns.windows.map(\.isOOD), [false, false, true])
        XCTAssertEqual(columns.windows.map(\.movementIntensity), [0.12, nil, 0.9])
        for (k, w) in columns.windows.enumerated() {
            XCTAssertNoThrow(try w.validate(against: b, index: k))
            XCTAssertNil(w.oodScore)
            for head in MotionHead.allCases {
                let original = source[k].probabilities(head)
                let decoded = w.probabilities(head)
                XCTAssertEqual(decoded == nil, original == nil, "\(head) of window \(k)")
                guard let original, let decoded else { continue }
                let top = { (d: [String: Double]) in
                    b.heads[head]!.supportedClasses.max { (d[$0] ?? 0) < (d[$1] ?? 0) }!
                }
                XCTAssertEqual(top(decoded), top(original), "\(head) of window \(k)")
                XCTAssertEqual(decoded[top(original)]!, (original[top(original)]! * 100).rounded() / 100, accuracy: 1e-12)
            }
        }
        // The rest of a categorical head follows the calibration prior: no claim among the non-top classes.
        let loco = try XCTUnwrap(columns.windows[0].locomotion)
        XCTAssertEqual(loco["stationary"]!, 0.9, accuracy: 1e-12)
        XCTAssertEqual(loco["walking"]! / loco["cycling"]!, 0.25 / 0.1, accuracy: 1e-9)
        XCTAssertEqual(columns.windows[2].locomotion, ["running": 1, "stationary": 0, "walking": 0, "cycling": 0])
        // A transition event other than the top one reads at its prior.
        let transition = try XCTUnwrap(columns.windows[0].transition)
        XCTAssertEqual(transition["walk_start"], 0.62)
        XCTAssertEqual(transition["run_stop"], 0.05)
        // The decoded windows are a track input the decoder accepts.
        let track = MotionHeadsTrackInput(bundle: b, windows: columns.trackWindows(from: 1_000, to: 1_010))
        XCTAssertEqual(track.windows.map(\.endTs), [1_000, 1_005])
    }

    func testAnEmptyDayDecodesToNoWindows() throws {
        let b = bundle()
        let columns = try XCTUnwrap(MotionHeadsColumns(try roundTrip(compact([], bundle: b)), bundle: b))
        XCTAssertTrue(columns.windows.isEmpty)
    }

    func testRefusesObjectsThatDoNotMatchTheFormatOrTheBundle() throws {
        let b = bundle()
        let good = compact(windows(), bundle: b)
        XCTAssertNotNil(MotionHeadsColumns(try roundTrip(good), bundle: b))
        func refused(_ label: String, _ mutate: (inout [String: Any]) -> Void,
                     bundle other: MotionHeadsBundleInfo? = nil) throws {
            var o = good
            mutate(&o)
            XCTAssertNil(MotionHeadsColumns(try roundTrip(o), bundle: other ?? b), label)
        }
        try refused("format") { $0["format"] = "mh-col-2" }
        try refused("window length") { $0["w"] = 30 }
        try refused("short column") { $0["mi"] = [12, -1] }
        try refused("starts not increasing") { $0["ds"] = [0, 5, 0] }
        try refused("first delta") { $0["ds"] = [5, 5, 10] }
        try refused("ood flag") { $0["x"] = [0, 2, 1] }
        try refused("intensity") { $0["mi"] = [12, -1, 101] }
        try refused("class index outside the supported classes") {
            var heads = $0["heads"] as! [String: [String: [Int]]]
            heads["locomotion"]!["i"] = [0, 1, 4]
            $0["heads"] = heads
        }
        try refused("percent") {
            var heads = $0["heads"] as! [String: [String: [Int]]]
            heads["posture"]!["p"] = [70, 0, 140]
            $0["heads"] = heads
        }
        try refused("a head the bundle does not support") {
            var heads = $0["heads"] as! [String: [String: [Int]]]
            heads["gesture"] = ["i": [0, 0, 0], "p": [50, 50, 50]]
            $0["heads"] = heads
        }
        try refused("a supported head missing") {
            var heads = $0["heads"] as! [String: [String: [Int]]]
            heads["arm_behavior"] = nil
            $0["heads"] = heads
        }
        try refused("another bundle's window length", { _ in }, bundle: MotionHeadsKit.bundle(windowS: 30, hopS: 5))
        XCTAssertNil(MotionHeadsColumns(nil, bundle: b))
    }
}
