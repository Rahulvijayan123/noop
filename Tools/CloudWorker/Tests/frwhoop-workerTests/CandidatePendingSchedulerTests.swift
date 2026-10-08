import XCTest
import WhoopProtocol
@testable import frwhoop_worker

/// The persisted candidate scheduler (`CandidateStage` with a `CandidatePendingStore`): no metric
/// starves under a small run budget, a budget/deadline/busy skip is never a completion, stale
/// work and lost leases cannot settle, and transient failures are bounded. The queue is an
/// in-memory model of `20261008110000_physiology_candidate_pending.sql` (the SQL itself is
/// covered by `physiology_candidate_pending_contract.sql` and `CandidatePendingDatabaseTests`);
/// the sidecar is a real 127.0.0.1 stub.
final class CandidatePendingSchedulerTests: XCTestCase {

    // MARK: - Queue model

    /// The SQL contract, in memory: oldest `pendingSince` first (then day, then metric order),
    /// a re-armed row keeps its place while still pending, settles fenced on revision + lease.
    final class FakePendingStore: CandidatePendingStore {
        struct Row {
            var key: String
            var userId: String, deviceId: String, day: String, metric: String
            var revision: Int64
            var providerId: String
            var state = "pending"
            var attempts = 0
            var lastReason: String?
            var pendingSince: Int
            var nextAttemptAt: Int = 0
            var leaseToken: String?
            var leaseLive = false
            var candidateId: String?
        }
        private let lock = NSLock()
        var available = true
        var rows: [String: Row] = [:]
        /// The day's scoring input revision (the record RPC's fence), keyed user|device|day.
        var currentRevisions: [String: Int64] = [:]
        /// Logical clock: every enqueue and settle advances it, so ordering is deterministic.
        private(set) var clock = 0
        var refusedSettles = 0
        var settleLog: [(metric: String, outcome: String, reason: String)] = []

        private static let order = ["hrv", "sleep_boundary", "sleep_stage", "respiration"]
        static func dayKey(_ u: String, _ d: String, _ day: String) -> String { "\(u)|\(d)|\(day)" }

        func isAvailable() -> Bool { available }

        func enqueue(userId: String, deviceId: String, day: String, inputRevision: Int64,
                     entries: [CandidatePendingEntry]) throws -> Int {
            lock.lock(); defer { lock.unlock() }
            clock += 1
            if let current = currentRevisions[Self.dayKey(userId, deviceId, day)], inputRevision < current { return 0 }
            var changed = 0
            for entry in entries {
                let key = "\(Self.dayKey(userId, deviceId, day))|\(entry.metric)"
                let state = entry.hasInput ? "pending" : "withheld"
                if var row = rows[key] {
                    guard row.revision < inputRevision || row.providerId != entry.providerId else { continue }
                    let keepPlace = row.state == "pending" && state == "pending"
                    row.revision = inputRevision
                    row.providerId = entry.providerId
                    row.state = state
                    row.attempts = 0
                    row.lastReason = entry.hasInput ? nil : "no_input"
                    row.pendingSince = keepPlace ? row.pendingSince : clock
                    row.nextAttemptAt = clock
                    row.leaseToken = nil
                    row.leaseLive = false
                    rows[key] = row
                } else {
                    rows[key] = Row(key: key, userId: userId, deviceId: deviceId, day: day,
                                    metric: entry.metric, revision: inputRevision,
                                    providerId: entry.providerId, state: state,
                                    lastReason: entry.hasInput ? nil : "no_input", pendingSince: clock,
                                    nextAttemptAt: clock)
                }
                changed += 1
            }
            return changed
        }

        func claim(owner: String, leaseSeconds: Int) throws -> CandidatePendingItem? {
            lock.lock(); defer { lock.unlock() }
            while true {
                let due = rows.values.filter { $0.state == "pending" && !$0.leaseLive && $0.nextAttemptAt <= clock }
                guard var row = due.min(by: { a, b in
                    if a.pendingSince != b.pendingSince { return a.pendingSince < b.pendingSince }
                    if a.day != b.day { return a.day < b.day }
                    return (Self.order.firstIndex(of: a.metric) ?? 9) < (Self.order.firstIndex(of: b.metric) ?? 9)
                }) else { return nil }
                if let current = currentRevisions[Self.dayKey(row.userId, row.deviceId, row.day)],
                   row.revision < current {
                    row.state = "superseded"
                    row.lastReason = "stale_input_revision"
                    rows[row.key] = row
                    continue
                }
                let prior = row.lastReason
                if row.leaseToken != nil {          // expired unsettled: the run counts
                    row.attempts += 1
                    row.lastReason = "lease_expired"
                }
                row.leaseToken = UUID().uuidString.lowercased()
                row.leaseLive = true
                rows[row.key] = row
                return CandidatePendingItem(userId: row.userId, deviceId: row.deviceId, day: row.day,
                                            metric: row.metric, inputRevision: row.revision,
                                            providerId: row.providerId, providerVersion: "1.0.0",
                                            configVersion: "cfg-1", attempts: row.attempts,
                                            leaseToken: row.leaseToken!, lastReason: row.lastReason ?? prior)
            }
        }

        func settle(_ item: CandidatePendingItem, _ settlement: CandidatePendingSettlement,
                    maxAttempts: Int) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            clock += 1
            let key = "\(Self.dayKey(item.userId, item.deviceId, item.day))|\(item.metric)"
            guard var row = rows[key], row.revision == item.inputRevision, row.state == "pending",
                  row.leaseLive, row.leaseToken == item.leaseToken else {
                refusedSettles += 1
                return false
            }
            let parameters = PhysiologyCandidatePendingSQL.settleParameters(item, settlement, maxAttempts: maxAttempts)
            let outcome = parameters[6], reason = parameters[7]
            settleLog.append((item.metric, outcome, reason))
            if settlement.countsAttempt { row.attempts += 1 }
            row.leaseToken = nil
            row.leaseLive = false
            row.lastReason = reason
            switch settlement {
            case .done(_, let id), .withheld(_, let id):
                row.state = outcome
                row.candidateId = id
            case .superseded:
                row.state = "superseded"
            case .retry(_, let counted, let after):
                if counted && row.attempts >= maxAttempts {
                    row.state = "withheld"
                    row.lastReason = "attempts_exhausted:\(reason)"
                } else {
                    row.nextAttemptAt = clock + after
                }
            }
            rows[key] = row
            return true
        }

        func currentRevision(userId: String, deviceId: String, day: String) throws -> Int64? {
            lock.lock(); defer { lock.unlock() }
            return currentRevisions[Self.dayKey(userId, deviceId, day)]
        }

        func stats() throws -> CandidatePendingStats {
            lock.lock(); defer { lock.unlock() }
            let pending = rows.values.filter { $0.state == "pending" }
            var out = CandidatePendingStats()
            out.pending = pending.count
            out.due = pending.filter { !$0.leaseLive && $0.nextAttemptAt <= clock }.count
            out.leased = pending.filter { $0.leaseLive }.count
            for row in pending {
                out.byMetric[row.metric, default: 0] += 1
                out.byReason[row.lastReason ?? "new", default: 0] += 1
            }
            return out
        }

        // Test controls.
        func advance(_ ticks: Int) { lock.lock(); clock += ticks; lock.unlock() }
        func row(_ day: String, _ metric: String) -> Row? {
            lock.lock(); defer { lock.unlock() }
            return rows.values.first { $0.day == day && $0.metric == metric }
        }
        func expireLeases() {
            lock.lock(); defer { lock.unlock() }
            for key in rows.keys where rows[key]!.leaseLive { rows[key]!.leaseLive = false }
        }
        func setRevision(_ u: String, _ d: String, _ day: String, _ rev: Int64) {
            lock.lock(); currentRevisions[Self.dayKey(u, d, day)] = rev; lock.unlock()
        }
    }

    /// Hands back canned inputs for any day, as `ScoringCandidateAssembler` would re-assemble them.
    final class FakeAssembler: CandidateInputAssembling {
        var make: (String, Int64) -> DayScorer.CandidateInputs
        var calls = 0
        init(make: @escaping (String, Int64) -> DayScorer.CandidateInputs) { self.make = make }
        func assemble(userId: String, deviceId: String, day: String,
                      inputRevision: Int64) throws -> CandidateAssembly {
            calls += 1
            return CandidateAssembly(inputs: make(day, inputRevision), timezoneId: "UTC")
        }
    }

    // MARK: - Fixtures

    static let user = "11111111-1111-5111-8111-111111111111"
    static let device = "22222222-2222-5222-8222-222222222222"
    static let allMetrics: Set<String> = ["hrv", "sleep_boundary", "sleep_stage", "respiration"]

    private func selection(_ mode: String = "shadow", provider: String = "prov.v1") -> SelectedProvider {
        SelectedProvider(providerId: provider, providerVersion: "1.0.0", configVersion: "cfg-1", mode: mode)
    }

    /// Inputs where hrv, sleep_boundary and sleep_stage have payloads; respiration has no
    /// assembly in this tree, so it is enqueued as no_input.
    static func inputs(day: String = "2026-10-01", revision: Int64 = 1,
                       enabled: Set<String> = allMetrics) -> DayScorer.CandidateInputs {
        let beats = (0..<40).map { index in
            RRInterval(ts: 1_772_006_400 + index, rrMs: 800 + (index % 7),
                       srcChannel: .whoop5Historical, ord: index, seq: index)
        }
        let deduped = DayScorer.dedupByObservationIdentity(beats)
        return DayScorer.CandidateInputs(
            userId: user, deviceId: device, day: day, inputRevision: revision,
            intervalStart: 1_772_006_400, intervalEnd: 1_772_035_200,
            claimSealedAt: Date(), status: "available",
            canonicalAvgHrv: 48.0, canonicalSdnn: 61.0,
            profileVersion: "profile1:abc", correctionsVersion: "none",
            enabledMetrics: enabled, assembled: true,
            hrvBeats: DayScorer.candidateBeats(deduped), hrvInputRows: beats.count,
            hrvTimestampResolution: "whole_seconds",
            hrSamples: DayScorer.candidateHRSamples([HRSample(ts: 1_772_006_400, bpm: 58)]),
            rrRows: DayScorer.candidateRRRows(deduped),
            sleepWindowStart: 1_772_006_400, sleepWindowEnd: 1_772_035_200,
            sleepEdits: [], age: 34, gender: 1)
    }

    static func claim(day: String = "2026-10-01", revision: Int64 = 1) -> DayScorer.Claim {
        DayScorer.Claim(userId: user, deviceId: device, day: day, timezoneId: "UTC",
                        inputRevision: revision, leaseToken: UUID().uuidString.lowercased(),
                        runId: UUID().uuidString.lowercased(), measurementRevision: 0)
    }

    /// A sidecar that answers every metric with a deterministic withheld result, echoing the
    /// request's metric and provider (a settled outcome, so the item completes).
    static func echoServer(onRequest: @escaping (String) -> Void = { _ in }) -> StubHTTPServer {
        StubHTTPServer { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let metric = body["metric"] as? String ?? "hrv"
            let provider = (body["provider"] as? [String: Any])?["provider_id"] as? String ?? "prov.v1"
            onRequest(metric)
            return .json("""
                {"status":"withheld","metric":"\(metric)","provider_id":"\(provider)",
                 "withheld_reason":"insufficient_coverage","runtime_ms":3}
                """)
        }
    }

    private func makeStage(server: StubHTTPServer, store: CandidateStageTests.FakeCandidateStore,
                           pending: FakePendingStore) -> CandidateStage {
        let client = InferenceClient(baseURL: URL(string: server.baseURL)!, timeoutMS: 5_000)
        var stage = CandidateStage(client: client, store: store, pending: pending)
        stage.maxDrainSeconds = 20
        return stage
    }

    private func enableAll(_ store: CandidateStageTests.FakeCandidateStore) {
        for metric in CandidateStage.metrics { store.selection[metric] = selection() }
    }

    // MARK: - No starvation

    /// Four enabled metrics, budget 1, the same day re-scored before every drain (a new input
    /// revision each time, as a streaming phone causes): every metric with an input runs, the
    /// one without settles withheld with its reason, and budget skips are never completions.
    func testBudgetOfOneDoesNotStarveLaterMetricsWhileTheDayKeepsBeingRescored() throws {
        let server = Self.echoServer()
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        enableAll(store)
        let pending = FakePendingStore()
        var stage = makeStage(server: server, store: store, pending: pending)

        var ranAt: [String: Int] = [:]
        for drain in 1...6 {
            let revision = Int64(drain)
            pending.setRevision(Self.user, Self.device, "2026-10-01", revision)
            let before = store.recorded.count
            stage.beginDrain(budget: 1)
            stage.run(claim: Self.claim(revision: revision), inputs: Self.inputs(revision: revision))
            XCTAssertLessThanOrEqual(store.recorded.count - before, 1, "budget 1 means one run per drain")
            for record in store.recorded[before...] where ranAt[record.metric] == nil { ranAt[record.metric] = drain }
        }
        XCTAssertEqual(Set(ranAt.keys), ["hrv", "sleep_boundary", "sleep_stage"],
                       "every metric with an input must run; got \(ranAt)")
        XCTAssertLessThanOrEqual(ranAt.values.max() ?? 99, 3, "three runnable metrics, three drains: \(ranAt)")
        let respiration = try XCTUnwrap(pending.row("2026-10-01", "respiration"))
        XCTAssertEqual(respiration.state, "withheld")
        XCTAssertEqual(respiration.lastReason, "no_input", "the metric that cannot run says why")
        XCTAssertGreaterThan(stage.stats.skippedBudget, 0)
        XCTAssertEqual(stage.stats.pendingDone, stage.stats.recorded + stage.stats.duplicates,
                       "only a run that reached the record RPC is a completion, never a budget skip")
        XCTAssertFalse(pending.settleLog.contains { $0.outcome == "done" && $0.reason == "budget" })
        for (metric, outcome, reason) in pending.settleLog where reason == "budget" {
            XCTAssertEqual(outcome, "retry", "\(metric): a budget skip stays pending")
        }
    }

    /// Budget 2 across two days that are scored once each and then never again: the idle-drain
    /// backlog re-assembles their inputs and every metric of both days runs.
    func testBacklogDrainsReachEveryMetricOfDaysThatAreNotRescored() throws {
        let server = Self.echoServer()
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        enableAll(store)
        let pending = FakePendingStore()
        var stage = makeStage(server: server, store: store, pending: pending)
        stage.backlogIntervalSeconds = 0
        let assembler = FakeAssembler { day, revision in Self.inputs(day: day, revision: revision) }

        for day in ["2026-10-01", "2026-10-02"] {
            pending.setRevision(Self.user, Self.device, day, 1)
            stage.beginDrain(budget: 2)
            stage.run(claim: Self.claim(day: day), inputs: Self.inputs(day: day), assembler: assembler)
        }
        for _ in 0..<6 {
            stage.beginDrain(budget: 2)
            stage.drainBacklog(assembler: assembler)
        }
        let ran = Set(store.recorded.map { "\($0.periodDay):\($0.metric)" })
        XCTAssertEqual(ran, ["2026-10-01:hrv", "2026-10-01:sleep_boundary", "2026-10-01:sleep_stage",
                             "2026-10-02:hrv", "2026-10-02:sleep_boundary", "2026-10-02:sleep_stage"])
        XCTAssertEqual(try pending.stats().pending, 0, "nothing is left waiting")
        XCTAssertGreaterThan(assembler.calls, 0, "backlog items get their inputs re-assembled")
        XCTAssertEqual(stage.stats.reassembled, assembler.calls)
    }

    /// The deadline is spent before anything runs: the item waits with reason `deadline`.
    func testDeadlineSkipStaysPendingWithItsReason() throws {
        let server = Self.echoServer()
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        store.selection["hrv"] = selection()
        let pending = FakePendingStore()
        var stage = makeStage(server: server, store: store, pending: pending)
        stage.maxDrainSeconds = 0
        stage.beginDrain(budget: 2)
        stage.run(claim: Self.claim(), inputs: Self.inputs(enabled: ["hrv"]))
        XCTAssertEqual(server.requestCount, 0)
        let row = try XCTUnwrap(pending.row("2026-10-01", "hrv"))
        XCTAssertEqual(row.state, "pending")
        XCTAssertEqual(row.lastReason, "deadline")
        XCTAssertEqual(row.attempts, 0)
        XCTAssertTrue(store.recorded.isEmpty)
        XCTAssertEqual(stage.stats.pendingDone, 0)
    }

    // MARK: - Busy

    func testBusyKeepsTheItemPendingUnrecordedAndStopsTheDrain() throws {
        let server = StubHTTPServer { _ in
            var response = StubHTTPServer.Response.json(
                #"{"status":"error","error":{"code":"busy","message":"all workers busy"}}"#, status: 429)
            response.headers["Retry-After"] = "7"
            return response
        }
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        enableAll(store)
        let pending = FakePendingStore()
        var stage = makeStage(server: server, store: store, pending: pending)
        stage.beginDrain(budget: 2)
        stage.run(claim: Self.claim(), inputs: Self.inputs())

        XCTAssertEqual(server.requestCount, 1, "busy is backpressure: no further call in the drain")
        XCTAssertTrue(store.recorded.isEmpty, "a busy answer is never recorded")
        XCTAssertEqual(stage.stats.busy, 1)
        let hrv = try XCTUnwrap(pending.row("2026-10-01", "hrv"))
        XCTAssertEqual(hrv.state, "pending")
        XCTAssertEqual(hrv.lastReason, "busy")
        XCTAssertEqual(hrv.attempts, 0, "busy is not an attempt")
        XCTAssertEqual(stage.stats.pendingDone, 0)
        XCTAssertEqual(stage.heartbeatCounters()["candidate_busy"], 1)
    }

    // MARK: - Fences

    /// New data arrives while the sidecar computes: the day is re-scored at a newer revision and
    /// re-enqueued. The old run's settle is refused and the newer revision's row is untouched.
    func testStaleRunCannotSettleOverANewerRevision() throws {
        let pending = FakePendingStore()
        let server = Self.echoServer { _ in
            pending.setRevision(Self.user, Self.device, "2026-10-01", 2)
            _ = try? pending.enqueue(userId: Self.user, deviceId: Self.device, day: "2026-10-01",
                                     inputRevision: 2,
                                     entries: [CandidatePendingEntry(metric: "hrv", providerId: "prov.v1",
                                                                     providerVersion: "1.0.0", configVersion: "cfg-1",
                                                                     requestedMode: "shadow", hasInput: true)])
        }
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        store.selection["hrv"] = selection()
        var stage = makeStage(server: server, store: store, pending: pending)
        pending.setRevision(Self.user, Self.device, "2026-10-01", 1)
        stage.beginDrain(budget: 1)
        stage.run(claim: Self.claim(), inputs: Self.inputs(enabled: ["hrv"]))

        XCTAssertEqual(stage.stats.pendingSettleRefused, 1, "the stale settle is refused")
        XCTAssertEqual(stage.stats.pendingDone, 0)
        let row = try XCTUnwrap(pending.row("2026-10-01", "hrv"))
        XCTAssertEqual(row.revision, 2)
        XCTAssertEqual(row.state, "pending", "the newer revision still has to run")
        XCTAssertEqual(row.attempts, 0)
        XCTAssertNotEqual(row.lastReason, "recorded")
    }

    /// A pending item whose day moved on is superseded at claim time and never computed.
    func testStaleItemIsSupersededWithoutACall() throws {
        let server = Self.echoServer()
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        store.selection["hrv"] = selection()
        let pending = FakePendingStore()
        var stage = makeStage(server: server, store: store, pending: pending)
        pending.setRevision(Self.user, Self.device, "2026-10-01", 1)
        stage.beginDrain(budget: 0)
        stage.run(claim: Self.claim(), inputs: Self.inputs(enabled: ["hrv"]))
        pending.setRevision(Self.user, Self.device, "2026-10-01", 5)
        stage.beginDrain(budget: 2)
        stage.drainBacklog(assembler: FakeAssembler { day, rev in Self.inputs(day: day, revision: rev) })
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertEqual(pending.row("2026-10-01", "hrv")?.state, "superseded")
        XCTAssertTrue(store.recorded.isEmpty)
    }

    /// The lease expires while the sidecar computes (the worker stalled past its lease): the
    /// settle is refused, and the next claim counts the abandoned run.
    func testLostLeaseCannotSettle() throws {
        let pending = FakePendingStore()
        let server = Self.echoServer { _ in pending.expireLeases() }
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        store.selection["hrv"] = selection()
        var stage = makeStage(server: server, store: store, pending: pending)
        stage.beginDrain(budget: 1)
        stage.run(claim: Self.claim(), inputs: Self.inputs(enabled: ["hrv"]))
        XCTAssertEqual(stage.stats.pendingSettleRefused, 1)
        XCTAssertEqual(stage.stats.pendingDone, 0)
        XCTAssertEqual(pending.row("2026-10-01", "hrv")?.state, "pending")
    }

    // MARK: - Bounded attempts

    func testTransientTimeoutsAreBoundedThenWithheld() throws {
        let server = StubHTTPServer { _ in .json("""
            {"status":"withheld","metric":"hrv","provider_id":"prov.v1","withheld_reason":"timeout"}
            """) }
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        store.selection["hrv"] = selection()
        let pending = FakePendingStore()
        var stage = makeStage(server: server, store: store, pending: pending)
        stage.pendingMaxAttempts = 3
        stage.backlogIntervalSeconds = 0
        let assembler = FakeAssembler { day, rev in Self.inputs(day: day, revision: rev, enabled: ["hrv"]) }
        stage.beginDrain(budget: 1)
        stage.run(claim: Self.claim(), inputs: Self.inputs(enabled: ["hrv"]), assembler: assembler)
        for _ in 0..<5 {
            pending.advance(10_000)                 // past every backoff
            stage.beginDrain(budget: 1)
            stage.drainBacklog(assembler: assembler)
        }
        XCTAssertEqual(server.requestCount, 3, "exactly pendingMaxAttempts real attempts")
        let row = try XCTUnwrap(pending.row("2026-10-01", "hrv"))
        XCTAssertEqual(row.state, "withheld")
        XCTAssertEqual(row.lastReason, "attempts_exhausted:timeout")
        XCTAssertEqual(row.attempts, 3)
        XCTAssertEqual(store.recorded.count, 1, "the terminal attempt records one withheld row")
        XCTAssertEqual(store.recorded.first?.withheldReason, "timeout")
    }

    /// A run that keeps dying with its lease (counted by the claim) reaches the bound too.
    func testAbandonedLeasesReachTheAttemptBound() throws {
        let server = Self.echoServer()
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        store.selection["hrv"] = selection()
        let pending = FakePendingStore()
        var stage = makeStage(server: server, store: store, pending: pending)
        stage.pendingMaxAttempts = 2
        stage.beginDrain(budget: 0)
        stage.run(claim: Self.claim(), inputs: Self.inputs(enabled: ["hrv"]))
        for _ in 0..<2 {                            // two holders die mid-run
            _ = try pending.claim(owner: "dead", leaseSeconds: 60)
            pending.expireLeases()
        }
        stage.beginDrain(budget: 1)
        stage.drainBacklog(assembler: FakeAssembler { day, rev in Self.inputs(day: day, revision: rev) })
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertEqual(pending.row("2026-10-01", "hrv")?.state, "withheld")
        XCTAssertEqual(pending.row("2026-10-01", "hrv")?.lastReason, "attempts_exhausted:lease_expired")
    }

    // MARK: - Fallback, configuration and heartbeat

    func testWithoutTheMigrationTheStageSchedulesInMemory() {
        let server = Self.echoServer()
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        store.selection["hrv"] = selection()
        let pending = FakePendingStore()
        pending.available = false
        var stage = makeStage(server: server, store: store, pending: pending)
        stage.beginDrain(budget: 2)
        stage.run(claim: Self.claim(), inputs: Self.inputs(enabled: ["hrv"]))
        XCTAssertEqual(store.recorded.count, 1, "the in-memory path still runs")
        XCTAssertTrue(pending.rows.isEmpty)
        XCTAssertEqual(stage.schedulingMode, "in_memory")
    }

    func testConfigurePendingReadsTheEnvironment() {
        let client = InferenceClient(baseURL: URL(string: "http://127.0.0.1:9")!, timeoutMS: 1_000)
        var stage = CandidateStage(client: client, store: CandidateStageTests.FakeCandidateStore())
        let pending = FakePendingStore()
        stage.configurePending(pending, environment: [:], owner: "frwhoop-worker-2")
        XCTAssertNotNil(stage.pending)
        XCTAssertEqual(stage.pendingMaxAttempts, 4)
        XCTAssertEqual(stage.reassemblyBudget, 1)
        XCTAssertEqual(stage.pendingLeaseSeconds, 300)
        XCTAssertEqual(stage.pendingOwner, "frwhoop-worker-2")
        XCTAssertEqual(stage.schedulingMode, "unknown")
        stage.configurePending(pending, environment: [
            "FRWHOOP_CANDIDATE_MAX_ATTEMPTS": "99", "FRWHOOP_CANDIDATE_REASSEMBLY_BUDGET": "0",
            "FRWHOOP_CANDIDATE_LEASE_SECONDS": "5"], owner: "w")
        XCTAssertEqual(stage.pendingMaxAttempts, 20, "clamped")
        XCTAssertEqual(stage.reassemblyBudget, 0)
        XCTAssertEqual(stage.pendingLeaseSeconds, 60, "clamped")
        stage.configurePending(pending, environment: ["FRWHOOP_CANDIDATE_SCHEDULER": "memory"], owner: "w")
        XCTAssertNil(stage.pending)
        XCTAssertEqual(stage.schedulingMode, "in_memory")
    }

    func testHeartbeatReportsQueueAndRequestedVersusEffectiveMode() throws {
        let server = Self.echoServer()
        defer { server.stop() }
        let store = CandidateStageTests.FakeCandidateStore()
        store.selection["hrv"] = SelectedProvider(providerId: "prov.v1", providerVersion: "1.0.0",
                                                  configVersion: "cfg-1", mode: "active",
                                                  requestedMode: "active", source: "default")
        let pending = FakePendingStore()
        var stage = makeStage(server: server, store: store, pending: pending)
        stage.beginDrain(budget: 0)
        stage.run(claim: Self.claim(), inputs: Self.inputs(enabled: ["hrv"]))
        stage.refreshPendingStats()
        let counters = stage.heartbeatCounters()
        XCTAssertEqual(counters["candidate_pending_queue"], 1)
        XCTAssertEqual(counters["candidate_skipped_budget"], nil, "existing keys stay in main.swift")
        let meta = stage.heartbeatMeta()
        XCTAssertEqual(meta["scheduling"] as? String, "persisted")
        let modes = try XCTUnwrap(meta["modes"] as? [String: [String: Any]])
        XCTAssertEqual(modes["hrv"]?["requested"] as? String, "active")
        XCTAssertEqual(modes["hrv"]?["effective"] as? String, "shadow")
        XCTAssertEqual(modes["hrv"]?["reason"] as? String, "active_promotion_deferred")
        let queue = try XCTUnwrap(meta["pending"] as? [String: Any])
        XCTAssertEqual((queue["by_reason"] as? [String: Int])?["budget"], 1)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: meta), "heartbeat meta must serialise")
    }

    // MARK: - Wire shapes

    func testClaimAndStatsParsersReadTheMigrationShapes() throws {
        let item = try XCTUnwrap(PhysiologyCandidatePendingSQL.parseItem("""
            {"user_id":"\(Self.user)","device_id":"\(Self.device)","period_day":"2026-10-01",
             "metric":"sleep_stage","input_revision":12,"provider_id":"p","provider_version":"1",
             "config_version":"c","requested_mode":"shadow","attempts":2,"last_reason":"timeout",
             "pending_since":"2026-10-01T00:00:00+00:00","lease_token":"5f0c6a52-6a77-4b5e-9a7f-2b0e1c3d4e5f",
             "lease_owner":"w","lease_until":"2026-10-01T00:05:00+00:00"}
            """))
        XCTAssertEqual(item.metric, "sleep_stage")
        XCTAssertEqual(item.inputRevision, 12)
        XCTAssertEqual(item.attempts, 2)
        XCTAssertEqual(item.lastReason, "timeout")
        XCTAssertNil(PhysiologyCandidatePendingSQL.parseItem(nil))
        let stats = try XCTUnwrap(PhysiologyCandidatePendingSQL.parseStats("""
            {"pending":5,"due":3,"leased":1,"oldest_pending_age_s":7201,"withheld_24h":1,"superseded_24h":0,
             "by_metric":{"hrv":2},"by_reason":{"busy":1,"new":4},"at":"2026-10-01T00:00:00+00:00"}
            """))
        XCTAssertEqual(stats.pending, 5)
        XCTAssertEqual(stats.oldestPendingAgeSeconds, 7201)
        XCTAssertEqual(stats.byReason["new"], 4)
        // Settle parameters follow the SQL's positional order.
        let params = PhysiologyCandidatePendingSQL.settleParameters(
            item, .retry(reason: "busy", countAttempt: false, retryAfterSeconds: 7), maxAttempts: 4)
        XCTAssertEqual(params.count, 12)
        XCTAssertEqual(Array(params[6...11]), ["retry", "busy", "", "false", "7", "4"])
    }
}
