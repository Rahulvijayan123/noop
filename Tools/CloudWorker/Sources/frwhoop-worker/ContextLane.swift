import Foundation
import StrandAnalytics

/// Lane 7: physiology context (docs/physiology-context/contracts.md §7). OFF unless `FRWHOOP_CONTEXT_ENABLED=1`.
///
/// One wake:
///   1. guard: the queue table and RPCs must exist (`to_regclass` / `to_regprocedure`); without them the lane
///      idles and says so (`context_tables_missing`), re-probing once a minute;
///   2. every `enqueueInterval` (default 120 s): `enqueue_physiology_context_days_v1` turns scoring completions,
///      placement and exposure revisions into context jobs (idempotent, bounded);
///   3. up to `budget` jobs: claim (a lease, committed before any long work) → renew → read every input in one
///      read-only snapshot (`ContextInputs.load`) → renew → `Engine.buildDay` (pure, no clock) → encode with
///      `PhysiologyContext.encoder()` → `publish_physiology_context_v1` (fenced on the live lease and the claimed
///      revision; idempotent on the (policy, input) fingerprint pair).
///
/// Settlement mirrors `ActivityLane`: a publish that did not apply (NULL, `applied=false`: lease lost or revision
/// moved) releases the lease through renew + fail with the CLAIMED revision, which the queue treats as a clean
/// release when the revision moved; a lost lease mid-job is `.stale` and nothing is failed; every other error is
/// settled through `fail_physiology_context_v1` with a sanitized one-line reason (bounded backoff, dead letter at
/// the queue's cap); a lost connection leaves the lease to expire.
///
/// Isolation: own connection, own thread, own lane state. The lane writes nothing but its own RPCs: never a
/// `noop_*`, `sessions`, scoring or series table, never `scoring_dirty_span` / `enqueue_scoring_v2`, never inside
/// a scoring transaction. A context failure is counted and retried and cannot reach scoring, series, BLE or
/// uploads.
struct ContextLane {
    typealias PC = PhysiologyContext

    let db: PostgresClient
    /// Recorded by the claim RPC (`p_worker`).
    var workerName: String = "frwhoop-worker"
    var leaseSeconds: Int = 300
    var enqueueIntervalSeconds: TimeInterval = 120
    /// Jobs one enqueue call may create or bump.
    var enqueueLimit: Int = 200
    var policy: PC.Policy = .default

    static let tablesProbeIntervalSeconds: TimeInterval = 60
    static let claimBackoffSeconds: TimeInterval = 60
    static let maxErrorLength = 300
    /// The publish RPC's document cap (`document_bytes between 2 and 16777216`, measured on the stored jsonb text,
    /// which is never shorter than the compact encoding). A larger document is refused here, before it is sent.
    static let maxDocumentBytes = 16_777_216

    struct Stats {
        var claimed = 0
        /// A new context revision was stored.
        var published = 0
        /// The publish matched the current revision's fingerprints: nothing new was stored.
        var unchanged = 0
        var failed = 0
        /// Later retrospective days the publish invalidated because this day's daily values changed.
        var cascaded = 0
        /// Publish did not apply (lease lost / revision moved); the lease was released.
        var notCompleted = 0
        /// The lease was lost (or a race was lost) before the publish; the queue owns the job again.
        var superseded = 0
        var failuresPersisted = 0
        var failuresUnsettled = 0
        var enqueued = 0
        var enqueueFailures = 0
        var claimFailures = 0
        /// Wakes that found the queue table or RPCs missing (the lane idles).
        var tablesMissing = 0
        /// Assemble + build + encode, per job.
        var builds = 0
        var buildMsTotal = 0
        var buildMsMax = 0
        /// Input reads, per job.
        var loadMsTotal = 0
        var loadMsMax = 0
        /// Stored bytes per job: summary document + every envelope table (contracts §6.1 stored form).
        var docBytesTotal = 0
        var docBytesMax = 0
        var summaryBytesTotal = 0
        var summaryBytesMax = 0
        /// All envelope tables of one job together.
        var tableBytesTotal = 0
        var tableBytesMax = 0
        var inputsRowsMax = 0
        var measurementsMax = 0
        /// `Engine.causalView` exclusions (telemetry only: the document never records them).
        var causalExcludedObservations = 0
        var causalExcludedRecords = 0
        var causalExcludedExposures = 0
        /// Optional inputs that could not be read, summed over jobs.
        var inputsUnavailable = 0
        var rowsSkipped = 0
        /// Daily values / bouts of the document not owned by the job's day (or mode), left out of the normalized
        /// rows the publish replaces (they stay in the document).
        var productsOutOfDay = 0
        /// Claims whose queue day bounds differed from the worker's (the worker's, i.e. scoring's, are used).
        var dayWindowMismatch = 0
        /// Documents over the publish cap (settled as a deterministic failure, never sent).
        var documentsTooLarge = 0
        var lastError: String?
        var lastErrorKind: String?
        var lastActivityAt: Date?

        /// The heartbeat's per-lane counters.
        var counters: [String: Int] {
            [
                "claimed": claimed, "published": published, "unchanged": unchanged, "failed": failed,
                "cascaded": cascaded, "not_completed": notCompleted, "superseded": superseded,
                "failures_persisted": failuresPersisted, "failures_unsettled": failuresUnsettled,
                "enqueued": enqueued, "enqueue_failures": enqueueFailures, "claim_failures": claimFailures,
                "context_tables_missing": tablesMissing,
                "builds": builds, "build_ms_total": buildMsTotal, "build_ms_max": buildMsMax,
                "build_ms_mean": builds > 0 ? buildMsTotal / builds : 0,
                "load_ms_total": loadMsTotal, "load_ms_max": loadMsMax,
                "doc_bytes_total": docBytesTotal, "doc_bytes_max": docBytesMax,
                "doc_bytes_mean": builds > 0 ? docBytesTotal / builds : 0,
                "summary_bytes_total": summaryBytesTotal, "summary_bytes_max": summaryBytesMax,
                "summary_bytes_mean": builds > 0 ? summaryBytesTotal / builds : 0,
                "table_bytes_total": tableBytesTotal, "table_bytes_max": tableBytesMax,
                "table_bytes_mean": builds > 0 ? tableBytesTotal / builds : 0,
                "inputs_rows_max": inputsRowsMax, "measurements_max": measurementsMax,
                "causal_excluded_observations": causalExcludedObservations,
                "causal_excluded_records": causalExcludedRecords,
                "causal_excluded_exposure_revisions": causalExcludedExposures,
                "inputs_unavailable": inputsUnavailable, "rows_skipped": rowsSkipped,
                "products_out_of_day": productsOutOfDay, "day_window_mismatch": dayWindowMismatch,
                "documents_too_large": documentsTooLarge,
            ]
        }
    }
    var stats = Stats()

    var tablesPresent: Bool?
    var tablesCheckedAt: Date?
    var lastEnqueueAt: Date?
    var backoffUntil: Date?
    /// Last reason written to stderr, so a failure that repeats on every wake is logged once.
    var lastLoggedReason: String?

    init(db: PostgresClient, workerName: String = "frwhoop-worker", leaseSeconds: Int = 300,
         enqueueIntervalSeconds: TimeInterval = 120, policy: PC.Policy = .default) {
        self.db = db
        self.workerName = workerName
        self.leaseSeconds = leaseSeconds
        self.enqueueIntervalSeconds = enqueueIntervalSeconds
        self.policy = policy
    }

    enum ContextError: Error, CustomStringConvertible {
        case deterministic(String)
        var description: String {
            switch self { case .deterministic(let d): return "context_deterministic: \(d)" }
        }
    }

    enum Outcome: Equatable {
        case published(revision: Int64, cascaded: Int)
        case unchanged(revision: Int64)
        /// The fenced publish did not apply; the lease was released.
        case fenced(reason: String)
    }

    private enum Cycle { case empty, done }

    // MARK: - Drain

    mutating func drain(budget: Int) {
        if let until = backoffUntil, Date() < until { return }
        do {
            try db.ensureConnected()
        } catch {
            record(error)
            return
        }
        guard checkTables() else { return }
        enqueueIfDue()
        for _ in 0..<max(1, budget) {
            do {
                if case .empty = try cycle() { return }
            } catch let e as PostgresClient.Error where e.kind == .connectionLost {
                record(e)
                return
            } catch {
                // The claim itself failed (a grant, a migration half applied): back off, say why once.
                stats.claimFailures += 1
                let why = Self.sanitize(error)
                note("claim failed: \(why)")
                stats.lastError = "context_claim: \(why)"
                stats.lastErrorKind = "context_claim"
                backoffUntil = Date().addingTimeInterval(Self.claimBackoffSeconds)
                if Self.isMissingObject(error) { tablesPresent = nil }
                return
            }
        }
    }

    /// The deploy-order guard: true when the queue and RPCs exist. Re-probed every minute while missing.
    mutating func checkTables() -> Bool {
        if tablesPresent == true { return true }
        if let at = tablesCheckedAt, tablesPresent == false,
           Date().timeIntervalSince(at) < Self.tablesProbeIntervalSeconds {
            stats.tablesMissing += 1
            return false
        }
        tablesCheckedAt = Date()
        let present = (try? db.query(ContextSQL.tablesPresent, []))?.first?["present"].map(isTrue) ?? false
        tablesPresent = present
        if present, stats.lastErrorKind == "context_tables_missing" { clearError() }
        if !present {
            stats.tablesMissing += 1
            stats.lastError = "context_tables_missing"
            stats.lastErrorKind = "context_tables_missing"
            note("physiology_context tables are not installed; the context lane idles")
        }
        return present
    }

    mutating func enqueueIfDue() {
        if let last = lastEnqueueAt, Date().timeIntervalSince(last) < enqueueIntervalSeconds { return }
        lastEnqueueAt = Date()
        do {
            let out = try db.callFunctionForJSON(ContextSQL.enqueue, [String(enqueueLimit)])
            stats.enqueued += Int((out ?? "").trimmingCharacters(in: .whitespaces)) ?? 0
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            record(e)
        } catch {
            stats.enqueueFailures += 1
            note("enqueue failed: \(Self.sanitize(error))")
        }
    }

    // MARK: - One job

    private mutating func cycle() throws -> Cycle {
        guard let row = try claimRow() else { return .empty }
        stats.claimed += 1
        guard let job = ContextInputs.parseJob(row) else {
            stats.failed += 1
            if let token = row["lease_token"], !token.isEmpty, let rev = Int64(row["input_revision"] ?? "") {
                settle(token: token, revision: rev, reason: "context_deterministic: malformed_job_row")
            }
            return .done
        }
        do {
            switch try process(job) {
            case .published(_, let cascaded):
                stats.published += 1
                stats.cascaded += cascaded
                stats.lastActivityAt = Date()
                clearError()
            case .unchanged:
                stats.unchanged += 1
                stats.lastActivityAt = Date()
                clearError()
            case .fenced:
                stats.notCompleted += 1
            }
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            stats.failuresUnsettled += 1
            throw e  // the lease expires and the queue hands the job out again
        } catch {
            let kind = (error as? PostgresClient.Error)?.kind ?? .other
            if kind == .stale || kind == .serialization {
                stats.superseded += 1
                return .done
            }
            stats.failed += 1
            let reason = Self.sanitize(error)
            note("job failed: \(reason)")
            stats.lastError = reason
            stats.lastErrorKind = "context_job"
            settle(token: job.leaseToken, revision: job.inputRevision, reason: reason)
        }
        return .done
    }

    /// The claim runs in its own committed transaction (with the service-role claim set), before any long work.
    func claimRow() throws -> [String: String]? {
        try db.withTransaction {
            try db.exec("SELECT set_config('request.jwt.claims', '{\"role\":\"service_role\"}', true)")
            return try db.query(ContextSQL.claim, [workerName, String(leaseSeconds)]).first
        }
    }

    /// Load, build and publish one claimed job. Internal so a scratch database can drive it directly.
    mutating func process(_ job: ContextInputs.Job) throws -> Outcome {
        guard let windows = ContextInputs.windows(day: job.day, timezoneId: job.timezoneId) else {
            throw ContextError.deterministic("invalid_job_day")
        }
        if let queue = job.queueDayWindow, queue != windows.dayWindow { stats.dayWindowMismatch += 1 }
        guard try renew(job) else { throw Self.leaseLost("before the input reads") }
        let loadStarted = Date()
        let loaded = try ContextInputs.load(db: db, job: job, windows: windows)
        let loadMS = Self.millis(since: loadStarted)
        guard try renew(job) else { throw Self.leaseLost("before the build") }

        let buildStarted = Date()
        let assembled = ContextInputs.assemble(loaded, job: job, windows: windows)
        let document = PC.Engine.buildDay(assembled.input, history: assembled.history, policy: policy)
        let products = try Self.encodeProducts(document)
        let buildMS = Self.millis(since: buildStarted)
        // The job's duration (reads + build) rides along for the queue's `last_duration_ms`.
        let built = Self.publishPayload(products, snapshot: loaded.snapshot, durationMS: loadMS + buildMS)
        noteTelemetry(loadMS: loadMS, buildMS: buildMS, built: built, assembled: assembled, loaded: loaded)
        do {
            try Self.checkDocumentSize(bytes: built.summaryBytes, envelopes: document.envelopes.count)
            try Self.checkDocumentSize(bytes: built.maxTableBytes, envelopes: document.envelopes.count)
        } catch {
            stats.documentsTooLarge += 1
            throw error
        }

        return try publish(job, payload: built.payloadText)
    }

    /// The fenced publish in its own transaction. NULL and `applied=false` are never success.
    mutating func publish(_ job: ContextInputs.Job, payload: String) throws -> Outcome {
        let text = try db.callFunctionForJSON(ContextSQL.publish,
                                              [job.leaseToken, String(job.inputRevision), payload])
        let result = Self.parsePublishResult(text)
        if result.applied, let revision = result.revision {
            return result.unchanged ? .unchanged(revision: revision)
                : .published(revision: revision, cascaded: result.cascadedDays)
        }
        try releaseLease(job, reason: result.reason)
        return .fenced(reason: result.reason)
    }

    private func renew(_ job: ContextInputs.Job) throws -> Bool {
        isTrue(try db.callFunctionForJSON(ContextSQL.renew, [job.leaseToken, String(leaseSeconds)]))
    }

    /// No bare release RPC: confirm the lease is still ours, then fail with the CLAIMED revision. The queue treats
    /// a revision mismatch as a clean release (no backoff); an unchanged revision counts one honest backoff.
    private mutating func releaseLease(_ job: ContextInputs.Job, reason: String) throws {
        guard try renew(job) else { return }
        _ = try db.callFunctionForJSON(
            ContextSQL.fail,
            [job.leaseToken, String(job.inputRevision), Self.releaseReason(claimedRevision: job.inputRevision,
                                                                           reason: reason)])
    }

    static func releaseReason(claimedRevision: Int64, reason: String) -> String {
        "context_publish_not_applied:claimed_revision=\(claimedRevision):\(sanitize(reason: reason))"
    }

    /// Persist a failure (bounded backoff / dead letter) in its own transaction; never throws. `failed` and
    /// `released` are settled; `lease_lost` / `lease_expired` leave the queue's expiry to recover the job.
    private mutating func settle(token: String, revision: Int64, reason: String) {
        do {
            let status = Self.failStatus(try db.callFunctionForJSON(ContextSQL.fail, [token, String(revision), reason]))
            if status == "failed" || status == "released" { stats.failuresPersisted += 1 }
            else { stats.failuresUnsettled += 1 }
        } catch {
            stats.failuresUnsettled += 1
        }
    }

    static func failStatus(_ text: String?) -> String {
        guard let text, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "unknown" }
        return (obj["status"] as? String) ?? "unknown"
    }

    // MARK: - Payload (contracts §6 publish_physiology_context_v1)

    /// The publish header: the document's identity, interpretation and version stamps.
    struct PublishHeader: Encodable, Equatable {
        var mode: PC.ProcessingMode
        var day: String
        var finality: PC.Finality
        var status: PC.ProductStatus
        var availabilityCutoff: Int
        var generatedAt: Int
        var contractVersion: String
        var schemaVersion: Int
        var policyFingerprint: String
        var inputFingerprint: String
        var versions: PC.PolicyVersions
    }

    static func header(of d: PC.DayDocument) -> PublishHeader {
        PublishHeader(mode: d.header.interpretation.mode, day: d.header.identity.day,
                      finality: d.header.interpretation.finality, status: d.status,
                      availabilityCutoff: d.header.interpretation.availabilityCutoff,
                      generatedAt: d.header.interpretation.generatedAt,
                      contractVersion: d.header.contractVersion, schemaVersion: d.header.schemaVersion,
                      policyFingerprint: d.header.policyFingerprint, inputFingerprint: d.header.inputFingerprint,
                      versions: d.header.versions)
    }

    /// The encoded products of one document, in the stored form (contracts §6.1): the summary document (envelopes
    /// split off, `envelope_index` set) and one interned `EnvelopeTable` per metric (`StoredDocument.split`).
    struct EncodedProducts {
        var header: PublishHeader
        var summaryText: String
        /// `(metric raw value, envelope count, table JSON)` in `MetricKind` order.
        var tables: [(metric: String, count: Int, text: String)]
        var boutsText: String
        var dailyValuesText: String
        var episodesText: String
        var frozenText: String
        /// Daily values / bouts left out of the normalized rows because another day (or mode) owns them.
        var outOfDay: Int
    }

    struct Built {
        var payloadText: String
        /// Summary document bytes (the `document` the RPC stores and caps).
        var summaryBytes: Int
        /// All envelope tables together, and the largest one.
        var tableBytes: Int
        var maxTableBytes: Int
        var header: PublishHeader
        var outOfDay: Int
        /// Summary + tables: what one revision stores.
        var documentBytes: Int { summaryBytes + tableBytes }
    }

    /// Split and encode with `PhysiologyContext.encoder()` (snake_case, sorted keys). The normalized `daily_values`
    /// and `bouts` are the document's items owned by the job's day (and mode for values): the RPC rejects any other,
    /// and a bout another day owns stays in this document but is that day's row to write.
    static func encodeProducts(_ d: PC.DayDocument) throws -> EncodedProducts {
        let encoder = PC.encoder()
        func text<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        let (summary, tables) = PC.StoredDocument.split(d)
        let day = d.header.identity.day, mode = d.header.interpretation.mode
        let values = d.dailyValues.filter { $0.day == day && $0.mode == mode }
        let bouts = d.bouts.filter { $0.day == day }
        return EncodedProducts(
            header: header(of: d), summaryText: try text(summary),
            tables: try tables.map { (metric: $0.metric.rawValue, count: $0.rows.count, text: try text($0)) },
            boutsText: try text(bouts), dailyValuesText: try text(values), episodesText: try text(d.episodes),
            frozenText: try text(d.newFrozenReferences),
            outOfDay: (d.dailyValues.count - values.count) + (d.bouts.count - bouts.count))
    }

    /// `{bouts, daily_values, document, duration_ms, envelope_tables, episodes, header, new_frozen_references,
    /// scoring_input_revision, scoring_result_revision}` (`publish_physiology_context_v1`, contracts §6/§6.1).
    /// `document` is the summary; `envelope_tables` is `[{envelope_count, metric, table}]`. The encoded parts are
    /// embedded byte for byte.
    static func publishPayload(_ p: EncodedProducts, snapshot: ContextInputs.Snapshot?,
                               durationMS: Int? = nil) -> Built {
        let header = (try? String(decoding: PC.encoder().encode(p.header), as: UTF8.self)) ?? "{}"
        let tables = p.tables.map { "{\"envelope_count\":\($0.count),\"metric\":\"\($0.metric)\",\"table\":\($0.text)}" }
        var parts: [(String, String)] = [
            ("bouts", p.boutsText),
            ("daily_values", p.dailyValuesText),
            ("document", p.summaryText),
        ]
        if let durationMS { parts.append(("duration_ms", String(max(0, durationMS)))) }
        parts += [
            ("envelope_tables", "[" + tables.joined(separator: ",") + "]"),
            ("episodes", p.episodesText),
            ("header", header),
            ("new_frozen_references", p.frozenText),
            ("scoring_input_revision", snapshot.map { String($0.inputRevision) } ?? "null"),
            ("scoring_result_revision", snapshot.map { String($0.resultRevision) } ?? "null"),
        ]
        let body = parts.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        let sizes = p.tables.map { $0.text.utf8.count }
        return Built(payloadText: "{" + body + "}", summaryBytes: p.summaryText.utf8.count,
                     tableBytes: sizes.reduce(0, +), maxTableBytes: sizes.max() ?? 0, header: p.header,
                     outOfDay: p.outOfDay)
    }

    /// Encode and assemble in one step (tests, tools).
    static func publishPayload(document d: PC.DayDocument, snapshot: ContextInputs.Snapshot?,
                               durationMS: Int? = nil) throws -> Built {
        publishPayload(try encodeProducts(d), snapshot: snapshot, durationMS: durationMS)
    }

    struct PublishResult: Equatable {
        var applied: Bool
        var revision: Int64?
        var reason: String
        var cascadedDays: Int
        var unchanged: Bool
    }

    /// `{applied, context_revision, reason, cascaded_days}`; NULL / unparsable → not applied. The RPC reports an
    /// identical (policy, input) fingerprint pair as `applied: false, reason: unchanged` WITH the existing
    /// revision and completes the job; that is success, not a fence.
    static func parsePublishResult(_ text: String?) -> PublishResult {
        guard let text, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return PublishResult(applied: false, revision: nil, reason: "null_result", cascadedDays: 0,
                                 unchanged: false)
        }
        let applied = (obj["applied"] as? Bool) ?? false
        let revision = (obj["context_revision"] as? NSNumber)?.int64Value
            ?? (obj["context_revision"] as? String).flatMap { Int64($0) }
        let reason = (obj["reason"] as? String) ?? (applied ? "published" : "not_applied")
        let cascaded: Int
        if let n = obj["cascaded_days"] as? NSNumber { cascaded = n.intValue }
        else if let a = obj["cascaded_days"] as? [Any] { cascaded = a.count }
        else { cascaded = 0 }
        let unchanged = reason == "unchanged" && revision != nil
        return PublishResult(applied: applied || unchanged, revision: revision, reason: reason,
                             cascadedDays: cascaded, unchanged: unchanged)
    }

    // MARK: - Telemetry and errors

    private mutating func noteTelemetry(loadMS: Int, buildMS: Int, built: Built,
                                        assembled: ContextInputs.Assembled, loaded: ContextInputs.Loaded) {
        stats.builds += 1
        stats.buildMsTotal += buildMS
        stats.buildMsMax = max(stats.buildMsMax, buildMS)
        stats.loadMsTotal += loadMS
        stats.loadMsMax = max(stats.loadMsMax, loadMS)
        stats.docBytesTotal += built.documentBytes
        stats.docBytesMax = max(stats.docBytesMax, built.documentBytes)
        stats.summaryBytesTotal += built.summaryBytes
        stats.summaryBytesMax = max(stats.summaryBytesMax, built.summaryBytes)
        stats.tableBytesTotal += built.tableBytes
        stats.tableBytesMax = max(stats.tableBytesMax, built.tableBytes)
        stats.inputsRowsMax = max(stats.inputsRowsMax, assembled.rowCount)
        stats.measurementsMax = max(stats.measurementsMax, assembled.measurementCount)
        for d in assembled.causalExcluded {
            switch d.name {
            case "causal_excluded_observations": stats.causalExcludedObservations += Int(d.value)
            case "causal_excluded_records": stats.causalExcludedRecords += Int(d.value)
            case "causal_excluded_exposure_revisions": stats.causalExcludedExposures += Int(d.value)
            default: break
            }
        }
        stats.inputsUnavailable += loaded.unavailable.count
        stats.rowsSkipped += loaded.skippedRows
        stats.productsOutOfDay += built.outOfDay
    }

    private mutating func clearError() {
        stats.lastError = nil
        stats.lastErrorKind = nil
        lastLoggedReason = nil
    }

    private mutating func record(_ error: Error) {
        stats.lastError = Self.sanitize(error)
        stats.lastErrorKind = (error as? PostgresClient.Error)?.kind.rawValue ?? "other"
    }

    /// Write a lane problem to stderr once per distinct reason.
    private mutating func note(_ reason: String) {
        guard reason != lastLoggedReason else { return }
        lastLoggedReason = reason
        FileHandle.standardError.write("frwhoop-worker: context lane: \(reason)\n".data(using: .utf8)!)
    }

    /// A document over the publish cap is a deterministic failure of this input (bounded retry, dead letter), not
    /// something to send: the RPC would refuse it after the transfer.
    static func checkDocumentSize(bytes: Int, envelopes: Int) throws {
        guard bytes <= maxDocumentBytes else {
            throw ContextError.deterministic("document_too_large bytes=\(bytes) envelopes=\(envelopes)")
        }
    }

    static func leaseLost(_ when: String) -> PostgresClient.Error {
        PostgresClient.Error(message: "context lease lost \(when)", sqlstate: "55000", kind: .stale)
    }

    static func millis(since start: Date) -> Int { max(0, Int(Date().timeIntervalSince(start) * 1000)) }

    /// A missing relation / function (the migration is not, or only partly, applied).
    static func isMissingObject(_ error: Error) -> Bool {
        guard let e = error as? PostgresClient.Error else { return false }
        return e.sqlstate == "42P01" || e.sqlstate == "42883"
    }

    /// A one-line, bounded reason that never carries row data: the first line of the message (Postgres DETAIL /
    /// CONTEXT lines can quote values), control characters removed, UUIDs masked, at most 300 characters,
    /// prefixed with the error kind.
    static func sanitize(_ error: Error) -> String {
        let kind: String
        if let e = error as? PostgresClient.Error { kind = e.kind.rawValue }
        else if error is ContextError { kind = "deterministic" }
        else { kind = "other" }
        let message: String
        if let e = error as? PostgresClient.Error { message = e.message + (e.sqlstate.map { " sqlstate=\($0)" } ?? "") }
        else { message = String(describing: error) }
        return "context_\(kind): " + sanitize(reason: message)
    }

    static func sanitize(reason text: String) -> String {
        let firstLine = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        var cleaned = String(firstLine.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init))
        if let regex = try? NSRegularExpression(
            pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") {
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned),
                                                     withTemplate: "<uuid>")
        }
        return String(cleaned.prefix(maxErrorLength))
    }
}
