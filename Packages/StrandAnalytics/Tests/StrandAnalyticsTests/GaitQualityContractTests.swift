import XCTest
@testable import StrandAnalytics

/// The Python ElderNet service (`python -m activity_context.eldernet.serve`) and this package meet at the
/// `gait-quality-1` response. These tests decode the golden response the Python side writes
/// (`Tools/ActivityContext/fixtures/eldernet/golden_gait_quality_response.json`) and push it through the track
/// builder, so a renamed key, a changed range, a rounding change that breaks the threshold agreement or a schema
/// change fails here instead of silently dropping the evidence. Skipped until the fixture exists (it is written
/// on the Python branch); `GaitQualityResponseTests` covers the same paths with this package's synthetic fixture.
final class GaitQualityContractTests: XCTestCase {

    private func goldenData() throws -> Data {
        // …/Packages/StrandAnalytics/Tests/StrandAnalyticsTests/<this file> → four levels up is the repository root.
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url.appendPathComponent("Tools/ActivityContext/fixtures/eldernet/golden_gait_quality_response.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Python golden gait-quality response not found at \(url.path)")
        }
        return try Data(contentsOf: url)
    }

    private func check(_ r: GaitQualityResponse) {
        XCTAssertEqual(r.model.modelId, GaitQualityWire.modelId)
        XCTAssertEqual(r.model.preprocessingVersion, GaitQualityWire.preprocessingVersion)
        XCTAssertEqual(r.model.windowS, GaitQualityWire.windowS)
        XCTAssertTrue(GaitQualityWire.allowedHopS.contains(r.model.hopS))
        XCTAssertNotNil(r.model.weights["gait_detection"])
        XCTAssertFalse(r.windows.isEmpty)
        for (i, w) in r.windows.enumerated() {
            XCTAssertEqual(w.endTs - w.startTs, r.model.windowS)
            if i > 0 { XCTAssertGreaterThan(w.startTs, r.windows[i - 1].startTs) }
            if !w.isGait { XCTAssertFalse(w.hasMetrics, "metrics only on gait windows (window \(i))") }
        }
    }

    private func drive(_ r: GaitQualityResponse) throws {
        let first = try XCTUnwrap(r.windows.first).startTs, last = try XCTUnwrap(r.windows.last).endTs
        var sim = ActivitySim(start: first - 30, seed: 13)
        let span = last - first + 60
        sim.still(span / 3)
        sim.walk(span / 3)
        sim.still(span - 2 * (span / 3))
        var input = sim.trackInput()
        input.gaitQuality = GaitQualityTrackInput(model: r.model, windows: r.windows)

        var config = ActivityDecoderConfig()
        config.gaitQuality = GaitQualityEvidenceConfig(mode: .candidate, model: r.model, gaitPrior: 0.2,
                                                       expectedModelVersion: r.model.modelVersion,
                                                       expectedWeightsDigest: r.model.weightsDigest)
        let a = TrackKit.builtTrack(input, config: config)
        let b = TrackKit.builtTrack(input, config: config)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try e.encode(a.states), try e.encode(b.states))
        XCTAssertEqual(try e.encode(a.snapshot), try e.encode(b.snapshot))
        let stamp = try XCTUnwrap(config.gaitQuality?.provenanceStamp)
        XCTAssertEqual(a.gaitQuality?.stamp, stamp)
        XCTAssertEqual(a.gaitQuality?.attached, r.windows.count, "every golden window lands on an observed second")
        XCTAssertTrue(a.states.allSatisfy { $0.versions.gaitQuality == stamp })
        XCTAssertTrue(stamp.hasPrefix("eldernet:\(r.model.modelVersion):\(r.model.weights12):"))
        // Pinned to another digest, the same windows are refused and the decode is the ElderNet-free one.
        var other = config
        other.gaitQuality?.expectedWeightsDigest = String(repeating: "0", count: 64)
        let refused = TrackKit.builtTrack(input, config: other)
        XCTAssertEqual(refused.gaitQuality?.refusal, "weights_digest_mismatch")
        XCTAssertEqual(try e.encode(refused.states), try e.encode(TrackKit.builtTrack(sim.trackInput()).states))
    }

    func testTheGoldenResponseThePythonServiceWritesDecodes() throws {
        let r = try GaitKit.decode(try goldenData())
        check(r)
        let again = try JSONDecoder().decode(GaitQualityModelInfo.self, from: JSONEncoder().encode(r.model))
        XCTAssertEqual(again, r.model)
    }

    func testTheGoldenResponseDrivesTheDecoderDeterministically() throws {
        try drive(try GaitKit.decode(try goldenData()))
    }

    /// The same two checks on this package's own synthetic fixture, so they run before the Python golden exists.
    func testTheSyntheticFixtureDrivesTheDecoderDeterministically() throws {
        let r = try GaitKit.decode(try GaitKit.syntheticFixture())
        check(r)
        try drive(r)
    }
}
