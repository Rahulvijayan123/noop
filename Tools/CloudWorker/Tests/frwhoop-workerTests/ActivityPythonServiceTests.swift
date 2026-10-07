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

    /// serve.py answers ping `ok:true` with `hart_unavailable` when the HART manifest is present but the
    /// model failed to load. That is no model: the lane must not claim jobs it can only fail.
    func testPingTreatsAHartModelThatFailedToLoadAsUnavailable() {
        let failed = ActivityPythonService.parsePing(
            ["ok": true, "model_status": "hart_unavailable", "error": "ModuleNotFoundError: torch"])
        XCTAssertTrue(failed.ok)
        XCTAssertFalse(failed.modelAvailable)
        XCTAssertEqual(failed.modelStatus, "hart_unavailable")
        for status in ["model_missing", "missing"] {
            XCTAssertFalse(ActivityPythonService.parsePing(["ok": true, "model_status": status]).modelAvailable)
        }
        for status in ["hart_loaded", "baseline", "loaded"] {
            XCTAssertTrue(ActivityPythonService.parsePing(["ok": true, "model_status": status]).modelAvailable)
        }
    }

    /// WS-11-F01: a host whose HART checkpoint failed to load answers ping with
    /// model_status "hart_unavailable" while still reporting ok:true. Only the
    /// known-available statuses may pass the guard; every non-loaded status must
    /// fail soft so the lane never claims a job it would dead-letter.
    func testParsePingModelStatusTruthTable() {
        func status(_ modelStatus: String?, ok: Bool = true) -> ActivityPythonService.PingStatus {
            var obj: [String: Any] = ["ok": ok]
            if let modelStatus { obj["model_status"] = modelStatus }
            return ActivityPythonService.parsePing(obj)
        }
        for unavailable in ["hart_unavailable", "model_missing", "missing"] {
            XCTAssertFalse(status(unavailable).modelAvailable, "\(unavailable) must be unavailable")
            XCTAssertEqual(status(unavailable).modelStatus, unavailable)
        }
        XCTAssertFalse(status(nil, ok: false).modelAvailable,
                       "an exchange that did not succeed is never model-available")
        for loaded in ["baseline", "hart_loaded", "loaded"] {
            XCTAssertTrue(status(loaded).modelAvailable, "\(loaded) must be available")
            XCTAssertEqual(status(loaded).modelStatus, loaded)
        }
        // An explicit model_available flag still wins (an older serve.py sends it).
        XCTAssertTrue(ActivityPythonService.parsePing(["ok": true, "model_available": true]).modelAvailable)
        XCTAssertFalse(ActivityPythonService.parsePing(["ok": true, "model_available": false]).modelAvailable)
    }

    /// A01/WS-01-F03: serve.py now reports its calibration claim (`calibrated` /
    /// `calibration_version` from the manifest artifact). The worker must carry it,
    /// and an older serve.py that never sends it must read as nil, never as
    /// calibrated.
    func testParsePingCarriesCalibrationClaim() {
        let ping = ActivityPythonService.parsePing([
            "ok": true, "model_status": "hart_loaded",
            "calibrated": true, "calibration_version": "cal-1",
        ])
        XCTAssertEqual(ping.calibrated, true)
        XCTAssertEqual(ping.calibrationVersion, "cal-1")

        let legacy = ActivityPythonService.parsePing(["ok": true, "model_status": "hart_loaded"])
        XCTAssertNil(legacy.calibrated, "absence must not read as calibrated")
        XCTAssertNil(legacy.calibrationVersion)
    }

    /// The per-window `calibrated` flag from serve.py reaches the parsed window.
    func testInferParsesPerWindowCalibratedFlag() throws {
        service = try makeService()
        _ = try service.ping()
        var request = emptyRun()
        request.extra = ["win_calibrated": true]
        let calibrated = try XCTUnwrap(try service.infer(run: request).windows.first)
        XCTAssertTrue(calibrated.calibrated)

        let plain = try XCTUnwrap(try service.infer(run: emptyRun()).windows.first)
        XCTAssertFalse(plain.calibrated, "the model-less stub is never calibrated by default")
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

    /// The per-window `imu-feat-2` facts and the schema stamp come through the parse.
    func testInferParsesPerWindowImuFeaturesAndSchema() throws {
        service = try makeService()
        _ = try service.ping()
        let result = try service.infer(run: emptyRun(start: 500, end: 504))
        XCTAssertEqual(result.featureSchema, "imu-feat-2")
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertEqual(window.features["accel_rms_g"] ?? -1, 0.012, accuracy: 1e-12)
        XCTAssertEqual(window.features["gyro_rms_dps"] ?? -1, 3.5, accuracy: 1e-12)
        XCTAssertEqual(window.features["jerk_rms_gps"] ?? -1, 0.04, accuracy: 1e-12)
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

    /// The optional transition-expert evidence parses per window (five classes, refined ts).
    func testInferParsesPerWindowTransitionEvidence() throws {
        service = try makeService()
        _ = try service.ping()
        var request = emptyRun()
        request.extra = ["transition": "plain"]
        let result = try service.infer(run: request)
        XCTAssertEqual(result.transitionSchema, "transition-1")
        XCTAssertEqual(result.transitionVersion, "stub-transition")
        XCTAssertEqual(service.reportedTransitionVersion, "stub-transition")
        let window = try XCTUnwrap(result.windows.first)
        let transition = try XCTUnwrap(window.transition)
        XCTAssertEqual(transition.probs["none"] ?? -1, 0.22, accuracy: 1e-12)
        XCTAssertEqual(transition.probs["sit_to_stand"] ?? -1, 0.61, accuracy: 1e-12)
        XCTAssertEqual(transition.probs["get_up"] ?? -1, 0.03, accuracy: 1e-12)
        XCTAssertEqual(transition.label, "sit_to_stand")
        XCTAssertFalse(transition.abstained)
        XCTAssertEqual(transition.ts ?? -1, Double(emptyRun().startTs) + 1.77, accuracy: 1e-9)
        // the general window fields are untouched by the transition evidence
        XCTAssertEqual(window.label, "stationary")
        XCTAssertFalse(window.baseline)
    }

    /// HART's fine distribution parses per window and ElderNet's gait windows parse from the response,
    /// a malformed gait window (zero length) is dropped, and the gait version keys the cache.
    func testInferParsesHartFineAndElderNetGaitWindows() throws {
        service = try makeService()
        _ = try service.ping()
        var request = emptyRun()
        request.extra = ["experts": true]
        let result = try service.infer(run: request)
        XCTAssertEqual(result.fineSchema, "wisdm-act-1")
        let fine = try XCTUnwrap(result.windows.first?.fine)
        XCTAssertEqual(fine["sitting"] ?? -1, 0.7, accuracy: 1e-12)
        XCTAssertEqual(fine.count, 3)
        XCTAssertEqual(result.gaitSchema, "gait-quality-1")
        XCTAssertEqual(result.gaitStatus, "gait_loaded")
        XCTAssertEqual(service.reportedGaitVersion, "stub-eldernet")
        XCTAssertEqual(result.gaitWindows.count, 2)
        let g0 = result.gaitWindows[0], g1 = result.gaitWindows[1]
        XCTAssertEqual(g0.startTs, Int(emptyRun().startTs))
        XCTAssertEqual(g0.endTs - g0.startTs, 10)
        XCTAssertTrue(g0.isGait)
        XCTAssertEqual(g0.cadenceSpm ?? -1, 108.5, accuracy: 1e-12)
        XCTAssertEqual(g0.speedMps ?? -1, 1.21, accuracy: 1e-12)
        XCTAssertEqual(g0.modelVersion, "stub-eldernet")
        XCTAssertFalse(g1.isGait)
        XCTAssertTrue(g1.prefiltered)
        XCTAssertNil(g1.cadenceSpm)
        // The general window fields are untouched.
        XCTAssertEqual(result.windows.first?.label, "stationary")
    }

    /// Without the experts the response carries neither, exactly as before.
    func testInferWithoutExpertsCarriesNoFineOrGait() throws {
        service = try makeService()
        _ = try service.ping()
        let result = try service.infer(run: emptyRun())
        XCTAssertNil(result.fineSchema)
        XCTAssertNil(result.windows.first?.fine)
        XCTAssertTrue(result.gaitWindows.isEmpty)
        XCTAssertNil(service.reportedGaitVersion)
    }

    /// An older serve.py (or an unloaded expert) sends no `transition`; every window is unchanged.
    func testInferAgainstAnOlderServiceWithoutTransitions() throws {
        service = try makeService()
        _ = try service.ping()
        let result = try service.infer(run: emptyRun())
        XCTAssertNil(result.transitionSchema)
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertNil(window.transition)
        XCTAssertEqual(window.label, "stationary")
    }

    /// A JSON-null or malformed `transition` object is dropped, never fatal (fail-open).
    func testMalformedTransitionEvidenceIsDroppedNotFatal() throws {
        service = try makeService()
        _ = try service.ping()
        for knob in ["null", "bad"] {
            var request = emptyRun()
            request.extra = ["transition": knob]
            let result = try service.infer(run: request)
            XCTAssertTrue(result.ok)
            let window = try XCTUnwrap(result.windows.first)
            XCTAssertNil(window.transition, "knob \(knob)")
            XCTAssertEqual(window.label, "stationary")
        }
    }

    /// Ping carries the transition expert's version when one is loaded (absent -> nil, never an error).
    func testPingReportsTransitionVersion() throws {
        service = try makeService()
        let status = try service.ping()
        XCTAssertEqual(status.transitionVersion, "stub-transition")
        XCTAssertEqual(service.reportedTransitionVersion, "stub-transition")
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
