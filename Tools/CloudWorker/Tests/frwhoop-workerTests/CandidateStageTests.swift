import XCTest
import WhoopProtocol
@testable import frwhoop_worker

/// CandidateStage: off-mode no-op, the closed failure taxonomy as SETTLED
/// candidates, bounded retry, idempotent replay, the stale-debt and deleted-user
/// skips, the per-drain budget, and the (unreachable-by-default) active plumbing.
/// The store is a fake and the sidecar is a real 127.0.0.1 stub.
final class CandidateStageTests: XCTestCase {

    // MARK: - Fakes

    final class FakeCandidateStore: CandidateStore {
        var selection: [String: SelectedProvider] = [:]
        var debt: Date?
        var live = true
        var selectionError: Error?
        var debtError: Error?
        var ownerError: Error?
        var recordError: Error?
        var ownerChecks = 0
        var recorded: [CandidateRecord] = []
        private var seenKeys = Set<String>()

        func selectedProvider(userId: String, metric: String) throws -> SelectedProvider? {
            if let selectionError { throw selectionError }
            return selection[metric]
        }

        func candidateDebtInvalidatedAt(userId: String, deviceId: String, day: String) throws -> Date? {
            if let debtError { throw debtError }
            return debt
        }

        func candidateOwnerIsLive(userId: String, deviceId: String) throws -> Bool {
            ownerChecks += 1
            if let ownerError { throw ownerError }
            return live
        }

        func recordCandidate(_ record: CandidateRecord) throws -> String? {
            if let recordError { throw recordError }
            // Mirrors the DB contract: UNIQUE + ON CONFLICT DO NOTHING, so a
            // replay of the same inputs returns NULL and writes nothing new.
            if seenKeys.contains(record.idempotencyKey) { return nil }
            seenKeys.insert(record.idempotencyKey)
            recorded.append(record)
            return UUID().uuidString.lowercased()
        }
    }

    private func selection(_ mode: String, provider: String = "production.runs.v1") -> SelectedProvider {
        SelectedProvider(providerId: provider, providerVersion: "1.0.0",
                         configVersion: "cfg-1", mode: mode)
    }

    private func inputs(beats: [RRInterval], intervalStart: Int = 1_772_006_400,
                        intervalEnd: Int = 1_772_035_200,
                        claimSealedAt: Date = Date()) -> DayScorer.CandidateInputs {
        let deduped = DayScorer.dedupByObservationIdentity(beats)
        return DayScorer.CandidateInputs(
            userId: "11111111-1111-5111-8111-111111111111",
            deviceId: "22222222-2222-5222-8222-222222222222",
            day: "2026-10-01", inputRevision: 7,
            intervalStart: intervalStart, intervalEnd: intervalEnd,
            claimSealedAt: claimSealedAt, status: "available",
            canonicalAvgHrv: 48.0, canonicalSdnn: 61.0,
            profileVersion: nil, correctionsVersion: nil,
            hrvBeats: DayScorer.candidateBeats(deduped),
            hrvInputRows: beats.count,
            hrvTimestampResolution: "whole_seconds")
    }

    private func claim() -> DayScorer.Claim {
        DayScorer.Claim(userId: "11111111-1111-5111-8111-111111111111",
                        deviceId: "22222222-2222-5222-8222-222222222222",
                        day: "2026-10-01", timezoneId: "America/New_York",
                        inputRevision: 7, leaseToken: UUID().uuidString.lowercased(),
                        runId: UUID().uuidString.lowercased(), measurementRevision: 0)
    }

    private func sampleBeats(_ count: Int = 40) -> [RRInterval] {
        (0..<count).map { index in
            RRInterval(ts: 1_772_006_400 + index, rrMs: 800 + (index % 7),
                       srcChannel: .whoop5Historical, ord: index, seq: index)
        }
    }

    private static let okBody = """
        {"status":"ok","metric":"hrv","provider_id":"production.runs.v1",
         "versions":{"adapter":"frwhoop.hrv.rmssd/1","preprocessing":"pp/1","dependency":"nk/0.2.13",
                     "config":"cfg-1","model":null},
         "input":{"sha256":"abc"},"result":{"value":42.5,"unit":"ms"},
         "final_or_provisional":"provisional","coverage":{"pairs":30},"runtime_ms":37}
        """

    private func stage(server: StubHTTPServer, store: FakeCandidateStore,
                       timeoutMS: Int = 5_000, maxAttempts: Int = 2) -> CandidateStage {
        let client = InferenceClient(baseURL: URL(string: server.baseURL)!, timeoutMS: timeoutMS)
        return CandidateStage(client: client, store: store, maxAttempts: maxAttempts)
    }

    // MARK: - Off mode

    func testOffModeMakesZeroCallsAndZeroWrites() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("off")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))

        XCTAssertEqual(server.requestCount, 0, "mode=off must not call the sidecar")
        XCTAssertTrue(store.recorded.isEmpty, "mode=off must not write a candidate")
        // hrv is explicitly `off`; the other three have no row at all, which also
        // resolves to `off`, so all four metrics are skipped.
        XCTAssertEqual(subject.stats.skippedOff, 4)
        XCTAssertEqual(subject.stats.runs, 0)
    }

    func testUnconfiguredMetricIsSkippedWithoutCalling() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()   // nothing configured at all
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertEqual(subject.stats.skippedOff, 4, "all four metrics are off")
    }

    func testMetricWithoutInputAssemblyIsSkipped() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["sleep_stage"] = selection("shadow", provider: "no_eeg_sleep_staging")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(server.requestCount, 0, "no input assembly => no call")
        XCTAssertEqual(subject.stats.skippedNoInput, 1)
    }

    // MARK: - Shadow write

    func testShadowOKRecordsACandidate() throws {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        let input = inputs(beats: sampleBeats())
        subject.run(claim: claim(), inputs: input)

        XCTAssertEqual(server.requestCount, 1)
        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.status, "ok")
        XCTAssertEqual(record.value, 42.5)
        XCTAssertEqual(record.unit, "ms")
        XCTAssertEqual(record.mode, "shadow")
        XCTAssertEqual(record.metric, "hrv")
        XCTAssertEqual(record.periodDay, "2026-10-01")
        XCTAssertEqual(record.providerId, "production.runs.v1")
        XCTAssertEqual(record.dependencyVersions["dependency"], "nk/0.2.13")
        XCTAssertEqual(record.inputRevision, 7, "the record RPC guard param is the claim revision")
        XCTAssertEqual(record.inputSHA256, try InferenceClient.inputDigest(try XCTUnwrap(input.input(for: "hrv"))))
        XCTAssertNil(record.withheldReason)
        XCTAssertEqual(subject.stats.recorded, 1)
        XCTAssertEqual(subject.stats.ok, 1)
    }

    func testReplayIsIdempotent() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        let input = inputs(beats: sampleBeats())

        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: input)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: input)

        XCTAssertEqual(server.requestCount, 2, "the replay still computes once per drain")
        XCTAssertEqual(store.recorded.count, 1, "the second write must not add a row")
        XCTAssertEqual(subject.stats.recorded, 1)
        XCTAssertEqual(subject.stats.duplicates, 1, "the store reported the row as already present")
    }

    func testCandidateDebtOlderThanTheClaimDoesNotSkip() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        store.debt = Date().addingTimeInterval(-600)
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(subject.stats.skippedStaleDebt, 0)
        XCTAssertEqual(server.requestCount, 1)
    }

    // MARK: - Failure taxonomy as settled candidates

    func testRefusedIsSettledAsWithheldProviderError() throws {
        let url = "http://127.0.0.1:\(closedLoopbackPort())"
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        let client = InferenceClient(baseURL: URL(string: url)!, timeoutMS: 2_000)
        var subject = CandidateStage(client: client, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))

        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.status, "withheld")
        XCTAssertEqual(record.withheldReason, "provider_error")
        XCTAssertNil(record.value)
        XCTAssertEqual(subject.stats.withheld, 1)
        XCTAssertEqual(subject.stats.calls, 2, "a refused connection is retried once, then settled")
    }

    func testTimeoutIsSettledAsWithheldTimeout() throws {
        let server = StubHTTPServer { _ in
            var response = StubHTTPServer.Response()
            response.neverRespond = true
            return response
        }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store, timeoutMS: 600)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))

        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.status, "withheld")
        XCTAssertEqual(record.withheldReason, "timeout")
        XCTAssertEqual(subject.stats.calls, 2, "a timeout is retried once, then settled")
    }

    func testNon200IsSettledAsProviderErrorWithoutRetry() throws {
        let server = StubHTTPServer { _ in .json("{\"error\":\"boom\"}", status: 500) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(subject.stats.calls, 1, "a non-200 is deterministic: no retry")
        XCTAssertEqual(try XCTUnwrap(store.recorded.first).withheldReason, "provider_error")
    }

    func testMalformedBodyIsSettledAsProviderErrorWithoutRetry() throws {
        let server = StubHTTPServer { _ in .json("<html>nope</html>") }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(subject.stats.calls, 1)
        XCTAssertEqual(try XCTUnwrap(store.recorded.first).withheldReason, "provider_error")
    }

    func testNotReady503IsSettledAsNotReady() throws {
        let server = StubHTTPServer { _ in .json("{\"reason\":\"not_ready\"}", status: 503) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(try XCTUnwrap(store.recorded.first).withheldReason, "not_ready")
        XCTAssertEqual(subject.stats.calls, 2)
    }

    func testAttemptsAreBoundedEvenWhenTheServerAlwaysFails() {
        let server = StubHTTPServer { _ in .json("{\"error\":\"boom\"}", status: 500) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store, maxAttempts: 5)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertLessThanOrEqual(subject.stats.calls, 5)
        XCTAssertEqual(subject.stats.calls, 1, "a deterministic failure must not burn attempts")
    }

    func testProviderWithheldReasonIsCarriedThrough() throws {
        let server = StubHTTPServer { _ in .json("""
            {"status":"withheld","metric":"hrv","withheld_reason":"insufficient_coverage",
             "diagnostics":{"valid_pairs":3}}
            """) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.status, "withheld")
        XCTAssertEqual(record.withheldReason, "insufficient_coverage")
        XCTAssertEqual(subject.stats.withheld, 1)
    }

    func testUnknownProviderReasonIsCoercedToProviderError() throws {
        let server = StubHTTPServer { _ in .json("""
            {"status":"withheld","metric":"hrv","withheld_reason":"banana"}
            """) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.withheldReason, "provider_error")
        XCTAssertEqual(record.diagnostics?.stringMember("provider_reason_raw"), "banana")
    }

    func testOutOfBoundsValueIsWithheldNotWrittenAsOK() throws {
        let server = StubHTTPServer { _ in .json("""
            {"status":"ok","metric":"hrv","result":{"value":5000.0,"unit":"ms"}}
            """) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.status, "withheld")
        XCTAssertEqual(record.withheldReason, "provider_error")
        XCTAssertEqual(record.diagnostics?.stringMember("bounds_violation"), "value_out_of_bounds")
        // R2: the RPC's non-ok branch raises 22023 when p_value OR p_stages is
        // non-null, so the demotion must clear them; the number survives in diagnostics.
        XCTAssertNil(record.value, "a demoted row must not carry a value")
        XCTAssertNil(record.unit)
        XCTAssertNil(record.stages)
        XCTAssertNil(record.labelSpace)
        XCTAssertEqual(record.diagnostics?.member("rejected_value")?.doubleValue, 5000.0)
    }

    func testStagesWithoutLabelSpaceIsDemoted() throws {
        // The RPC's ok branch requires a label space with stages
        // (`invalid_candidate_label_space`, migration lines 433-435), so a stage
        // result without one must be settled client-side, not sent.
        // Driven through the hrv metric because it is the only one with an input
        // assembler today; the shape rule itself is metric-independent.
        let server = StubHTTPServer { _ in .json("""
            {"status":"ok","metric":"hrv","result":{"stages":[1,2,3]}}
            """) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.status, "withheld")
        XCTAssertEqual(record.withheldReason, "provider_error")
        XCTAssertEqual(record.diagnostics?.stringMember("bounds_violation"),
                       "stages_without_label_space")
        XCTAssertNil(record.stages, "a demoted row must not carry stages")
        XCTAssertNil(record.labelSpace)
        XCTAssertNil(record.value)
    }

    func testValueWithoutUnitIsSettledAsWithheldBeforeTheWrite() throws {
        // ok + value + no unit is rejected by the client (and by the RPC's
        // `invalid_candidate_unit` check, migration lines 430-432).
        let server = StubHTTPServer { _ in .json("""
            {"status":"ok","metric":"hrv","result":{"value":42.5}}
            """) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.status, "withheld")
        XCTAssertEqual(record.withheldReason, "provider_error")
        XCTAssertNil(record.value)
        XCTAssertNil(record.unit)
    }

    func testRespirationBoundsMatchTheMigration() {
        // Migration lines 452-455 (`candidate_value_out_of_bounds`): hrv 0..1000,
        // respiration 4..40, sleep_boundary/sleep_stage -1e9..1e9.
        XCTAssertEqual(CandidateStage.bounds(for: "hrv"), 0.0...1_000.0)
        XCTAssertEqual(CandidateStage.bounds(for: "respiration"), 4.0...40.0)
        XCTAssertEqual(CandidateStage.bounds(for: "sleep_boundary"),
                       -1_000_000_000.0...1_000_000_000.0)
        XCTAssertEqual(CandidateStage.bounds(for: "sleep_stage"),
                       -1_000_000_000.0...1_000_000_000.0)
        XCTAssertNil(CandidateStage.bounds(for: "not_a_metric"))
        // A respiration value the old 1..60 table accepted is now withheld client-side.
        XCTAssertFalse(try! XCTUnwrap(CandidateStage.bounds(for: "respiration")).contains(45.0))
    }

    // MARK: - R1: SQL NULL binding

    private func makeRecord(status: String, withheldReason: String?, value: Double?, unit: String?,
                            stages: JSONValue?, labelSpace: String?, coverage: JSONValue?,
                            runtimeMS: Int?) -> CandidateRecord {
        CandidateRecord(
            userId: "u", deviceId: "d", metric: "hrv", periodDay: "2026-10-01",
            intervalStart: Date(timeIntervalSince1970: 1_790_812_800),
            intervalEnd: Date(timeIntervalSince1970: 1_790_841_600),
            inputSHA256: String(repeating: "a", count: 64),
            providerId: "production.runs.v1", providerVersion: "1.0.0",
            adapterVersion: "frwhoop.hrv.rmssd/1", preprocessingVersion: "pp/1",
            configVersion: "cfg-1", dependencyVersions: [:],
            status: status, withheldReason: withheldReason, value: value, unit: unit,
            stages: stages, labelSpace: labelSpace, coverage: coverage,
            diagnostics: .object(["attempts": .int(1)]), runtimeMS: runtimeMS,
            mode: "shadow", finality: "provisional", inputRevision: 7)
    }

    func testAbsentOptionalsEncodeAsEmptyStringsForTheSqlToNullify() throws {
        // The Swift side cannot express SQL NULL (PostgresClient sends every
        // parameter as a C string), so "absent" is the empty string and the SQL
        // text is what converts it. Both halves are asserted here.
        let ok = try PhysiologyCandidateSQL.recordCandidateParameters(
            makeRecord(status: "ok", withheldReason: nil, value: 42.5, unit: "ms",
                       stages: nil, labelSpace: nil, coverage: nil, runtimeMS: 37))
        XCTAssertEqual(ok[14], "{}", "dependency_versions must stay a jsonb object")
        XCTAssertEqual(ok[15], "", "p_withheld_reason absent -> '' -> nullif -> NULL")
        XCTAssertEqual(ok[16], "42.5")
        XCTAssertEqual(ok[17], "ms")
        XCTAssertEqual(ok[18], "", "p_stages absent")
        XCTAssertEqual(ok[19], "", "p_label_space absent")
        XCTAssertEqual(ok[20], "", "p_coverage absent")
        XCTAssertEqual(ok[22], "37")

        let withheld = try PhysiologyCandidateSQL.recordCandidateParameters(
            makeRecord(status: "withheld", withheldReason: "provider_error", value: nil, unit: nil,
                       stages: nil, labelSpace: nil, coverage: nil, runtimeMS: nil))
        XCTAssertEqual(withheld[15], "provider_error")
        XCTAssertEqual(withheld[16], "", "p_value absent")
        XCTAssertEqual(withheld[17], "", "p_unit absent")
        XCTAssertEqual(withheld[18], "")
        XCTAssertEqual(withheld[20], "")
        XCTAssertEqual(withheld[22], "", "p_runtime_ms absent")

        let staged = try PhysiologyCandidateSQL.recordCandidateParameters(
            makeRecord(status: "ok", withheldReason: nil, value: nil, unit: nil,
                       stages: .array([.int(1)]), labelSpace: "wake_rem_nrem",
                       coverage: .object(["epochs": .int(10)]), runtimeMS: 0))
        XCTAssertEqual(staged[15], "")
        XCTAssertEqual(staged[16], "", "a stage result has no scalar value")
        XCTAssertEqual(staged[18], "[1]")
        XCTAssertEqual(staged[19], "wake_rem_nrem")
        XCTAssertEqual(staged[20], "{\"epochs\":10}")
        XCTAssertEqual(staged[22], "0")
    }

    func testRecordSqlNullifiesEveryNullableParameterAndNeverTheJsonbObject() {
        let sql = PhysiologyCandidateSQL.recordCandidate
        // p_dependency_versions ($15) must NOT be nullif'd: the migration raises
        // invalid_candidate_dependencies for NULL (lines 407-409).
        XCTAssertTrue(sql.contains("$15::jsonb"))
        XCTAssertFalse(sql.contains("nullif($15"))
        // Every other optional parameter is nullif'd, so an empty string becomes SQL NULL
        // instead of raising 22P02 while the call is bound.
        let nullable = [16, 17, 18, 19, 20, 21, 22, 23]
        for n in nullable {
            XCTAssertTrue(sql.contains("nullif($\(n)::text,'')"), "parameter $\(n) must be nullif'd")
        }
        // The bare casts that caused the 22P02 defect must be gone.
        for bare in ["$17::numeric", "$19::jsonb", "$21::jsonb", "$22::jsonb", "$23::integer"] {
            XCTAssertFalse(sql.contains(bare), "\(bare) must not be cast without nullif")
        }
    }

    // MARK: - Skips and budget

    func testStaleDebtSkipsWithoutCalling() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        store.debt = Date().addingTimeInterval(60)   // newer than the claim
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats(), claimSealedAt: Date()))

        XCTAssertEqual(subject.stats.skippedStaleDebt, 1)
        XCTAssertEqual(server.requestCount, 0, "a stale claim must not reach the sidecar")
        XCTAssertTrue(store.recorded.isEmpty)
    }

    func testDeletedUserSkipsWithoutCallingOrWriting() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        store.live = false
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))

        XCTAssertEqual(store.ownerChecks, 1, "the owner check must run before anything else")
        XCTAssertEqual(subject.stats.skippedDeletedUser, 1)
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertTrue(store.recorded.isEmpty, "a deleted user must not get a candidate row")
    }

    func testDrainBudgetBoundsCandidateRuns() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)

        subject.beginDrain(budget: 0)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(server.requestCount, 0, "an exhausted budget must not call")
        XCTAssertEqual(subject.stats.skippedBudget, 1)

        subject.beginDrain(budget: 1)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(server.requestCount, 1)
    }

    func testStoreErrorsAreRecordedNotThrown() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selectionError = NSError(domain: "test", code: 1)
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertNotNil(subject.stats.lastError)
    }

    func testRecordFailureIsCounted() throws {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        store.recordError = NSError(domain: "test", code: 2)
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(subject.stats.writeFailures, 1)
        XCTAssertEqual(subject.stats.recorded, 0)
    }

    // MARK: - R4: bounded stage wall time and backoff

    func testDrainDeadlineSkipsEverythingWhenAlreadySpent() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.maxDrainSeconds = 0
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertEqual(server.requestCount, 0, "an exhausted drain cap must not call the sidecar")
        XCTAssertEqual(subject.stats.skippedDeadline, 1)
        XCTAssertTrue(store.recorded.isEmpty, "nothing computed => nothing written")
    }

    func testStalledSidecarIsCappedByTheDrainDeadline() throws {
        let server = StubHTTPServer { _ in
            var response = StubHTTPServer.Response()
            response.neverRespond = true
            return response
        }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        // A 20 s client timeout, but only 0.6 s of drain budget: the stage must give
        // up long before the client's own deadline, and must not retry into a stall.
        var subject = stage(server: server, store: store, timeoutMS: 20_000)
        subject.maxDrainSeconds = 0.6
        subject.beginDrain(budget: 2)
        let started = Date()
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 6.0, "the drain cap must bound the stage (took \(elapsed)s)")
        XCTAssertEqual(subject.stats.calls, 1, "the cap must prevent a second attempt")
        // The attempt that DID start settles as a withheld timeout row.
        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.status, "withheld")
        XCTAssertEqual(record.withheldReason, "timeout")
    }

    func testTransientRetryBacksOff() {
        // A refused connection fails in ~1 ms, so a measurable gap between the two
        // attempts is the backoff and nothing else.
        let url = "http://127.0.0.1:\(closedLoopbackPort())"
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        let client = InferenceClient(baseURL: URL(string: url)!, timeoutMS: 5_000)
        var subject = CandidateStage(client: client, store: store)
        subject.beginDrain(budget: 2)
        let started = Date()
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(subject.stats.calls, 2, "a refused connection is still retried once")
        XCTAssertGreaterThanOrEqual(elapsed, CandidateStage.retryBackoffSeconds * 0.8,
                                    "the retry must back off (elapsed \(elapsed)s)")
    }

    // MARK: - Active plumbing (unreachable while defaults are off)

    func testShadowModeNeverProducesASubstitution() {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertNil(subject.lastActiveSubstitution)
        XCTAssertEqual(subject.stats.activeSubstitutions, 0)
        XCTAssertEqual(store.recorded.first?.mode, "shadow")
    }

    func testActiveModeProducesASubstitutionAndRecordsActiveMode() throws {
        let server = StubHTTPServer { _ in .json(CandidateStageTests.okBody) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("active")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))

        let substitution = try XCTUnwrap(subject.lastActiveSubstitution)
        XCTAssertEqual(substitution.value, 42.5)
        XCTAssertEqual(substitution.providerId, "production.runs.v1")
        XCTAssertEqual(substitution.mode, "active")
        XCTAssertEqual(subject.stats.activeSubstitutions, 1)
        XCTAssertEqual(store.recorded.first?.mode, "active")
    }

    func testActiveSubstitutionIsNotProducedForAWithheldResult() {
        let server = StubHTTPServer { _ in .json("""
            {"status":"withheld","metric":"hrv","withheld_reason":"artifact_fraction"}
            """) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("active")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        XCTAssertNil(subject.lastActiveSubstitution)
    }

    // MARK: - Record RPC parameter contract (INTEGRATION SEAM)

    func testRecordParametersMatchTheDocumentedSignature() throws {
        let record = CandidateRecord(
            userId: "u", deviceId: "d", metric: "hrv", periodDay: "2026-10-01",
            intervalStart: Date(timeIntervalSince1970: 1_790_812_800),   // 2026-10-01T00:00:00Z
            intervalEnd: Date(timeIntervalSince1970: 1_790_841_600),     // 2026-10-01T08:00:00Z
            inputSHA256: String(repeating: "a", count: 64),
            providerId: "production.runs.v1", providerVersion: "1.0.0",
            adapterVersion: "frwhoop.hrv.rmssd/1", preprocessingVersion: "pp/1",
            configVersion: "cfg-1", dependencyVersions: ["dependency": "nk/0.2.13"],
            status: "ok", withheldReason: nil, value: 42.5, unit: "ms", stages: nil,
            labelSpace: nil, coverage: .object(["pairs": .int(30)]),
            diagnostics: .object(["attempts": .int(1)]), runtimeMS: 37,
            mode: "shadow", finality: "provisional", inputRevision: 7)
        let params = try PhysiologyCandidateSQL.recordCandidateParameters(record)
        // W-B's FINAL signature: 23 positional parameters, in this exact order.
        XCTAssertEqual(params.count, 23, "the record RPC takes 23 positional parameters")
        XCTAssertEqual(params[0], "u")                     // p_user
        XCTAssertEqual(params[1], "d")                     // p_device (text)
        XCTAssertEqual(params[2], "hrv")                   // p_metric
        XCTAssertEqual(params[3], "2026-10-01")            // p_period_day
        XCTAssertEqual(params[4], "2026-10-01T00:00:00Z")  // p_interval_start_at
        XCTAssertEqual(params[5], "2026-10-01T08:00:00Z")  // p_interval_end_at
        XCTAssertEqual(params[6].count, 64)                // p_input_sha256
        XCTAssertEqual(params[7], "7")                     // p_input_revision (8th, not last)
        XCTAssertEqual(params[8], "production.runs.v1")    // p_provider_id
        XCTAssertEqual(params[9], "1.0.0")                 // p_provider_version
        XCTAssertEqual(params[10], "frwhoop.hrv.rmssd/1")  // p_adapter_version
        XCTAssertEqual(params[11], "pp/1")                 // p_preprocessing_version
        XCTAssertEqual(params[12], "cfg-1")                // p_config_version
        XCTAssertEqual(params[13], "ok")                   // p_status
        // JSONEncoder escapes the solidus, so the wire form is {"dependency":"nk\/0.2.13"}.
        XCTAssertEqual(params[14], "{\"dependency\":\"nk\\/0.2.13\"}")   // p_dependency_versions
        XCTAssertEqual(params[15], "", "an absent withheld reason is SQL NULL (empty string)")
        XCTAssertEqual(params[16], "42.5")                 // p_value
        XCTAssertEqual(params[17], "ms")                   // p_unit
        XCTAssertEqual(params[18], "")                     // p_stages (SQL NULL)
        XCTAssertEqual(params[19], "")                     // p_label_space
        XCTAssertEqual(params[20], "{\"pairs\":30}")      // p_coverage
        XCTAssertEqual(params[21], "{\"attempts\":1}")    // p_diagnostics
        XCTAssertEqual(params[22], "37")                   // p_runtime_ms
        XCTAssertTrue(PhysiologyCandidateSQL.recordCandidate.contains("physiology_record_candidate_result"))
        XCTAssertTrue(PhysiologyCandidateSQL.selectedProvider.contains("physiology_selected_provider"))
        XCTAssertTrue(PhysiologyCandidateSQL.candidateDebt.contains("physiology_candidate_debt_read"))
    }

    func testRecordUsesTheSelectedProviderTriple() throws {
        // The record RPC drops the row when the provider triple differs from the
        // current selection, so the worker must write the SELECTION's triple even
        // when the sidecar echoes something else.
        let server = StubHTTPServer { _ in .json("""
            {"status":"ok","metric":"hrv","provider_id":"some.other.provider",
             "versions":{"adapter":"frwhoop.hrv.rmssd/1","config":"other-cfg"},
             "result":{"value":42.5,"unit":"ms"}}
            """) }
        defer { server.stop() }
        let store = FakeCandidateStore()
        store.selection["hrv"] = selection("shadow")
        var subject = stage(server: server, store: store)
        subject.beginDrain(budget: 2)
        subject.run(claim: claim(), inputs: inputs(beats: sampleBeats()))
        let record = try XCTUnwrap(store.recorded.first)
        XCTAssertEqual(record.providerId, "production.runs.v1", "the triple must be the selection's")
        XCTAssertEqual(record.providerVersion, "1.0.0")
        XCTAssertEqual(record.configVersion, "cfg-1")
        // The mismatch is preserved as evidence instead of being lost.
        XCTAssertEqual(record.diagnostics?.stringMember("provider_id_mismatch"), "some.other.provider")
        XCTAssertEqual(record.diagnostics?.stringMember("config_version_mismatch"), "other-cfg")
    }

    func testDebtTimestampParsingHandlesPostgresRendering() {
        XCTAssertNotNil(PostgresCandidateStore.parseTimestamp("2026-10-01T08:00:00+00:00"))
        XCTAssertNotNil(PostgresCandidateStore.parseTimestamp("2026-10-01T08:00:00.123456+00:00"))
        XCTAssertNotNil(PostgresCandidateStore.parseTimestamp("2026-10-01 08:00:00+00"))
        XCTAssertNil(PostgresCandidateStore.parseTimestamp("not a timestamp"))
        let a = try? XCTUnwrap(PostgresCandidateStore.parseTimestamp("2026-10-01T08:00:00+00:00"))
        let b = try? XCTUnwrap(PostgresCandidateStore.parseTimestamp("2026-10-01T08:00:00.123456+00:00"))
        XCTAssertEqual(a?.timeIntervalSince1970 ?? 0, 1_790_841_600, accuracy: 0.001)
        XCTAssertEqual(b?.timeIntervalSince1970 ?? 0, 1_790_841_600.123456, accuracy: 0.01)
    }

    // MARK: - WorkerConfig off switch

    func testWorkerConfigKeepsTheCandidateLaneOffWithoutTheURL() throws {
        let config = try WorkerConfig(environment: [
            "FRWHOOP_DB_URL": "postgres://u:p@host:5432/postgres",
            "FRWHOOP_B2_KEY_ID": "key", "FRWHOOP_B2_APPLICATION_KEY": "secret",
            "FRWHOOP_INGEST_SECRET": "ingest",
        ])
        XCTAssertNil(config.inferenceURL)
        XCTAssertFalse(config.inferenceEnabled)
        XCTAssertEqual(config.inferenceTimeoutMS, 25_000)
        XCTAssertEqual(config.inferenceBudget, 2)
    }

    func testWorkerInferenceDefaultSitsAboveTheSidecarBudget() {
        // F3: the sidecar joins its provider thread with its own 20 s budget
        // (deploy/inference.env.example FRWHOOP_REQUEST_TIMEOUT_MS=20000). The
        // worker's default deadline must be STRICTLY larger, otherwise a request
        // that consumes the sidecar's whole budget trips the worker's own request
        // timeout at the same instant and the sidecar's withheld/timeout verdict
        // and diagnostics are lost.
        XCTAssertEqual(InferenceClient.defaultTimeoutMS, 25_000)
        XCTAssertGreaterThan(InferenceClient.defaultTimeoutMS, 20_000)
    }

    func testWorkerConfigReadsTheInferenceVariables() throws {
        let config = try WorkerConfig(environment: [
            "FRWHOOP_DB_URL": "postgres://u:p@host:5432/postgres",
            "FRWHOOP_B2_KEY_ID": "key", "FRWHOOP_B2_APPLICATION_KEY": "secret",
            "FRWHOOP_INGEST_SECRET": "ingest",
            "FRWHOOP_INFERENCE_URL": "http://127.0.0.1:8787",
            "FRWHOOP_INFERENCE_TIMEOUT_MS": "5000",
            "FRWHOOP_INFERENCE_BUDGET": "1",
        ])
        XCTAssertEqual(config.inferenceURL, "http://127.0.0.1:8787")
        XCTAssertTrue(config.inferenceEnabled)
        XCTAssertEqual(config.inferenceTimeoutMS, 5_000)
        XCTAssertEqual(config.inferenceBudget, 1)
    }

    func testHeartbeatEncodesTheOffLaneAsJsonNull() throws {
        // The heartbeat puts JSON null in meta["inference"] when the candidate lane
        // is off. The value must reach jsonb as a real `null`, not the string
        // "null" and not a serialization failure.
        let meta: [String: Any] = ["worker_name": "w", "inference": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"inference\":null"), text)
        // ...and an ENABLED lane carries an object instead.
        let on: [String: Any] = ["worker_name": "w", "inference": ["enabled": true, "ready": false]]
        let onData = try JSONSerialization.data(withJSONObject: on, options: [.sortedKeys])
        let onText = try XCTUnwrap(String(data: onData, encoding: .utf8))
        XCTAssertTrue(onText.contains("\"enabled\":true"), onText)
    }

    func testWorkerConfigTreatsWhitespaceURLAsOff() throws {
        let config = try WorkerConfig(environment: [
            "FRWHOOP_DB_URL": "postgres://u:p@host:5432/postgres",
            "FRWHOOP_B2_KEY_ID": "key", "FRWHOOP_B2_APPLICATION_KEY": "secret",
            "FRWHOOP_INGEST_SECRET": "ingest",
            "FRWHOOP_INFERENCE_URL": "   ",
        ])
        XCTAssertNil(config.inferenceURL)
        XCTAssertFalse(config.inferenceEnabled)
    }
}
