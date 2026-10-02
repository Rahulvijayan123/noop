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
// without bound (at most `maxAttempts`, default 2, and only for transient
// transport failures).

/// One metric's selected provider, from `physiology_selected_provider`.
struct SelectedProvider: Equatable {
    let providerId: String
    let providerVersion: String
    let configVersion: String
    /// `off` | `shadow` | `active`.
    let mode: String

    var isOff: Bool { mode == "off" }
    var isActive: Bool { mode == "active" }
    var isShadow: Bool { mode == "shadow" }
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

/// The candidate stage: per-metric provider selection, a bounded sidecar call,
/// and a bounded write.
struct CandidateStage {
    let client: InferenceClient
    let store: CandidateStore
    /// Attempts per sidecar call. Bounded by contract; never unbounded.
    var maxAttempts: Int = 2

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
        var skippedBudget = 0
        /// Metrics not attempted because the drain's wall-clock cap was reached.
        var skippedDeadline = 0
        var writeFailures = 0
        /// Active-mode substitutions produced. Zero while every metric is `off`.
        var activeSubstitutions = 0
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

    /// The most recent `active`-mode `ok` result, if any. Always nil while every
    /// metric is `off` (the shipped defaults), which is what makes the active
    /// promotion plumbing unreachable in production today.
    private(set) var lastActiveSubstitution: ActiveHrvSubstitution?

    init(client: InferenceClient, store: CandidateStore, maxAttempts: Int = 2) {
        self.client = client
        self.store = store
        self.maxAttempts = max(1, maxAttempts)
    }

    /// Reset the per-drain run budget and wall-clock deadline. Called once at the
    /// top of a drain.
    mutating func beginDrain(budget: Int) {
        runsRemaining = max(0, budget)
        drainDeadline = Date().addingTimeInterval(max(0, maxDrainSeconds))
    }

    /// Attempts that are worth one bounded retry. A malformed body or a non-200
    /// status is deterministic: retrying it in the same drain cannot help.
    static func isRetryable(_ error: InferenceClientError) -> Bool {
        switch error {
        case .timeout, .refused, .transport, .notReady: return true
        case .disabled, .nonLoopbackURL, .non200, .malformed: return false
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

    /// The metrics this stage will consider, in a fixed order.
    static let metrics = ["hrv", "sleep_boundary", "sleep_stage", "respiration"]

    /// Run the candidate lane for one claimed day. Never throws: every failure is
    /// settled as a withheld candidate and recorded in `stats`.
    mutating func run(claim: DayScorer.Claim, inputs: DayScorer.CandidateInputs) {
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

        for metric in CandidateStage.metrics {
            guard runsRemaining > 0 else {
                stats.skippedBudget += 1
                return
            }
            // R4: the drain's wall-clock cap. Once it is spent, stop starting work
            // so a stalled sidecar cannot hold the scoring lane thread.
            guard drainDeadline.timeIntervalSinceNow >= CandidateStage.minAttemptSeconds else {
                stats.skippedDeadline += 1
                return
            }
            let selection: SelectedProvider?
            do {
                selection = try store.selectedProvider(userId: claim.userId, metric: metric)
            } catch {
                stats.lastError = "candidate store (selection) failed: \(String(describing: error))"
                continue
            }
            guard let selection, !selection.isOff else {
                stats.skippedOff += 1
                continue
            }
            guard let input = inputs.input(for: metric) else {
                // No input assembly for this metric yet (sleep/respiration arrive
                // with their providers). Not an error: nothing is called.
                stats.skippedNoInput += 1
                continue
            }
            runsRemaining -= 1
            runOne(metric: metric, selection: selection, input: input, claim: claim, inputs: inputs)
        }
    }

    private mutating func runOne(metric: String, selection: SelectedProvider, input: JSONValue,
                                 claim: DayScorer.Claim, inputs: DayScorer.CandidateInputs) {
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
            return
        }

        var attempts = 0
        var response: InferenceResponse?
        var failure: InferenceClientError?
        var elapsedMS = 0
        while attempts < maxAttempts {
            // R4: never start an attempt that the drain cap cannot accommodate,
            // and never let one attempt outlive the cap.
            let remaining = drainDeadline.timeIntervalSinceNow
            guard remaining >= CandidateStage.minAttemptSeconds else { break }
            let attemptBudgetMS = min(client.timeoutMS, Int(remaining * 1000))
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
                if !CandidateStage.isRetryable(error) { break }
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
            return
        }
        stats.lastCallAt = Date()
        stats.lastProviderId = selection.providerId
        stats.lastRuntimeMS = elapsedMS

        let record = buildRecord(metric: metric, selection: selection, claim: claim, inputs: inputs,
                                 inputSHA: inputSHA, response: response, failure: failure,
                                 attempts: attempts, elapsedMS: elapsedMS)
        stats.lastWithheldReason = record.withheldReason
        switch record.status {
        case "ok": stats.ok += 1
        case "withheld": stats.withheld += 1
        default: stats.errors += 1
        }
        if let failure { stats.lastError = failure.description }

        // ACTIVE PROMOTION: only reachable when a metric's mode is `active`.
        // The shipped defaults are `off` for all four metrics.
        if metric == "hrv", record.status == "ok", selection.isActive,
           let substitution = CandidateStage.activeHrvSubstitution(
               selection: selection, response: response, inputSHA256: inputSHA) {
            lastActiveSubstitution = substitution
            stats.activeSubstitutions += 1
        }

        do {
            if let candidateId = try store.recordCandidate(record) {
                stats.recorded += 1
                _ = candidateId
            } else {
                stats.duplicates += 1
            }
        } catch {
            stats.writeFailures += 1
            stats.lastError = "candidate write failed: \(String(describing: error))"
        }
    }

    /// Turn one call outcome into a record. A client failure always becomes a
    /// withheld row (never a retry loop and never a canonical change).
    private func buildRecord(metric: String, selection: SelectedProvider, claim: DayScorer.Claim,
                             inputs: DayScorer.CandidateInputs, inputSHA: String,
                             response: InferenceResponse?, failure: InferenceClientError?,
                             attempts: Int, elapsedMS: Int) -> CandidateRecord {
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
        let mode = (obj["mode"] as? String) ?? "off"
        let providerId = (obj["provider_id"] as? String) ?? ""
        if mode == "off" || providerId.isEmpty { return nil }
        return SelectedProvider(
            providerId: providerId,
            providerVersion: (obj["provider_version"] as? String) ?? "unknown",
            configVersion: (obj["config_version"] as? String) ?? "unknown",
            mode: mode)
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
