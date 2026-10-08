import XCTest
@testable import frwhoop_worker

/// The worker's own identity: the executable digest it measures, the release stamp beside it, and
/// whether the release's build record names the bytes that run. A configured revision is only a claim.
final class RuntimeIdentityTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A release laid out like /opt/noop/releases/<id>, with a fake executable where the build puts it.
    private func makeRelease(executableBytes: Data, recordedSHA: String?,
                             stampAtBuild: String? = nil, commit: String = String(repeating: "a", count: 40))
        throws -> (release: URL, executable: URL, stamp: URL) {
        let release = root.appendingPathComponent(commit, isDirectory: true)
        let binDir = release.appendingPathComponent("Tools/CloudWorker/.build/x86_64-unknown-linux-gnu/release",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let executable = binDir.appendingPathComponent("frwhoop-worker")
        try executableBytes.write(to: executable)
        let stamp = release.appendingPathComponent("RELEASE.json")
        let stampDoc: [String: Any] = [
            "schema": "nara-release-stamp/1", "release_id": commit, "git_commit": commit,
            "git_tree": String(repeating: "b", count: 40), "dirty": false,
            "created_at_utc": "2026-10-07T00:00:00Z",
            "package_resolved_sha256": String(repeating: "c", count: 64),
            "files": ["name": "RELEASE.files", "count": 3, "sha256": String(repeating: "d", count: 64)],
        ]
        let stampData = try JSONSerialization.data(withJSONObject: stampDoc, options: [.sortedKeys])
        try stampData.write(to: stamp)
        if let recordedSHA {
            let build: [String: Any] = [
                "schema": "nara-release-build/1", "release_id": commit,
                "release_stamp_sha256": stampAtBuild ?? sha256Hex(stampData),
                "built_at_utc": "2026-10-07T01:00:00Z", "swift_version": "Swift version 6.0.3",
                "platform": "Linux x86_64",
                "executables": ["frwhoop-worker": ["path": "Tools/CloudWorker/.build/release/frwhoop-worker",
                                                   "sha256": recordedSHA, "size_bytes": executableBytes.count]],
                "tests": ["status": "passed", "summary": "Executed 3 tests"],
            ]
            try JSONSerialization.data(withJSONObject: build).write(to: release.appendingPathComponent("BUILD.json"))
        }
        return (release, executable, stamp)
    }

    func testMeasuresTheBytesOfTheGivenExecutable() throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let file = root.appendingPathComponent("frwhoop-worker")
        try bytes.write(to: file)
        let identity = RuntimeIdentity.measure(environment: [:], executablePath: file.path)
        XCTAssertEqual(identity.executableSHA256, sha256Hex(bytes))
        XCTAssertEqual(identity.executablePath, file.path)
        XCTAssertNil(identity.release, "no stamp near the file")
        XCTAssertNil(identity.matchesRelease)
        XCTAssertTrue(identity.errors.isEmpty, "\(identity.errors)")
    }

    func testTheBuildRecordThatNamesTheRunningBytesMatches() throws {
        let bytes = Data("the release binary".utf8)
        let commit = String(repeating: "1", count: 40)
        let made = try makeRelease(executableBytes: bytes, recordedSHA: sha256Hex(bytes), commit: commit)
        let identity = RuntimeIdentity.measure(environment: ["FRWHOOP_SOURCE_REVISION": commit],
                                               executablePath: made.executable.path)
        let release = try XCTUnwrap(identity.release, "the stamp five levels above the binary is found")
        XCTAssertEqual(URL(fileURLWithPath: release.stampPath).resolvingSymlinksInPath(),
                       made.stamp.resolvingSymlinksInPath())
        XCTAssertEqual(release.gitCommit, commit)
        XCTAssertEqual(release.dirty, false)
        XCTAssertEqual(release.build?.executableSHA256, sha256Hex(bytes))
        XCTAssertEqual(identity.matchesRelease, true)
        XCTAssertEqual(identity.claimedRevisionMatchesRelease, true)
    }

    func testABuildRecordForOtherBytesDoesNotMatch() throws {
        let bytes = Data("replaced after the build".utf8)
        let made = try makeRelease(executableBytes: bytes, recordedSHA: String(repeating: "e", count: 64))
        let identity = RuntimeIdentity.measure(environment: [:], executablePath: made.executable.path)
        XCTAssertEqual(identity.matchesRelease, false)
    }

    func testABuildRecordMadeForAnotherStampDoesNotMatch() throws {
        let bytes = Data("binary".utf8)
        let made = try makeRelease(executableBytes: bytes, recordedSHA: sha256Hex(bytes),
                                   stampAtBuild: String(repeating: "f", count: 64))
        let identity = RuntimeIdentity.measure(environment: [:], executablePath: made.executable.path)
        XCTAssertEqual(identity.matchesRelease, false, "the stamp was rewritten after the build")
    }

    func testAStampWithoutABuildRecordLeavesTheComparisonOpen() throws {
        let bytes = Data("unbuilt".utf8)
        let made = try makeRelease(executableBytes: bytes, recordedSHA: nil)
        let identity = RuntimeIdentity.measure(environment: [:], executablePath: made.executable.path)
        XCTAssertNotNil(identity.release)
        XCTAssertNil(identity.release?.build)
        XCTAssertNil(identity.matchesRelease)
    }

    func testTheClaimedRevisionIsOnlyAClaim() throws {
        let bytes = Data("binary".utf8)
        let made = try makeRelease(executableBytes: bytes, recordedSHA: sha256Hex(bytes))
        let identity = RuntimeIdentity.measure(environment: ["FRWHOOP_SOURCE_REVISION": "deadbeef"],
                                               executablePath: made.executable.path)
        XCTAssertEqual(identity.claimedSourceRevision, "deadbeef")
        XCTAssertEqual(identity.claimedRevisionMatchesRelease, false)
        XCTAssertEqual(identity.matchesRelease, true, "the bytes still match; only the claim is stale")
        XCTAssertNil(RuntimeIdentity.measure(environment: ["FRWHOOP_SOURCE_REVISION": ""],
                                             executablePath: made.executable.path).claimedSourceRevision)
    }

    func testTheStampVariableOverridesTheSearch() throws {
        let bytes = Data("binary".utf8)
        let made = try makeRelease(executableBytes: bytes, recordedSHA: sha256Hex(bytes))
        let elsewhere = root.appendingPathComponent("elsewhere/frwhoop-worker")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: elsewhere)
        let identity = RuntimeIdentity.measure(environment: ["FRWHOOP_RELEASE_STAMP": made.stamp.path],
                                               executablePath: elsewhere.path)
        XCTAssertEqual(identity.release?.stampPath, made.stamp.path)
        XCTAssertEqual(identity.matchesRelease, true)
    }

    func testUnreadableInputsAreReportedNeverThrown() throws {
        let missing = RuntimeIdentity.measure(
            environment: ["FRWHOOP_RELEASE_STAMP": root.appendingPathComponent("nope.json").path],
            executablePath: root.appendingPathComponent("no-such-binary").path)
        XCTAssertNil(missing.executableSHA256)
        XCTAssertNil(missing.release)
        XCTAssertNil(missing.matchesRelease)
        XCTAssertEqual(missing.errors.count, 2, "\(missing.errors)")
        XCTAssertNotNil(missing.wire["error"])

        let bytes = Data("binary".utf8)
        let made = try makeRelease(executableBytes: bytes, recordedSHA: sha256Hex(bytes))
        try Data("{not json".utf8).write(to: made.release.appendingPathComponent("BUILD.json"))
        let malformed = RuntimeIdentity.measure(environment: [:], executablePath: made.executable.path)
        XCTAssertNotNil(malformed.release, "a broken build record leaves the stamp readable")
        XCTAssertNil(malformed.release?.build)
        XCTAssertNil(malformed.matchesRelease)
        XCTAssertEqual(malformed.errors.count, 1, "\(malformed.errors)")
    }

    func testTheWireIsJSONWithTheDocumentedMembers() throws {
        let bytes = Data("binary".utf8)
        let made = try makeRelease(executableBytes: bytes, recordedSHA: sha256Hex(bytes))
        let identity = RuntimeIdentity.measure(environment: [:], executablePath: made.executable.path)
        let data = try JSONSerialization.data(withJSONObject: identity.wire)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["schema", "claimed_source_revision", "executable", "release", "matches_release",
                    "claimed_revision_matches_release", "measured_at"] {
            XCTAssertNotNil(decoded[key], "missing \(key)")
        }
        XCTAssertEqual(decoded["schema"] as? String, "worker-identity/1")
        XCTAssertTrue(decoded["claimed_source_revision"] is NSNull)
        XCTAssertEqual(decoded["matches_release"] as? Bool, true)
        let executable = try XCTUnwrap(decoded["executable"] as? [String: Any])
        XCTAssertEqual(executable["sha256"] as? String, sha256Hex(bytes))
        let release = try XCTUnwrap(decoded["release"] as? [String: Any])
        XCTAssertEqual((release["build"] as? [String: Any])?["tests"] as? String, "passed")
        XCTAssertNil(decoded["error"])
        XCTAssertEqual(identity.jsonText().data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["schema"] as? String,
            "worker-identity/1")
    }

    func testTheRunningProcessMeasuresItself() {
        let identity = RuntimeIdentity.measure(environment: [:])
        let sha = identity.executableSHA256 ?? ""
        XCTAssertEqual(sha.count, 64, "\(identity.errors)")
        XCTAssertTrue(sha.allSatisfy { $0.isHexDigit })
        XCTAssertNotNil(identity.executablePath)
    }
}
