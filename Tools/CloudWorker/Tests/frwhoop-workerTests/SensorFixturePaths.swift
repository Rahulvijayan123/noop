import Foundation
import XCTest

/// Where the sensor-lane fixtures live, resolved from this source file rather than the working
/// directory, so a test run from anywhere finds them. A missing fixture fails the test: a golden
/// that silently skips would let every cross-stack check pass without running.
enum SensorFixturePaths {
    struct Missing: Error, CustomStringConvertible {
        let path: String
        var description: String { "fixture missing: \(path)" }
    }

    /// `Tools/CloudWorker/Tests/frwhoop-workerTests`.
    static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let repositoryRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let sensorResources = testsDirectory.appendingPathComponent("Resources/sensor_biomarkers")
    static let ppgAnchorGolden = repositoryRoot
        .appendingPathComponent("Packages/NoopPush/Tests/NoopPushTests/Resources/ppg_anchor_v3_golden.json")

    /// A sensor fixture by name: `FRWHOOP_SENSOR_FIXTURE_DIR` first when set, else beside these tests.
    static func sensor(_ name: String) -> URL {
        if let dir = ProcessInfo.processInfo.environment["FRWHOOP_SENSOR_FIXTURE_DIR"], !dir.isEmpty {
            let override = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: override.path) { return override }
        }
        return sensorResources.appendingPathComponent(name)
    }

    /// The bytes at `url`, or a recorded failure (never a skip) when the file is not there.
    static func data(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("fixture missing: \(url.path)", file: file, line: line)
            throw Missing(path: url.path)
        }
        return try Data(contentsOf: url)
    }
}
