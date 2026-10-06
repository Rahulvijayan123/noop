import XCTest
@testable import StrandAnalytics

/// The offline replay harness (`ActivityReplayHarness.swift`). The comparison run itself only happens when
/// `ACTIVITY_REPLAY_IN` points at a `nara-activity-replay-1` file:
///
///     ACTIVITY_REPLAY_IN=/path/records.jsonl ACTIVITY_REPLAY_OUT=/path/out.json \
///         swift test --filter ActivityReplayTests/testReplayFromEnvironment
///
/// The other tests pin the format: a recorded day replayed through the record mirror decodes bit-for-bit like
/// the same day decoded directly.
final class ActivityReplayTests: XCTestCase {

    func testReplayFromEnvironment() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inPath = env["ACTIVITY_REPLAY_IN"], !inPath.isEmpty else {
            throw XCTSkip("set ACTIVITY_REPLAY_IN (and ACTIVITY_REPLAY_OUT) to run the offline replay")
        }
        let input = try ActivityReplay.parse(try Data(contentsOf: URL(fileURLWithPath: inPath)))
        let output = try ActivityReplay.run(input)
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let outPath = env["ACTIVITY_REPLAY_OUT"].flatMap { $0.isEmpty ? nil : $0 } ?? inPath + ".out.json"
        try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
        print("activity replay: \(input.sequences.count) sequence(s), arms \(input.header.arms ?? ActivityReplayHeader.allArms) -> \(outPath)")
    }

    private func sampleDay() -> [ActivityObservation] {
        var sim = ActivitySim(start: 1_760_000_000, seed: 17)
        var desk = ActivitySim.Options()
        desk.encoder = SimEncoder.coarse("stationary")
        desk.imu = ActivityGoldenScenarios.imu(accel: 0.03, gyro: 6, cadenceHz: nil, strength: 0.05, orientation: 3)
        sim.sleeping(200)
        sim.desk(200, opt: desk)
        var walk = ActivitySim.Options()
        walk.encoder = SimEncoder.coarse("walking")
        walk.imu = ActivityGoldenScenarios.imu(accel: 0.14, gyro: 40, cadenceHz: 1.8, strength: 0.6, orientation: 12)
        sim.walk(200, opt: walk)
        sim.offWrist(30)
        sim.fidget(100)
        var effort = ActivitySim.Options()
        effort.workout = true
        effort.workoutKind = .cycling
        sim.vigorous(120, opt: effort)
        return MotionHeadsKit.attach(sim.observations) { ActivityContextGoldenTests.loudWindow($0) }
    }

    private func header(arms: [String]? = nil, standIn: Bool = false) -> ActivityReplayHeader {
        ActivityReplayHeader(
            format: ActivityReplayHeader.formatName, arms: arms,
            decoder: .init(restingHR: 57, maxHR: 187),
            motionHeads: .init(bundle: standIn ? MotionHeadsKit.bundle(kind: .standin, tier: .shadow) : MotionHeadsKit.bundle(),
                               config: .init(locomotion: 0.3, posture: 0.2, arm: 0.25, bodyBudget: nil, armBudget: nil,
                                             hartRedundancy: nil),
                               allowStandIn: standIn))
    }

    /// An ActivitySim day written as replay records, read back and decoded through the public track builder
    /// equals a direct decode of the same observations, bit for bit, for every arm's config.
    func testReplayRecordsRoundTripBitForBit() throws {
        let day = sampleDay()
        let h = header()
        let data = try ActivityReplay.encode(header: h, sequences: [("day-1", day), ("day-2", Array(day.suffix(300)))])
        let input = try ActivityReplay.parse(data)
        XCTAssertEqual(input.sequences.map(\.id), ["day-1", "day-2"])
        XCTAssertEqual(input.sequences[0].observations, day, "the record mirror is lossless")
        XCTAssertEqual(input.sequences[1].observations, Array(day.suffix(300)))

        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        for config in [ActivityReplay.baseConfig(h), try XCTUnwrap(ActivityReplay.inertiaConfig(h))] {
            let direct = ActivityContextTrackBuilder.decode(day, config: config)
            let replayed = ActivityContextTrackBuilder.decode(input.sequences[0].observations, config: config)
            XCTAssertEqual(try e.encode(replayed.states), try e.encode(direct.states))
            XCTAssertEqual(try e.encode(replayed.snapshot), try e.encode(direct.snapshot))
            XCTAssertEqual(replayed.events, direct.events)
        }
    }

    func testEveryArmRunsAndTheyDiffer() throws {
        let input = try ActivityReplay.parse(ActivityReplay.encode(header: header(), sequences: [("d", sampleDay())]))
        let out = try ActivityReplay.run(input)
        let arms = try XCTUnwrap(out["arms"] as? [String: [String: [String: Any]]])
        XCTAssertEqual(Set(arms.keys), Set(ActivityReplayHeader.allArms))
        var signatures: [String: String] = [:]
        for (name, perSeq) in arms {
            let entry = try XCTUnwrap(perSeq["d"])
            XCTAssertTrue(entry["refusal"] is NSNull, "\(name): \(entry["refusal"] ?? "")")
            let states = try XCTUnwrap(entry["states"] as? [[String: Any]])
            XCTAssertFalse(states.isEmpty, name)
            let first = states[states.count / 2]
            for key in ["ts", "posture", "locomotion", "arm_behavior", "display", "class", "class_confidence", "unknown",
                        "overall_confidence", "overall_uncertainty", "transition"] {
                XCTAssertNotNil(first[key], "\(name) state lacks \(key)")
            }
            signatures[name] = String(decoding: try JSONSerialization.data(withJSONObject: states, options: [.sortedKeys]),
                                      as: UTF8.self)
        }
        XCTAssertNotNil((arms["hart+inertia"]?["d"]?["motion_heads"] as? [String: Any])?["stamp"] as? String)
        XCTAssertEqual(Set(signatures.values).count, signatures.count, "each arm is a different decode")
    }

    func testAStandInBundleNeedsTheTestOverride() throws {
        var h = header(standIn: true)
        h.motionHeads?.allowStandIn = false
        let refused = try ActivityReplay.run(ActivityReplay.parse(ActivityReplay.encode(header: h, sequences: [("d", sampleDay())])))
        let arms = try XCTUnwrap(refused["arms"] as? [String: [String: [String: Any]]])
        XCTAssertEqual(arms["inertia"]?["d"]?["refusal"] as? String, "encoder_kind_standin")
        XCTAssertEqual((arms["inertia"]?["d"]?["states"] as? [Any])?.count, 0)
        let admitted = try ActivityReplay.run(ActivityReplay.parse(
            ActivityReplay.encode(header: header(standIn: true), sequences: [("d", sampleDay())])))
        let a = try XCTUnwrap(admitted["arms"] as? [String: [String: [String: Any]]])
        XCTAssertTrue(a["inertia"]?["d"]?["refusal"] is NSNull)
        let stamp = (a["inertia"]?["d"]?["motion_heads"] as? [String: Any])?["stamp"] as? String
        XCTAssertTrue(stamp?.hasPrefix("standin-test:") ?? false, stamp ?? "nil")
    }

    func testMalformedReplayFilesAreRefused() {
        XCTAssertThrowsError(try ActivityReplay.parse(Data()))
        XCTAssertThrowsError(try ActivityReplay.parse(Data(#"{"format":"other"}"#.utf8)))
        XCTAssertThrowsError(try ActivityReplay.parse(Data(#"{"format":"nara-activity-replay-1","arms":["x"]}"#.utf8)))
        let unordered = #"{"format":"nara-activity-replay-1"}"# + "\n"
            + #"{"seq":"a","obs":{"ts":10}}"# + "\n" + #"{"seq":"a","obs":{"ts":10}}"#
        XCTAssertThrowsError(try ActivityReplay.parse(Data(unordered.utf8)))
    }

    /// The replay path refuses what the wire decoder refuses: the header bundle goes through `parseBundle`, every
    /// window through the structural checks and then `validate(against:)` the header's bundle.
    func testReplayRecordsGetTheWireValidation() throws {
        let h = header()
        let good = try ActivityReplay.encode(header: h, sequences: [("d", Array(sampleDay().prefix(40)))])
        XCTAssertNoThrow(try ActivityReplay.parse(good))
        var lines = String(decoding: good, as: UTF8.self).split(separator: "\n").map(String.init)
        let withWindow = try XCTUnwrap(lines.indices.dropFirst().first { lines[$0].contains("\"motion_heads\":{") })
        func refused(_ mutate: (inout [String: Any]) -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
            var copy = lines
            var rec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(copy[withWindow].utf8)) as? [String: Any])
            var obs = try XCTUnwrap(rec["obs"] as? [String: Any])
            var w = try XCTUnwrap(obs["motion_heads"] as? [String: Any])
            mutate(&w)
            obs["motion_heads"] = w
            rec["obs"] = obs
            copy[withWindow] = String(decoding: try JSONSerialization.data(withJSONObject: rec), as: UTF8.self)
            XCTAssertThrowsError(try ActivityReplay.parse(Data(copy.joined(separator: "\n").utf8)), file: file, line: line)
        }
        try refused { w in var p = w["posture"] as! [String: Any]; p.removeValue(forKey: "recumbent"); w["posture"] = p }
        try refused { w in var p = w["locomotion"] as! [String: Any]; p["stationary"] = 0.9; w["locomotion"] = p }
        try refused { w in w["e"] = (w["s"] as! Int) + 30 }        // the bundle's windows are 10 s
        try refused { w in w["s"] = 1e19 }
        try refused { w in w["kneeling"] = 1 }
        // A window without a bundle in the header is refused too.
        var bare = h
        bare.motionHeads = nil
        lines[0] = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
        XCTAssertThrowsError(try ActivityReplay.parse(Data(lines.joined(separator: "\n").utf8)))
    }

    func testTheNaiveAverageFoldsInertiaOntoTheV1Labels() {
        let v1 = ActivityReplay.v1Labels(["stationary": 0.1, "walking": 0.2, "brisk_walking": 0.1, "stairs": 0.1,
                                          "running": 0.3, "cycling": 0.1, "vehicle_motion": 0.05, "other": 0.05])
        XCTAssertEqual(Set(v1.keys), ["stationary", "walking", "running", "other_movement"])
        XCTAssertEqual(v1["stationary"]!, 0.1, accuracy: 1e-12)
        XCTAssertEqual(v1["walking"]!, 0.4, accuracy: 1e-12)
        XCTAssertEqual(v1["running"]!, 0.3, accuracy: 1e-12)
        XCTAssertEqual(v1["other_movement"]!, 0.2, accuracy: 1e-12)
    }
}
