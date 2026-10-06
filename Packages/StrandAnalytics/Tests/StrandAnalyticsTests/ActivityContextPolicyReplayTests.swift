import XCTest
@testable import StrandAnalytics

/// Cross-runtime replay of the committed synthetic fixture (spec A04 / audit WS-07-F04).
///
/// The fixture `Tools/ActivityContext/tests/fixtures/policy_replay_fixture.json` is
/// generated deterministically by `generate_policy_replay_fixture.py` and carries
/// timestamped windows across three sessions with two known WITHIN-session
/// transitions. This test replays it through the deployed
/// `ActivityContextPolicy.buildEpochs` (the coarse policy that actually ships on
/// device) and asserts the exact epochs and hysteresis transition offsets the
/// fixture declares. The Python side replays the SAME file through
/// `activity_context.evaluate._transition_delay`, so the two runtimes are pinned
/// to one shared truth — a Python evaluation can never silently diverge from the
/// Swift temporal behavior.
///
/// The fixture is synthetic (no raw WISDM data in git).
final class ActivityContextPolicyReplayTests: XCTestCase {

    // MARK: - Fixture decoding

    private struct ReplayFixture: Decodable {
        struct Meta: Decodable { let name: String; let base: Int; let nWindows: Int }
        struct ExpectEpoch: Decodable {
            let s: Int; let e: Int; let motion: String
            let observedS: Int; let validS: Int
        }
        struct ExpectTransition: Decodable {
            let from: String; let to: String; let offset: Int
        }
        struct Expect: Decodable { let epochs: [ExpectEpoch]; let transitions: [ExpectTransition] }
        let meta: Meta
        let runStart: Int
        let runEnd: Int
        let windows: [ActivityWindowPrediction]
        let expect: Expect
    }

    private func fixtureURL() throws -> URL {
        // Resolve relative to THIS source file: .../Packages/StrandAnalytics/
        // Tests/StrandAnalyticsTests/ -> walk up 4 levels to the repo root.
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StrandAnalyticsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // StrandAnalytics
            .deletingLastPathComponent()   // Packages
        let url = dir.appendingPathComponent(
            "Tools/ActivityContext/fixtures/policy_replay_fixture.json")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        // Fallback: relative to the package root (swift test runs from
        // Packages/StrandAnalytics by convention).
        let alt = URL(fileURLWithPath: "../..")
            .appendingPathComponent("Tools/ActivityContext/fixtures/policy_replay_fixture.json")
        guard FileManager.default.fileExists(atPath: alt.path) else {
            throw XCTSkip("fixture not found (expected at \(url.path) or \(alt.path))")
        }
        return alt
    }

    private func loadFixture() throws -> ReplayFixture {
        let data = try Data(contentsOf: fixtureURL())
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase  // meta.n_windows
        return try decoder.decode(ReplayFixture.self, from: data)
    }

    // MARK: - Replay assertions

    func testReplayProducesDeclaredEpochsAndTransitions() throws {
        let fixture = try loadFixture()
        let build = ActivityContextPolicy.buildEpochs(
            windows: fixture.windows,
            runStart: fixture.runStart,
            runEnd: fixture.runEnd)

        // Exact epoch count and grid alignment (8 epochs: 2 + 4 + 2).
        XCTAssertEqual(build.epochs.count, fixture.expect.epochs.count,
                       "epoch count must match the fixture declaration")

        for (epoch, expect) in zip(build.epochs, fixture.expect.epochs) {
            XCTAssertEqual(epoch.startTs, expect.s, "epoch start")
            XCTAssertEqual(epoch.endTs, expect.e, "epoch end")
            XCTAssertEqual(epoch.motion.rawValue, expect.motion, "epoch motion at \(expect.s)")
            XCTAssertEqual(epoch.observedS, expect.observedS, "observed seconds at \(expect.s)")
            XCTAssertEqual(epoch.validS, expect.validS, "valid seconds at \(expect.s)")
            XCTAssertEqual(epoch.startTs % 30, 0, "epoch on the 30-s UTC grid")
        }

        // Hysteresis flips must match the fixture's declared offsets exactly
        // (first disagreeing window). Session-boundary label resets are NOT
        // transitions, so there are exactly two.
        XCTAssertEqual(build.transitions.count, fixture.expect.transitions.count,
                       "transition count must match the fixture declaration")
        for (transition, expect) in zip(build.transitions, fixture.expect.transitions) {
            XCTAssertEqual(transition.from.rawValue, expect.from, "transition from")
            XCTAssertEqual(transition.to.rawValue, expect.to, "transition to")
            XCTAssertEqual(transition.offset, expect.offset, "transition offset")
        }
    }

    func testReplaySessionsDoNotBleedAcrossGaps() throws {
        let fixture = try loadFixture()
        let build = ActivityContextPolicy.buildEpochs(
            windows: fixture.windows,
            runStart: fixture.runStart,
            runEnd: fixture.runEnd)
        // Session 2 (running) begins at base+300; no walking/stationary
        // hysteresis may survive the gap into it.
        let base = fixture.meta.base
        let runningEpochs = build.epochs.filter { $0.startTs >= base + 300 }
        XCTAssertEqual(runningEpochs.count, 2)
        XCTAssertTrue(runningEpochs.allSatisfy { $0.motion == .running })
    }
}
