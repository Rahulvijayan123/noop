import XCTest
@testable import StrandAnalytics

/// The committed Python sidecar response (Tools/CloudWorker/Tests/.../sleep_features_response.json,
/// the real answer to the committed request fixture) must decode into the document the Sleep tab
/// renders, block for block. A rename on either side fails here instead of leaving a silent empty card.
final class SleepFeatureCrossLanguageTests: XCTestCase {

    func testRealPythonResponseDecodesBlockForBlock() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repo.appendingPathComponent(
            "Tools/CloudWorker/Tests/frwhoop-workerTests/SleepFeatureWireFixtures/sleep_features_response.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("cross-language fixture not present at \(fixture.path)")
        }
        let data = try Data(contentsOf: fixture)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawNight = try XCTUnwrap((raw["nights"] as? [[String: Any]])?.first)

        let doc = try JSONDecoder().decode(SleepFeatureDocument.self, from: data)
        XCTAssertEqual(doc.nights.count, (raw["nights"] as? [Any])?.count)
        let night = try XCTUnwrap(doc.nights.first)

        let decoded: [(String, Bool)] = [
            ("continuity", night.continuity != nil), ("architecture", night.architecture != nil),
            ("stage_physiology", night.stagePhysiology != nil), ("settling", night.settling != nil),
            ("thermal", night.thermal != nil), ("respiratory_variability", night.respiratoryVariability != nil),
            ("coverage", night.coverage != nil), ("metric_status", night.metricStatus != nil),
        ]
        for (key, present) in decoded {
            let sent = rawNight[key] != nil && !(rawNight[key] is NSNull)
            XCTAssertEqual(present, sent, "block \(key): decoded=\(present) sent=\(sent)")
        }
        let continuity = try XCTUnwrap(rawNight["continuity"] as? [String: Any])
        XCTAssertEqual(night.continuity?.tstMin, continuity["tst_min"] as? Double)
        XCTAssertEqual(night.continuity?.wasoMin, continuity["waso_min"] as? Double)
        XCTAssertNotNil(doc.regularity)
        XCTAssertNotNil(doc.night(matchingStart: night.startAtUnix, end: night.endAtUnix),
                        "the Sleep tab matches a document to the night it is showing by its span")
    }
}
