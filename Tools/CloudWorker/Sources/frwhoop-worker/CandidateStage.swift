import Foundation

// MARK: - Candidate ("shadow"/"active") lane stage
//
// The candidate stage runs AFTER the canonical snapshot transaction has
// COMMITTED. That ordering is the whole design:
//
//   * The v2 scoring path holds one REPEATABLE READ transaction across claim,
//     input load, compute and publish (`ScoringLane.runV2Once`), and the fleet
//     path holds its publish transaction (`ScoringLane.publishAndFinishFleet`).
//     A Python inference call inside either one would add seconds of latency to a
//     transaction that already holds locks uploads deadlock against.
//   * Inference happens with NO transaction open. The write happens afterwards in
//     its own fresh committed transaction, the same shape as the existing
//     post-commit dense-series write that the deployment findings record as
//     `publish_metric_series_v1`. NOTE: that series write lives only in the
//     uncommitted `/noop` checkout, NOT at this branch's base 59f0415a, so it is
//     cited as a precedent rather than as code in this tree.
//     Symbols are named instead of numbered here because line numbers drift.
//
// Failure isolation: every failure — refused, timeout, non-200, malformed,
// not_ready — settles as a WITHHELD candidate with a machine-readable reason. It
// never blocks, delays or alters the canonical publish, and it never retries
// without bound.
//
// Scheduling (docs/model-integration/runtime-bounds.md). With the pending store
// (`20261008110000_physiology_candidate_pending.sql`) every enabled metric of a
// scored day becomes a persisted pending item at the claim's input revision, and
// each drain runs the OLDEST due items first, across metrics and days, within
// the drain's run budget and wall-clock cap. A budget, deadline or busy skip
// leaves the item pending with that reason; it is never recorded as a result.
// Transient failures (timeout, refused, not_ready) retry with backoff in later
// drains and settle as a withheld row after `pendingMaxAttempts`; deterministic
// outcomes settle at once. An item whose day is not being re-scored gets its
// inputs re-assembled read-only by `CandidateInputAssembling` (DayScorer's own
// assembly). Without the store (migration not applied) the stage falls back to
// the in-memory pass below, ordered least-recently-run first.

/// One metric's selected provider, from `physiology_selected_provider`.
struct SelectedProvider: Equatable {
    let providerId: String
    let providerVersion: String
    let configVersion: String
    /// `off` | `shadow` | `active`: the mode after the promotion gate (an `active`
    /// request without a live signed approval is demoted to `shadow`).
    let mode: String
    /// What the selection asked for (`requested_mode`; derived from `source` when the
    /// database predates 20261008110000).
    var requestedMode: String? = nil
    /// `default` | `user_override` | `..._demoted_unapproved` | `unset`.
    var source: String? = nil
    /// The gate's reason for a demotion (`promotion_approval_required`,
    /// `promotion_gate_unavailable`), when the database reports one.
    var demotionReason: String? = nil

    var isOff: Bool { mode == "off" }
    var isActive: Bool { mode == "active" }
    var isShadow: Bool { mode == "shadow" }

    /// The mode the selection requested.
    var requested: String {
        if let requestedMode, !requestedMode.isEmpty { return requestedMode }
        return (source ?? "").hasSuffix("_demoted_unapproved") ? "active" : mode
    }

    /// An `active` request the promotion gate demoted. The record RPC refuses every
    /// write for such a selection, so the stage withholds it without calling the sidecar.
    var isDemoted: Bool { requested == "active" && mode != "active" }

    /// What a candidate of this selection actually is downstream: `shadow` for every
    /// computed mode. No validated selection path publishes canonical physiology from a
    /// candidate, so an approved `active` is still recorded only as evidence.
    var effectiveMode: String { isOff ? "off" : "shadow" }

    /// Why the effective mode differs from the requested one, or nil.
    var modeReason: String? {
        if isDemoted { return demotionReason ?? "promotion_approval_required" }
        if isActive { return "active_promotion_deferred" }
        return nil
    }

    /// Parse the RPC's jsonb object; nil for `off` or an unconfigured metric.
    static func parse(_ obj: [String: Any]) -> SelectedProvider? {
        let mode = (obj["mode"] as? String) ?? "off"
        let providerId = (obj["provider_id"] as? String) ?? ""
        if mode == "off" || providerId.isEmpty { return nil }
        return SelectedProvider(
            providerId: providerId,
            providerVersion: (obj["provider_version"] as? String) ?? "unknown",
            configVersion: (obj["config_version"] as? String) ?? "unknown",
            mode: mode,
            requestedMode: obj["requested_mode"] as? String,
            source: obj["source"] as? String,
            demotionReason: obj["demoted"] as? Bool == true ? obj["mode_reason"] as? String : nil)
    }
}

/// Requested vs effective mode of one metric, as last seen by the stage (heartbeat).
struct CandidateModeReport: Equatable {
    let requested: String
    let effective: String
    let reason: String?
    let providerId: String
}

/// A validated candidate result, ready to be recorded.
struct CandidateRecord {
    let userId: String
    let deviceId: String
    let metric: String
    let periodDay: String
    let intervalStart: Date
    let intervalEnd: Date
    let inputSHA256: String
    let providerId: String
    let providerVersion: String
    let adapterVersion: String
    let preprocessingVersion: String
    let configVersion: String
    let dependencyVersions: [String: String]
    /// `ok` | `withheld` | `error`.
    let status: String
    let withheldReason: String?
    let value: Double?
    let unit: String?
    let stages: JSONValue?
    let labelSpace: String?
    let coverage: JSONValue?
    let diagnostics: JSONValue?
    let runtimeMS: Int?
    /// `shadow` | `active`. NOT a parameter of the record RPC: the migration
    /// derives the stored publication mode from the current selection. Kept here
    /// for the active-promotion plumbing and for diagnostics.
    let mode: String
    /// `provisional` | `final`. Also not a record-RPC parameter (the migration
    /// owns the default); kept for the same reason as `mode`.
    let finality: String
    /// The guard the record RPC checks against the day's current revision.
    let inputRevision: Int64

    /// The DB uniqueness key (`physiology_candidate_results` UNIQUE) as one
    /// string. A replay with the same inputs produces the same key, so the
    /// `ON CONFLICT DO NOTHING` insert is idempotent by construction.
    var idempotencyKey: String {
        [userId, deviceId, metric, periodDay, iso(intervalStart), inputSHA256,
         providerId, providerVersion, configVersion].joined(separator: "|")
    }

    private func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }
}

/// The DB-facing side of the candidate lane, behind a protocol so the whole stage
/// is unit-testable without a database.
protocol CandidateStore {
    /// The selected provider for a metric, or nil when nothing is configured.
    func selectedProvider(userId: String, metric: String) throws -> SelectedProvider?
    /// The instant candidate debt was last invalidated for this day, or nil.
    func candidateDebtInvalidatedAt(userId: String, deviceId: String, day: String) throws -> Date?
    /// False when the user is deleted or the device is inactive: no candidate may
    /// be computed or recorded for them (spec section 4, rule 6).
    func candidateOwnerIsLive(userId: String, deviceId: String) throws -> Bool
    /// Record one candidate. Returns the new candidate id, or nil when the row
    /// already existed (idempotent replay) or the guard rejected it.
    func recordCandidate(_ record: CandidateRecord) throws -> String?
}

// MARK: - Pending candidate work (persisted, fair)

/// One claimed pending item (`physiology_candidate_pending_claim`).
struct CandidatePendingItem: Equatable {
    let userId: String
    let deviceId: String
    let day: String
    let metric: String
    /// The input revision the item was created for; every write and settle is fenced on it.
    let inputRevision: Int64
    let providerId: String
    let providerVersion: String
    let configVersion: String
    /// Attempts that ran (busy, budget and deadline skips do not count).
    let attempts: Int
    let leaseToken: String
    let lastReason: String?
}

/// One metric of a scored day, as handed to `physiology_candidate_pending_enqueue`.
struct CandidatePendingEntry: Equatable {
    let metric: String
    let providerId: String
    let providerVersion: String
    let configVersion: String
    let requestedMode: String
    /// False when the scoring pass could build no payload for the metric: the item is
    /// recorded at once as withheld `no_input` for this revision, nothing is called.
    let hasInput: Bool
}

/// How a claimed item leaves this drain.
enum CandidatePendingSettlement: Equatable {
    /// It ran; its row was recorded (`candidateId`) or was already present / fenced.
    case done(reason: String, candidateId: String?)
    /// It will not run at this revision, for `reason` (`no_input`, a demoted `active`,
    /// attempts exhausted — the last one with the withheld row it recorded).
    case withheld(reason: String, candidateId: String?)
    /// It no longer applies (newer revision, selection off, owner gone).
    case superseded(reason: String)
    /// It stays pending: due again after `retryAfterSeconds`; only a real attempt counts.
    case retry(reason: String, countAttempt: Bool, retryAfterSeconds: Int)

    /// Whether the item's `attempts` grows: only when a computation really ran.
    var countsAttempt: Bool {
        switch self {
        case .done: return true
        case .withheld(let reason, _): return reason.hasPrefix("attempts_exhausted:")
        case .superseded: return false
        case .retry(_, let count, _): return count
        }
    }
}

/// Queue state for the heartbeat (`physiology_candidate_pending_stats`).
struct CandidatePendingStats: Equatable {
    var pending = 0
    var due = 0
    var leased = 0
    var oldestPendingAgeSeconds = 0
    var withheldLast24h = 0
    var supersededLast24h = 0
    var byMetric: [String: Int] = [:]
    var byReason: [String: Int] = [:]
}

/// The persisted queue, behind a protocol so the scheduler is testable without a database.
protocol CandidatePendingStore {
    /// False when the migration is not applied: the stage then schedules in memory.
    func isAvailable() -> Bool
    /// Insert or re-revision one day's items; returns how many rows changed.
    func enqueue(userId: String, deviceId: String, day: String, inputRevision: Int64,
                 entries: [CandidatePendingEntry]) throws -> Int
    /// The oldest due item, leased to `owner`, or nil. Stale-revision items are superseded
    /// inside the call and never returned.
    func claim(owner: String, leaseSeconds: Int) throws -> CandidatePendingItem?
    /// Settle under the item's lease. False when the lease was lost (expired or reset by a
    /// newer revision): nothing changed.
    func settle(_ item: CandidatePendingItem, _ settlement: CandidatePendingSettlement,
                maxAttempts: Int) throws -> Bool
    /// The day's current input revision (the record RPC's own fence), or nil.
    func currentRevision(userId: String, deviceId: String, day: String) throws -> Int64?
    func stats() throws -> CandidatePendingStats
}

/// Candidate inputs for a day that is not being scored right now, re-assembled read-only by
/// `DayScorer`'s own assembly, outside any scoring transaction.
struct CandidateAssembly {
    let inputs: DayScorer.CandidateInputs
    let timezoneId: String
}

protocol CandidateInputAssembling {
    func assemble(userId: String, deviceId: String, day: String,
                  inputRevision: Int64) throws -> CandidateAssembly
}

/// The candidate stage: per-metric provider selection, a bounded sidecar call,
/// and a bounded write.
struct CandidateStage {
    let client: InferenceClient
    let store: CandidateStore
    /// Attempts per sidecar call on the in-memory path. Bounded by contract; never unbounded.
    var maxAttempts: Int = 2

    /// The persisted queue; nil (or unavailable) means in-memory scheduling.
    var pending: CandidatePendingStore?
    /// Real attempts a pending item gets before it settles as a withheld row.
    var pendingMaxAttempts = 4
    var pendingLeaseSeconds = 300
    /// Written as the lease owner (the worker's name).
    var pendingOwner = "frwhoop-worker"
    /// Read-only input re-assemblies (a whole day's load + analysis) per drain.
    var reassemblyBudget = 1
    /// Claims per drain, including items settled without a sidecar call.
    var maxClaimsPerDrain = 16
    /// How often an idle drain looks at the queue, and how often its stats are read.
    var backlogIntervalSeconds: TimeInterval = 15
    var statsIntervalSeconds: TimeInterval = 60

    struct Stats {
        /// Sidecar calls attempted (including retries).
        var calls = 0
        /// Candidate runs started (one per metric per claimed day).
        var runs = 0
        var ok = 0
        var withheld = 0
        var errors = 0
        var recorded = 0
        /// The record RPC returned NULL, so nothing new was written. The RPC
        /// cannot distinguish the reasons (row already present, mode off, provider
        /// triple no longer selected, user deleted, device not owned, stale input
        /// revision); none of them is an error.
        var duplicates = 0
        var skippedOff = 0
        var skippedStaleDebt = 0
        var skippedDeletedUser = 0
        var skippedNoInput = 0
        /// Work left for a later drain because the run budget was spent. On the
        /// persisted path the item stays pending with reason `budget`.
        var skippedBudget = 0
        /// Metrics not attempted because the drain's wall-clock cap was reached.
        var skippedDeadline = 0
        /// `active` requests the promotion gate demoted: withheld without a call, because
        /// the record RPC refuses every write for them.
        var skippedDemoted = 0
        /// Sidecar `busy` answers. Never recorded; the work stays pending.
        var busy = 0
        /// Answers for a provider the sidecar has quarantined (nothing ran). Never recorded.
        var quarantined = 0
        var writeFailures = 0
        /// Active-mode substitutions produced. Zero while every metric is `off`.
        var activeSubstitutions = 0
        // Persisted scheduling.
        var pendingEnqueued = 0
        var pendingClaimed = 0
        var pendingDone = 0
        var pendingWithheld = 0
        var pendingSuperseded = 0
        /// Items put back to pending (transient failure, busy, budget, deadline).
        var pendingRetried = 0
        /// Settles refused because the lease was lost, plus settle errors.
        var pendingSettleRefused = 0
        var reassembled = 0
        var reassemblyFailures = 0
        var pendingStoreAvailable: Bool?
        var pendingQueue: CandidatePendingStats?
        var pendingQueueAt: Date?
        /// Requested vs effective mode per metric, as last seen.
        var modes: [String: CandidateModeReport] = [:]
        var lastError: String?
        var lastProviderId: String?
        var lastWithheldReason: String?
        var lastRuntimeMS: Int?
        var lastCallAt: Date?
    }
    var stats = Stats()

    /// Candidate runs still available in this drain (`FRWHOOP_INFERENCE_BUDGET`).
    private var runsRemaining = 0

    /// R4: wall-clock cap for the WHOLE candidate stage in one drain. The scoring
    /// lane thread runs this synchronously, so without a cap a stalled sidecar
    /// could hold it for runs(2) x attempts(2) x (timeout 20 s + slack 1.5 s) =
    /// ~86 s, i.e. no scoring throughput at all during the stall.
    ///
    /// With the cap, each attempt's deadline is `min(client timeout, remaining)`
    /// and the stage stops once the drain budget is spent, so the worst case is
    /// about `maxDrainSeconds + InferenceClient.deadlineSlackMS`. 30 s keeps the
    /// whole stall well inside the worker's `TimeoutStopSec=90`.
    var maxDrainSeconds: TimeInterval = 30
    /// Floor below which an attempt is not worth starting.
    static let minAttemptSeconds: TimeInterval = 0.25
    /// Backoff between the two transient attempts: an immediate retry against a
    /// sidecar that just proved it cannot answer inside the deadline is wasted work.
    static let retryBackoffSeconds: TimeInterval = 0.25

    /// When the current drain's candidate work must stop. Set by `beginDrain`.
    private var drainDeadline = Date.distantPast
    /// Set by a `busy` answer: no further call in this drain.
    private var sidecarBusy = false
    /// Selections read in this drain, keyed `user|metric` (nil = off).
    private var selectionCache: [String: SelectedProvider?] = [:]
    /// In-memory path: when each metric last ran, for least-recently-run ordering.
    private var lastRunAt: [String: Date] = [:]
    private var lastBacklogAt = Date.distantPast
    private var lastBacklogFoundWork = false

    /// The `active`-mode `ok` result of the latest `run`, if any. Always nil while every
    /// metric is `off` (the shipped defaults), which is what makes the active
    /// promotion plumbing unreachable in production today.
    private(set) var lastActiveSubstitution: ActiveHrvSubstitution?

    init(client: InferenceClient, store: CandidateStore, maxAttempts: Int = 2,
         pending: CandidatePendingStore? = nil) {
        self.client = client
        self.store = store
        self.maxAttempts = max(1, maxAttempts)
        self.pending = pending
    }

    /// Reset the per-drain run budget and wall-clock deadline. Called once at the
    /// top of a drain.
    mutating func beginDrain(budget: Int) {
        runsRemaining = max(0, budget)
        drainDeadline = Date().addingTimeInterval(max(0, maxDrainSeconds))
        sidecarBusy = false
        selectionCache = [:]
    }

    /// Attempts that are worth one bounded retry. A malformed body or a non-200
    /// status is deterministic: retrying it in the same drain cannot help. A `busy`
    /// answer is transient but never retried in the drain: the work stays pending
    /// and the drain stops calling (backpressure).
    static func isRetryable(_ error: InferenceClientError) -> Bool {
        switch error {
        case .timeout, .refused, .transport, .notReady: return true
        case .busy, .disabled, .nonLoopbackURL, .non200, .malformed: return false
        }
    }

    /// Value bounds per metric, copied VERBATIM from the authoritative check in
    /// `supabase/migrations/20261002090000_physiology_candidate_providers.sql`
    /// (`physiology_record_candidate_result`, the `candidate_value_out_of_bounds`
    /// raise; lines 452-455 at migration revision of 2026-10-01):
    ///
    ///   if (p_metric='hrv' and p_value not between 0 and 1000)
    ///     or (p_metric='respiration' and p_value not between 4 and 40)
    ///     or (p_metric in ('sleep_boundary','sleep_stage')
    ///         and p_value not between -1000000000 and 1000000000) then
    ///     raise exception 'candidate_value_out_of_bounds' using errcode='22023';
    ///
    /// A value outside these bounds is settled client-side as a withheld
    /// `provider_error` row (with the rejected number kept in diagnostics) rather
    /// than sent and rejected with 22023. Keeping the two in step is what makes
    /// that settlement possible, so this table must follow the migration, not the
    /// other way round.
    static func bounds(for metric: String) -> ClosedRange<Double>? {
        switch metric {
        case "hrv": return 0.0...1_000.0                        // RMSSD, milliseconds
        case "respiration": return 4.0...40.0                    // breaths per minute
        case "sleep_boundary", "sleep_stage":
            return -1_000_000_000.0...1_000_000_000.0            // scalar stage/boundary values
        default: return nil                                      // unknown metric: no client gate
        }
    }

    /// The metrics this stage will consider. The order is only a tie-break: the persisted
    /// queue runs the oldest work first and the in-memory path the least recently run.
    static let metrics = ["hrv", "sleep_boundary", "sleep_stage", "respiration"]

    /// Backoff before a pending item's next real attempt: 30 s, 60 s, 120 s, ... capped at 1 h.
    static func pendingBackoffSeconds(attempts: Int) -> Int {
        min(3_600, 30 * (1 << min(7, max(0, attempts - 1))))
    }

    /// Persisted-scheduling knobs (docs/model-integration/runtime-bounds.md). `store` is used
    /// unless `FRWHOOP_CANDIDATE_SCHEDULER=memory`; out-of-range values are clamped.
    mutating func configurePending(_ store: CandidatePendingStore?, environment: [String: String],
                                   owner: String) {
        func int(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            let raw = (environment[key] ?? "").trimmingCharacters(in: .whitespaces)
            return min(range.upperBound, max(range.lowerBound, Int(raw) ?? fallback))
        }
        let scheduler = (environment["FRWHOOP_CANDIDATE_SCHEDULER"] ?? "").trimmingCharacters(in: .whitespaces)
        pending = scheduler.lowercased() == "memory" ? nil : store
        pendingOwner = owner.isEmpty ? "frwhoop-worker" : String(owner.prefix(200))
        pendingMaxAttempts = int("FRWHOOP_CANDIDATE_MAX_ATTEMPTS", 4, 1...20)
        reassemblyBudget = int("FRWHOOP_CANDIDATE_REASSEMBLY_BUDGET", 1, 0...4)
        pendingLeaseSeconds = int("FRWHOOP_CANDIDATE_LEASE_SECONDS", 300, 60...3600)
    }

    /// `persisted` (pending store in use), `in_memory` (no store, or the migration is absent),
    /// `unknown` (configured, not probed yet).
    var schedulingMode: String {
        guard pending != nil else { return "in_memory" }
        guard let available = stats.pendingStoreAvailable else { return "unknown" }
        return available ? "persisted" : "in_memory"
    }

    /// Scheduling counters for the scoring lane's heartbeat counters (additive keys).
    func heartbeatCounters() -> [String: Int] {
        var out: [String: Int] = [
            "candidate_busy": stats.busy,
            "candidate_provider_quarantined": stats.quarantined,
            "candidate_skipped_demoted": stats.skippedDemoted,
            "candidate_pending_enqueued": stats.pendingEnqueued,
            "candidate_pending_claimed": stats.pendingClaimed,
            "candidate_pending_done": stats.pendingDone,
            "candidate_pending_withheld": stats.pendingWithheld,
            "candidate_pending_superseded": stats.pendingSuperseded,
            "candidate_pending_retried": stats.pendingRetried,
            "candidate_pending_settle_refused": stats.pendingSettleRefused,
            "candidate_reassembled": stats.reassembled,
            "candidate_reassembly_failures": stats.reassemblyFailures,
        ]
        if let queue = stats.pendingQueue {
            out["candidate_pending_queue"] = queue.pending
            out["candidate_pending_due"] = queue.due
            out["candidate_pending_oldest_age_s"] = queue.oldestPendingAgeSeconds
        }
        return out
    }

    /// Scheduling state and per-metric modes for `meta.inference.candidate` (additive keys).
    func heartbeatMeta() -> [String: Any] {
        var out: [String: Any] = [
            "scheduling": schedulingMode,
            "busy": stats.busy,
            "skipped_demoted": stats.skippedDemoted,
        ]
        if let queue = stats.pendingQueue {
            out["pending"] = [
                "pending": queue.pending, "due": queue.due, "leased": queue.leased,
                "oldest_pending_age_s": queue.oldestPendingAgeSeconds,
                "withheld_24h": queue.withheldLast24h, "superseded_24h": queue.supersededLast24h,
                "by_metric": queue.byMetric, "by_reason": queue.byReason,
            ] as [String: Any]
        }
        if !stats.modes.isEmpty {
            out["modes"] = stats.modes.mapValues { report -> [String: Any] in
                var entry: [String: Any] = ["requested": report.requested, "effective": report.effective,
                                            "provider_id": report.providerId]
                if let reason = report.reason { entry["reason"] = reason }
                return entry
            }
        }
        return out
    }

    /// The pending store when it can be used now; records availability for the heartbeat.
    private mutating func activePendingStore() -> CandidatePendingStore? {
        guard let pending else { return nil }
        let available = pending.isAvailable()
        stats.pendingStoreAvailable = available
        return available ? pending : nil
    }

    /// Run the candidate lane for one claimed day. Never throws: every failure is
    /// settled as a withheld candidate or left pending, and recorded in `stats`.
    mutating func run(claim: DayScorer.Claim, inputs: DayScorer.CandidateInputs,
                      assembler: CandidateInputAssembling? = nil) {
        lastActiveSubstitution = nil
        guard let pending = activePendingStore() else {
            runInMemory(claim: claim, inputs: inputs)
            return
        }
        enqueue(pending, claim: claim, inputs: inputs)
        drainPending(pending, current: CandidateAssembly(inputs: inputs, timezoneId: claim.timezoneId),
                     assembler: assembler)
    }

    /// Pending work when no day was scored in this drain (the scoring queue is empty).
    /// Throttled to one look per `backlogIntervalSeconds` unless the last look found work.
    mutating func drainBacklog(assembler: CandidateInputAssembling?, now: Date = Date()) {
        guard pending != nil else { return }
        guard lastBacklogFoundWork || now.timeIntervalSince(lastBacklogAt) >= backlogIntervalSeconds else {
            return
        }
        lastBacklogAt = now
        guard let store = activePendingStore() else { return }
        let before = backlogProgress
        drainPending(store, current: nil, assembler: assembler)
        // Skip the idle throttle only after real progress. A drain that only re-queued its head
        // (budget, deadline, awaiting assembly) waits out the interval like an empty one.
        lastBacklogFoundWork = backlogProgress > before
    }

    /// Calls made, items settled for good, and inputs assembled: what counts as backlog progress.
    private var backlogProgress: Int {
        stats.calls + stats.pendingDone + stats.pendingWithheld + stats.pendingSuperseded + stats.reassembled
    }

    /// Re-assembled inputs kept across drains. A whole-day re-assembly can use up a drain's
    /// wall-clock cap before the call starts; the next drain then calls with these inputs
    /// instead of assembling the same day again (which would never leave time to call).
    private var assemblyCache: [(key: String, assembly: CandidateAssembly)] = []
    static let assemblyCacheLimit = 2

    private mutating func cacheAssembly(_ key: String, _ assembly: CandidateAssembly) {
        assemblyCache.removeAll { $0.key == key }
        assemblyCache.append((key, assembly))
        if assemblyCache.count > Self.assemblyCacheLimit {
            assemblyCache.removeFirst(assemblyCache.count - Self.assemblyCacheLimit)
        }
    }

    private mutating func evictAssembly(_ key: String) {
        assemblyCache.removeAll { $0.key == key }
    }

    /// Read the queue's stats for the heartbeat, at most once per `statsIntervalSeconds`.
    mutating func refreshPendingStats(now: Date = Date()) {
        if let at = stats.pendingQueueAt, now.timeIntervalSince(at) < statsIntervalSeconds { return }
        guard let store = activePendingStore() else { return }
        stats.pendingQueueAt = now
        do {
            stats.pendingQueue = try store.stats()
        } catch {
            stats.lastError = "candidate pending stats failed: \(String(describing: error))"
        }
    }

    // MARK: Selection and modes

    private mutating func selection(userId: String, metric: String) throws -> SelectedProvider? {
        let key = "\(userId)|\(metric)"
        if let cached = selectionCache[key] { return cached }
        let selection = try store.selectedProvider(userId: userId, metric: metric)
        selectionCache[key] = selection
        if let selection {
            stats.modes[metric] = CandidateModeReport(requested: selection.requested,
                                                      effective: selection.effectiveMode,
                                                      reason: selection.modeReason,
                                                      providerId: selection.providerId)
        }
        return selection
    }

    // MARK: Persisted path

    private mutating func enqueue(_ pending: CandidatePendingStore, claim: DayScorer.Claim,
                                  inputs: DayScorer.CandidateInputs) {
        var entries: [CandidatePendingEntry] = []
        for metric in CandidateStage.metrics {
            let selection: SelectedProvider?
            do {
                selection = try self.selection(userId: claim.userId, metric: metric)
            } catch {
                stats.lastError = "candidate store (selection) failed: \(String(describing: error))"
                continue
            }
            guard let selection, !selection.isOff else {
                stats.skippedOff += 1
                continue
            }
            entries.append(CandidatePendingEntry(
                metric: metric, providerId: selection.providerId,
                providerVersion: selection.providerVersion, configVersion: selection.configVersion,
                requestedMode: selection.requested == "active" ? "active" : "shadow",
                hasInput: inputs.input(for: metric) != nil))
        }
        guard !entries.isEmpty else { return }
        do {
            stats.pendingEnqueued += try pending.enqueue(
                userId: claim.userId, deviceId: claim.deviceId, day: claim.day,
                inputRevision: claim.inputRevision, entries: entries)
        } catch {
            stats.lastError = "candidate pending enqueue failed: \(String(describing: error))"
        }
    }

    /// Oldest-first over the whole queue. Budget and deadline are checked after a claim on
    /// purpose: the item then waits with a stated reason instead of an invisible skip.
    private mutating func drainPending(_ pending: CandidatePendingStore, current: CandidateAssembly?,
                                       assembler: CandidateInputAssembling?) {
        var assembled: [String: CandidateAssembly] = [:]
        if let current {
            assembled[Self.assemblyKey(current.inputs.userId, current.inputs.deviceId,
                                       current.inputs.day, current.inputs.inputRevision)] = current
        }
        for entry in assemblyCache where assembled[entry.key] == nil {
            assembled[entry.key] = entry.assembly
        }
        var assemblies = 0
        var claims = 0
        while claims < maxClaimsPerDrain, !sidecarBusy {
            let item: CandidatePendingItem?
            do {
                item = try pending.claim(owner: pendingOwner, leaseSeconds: pendingLeaseSeconds)
            } catch {
                stats.lastError = "candidate pending claim failed: \(String(describing: error))"
                return
            }
            guard let item else { return }
            claims += 1
            stats.pendingClaimed += 1
            if runsRemaining <= 0 {
                stats.skippedBudget += 1
                settle(pending, item, .retry(reason: "budget", countAttempt: false, retryAfterSeconds: 0))
                return
            }
            if drainDeadline.timeIntervalSinceNow < CandidateStage.minAttemptSeconds {
                stats.skippedDeadline += 1
                settle(pending, item, .retry(reason: "deadline", countAttempt: false, retryAfterSeconds: 0))
                return
            }
            guard process(item, pending: pending, assembled: &assembled, assemblies: &assemblies,
                          assembler: assembler) else { return }
        }
    }

    private static func assemblyKey(_ user: String, _ device: String, _ day: String, _ revision: Int64) -> String {
        "\(user)|\(device)|\(day)|\(revision)"
    }

    /// One claimed item. Returns false when the drain must stop here.
    private mutating func process(_ item: CandidatePendingItem, pending: CandidatePendingStore,
                                  assembled: inout [String: CandidateAssembly], assemblies: inout Int,
                                  assembler: CandidateInputAssembling?) -> Bool {
        let backoff = CandidateStage.pendingBackoffSeconds(attempts: item.attempts + 1)
        // Runs whose lease expired unsettled (the worker died mid-run) are counted by the claim.
        // A row that keeps doing that reaches the bound here instead of running again.
        if item.attempts >= pendingMaxAttempts {
            settle(pending, item, .withheld(reason: "attempts_exhausted:\(item.lastReason ?? "lease_expired")",
                                            candidateId: nil))
            return true
        }
        do {
            guard try store.candidateOwnerIsLive(userId: item.userId, deviceId: item.deviceId) else {
                stats.skippedDeletedUser += 1
                settle(pending, item, .superseded(reason: "owner_not_live"))
                return true
            }
        } catch {
            stats.lastError = "candidate store (owner) failed: \(String(describing: error))"
            settle(pending, item, .retry(reason: "store_error", countAttempt: true, retryAfterSeconds: backoff))
            return true
        }
        let selection: SelectedProvider?
        do {
            selection = try self.selection(userId: item.userId, metric: item.metric)
        } catch {
            stats.lastError = "candidate store (selection) failed: \(String(describing: error))"
            settle(pending, item, .retry(reason: "store_error", countAttempt: true, retryAfterSeconds: backoff))
            return true
        }
        guard let selection, !selection.isOff else {
            stats.skippedOff += 1
            settle(pending, item, .superseded(reason: "selection_off"))
            return true
        }
        if selection.isDemoted {
            stats.skippedDemoted += 1
            settle(pending, item, .withheld(reason: selection.modeReason ?? "promotion_approval_required",
                                            candidateId: nil))
            return true
        }

        let key = Self.assemblyKey(item.userId, item.deviceId, item.day, item.inputRevision)
        var freshlyAssembled = false
        if assembled[key] == nil {
            guard let assembler, assemblies < reassemblyBudget else {
                // Strict oldest-first: the next item would need the same, so stop here. With
                // re-assembly off the item waits for its day to be re-scored, so it is not
                // claimed again on every idle drain.
                let canAssemble = assembler != nil && reassemblyBudget > 0
                settle(pending, item, .retry(reason: "awaiting_input_assembly", countAttempt: false,
                                             retryAfterSeconds: canAssemble ? 0 : 300))
                return false
            }
            if let current = try? pending.currentRevision(userId: item.userId, deviceId: item.deviceId,
                                                          day: item.day),
               current > item.inputRevision {
                settle(pending, item, .superseded(reason: "stale_input_revision"))
                return true
            }
            assemblies += 1
            do {
                let fresh = try assembler.assemble(userId: item.userId, deviceId: item.deviceId,
                                                   day: item.day, inputRevision: item.inputRevision)
                assembled[key] = fresh
                cacheAssembly(key, fresh)
                stats.reassembled += 1
                freshlyAssembled = true
            } catch {
                stats.reassemblyFailures += 1
                stats.lastError = "candidate input assembly failed: \(String(describing: error))"
                settle(pending, item, .retry(reason: "input_assembly_failed", countAttempt: true,
                                             retryAfterSeconds: backoff))
                return true
            }
        }
        guard let assembly = assembled[key] else { return true }
        let inputs = assembly.inputs

        // Stale debt: input arrived after these inputs were sealed. The newer revision gets its
        // own item; this one waits and is superseded or re-assembled later.
        do {
            if let invalidatedAt = try store.candidateDebtInvalidatedAt(userId: item.userId,
                                                                       deviceId: item.deviceId,
                                                                       day: item.day),
               invalidatedAt > inputs.claimSealedAt {
                stats.skippedStaleDebt += 1
                // Kept inputs that are now stale are dropped, so the next look re-assembles.
                evictAssembly(key)
                settle(pending, item, .retry(reason: "stale_debt", countAttempt: false, retryAfterSeconds: 30))
                return true
            }
        } catch {
            stats.lastError = "candidate store (debt) failed: \(String(describing: error))"
            settle(pending, item, .retry(reason: "store_error", countAttempt: true, retryAfterSeconds: backoff))
            return true
        }
        guard let input = inputs.input(for: item.metric) else {
            stats.skippedNoInput += 1
            settle(pending, item, .withheld(reason: "no_input", candidateId: nil))
            return true
        }
        // Pre-check: data may have arrived while the inputs were re-assembled. The record RPC
        // fences the write as well; this saves the computation.
        if freshlyAssembled,
           let current = try? pending.currentRevision(userId: item.userId, deviceId: item.deviceId, day: item.day),
           current > item.inputRevision {
            settle(pending, item, .superseded(reason: "stale_input_revision"))
            return true
        }

        runsRemaining -= 1
        let claim = DayScorer.Claim(userId: item.userId, deviceId: item.deviceId, day: item.day,
                                    timezoneId: assembly.timezoneId, inputRevision: item.inputRevision,
                                    leaseToken: item.leaseToken, runId: item.leaseToken,
                                    measurementRevision: 0)
        guard let call = callSidecar(metric: item.metric, selection: selection, input: input,
                                     claim: claim, inputs: inputs, attemptsAllowed: 1) else {
            if drainDeadline.timeIntervalSinceNow < CandidateStage.minAttemptSeconds {
                settle(pending, item, .retry(reason: "deadline", countAttempt: false, retryAfterSeconds: 0))
                return false
            }
            // The payload would not encode: deterministic, so retrying cannot help.
            settle(pending, item, .withheld(reason: "input_digest_failed", candidateId: nil))
            return true
        }
        if let failure = call.failure, failure.isBusy {
            stats.busy += 1
            sidecarBusy = true
            settle(pending, item, .retry(reason: "busy", countAttempt: false,
                                         retryAfterSeconds: failure.retryAfterSeconds
                                            ?? InferenceClient.defaultBusyRetryAfterSeconds))
            return false
        }
        if call.isBudgetCutTimeout {
            // The drain's cap ended the attempt, not the provider: wait with reason `deadline`,
            // uncounted, so a short drain can never turn into `attempts_exhausted:timeout`.
            stats.skippedDeadline += 1
            settle(pending, item, .retry(reason: "deadline", countAttempt: false, retryAfterSeconds: 0))
            return false
        }
        if let after = call.quarantineRetryAfterSeconds {
            // Nothing ran: the sidecar is resting a provider that kept overrunning. Its real
            // trials are what count toward the attempt bound.
            stats.quarantined += 1
            settle(pending, item, .retry(reason: "provider_quarantined", countAttempt: false,
                                         retryAfterSeconds: after))
            return true
        }
        if let reason = Self.transientReason(call) {
            if item.attempts + 1 < pendingMaxAttempts {
                settle(pending, item, .retry(reason: reason, countAttempt: true, retryAfterSeconds: backoff))
                return true
            }
            // Bounded: the last attempt settles as a withheld row with the terminal reason.
            let recorded = record(call, metric: item.metric, selection: selection, claim: claim, inputs: inputs,
                                  extra: ["pending_attempts": .int(item.attempts + 1), "pending_terminal": .bool(true)])
            switch recorded {
            case .written(let id):
                settle(pending, item, .withheld(reason: "attempts_exhausted:\(reason)", candidateId: id))
            case .alreadyPresent(let id):
                settle(pending, item, .withheld(reason: "attempts_exhausted:\(reason)", candidateId: id))
            case .writeFailed:
                settle(pending, item, .retry(reason: "write_failed", countAttempt: false, retryAfterSeconds: backoff))
            }
            return true
        }
        let recorded = record(call, metric: item.metric, selection: selection, claim: claim, inputs: inputs,
                              extra: item.attempts > 0 ? ["pending_attempts": .int(item.attempts + 1)] : [:])
        switch recorded {
        case .written(let id):
            settle(pending, item, .done(reason: "recorded", candidateId: id))
        case .alreadyPresent:
            settle(pending, item, .done(reason: "not_recorded", candidateId: nil))
        case .writeFailed:
            settle(pending, item, .retry(reason: "write_failed", countAttempt: true, retryAfterSeconds: backoff))
        }
        return true
    }

    /// The reason a call is worth another attempt in a later drain, or nil when its outcome
    /// is final: a client timeout/refusal/not_ready, or the sidecar's own budget overrun.
    private static func transientReason(_ call: SidecarCall) -> String? {
        if let failure = call.failure {
            return isRetryable(failure) ? failure.withheldReason.rawValue : nil
        }
        if let response = call.response, response.isWithheld,
           response.withheldReason == CandidateWithheldReason.timeout.rawValue {
            return CandidateWithheldReason.timeout.rawValue
        }
        return nil
    }

    private mutating func settle(_ pending: CandidatePendingStore, _ item: CandidatePendingItem,
                                 _ settlement: CandidatePendingSettlement) {
        do {
            guard try pending.settle(item, settlement, maxAttempts: pendingMaxAttempts) else {
                stats.pendingSettleRefused += 1
                return
            }
        } catch {
            stats.pendingSettleRefused += 1
            stats.lastError = "candidate pending settle failed: \(String(describing: error))"
            return
        }
        switch settlement {
        case .done: stats.pendingDone += 1
        case .withheld: stats.pendingWithheld += 1
        case .superseded: stats.pendingSuperseded += 1
        case .retry: stats.pendingRetried += 1
        }
    }

    // MARK: In-memory path (no pending store)

    /// The pass the stage ran before the pending store existed, for a database without
    /// 20261008110000: everything is decided now, nothing is persisted. Metrics run least
    /// recently run first, so a fixed order cannot starve the last ones.
    private mutating func runInMemory(claim: DayScorer.Claim, inputs: DayScorer.CandidateInputs) {
        guard runsRemaining > 0 else {
            stats.skippedBudget += 1
            return
        }
        // Deleted user / inactive device: refuse publication (spec section 4.6).
        do {
            guard try store.candidateOwnerIsLive(userId: claim.userId, deviceId: claim.deviceId) else {
                stats.skippedDeletedUser += 1
                return
            }
        } catch {
            stats.lastError = "candidate store (owner) failed: \(String(describing: error))"
            return
        }
        // Stale debt: newer input arrived after this claim was sealed, so this
        // claim's candidate would be computed from a superseded input revision.
        do {
            if let invalidatedAt = try store.candidateDebtInvalidatedAt(userId: claim.userId,
                                                                       deviceId: claim.deviceId,
                                                                       day: claim.day),
               invalidatedAt > inputs.claimSealedAt {
                stats.skippedStaleDebt += 1
                return
            }
        } catch {
            stats.lastError = "candidate store (debt) failed: \(String(describing: error))"
            return
        }

        for metric in leastRecentlyRunOrder() {
            guard runsRemaining > 0 else {
                stats.skippedBudget += 1
                return
            }
            guard !sidecarBusy else { return }
            // R4: the drain's wall-clock cap. Once it is spent, stop starting work
            // so a stalled sidecar cannot hold the scoring lane thread.
            guard drainDeadline.timeIntervalSinceNow >= CandidateStage.minAttemptSeconds else {
                stats.skippedDeadline += 1
                return
            }
            let selection: SelectedProvider?
            do {
                selection = try self.selection(userId: claim.userId, metric: metric)
            } catch {
                stats.lastError = "candidate store (selection) failed: \(String(describing: error))"
                continue
            }
            guard let selection, !selection.isOff else {
                stats.skippedOff += 1
                continue
            }
            if selection.isDemoted {
                stats.skippedDemoted += 1
                continue
            }
            guard let input = inputs.input(for: metric) else {
                // No input assembly for this metric yet (sleep/respiration arrive
                // with their providers). Not an error: nothing is called.
                stats.skippedNoInput += 1
                continue
            }
            runsRemaining -= 1
            guard let call = callSidecar(metric: metric, selection: selection, input: input, claim: claim,
                                         inputs: inputs, attemptsAllowed: maxAttempts) else { continue }
            if let failure = call.failure, failure.isBusy {
                // Backpressure, not a result: nothing is written and the drain stops calling.
                stats.busy += 1
                sidecarBusy = true
                return
            }
            if call.isBudgetCutTimeout {
                // The drain ran out of time, not the provider: no row, the next pass retries.
                stats.skippedDeadline += 1
                return
            }
            if call.quarantineRetryAfterSeconds != nil {
                stats.quarantined += 1
                continue
            }
            // Only a call that reached a result moves the metric back in the fairness order.
            lastRunAt[metric] = Date()
            _ = record(call, metric: metric, selection: selection, claim: claim, inputs: inputs, extra: [:])
        }
    }

    /// Metrics ordered by when they last ran (never first), the fixed order breaking ties.
    private func leastRecentlyRunOrder() -> [String] {
        CandidateStage.metrics.enumerated().sorted { lhs, rhs in
            let a = lastRunAt[lhs.element] ?? .distantPast
            let b = lastRunAt[rhs.element] ?? .distantPast
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: One call and its record

    struct SidecarCall {
        let request: InferenceRequest
        let inputSHA: String
        let response: InferenceResponse?
        let failure: InferenceClientError?
        let attempts: Int
        let elapsedMS: Int
        /// The last attempt ran with less than the client's full timeout (the drain's
        /// wall-clock cap cut it short).
        var budgetCut = false

        /// A client timeout of an attempt the drain cap cut short: the drain ran out of time,
        /// the provider was never given its full budget, so it is not a provider outcome.
        var isBudgetCutTimeout: Bool {
            guard budgetCut, let failure else { return false }
            if case .timeout = failure { return true }
            return false
        }

        /// Seconds until a quarantined provider takes a real trial again, when the sidecar
        /// answered without dispatching (`provider_quarantined`); nil otherwise.
        var quarantineRetryAfterSeconds: Int? {
            guard let response, response.isWithheld,
                  response.withheldReason == CandidateWithheldReason.timeout.rawValue,
                  response.diagnostics?.member("withheld_detail")?.stringValue == "provider_quarantined"
            else { return nil }
            return max(1, response.diagnostics?.member("retry_after_s")?.doubleValue.map { Int($0) } ?? 300)
        }
    }

    /// Call the sidecar with at most `attemptsAllowed` attempts (one transient retry with
    /// backoff on the in-memory path; one attempt when the work is persisted, since a
    /// later drain retries it). nil when no attempt could start.
    private mutating func callSidecar(metric: String, selection: SelectedProvider, input: JSONValue,
                                      claim: DayScorer.Claim, inputs: DayScorer.CandidateInputs,
                                      attemptsAllowed: Int) -> SidecarCall? {
        stats.runs += 1
        let request = InferenceRequest(
            metric: metric,
            context: InferenceRequest.Context(
                userId: claim.userId,
                deviceId: claim.deviceId,
                intervalStartUTC: iso(inputs.intervalStart),
                intervalEndUTC: iso(inputs.intervalEnd),
                ianaTimezone: claim.timezoneId,
                profileVersion: inputs.profileVersion,
                configVersion: selection.configVersion,
                correctionsVersion: inputs.correctionsVersion),
            input: input,
            provider: InferenceRequest.Provider(providerId: selection.providerId))

        let inputSHA: String
        do {
            inputSHA = try InferenceClient.inputDigest(input)
        } catch {
            stats.lastError = "candidate input digest failed: \(String(describing: error))"
            return nil
        }

        var attempts = 0
        var response: InferenceResponse?
        var failure: InferenceClientError?
        var elapsedMS = 0
        var budgetCut = false
        while attempts < max(1, attemptsAllowed) {
            // R4: never start an attempt that the drain cap cannot accommodate,
            // and never let one attempt outlive the cap.
            let remaining = drainDeadline.timeIntervalSinceNow
            guard remaining >= CandidateStage.minAttemptSeconds else { break }
            let attemptBudgetMS = min(client.timeoutMS, Int(remaining * 1000))
            budgetCut = attemptBudgetMS < client.timeoutMS
            attempts += 1
            let started = Date()
            do {
                stats.calls += 1
                response = try client.infer(request, timeoutMSOverride: attemptBudgetMS)
                elapsedMS = Int(Date().timeIntervalSince(started) * 1000)
                failure = nil
                break
            } catch let error as InferenceClientError {
                elapsedMS = Int(Date().timeIntervalSince(started) * 1000)
                failure = error
                if !CandidateStage.isRetryable(error) || attempts >= attemptsAllowed { break }
                // Back off before the single transient retry, but never sleep past
                // the drain deadline.
                let pause = min(CandidateStage.retryBackoffSeconds,
                                max(0, drainDeadline.timeIntervalSinceNow - CandidateStage.minAttemptSeconds))
                if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            } catch {
                elapsedMS = Int(Date().timeIntervalSince(started) * 1000)
                failure = .transport(String(describing: error))
                break
            }
        }
        // Nothing was attempted because the drain cap was already spent: skip the
        // metric entirely rather than writing a row we never computed.
        guard attempts > 0 else {
            stats.skippedDeadline += 1
            return nil
        }
        stats.lastCallAt = Date()
        stats.lastProviderId = selection.providerId
        stats.lastRuntimeMS = elapsedMS
        if let failure { stats.lastError = failure.description }
        return SidecarCall(request: request, inputSHA: inputSHA, response: response, failure: failure,
                           attempts: attempts, elapsedMS: elapsedMS, budgetCut: budgetCut)
    }

    enum RecordOutcome: Equatable {
        case written(String)
        /// The record RPC returned NULL: already present, or fenced (stale, off, unowned).
        case alreadyPresent(String?)
        case writeFailed
    }

    /// Build the row for a call and write it (never for a busy answer).
    private mutating func record(_ call: SidecarCall, metric: String, selection: SelectedProvider,
                                 claim: DayScorer.Claim, inputs: DayScorer.CandidateInputs,
                                 extra: [String: JSONValue]) -> RecordOutcome {
        let record = buildRecord(metric: metric, selection: selection, claim: claim, inputs: inputs,
                                 inputSHA: call.inputSHA, response: call.response, failure: call.failure,
                                 attempts: call.attempts, elapsedMS: call.elapsedMS, extra: extra)
        stats.lastWithheldReason = record.withheldReason
        switch record.status {
        case "ok": stats.ok += 1
        case "withheld": stats.withheld += 1
        default: stats.errors += 1
        }

        // ACTIVE PROMOTION: only reachable when a metric's mode is `active`.
        // The shipped defaults are `off` for all four metrics.
        if metric == "hrv", record.status == "ok", selection.isActive,
           let substitution = CandidateStage.activeHrvSubstitution(
               selection: selection, response: call.response, inputSHA256: call.inputSHA) {
            lastActiveSubstitution = substitution
            stats.activeSubstitutions += 1
        }

        do {
            if let candidateId = try store.recordCandidate(record) {
                stats.recorded += 1
                return .written(candidateId)
            }
            stats.duplicates += 1
            return .alreadyPresent(nil)
        } catch {
            stats.writeFailures += 1
            stats.lastError = "candidate write failed: \(String(describing: error))"
            return .writeFailed
        }
    }

    /// Turn one call outcome into a record. A client failure always becomes a
    /// withheld row (never a retry loop and never a canonical change).
    private func buildRecord(metric: String, selection: SelectedProvider, claim: DayScorer.Claim,
                             inputs: DayScorer.CandidateInputs, inputSHA: String,
                             response: InferenceResponse?, failure: InferenceClientError?,
                             attempts: Int, elapsedMS: Int,
                             extra: [String: JSONValue] = [:]) -> CandidateRecord {
        var status = "withheld"
        var withheldReason: String? = CandidateWithheldReason.providerError.rawValue
        var value: Double?
        var unit: String?
        var stages: JSONValue?
        var labelSpace: String?
        var finality = "provisional"
        var diagnostics: [String: JSONValue] = [
            "attempts": .int(attempts),
            "client_elapsed_ms": .int(elapsedMS),
            "transport": .string(failure == nil ? "ok" : "failed"),
        ]

        if let failure {
            withheldReason = failure.withheldReason.rawValue
            diagnostics["error_class"] = .string(failure.description)
        } else if let response {
            finality = response.finalOrProvisional ?? "provisional"
            if let runtime = response.runtimeMs { diagnostics["provider_runtime_ms"] = .int(runtime) }
            if response.isOK, let result = response.result {
                value = result.value
                unit = result.unit
                stages = result.stages
                labelSpace = result.labelSpace
                // R2: the non-ok branch of the RPC raises 22023 when p_value OR
                // p_stages is non-null (`invalid_candidate_result`, migration
                // lines 443-445), and the ok branch requires a unit with a value
                // (`invalid_candidate_unit`, 430-432) and a label space with stages
                // (`invalid_candidate_label_space`, 433-435). A shape the RPC would
                // reject is therefore settled
                // here as a withheld row with the offending value kept in
                // diagnostics, so the write still succeeds and the evidence survives.
                var demotion: String?
                if let bound = CandidateStage.bounds(for: metric), let v = value, !bound.contains(v) {
                    demotion = "value_out_of_bounds"
                    diagnostics["bounds"] = .string("\(bound.lowerBound)...\(bound.upperBound)")
                } else if value != nil && (unit ?? "").isEmpty {
                    demotion = "value_without_unit"
                } else if stages != nil && (labelSpace ?? "").isEmpty {
                    demotion = "stages_without_label_space"
                }
                if let demotion {
                    status = "withheld"
                    withheldReason = CandidateWithheldReason.providerError.rawValue
                    diagnostics["bounds_violation"] = .string(demotion)
                    if let v = value { diagnostics["rejected_value"] = .double(v) }
                    if let u = unit { diagnostics["rejected_unit"] = .string(u) }
                    // The RPC accepts a non-ok row ONLY with null value and stages.
                    value = nil
                    unit = nil
                    stages = nil
                    labelSpace = nil
                } else {
                    status = "ok"
                    withheldReason = nil
                }
            } else if response.isOK {
                status = "withheld"
                withheldReason = CandidateWithheldReason.providerError.rawValue
                diagnostics["shape"] = .string("ok_without_result")
            } else {
                status = response.isWithheld ? "withheld" : "error"
                let raw = response.withheldReason ?? ""
                if CandidateWithheldReason(rawValue: raw) != nil {
                    withheldReason = raw
                } else {
                    withheldReason = CandidateWithheldReason.providerError.rawValue
                    if !raw.isEmpty { diagnostics["provider_reason_raw"] = .string(raw) }
                }
            }
        }
        // Both counts, so a coverage question can be answered from the row alone.
        diagnostics["input_rows"] = .int(inputs.hrvInputRows)
        diagnostics["deduped_rows"] = .int(inputs.inputRowCount)
        diagnostics["mode"] = .string(selection.mode)
        // Requested vs effective mode on every row: `active` is never effective while no
        // validated selection path publishes canonical physiology from a candidate.
        diagnostics["requested_mode"] = .string(selection.requested)
        diagnostics["effective_mode"] = .string(selection.effectiveMode)
        if let reason = selection.modeReason { diagnostics["mode_reason"] = .string(reason) }
        // Audit DD-5: an `active` provider result is recorded with mode='active',
        // but this worker does NOT publish it as canonical (promotion needs a fresh
        // canonical republish, which is parent-gated). Without these keys the row
        // would claim an active value that no consumer can see, so state it.
        if selection.isActive && status == "ok" {
            diagnostics["active_promotion_deferred"] = .bool(true)
            diagnostics["canonical_published"] = .bool(false)
        }
        // The record RPC DROPS the row when the provider triple differs from the
        // current selection, so the triple written is always the SELECTION's. If
        // the response echoes a different provider/config, keep it as evidence
        // (diagnostics) instead of letting the row be silently discarded.
        if let echoed = response?.providerId, !echoed.isEmpty, echoed != selection.providerId {
            diagnostics["provider_id_mismatch"] = .string(echoed)
        }
        if let echoed = response?.versions?.config, !echoed.isEmpty, echoed != selection.configVersion {
            diagnostics["config_version_mismatch"] = .string(echoed)
        }
        for (key, value) in extra { diagnostics[key] = value }

        return CandidateRecord(
            userId: claim.userId,
            deviceId: claim.deviceId,
            metric: metric,
            periodDay: claim.day,
            intervalStart: Date(timeIntervalSince1970: TimeInterval(inputs.intervalStart)),
            intervalEnd: Date(timeIntervalSince1970: TimeInterval(inputs.intervalEnd)),
            inputSHA256: inputSHA,
            // The SELECTED triple, verbatim: the record RPC requires it to equal
            // the current selection or it drops the row.
            providerId: selection.providerId,
            providerVersion: selection.providerVersion,
            // The response's `versions` carries adapter/preprocessing/dependency/
            // model, none of which are part of the selection triple.
            adapterVersion: response?.versions?.adapter ?? "unknown",
            preprocessingVersion: response?.versions?.preprocessing ?? "unknown",
            configVersion: selection.configVersion,
            dependencyVersions: CandidateStage.dependencyVersions(from: response),
            status: status,
            withheldReason: withheldReason,
            value: value,
            unit: unit,
            stages: stages,
            labelSpace: labelSpace,
            coverage: response?.coverage,
            diagnostics: .object(diagnostics),
            runtimeMS: response?.runtimeMs ?? elapsedMS,
            mode: selection.isActive ? "active" : "shadow",
            finality: finality,
            inputRevision: claim.inputRevision)
    }

    static func dependencyVersions(from response: InferenceResponse?) -> [String: String] {
        var out: [String: String] = [:]
        guard let versions = response?.versions else { return out }
        if let v = versions.dependency { out["dependency"] = v }
        if let v = versions.model { out["model"] = v }
        return out
    }

    private func iso(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // MARK: - ACTIVE PROMOTION PLUMBING (unreachable while defaults are `off`)
    //
    // `active` mode means a validated provider may publish the canonical value.
    // The candidate write happens after the canonical publish has committed, so a
    // promotion cannot happen in the same pass. The plumbing below is therefore:
    //
    //   1. `activeHrvSubstitution` — a pure decision: non-nil ONLY when the
    //      selection is `active` and the provider returned a finite `ok` value.
    //   2. `DayScorer.applyActiveHrvSubstitution` — a pure transform that swaps
    //      the canonical `hrv_rmssd_ms` and records provenance in the snapshot
    //      payload (unit-tested in DayScoringCandidateInputTests).
    //
    // The call site is gated on mode == "active"; every metric ships `off`
    // (`physiology_provider_defaults` seeds all four metrics `off`), so this is
    // unreachable in production until the parent flips a metric on purpose.
    struct ActiveHrvSubstitution {
        let value: Double
        let providerId: String
        let providerVersion: String
        let adapterVersion: String
        let configVersion: String
        let inputSHA256: String
        let mode: String
    }

    /// Decide whether an `ok` result may replace the canonical nightly HRV.
    static func activeHrvSubstitution(selection: SelectedProvider, response: InferenceResponse?,
                                      inputSHA256: String) -> ActiveHrvSubstitution? {
        guard selection.isActive, let response, response.isOK, let result = response.result,
              let value = result.value, value.isFinite else { return nil }
        if let bound = CandidateStage.bounds(for: "hrv"), !bound.contains(value) { return nil }
        return ActiveHrvSubstitution(
            value: value,
            providerId: response.providerId ?? selection.providerId,
            providerVersion: selection.providerVersion,
            adapterVersion: response.versions?.adapter ?? "unknown",
            configVersion: response.versions?.config ?? selection.configVersion,
            inputSHA256: inputSHA256,
            mode: "active")
    }
}

// MARK: - Postgres-backed store

/// INTEGRATION SEAM (W-B owns the migration).
///
/// Every candidate SQL statement the worker issues lives in this one enum. The
/// parent plan fixes the RPC NAMES (`physiology_selected_provider`,
/// `physiology_record_candidate_result`) but W-B owns their exact parameter list,
/// so when the migration lands the ONLY edit required in the Swift worker is the
/// text below — no call site, no type, and no test changes.
enum PhysiologyCandidateSQL {
    // NOTE ON SCOPE: every statement below is a call to a migration-owned RPC.
    // The worker issues no ad-hoc DML against the candidate tables.

    /// `physiology_selected_provider(p_user uuid, p_metric text) returns jsonb`
    /// -> `{"provider_id","provider_version","config_version",
    ///      "mode":"off"|"shadow"|"active","source":"user_override"|"default"|"unset"}`.
    /// `mode` is the SOLE authority for whether a metric is computed (a follow-up
    /// migration may demote `active` to `shadow` when no live promotion approval
    /// exists; the worker does not second-guess it).
    static let selectedProvider =
        "select public.physiology_selected_provider($1::uuid, $2::text)::text"

    /// `physiology_candidate_debt_read(p_user uuid, p_device text, p_day date)
    /// returns jsonb` -> `{"debt":bool,"invalidated_at":ts|null}`.
    /// The worker skips a candidate when the debt is NEWER than the claim it is
    /// scoring, because the claim's input revision has been superseded.
    static let candidateDebt =
        "select public.physiology_candidate_debt_read($1::uuid, $2::text, $3::date)::text"

    /// A deleted user cascades away `auth.users`; an inactive device must also be
    /// refused (spec section 4, rule 6). `physiology_record_candidate_result`
    /// ALSO drops these cases (it returns NULL for a deleted user or a device that
    /// is not owned), so this read is an explicit early refusal that avoids
    /// computing — and calling the sidecar — for a user we may not publish for.
    static let ownerIsLive = """
        select exists(
                 select 1 from public.devices d
                   join auth.users u on u.id = d.user_id
                  where d.user_id = $1::uuid and d.id = $2::uuid and d.is_active
               )::text as live
        """

    /// `physiology_record_candidate_result(...) returns uuid` — W-B's FINAL
    /// signature (23 positional parameters, in this exact order).
    ///
    /// Returns NULL (never an error) when: mode is `off`, the provider triple does
    /// not equal the selected triple, the user is deleted/unknown, the device is
    /// not owned, the input revision is stale, or the row is a duplicate replay.
    /// Raises SQLSTATE 22023 with a named error on malformed shape/bounds/
    /// finiteness. The worker treats NULL as "nothing new was written" and 22023
    /// as a write failure — neither is retried.
    /// NULL BINDING (R1): `PostgresClient` sends every parameter as a
    /// zero-terminated C string (`PostgresClient.swift:runQuery` ->
    /// `params.map { UnsafePointer(strdup($0)) }` -> `PQexecParams`), so it has no
    /// way to express SQL NULL. libpq sends NULL only for a NULL pointer. The
    /// Swift side therefore encodes "absent" as the empty string, and NULLIF is
    /// what turns that into a real SQL NULL.
    ///
    /// This matters BEFORE the function body runs: `''::numeric` and `''::jsonb`
    /// are evaluated while binding the call and raise 22P02
    /// (`invalid input syntax for type numeric/json`). And an `ok` row carrying
    /// `p_withheld_reason = ''` fails the body's own `invalid_candidate_result`
    /// check (`if p_withheld_reason is not null then raise ...`, migration lines
    /// 427-429). So every nullable parameter is nullif'd.
    ///
    /// EXCEPTION: `p_dependency_versions` must be a jsonb OBJECT — the migration
    /// raises `invalid_candidate_dependencies` for NULL (lines 407-409) — so it is
    /// never nullif'd; the Swift side always encodes at least `{}`.
    static let recordCandidate = """
        select public.physiology_record_candidate_result(
                 $1::uuid, $2::text, $3::text, $4::date,
                 $5::timestamptz, $6::timestamptz,
                 $7::text, $8::bigint,
                 $9::text, $10::text, $11::text, $12::text, $13::text,
                 $14::text,
                 $15::jsonb,
                 nullif($16::text,''),
                 nullif($17::text,'')::numeric,
                 nullif($18::text,''),
                 nullif($19::text,'')::jsonb,
                 nullif($20::text,''),
                 nullif($21::text,'')::jsonb,
                 nullif($22::text,'')::jsonb,
                 nullif($23::text,'')::integer
               )::text
        """

    /// Positional parameter list for `recordCandidate`, in the same order as the
    /// SQL above. Kept next to the SQL so the two cannot drift.
    ///
    /// `p_provider_id`/`p_provider_version`/`p_config_version` MUST be the
    /// SELECTED triple: the RPC drops the row when they differ from the current
    /// selection. The caller therefore passes the selection, not the response.
    static func recordCandidateParameters(_ record: CandidateRecord) throws -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ value: JSONValue?) throws -> String {
            guard let value else { return "" }
            return String(data: try encoder.encode(value), encoding: .utf8) ?? ""
        }
        return [
            record.userId,                                            // p_user
            record.deviceId,                                          // p_device (text)
            record.metric,                                            // p_metric
            record.periodDay,                                         // p_period_day
            f.string(from: record.intervalStart),                     // p_interval_start_at
            f.string(from: record.intervalEnd),                       // p_interval_end_at
            record.inputSHA256,                                       // p_input_sha256
            String(record.inputRevision),                             // p_input_revision
            record.providerId,                                        // p_provider_id
            record.providerVersion,                                   // p_provider_version
            record.adapterVersion,                                    // p_adapter_version
            record.preprocessingVersion,                              // p_preprocessing_version
            record.configVersion,                                     // p_config_version
            record.status,                                            // p_status
            String(data: try encoder.encode(record.dependencyVersions), encoding: .utf8) ?? "{}",
            record.withheldReason ?? "",                              // p_withheld_reason
            record.value.map { String($0) } ?? "",                    // p_value
            record.unit ?? "",                                        // p_unit
            try json(record.stages),                                  // p_stages
            record.labelSpace ?? "",                                  // p_label_space
            try json(record.coverage),                                // p_coverage
            try json(record.diagnostics),                             // p_diagnostics
            record.runtimeMS.map { String($0) } ?? "",                // p_runtime_ms
        ]
    }
}


/// The production `CandidateStore`, backed by the worker's own Postgres
/// connection. Every write goes through `callFunctionForJSON`, which opens its
/// own committed transaction and sets the service-role claim exactly like the
/// canonical publish path.
struct PostgresCandidateStore: CandidateStore {
    let db: PostgresClient

    func selectedProvider(userId: String, metric: String) throws -> SelectedProvider? {
        guard let text = try db.callFunctionForJSON(PhysiologyCandidateSQL.selectedProvider,
                                                    [userId, metric]) else { return nil }
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return SelectedProvider.parse(obj)
    }

    func candidateDebtInvalidatedAt(userId: String, deviceId: String, day: String) throws -> Date? {
        guard let text = try db.callFunctionForJSON(PhysiologyCandidateSQL.candidateDebt,
                                                     [userId, deviceId, day]) else { return nil }
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        guard (obj["debt"] as? Bool) == true else { return nil }
        guard let stamp = obj["invalidated_at"] as? String, !stamp.isEmpty else { return nil }
        return PostgresCandidateStore.parseTimestamp(stamp)
    }

    /// `physiology_candidate_debt_read` returns `invalidated_at` as a jsonb
    /// timestamptz. Postgres renders it with a numeric offset
    /// (`2026-10-01T08:00:00+00:00`) and may include fractional seconds, so try
    /// both ISO-8601 forms and then a plain `yyyy-MM-dd HH:mm:ssZ` form.
    static func parseTimestamp(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(identifier: "UTC")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        return fallback.date(from: text)
    }

    func candidateOwnerIsLive(userId: String, deviceId: String) throws -> Bool {
        let rows = try db.query(PhysiologyCandidateSQL.ownerIsLive, [userId, deviceId])
        return isTrue(rows.first?["live"])
    }

    func recordCandidate(_ record: CandidateRecord) throws -> String? {
        let params = try PhysiologyCandidateSQL.recordCandidateParameters(record)
        // `callFunctionForJSON` opens its own committed transaction and sets the
        // service-role claim, exactly like the canonical publish path. A NULL
        // return is "nothing new written" (off / triple mismatch / deleted user /
        // unowned device / stale revision / duplicate replay); a 22023 raise
        // propagates as a write failure.
        guard let text = try db.callFunctionForJSON(PhysiologyCandidateSQL.recordCandidate, params) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Postgres-backed pending store

/// A JSON number (or numeric string) as Int, whichever type the platform's
/// JSONSerialization produced.
func jsonInt(_ value: Any?) -> Int? {
    switch value {
    case let v as Int: return v
    case let v as Int64: return Int(v)
    case let v as Double: return v.isFinite ? Int(v) : nil
    case let v as NSNumber: return v.intValue
    case let v as String: return Int(v)
    default: return nil
    }
}

/// Every pending-queue statement the worker issues: calls to the RPCs of
/// `20261008110000_physiology_candidate_pending.sql`, nothing else.
enum PhysiologyCandidatePendingSQL {
    /// Whether the migration is applied (a plain catalog read, no transaction needed).
    static let probe = """
        select (to_regprocedure('public.physiology_candidate_pending_claim(text,integer)') is not null)::text as present
        """
    /// `physiology_candidate_pending_enqueue(p_user, p_device, p_day, p_input_revision, p_entries jsonb) returns integer`.
    static let enqueue =
        "select public.physiology_candidate_pending_enqueue($1::uuid, $2::text, $3::date, $4::bigint, $5::jsonb)::text"
    /// `physiology_candidate_pending_claim(p_owner, p_lease_seconds) returns jsonb` (one item or NULL).
    static let claim = "select public.physiology_candidate_pending_claim($1::text, $2::integer)::text"
    /// `physiology_candidate_pending_settle(...) returns jsonb` -> `{"settled": bool, ...}`.
    static let settle = """
        select public.physiology_candidate_pending_settle(
                 $1::uuid, $2::text, $3::date, $4::text, $5::bigint, $6::uuid,
                 $7::text, $8::text, nullif($9::text,'')::uuid, $10::boolean,
                 nullif($11::text,'')::integer, $12::integer)::text
        """
    /// `physiology_candidate_current_revision(p_user, p_device, p_day) returns bigint`.
    static let currentRevision =
        "select public.physiology_candidate_current_revision($1::uuid, $2::text, $3::date)::text"
    /// `physiology_candidate_pending_stats() returns jsonb`.
    static let stats = "select public.physiology_candidate_pending_stats()::text"

    static func entriesJSON(_ entries: [CandidatePendingEntry]) throws -> String {
        let objects: [[String: Any]] = entries.map {
            ["metric": $0.metric, "provider_id": $0.providerId, "provider_version": $0.providerVersion,
             "config_version": $0.configVersion, "requested_mode": $0.requestedMode,
             "has_input": $0.hasInput]
        }
        return try jsonText(objects)
    }

    /// Positional parameters for `settle`, in the SQL's order.
    static func settleParameters(_ item: CandidatePendingItem, _ settlement: CandidatePendingSettlement,
                                 maxAttempts: Int) -> [String] {
        let outcome: String, reason: String, candidateId: String?, retryAfter: Int?
        switch settlement {
        case .done(let r, let id): (outcome, reason, candidateId, retryAfter) = ("done", r, id, nil)
        case .withheld(let r, let id): (outcome, reason, candidateId, retryAfter) = ("withheld", r, id, nil)
        case .superseded(let r): (outcome, reason, candidateId, retryAfter) = ("superseded", r, nil, nil)
        case .retry(let r, _, let after): (outcome, reason, candidateId, retryAfter) = ("retry", r, nil, after)
        }
        return [item.userId, item.deviceId, item.day, item.metric, String(item.inputRevision),
                item.leaseToken, outcome, reason, candidateId ?? "",
                settlement.countsAttempt ? "true" : "false",
                retryAfter.map(String.init) ?? "", String(maxAttempts)]
    }

    /// Parse the claim RPC's jsonb item.
    static func parseItem(_ text: String?) -> CandidatePendingItem? {
        guard let text, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = obj["user_id"] as? String, let device = obj["device_id"] as? String,
              let day = obj["period_day"] as? String, let metric = obj["metric"] as? String,
              let token = obj["lease_token"] as? String else { return nil }
        let revision = Int64(jsonInt(obj["input_revision"]) ?? 0)
        guard revision > 0 else { return nil }
        return CandidatePendingItem(
            userId: user, deviceId: device, day: String(day.prefix(10)), metric: metric,
            inputRevision: revision,
            providerId: (obj["provider_id"] as? String) ?? "",
            providerVersion: (obj["provider_version"] as? String) ?? "",
            configVersion: (obj["config_version"] as? String) ?? "",
            attempts: jsonInt(obj["attempts"]) ?? 0,
            leaseToken: token, lastReason: obj["last_reason"] as? String)
    }

    static func parseStats(_ text: String?) -> CandidatePendingStats? {
        guard let text, let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { jsonInt(obj[key]) ?? 0 }
        func counts(_ key: String) -> [String: Int] {
            ((obj[key] as? [String: Any]) ?? [:]).compactMapValues { jsonInt($0) }
        }
        return CandidatePendingStats(pending: int("pending"), due: int("due"), leased: int("leased"),
                                     oldestPendingAgeSeconds: int("oldest_pending_age_s"),
                                     withheldLast24h: int("withheld_24h"),
                                     supersededLast24h: int("superseded_24h"),
                                     byMetric: counts("by_metric"), byReason: counts("by_reason"))
    }
}

/// The production pending store on the scoring lane's connection. Each call is its own
/// committed transaction (`callFunctionForJSON`), never inside a scoring transaction.
final class PostgresCandidatePendingStore: CandidatePendingStore {
    let db: PostgresClient
    /// How long a negative probe (migration not applied yet) is trusted.
    var probeTTL: TimeInterval = 300
    private var probed: (available: Bool, at: Date)?

    init(db: PostgresClient) { self.db = db }

    func isAvailable() -> Bool {
        if let probed, probed.available || Date().timeIntervalSince(probed.at) < probeTTL {
            return probed.available
        }
        // A failed probe (database unreachable) is not cached: only a real "absent" answer is.
        guard let rows = try? db.query(PhysiologyCandidatePendingSQL.probe, []) else { return false }
        let available = isTrue(rows.first?["present"])
        probed = (available, Date())
        if !available {
            FileHandle.standardError.write(
                ("frwhoop-worker: candidate pending store unavailable (20261008110000 not applied); "
                 + "scheduling candidates in memory\n").data(using: .utf8)!)
        }
        return available
    }

    func enqueue(userId: String, deviceId: String, day: String, inputRevision: Int64,
                 entries: [CandidatePendingEntry]) throws -> Int {
        let text = try db.callFunctionForJSON(
            PhysiologyCandidatePendingSQL.enqueue,
            [userId, deviceId, day, String(inputRevision), try PhysiologyCandidatePendingSQL.entriesJSON(entries)])
        return Int((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func claim(owner: String, leaseSeconds: Int) throws -> CandidatePendingItem? {
        PhysiologyCandidatePendingSQL.parseItem(
            try db.callFunctionForJSON(PhysiologyCandidatePendingSQL.claim, [owner, String(leaseSeconds)]))
    }

    func settle(_ item: CandidatePendingItem, _ settlement: CandidatePendingSettlement,
                maxAttempts: Int) throws -> Bool {
        let text = try db.callFunctionForJSON(
            PhysiologyCandidatePendingSQL.settle,
            PhysiologyCandidatePendingSQL.settleParameters(item, settlement, maxAttempts: maxAttempts))
        guard let data = text?.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (obj["settled"] as? Bool) == true
    }

    func currentRevision(userId: String, deviceId: String, day: String) throws -> Int64? {
        let text = try db.callFunctionForJSON(PhysiologyCandidatePendingSQL.currentRevision,
                                              [userId, deviceId, day])
        return Int64((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func stats() throws -> CandidatePendingStats {
        PhysiologyCandidatePendingSQL.parseStats(try db.callFunctionForJSON(PhysiologyCandidatePendingSQL.stats, []))
            ?? CandidatePendingStats()
    }
}
