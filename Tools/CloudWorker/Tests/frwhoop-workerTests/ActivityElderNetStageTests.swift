import XCTest
import StrandAnalytics
@testable import frwhoop_worker

/// The ElderNet stage of the activity lane against stub services (no torch, no model, no database): configuration,
/// failure isolation, pins, the shadow payload and the candidate comparison, and that the HART output is
/// byte-identical whatever ElderNet does. The SQL side is `supabase/functions/tests/activity_gait_windows_contract.sql`;
/// the two together are `ActivityGaitWindowsDatabaseTests`.
final class ActivityElderNetStageTests: XCTestCase {

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

    private let version = "eldernet-437a38b"

    /// The weights digest the stub serves for `seed` (the same canonical text the decoder hashes).
    private func digest(_ seed: String = "stub") throws -> String {
        let heads = GaitQualityWire.weightNames
        var w: [String: String] = [:]
        for h in heads {
            // hashlib.sha256("stub-eldernet-<head>-<seed>") — computed through the same SHA-256 the package uses.
            w[h] = try sha256Hex("stub-eldernet-\(h)-\(seed)")
        }
        return ElderNetStage.weightsDigest(of: w)
    }

    /// SHA-256 of `text`, via the system shasum (test-only; the worker never shells out for it).
    private func sha256Hex(_ text: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())", text]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func eldernet(_ behaviour: String = "ok", mode: ElderNetSettings.Mode = .shadow, timeout: Double = 5,
                          pinVersion: String?? = .none, pinDigest: String?? = .none, prior: Double? = 0.2,
                          extraArgs: [String] = [],
                          jobBudget: Double = ElderNetSettings.defaultJobBudgetSeconds) throws -> ElderNetStage {
        guard let path = stub("stub_eldernet_service.py") else { throw XCTSkip("stub_eldernet_service.py not found") }
        let settings = ElderNetSettings.fromEnvironment([
            "FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/opt/eldernet",
            "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u",
            "FRWHOOP_ELDERNET_TIMEOUT_SECONDS": String(timeout)], activityPython: "/usr/bin/python3")
        var config = try XCTUnwrap(settings.serviceConfig(activityHome: FileManager.default.currentDirectoryPath))
        config.serveArgs = [path, "--behaviour", behaviour, "--sleep", "30"] + extraArgs
        let s = ActivityPythonService(config: config)
        services.append(s)
        // Candidate mode is always pinned (the settings refuse it otherwise); shadow only when asked.
        let v: String? = pinVersion ?? (mode == .candidate ? version : nil)
        let d: String? = try pinDigest ?? (mode == .candidate ? digest() : nil)
        return ElderNetStage(service: s, mode: mode, expectedModelVersion: v, expectedWeightsDigest: d, gaitPrior: prior,
                             jobBudgetSeconds: jobBudget)
    }

    private func inertia() throws -> InertiaStage {
        guard let path = stub("stub_inertia_service.py") else { throw XCTSkip("stub_inertia_service.py not found") }
        let settings = InertiaSettings.fromEnvironment([
            "FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/opt/bundle",
            "FRWHOOP_INERTIA_TIMEOUT_SECONDS": "5"], activityPython: "/usr/bin/python3")
        var config = try XCTUnwrap(settings.serviceConfig(activityHome: FileManager.default.currentDirectoryPath))
        config.serveArgs = [path, "--behaviour", "ok"]
        let s = ActivityPythonService(config: config)
        services.append(s)
        return InertiaStage(service: s, mode: .shadow)
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

    private func versions(_ hart: ActivityPythonService) -> (model: String, preprocessing: String) {
        ActivityLane.resolvedVersions(reportedModel: hart.reportedModelVersion,
                                      reportedPreprocessing: hart.reportedPreprocessingVersion)
    }

    private func infer(_ eldernet: ElderNetStage?, inertia: InertiaStage? = nil, stats: inout ActivityLane.Stats,
                       renew: () throws -> Bool = { true }) throws -> ActivityLane.ChunkInference {
        try ActivityLane.inferChunks(requests(), service: try hartService(), inertia: inertia, eldernet: eldernet,
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

    func testElderNetIsOffUnlessEnabledWithAWeightsDirectory() {
        XCTAssertFalse(ElderNetSettings.fromEnvironment([:]).enabled)
        XCTAssertNil(ElderNetSettings.fromEnvironment([:]).serviceConfig(activityHome: "/x"))
        XCTAssertNil(ElderNetSettings.fromEnvironment([:]).configurationError, "unset is plainly off")
        let noDir = ElderNetSettings.fromEnvironment(["FRWHOOP_ELDERNET_ENABLED": "1"])
        XCTAssertFalse(noDir.enabled)
        XCTAssertEqual(noDir.configurationError, "FRWHOOP_ELDERNET_WEIGHTS_DIR is required")
        // The serve process imports upstream's own modules from a sha-verified source checkout: required too.
        let noUpstream = ElderNetSettings.fromEnvironment(["FRWHOOP_ELDERNET_ENABLED": "1",
                                                           "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w"])
        XCTAssertFalse(noUpstream.enabled)
        XCTAssertEqual(noUpstream.configurationError,
                       "FRWHOOP_ELDERNET_UPSTREAM_DIR is required (the sha-verified upstream source checkout)")
        XCTAssertNil(noUpstream.serviceConfig(activityHome: "/x"))
        let badMode = ElderNetSettings.fromEnvironment(["FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w",
                                                        "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u",
                                                        "FRWHOOP_ELDERNET_MODE": "production"])
        XCTAssertFalse(badMode.enabled, "production evidence needs a code and config change, not an env flag")
        XCTAssertEqual(badMode.configurationError, "unknown FRWHOOP_ELDERNET_MODE production")
        let on = ElderNetSettings.fromEnvironment(["FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w",
                                                   "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u"],
                                                  activityPython: "/usr/bin/python3")
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.mode, .shadow, "shadow is the default")
        XCTAssertEqual(on.python, "/usr/bin/python3")
        XCTAssertEqual(on.timeoutSeconds, 60)
        XCTAssertNil(on.modelVersion)
        XCTAssertNil(on.weightsSHA256)
        XCTAssertEqual(on.jobBudgetSeconds, ElderNetSettings.defaultJobBudgetSeconds)
        XCTAssertEqual(ElderNetSettings.defaultJobBudgetSeconds, 600)
        let budget = ElderNetSettings.fromEnvironment(["FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w",
                                                       "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u",
                                                       "FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS": "120"])
        XCTAssertTrue(budget.enabled)
        XCTAssertEqual(budget.jobBudgetSeconds, 120)
        for junk in ["0", "-1", "inf", "later"] {
            let bad = ElderNetSettings.fromEnvironment(["FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w",
                                                        "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u",
                                                        "FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS": junk])
            XCTAssertFalse(bad.enabled, junk)
            XCTAssertEqual(bad.configurationError, "invalid FRWHOOP_ELDERNET_JOB_BUDGET_SECONDS \(junk)")
        }
    }

    func testTheEnabledFlagIsStrictlyParsed() {
        let base = ["FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w", "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u"]
        for v in ["1", "true", "TRUE", "yes", "On", " on "] {
            let s = ElderNetSettings.fromEnvironment(base.merging(["FRWHOOP_ELDERNET_ENABLED": v]) { $1 })
            XCTAssertTrue(s.enabled, v)
            XCTAssertNil(s.configurationError, v)
        }
        for v in ["0", "false", "No", "OFF", ""] {
            let s = ElderNetSettings.fromEnvironment(base.merging(["FRWHOOP_ELDERNET_ENABLED": v]) { $1 })
            XCTAssertFalse(s.enabled, v)
            XCTAssertNil(s.configurationError, "a recognised off is not an error: \(v)")
        }
        for junk in ["enable", "2", "y", "tru"] {
            let s = ElderNetSettings.fromEnvironment(base.merging(["FRWHOOP_ELDERNET_ENABLED": junk]) { $1 })
            XCTAssertFalse(s.enabled, junk)
            XCTAssertTrue(s.configurationError?.contains("unknown FRWHOOP_ELDERNET_ENABLED value \(junk)") ?? false,
                          "never silently ignored: \(s.configurationError ?? "nil")")
        }
    }

    func testCandidateModeNeedsBothPinsAndTheGaitPrior() throws {
        let env = ["FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w",
                   "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u", "FRWHOOP_ELDERNET_MODE": "candidate"]
        let sha = String(repeating: "ab", count: 32)
        let unpinned = ElderNetSettings.fromEnvironment(env)
        XCTAssertFalse(unpinned.enabled)
        XCTAssertEqual(unpinned.configurationError,
                       "FRWHOOP_ELDERNET_MODEL_VERSION and FRWHOOP_ELDERNET_WEIGHTS_SHA256 are required in candidate mode")
        let noPrior = ElderNetSettings.fromEnvironment(env.merging([
            "FRWHOOP_ELDERNET_MODEL_VERSION": version, "FRWHOOP_ELDERNET_WEIGHTS_SHA256": sha]) { $1 })
        XCTAssertFalse(noPrior.enabled)
        XCTAssertEqual(noPrior.configurationError, "FRWHOOP_ELDERNET_GAIT_PRIOR is required in candidate mode")
        let ok = ElderNetSettings.fromEnvironment(env.merging([
            "FRWHOOP_ELDERNET_MODEL_VERSION": version, "FRWHOOP_ELDERNET_WEIGHTS_SHA256": sha.uppercased(),
            "FRWHOOP_ELDERNET_GAIT_PRIOR": "0.18"]) { $1 })
        XCTAssertTrue(ok.enabled)
        XCTAssertEqual(ok.weightsSHA256, sha, "the pin is normalised to lower case")
        XCTAssertEqual(ok.gaitPrior, 0.18)
        for (key, value, message) in [
            ("FRWHOOP_ELDERNET_WEIGHTS_SHA256", "abc", "FRWHOOP_ELDERNET_WEIGHTS_SHA256 must be 64 hex characters"),
            ("FRWHOOP_ELDERNET_MODEL_VERSION", "bad version", "FRWHOOP_ELDERNET_MODEL_VERSION is not a plain identifier"),
            ("FRWHOOP_ELDERNET_GAIT_PRIOR", "1.5", "FRWHOOP_ELDERNET_GAIT_PRIOR must be a number in [0.01, 0.99]"),
            ("FRWHOOP_ELDERNET_GAIT_PRIOR", "lots", "FRWHOOP_ELDERNET_GAIT_PRIOR must be a number in [0.01, 0.99]"),
            ("FRWHOOP_ELDERNET_TIMEOUT_SECONDS", "soon", "invalid FRWHOOP_ELDERNET_TIMEOUT_SECONDS soon"),
        ] {
            let s = ElderNetSettings.fromEnvironment(["FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w",
                                                      "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u",
                                                      key: value])
            XCTAssertFalse(s.enabled, key)
            XCTAssertEqual(s.configurationError, message)
        }
        // Shadow: the pins are optional, and enforced when set.
        let shadowPinned = ElderNetSettings.fromEnvironment(["FRWHOOP_ELDERNET_ENABLED": "1",
                                                             "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w",
                                                             "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u",
                                                             "FRWHOOP_ELDERNET_MODEL_VERSION": version])
        XCTAssertTrue(shadowPinned.enabled)
        XCTAssertEqual(shadowPinned.modelVersion, version)
    }

    func testTheElderNetChildIsItsOwnProcessAndItsTimeoutFitsTheLease() throws {
        let s = ElderNetSettings.fromEnvironment([
            "FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/opt/eldernet/weights",
            "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/opt/eldernet/upstream",
            "FRWHOOP_ELDERNET_PYTHON": "/opt/venv/bin/python", "FRWHOOP_ELDERNET_TIMEOUT_SECONDS": "45"])
        let c = try XCTUnwrap(s.serviceConfig(activityHome: "/srv/Tools/ActivityContext"))
        XCTAssertEqual(c.serveArgs, ["-m", "activity_context.eldernet.serve", "--weights-dir", "/opt/eldernet/weights",
                                     "--upstream-dir", "/opt/eldernet/upstream", "--timeout", "40"])
        XCTAssertEqual(c.pythonBin, "/opt/venv/bin/python")
        XCTAssertEqual(c.requestTimeoutSeconds, 45)
        XCTAssertTrue(c.keepsRawLines)
        XCTAssertTrue(c.extraEnvironment.isEmpty)
        XCTAssertLessThanOrEqual(c.maxResponseLineBytes, 16 * 1024 * 1024)
        // A short lease clamps the timeout to a third, with a warning; the child still answers first.
        let clamped = ElderNetSettings.fromEnvironment(["FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/w",
                                                        "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u",
                                                        "FRWHOOP_ELDERNET_TIMEOUT_SECONDS": "90"], leaseSeconds: 120)
        XCTAssertEqual(clamped.timeoutSeconds, 40)
        XCTAssertEqual(clamped.warnings.count, 1)
        XCTAssertTrue(clamped.warnings[0].contains("clamped to 40"), clamped.warnings[0])
        let cc = try XCTUnwrap(clamped.serviceConfig(activityHome: "/h"))
        let i = try XCTUnwrap(cc.serveArgs.firstIndex(of: "--timeout"))
        XCTAssertEqual(cc.serveArgs[i + 1], "35")
        // The HART child's config is untouched by any of this.
        XCTAssertFalse(ActivityPythonService.Config.fromEnvironment([:]).keepsRawLines)
        // The ping parser reports an unavailable ElderNet model as unavailable, and keeps the weights map.
        let ping = ActivityPythonService.parsePing(["ok": true, "model_available": true, "model_status": "eldernet_loaded",
                                                    "model_version": version, "weights": ["gait_detection": "ab"]])
        XCTAssertTrue(ping.modelAvailable)
        XCTAssertEqual(ping.objects["weights"], ["gait_detection": "ab"])
        // The newer serve's extra ping keys are tolerated (a string digest, an object with non-string values).
        let newer = ActivityPythonService.parsePing(["ok": true, "model_available": true, "model_status": "eldernet_loaded",
                                                     "model_version": version, "weights": ["gait_detection": "ab"],
                                                     "weights_digest": String(repeating: "c", count: 64),
                                                     "upstream_source": ["commit": "437a38b", "verified": true]])
        XCTAssertTrue(newer.modelAvailable)
        XCTAssertEqual(newer.objects["weights"], ["gait_detection": "ab"])
        XCTAssertEqual(newer.details["weights_digest"], String(repeating: "c", count: 64))
        XCTAssertFalse(ActivityPythonService.parsePing(["ok": true, "model_status": "eldernet_unavailable"]).modelAvailable)
    }

    /// The worker hashes a ping's weights itself; it must agree with the package's digest of the same weights.
    func testTheWorkerWeightsDigestIsThePackagesDigest() throws {
        let weights = Dictionary(uniqueKeysWithValues: GaitQualityWire.weightNames.enumerated().map {
            ($0.element, String(repeating: String("0123456789abcdef".map { $0 }[$0.offset]), count: 64))
        })
        let model = GaitQualityModelInfo(modelVersion: version, weights: weights, upstreamCommit: "437a38bc", hopS: 5)
        XCTAssertEqual(ElderNetStage.weightsDigest(of: weights), model.weightsDigest)
        XCTAssertTrue(ElderNetSettings.isModelVersion("eldernet-437a38b"))
        XCTAssertFalse(ElderNetSettings.isModelVersion("bad version"))
        XCTAssertFalse(ElderNetSettings.isModelVersion(""))
        // The worker's line decoder: not JSON at all is .notJSON (nonfinite on a NaN token); the rest is the package's.
        XCTAssertThrowsError(try ElderNetStage.decodeResponse(Data(#"{"gait_prob": NaN}"#.utf8))) {
            XCTAssertEqual($0 as? GaitQualityResponseError, .notJSON(nonfinite: true))
        }
        XCTAssertThrowsError(try ElderNetStage.decodeResponse(Data("[1]".utf8))) {
            XCTAssertEqual($0 as? GaitQualityResponseError, .notAnObject)
        }
        XCTAssertThrowsError(try ElderNetStage.decodeResponse(Data(#"{"ok":false,"kind":"timeout","error":"slow"}"#.utf8))) {
            XCTAssertEqual($0 as? GaitQualityResponseError, .serviceError(kind: "timeout", message: "slow"))
        }
    }

    // MARK: - Failure isolation

    func testElderNetDisabledLeavesTheLaneAsItWas() throws {
        var stats = ActivityLane.Stats()
        let inferred = try infer(nil, stats: &stats)
        XCTAssertEqual(inferred.windows.count, 3)
        XCTAssertTrue(inferred.gaitQuality.isEmpty)
        XCTAssertEqual(stats.eldernetJobs, 0)
        XCTAssertEqual(stats.eldernetChunks, 0)
        XCTAssertNil(stats.lastElderNetError)
    }

    private func assertIsolated(_ behaviour: String, kind expectedKind: String, chunks: Int, failed: Int,
                                unavailable: Int = 0, pinRefused: Int = 0, stage: ElderNetStage? = nil,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let reference = try baseline()
        var stats = ActivityLane.Stats()
        let started = Date()
        let inferred = try infer(try stage ?? eldernet(behaviour, timeout: 1), stats: &stats)
        let payloads = try hartPayloads(inferred)
        XCTAssertEqual(payloads.v1, reference.v1, "\(behaviour): v1 payload", file: file, line: line)
        XCTAssertEqual(payloads.v2, reference.v2, "\(behaviour): v2 payload", file: file, line: line)
        XCTAssertEqual(stats.windowsInferred, 3, file: file, line: line)
        XCTAssertEqual(inferred.gaitQuality.chunks, chunks, "\(behaviour): chunks asked", file: file, line: line)
        XCTAssertEqual(inferred.gaitQuality.failedChunks, failed, file: file, line: line)
        XCTAssertEqual(stats.eldernetFailures, failed, file: file, line: line)
        XCTAssertEqual(stats.eldernetUnavailable, unavailable, file: file, line: line)
        XCTAssertEqual(stats.eldernetPinRefused, pinRefused, file: file, line: line)
        XCTAssertEqual(stats.lastElderNetErrorKind, expectedKind, stats.lastElderNetError ?? "", file: file, line: line)
        XCTAssertNil(stats.lastError, "the HART path saw no error", file: file, line: line)
        XCTAssertNil(inferred.gaitQuality.trackInput, "\(behaviour): nothing valid to store", file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "\(behaviour): at most one timeout per job",
                          file: file, line: line)
    }

    func testAMissingModelOrBadWeightsNeverTouchTheHartJob() throws {
        try assertIsolated("model_missing", kind: "model_unavailable", chunks: 0, failed: 0, unavailable: 1)
        try assertIsolated("weights_mismatch", kind: "model_unavailable", chunks: 0, failed: 0, unavailable: 1)
    }

    func testATimeoutCostsOneChunkAndACrashStopsElderNetForTheJob() throws {
        try assertIsolated("timeout", kind: "timeout", chunks: 1, failed: 1)
        try assertIsolated("crash", kind: "crash", chunks: 1, failed: 1)
    }

    /// A refusal that would repeat on every chunk (malformed output, an unknown schema, invalid values, a
    /// structured `output_too_large`) costs one chunk and stops ElderNet for the job, like `model_missing`.
    func testANonTransientFailureStopsElderNetForTheJob() throws {
        try assertIsolated("malformed", kind: "malformed", chunks: 1, failed: 1)
        try assertIsolated("schema", kind: "schema", chunks: 1, failed: 1)
        try assertIsolated("out_of_range", kind: "invalid_values", chunks: 1, failed: 1)
        try assertIsolated("metrics_on_non_gait", kind: "invalid_values", chunks: 1, failed: 1)
        try assertIsolated("output_too_large", kind: "output_too_large", chunks: 1, failed: 1)
        XCTAssertTrue(ElderNetStage.stoppingServiceKinds.isSuperset(of: ["malformed", "schema", "invalid_values",
                                                                         "output_too_large"]))
    }

    /// Only a NaN line (this chunk's numbers; refused at once, not at the timeout) or a structured `internal`
    /// answer costs a single chunk.
    func testNaNAndAnInternalErrorCostOneChunkEach() throws {
        try assertIsolated("nan", kind: "malformed_json", chunks: 3, failed: 3)
        try assertIsolated("internal", kind: "internal", chunks: 3, failed: 3)
        XCTAssertTrue(ElderNetStage.stoppingServiceKinds.isDisjoint(with: ["nonfinite", "malformed_json", "internal"]))
    }

    /// ElderNet's calls in one job (its readiness check included) share a wall-clock budget: once it is used,
    /// ElderNet is stopped for the rest of the job (counted, logged once), the chunks it already answered are kept
    /// and stored, and the HART path is untouched.
    func testElderNetStopsForTheJobOnceItsTimeBudgetIsUsed() throws {
        let reference = try baseline()
        var none = ActivityLane.Stats()
        let skipped = try infer(try eldernet("ok", jobBudget: 1e-9), stats: &none)
        XCTAssertEqual(skipped.gaitQuality.chunks, 0, "the readiness check alone used the budget")
        XCTAssertEqual(skipped.gaitQuality.stopped, ActivityLane.jobTimeBudgetKind)
        XCTAssertEqual(none.eldernetBudgetExhausted, 1)
        XCTAssertEqual(none.eldernetFailures, 0, "a used budget is not a chunk failure")
        XCTAssertEqual(none.lastElderNetErrorKind, ActivityLane.jobTimeBudgetKind)
        XCTAssertEqual(try hartPayloads(skipped).v1, reference.v1)
        XCTAssertEqual(try hartPayloads(skipped).v2, reference.v2)
        // A slow child (1 s per chunk) against a 1.5 s budget: one or two chunks, never all three.
        var slow = ActivityLane.Stats()
        let partial = try infer(try eldernet("ok", extraArgs: ["--delay", "1"], jobBudget: 1.5), stats: &slow)
        XCTAssertTrue((1...2).contains(partial.gaitQuality.chunks), "\(partial.gaitQuality.chunks) chunks")
        XCTAssertEqual(partial.gaitQuality.responses.count, partial.gaitQuality.chunks, "answered chunks are kept")
        XCTAssertEqual(partial.gaitQuality.stopped, ActivityLane.jobTimeBudgetKind)
        XCTAssertEqual(slow.eldernetBudgetExhausted, 1)
        XCTAssertNotNil(partial.gaitQuality.trackInput, "what it answered is still stored")
        XCTAssertEqual(try hartPayloads(partial).v1, reference.v1)
        var normal = ActivityLane.Stats()
        let full = try infer(try eldernet("ok"), stats: &normal)
        XCTAssertEqual(full.gaitQuality.chunks, 3, "the default budget never binds on a normal job")
        XCTAssertNil(full.gaitQuality.stopped)
        XCTAssertEqual(normal.eldernetBudgetExhausted, 0)
    }

    func testAChildServingAnotherModelThanThePinnedOneIsRefusedAndCounted() throws {
        // At the start of the job (ping): another model version, or another weights digest.
        try assertIsolated("ok", kind: ElderNetStage.pinMismatchKind, chunks: 0, failed: 0, pinRefused: 1,
                           stage: try eldernet("ok", pinVersion: .some("eldernet-other")))
        try assertIsolated("ok", kind: ElderNetStage.pinMismatchKind, chunks: 0, failed: 0, pinRefused: 1,
                           stage: try eldernet("ok", pinDigest: .some(try digest("other"))))
        // Mid-job (an infer response names another model version): refused, and ElderNet stops for the job.
        var mid = ActivityLane.Stats()
        let midInferred = try infer(try eldernet("ok", pinVersion: .some(version),
                                                 extraArgs: ["--infer-model-version", "eldernet-other"]), stats: &mid)
        XCTAssertEqual(midInferred.gaitQuality.chunks, 1)
        XCTAssertEqual(midInferred.gaitQuality.failureKinds[ElderNetStage.pinMismatchKind], 1)
        XCTAssertEqual(midInferred.gaitQuality.stopped, ElderNetStage.pinMismatchKind)
        XCTAssertEqual(mid.eldernetPinRefused, 1)
        // The matching pins are accepted.
        var okStats = ActivityLane.Stats()
        let ok = try infer(try eldernet("ok", pinVersion: .some(version), pinDigest: .some(try digest())), stats: &okStats)
        XCTAssertEqual(ok.gaitQuality.responses.count, 3)
        XCTAssertEqual(okStats.eldernetPinRefused, 0)
        XCTAssertEqual(ok.gaitQuality.trackInput?.model.weightsDigest, try digest())
    }

    func testACrashAfterAGoodChunkKeepsTheGoodChunk() throws {
        var stats = ActivityLane.Stats()
        let inferred = try infer(try eldernet("ok_then_crash"), stats: &stats)
        XCTAssertEqual(inferred.gaitQuality.responses.count, 1)
        XCTAssertEqual(inferred.gaitQuality.stopped, "crash")
        XCTAssertEqual(inferred.gaitQuality.chunks, 2)
        XCTAssertEqual(stats.eldernetFailures, 1)
        XCTAssertEqual(try hartPayloads(inferred).v1, try baseline().v1)
    }

    // MARK: - Lease, cache, Inertia beside it

    func testTheLeaseIsRenewedBeforeEveryElderNetCallAndALostLeaseEndsTheJob() throws {
        var calls = 0
        var stats = ActivityLane.Stats()
        let both = try infer(try eldernet("ok"), inertia: try inertia(), stats: &stats, renew: { calls += 1; return true })
        XCTAssertEqual(calls, 11, "one renewal before each readiness check (Inertia, ElderNet) and before each HART, "
                       + "each Inertia and each ElderNet call")
        XCTAssertEqual(both.motionHeads.responses.count, 3, "Inertia unaffected by ElderNet beside it")
        XCTAssertEqual(both.gaitQuality.responses.count, 3)
        XCTAssertEqual(stats.eldernetChunks, 3)
        XCTAssertEqual(stats.inertiaChunks, 3)
        // The renewal before ElderNet's readiness check (start + ping, up to a request timeout) fails: the job ends
        // before ElderNet or HART is asked anything.
        calls = 0
        var early = ActivityLane.Stats()
        XCTAssertThrowsError(try infer(try eldernet("ok"), stats: &early, renew: { calls += 1; return false })) { error in
            XCTAssertEqual((error as? PostgresClient.Error)?.kind, .stale)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(early.eldernetUnavailable, 0, "the readiness check never ran")
        XCTAssertEqual(early.windowsInferred, 0)
        calls = 0
        var lost = ActivityLane.Stats()
        // Readiness (1), HART (2), ElderNet (3: refused): the job ends exactly as a lost lease before HART does.
        XCTAssertThrowsError(try infer(try eldernet("ok"), stats: &lost, renew: { calls += 1; return calls < 3 })) { error in
            let pg = error as? PostgresClient.Error
            XCTAssertEqual(pg?.kind, .stale)
            XCTAssertEqual(pg?.message, "activity lease lost during inference")
        }
        XCTAssertEqual(lost.eldernetChunks, 0, "no ElderNet call without a live lease")
    }

    /// A chunk whose HART answer comes from the on-host cache still gets its ElderNet call (with its own lease
    /// renewal first), so a day's shadow row is never partial because HART was cached.
    func testACachedHartChunkStillGetsItsElderNetCall() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try XCTUnwrap(ActivityLocalCache(path: directory.path))
        let hart = try hartService()
        _ = try hart.ping()
        var first = ActivityLane.Stats()
        var renewals = 0
        let filled = try ActivityLane.inferChunks(requests(), service: hart, inertia: nil, versions: versions(hart),
                                                  cache: cache, stats: &first, renew: { renewals += 1; return true })
        XCTAssertEqual(first.windowsInferred, 3)
        var second = ActivityLane.Stats()
        renewals = 0
        let cached = try ActivityLane.inferChunks(requests(), service: hart, inertia: nil, eldernet: try eldernet("ok"),
                                                  versions: versions(hart), cache: cache, stats: &second,
                                                  renew: { renewals += 1; return true })
        XCTAssertEqual(second.windowsInferred, 0, "HART is not re-inferred")
        XCTAssertEqual(second.windowsReused, 3)
        XCTAssertEqual(second.eldernetChunks, 3, "ElderNet still runs on every cached chunk")
        XCTAssertEqual(cached.gaitQuality.trackInput?.windows.count, 3 * 23, "the shadow row is complete")
        XCTAssertEqual(renewals, 4, "one before the readiness check and each ElderNet call, none for the cached HART answers")
        XCTAssertEqual(try hartPayloads(filled).v1, try hartPayloads(cached).v1)
        XCTAssertEqual(try hartPayloads(filled).v2, try hartPayloads(cached).v2)
    }

    /// The same day re-claimed after an upload moved its revision: a pinned stage answers the chunks it has
    /// already seen from its own memory, so only the new chunk costs a call and the job can publish in time.
    func testAPinnedStageAnswersARepeatedChunkWithoutCallingTheChild() throws {
        let stage = try eldernet("ok", pinVersion: .some(version), pinDigest: .some(try digest()))
        var first = ActivityLane.Stats()
        let filled = try infer(stage, stats: &first)
        XCTAssertEqual(first.eldernetChunksReused, 0)
        XCTAssertEqual(stage.responses.count, 3)
        var calls = 0
        var second = ActivityLane.Stats()
        let again = try infer(stage, stats: &second, renew: { calls += 1; return true })
        XCTAssertEqual(second.eldernetChunks, 3)
        XCTAssertEqual(second.eldernetChunksReused, 3)
        XCTAssertEqual(calls, 4, "the readiness check and the three HART calls; no ElderNet call")
        XCTAssertEqual(again.gaitQuality.responses, filled.gaitQuality.responses)
        XCTAssertEqual(again.gaitQuality.trackInput, filled.gaitQuality.trackInput)
        // Unpinned, the answer could come from any model: nothing is kept.
        let unpinned = try eldernet("ok")
        var stats = ActivityLane.Stats()
        _ = try infer(unpinned, stats: &stats)
        XCTAssertEqual(unpinned.responses.count, 0)
    }

    func testTheResponseCacheDropsTheOldestPastItsCapacity() {
        let cache = ElderNetResponseCache(capacity: 2)
        let model = GaitQualityModelInfo(modelVersion: "v", weights: [:], upstreamCommit: "c", hopS: 5)
        for k in ["a", "b", "c"] { cache.store(GaitQualityResponse(model: model, windows: []), key: k) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.response("a"))
        XCTAssertNotNil(cache.response("c"))
    }

    // MARK: - Shadow and candidate output

    func testShadowModeStoresCompactGaitWindowsAndLeavesTheHartPayloadsByteIdentical() throws {
        let reference = try baseline()
        var stats = ActivityLane.Stats()
        let inferred = try infer(try eldernet("ok"), stats: &stats)
        let payloads = try hartPayloads(inferred)
        XCTAssertEqual(payloads.v1, reference.v1)
        XCTAssertEqual(payloads.v2, reference.v2)
        let gait = try XCTUnwrap(inferred.gaitQuality.trackInput)
        XCTAssertEqual(gait.windows.count, 3 * 23, "10-s windows on a 5-s grid inside each 120-s chunk")
        XCTAssertEqual(stats.eldernetWindows, gait.windows.count)

        let context = ActivityLane.ContextDayBuild(built: nil, input: contextInput(), generatedAt: 1_789_500_000)
        let text = ActivityLane.gaitWindowsPayload(day: day, eldernet: try eldernet("ok"), collector: inferred.gaitQuality,
                                                   context: context, stats: &stats)
        let p = try payloadObject(text)
        XCTAssertEqual(p["day"] as? String, day)
        XCTAssertEqual(p["mode"] as? String, "shadow")
        XCTAssertEqual(p["schema"] as? String, "gait-quality-1")
        XCTAssertEqual(p["weights_digest"] as? String, try digest())
        XCTAssertTrue(p["candidate_document"] is NSNull)
        XCTAssertTrue(p["withheld_reason"] is NSNull)
        let model = try XCTUnwrap(p["model"] as? [String: Any])
        XCTAssertEqual(model["model_version"] as? String, version)
        XCTAssertEqual(model["model_id"] as? String, "eldernet")
        let summary = try XCTUnwrap(p["summary"] as? [String: Any])
        XCTAssertEqual(summary["n_windows"] as? Int, gait.windows.count)
        XCTAssertEqual(summary["n_gait"] as? Int, 3 * 15)
        XCTAssertEqual(summary["n_prefiltered"] as? Int, 3 * 4)
        XCTAssertEqual(summary["n_chunks"] as? Int, 3)
        XCTAssertTrue(summary["gait_prior"] is NSNull, "π is a candidate-mode setting")
        let metrics = try XCTUnwrap(summary["gait"] as? [String: Any])
        XCTAssertEqual(metrics["windows"] as? Int, 45)
        XCTAssertEqual(metrics["cadence_spm"] as? Double, 108)
        XCTAssertEqual(metrics["steps"] as? Double, 45 * 9, "hop-normalised steps")
        let report = try XCTUnwrap(summary["track_report"] as? [String: Any])
        XCTAssertEqual(report["windows_in"] as? Int, gait.windows.count)
        XCTAssertGreaterThan(report["attached"] as? Int ?? 0, 0)
        XCTAssertEqual(stats.eldernetWindowsAttached, report["attached"] as? Int)
        let windows = try XCTUnwrap(p["windows"] as? [String: Any])
        XCTAssertEqual(windows["format"] as? String, "gait-windows-1")
        XCTAssertEqual(windows["n"] as? Int, gait.windows.count)
        XCTAssertEqual(windows["w"] as? Int, 10)
        XCTAssertEqual(windows["h"] as? Int, 5)
        XCTAssertEqual(windows["s0"] as? Int, gait.windows[0].startTs)
        for key in ["ds", "gp", "g", "pf", "sp", "cad", "st", "rg", "stp"] {
            XCTAssertEqual((windows[key] as? [Int])?.count, gait.windows.count, key)
        }
        XCTAssertEqual((windows["g"] as? [Int])?.reduce(0, +), 45)
        XCTAssertEqual((windows["pf"] as? [Int])?.reduce(0, +), 12)
        XCTAssertEqual((windows["gp"] as? [Int])?.max(), 940, "per mille")
        XCTAssertEqual((windows["sp"] as? [Int])?.filter { $0 >= 0 }, Array(repeating: 121, count: 45), "cm/s on gait only")
        XCTAssertEqual((windows["stp"] as? [Int])?.max(), 180, "steps × 10")
        // Deterministic.
        var again = ActivityLane.Stats()
        XCTAssertEqual(text, ActivityLane.gaitWindowsPayload(day: day, eldernet: try eldernet("ok"),
                                                             collector: inferred.gaitQuality, context: context, stats: &again))
    }

    func testTheStoredWindowsAreCappedPerDay() throws {
        let model = GaitQualityModelInfo(modelVersion: version, weights: ["gait_detection": String(repeating: "a", count: 64)],
                                         upstreamCommit: "437a38bc", hopS: 1, gaitThreshold: 0.5)
        // A whole day of walking at a 1-s hop: far above the cap, so the columns are left out and the summary says so.
        let windows = (0..<86_000).map { k in
            GaitQualityWindow(startTs: dayStart + k, endTs: dayStart + k + 10, gaitProb: 0.97, isGait: true,
                              speedMps: 1.234, cadenceSpm: 112.5, strideM: 1.33, regularity: 0.77, steps: 18.5)
        }
        var c = GaitQualityCollector()
        c.responses = [GaitQualityResponse(model: model, windows: windows)]
        c.chunks = 1
        let p = try payloadObject(try ActivityGaitWindowsDays.payload(day: day, mode: .shadow, collector: c,
                                                                      candidate: .notRequested))
        XCTAssertTrue(p["windows"] is NSNull)
        XCTAssertEqual((p["summary"] as? [String: Any])?["windows_omitted"] as? Bool, true)
        // A whole worn day at a 5-s hop with a couple of hours of walking fits.
        var fiveSecond = model
        fiveSecond.hopS = 5
        let worn = (0..<17_280).map { k -> GaitQualityWindow in
            let s = dayStart + 5 * k
            if k % 10 == 0 {
                return GaitQualityWindow(startTs: s, endTs: s + 10, gaitProb: 0.97, isGait: true, speedMps: 1.234,
                                         cadenceSpm: 112.5, strideM: 1.33, regularity: 0.77, steps: 18.5)
            }
            return k % 2 == 0 ? GaitQualityWindow(startTs: s, endTs: s + 10, gaitProb: 0, isGait: false, prefiltered: true)
                : GaitQualityWindow(startTs: s, endTs: s + 10, gaitProb: 0.123, isGait: false)
        }
        let compact = ActivityGaitWindowsDays.compact(worn, model: fiveSecond)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        XCTAssertLessThanOrEqual(try e.encode(compact).count, ActivityGaitWindowsDays.maxWindowsBytes)
        XCTAssertEqual(ActivityGaitWindowsDays.scaled(.infinity, 100, 0...2), -1)
        XCTAssertEqual(ActivityGaitWindowsDays.scaled(5, 100, 0...2), 200, "clamped, never trapped")
    }

    func testCandidateModeWithPinsStoresTheComparisonBesideAnUnchangedPublication() throws {
        let reference = try baseline()
        var stats = ActivityLane.Stats()
        let stage = try eldernet("ok", mode: .candidate)
        let inferred = try infer(stage, stats: &stats)
        let payloads = try hartPayloads(inferred)
        XCTAssertEqual(payloads.v1, reference.v1)
        XCTAssertEqual(payloads.v2, reference.v2, "the published v2 document never sees ElderNet")
        let gait = try XCTUnwrap(inferred.gaitQuality.trackInput)
        let input = contextInput()
        let candidate = ActivityGaitWindowsDays.candidate(mode: .candidate, gait: gait, input: input,
                                                          generatedAt: 1_789_500_000, expectedModelVersion: version,
                                                          expectedWeightsDigest: try digest(), gaitPrior: 0.2)
        guard case .document(let doc, let report) = candidate else { return XCTFail("expected a document, got \(candidate)") }
        XCTAssertGreaterThan(report?.attached ?? 0, 0)
        XCTAssertEqual((report?.attached ?? 0) + (report?.dropped ?? 0), gait.windows.count)
        let stamp = try XCTUnwrap(doc.versions.gaitQuality)
        XCTAssertEqual(report?.stamp, stamp)
        XCTAssertTrue(stamp.hasPrefix("eldernet:\(version):\(try digest().prefix(12)):"), stamp)
        XCTAssertNil(doc.snapshot)
        XCTAssertNil(doc.versions.motionHeads)
        let published = ActivityContextDays.dayDocument(input: input, generatedAt: 1_789_500_000)
        XCTAssertNil(published.versions.gaitQuality)
        XCTAssertEqual(doc.observedSeconds, published.observedSeconds, "the same seconds, decoded a second time")

        let context = ActivityLane.ContextDayBuild(built: nil, input: input, generatedAt: 1_789_500_000)
        let p = try payloadObject(ActivityLane.gaitWindowsPayload(day: day, eldernet: stage, collector: inferred.gaitQuality,
                                                                  context: context, stats: &stats))
        XCTAssertTrue(p["withheld_reason"] is NSNull)
        let stored = try XCTUnwrap(p["candidate_document"] as? [String: Any])
        XCTAssertEqual((stored["versions"] as? [String: Any])?["gait_quality"] as? String, stamp)
        XCTAssertEqual((p["summary"] as? [String: Any])?["candidate_stamp"] as? String, stamp)
        XCTAssertEqual((p["summary"] as? [String: Any])?["gait_prior"] as? Double, 0.2)
        XCTAssertEqual(stats.eldernetCandidateDocuments, 1)
    }

    func testACandidateWithoutPinsOrPriorOrWithAnotherModelIsWithheld() throws {
        var stats = ActivityLane.Stats()
        let gait = try XCTUnwrap(try infer(try eldernet("ok"), stats: &stats).gaitQuality.trackInput)
        func withheld(_ c: ActivityGaitWindowsDays.Candidate) -> String? {
            if case .withheld(let why) = c { return why }
            return nil
        }
        let d = try digest()
        XCTAssertEqual(withheld(ActivityGaitWindowsDays.candidate(
            mode: .candidate, gait: gait, input: contextInput(), generatedAt: 1, expectedModelVersion: nil,
            expectedWeightsDigest: d, gaitPrior: 0.2)), "model_not_pinned")
        XCTAssertEqual(withheld(ActivityGaitWindowsDays.candidate(
            mode: .candidate, gait: gait, input: contextInput(), generatedAt: 1, expectedModelVersion: version,
            expectedWeightsDigest: d, gaitPrior: nil)), "gait_prior_not_set")
        XCTAssertEqual(withheld(ActivityGaitWindowsDays.candidate(
            mode: .candidate, gait: gait, input: contextInput(), generatedAt: 1, expectedModelVersion: version,
            expectedWeightsDigest: try digest("other"), gaitPrior: 0.2)), "weights_digest_mismatch")
        XCTAssertEqual(withheld(ActivityGaitWindowsDays.candidate(
            mode: .candidate, gait: gait, input: nil, generatedAt: 1, expectedModelVersion: version,
            expectedWeightsDigest: d, gaitPrior: 0.2)), "context_days_disabled")
        guard case .notRequested = ActivityGaitWindowsDays.candidate(
            mode: .shadow, gait: gait, input: contextInput(), generatedAt: 1, expectedModelVersion: version,
            expectedWeightsDigest: d, gaitPrior: 0.2) else { return XCTFail("shadow mode never decodes a second time") }
        // The lane counts a withheld comparison and stores the reason.
        let unpinned = ElderNetStage(service: try eldernet("ok").service, mode: .candidate, gaitPrior: 0.2)
        var c = ActivityLane.Stats()
        var collector = GaitQualityCollector()
        collector.responses = [GaitQualityResponse(model: gait.model, windows: gait.windows)]
        let p = try payloadObject(ActivityLane.gaitWindowsPayload(
            day: day, eldernet: unpinned, collector: collector,
            context: ActivityLane.ContextDayBuild(built: nil, input: contextInput(), generatedAt: 1), stats: &c))
        XCTAssertEqual(p["withheld_reason"] as? String, "model_not_pinned")
        XCTAssertEqual(c.eldernetCandidateWithheld, 1)
        XCTAssertEqual(c.lastElderNetWithheldReason, "model_not_pinned")
    }
}
