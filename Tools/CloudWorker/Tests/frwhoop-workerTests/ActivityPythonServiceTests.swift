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

    // MARK: - Serve argv (HART wiring, audit P1-3)

    /// serve.py reads `--manifest`/`--checkpoint` from argv ONLY (never the
    /// environment), so a model dir that is merely placed in the child's env
    /// boots the BASELINE manifest while the lane stamps 'hart-activity-1' —
    /// the HART model is then unreachable and provenance is wrong. With a
    /// model dir the manifest + checkpoint MUST be part of the launched argv.
    func testServeArgsIncludeManifestAndCheckpointWithModelDir() {
        let args = ActivityPythonService.Config.serveArgs(
            modelDir: "/opt/frwhoop/activity/hart")
        XCTAssertEqual(args, [
            "-m", "activity_context.serve",
            "--manifest", "/opt/frwhoop/activity/hart/manifest.json",
            "--checkpoint", "/opt/frwhoop/activity/hart",
        ])
    }

    /// Without a model dir the child keeps the bare module launch (baseline
    /// manifest); the lane then stamps the versions serve reports for
    /// baseline, never a hard-coded 'hart-activity-1'.
    func testServeArgsStayBaselineWithoutModelDir() {
        XCTAssertEqual(ActivityPythonService.Config.serveArgs(modelDir: nil),
                       ["-m", "activity_context.serve"])
        XCTAssertEqual(ActivityPythonService.Config.serveArgs(modelDir: ""),
                       ["-m", "activity_context.serve"])
    }

    /// fromEnvironment derives the argv from FRWHOOP_ACTIVITY_MODEL_DIR so a
    /// deployed worker cannot accidentally drop the HART args.
    func testFromEnvironmentDerivesServeArgsFromModelDir() {
        let env = ["FRWHOOP_ACTIVITY_MODEL_DIR": "/var/lib/activity/model"]
        let config = ActivityPythonService.Config.fromEnvironment(env)
        XCTAssertEqual(config.modelDir, "/var/lib/activity/model")
        XCTAssertTrue(config.serveArgs.contains("--manifest"))
        XCTAssertTrue(config.serveArgs.contains("/var/lib/activity/model/manifest.json"))
        XCTAssertTrue(config.serveArgs.contains("--checkpoint"))
        XCTAssertTrue(config.serveArgs.contains("/var/lib/activity/model"))

        let noModel = ActivityPythonService.Config.fromEnvironment([:])
        XCTAssertNil(noModel.modelDir)
        XCTAssertEqual(noModel.serveArgs, ["-m", "activity_context.serve"])
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

    /// The real serve.py reads head_b64/tail_b64 from INSIDE `run` (its
    /// original placement), while the C10 contract puts them top-level. A
    /// worker that only sends the top-level copy would silently lose all
    /// boundary filter state. The worker sends BOTH so it is correct against
    /// either serve.py variant.
    func testInferSendsHeadTailBothTopLevelAndInsideRun() throws {
        service = try makeService()
        _ = try service.ping()
        let request = ActivityPythonService.RunRequest(
            startTs: 100, endTs: 103,
            columnsB64: ["a", "b", "c"],
            headB64: ["h1", "h2", "h3"], tailB64: ["t1", "t2"])
        _ = try service.infer(run: request)
        // The stub echoes both placements; assert the worker sent both.
        // (Exposed via a stub-managed last-echo; see stub_activity_service.py.)
        let lastEcho = service.lastEcho
        XCTAssertEqual(lastEcho?["n_head"] as? Int, 3, "top-level head_b64 present")
        XCTAssertEqual(lastEcho?["n_tail"] as? Int, 2, "top-level tail_b64 present")
        XCTAssertEqual(lastEcho?["n_head_run"] as? Int, 3, "run.head_b64 present")
        XCTAssertEqual(lastEcho?["n_tail_run"] as? Int, 2, "run.tail_b64 present")
    }

    // MARK: - IMU features (ActivityContext v2)

    /// The per-window `imu-feat-1` facts and the schema stamp come through the parse.
    func testInferParsesPerWindowImuFeaturesAndSchema() throws {
        service = try makeService()
        _ = try service.ping()
        let result = try service.infer(run: emptyRun(start: 500, end: 504))
        XCTAssertEqual(result.featureSchema, "imu-feat-1")
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertEqual(window.features["accel_rms_g"] ?? -1, 0.012, accuracy: 1e-12)
        XCTAssertEqual(window.features["gyro_rms_dps"] ?? -1, 3.5, accuracy: 1e-12)
        XCTAssertEqual(window.features["jerk_rms"] ?? -1, 0.04, accuracy: 1e-12)
        XCTAssertEqual(window.features["cadence_hz"] ?? -1, 1.8, accuracy: 1e-12)
        XCTAssertEqual(window.features["cadence_strength"] ?? -1, 0.31, accuracy: 1e-12)
        XCTAssertEqual(window.features["orientation_change_deg"] ?? -1, 2.5, accuracy: 1e-12)
    }

    /// JSON null (a feature the window could not compute) leaves the key out instead of reading as zero.
    func testInferLeavesNullFeaturesOut() throws {
        service = try makeService()
        _ = try service.ping()
        var request = emptyRun()
        request.extra = ["feat_nulls": true]
        let window = try XCTUnwrap(try service.infer(run: request).windows.first)
        XCTAssertNil(window.features["cadence_hz"])
        XCTAssertNil(window.features["orientation_change_deg"])
        XCTAssertNotNil(window.features["accel_rms_g"])
        XCTAssertEqual(window.features.count, 4)
    }

    /// An older serve.py has no `feat` or `feature_schema`; the parse still succeeds.
    func testInferAgainstAnOlderServiceWithoutFeatures() throws {
        service = try makeService()
        _ = try service.ping()
        var request = emptyRun()
        request.extra = ["legacy_no_feat": true]
        let result = try service.infer(run: request)
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.featureSchema)
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertTrue(window.features.isEmpty)
        XCTAssertEqual(window.label, "stationary")
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

    /// Starting the service arms a process-wide SIGPIPE ignore. Without it, the one request line that races a
    /// child's exit would kill the worker itself; with it, the write comes back as an error. If the guard is
    /// ever lost, this test ends the test process with signal 13 instead of failing politely.
    func testAWriteToAGoneReaderIsAnErrorNotASignal() throws {
        service = try makeService()
        _ = try service.ping()

        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try pipe.fileHandleForWriting.write(contentsOf: Data("x\n".utf8)))
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
