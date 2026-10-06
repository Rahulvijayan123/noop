import XCTest
import StrandAnalytics
@testable import frwhoop_worker

/// The Inertia-1 stage of the activity lane against stub services (no torch, no model, no database):
/// configuration, failure isolation, and that the HART output is byte-identical whatever Inertia does.
/// The SQL side is `supabase/functions/tests/activity_motion_heads_contract.sql`; the two together are
/// `ActivityMotionHeadsDatabaseTests`.
final class ActivityInertiaStageTests: XCTestCase {

    private let dayStart = 1_789_430_400          // 2026-09-15 00:00:00 UTC
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"
    private var services: [ActivityPythonService] = []

    override func tearDown() {
        for s in services { s.shutdown() }
        services = []
        super.tearDown()
    }

    private func stub(_ name: String) -> String? {
        for c in ["Tests/frwhoop-workerTests/\(name)", "../../Tests/frwhoop-workerTests/\(name)"]
        where FileManager.default.fileExists(atPath: c) { return c }
        return nil
    }

    private func hartService() throws -> ActivityPythonService {
        guard let path = stub("stub_activity_service.py") else { throw XCTSkip("stub_activity_service.py not found") }
        let s = ActivityPythonService(config: ActivityPythonService.Config(
            pythonBin: "/usr/bin/python3", activityHome: FileManager.default.currentDirectoryPath, modelDir: nil,
            serveArgs: [path], requestTimeoutSeconds: 5, maxRequestBytes: 64 * 1024 * 1024,
            maxResponseLineBytes: 16 * 1024 * 1024, restartCap: 8, restartCooldownSeconds: 30))
        services.append(s)
        return s
    }

    private func inertia(_ behaviour: String = "ok", kind: String = "standin", tier: String = "shadow",
                         mode: InertiaSettings.Mode = .shadow, timeout: Double = 5) throws -> InertiaStage {
        guard let path = stub("stub_inertia_service.py") else { throw XCTSkip("stub_inertia_service.py not found") }
        var settings = InertiaSettings.fromEnvironment([
            "FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/opt/bundle",
            "FRWHOOP_INERTIA_TIMEOUT_SECONDS": String(timeout)], activityPython: "/usr/bin/python3")
        settings.mode = mode
        var config = try XCTUnwrap(settings.serviceConfig(activityHome: FileManager.default.currentDirectoryPath))
        config.serveArgs = [path, "--behaviour", behaviour, "--kind", kind, "--tier", tier, "--sleep", "30"]
        let s = ActivityPythonService(config: config)
        services.append(s)
        return InertiaStage(service: s, mode: mode)
    }

    /// Three 2-minute chunks inside the day (column payloads are not inspected by the stubs).
    private func requests() -> [ActivityPythonService.RunRequest] {
        let t0 = dayStart + 36_000
        let column = Data(repeating: 0, count: 1200).base64EncodedString()
        return (0..<3).map { i in
            ActivityPythonService.RunRequest(startTs: t0 + i * 120, endTs: t0 + (i + 1) * 120,
                                             columnsB64: Array(repeating: column, count: 120), headB64: [], tailB64: [])
        }
    }

    private func infer(_ inertia: InertiaStage?, stats: inout ActivityLane.Stats) throws -> ActivityLane.ChunkInference {
        try ActivityLane.inferChunks(requests(), service: try hartService(), inertia: inertia,
                                     versions: (ActivityLane.baselineModelVersion, ActivityLane.baselinePreprocessingVersion),
                                     stats: &stats, renew: { true })
    }

    private func daySim() -> DaySim {
        var sim = DaySim(start: dayStart + 36_000)
        sim.still(120); sim.walk(120); sim.still(120)
        return sim
    }

    /// Everything the lane publishes for the HART path, built from one inference.
    private func hartPayloads(_ inferred: ActivityLane.ChunkInference) throws -> (v1: String, v2: String) {
        var doc = try ActivityLane.activityDocument(
            windows: inferred.windows, sleepIntervals: [], exerciseIntervals: [], dayStart: dayStart, dayEnd: dayEnd,
            inputRevision: 3, modelVersion: inferred.versions.model, preprocessingVersion: inferred.versions.preprocessing,
            dataThrough: dayStart + 36_360)
        let v1 = try ActivityLane.dayStampedJSONText(doc: &doc, day: day)
        let input = ActivityContextDays.trackInput(
            windows: inferred.windows, streams: daySim().streams, sleep: [], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, encoderVersion: inferred.versions.model)
        let v2 = try ActivityContextDays.build(input: input, day: day, modelVersion: inferred.versions.model,
                                               preprocessingVersion: inferred.versions.preprocessing,
                                               generatedAt: 1_789_500_000).payloadText
        return (v1, v2)
    }

    private func baseline() throws -> (v1: String, v2: String) {
        var stats = ActivityLane.Stats()
        return try hartPayloads(try infer(nil, stats: &stats))
    }

    private func contextInput() -> ActivityContextTrackInput {
        let sim = daySim()
        return ActivityContextDays.trackInput(windows: sim.windows, streams: sim.streams, sleep: [], exercise: [],
                                              dayStart: dayStart, dayEnd: dayEnd, encoderVersion: "stub-model")
    }

    private func payloadObject(_ text: String?) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(text).utf8)) as? [String: Any])
    }

    // MARK: - Configuration

    func testInertiaIsOffUnlessEnabledWithABundle() {
        XCTAssertFalse(InertiaSettings.fromEnvironment([:]).enabled)
        XCTAssertNil(InertiaSettings.fromEnvironment([:]).serviceConfig(activityHome: "/x"))
        let noBundle = InertiaSettings.fromEnvironment(["FRWHOOP_INERTIA_ENABLED": "1"])
        XCTAssertFalse(noBundle.enabled)
        XCTAssertEqual(noBundle.configurationError, "FRWHOOP_INERTIA_BUNDLE_DIR is required")
        let badMode = InertiaSettings.fromEnvironment(["FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/b",
                                                       "FRWHOOP_INERTIA_MODE": "production"])
        XCTAssertFalse(badMode.enabled, "production evidence needs a code and config change, not an env flag")
        XCTAssertNotNil(badMode.configurationError)
        let on = InertiaSettings.fromEnvironment(["FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/b"],
                                                 activityPython: "/usr/bin/python3")
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.mode, .shadow, "shadow is the default")
        XCTAssertEqual(on.python, "/usr/bin/python3")
        XCTAssertEqual(on.timeoutSeconds, 60)
    }

    func testTheInertiaChildIsItsOwnProcessWithTheCheckpointPassedBothWays() throws {
        let s = InertiaSettings.fromEnvironment([
            "FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_MODE": "candidate",
            "FRWHOOP_INERTIA_BUNDLE_DIR": "/opt/inertia/bundle", "FRWHOOP_INERTIA_CHECKPOINT": "/opt/inertia/enc.ckpt",
            "FRWHOOP_INERTIA_PYTHON": "/opt/venv/bin/python", "FRWHOOP_INERTIA_TIMEOUT_SECONDS": "45"])
        XCTAssertEqual(s.mode, .candidate)
        let c = try XCTUnwrap(s.serviceConfig(activityHome: "/srv/Tools/ActivityContext"))
        XCTAssertEqual(c.serveArgs, ["-m", "activity_context.inertia.serve", "--bundle", "/opt/inertia/bundle",
                                     "--checkpoint", "/opt/inertia/enc.ckpt"])
        XCTAssertEqual(c.extraEnvironment["INERTIA1_CKPT_PATH"], "/opt/inertia/enc.ckpt")
        XCTAssertEqual(c.pythonBin, "/opt/venv/bin/python")
        XCTAssertEqual(c.requestTimeoutSeconds, 45)
        XCTAssertTrue(c.keepsRawLines)
        XCTAssertLessThanOrEqual(c.maxResponseLineBytes, 16 * 1024 * 1024)
        XCTAssertEqual(InertiaSettings.serveArgs(bundleDir: "/b", checkpoint: nil),
                       ["-m", "activity_context.inertia.serve", "--bundle", "/b"])
        // The HART child's config is untouched by any of this.
        XCTAssertFalse(ActivityPythonService.Config.fromEnvironment([:]).keepsRawLines)
        XCTAssertTrue(ActivityPythonService.Config.fromEnvironment([:]).extraEnvironment.isEmpty)
    }

    // MARK: - Ping parsing (the HART readiness fix)

    func testHartUnavailableWithOkTrueIsNotAvailable() {
        // What the real activity_context.serve answers when the HART manifest's checkpoint does not load.
        let real: [String: Any] = ["id": "x", "ok": true, "model_status": "hart_unavailable",
                                   "model_error": "FileNotFoundError: /opt/hart", "model_version": "hart-activity-1",
                                   "preprocessing_version": "1.0.0"]
        let ping = ActivityPythonService.parsePing(real)
        XCTAssertTrue(ping.ok)
        XCTAssertFalse(ping.modelAvailable, "a model that did not load must not let the lane claim jobs")
        XCTAssertEqual(ping.modelStatus, "hart_unavailable")
        XCTAssertEqual(ping.error, "FileNotFoundError: /opt/hart")

        XCTAssertTrue(ActivityPythonService.parsePing(["ok": true, "model_status": "hart_loaded"]).modelAvailable)
        XCTAssertTrue(ActivityPythonService.parsePing(["ok": true, "model_status": "baseline"]).modelAvailable)
        XCTAssertTrue(ActivityPythonService.parsePing(["ok": true, "model_status": "loaded"]).modelAvailable)
        XCTAssertFalse(ActivityPythonService.parsePing(["ok": true, "model_available": false]).modelAvailable)
        XCTAssertFalse(ActivityPythonService.parsePing(["ok": true, "model_status": "inertia_unavailable",
                                                        "model_available": false]).modelAvailable)
        // Neither signal can override the other into "available".
        XCTAssertFalse(ActivityPythonService.parsePing(["ok": true, "model_status": "hart_unavailable",
                                                        "model_available": true]).modelAvailable)
        XCTAssertFalse(ActivityPythonService.parsePing(["ok": false, "model_status": "hart_loaded"]).modelAvailable)
        let inertiaPing = ActivityPythonService.parsePing(["ok": true, "model_available": true, "model_status": "standin_shadow",
                                                           "encoder_kind": "standin", "evidence_tier_max": "shadow"])
        XCTAssertTrue(inertiaPing.modelAvailable)
        XCTAssertEqual(inertiaPing.details["encoder_kind"], "standin")
    }

    func testAHartChildReportingHartUnavailableIsNotReady() throws {
        guard let path = stub("stub_activity_service.py") else { throw XCTSkip("stub_activity_service.py not found") }
        let s = ActivityPythonService(config: ActivityPythonService.Config(
            pythonBin: "/usr/bin/python3", activityHome: FileManager.default.currentDirectoryPath, modelDir: nil,
            serveArgs: [path, "--ping-status", "hart_unavailable"], requestTimeoutSeconds: 5,
            maxRequestBytes: 1 << 20, maxResponseLineBytes: 1 << 20, restartCap: 2, restartCooldownSeconds: 1))
        services.append(s)
        let ping = try s.ping()
        XCTAssertTrue(ping.ok)
        XCTAssertFalse(ping.modelAvailable)
        XCTAssertFalse(s.modelAvailable, "ensureServiceReady throws on this, so the lane does not claim")
    }

    // MARK: - Failure isolation

    func testInertiaDisabledLeavesTheLaneAsItWas() throws {
        var stats = ActivityLane.Stats()
        let inferred = try infer(nil, stats: &stats)
        XCTAssertEqual(inferred.windows.count, 3)
        XCTAssertTrue(inferred.motionHeads.isEmpty)
        XCTAssertEqual(stats.inertiaJobs, 0)
        XCTAssertEqual(stats.inertiaChunks, 0)
        XCTAssertNil(stats.lastInertiaError)
    }

    private func assertIsolated(_ behaviour: String, kind expectedKind: String, chunks: Int, failed: Int,
                                unavailable: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws {
        let reference = try baseline()
        var stats = ActivityLane.Stats()
        let started = Date()
        let inferred = try infer(try inertia(behaviour, timeout: 1), stats: &stats)
        let payloads = try hartPayloads(inferred)
        XCTAssertEqual(payloads.v1, reference.v1, "\(behaviour): v1 payload", file: file, line: line)
        XCTAssertEqual(payloads.v2, reference.v2, "\(behaviour): v2 payload", file: file, line: line)
        XCTAssertEqual(stats.windowsInferred, 3, file: file, line: line)
        XCTAssertEqual(inferred.motionHeads.chunks, chunks, "\(behaviour): chunks asked", file: file, line: line)
        XCTAssertEqual(inferred.motionHeads.failedChunks, failed, file: file, line: line)
        XCTAssertEqual(stats.inertiaFailures, failed, file: file, line: line)
        XCTAssertEqual(stats.inertiaUnavailable, unavailable, file: file, line: line)
        XCTAssertEqual(stats.lastInertiaErrorKind, expectedKind, stats.lastInertiaError ?? "", file: file, line: line)
        XCTAssertNotNil(stats.lastInertiaError, file: file, line: line)
        XCTAssertNil(stats.lastError, "the HART path saw no error", file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "\(behaviour): at most one timeout per job",
                          file: file, line: line)
    }

    func testAMissingInertiaModelNeverTouchesTheHartJob() throws {
        try assertIsolated("model_missing", kind: "model_unavailable", chunks: 0, failed: 0, unavailable: 1)
    }

    func testAnInertiaTimeoutCostsOneChunkAndIsCounted() throws {
        try assertIsolated("timeout", kind: "timeout", chunks: 1, failed: 1)
    }

    func testAnInertiaCrashIsCountedAndStopsInertiaForTheJob() throws {
        try assertIsolated("crash", kind: "crash", chunks: 1, failed: 1)
    }

    func testMalformedInertiaOutputIsRefusedChunkByChunk() throws {
        try assertIsolated("malformed", kind: "malformed", chunks: 3, failed: 3)
        try assertIsolated("schema", kind: "schema", chunks: 3, failed: 3)
    }

    func testNaNAndInvalidProbabilitiesAreRefused() throws {
        // A NaN token makes the line unparseable; it names the request, so it fails at once, not at the timeout.
        try assertIsolated("nan", kind: "malformed_json", chunks: 3, failed: 3)
        try assertIsolated("bad_sum", kind: "invalid_probabilities", chunks: 3, failed: 3)
    }

    func testACrashAfterAGoodChunkKeepsTheGoodChunk() throws {
        var stats = ActivityLane.Stats()
        let inferred = try infer(try inertia("ok_then_crash"), stats: &stats)
        XCTAssertEqual(inferred.motionHeads.responses.count, 1)
        XCTAssertEqual(inferred.motionHeads.stopped, "crash")
        XCTAssertEqual(inferred.motionHeads.chunks, 2)
        XCTAssertEqual(stats.inertiaFailures, 1)
        XCTAssertEqual(try hartPayloads(inferred).v1, try baseline().v1)
    }

    // MARK: - Shadow and candidate output

    func testShadowModeStoresCompactHeadsAndLeavesTheHartPayloadsByteIdentical() throws {
        let reference = try baseline()
        var stats = ActivityLane.Stats()
        let inferred = try infer(try inertia("ok"), stats: &stats)
        let payloads = try hartPayloads(inferred)
        XCTAssertEqual(payloads.v1, reference.v1)
        XCTAssertEqual(payloads.v2, reference.v2)
        XCTAssertEqual(inferred.motionHeads.responses.count, 3)
        XCTAssertEqual(stats.inertiaChunks, 3)
        XCTAssertEqual(stats.inertiaFailures, 0)
        let heads = try XCTUnwrap(inferred.motionHeads.trackInput)
        XCTAssertEqual(heads.windows.count, 3 * 19, "30-s windows on a 5-s grid inside each 120-s chunk")
        XCTAssertEqual(stats.inertiaWindows, heads.windows.count)

        let candidate = ActivityMotionHeadsDays.candidate(mode: .shadow, heads: heads, input: contextInput(),
                                                         generatedAt: 1_789_500_000)
        let text = try ActivityMotionHeadsDays.payload(day: day, mode: .shadow, collector: inferred.motionHeads,
                                                      candidate: candidate)
        let p = try payloadObject(text)
        XCTAssertEqual(p["day"] as? String, day)
        XCTAssertEqual(p["mode"] as? String, "shadow")
        XCTAssertEqual(p["schema"] as? String, "motion-heads-1")
        XCTAssertTrue(p["candidate_document"] is NSNull)
        XCTAssertTrue(p["withheld_reason"] is NSNull)
        let bundle = try XCTUnwrap(p["bundle"] as? [String: Any])
        XCTAssertEqual(bundle["encoder_kind"] as? String, "standin")
        XCTAssertEqual(bundle["heads_version"] as? String, "stub-bundle-1")
        let summary = try XCTUnwrap(p["summary"] as? [String: Any])
        XCTAssertEqual(summary["n_windows"] as? Int, heads.windows.count)
        XCTAssertEqual(summary["n_ood"] as? Int, heads.windows.filter(\.isOOD).count)
        XCTAssertGreaterThan(summary["n_ood"] as? Int ?? 0, 0)
        XCTAssertEqual(summary["n_chunks"] as? Int, 3)
        XCTAssertEqual((summary["class_order"] as? [String: [String]])?["posture"], MotionHead.posture.classOrder)
        let windows = try XCTUnwrap(p["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, heads.windows.count)
        XCTAssertEqual((windows[0]["p"] as? [Double])?.count, 4)
        XCTAssertEqual((windows[0]["l"] as? [Double])?.count, 8)
        XCTAssertNotNil(windows[0]["x"] as? Bool)
        // Deterministic.
        XCTAssertEqual(text, try ActivityMotionHeadsDays.payload(day: day, mode: .shadow, collector: inferred.motionHeads,
                                                                candidate: candidate))
    }

    func testCandidateModeWithAStandInIsWithheld() throws {
        var stats = ActivityLane.Stats()
        let inferred = try infer(try inertia("ok", kind: "standin", tier: "shadow", mode: .candidate), stats: &stats)
        let heads = try XCTUnwrap(inferred.motionHeads.trackInput)
        let candidate = ActivityMotionHeadsDays.candidate(mode: .candidate, heads: heads, input: contextInput(),
                                                         generatedAt: 1_789_500_000)
        guard case .withheld(let why) = candidate else { return XCTFail("expected withheld, got \(candidate)") }
        XCTAssertEqual(why, "encoder_kind_standin")
        let p = try payloadObject(try ActivityMotionHeadsDays.payload(day: day, mode: .candidate,
                                                                     collector: inferred.motionHeads, candidate: candidate))
        XCTAssertEqual(p["withheld_reason"] as? String, "encoder_kind_standin")
        XCTAssertTrue(p["candidate_document"] is NSNull)
        // A real encoder whose bundle is shadow-tier is withheld too.
        var tierStats = ActivityLane.Stats()
        let shadowTier = try infer(try inertia("ok", kind: "inertia1", tier: "shadow", mode: .candidate), stats: &tierStats)
        let c2 = ActivityMotionHeadsDays.candidate(mode: .candidate, heads: try XCTUnwrap(shadowTier.motionHeads.trackInput),
                                                  input: contextInput(), generatedAt: 1_789_500_000)
        guard case .withheld(let why2) = c2 else { return XCTFail("expected withheld, got \(c2)") }
        XCTAssertEqual(why2, "evidence_tier_shadow")
    }

    func testCandidateModeWithARealEncoderStoresTheComparisonBesideAnUnchangedPublication() throws {
        let reference = try baseline()
        var stats = ActivityLane.Stats()
        let inferred = try infer(try inertia("ok", kind: "inertia1", tier: "candidate", mode: .candidate), stats: &stats)
        let payloads = try hartPayloads(inferred)
        XCTAssertEqual(payloads.v1, reference.v1)
        XCTAssertEqual(payloads.v2, reference.v2, "the published v2 document never sees Inertia")
        let heads = try XCTUnwrap(inferred.motionHeads.trackInput)
        let input = contextInput()
        let candidate = ActivityMotionHeadsDays.candidate(mode: .candidate, heads: heads, input: input,
                                                         generatedAt: 1_789_500_000)
        guard case .document(let doc) = candidate else { return XCTFail("expected a document, got \(candidate)") }
        let stamp = try XCTUnwrap(doc.versions.motionHeads)
        XCTAssertTrue(stamp.hasPrefix("inertia-1:abababababab:"), stamp)
        XCTAssertNil(doc.snapshot)
        let published = ActivityContextDays.dayDocument(input: input, generatedAt: 1_789_500_000)
        XCTAssertNil(published.versions.motionHeads)
        XCTAssertEqual(doc.observedSeconds, published.observedSeconds, "the same seconds, decoded a second time")
        let p = try payloadObject(try ActivityMotionHeadsDays.payload(day: day, mode: .candidate,
                                                                     collector: inferred.motionHeads, candidate: candidate))
        XCTAssertTrue(p["withheld_reason"] is NSNull)
        let stored = try XCTUnwrap(p["candidate_document"] as? [String: Any])
        XCTAssertEqual((stored["versions"] as? [String: Any])?["motion_heads"] as? String, stamp)
        XCTAssertEqual((p["summary"] as? [String: Any])?["candidate_stamp"] as? String, stamp)
    }

    func testNothingValidMeansNoShadowRow() throws {
        var stats = ActivityLane.Stats()
        let inferred = try infer(try inertia("schema"), stats: &stats)
        XCTAssertNil(inferred.motionHeads.trackInput)
        XCTAssertNil(try ActivityMotionHeadsDays.payload(day: day, mode: .shadow, collector: inferred.motionHeads,
                                                        candidate: .notRequested))
    }
}
