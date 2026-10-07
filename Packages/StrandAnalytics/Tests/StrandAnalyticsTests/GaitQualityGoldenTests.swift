import XCTest
@testable import StrandAnalytics

/// ElderNet off in every way it can be off reproduces the decoder goldens (`Goldens/ActivityContext/`, recorded
/// before any ElderNet code existed) byte for byte; ElderNet ON with zero weights reproduces them once its own
/// provenance and its reported block are set aside.
final class GaitQualityGoldenTests: XCTestCase {

    /// A window every 5 s with strong, varied opinions (gait with brisk / easy cadences, non-gait, pre-filtered),
    /// so a leak of any term would show.
    static func loudWindow(_ e: Int) -> GaitQualityWindow {
        switch (e / 5) % 4 {
        case 0: return GaitKit.window(endingAt: e, p: 0.99, speed: 1.7, cadence: 140, stride: 1.6, regularity: 0.9, steps: 23)
        case 1: return GaitKit.window(endingAt: e, p: 0.02)
        case 2: return GaitKit.prefiltered(endingAt: e)
        default: return GaitKit.window(endingAt: e, p: 0.9, speed: 0.6, cadence: 72, stride: 0.8, regularity: 0.4, steps: 12)
        }
    }

    static func withGait(_ obs: [ActivityObservation]) -> [ActivityObservation] {
        GaitKit.attach(obs) { loudWindow($0) }
    }

    static func withGait(_ input: ActivityContextTrackInput, model: GaitQualityModelInfo) -> ActivityContextTrackInput {
        var input = input
        let windows = stride(from: input.dayStart + 10, to: input.dayEnd, by: 5).map { loudWindow($0) }
        input.gaitQuality = GaitQualityTrackInput(model: model, windows: windows)
        return input
    }

    func testGaitWindowsPresentWithoutAConfigAreByteIdentical() throws {
        for scenario in ActivityGoldenScenarios.all {
            let out = try ActivityGoldenScenarios.run(
                scenario, transformObservations: Self.withGait,
                transformInput: { Self.withGait($0, model: GaitKit.model()) })
            try ActivityContextGoldenTests.assertMatchesGolden(scenario.name, out, variant: "gait windows present, config nil")
        }
    }

    /// A config that refuses its model (shadow mode, a pin on another digest or version, out-of-bounds weights,
    /// production without pins) is the same as no config: byte-identical, `cacheTag` included.
    func testRefusedGaitConfigsAreByteIdentical() throws {
        let refused: [(String, (ActivityDecoderConfig) -> ActivityDecoderConfig)] = [
            ("shadow mode", { GaitKit.config(base: $0, mode: .shadow) }),
            ("pinned digest mismatch", { GaitKit.config(base: $0, pinDigest: String(repeating: "0", count: 64)) }),
            ("pinned version mismatch", { GaitKit.config(base: $0, pinVersion: "eldernet-other") }),
            ("weight above the ceiling", { GaitKit.config(base: $0, gait: 0.95) }),
            ("production without pins", { GaitKit.config(base: $0, mode: .production) }),
        ]
        for (label, make) in refused {
            for scenario in ActivityGoldenScenarios.all {
                let config = make(scenario.config)
                XCTAssertNotNil(config.gaitQuality?.evidenceRefusal, label)
                let out = try ActivityGoldenScenarios.run(
                    scenario, config: config, transformObservations: Self.withGait,
                    transformInput: { Self.withGait($0, model: config.gaitQuality!.model) })
                try ActivityContextGoldenTests.assertMatchesGolden(scenario.name, out, variant: label)
            }
        }
    }

    /// ElderNet ACTIVE with every weight at zero runs every gait code path (windows held in the feature window,
    /// terms evaluated, the shared budget computed, the stretch tracked and reported) and must reproduce the
    /// goldens once its own provenance (stamp, held window, cache-tag suffix) and its reported `gait` blocks are set
    /// aside. With Inertia active at zero weights too, both together.
    func testActiveGaitWithZeroWeightsReproducesTheGoldens() throws {
        #if !canImport(Darwin)
        throw XCTSkip("goldens are recorded with Darwin libm")
        #else
        for withInertia in [false, true] {
            for scenario in ActivityGoldenScenarios.all {
                var config = GaitKit.config(base: scenario.config, gait: 0, brisk: 0)
                if withInertia {
                    config.motionHeads = MotionHeadsKit.config(base: scenario.config, locomotion: 0, posture: 0, arm: 0).motionHeads
                }
                XCTAssertNil(config.gaitQuality?.evidenceRefusal)
                let out = try ActivityGoldenScenarios.run(
                    scenario, config: config,
                    transformObservations: { obs in
                        let g = Self.withGait(obs)
                        return withInertia ? ActivityContextGoldenTests.withHeads(g) : g
                    },
                    transformInput: { input in
                        let g = Self.withGait(input, model: config.gaitQuality!.model)
                        return withInertia ? ActivityContextGoldenTests.withHeads(g, bundle: config.motionHeads!.bundle) : g
                    })
                let golden = try ActivityContextGoldenTests.load(scenario.name)
                let label = "\(scenario.name)\(withInertia ? " + inertia" : "")"
                XCTAssertTrue(out.versions.contains("\"gait_quality\":\"eldernet:"), label)
                XCTAssertTrue(out.cacheTag.contains("-eg"), label)
                XCTAssertTrue(out.cacheTag.hasPrefix(golden.cacheTag.trimmingCharacters(in: .newlines)), label)
                XCTAssertEqual(try Self.stripped(out.states), try Self.stripped(golden.states), "\(label): states")
                XCTAssertEqual(try Self.stripped(out.snapshot), try Self.stripped(golden.snapshot), "\(label): snapshot")
                XCTAssertEqual(try Self.stripped(out.versions), try Self.stripped(golden.versions), "\(label): versions")
                XCTAssertEqual(out.events, golden.events, "\(label): events")
                XCTAssertEqual(try out.document.map(Self.stripped), try golden.document.map(Self.stripped), "\(label): document")
                XCTAssertNotEqual(out.snapshot, golden.snapshot, "the active decoder does hold the window")
            }
        }
        #endif
    }

    /// Some scenario actually publishes a gait block with zero weights (so the strip above is not vacuous).
    func testZeroWeightsStillReportTheBlockSomewhere() throws {
        let scenario = ActivityGoldenScenarios.mixedObservations()
        guard case .observations(let raw) = scenario.source else { return XCTFail("observations scenario") }
        let config = GaitKit.config(base: scenario.config, gait: 0, brisk: 0)
        let t = ActivityContextTrackBuilder.decode(GaitKit.attach(raw) { e in
            GaitKit.window(endingAt: e, p: 0.97)
        }, config: config)
        XCTAssertGreaterThan(t.states.filter { $0.gait != nil }.count, 0)
    }

    /// JSON text (one document per line) with every ElderNet and Inertia key removed at any depth, re-encoded
    /// with sorted keys.
    static func stripped(_ text: String) throws -> String {
        let keys: Set<String> = ["gait_quality", "gaitQuality", "gaitQualitySeenTs", "gaitStretch", "gait",
                                 "motion_heads", "motionHeads", "motionHeadsSeenTs",
                                 // The day fingerprint folds the accepted windows, so an active channel moves it.
                                 "context_fp"]
        func strip(_ v: Any) -> Any {
            if let d = v as? [String: Any] {
                var out: [String: Any] = [:]
                for (k, x) in d where !keys.contains(k) { out[k] = strip(x) }
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
}
