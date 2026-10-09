import Foundation
import CCrypto

/// What this worker process runs, measured from its own bytes rather than claimed by configuration
/// (docs/model-integration/provisioning.md). The heartbeat reports it as `meta.identity`, and
/// `frwhoop-worker --print-identity` prints it and exits before any configuration or connection.
///
/// `FRWHOOP_SOURCE_REVISION` is reported only as `claimed_source_revision`. The executable digest is
/// measured once at startup, on Linux from `/proc/self/exe` (the file actually running, even after its
/// path was replaced), and compared with the release's build record: `BUILD.json` beside the release
/// stamp `RELEASE.json` (deploy/package_release.py writes the stamp, deploy/release-host.sh build the
/// record). A failure to measure is reported in `error`; it never stops startup or the heartbeat.
struct RuntimeIdentity {
    static let schema = "worker-identity/1"
    static let stampEnvironmentKey = "FRWHOOP_RELEASE_STAMP"
    static let stampName = "RELEASE.json"
    static let buildName = "BUILD.json"
    static let executableName = "frwhoop-worker"
    /// Directory levels searched above the executable for a release stamp. The release build puts the
    /// binary at `<release>/Tools/CloudWorker/.build/<triple>/release/frwhoop-worker`, five levels down.
    static let stampSearchDepth = 6

    struct Build {
        let path: String
        let executableSHA256: String?
        let releaseStampSHA256: String?
        let builtAt: String?
        let swiftVersion: String?
        let platform: String?
        let tests: String?
    }

    struct Release {
        let stampPath: String
        let stampSHA256: String
        let releaseID: String?
        let gitCommit: String?
        let gitTree: String?
        let dirty: Bool?
        let createdAt: String?
        let packageResolvedSHA256: String?
        let filesSHA256: String?
        let build: Build?
    }

    let claimedSourceRevision: String?
    let executablePath: String?
    let executableSHA256: String?
    let release: Release?
    let measuredAt: Date
    let errors: [String]

    /// True when the release's build record names exactly the bytes this process runs (and was made for
    /// this stamp); false when it names other bytes; nil when there is nothing to compare.
    var matchesRelease: Bool? {
        guard let measured = executableSHA256, let release, let build = release.build,
              let recorded = build.executableSHA256 else { return nil }
        if let stampAtBuild = build.releaseStampSHA256, stampAtBuild != release.stampSHA256 { return false }
        return measured.lowercased() == recorded.lowercased()
    }

    /// Whether the configured revision claim names the stamped commit (nil when either is absent).
    var claimedRevisionMatchesRelease: Bool? {
        guard let claimed = claimedSourceRevision, let commit = release?.gitCommit else { return nil }
        return claimed.lowercased() == commit.lowercased()
    }

    // MARK: - Measuring

    /// Measure this process. `executablePath` and `stampSearchStart` exist for tests; production passes
    /// neither and gets `/proc/self/exe` (Linux) or the resolved main executable (macOS).
    static func measure(environment: [String: String], executablePath: String? = nil,
                        stampSearchStart: String? = nil) -> RuntimeIdentity {
        var errors: [String] = []
        let claimed = environment["FRWHOOP_SOURCE_REVISION"].flatMap { $0.isEmpty ? nil : $0 }

        let (hashPath, displayPath) = executablePath.map { ($0, $0) } ?? currentExecutable()
        var executableSHA: String?
        if let hashPath {
            do {
                executableSHA = try fileSHA256(hashPath)
            } catch {
                errors.append("executable \(hashPath): \(error)")
            }
        } else {
            errors.append("executable: no path for the running executable")
        }

        var release: Release?
        let explicitStamp = environment[stampEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 }
        let searchStart = stampSearchStart
            ?? displayPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        if let stampPath = explicitStamp ?? searchStart.flatMap(findStamp(from:)) {
            do {
                release = try readRelease(stampPath: stampPath, errors: &errors)
            } catch {
                errors.append("release stamp \(stampPath): \(error)")
            }
        }
        return RuntimeIdentity(claimedSourceRevision: claimed, executablePath: displayPath,
                               executableSHA256: executableSHA, release: release, measuredAt: Date(),
                               errors: errors)
    }

    /// (path to hash, path to report). On Linux `/proc/self/exe` opens the running image itself.
    private static func currentExecutable() -> (String?, String?) {
        #if os(Linux)
        let link = "/proc/self/exe"
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link)
        return (link, target ?? link)
        #else
        let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments.first
        return (path, path)
        #endif
    }

    /// The nearest `RELEASE.json` at most `stampSearchDepth` levels above `start`.
    static func findStamp(from start: String) -> String? {
        var directory = URL(fileURLWithPath: start).resolvingSymlinksInPath()
        for _ in 0...stampSearchDepth {
            let candidate = directory.appendingPathComponent(stampName).path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private static func readRelease(stampPath: String, errors: inout [String]) throws -> Release {
        let data = try Data(contentsOf: URL(fileURLWithPath: stampPath))
        guard let stamp = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IdentityError("not a JSON object")
        }
        var build: Build?
        let buildPath = URL(fileURLWithPath: stampPath).deletingLastPathComponent()
            .appendingPathComponent(buildName).path
        if FileManager.default.fileExists(atPath: buildPath) {
            do {
                let record = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: buildPath)))
                guard let record = record as? [String: Any] else { throw IdentityError("not a JSON object") }
                let executables = record["executables"] as? [String: Any]
                let executable = executables?[executableName] as? [String: Any]
                build = Build(path: buildPath,
                              executableSHA256: executable?["sha256"] as? String,
                              releaseStampSHA256: record["release_stamp_sha256"] as? String,
                              builtAt: record["built_at_utc"] as? String,
                              swiftVersion: record["swift_version"] as? String,
                              platform: record["platform"] as? String,
                              tests: (record["tests"] as? [String: Any])?["status"] as? String)
            } catch {
                errors.append("build record \(buildPath): \(error)")
            }
        }
        let files = stamp["files"] as? [String: Any]
        return Release(stampPath: stampPath, stampSHA256: sha256Hex(data),
                       releaseID: stamp["release_id"] as? String,
                       gitCommit: stamp["git_commit"] as? String,
                       gitTree: stamp["git_tree"] as? String,
                       dirty: stamp["dirty"] as? Bool,
                       createdAt: stamp["created_at_utc"] as? String,
                       packageResolvedSHA256: stamp["package_resolved_sha256"] as? String,
                       filesSHA256: files?["sha256"] as? String,
                       build: build)
    }

    /// sha256 of a file, read through a memory map so a large executable is never copied into memory.
    static func fileSHA256(_ path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            _ = SHA256(pointer.baseAddress, pointer.count, &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    struct IdentityError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Reporting

    /// The heartbeat's `meta.identity` (JSONSerialization-ready).
    var wire: [String: Any] {
        func value(_ v: Any?) -> Any { v ?? NSNull() }
        var out: [String: Any] = [
            "schema": Self.schema,
            "claimed_source_revision": value(claimedSourceRevision),
            "executable": ["path": value(executablePath), "sha256": value(executableSHA256)],
            "release": value(release.map { release -> [String: Any] in
                [
                    "stamp_path": release.stampPath,
                    "stamp_sha256": release.stampSHA256,
                    "release_id": value(release.releaseID),
                    "git_commit": value(release.gitCommit),
                    "git_tree": value(release.gitTree),
                    "dirty": value(release.dirty),
                    "created_at_utc": value(release.createdAt),
                    "package_resolved_sha256": value(release.packageResolvedSHA256),
                    "files_sha256": value(release.filesSHA256),
                    "build": value(release.build.map { build -> [String: Any] in
                        [
                            "path": build.path,
                            "executable_sha256": value(build.executableSHA256),
                            "release_stamp_sha256": value(build.releaseStampSHA256),
                            "built_at_utc": value(build.builtAt),
                            "swift_version": value(build.swiftVersion),
                            "platform": value(build.platform),
                            "tests": value(build.tests),
                        ]
                    }),
                ]
            }),
            "matches_release": value(matchesRelease),
            "claimed_revision_matches_release": value(claimedRevisionMatchesRelease),
            "measured_at": ISO8601DateFormatter().string(from: measuredAt),
        ]
        if !errors.isEmpty { out["error"] = String(errors.joined(separator: "; ").prefix(1000)) }
        return out
    }

    func jsonText() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"schema\":\"\(Self.schema)\",\"error\":\"identity encoding failed\"}"
        }
        return text
    }
}
