import XCTest
@testable import StrandAnalytics

/// The Python side (`Tools/EnergyModels`, `energy-evidence`) and this package meet at one JSON document.
/// These tests decode a document the Python pipeline wrote and push it through the estimator, so a renamed
/// key, a shifted minute grid or a changed schema fails here instead of silently dropping the evidence.
final class MotionEvidenceContractTests: XCTestCase {
    private func exampleData() throws -> Data {
        // …/Packages/StrandAnalytics/Tests/StrandAnalyticsTests/<this file> → four levels up is the repository root.
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url.appendPathComponent("Tools/EnergyModels/tests/fixtures/energy_motion_evidence_v1.example.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Python example document not found at \(url.path)")
        }
        return try Data(contentsOf: url)
    }

    func testTheDocumentThePythonPipelineWritesDecodes() throws {
        let doc = try MotionEvidenceDocument.decode(try exampleData())
        XCTAssertEqual(doc.minutes.count, 3)
        XCTAssertEqual(doc.minutes.map(\.minuteStart), [1_790_035_200, 1_790_035_260, 1_790_035_320])
        XCTAssertTrue(doc.minutes.allSatisfy { $0.minuteStart % 60 == 0 && $0.imuSeconds == 60 })

        let rest = doc.minutes[0]
        XCTAssertEqual(rest.wristMET?.met, 1.0)
        XCTAssertLessThan(rest.wristMET?.pActive ?? 1, 0.05, "a sedentary call carries a low probability of being active")
        XCTAssertNil(rest.cnn, "the CNN is not run on sedentary minutes")

        let active = doc.minutes[1]
        XCTAssertGreaterThan(active.wristMET?.met ?? 0, 3)
        XCTAssertGreaterThan(active.wristMET?.pActive ?? 0, 0.95)
        XCTAssertEqual(active.cnn?.met, 3.3)
        XCTAssertEqual(active.cnn?.model, "wrist-cnn-9ca77ea")
        XCTAssertNotNil(active.wristMETDemographicOOD)
        XCTAssertTrue(active.wristMET?.model.hasPrefix("wristmet-v1-") ?? false)
    }

    func testPythonEvidenceReachesTheEstimatorOnTheSameMinuteGrid() throws {
        let doc = try MotionEvidenceDocument.decode(try exampleData())
        let start = SyntheticDay.dayStart
        XCTAssertEqual(doc.minutes[0].minuteStart, start, "the example is anchored on the synthetic day's first minute")

        var day = SyntheticDay()
        day.add(.sitting(10))
        let estimate = MetabolicEstimator.estimate(day.input(motionEvidence: doc.minutes))
        XCTAssertEqual(estimate.evidenceMinutes["wristmet"], 3)
        XCTAssertEqual(estimate.evidenceMinutes["wrist_cnn"], 2)
        XCTAssertTrue(estimate.minutes[0].evidence.contains(.wristMET))
        XCTAssertFalse(estimate.minutes[0].evidence.contains(.wristCNN))
        XCTAssertTrue(estimate.minutes[1].evidence.contains(.wristCNN))
    }

    func testADocumentFromAnotherSchemaIsRefused() throws {
        let text = String(data: try exampleData(), encoding: .utf8)!
            .replacingOccurrences(of: MotionEvidenceDocument.schema, with: "energy-motion-evidence-v2")
        XCTAssertThrowsError(try MotionEvidenceDocument.decode(Data(text.utf8)))
    }
}
