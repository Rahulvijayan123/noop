import XCTest
@testable import frwhoop_worker

/// Protocol + lifecycle tests for `ActivityPythonService` against a stub
/// Python echo service (no torch, no model). Pins the C10 serve protocol
/// request/response shapes, the per-request timeout kill/restart, and restart
/// after a crash. The real-model test runs at integration
/// (Tools/ActivityContext serve.py).
final class ActivityPythonServiceTests: XCTestCase {

    private var service: ActivityPythonService!

    private func makeService(timeout: Double = 2.0, restartCap: Int = 8,
                             cooldown: Double = 30) throws -> ActivityPythonService {
        guard let stub = stubPath() else {
            throw XCTSkip("stub_activity_service.py not found")
        }
        let config = ActivityPythonService.Config(
            pythonBin: "/usr/bin/python3",
            activityHome: FileManager.default.currentDirectoryPath,
            modelDir: nil,
            serveArgs: [stub],
            requestTimeoutSeconds: timeout,
            maxRequestBytes: 64 * 1024 * 1024,
            maxResponseLineBytes: 16 * 1024 * 1024,
            restartCap: restartCap,
            restartCooldownSeconds: cooldown)
        return ActivityPythonService(config: config)
    }

    override func tearDown() {
        service?.shutdown()
        service = nil
        super.tearDown()
    }

    private func stubPath() -> String? {
        let candidates = [
            "Tests/frwhoop-workerTests/stub_activity_service.py",
            "../../Tests/frwhoop-workerTests/stub_activity_service.py",
            "Tests/frwhoop-workerTests/stub_activity_service.py",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        return nil
    }

    private func emptyRun(start: Int = 100, end: Int = 104) -> ActivityPythonService.RunRequest {
        ActivityPythonService.RunRequest(
            startTs: start, endTs: end, columnsB64: [], headB64: [], tailB64: [])
    }

    // MARK: - Protocol

    func testPingReportsLoadedModel() throws {
        service = try makeService()
        let ping = try service.ping()
        XCTAssertTrue(ping.ok)
        XCTAssertTrue(ping.modelAvailable)
        XCTAssertEqual(ping.modelStatus, "loaded")
        XCTAssertEqual(ping.modelVersion, "stub-model")
        XCTAssertEqual(ping.preprocessingVersion, "stub-preprocess")
        XCTAssertTrue(service.modelAvailable)
    }

    func testInferRequestShapeAndResponseParsing() throws {
        service = try makeService()
        _ = try service.ping()

        let request = ActivityPythonService.RunRequest(
            startTs: 1_758_000_000, endTs: 1_758_000_003,
            columnsB64: [Data(repeating: 0, count: 1200).base64EncodedString(),
                         Data(repeating: 0, count: 1200).base64EncodedString(),
                         Data(repeating: 0, count: 1200).base64EncodedString()],
            headB64: ["head"], tailB64: ["t1", "t2"])
        let result = try service.infer(run: request)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.modelVersion, "stub-model")
        XCTAssertEqual(result.preprocessingVersion, "stub-preprocess")
        XCTAssertEqual(result.windows.count, 1)
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertEqual(window.start, 1_758_000_000)
        XCTAssertEqual(window.end, 1_758_000_004)
        XCTAssertEqual(window.label, "stationary")
        XCTAssertEqual(window.probs["stationary"] ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertFalse(window.baseline)
        XCTAssertEqual(service.reportedModelVersion, "stub-model")
        XCTAssertEqual(service.reportedPreprocessingVersion, "stub-preprocess")
    }

    func testInferModelMissingIsReportedAndRemembersModelState() throws {
        service = try makeService()
        _ = try service.ping()
        var request = emptyRun()
        request.extra = ["respond_ok": false]
        let result = try service.infer(run: request)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.errorKind, "model_missing")
        XCTAssertFalse(service.modelAvailable)
    }

    // MARK: - Timeout / restart

    func testTimeoutKillsAndRestarts() throws {
        service = try makeService(timeout: 0.6, cooldown: 30)
        _ = try service.ping()
        XCTAssertEqual(service.restartCountValue, 0, "a healthy ping resets the restart counter")

        // Stub sleeps 3 s; the 0.6 s timeout must win, kill the child and
        // throw. The next call restarts it.
        var request = emptyRun()
        request.extra = ["sleep_seconds": 3]
        XCTAssertThrowsError(try service.infer(run: request)) { error in
            guard let se = error as? ActivityPythonService.ServiceError else {
                return XCTFail("expected ServiceError, got \(error)")
            }
            guard case .timeout = se else {
                return XCTFail("expected timeout, got \(se)")
            }
        }
        // A fresh ping restarts the child and succeeds.
        let ping = try service.ping()
        XCTAssertTrue(ping.ok)
        XCTAssertTrue(service.isRunning)
    }

    func testCrashRestartsAndServesNextRequest() throws {
        service = try makeService()
        _ = try service.ping()

        // The stub exits(2) without a response on `die`.
        var request = emptyRun()
        request.extra = ["die": true]
        XCTAssertThrowsError(try service.infer(run: request)) { error in
            guard let se = error as? ActivityPythonService.ServiceError else {
                return XCTFail("expected ServiceError, got \(error)")
            }
            guard case .processDied = se else {
                return XCTFail("expected processDied, got \(se)")
            }
        }
        // The crashed child is replaced on the next call.
        let ping = try service.ping()
        XCTAssertTrue(ping.ok)
        XCTAssertTrue(service.isRunning)
    }

    func testRestartCapBlocksUntilCooldown() throws {
        service = try makeService(timeout: 0.4, restartCap: 2, cooldown: 0.6)
        _ = try service.ping()  // healthy: restart counter resets to 0

        // Three timeout-crashes force two respawns (each within the cap);
        // the third respawn attempt is blocked by the cap.
        for _ in 0..<3 {
            var request = emptyRun()
            request.extra = ["sleep_seconds": 5]
            _ = try? service.infer(run: request)
        }
        // Immediately after the third crash the cap is exhausted and the
        // cooldown is still running: the next start attempt is refused.
        XCTAssertThrowsError(try service.ping()) { error in
            guard let se = error as? ActivityPythonService.ServiceError else {
                return XCTFail("expected ServiceError, got \(error)")
            }
            guard case .restartCooldown = se else {
                return XCTFail("expected restartCooldown, got \(se)")
            }
        }
        // After the cooldown elapses the cap resets and the service recovers.
        Thread.sleep(forTimeInterval: 0.8)
        let ping = try service.ping()
        XCTAssertTrue(ping.ok)
        XCTAssertTrue(service.isRunning)
    }

    // MARK: - Shutdown

    func testShutdownIsIdempotentAndStopsTheProcess() throws {
        service = try makeService()
        _ = try service.ping()
        XCTAssertTrue(service.isRunning)
        service.shutdown()
        XCTAssertFalse(service.isRunning)
        service.shutdown()  // no crash on double shutdown
    }
}
