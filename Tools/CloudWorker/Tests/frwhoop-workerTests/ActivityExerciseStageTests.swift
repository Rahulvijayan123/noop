import XCTest
import StrandAnalytics
@testable import frwhoop_worker

/// The RecGym exercise stage of the activity lane against stub services (no torch, no model, no database):
/// configuration (shadow only), the strict response decoder, failure isolation, pins, the answer and publish caches,
/// the payload (shadow-only authority, day clipping) and that the HART output is byte-identical whatever the stage
/// does. The SQL side is `supabase/functions/tests/activity_exercise_windows_contract.sql`; the two together are
/// `ActivityExerciseWindowsDatabaseTests`.
final class ActivityExerciseStageTests: XCTestCase {

    private let dayStart = 1_789_430_400          // 2026-09-15 00:00:00 UTC
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"
    private let pin = "7f0c4adf066bb842eeb0c114e765fd3cf1ca3a7ca6ef6cf5344f5f142651f5d9"
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

    private func exercise(_ behaviour: String = "ok", timeout: Double = 5, pinVersion: String? = nil,
                          pinSHA: String? = nil, extraArgs: [String] = [],
                          jobBudget: Double = ExerciseSettings.defaultJobBudgetSeconds) throws -> ExerciseStage {
        guard let path = stub("stub_exercise_service.py") else { throw XCTSkip("stub_exercise_service.py not found") }
        let settings = ExerciseSettings.fromEnvironment([
            "FRWHOOP_EXERCISE_ENABLED": "1", "FRWHOOP_EXERCISE_WEIGHTS_PATH": "/opt/frwhoop-models/current/recgym",
            "FRWHOOP_EXERCISE_TIMEOUT_SECONDS": String(timeout)], activityPython: "/usr/bin/python3")
        var config = try XCTUnwrap(settings.serviceConfig(activityHome: FileManager.default.currentDirectoryPath))
        config.serveArgs = [path, "--behaviour", behaviour, "--sleep", "30"] + extraArgs
        let s = ActivityPythonService(config: config)
        services.append(s)
        return ExerciseStage(service: s, expectedModelVersion: pinVersion, expectedWeightsSHA256: pinSHA,
                             jobBudgetSeconds: jobBudget)
    }

    /// Three 2-minute chunks inside the day (column payloads are not inspected by the stubs).
    private func requests(offset: Int = 36_000) -> [ActivityPythonService.RunRequest] {
        let t0 = dayStart + offset
        let column = Data(repeating: 0, count: 1200).base64EncodedString()
        return (0..<3).map { i in
            ActivityPythonService.RunRequest(startTs: t0 + i * 120, endTs: t0 + (i + 1) * 120,
                                             columnsB64: Array(repeating: column, count: 120), headB64: [], tailB64: [])
        }
    }

    private func infer(_ exercise: ExerciseStage?, stats: inout ActivityLane.Stats,
                       requests reqs: [ActivityPythonService.RunRequest]? = nil, device: String = "dev-1",
                       renew: () throws -> Bool = { true }) throws -> ActivityLane.ChunkInference {
        try ActivityLane.inferChunks(reqs ?? requests(), service: try hartService(), inertia: nil, eldernet: nil,
                                     exercise: exercise, device: device,
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

    private func job() -> ActivityLane.ActivityJob {
        ActivityLane.ActivityJob(userId: "u", deviceId: "dev-1", day: day, algorithmVersion: "hart-activity-1",
                                 objectIds: [], digests: [], fingerprint: String(repeating: "f", count: 64),
                                 inputRevision: 9, leaseToken: "t")
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - Configuration

    func testTheHeadIsOffUnlessEnabledWithACheckpointAndRunsInShadowOnly() {
        XCTAssertFalse(ExerciseSettings.fromEnvironment([:]).enabled)
        XCTAssertNil(ExerciseSettings.fromEnvironment([:]).serviceConfig(activityHome: "/x"))
        XCTAssertNil(ExerciseSettings.fromEnvironment([:]).configurationError, "unset is plainly off")
        let noPath = ExerciseSettings.fromEnvironment(["FRWHOOP_EXERCISE_ENABLED": "1"])
        XCTAssertFalse(noPath.enabled)
        XCTAssertNotNil(noPath.configurationError)
        for mode in ["candidate", "production", "on"] {
            let s = ExerciseSettings.fromEnvironment(["FRWHOOP_EXERCISE_ENABLED": "1", "FRWHOOP_EXERCISE_MODE": mode,
                                                      "FRWHOOP_EXERCISE_WEIGHTS_PATH": "/w.pt"])
            XCTAssertFalse(s.enabled, mode)
            XCTAssertTrue(s.configurationError?.contains("shadow only") ?? false, mode)
        }
        let shadow = ExerciseSettings.fromEnvironment(["FRWHOOP_EXERCISE_ENABLED": "yes", "FRWHOOP_EXERCISE_MODE": "Shadow",
                                                       "FRWHOOP_EXERCISE_WEIGHTS_PATH": "/w.pt"])
        XCTAssertTrue(shadow.enabled)
        XCTAssertEqual(shadow.retentionDays, 14)
        XCTAssertEqual(shadow.jobBudgetSeconds, 300)
        let bad = ExerciseSettings.fromEnvironment(["FRWHOOP_EXERCISE_ENABLED": "maybe", "FRWHOOP_EXERCISE_WEIGHTS_PATH": "/w"])
        XCTAssertFalse(bad.enabled)
        XCTAssertNotNil(bad.configurationError)
        for (key, value) in [("FRWHOOP_EXERCISE_WEIGHTS_SHA256", "abc"), ("FRWHOOP_EXERCISE_THREADS", "0"),
                             ("FRWHOOP_EXERCISE_RETENTION_DAYS", "0"), ("FRWHOOP_EXERCISE_MODEL_VERSION", "bad version"),
                             ("FRWHOOP_EXERCISE_TIMEOUT_SECONDS", "-1")] {
            let s = ExerciseSettings.fromEnvironment(["FRWHOOP_EXERCISE_ENABLED": "1",
                                                      "FRWHOOP_EXERCISE_WEIGHTS_PATH": "/w.pt", key: value])
            XCTAssertFalse(s.enabled, key)
            XCTAssertNotNil(s.configurationError, key)
        }
    }

    func testTheChildIsItsOwnProcessAndItsTimeoutFitsTheLease() throws {
        let s = ExerciseSettings.fromEnvironment([
            "FRWHOOP_EXERCISE_ENABLED": "1", "FRWHOOP_EXERCISE_WEIGHTS_PATH": "/opt/m/w.pt",
            "FRWHOOP_EXERCISE_TIMEOUT_SECONDS": "500", "FRWHOOP_EXERCISE_THREADS": "2",
            "FRWHOOP_EXERCISE_PYTHON": "/venv/bin/python",
            "FRWHOOP_EXERCISE_WEIGHTS_SHA256": pin.uppercased()], activityPython: "/usr/bin/python3", leaseSeconds: 300)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.timeoutSeconds, 100, "clamped to a third of the lease")
        XCTAssertEqual(s.warnings.count, 1)
        XCTAssertEqual(s.weightsSHA256, pin)
        let config = try XCTUnwrap(s.serviceConfig(activityHome: "/opt/noop/current/Tools/ActivityContext"))
        XCTAssertEqual(config.pythonBin, "/venv/bin/python")
        XCTAssertEqual(config.serveArgs, ["-m", "activity_context.recgym.serve", "--weights-path", "/opt/m/w.pt",
                                          "--timeout", "95", "--threads", "2"])
        XCTAssertEqual(config.numericalThreads, 2)
        XCTAssertEqual(config.requestTimeoutSeconds, 100)
        XCTAssertTrue(ActivityPythonService.unavailableModelStatuses.contains("recgym_unavailable"))
    }

    // MARK: - Decoder

    private func response(_ edit: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var obj: [String: Any] = [
            "ok": true, "schema": "exercise-windows-1", "model_id": "recgym-cnn-transformer",
            "model_version": "recgym-cnn-transformer-e085ac0", "weights_sha256": pin,
            "scaler_version": "recgym-wrist-imu-scaler-1", "preprocessing_version": "recgym-prep-1",
            "classes": ExerciseWire.classes, "window_s": 4, "hop_s": 2, "n_dropped_nonfinite": 0,
            "windows": [["s": 100, "e": 104, "p": [0.01, 0.01, 0.86, 0.01, 0.01, 0.03, 0.01, 0.01, 0.01, 0.02, 0.01, 0.01],
                         "input_sha256": String(repeating: "a", count: 64)]]]
        edit(&obj)
        return obj
    }

    private func kind(_ obj: [String: Any]) -> String? {
        do { _ = try ExerciseResponse.decode(obj); return nil } catch let e as ExerciseResponseError { return e.kind }
        catch { return "other" }
    }

    func testTheDecoderAcceptsTheContractAndRefusesEverythingElse() throws {
        let ok = try ExerciseResponse.decode(response())
        XCTAssertEqual(ok.windows.count, 1)
        XCTAssertEqual(ok.windows[0].start, 100)
        XCTAssertEqual(ok.model.weightsSHA256, pin)
        XCTAssertEqual(kind(["ok": false, "kind": "weights_mismatch", "error": "x"]), "weights_mismatch")
        XCTAssertEqual(kind(response { $0["schema"] = "exercise-windows-2" }), "schema")
        XCTAssertEqual(kind(response { $0["classes"] = Array(ExerciseWire.classes.reversed()) }), "schema")
        XCTAssertEqual(kind(response { $0["window_s"] = 10 }), "schema")
        XCTAssertEqual(kind(response { $0["weights_sha256"] = "xyz" }), "schema")
        func window(_ w: [String: Any]) -> (inout [String: Any]) -> Void {
            { obj in
                var base = (obj["windows"] as! [[String: Any]])[0]
                for (k, v) in w { base[k] = v }
                obj["windows"] = [base]
            }
        }
        XCTAssertEqual(kind(response(window(["s": 101, "e": 105]))), "invalid_values", "odd start")
        XCTAssertEqual(kind(response(window(["e": 110]))), "invalid_values", "not 4 s")
        XCTAssertEqual(kind(response(window(["p": [0.5, 0.5]]))), "invalid_values", "twelve probabilities")
        XCTAssertEqual(kind(response(window(["p": [0.6, 0.01, 0.86, 0.01, 0.01, 0.03, 0.01, 0.01, 0.01, 0.02, 0.01, 0.01]]))),
                       "invalid_values", "sum")
        XCTAssertEqual(kind(response(window(["input_sha256": "x"]))), "invalid_values")
        XCTAssertEqual(kind(response { $0["windows"] = [["s": 100]] }), "schema")
        XCTAssertThrowsError(try ExerciseResponse.decode(Data("{\"ok\":true,\"p\":[NaN]}".utf8))) { e in
            XCTAssertEqual((e as? ExerciseResponseError)?.kind, "nonfinite")
        }
    }

    // MARK: - Lane isolation

    func testWindowsArriveForEveryChunkAndTheHartJobIsByteIdentical() throws {
        let reference = try baseline()
        var stats = ActivityLane.Stats()
        let inferred = try infer(try exercise(), stats: &stats)
        let payloads = try hartPayloads(inferred)
        XCTAssertEqual(payloads.v1, reference.v1)
        XCTAssertEqual(payloads.v2, reference.v2)
        XCTAssertEqual(inferred.exercise.answered.count, 3)
        XCTAssertEqual(inferred.exercise.chunks, 3)
        XCTAssertNil(inferred.exercise.stopped)
        XCTAssertEqual(stats.exerciseJobs, 1)
        XCTAssertEqual(stats.exerciseWindows, inferred.exercise.answered.reduce(0) { $0 + $1.response.windows.count })
        XCTAssertGreaterThan(stats.exerciseWindows, 100)
        XCTAssertTrue(inferred.exercise.answered.allSatisfy { $0.key != nil }, "the stub reports a measured identity")
    }

    private func assertIsolated(_ behaviour: String, kind expectedKind: String, chunks: Int, failed: Int,
                                unavailable: Int = 0, pinRefused: Int = 0, stage: ExerciseStage? = nil,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let reference = try baseline()
        var stats = ActivityLane.Stats()
        let started = Date()
        let inferred = try infer(try stage ?? exercise(behaviour, timeout: 1), stats: &stats)
        let payloads = try hartPayloads(inferred)
        XCTAssertEqual(payloads.v1, reference.v1, "\(behaviour): v1 payload", file: file, line: line)
        XCTAssertEqual(payloads.v2, reference.v2, "\(behaviour): v2 payload", file: file, line: line)
        XCTAssertEqual(stats.windowsInferred, 3, file: file, line: line)
        XCTAssertEqual(inferred.exercise.chunks, chunks, "\(behaviour): chunks asked", file: file, line: line)
        XCTAssertEqual(inferred.exercise.failedChunks, failed, file: file, line: line)
        XCTAssertEqual(stats.exerciseFailures, failed, file: file, line: line)
        XCTAssertEqual(stats.exerciseUnavailable, unavailable, file: file, line: line)
        XCTAssertEqual(stats.exercisePinRefused, pinRefused, file: file, line: line)
        XCTAssertEqual(stats.lastExerciseErrorKind, expectedKind, stats.lastExerciseError ?? "", file: file, line: line)
        XCTAssertNil(stats.lastError, "the HART path saw no error", file: file, line: line)
        XCTAssertTrue(inferred.exercise.answered.isEmpty, "\(behaviour): nothing valid to store", file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "\(behaviour): at most one timeout per job",
                          file: file, line: line)
    }

    func testAMissingOrMismatchedCheckpointNeverTouchesTheHartJob() throws {
        try assertIsolated("model_missing", kind: "model_unavailable", chunks: 0, failed: 0, unavailable: 1)
        try assertIsolated("weights_mismatch", kind: "model_unavailable", chunks: 0, failed: 0, unavailable: 1)
    }

    func testATimeoutCrashOrRepeatingRefusalStopsTheHeadForTheJob() throws {
        try assertIsolated("timeout", kind: "timeout", chunks: 1, failed: 1)
        try assertIsolated("crash", kind: "crash", chunks: 1, failed: 1)
        try assertIsolated("schema", kind: "schema", chunks: 1, failed: 1)
        try assertIsolated("classes", kind: "schema", chunks: 1, failed: 1)
        try assertIsolated("bad_probs", kind: "invalid_values", chunks: 1, failed: 1)
    }

    func testANaNLineOrAnInternalAnswerCostsOneChunkEach() throws {
        try assertIsolated("nan", kind: "malformed_json", chunks: 3, failed: 3)
        try assertIsolated("internal", kind: "internal", chunks: 3, failed: 3)
        XCTAssertTrue(ExerciseStage.stoppingServiceKinds.isDisjoint(with: ["nonfinite", "malformed_json", "internal"]))
    }

    func testAChildServingAnotherCheckpointThanThePinnedOneIsRefused() throws {
        // The pin is checked against what the child measured it loaded, at the start of the job.
        try assertIsolated("ok", kind: ExerciseStage.pinMismatchKind, chunks: 0, failed: 0, pinRefused: 1,
                           stage: try exercise("ok", pinSHA: pin, extraArgs: ["--weights-sha", String(repeating: "c", count: 64)]))
        try assertIsolated("ok", kind: ExerciseStage.pinMismatchKind, chunks: 0, failed: 0, pinRefused: 1,
                           stage: try exercise("ok", pinVersion: "recgym-cnn-transformer-0000000"))
        var stats = ActivityLane.Stats()
        let pinned = try infer(try exercise("ok", pinVersion: "recgym-cnn-transformer-e085ac0", pinSHA: pin), stats: &stats)
        XCTAssertEqual(pinned.exercise.answered.count, 3, "the pinned checkpoint is served")
    }

    func testTheHeadStopsOnceItsTimeBudgetIsUsedAndALostLeaseEndsTheJob() throws {
        var stats = ActivityLane.Stats()
        let skipped = try infer(try exercise("ok", jobBudget: 1e-9), stats: &stats)
        XCTAssertEqual(skipped.exercise.chunks, 0)
        XCTAssertEqual(skipped.exercise.stopped, ActivityLane.jobTimeBudgetKind)
        XCTAssertEqual(stats.exerciseBudgetExhausted, 1)
        XCTAssertEqual(stats.exerciseFailures, 0)
        // Every renewal fails after HART's own (the first call of each chunk is HART's): the job ends, as for HART.
        var calls = 0
        var lost = ActivityLane.Stats()
        XCTAssertThrowsError(try infer(try exercise(), stats: &lost, renew: {
            calls += 1
            return calls <= 2
        }))
    }

    // MARK: - Answer and publish caches

    func testAnAnsweredChunkIsNotAskedAgainAndAPublishedOneIsNotSentAgain() throws {
        let stage = try exercise()
        var first = ActivityLane.Stats()
        let one = try infer(stage, stats: &first)
        XCTAssertEqual(first.exerciseChunksReused, 0)
        var second = ActivityLane.Stats()
        let two = try infer(stage, stats: &second)
        XCTAssertEqual(second.exerciseChunksReused, 3, "the same requests and child: answered from the cache")
        XCTAssertEqual(two.exercise.answered, one.exercise.answered)

        let built = try XCTUnwrap(try ActivityExerciseWindows.payload(
            day: day, dayBounds: (dayStart, dayEnd), device: "dev-1", inputRevision: 9, collector: two.exercise,
            stage: stage))
        XCTAssertEqual(built.chunks, 3)
        XCTAssertEqual(built.publishedKeys.count, 3)
        // What publishDay does after its commit:
        for key in built.publishedKeys { stage.published.store(true, key: key) }
        var third = ActivityLane.Stats()
        let three = try infer(stage, stats: &third)
        XCTAssertEqual(third.exerciseChunksAlreadyPublished, 3)
        XCTAssertEqual(three.exercise.chunks, 0, "nothing asked")
        XCTAssertNil(try ActivityExerciseWindows.payload(day: day, dayBounds: (dayStart, dayEnd), device: "dev-1",
                                                         inputRevision: 10, collector: three.exercise, stage: stage),
                     "nothing new to send")
        // Another device's identical chunks are its own.
        var other = ActivityLane.Stats()
        _ = try infer(stage, stats: &other, device: "dev-2")
        XCTAssertEqual(other.exerciseChunksAlreadyPublished, 0)
        // A child without a measured identity: no cache key, every chunk asked and sent.
        var bare = ActivityLane.Stats()
        let noLoaded = try infer(try exercise("ok", extraArgs: ["--no-loaded"]), stats: &bare)
        XCTAssertTrue(noLoaded.exercise.answered.allSatisfy { $0.key == nil })
    }

    // MARK: - Payload

    func testThePayloadIsShadowOnlyClippedToTheDayAndInTimeOrder() throws {
        let stage = try exercise()
        var stats = ActivityLane.Stats()
        // The last chunk crosses midnight: its windows after the day end are left out, its span clipped.
        let late = requests(offset: 86_400 - 250)
        let inferred = try infer(stage, stats: &stats, requests: late)
        let built = try XCTUnwrap(try ActivityExerciseWindows.payload(
            day: day, dayBounds: (dayStart, dayEnd), device: "dev-1", inputRevision: 9, collector: inferred.exercise,
            stage: stage))
        let obj = try object(built.text)
        XCTAssertEqual(obj["day"] as? String, day)
        XCTAssertEqual(obj["schema"] as? String, "exercise-windows-1")
        let model = try XCTUnwrap(obj["model"] as? [String: Any])
        XCTAssertEqual(model["model_id"] as? String, "recgym-cnn-transformer")
        XCTAssertEqual(model["classes"] as? [String], ExerciseWire.classes)
        XCTAssertEqual(model["window_s"] as? Int, 4)
        let authority = try XCTUnwrap(obj["authority"] as? [String: Any])
        XCTAssertEqual(authority["channel"] as? String, "exercise_recognition")
        XCTAssertEqual(authority["mode"] as? String, "shadow")
        XCTAssertEqual(authority["release_mode"] as? String, "shadow")
        XCTAssertEqual(authority["use"] as? String, "none")
        XCTAssertEqual(authority["input_revision"] as? String, "9")
        let spans = try XCTUnwrap(obj["spans"] as? [[Int]])
        XCTAssertEqual(spans.count, 3)
        XCTAssertTrue(spans.allSatisfy { $0[0] >= dayStart && $0[1] <= dayEnd && $0[0] < $0[1] })
        XCTAssertEqual(spans.last?[1], dayEnd)
        let windows = try XCTUnwrap(obj["windows"] as? [[String: Any]])
        let starts = windows.compactMap { $0["s"] as? Int }
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertEqual(Set(starts).count, starts.count)
        XCTAssertTrue(starts.allSatisfy { $0 % 2 == 0 && $0 >= dayStart && $0 + 4 <= dayEnd })
        XCTAssertEqual(built.windows, windows.count)
        XCTAssertTrue(windows.allSatisfy { ($0["p"] as? [Double])?.count == 12 && ($0["fp"] as? String)?.count == 64 })
        // Nothing answered: no payload.
        XCTAssertNil(try ActivityExerciseWindows.payload(day: day, dayBounds: (dayStart, dayEnd), device: "dev-1",
                                                         inputRevision: 9, collector: ExerciseCollector(), stage: stage))
    }

    func testTheHeartbeatIdentityNamesTheChildAndItsShadowMode() throws {
        let stage = try exercise()
        XCTAssertNil(stage.begin())
        let identity = ActivityLane.identity(service: try hartService(), inertia: nil, eldernet: nil, selectionDigest: nil,
                                             exercise: stage)
        XCTAssertEqual(identity["recgym.mode"], "shadow")
        XCTAssertEqual(identity["recgym.weights_sha256"], pin)
        XCTAssertNotNil(identity["recgym.loaded_digest"])
        XCTAssertNil(ActivityLane.identity(service: try hartService(), inertia: nil, eldernet: nil,
                                           selectionDigest: nil)["recgym.mode"])
    }
}
