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

    /// The digest every stub bundle reports unless told otherwise.
    private let stubSha = String(repeating: "ab", count: 32)

    private func inertia(_ behaviour: String = "ok", kind: String = "standin", tier: String = "shadow",
                         mode: InertiaSettings.Mode = .shadow, timeout: Double = 5,
                         pin: String?? = .none, extraArgs: [String] = [],
                         jobBudget: Double = InertiaSettings.defaultJobBudgetSeconds) throws -> InertiaStage {
        guard let path = stub("stub_inertia_service.py") else { throw XCTSkip("stub_inertia_service.py not found") }
        var settings = InertiaSettings.fromEnvironment([
            "FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/opt/bundle",
            "FRWHOOP_INERTIA_TIMEOUT_SECONDS": String(timeout)], activityPython: "/usr/bin/python3")
        settings.mode = mode
        var config = try XCTUnwrap(settings.serviceConfig(activityHome: FileManager.default.currentDirectoryPath))
        config.serveArgs = [path, "--behaviour", behaviour, "--kind", kind, "--tier", tier, "--sleep", "30"] + extraArgs
        let s = ActivityPythonService(config: config)
        services.append(s)
        // Candidate mode is always pinned (the settings refuse it otherwise); shadow only when asked.
        let expected: String? = pin ?? (mode == .candidate ? stubSha : nil)
        return InertiaStage(service: s, mode: mode, expectedBundleSHA256: expected, jobBudgetSeconds: jobBudget)
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

    private func infer(_ inertia: InertiaStage?, stats: inout ActivityLane.Stats,
                       renew: () throws -> Bool = { true }) throws -> ActivityLane.ChunkInference {
        try ActivityLane.inferChunks(requests(), service: try hartService(), inertia: inertia,
                                     versions: (ActivityLane.baselineModelVersion, ActivityLane.baselinePreprocessingVersion),
                                     stats: &stats, renew: renew)
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
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: inferred.versions.model)
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
                                              dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "stub-model")
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
        XCTAssertEqual(on.jobBudgetSeconds, InertiaSettings.defaultJobBudgetSeconds)
        XCTAssertEqual(InertiaSettings.defaultJobBudgetSeconds, 600)
        let budget = InertiaSettings.fromEnvironment(["FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/b",
                                                      "FRWHOOP_INERTIA_JOB_BUDGET_SECONDS": "90"])
        XCTAssertTrue(budget.enabled)
        XCTAssertEqual(budget.jobBudgetSeconds, 90)
        for junk in ["0", "-5", "nan", "soon"] {
            let bad = InertiaSettings.fromEnvironment(["FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/b",
                                                       "FRWHOOP_INERTIA_JOB_BUDGET_SECONDS": junk])
            XCTAssertFalse(bad.enabled, junk)
            XCTAssertEqual(bad.configurationError, "invalid FRWHOOP_INERTIA_JOB_BUDGET_SECONDS \(junk)")
        }
    }

    func testTheInertiaChildIsItsOwnProcessWithTheCheckpointPassedBothWays() throws {
        let s = InertiaSettings.fromEnvironment([
            "FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_MODE": "candidate",
            "FRWHOOP_INERTIA_BUNDLE_DIR": "/opt/inertia/bundle", "FRWHOOP_INERTIA_CHECKPOINT": "/opt/inertia/enc.ckpt",
            "FRWHOOP_INERTIA_BUNDLE_SHA256": stubSha.uppercased(),
            "FRWHOOP_INERTIA_PYTHON": "/opt/venv/bin/python", "FRWHOOP_INERTIA_TIMEOUT_SECONDS": "45"])
        XCTAssertEqual(s.mode, .candidate)
        XCTAssertEqual(s.bundleSHA256, stubSha, "the pin is normalised to lower case")
        let c = try XCTUnwrap(s.serviceConfig(activityHome: "/srv/Tools/ActivityContext"))
        XCTAssertEqual(c.serveArgs, ["-m", "activity_context.inertia.serve", "--bundle", "/opt/inertia/bundle",
                                     "--checkpoint", "/opt/inertia/enc.ckpt", "--timeout", "40",
                                     "--expect-bundle-sha256", stubSha])
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

    /// A refusal that would repeat on every chunk (malformed output, an unknown schema, invalid probabilities, a
    /// structured `output_too_large`) costs one chunk and stops Inertia for the job.
    func testANonTransientInertiaFailureStopsInertiaForTheJob() throws {
        try assertIsolated("malformed", kind: "malformed", chunks: 1, failed: 1)
        try assertIsolated("schema", kind: "schema", chunks: 1, failed: 1)
        try assertIsolated("bad_sum", kind: "invalid_probabilities", chunks: 1, failed: 1)
        try assertIsolated("output_too_large", kind: "output_too_large", chunks: 1, failed: 1)
        XCTAssertTrue(InertiaStage.stoppingServiceKinds.isSuperset(of: ["malformed", "schema", "invalid_probabilities",
                                                                        "output_too_large"]))
    }

    /// Only a NaN line (this chunk's numbers) or a structured `internal` answer costs a single chunk.
    func testNaNAndAnInternalErrorCostOneChunkEach() throws {
        // A NaN token makes the line unparseable; it names the request, so it fails at once, not at the timeout.
        try assertIsolated("nan", kind: "malformed_json", chunks: 3, failed: 3)
        try assertIsolated("internal", kind: "internal", chunks: 3, failed: 3)
        XCTAssertTrue(InertiaStage.stoppingServiceKinds.isDisjoint(with: ["nonfinite", "malformed_json", "internal"]))
    }

    /// Inertia's calls in one job (its readiness check included) share a wall-clock budget: once it is used, Inertia
    /// is stopped for the rest of the job (counted, logged once), the chunks it already answered are kept, and the
    /// HART path is untouched.
    func testInertiaStopsForTheJobOnceItsTimeBudgetIsUsed() throws {
        let reference = try baseline()
        // A budget already used by the readiness check: no chunk is asked.
        var none = ActivityLane.Stats()
        let skipped = try infer(try inertia("ok", jobBudget: 1e-9), stats: &none)
        XCTAssertEqual(skipped.motionHeads.chunks, 0)
        XCTAssertEqual(skipped.motionHeads.stopped, ActivityLane.jobTimeBudgetKind)
        XCTAssertEqual(none.inertiaBudgetExhausted, 1)
        XCTAssertEqual(none.inertiaFailures, 0, "a used budget is not a chunk failure")
        XCTAssertEqual(none.lastInertiaErrorKind, ActivityLane.jobTimeBudgetKind)
        XCTAssertEqual(try hartPayloads(skipped).v1, reference.v1)
        XCTAssertEqual(try hartPayloads(skipped).v2, reference.v2)
        // A slow child (1 s per chunk) against a 1.5 s budget: one or two chunks, never all three.
        var slow = ActivityLane.Stats()
        let partial = try infer(try inertia("ok", extraArgs: ["--delay", "1"], jobBudget: 1.5), stats: &slow)
        XCTAssertTrue((1...2).contains(partial.motionHeads.chunks), "\(partial.motionHeads.chunks) chunks")
        XCTAssertEqual(partial.motionHeads.responses.count, partial.motionHeads.chunks, "answered chunks are kept")
        XCTAssertEqual(partial.motionHeads.stopped, ActivityLane.jobTimeBudgetKind)
        XCTAssertEqual(slow.inertiaBudgetExhausted, 1)
        XCTAssertEqual(try hartPayloads(partial).v1, reference.v1)
        // The default budget never binds on a normal job.
        var normal = ActivityLane.Stats()
        let full = try infer(try inertia("ok"), stats: &normal)
        XCTAssertEqual(full.motionHeads.chunks, 3)
        XCTAssertNil(full.motionHeads.stopped)
        XCTAssertEqual(normal.inertiaBudgetExhausted, 0)
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
                                                         generatedAt: 1_789_500_000, expectedBundleSHA256: nil)
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
        let windows = try XCTUnwrap(p["windows"] as? [String: Any])
        XCTAssertEqual(windows["format"] as? String, "mh-col-1")
        XCTAssertEqual(windows["n"] as? Int, heads.windows.count)
        XCTAssertEqual(windows["w"] as? Int, 30)
        XCTAssertEqual(windows["s0"] as? Int, heads.windows[0].startTs)
        for key in ["ds", "x", "mi"] { XCTAssertEqual((windows[key] as? [Int])?.count, heads.windows.count, key) }
        let columns = try XCTUnwrap(windows["heads"] as? [String: [String: [Int]]])
        XCTAssertEqual(Set(columns.keys), ["posture", "locomotion", "arm_behavior", "transition"])
        for (head, c) in columns {
            XCTAssertEqual(c["i"]?.count, heads.windows.count, head)
            XCTAssertEqual(c["p"]?.count, heads.windows.count, head)
        }
        XCTAssertEqual((windows["x"] as? [Int])?.reduce(0, +), heads.windows.filter(\.isOOD).count)
        // Deterministic.
        XCTAssertEqual(text, try ActivityMotionHeadsDays.payload(day: day, mode: .shadow, collector: inferred.motionHeads,
                                                                candidate: candidate))
    }

    func testCandidateModeWithAStandInIsWithheld() throws {
        var stats = ActivityLane.Stats()
        let inferred = try infer(try inertia("ok", kind: "standin", tier: "shadow", mode: .candidate), stats: &stats)
        let heads = try XCTUnwrap(inferred.motionHeads.trackInput)
        let candidate = ActivityMotionHeadsDays.candidate(mode: .candidate, heads: heads, input: contextInput(),
                                                         generatedAt: 1_789_500_000, expectedBundleSHA256: stubSha)
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
                                                  input: contextInput(), generatedAt: 1_789_500_000,
                                                  expectedBundleSHA256: stubSha)
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
                                                         generatedAt: 1_789_500_000, expectedBundleSHA256: stubSha)
        guard case .document(let doc, let report) = candidate else { return XCTFail("expected a document, got \(candidate)") }
        XCTAssertGreaterThan(report?.attached ?? 0, 0)
        XCTAssertEqual((report?.attached ?? 0) + (report?.dropped ?? 0), heads.windows.count)
        XCTAssertEqual(report?.stamp, doc.versions.motionHeads)
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

    // MARK: - Audit fixes: settings (G-11, G-15, W-5, W-7)

    func testInertiaBooleansAcceptTheUsualSpellingsAndRefuseTheRest() {
        let base = ["FRWHOOP_INERTIA_BUNDLE_DIR": "/b"]
        for on in ["1", "true", "TRUE", "yes", "Yes", "on", " On "] {
            let s = InertiaSettings.fromEnvironment(base.merging(["FRWHOOP_INERTIA_ENABLED": on]) { $1 })
            XCTAssertTrue(s.enabled, on)
            XCTAssertNil(s.configurationError, on)
        }
        for off in ["0", "false", "No", "OFF", ""] {
            let s = InertiaSettings.fromEnvironment(base.merging(["FRWHOOP_INERTIA_ENABLED": off]) { $1 })
            XCTAssertFalse(s.enabled, off)
            XCTAssertNil(s.configurationError, "a recognised off is not an error: \(off)")
        }
        for junk in ["enable", "2", "y", "tru"] {
            let s = InertiaSettings.fromEnvironment(base.merging(["FRWHOOP_INERTIA_ENABLED": junk]) { $1 })
            XCTAssertFalse(s.enabled, junk)
            XCTAssertTrue(s.configurationError?.contains("unknown FRWHOOP_INERTIA_ENABLED value \(junk)") ?? false,
                          "an unknown value is reported, never silently ignored: \(s.configurationError ?? "nil")")
        }
        let badFlag = InertiaSettings.fromEnvironment(base.merging(["FRWHOOP_INERTIA_ENABLED": "1",
                                                                    "FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW": "maybe"]) { $1 })
        XCTAssertFalse(badFlag.enabled)
        XCTAssertTrue(badFlag.configurationError?.contains("FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW") ?? false)
        let badTimeout = InertiaSettings.fromEnvironment(base.merging(["FRWHOOP_INERTIA_ENABLED": "1",
                                                                       "FRWHOOP_INERTIA_TIMEOUT_SECONDS": "soon"]) { $1 })
        XCTAssertFalse(badTimeout.enabled)
        XCTAssertNotNil(badTimeout.configurationError)
    }

    func testCandidateModeNeedsAPinnedBundleAndTheStandInShadowIsAnExplicitShadowOnlyOptIn() throws {
        let env = ["FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/b"]
        let unpinned = InertiaSettings.fromEnvironment(env.merging(["FRWHOOP_INERTIA_MODE": "candidate"]) { $1 })
        XCTAssertFalse(unpinned.enabled)
        XCTAssertEqual(unpinned.configurationError, "FRWHOOP_INERTIA_BUNDLE_SHA256 is required in candidate mode")
        let malformed = InertiaSettings.fromEnvironment(env.merging(["FRWHOOP_INERTIA_BUNDLE_SHA256": "abc"]) { $1 })
        XCTAssertFalse(malformed.enabled)
        XCTAssertEqual(malformed.configurationError, "FRWHOOP_INERTIA_BUNDLE_SHA256 must be 64 hex characters")
        // Shadow: the pin is optional, and passed through (and enforced) when set.
        let shadow = InertiaSettings.fromEnvironment(env)
        XCTAssertTrue(shadow.enabled)
        XCTAssertNil(shadow.bundleSHA256)
        XCTAssertFalse(try XCTUnwrap(shadow.serviceConfig(activityHome: "/h")).serveArgs.contains("--expect-bundle-sha256"))
        let pinnedShadow = InertiaSettings.fromEnvironment(env.merging(["FRWHOOP_INERTIA_BUNDLE_SHA256": stubSha]) { $1 })
        let args = try XCTUnwrap(pinnedShadow.serviceConfig(activityHome: "/h")).serveArgs
        XCTAssertEqual(Array(args.suffix(2)), ["--expect-bundle-sha256", stubSha])
        // The stand-in opt-in: off by default, shadow only.
        XCTAssertFalse(args.contains("--allow-standin-shadow"))
        let standIn = InertiaSettings.fromEnvironment(env.merging(["FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW": "yes"]) { $1 })
        XCTAssertTrue(standIn.enabled)
        XCTAssertTrue(standIn.allowStandInShadow)
        XCTAssertEqual(try XCTUnwrap(standIn.serviceConfig(activityHome: "/h")).serveArgs.last, "--allow-standin-shadow")
        let candidateStandIn = InertiaSettings.fromEnvironment(env.merging([
            "FRWHOOP_INERTIA_MODE": "candidate", "FRWHOOP_INERTIA_BUNDLE_SHA256": stubSha,
            "FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW": "1"]) { $1 })
        XCTAssertFalse(candidateStandIn.enabled)
        XCTAssertEqual(candidateStandIn.configurationError, "FRWHOOP_INERTIA_ALLOW_STANDIN_SHADOW is for shadow mode only")
    }

    func testTheInertiaTimeoutFitsInsideTheLeaseAndTheChildTimesOutFirst() throws {
        let env = ["FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/b"]
        // Default lease 300 s: 60 s fits (≤ 100 s).
        let fits = InertiaSettings.fromEnvironment(env)
        XCTAssertEqual(fits.timeoutSeconds, 60)
        XCTAssertTrue(fits.warnings.isEmpty)
        XCTAssertEqual(try XCTUnwrap(fits.serviceConfig(activityHome: "/h")).requestTimeoutSeconds, 60)
        // A short lease clamps it to a third, with a warning.
        let clamped = InertiaSettings.fromEnvironment(env.merging(["FRWHOOP_INERTIA_TIMEOUT_SECONDS": "90"]) { $1 },
                                                      leaseSeconds: 120)
        XCTAssertEqual(clamped.timeoutSeconds, 40)
        XCTAssertEqual(clamped.warnings.count, 1)
        XCTAssertTrue(clamped.warnings[0].contains("clamped to 40"), clamped.warnings[0])
        let c = try XCTUnwrap(clamped.serviceConfig(activityHome: "/h"))
        XCTAssertEqual(c.requestTimeoutSeconds, 40)
        let i = try XCTUnwrap(c.serveArgs.firstIndex(of: "--timeout"))
        XCTAssertEqual(c.serveArgs[i + 1], "35", "the child's own timeout answers before the worker's")
        // Strictly below the worker's timeout everywhere.
        for t in [0.5, 1, 4, 5, 5.5, 8, 10, 10.5, 33.3, 60, 100] as [Double] {
            let child = InertiaSettings.serveTimeoutSeconds(workerTimeout: t)
            XCTAssertLessThan(child, t, "\(t)")
            XCTAssertGreaterThan(child, 0, "\(t)")
        }
        XCTAssertEqual(InertiaSettings.serveTimeoutSeconds(workerTimeout: 60), 55)
        XCTAssertEqual(InertiaSettings.serveTimeoutSeconds(workerTimeout: 8), 5)
        XCTAssertEqual(InertiaSettings.serveTimeoutSeconds(workerTimeout: 4), 2)
        XCTAssertEqual(InertiaSettings.formatSeconds(2.5), "2.500")
    }

    // MARK: - Audit fixes: lease, pin, counters (G-11, G-15, S-8)

    func testTheLeaseIsRenewedBeforeEveryInertiaCallAndALostLeaseEndsTheJob() throws {
        var calls = 0
        var stats = ActivityLane.Stats()
        _ = try infer(try inertia("ok"), stats: &stats, renew: { calls += 1; return true })
        XCTAssertEqual(calls, 7, "one renewal before Inertia's readiness check, each HART call and each Inertia call")
        calls = 0
        var off = ActivityLane.Stats()
        _ = try infer(nil, stats: &off, renew: { calls += 1; return true })
        XCTAssertEqual(calls, 3, "Inertia off: the lane renews exactly as before")
        // The renewal before the readiness check fails: the job ends before Inertia (or HART) is asked anything.
        calls = 0
        var early = ActivityLane.Stats()
        XCTAssertThrowsError(try infer(try inertia("ok"), stats: &early, renew: { calls += 1; return false })) { error in
            XCTAssertEqual((error as? PostgresClient.Error)?.kind, .stale)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(early.inertiaChunks, 0)
        XCTAssertEqual(early.inertiaUnavailable, 0, "the readiness check never ran")
        XCTAssertEqual(early.windowsInferred, 0)
        // The renewal before the first Inertia call fails: the job ends exactly as a lost lease before HART does.
        calls = 0
        var lost = ActivityLane.Stats()
        XCTAssertThrowsError(try infer(try inertia("ok"), stats: &lost, renew: { calls += 1; return calls < 3 })) { error in
            let pg = error as? PostgresClient.Error
            XCTAssertEqual(pg?.kind, .stale)
            XCTAssertEqual(pg?.sqlstate, "55000")
            XCTAssertEqual(pg?.message, "activity lease lost during inference")
        }
        XCTAssertEqual(lost.inertiaChunks, 0, "no Inertia call without a live lease")
        // A renewal that throws (connection lost) propagates too.
        struct Boom: Error {}
        calls = 0
        var thrown = ActivityLane.Stats()
        XCTAssertThrowsError(try infer(try inertia("ok"), stats: &thrown, renew: {
            calls += 1
            if calls == 3 { throw Boom() }
            return true
        })) { XCTAssertTrue($0 is Boom) }
    }

    func testAChildServingAnotherBundleThanThePinnedOneIsRefusedAndCounted() throws {
        let reference = try baseline()
        // At the start of the job (ping).
        var stats = ActivityLane.Stats()
        let other = String(repeating: "ef", count: 32)
        let inferred = try infer(try inertia("ok", pin: .some(stubSha), extraArgs: ["--bundle-sha", other]), stats: &stats)
        XCTAssertEqual(inferred.motionHeads.stopped, "bundle_mismatch")
        XCTAssertEqual(inferred.motionHeads.chunks, 0)
        XCTAssertEqual(stats.inertiaBundleRefused, 1)
        XCTAssertEqual(stats.inertiaUnavailable, 0, "a pin refusal is its own counter")
        XCTAssertEqual(stats.lastInertiaErrorKind, "bundle_mismatch")
        XCTAssertNil(inferred.motionHeads.trackInput)
        XCTAssertEqual(try hartPayloads(inferred).v1, reference.v1)
        // A child that refused to load because of its own --expect-bundle-sha256 check (model unavailable, another
        // digest reported) is counted as a pin refusal, not as a missing model.
        var refusedStats = ActivityLane.Stats()
        let refusedLoad = try infer(try inertia("model_missing", pin: .some(stubSha), extraArgs: ["--bundle-sha", other]),
                                    stats: &refusedStats)
        XCTAssertEqual(refusedLoad.motionHeads.stopped, "bundle_mismatch")
        XCTAssertEqual(refusedStats.inertiaBundleRefused, 1)
        XCTAssertEqual(refusedStats.inertiaUnavailable, 0)
        // A missing model with the right digest is still a missing model.
        var missingStats = ActivityLane.Stats()
        let missing = try infer(try inertia("model_missing", pin: .some(stubSha)), stats: &missingStats)
        XCTAssertEqual(missing.motionHeads.stopped, "model_unavailable")
        XCTAssertEqual(missingStats.inertiaUnavailable, 1)
        XCTAssertEqual(missingStats.inertiaBundleRefused, 0)
        // Mid-job (the infer response names another bundle): refused, and Inertia stops for the job.
        var midStats = ActivityLane.Stats()
        let mid = try infer(try inertia("ok", pin: .some(stubSha), extraArgs: ["--infer-bundle-sha", other]), stats: &midStats)
        XCTAssertEqual(mid.motionHeads.chunks, 1)
        XCTAssertEqual(mid.motionHeads.failureKinds["bundle_mismatch"], 1)
        XCTAssertEqual(mid.motionHeads.stopped, "bundle_mismatch")
        XCTAssertEqual(midStats.inertiaBundleRefused, 1)
        XCTAssertNil(mid.motionHeads.trackInput)
        // The matching pin is accepted.
        var okStats = ActivityLane.Stats()
        let ok = try infer(try inertia("ok", pin: .some(stubSha)), stats: &okStats)
        XCTAssertEqual(ok.motionHeads.responses.count, 3)
        XCTAssertEqual(okStats.inertiaBundleRefused, 0)
        // And a candidate decode with a pin that does not match is withheld, never decoded.
        let heads = try XCTUnwrap(ok.motionHeads.trackInput)
        guard case .withheld(let why) = ActivityMotionHeadsDays.candidate(
            mode: .candidate, heads: heads, input: contextInput(), generatedAt: 1, expectedBundleSHA256: other)
        else { return XCTFail("expected withheld") }
        XCTAssertEqual(why, "bundle_sha256_mismatch")
        guard case .withheld(let unpinned) = ActivityMotionHeadsDays.candidate(
            mode: .candidate, heads: heads, input: contextInput(), generatedAt: 1, expectedBundleSHA256: nil)
        else { return XCTFail("expected withheld") }
        XCTAssertEqual(unpinned, "bundle_sha256_not_pinned")
    }

    func testTheShadowRowAndStatsCarryTheAttachDropAndOmitCounters() throws {
        // Shadow: a dry-run attachment report.
        var stats = ActivityLane.Stats()
        let inferred = try infer(try inertia("ok"), stats: &stats)
        let input = contextInput()
        let context = ActivityLane.ContextDayBuild(built: nil, input: input, generatedAt: 1_789_500_000)
        let shadowStage = try inertia("ok")
        let text = ActivityLane.motionHeadsPayload(day: day, inertia: shadowStage, collector: inferred.motionHeads,
                                                   context: context, stats: &stats)
        let summary = try XCTUnwrap(try payloadObject(text)["summary"] as? [String: Any])
        let report = try XCTUnwrap(summary["track_report"] as? [String: Any])
        let n = inferred.motionHeads.trackInput?.windows.count ?? -1
        let attached = try XCTUnwrap(report["attached"] as? Int)
        let dropped = (report["dropped_no_observation"] as? Int ?? 0) + (report["dropped_superseded"] as? Int ?? 0)
            + (report["dropped_out_of_range"] as? Int ?? 0)
        XCTAssertGreaterThan(attached, 0)
        XCTAssertEqual(attached + dropped, n)
        XCTAssertEqual(report["windows_in"] as? Int, n)
        XCTAssertEqual(report["posture_omitted_sleep"] as? Int, 0)
        XCTAssertEqual(stats.inertiaWindowsAttached, attached)
        XCTAssertEqual(stats.inertiaWindowsDropped, dropped)
        // Candidate over a sleeping day: the decode's own report, posture omissions included.
        var sim = DaySim(start: dayStart + 36_000)
        sim.still(360)
        var sleepInput = ActivityContextDays.trackInput(
            windows: sim.windows, streams: sim.streams, sleep: [(dayStart + 36_000, dayStart + 36_360)], exercise: [],
            dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false, encoderVersion: "stub-model")
        sleepInput.sleepKnownOutsideSessions = true
        var cStats = ActivityLane.Stats()
        let real = try infer(try inertia("ok", kind: "inertia1", tier: "candidate", mode: .candidate), stats: &cStats)
        let cText = ActivityLane.motionHeadsPayload(
            day: day, inertia: try inertia("ok", kind: "inertia1", tier: "candidate", mode: .candidate),
            collector: real.motionHeads,
            context: ActivityLane.ContextDayBuild(built: nil, input: sleepInput, generatedAt: 1_789_500_000),
            stats: &cStats)
        let cSummary = try XCTUnwrap(try payloadObject(cText)["summary"] as? [String: Any])
        let cReport = try XCTUnwrap(cSummary["track_report"] as? [String: Any])
        XCTAssertNotNil(cReport["stamp"] as? String)
        XCTAssertGreaterThan(cReport["posture_omitted_sleep"] as? Int ?? 0, 0, "asleep seconds drop the posture term")
        XCTAssertEqual(cStats.inertiaCandidateDocuments, 1)
        XCTAssertEqual(cStats.inertiaPostureOmitted, cReport["posture_omitted_sleep"] as? Int)
        XCTAssertEqual(cStats.inertiaWindowsAttached, cReport["attached"] as? Int)
    }

    // MARK: - Audit fixes: retention-sized windows (W-6)

    func testTheStoredWindowsAreColumnarSmallIntegersAndCappedPerDay() throws {
        func spec(_ head: MotionHead) -> MotionHeadSpec {
            let classes = head.classOrder
            var prior: [String: Double] = [:]
            for c in classes { prior[c] = head.isCategorical ? 1 / Double(classes.count) : 0.05 }
            return MotionHeadSpec(classOrder: classes, prior: prior,
                                  status: Dictionary(uniqueKeysWithValues: classes.map { ($0, .strong) }))
        }
        func collector(hop: Int) -> MotionHeadsCollector {
            let bundle = MotionHeadsBundleInfo(
                encoderId: "standin:handcrafted-stats-v1", encoderKind: .standin, encoderVersion: "t",
                checkpointSha256: nil, headsVersion: "cap-test", bundleSha256: stubSha, evidenceTierMax: .shadow,
                windowS: 30, hopS: hop,
                heads: [.posture: spec(.posture), .locomotion: spec(.locomotion), .armBehavior: spec(.armBehavior),
                        .transition: spec(.transition)],
                ood: MotionHeadsOODInfo(method: "knn", threshold: 1))
            let P = MotionHead.posture.classOrder, L = MotionHead.locomotion.classOrder, A = MotionHead.armBehavior.classOrder
            func peaked(_ classes: [String], _ k: Int, _ p: Double) -> [String: Double] {
                Dictionary(uniqueKeysWithValues: classes.enumerated().map {
                    ($0.element, $0.offset == k ? p : (1 - p) / Double(classes.count - 1))
                })
            }
            let windows = stride(from: dayStart, to: dayEnd - 30, by: hop).map { s -> MotionHeadsWindow in
                let k = (s / hop) % 4
                return MotionHeadsWindow(startTs: s, endTs: s + 30, posture: peaked(P, k, 0.873),
                                         locomotion: peaked(L, k + 1, 0.666), armBehavior: peaked(A, k, 0.512),
                                         transition: Dictionary(uniqueKeysWithValues: MotionHead.transition.classOrder
                                             .enumerated().map { ($0.element, $0.offset == k ? 0.9 : 0.123) }),
                                         movementIntensity: 0.4567, oodScore: 0.3, isOOD: s % 60 == 0)
            }
            var c = MotionHeadsCollector()
            c.responses = [MotionHeadsResponse(bundle: bundle, windows: windows)]
            c.chunks = 24
            return c
        }
        // A full day at a 5-s hop: 17,274 windows, stored, under the cap.
        let full = collector(hop: 5)
        let text = try XCTUnwrap(try ActivityMotionHeadsDays.payload(day: day, mode: .shadow, collector: full,
                                                                     candidate: .notRequested))
        let p = try payloadObject(text)
        let w = try XCTUnwrap(p["windows"] as? [String: Any])
        let n = full.responses[0].windows.count
        XCTAssertEqual(w["n"] as? Int, n)
        let windowsBytes = try JSONSerialization.data(withJSONObject: w).count
        XCTAssertLessThanOrEqual(windowsBytes, ActivityMotionHeadsDays.maxWindowsBytes, "\(windowsBytes) bytes")
        XCTAssertLessThanOrEqual(text.utf8.count, 600 * 1024, "the whole shadow row stays near 0.5 MB/day/bundle")
        let heads = try XCTUnwrap(w["heads"] as? [String: [String: [Int]]])
        // Window 1 (k = 1): posture top is class 1 at 87 %, locomotion class 2 at 67 %, intensity 46 %.
        XCTAssertEqual(heads["posture"]?["i"]?[1], 1)
        XCTAssertEqual(heads["posture"]?["p"]?[1], 87)
        XCTAssertEqual(heads["locomotion"]?["i"]?[1], 2)
        XCTAssertEqual(heads["locomotion"]?["p"]?[1], 67)
        XCTAssertEqual(heads["transition"]?["p"]?[1], 90)
        XCTAssertEqual((w["mi"] as? [Int])?[1], 46)
        XCTAssertEqual((w["ds"] as? [Int])?.prefix(3).map { $0 }, [0, 5, 5])
        XCTAssertEqual((w["x"] as? [Int])?.prefix(13).map { $0 }, [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertEqual((p["summary"] as? [String: Any])?["windows_omitted"] as? Bool, false)
        // A 1-s hop would be five times that: the windows are omitted and the summary says so.
        let dense = try payloadObject(try ActivityMotionHeadsDays.payload(day: day, mode: .shadow, collector: collector(hop: 1),
                                                                         candidate: .notRequested))
        XCTAssertTrue(dense["windows"] is NSNull)
        XCTAssertEqual((dense["summary"] as? [String: Any])?["windows_omitted"] as? Bool, true)
        XCTAssertEqual(ActivityMotionHeadsDays.percent(nil), -1)
        XCTAssertEqual(ActivityMotionHeadsDays.percent(.nan), -1)
        XCTAssertEqual(ActivityMotionHeadsDays.percent(1e300), 100, "clamped before conversion: never a trap")
    }

    // MARK: - The on-host HART cache never makes the shadow row partial

    /// A chunk whose HART answer comes from the on-host cache is not sent to HART again (no lease renewal, no
    /// model call, counted as reused) — but Inertia is still asked for it, with its own lease renewal first.
    /// With Inertia off the cached pass is exactly main's: no renewal, no call.
    func testACachedHartChunkIsStillInferredByInertia() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try XCTUnwrap(ActivityLocalCache(path: directory.path))
        let hart = try hartService()
        _ = try hart.ping()                                      // the child reports its versions: answers are cacheable
        func versions() -> (model: String, preprocessing: String) {
            ActivityLane.resolvedVersions(reportedModel: hart.reportedModelVersion,
                                          reportedPreprocessing: hart.reportedPreprocessingVersion)
        }
        // Pass 1 fills the cache (HART inferred for all three chunks).
        var first = ActivityLane.Stats()
        var renewals = 0
        let filled = try ActivityLane.inferChunks(requests(), service: hart, inertia: nil, versions: versions(),
                                                  cache: cache, stats: &first, renew: { renewals += 1; return true })
        XCTAssertEqual(first.windowsInferred, 3)
        XCTAssertEqual(first.windowsReused, 0)
        XCTAssertEqual(renewals, 3)

        // Pass 2, Inertia on: HART comes from the cache, Inertia is still asked for every chunk.
        var second = ActivityLane.Stats()
        renewals = 0
        let cached = try ActivityLane.inferChunks(requests(), service: hart, inertia: try inertia("ok"),
                                                  versions: versions(), cache: cache, stats: &second,
                                                  renew: { renewals += 1; return true })
        XCTAssertEqual(second.windowsInferred, 0, "HART is not re-inferred")
        XCTAssertEqual(second.windowsReused, 3)
        XCTAssertEqual(second.inertiaChunks, 3, "Inertia still runs on every cached chunk")
        XCTAssertEqual(cached.motionHeads.responses.count, 3)
        XCTAssertEqual(cached.motionHeads.trackInput?.windows.count, 3 * 19, "the shadow row is complete")
        XCTAssertEqual(renewals, 4, "one renewal before the readiness check and each Inertia call, none for the cached HART answers")
        let a = try hartPayloads(filled), b = try hartPayloads(cached)
        XCTAssertEqual(a.v1, b.v1, "the cached HART windows publish exactly what the inferred ones did")
        XCTAssertEqual(a.v2, b.v2)

        // Pass 3, Inertia off: main's cached pass, untouched.
        var third = ActivityLane.Stats()
        renewals = 0
        let plain = try ActivityLane.inferChunks(requests(), service: hart, inertia: nil, versions: versions(),
                                                 cache: cache, stats: &third, renew: { renewals += 1; return true })
        XCTAssertEqual(renewals, 0)
        XCTAssertEqual(third.windowsReused, 3)
        XCTAssertEqual(third.inertiaChunks, 0)
        XCTAssertEqual(try hartPayloads(plain).v1, a.v1)

        // A lost lease before the Inertia call of a cached chunk ends the job exactly like one before HART.
        var lost = ActivityLane.Stats()
        XCTAssertThrowsError(try ActivityLane.inferChunks(requests(), service: hart, inertia: try inertia("ok"),
                                                          versions: versions(), cache: cache, stats: &lost,
                                                          renew: { false })) { error in
            XCTAssertEqual((error as? PostgresClient.Error)?.kind, .stale)
        }
        XCTAssertEqual(lost.inertiaChunks, 0)
    }

    func testNothingValidMeansNoShadowRow() throws {
        var stats = ActivityLane.Stats()
        let inferred = try infer(try inertia("schema"), stats: &stats)
        XCTAssertNil(inferred.motionHeads.trackInput)
        XCTAssertNil(try ActivityMotionHeadsDays.payload(day: day, mode: .shadow, collector: inferred.motionHeads,
                                                        candidate: .notRequested))
    }
}
