import XCTest
@testable import StrandAnalytics

/// Byte-for-byte goldens of the ActivityContext decoder (see `ActivityGoldenScenarios`).
///
/// The fixtures under `Goldens/ActivityContext/` were recorded at `ccd5f0dc` (decoder `hsmm-1.3`)
/// BEFORE the Inertia-1 motion-head channels were added, and are never re-recorded to make a change pass.
/// Re-record only for a deliberate decoder change, with `ACTIVITY_GOLDEN_RECORD=1 swift test --filter
/// ActivityContextGoldenTests`, and say so in the change.
///
/// The fixtures carry full-precision doubles (the snapshot), so they are compared exactly only where they
/// were recorded: Darwin's libm. Another libm may differ in the last bit of `exp`/`log` without any change
/// in behaviour, so the comparison is skipped there rather than reporting noise.
final class ActivityContextGoldenTests: XCTestCase {

    static func fixtureRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens/ActivityContext")
    }

    static func load(_ name: String) throws -> ActivityGoldenOutput {
        let dir = fixtureRoot().appendingPathComponent(name)
        func read(_ file: String) throws -> String {
            String(decoding: try Data(contentsOf: dir.appendingPathComponent(file)), as: UTF8.self)
        }
        let docURL = dir.appendingPathComponent("document.json")
        let document = FileManager.default.fileExists(atPath: docURL.path) ? try read("document.json") : nil
        return ActivityGoldenOutput(states: try read("states.jsonl"), snapshot: try read("snapshot.json"),
                                    versions: try read("versions.json"), cacheTag: try read("cache_tag.txt"),
                                    events: try read("events.json"), document: document)
    }

    static func record(_ name: String, _ out: ActivityGoldenOutput) throws {
        let dir = fixtureRoot().appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ file: String, _ text: String) throws {
            try Data(text.utf8).write(to: dir.appendingPathComponent(file), options: .atomic)
        }
        try write("states.jsonl", out.states)
        try write("snapshot.json", out.snapshot)
        try write("versions.json", out.versions)
        try write("cache_tag.txt", out.cacheTag)
        try write("events.json", out.events)
        if let document = out.document { try write("document.json", document) }
    }

    static var recording: Bool { ProcessInfo.processInfo.environment["ACTIVITY_GOLDEN_RECORD"] == "1" }

    /// Compare one scenario's output with its fixture, naming the first differing state on failure.
    static func assertMatchesGolden(_ name: String, _ out: ActivityGoldenOutput, variant: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        #if !canImport(Darwin)
        throw XCTSkip("goldens are recorded with Darwin libm; exact comparison is not meaningful here")
        #else
        let golden = try load(name)
        if out.states != golden.states {
            let a = out.states.split(separator: "\n"), b = golden.states.split(separator: "\n")
            let i = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            XCTFail("\(name) [\(variant)]: states differ (\(a.count) vs \(b.count) states); first difference at #\(i):\n"
                    + "got      \(i < a.count ? String(a[i]) : "<none>")\nexpected \(i < b.count ? String(b[i]) : "<none>")",
                    file: file, line: line)
        }
        XCTAssertEqual(out.snapshot, golden.snapshot, "\(name) [\(variant)]: snapshot JSON differs", file: file, line: line)
        XCTAssertEqual(out.versions, golden.versions, "\(name) [\(variant)]: versions differ", file: file, line: line)
        XCTAssertEqual(out.cacheTag, golden.cacheTag, "\(name) [\(variant)]: cacheTag differs", file: file, line: line)
        XCTAssertEqual(out.events, golden.events, "\(name) [\(variant)]: events differ", file: file, line: line)
        XCTAssertEqual(out.document, golden.document, "\(name) [\(variant)]: day document differs", file: file, line: line)
        #endif
    }

    func testRecordOrCompareTheDisabledDecoderGoldens() throws {
        for scenario in ActivityGoldenScenarios.all {
            let out = try ActivityGoldenScenarios.run(scenario)
            if Self.recording {
                try Self.record(scenario.name, out)
                continue
            }
            try Self.assertMatchesGolden(scenario.name, out, variant: "default config")
        }
        if Self.recording { throw XCTSkip("recorded \(ActivityGoldenScenarios.all.count) golden scenarios") }
    }

    // MARK: - Inertia off in every way it can be off

    /// A synthetic window every 5 s with strong, varied opinions, so a leak of any term would show.
    static func loudWindow(_ e: Int) -> MotionHeadsWindow {
        let p = MotionHead.posture.classOrder, l = MotionHead.locomotion.classOrder, a = MotionHead.armBehavior.classOrder
        let k = (e / 5) % 4
        return MotionHeadsKit.window(endingAt: e, posture: MotionHeadsKit.peaked(p, p[k], 0.9),
                                     locomotion: MotionHeadsKit.peaked(l, ["stairs", "running", "cycling", "walking"][k], 0.95),
                                     arm: MotionHeadsKit.peaked(a, a[(k + 2) % a.count], 0.9),
                                     transition: Dictionary(uniqueKeysWithValues: MotionHead.transition.classOrder.map { ($0, 0.4) }),
                                     ood: false)
    }

    static func withHeads(_ obs: [ActivityObservation]) -> [ActivityObservation] {
        MotionHeadsKit.attach(obs) { loudWindow($0) }
    }

    static func withHeads(_ input: ActivityContextTrackInput, bundle: MotionHeadsBundleInfo) -> ActivityContextTrackInput {
        var input = input
        let windows = stride(from: input.dayStart + 10, to: input.dayEnd, by: 5).map { loudWindow($0) }
        input.motionHeads = MotionHeadsTrackInput(bundle: bundle, windows: windows)
        return input
    }

    /// Heads on every observation (or in the track input) but no motion-heads config: byte-identical.
    func testHeadsPresentWithoutAConfigAreByteIdentical() throws {
        for scenario in ActivityGoldenScenarios.all {
            let out = try ActivityGoldenScenarios.run(
                scenario, transformObservations: Self.withHeads,
                transformInput: { Self.withHeads($0, bundle: MotionHeadsKit.bundle()) })
            try Self.assertMatchesGolden(scenario.name, out, variant: "heads present, config nil")
        }
    }

    /// A config that refuses its bundle (a stand-in encoder without the test override, a shadow-tier bundle,
    /// shadow mode) is the same as no config: byte-identical, `cacheTag` included.
    func testRefusedConfigsAreByteIdentical() throws {
        let refused: [(String, (ActivityDecoderConfig) -> ActivityDecoderConfig)] = [
            ("stand-in encoder", { MotionHeadsKit.config(MotionHeadsKit.bundle(kind: .standin), base: $0) }),
            ("shadow tier", { MotionHeadsKit.config(MotionHeadsKit.bundle(tier: .shadow), base: $0) }),
            ("shadow mode", { MotionHeadsKit.config(base: $0, mode: .shadow) }),
        ]
        for (label, make) in refused {
            for scenario in ActivityGoldenScenarios.all {
                let config = make(scenario.config)
                XCTAssertNotNil(config.motionHeads?.evidenceRefusal, label)
                let out = try ActivityGoldenScenarios.run(
                    scenario, config: config, transformObservations: Self.withHeads,
                    transformInput: { Self.withHeads($0, bundle: config.motionHeads!.bundle) })
                try Self.assertMatchesGolden(scenario.name, out, variant: label)
            }
        }
    }

    /// Inertia ACTIVE with every weight at zero runs every Inertia code path (windows held in the feature
    /// window, terms evaluated, channels added with weight 0, the posture renormalisation, the arm factor)
    /// and must reproduce the goldens exactly once its own provenance is set aside: the stamp in `versions`,
    /// the held window in the snapshot, and the cache tag suffix.
    func testActiveInertiaWithZeroWeightsReproducesTheGoldens() throws {
        #if !canImport(Darwin)
        throw XCTSkip("goldens are recorded with Darwin libm")
        #else
        for scenario in ActivityGoldenScenarios.all {
            let config = MotionHeadsKit.config(base: scenario.config, locomotion: 0, posture: 0, arm: 0)
            XCTAssertNil(config.motionHeads?.evidenceRefusal)
            let out = try ActivityGoldenScenarios.run(
                scenario, config: config, transformObservations: Self.withHeads,
                transformInput: { Self.withHeads($0, bundle: config.motionHeads!.bundle) })
            let golden = try Self.load(scenario.name)
            XCTAssertTrue(out.versions.contains("\"motion_heads\":\"inertia-1:"), scenario.name)
            XCTAssertTrue(out.cacheTag.hasPrefix(golden.cacheTag.trimmingCharacters(in: .newlines) + "-ih"), scenario.name)
            XCTAssertEqual(try Self.stripped(out.states), try Self.stripped(golden.states), "\(scenario.name): states")
            XCTAssertEqual(try Self.stripped(out.snapshot), try Self.stripped(golden.snapshot), "\(scenario.name): snapshot")
            XCTAssertEqual(try Self.stripped(out.versions), try Self.stripped(golden.versions), "\(scenario.name): versions")
            XCTAssertEqual(out.events, golden.events, "\(scenario.name): events")
            XCTAssertEqual(try out.document.map(Self.stripped), try golden.document.map(Self.stripped), "\(scenario.name): document")
            XCTAssertNotEqual(out.snapshot, golden.snapshot, "the active decoder does hold the window")
        }
        #endif
    }

    /// JSON text (one document per line) with every motion-heads key removed at any depth, re-encoded with
    /// sorted keys.
    static func stripped(_ text: String) throws -> String {
        func strip(_ v: Any) -> Any {
            if let d = v as? [String: Any] {
                var out: [String: Any] = [:]
                for (k, x) in d where !["motion_heads", "motionHeads", "motionHeadsSeenTs"].contains(k) { out[k] = strip(x) }
                return out
            }
            if let a = v as? [Any] { return a.map(strip) }
            return v
        }
        return try text.split(separator: "\n").map { line -> String in
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])
            let data = try JSONSerialization.data(withJSONObject: strip(obj), options: [.sortedKeys, .fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
    }

    /// The goldens are only worth having if the scenarios are deterministic within a process too.
    func testScenariosAreDeterministic() throws {
        for scenario in ActivityGoldenScenarios.all {
            XCTAssertEqual(try ActivityGoldenScenarios.run(scenario), try ActivityGoldenScenarios.run(scenario),
                           scenario.name)
        }
    }
}
