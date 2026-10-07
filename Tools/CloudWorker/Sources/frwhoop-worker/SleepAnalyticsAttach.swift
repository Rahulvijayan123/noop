import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// SleepAnalyticsAttach.swift — the worker adapter for the Phase 1 sleep analytics
// document (`daily.sleep_analytics_v1`, docs/sleep-analytics/spec.md worker steps 1–2, 5, 7).
//
// The shared extractor (`SleepAnalyticsV1.compute(input:config:)` in Packages/StrandAnalytics)
// is PURE: this adapter only assembles `SleepAnalyticsInput` from the day's EXACT lineage and
// serializes the returned document. It is the pure-Swift twin of the dormant Python-sidecar
// `attachSleepFeatures` — no sidecar, no model, no DB read, no additional inference call.
//
// Bounded by contract: ANY failure here (empty main-night group, compute/encode error, a
// non-finite number reaching the wire) returns nil and emits ONE structured log line with
// counts/reasons — never raw arrays — so the caller withholds only this document and the
// canonical snapshot stays byte-identical (spec worker step 5).
//
// The static seams take `stageSourceVersion` explicitly so the pure logic is testable without
// a database; the instance wrappers thread the day's `v2StageAlgorithmVersion` (the same value
// `attachSleepFeatures` stamps into its night entries) at the `scoreAndBuildPayloads` call site.
extension DayScorer {

    // MARK: - Input assembly (pure; testable without compute())

    /// Assemble the extractor input from the day's resolved main-night group (spec worker
    /// step 1). The fragments are `result.sleepSessions` whose effective `[start, end)` EXACTLY
    /// matches a block of `result.mainNightBlocks` — the SAME group scoring uses (never a
    /// re-picked longest session, never a nap). Sorted by start. Returns nil when the day has
    /// no main-night fragment (a `no_data`/no-session day withholds the document).
    ///
    /// Lineage mirrored from `attachSleepFeatures` / `legacyNights`:
    ///   * fragment id = `sleep-<deviceId>-<session.start>` (the wire id the app matches on);
    ///   * `edited` = an accepted sleep edit's ORIGINAL span overlaps the session
    ///     (`payload.originalStart`/`originalEnd`, the same rule the enrichment uses);
    ///   * `editRevision` = the NEWEST overlapping edit's revision (`loadSleepEdits` returns
    ///     newest-first, so the authoritative edit wins, matching the candidate lane).
    static func sleepAnalyticsInput(stageSourceVersion: String,
                                    result: AnalyticsEngine.DayResult,
                                    claim: Claim,
                                    hr: [HRSample],
                                    rr: [RRInterval],
                                    gravity: [GravitySample],
                                    skinTemp: [SkinTempSample],
                                    skinFamily: DeviceFamily,
                                    edits: [CandidateSleepEdit],
                                    offWristIntervals: [(start: Int, end: Int)]) -> SleepAnalyticsInput? {
        let blocks = result.mainNightBlocks
        var fragments: [SleepAnalyticsInput.Fragment] = []
        fragments.reserveCapacity(blocks.count)
        for session in result.sleepSessions {
            guard blocks.contains(where: { $0.start == session.start && $0.end == session.end }) else {
                continue
            }
            var overlappingRevision: Int64? = nil
            for edit in edits {
                guard let originalStart = edit.payload.member("originalStart")?.doubleValue.map({ Int($0) }),
                      let originalEnd = edit.payload.member("originalEnd")?.doubleValue.map({ Int($0) }) else {
                    continue
                }
                // The authoritative edit is the newest accepted revision (`loadSleepEdits`
                // sorts newest-first); max() keeps this order-independent for the caller.
                if session.start < originalEnd && originalStart < session.end {
                    overlappingRevision = max(overlappingRevision ?? 0, edit.revision)
                }
            }
            fragments.append(SleepAnalyticsInput.Fragment(
                id: "sleep-\(claim.deviceId)-\(session.start)",
                start: session.start, end: session.end,
                // SleepStagerV2 native 30-second epochs; the extractor's native support mask
                // grids at this resolution (spec 4.4, 4.9). The stager's grid anchor IS the
                // session start (sessions are never reshaped server-side), passed explicitly
                // so alignment is verified against the stager's own grid (review P2-4).
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                edited: overlappingRevision != nil, editRevision: overlappingRevision,
                stageGridAnchorSeconds: session.start,
                stages: session.stages))
        }
        fragments.sort { $0.start < $1.start }
        guard !fragments.isEmpty else { return nil }

        // The whoop-4 per-device worn anchor: the SAME value the canonical funnel and the
        // sleep-features enrichment use (`Whoop4SkinTemp.deviceAnchorRaw`), nil elsewhere.
        let anchorRaw: Double? = skinFamily == .whoop4
            ? Whoop4SkinTemp.deviceAnchorRaw(skinTemp.map { $0.raw }) : nil

        return SleepAnalyticsInput(
            fragments: fragments,
            timezoneId: claim.timezoneId,
            // Streams passed AS LOADED (spec worker step 2): no per-metric requery, no history
            // expansion. The extractor clips internally to the fragments plus the explicit
            // peri-sleep thermal windows.
            hr: hr,
            gravity: gravity,
            skinTemp: skinTemp,
            beats: dedupByObservationIdentity(rr),      // same identity rule as the candidate lane
            deviceFamily: skinFamily,
            skinTempAnchorRaw: anchorRaw,
            offWristIntervals: offWristIntervals.map { SleepAnalyticsInterval(start: $0.start, end: $0.end) },
            // Phase 1 wires NO attempted-sleep marker: no marker source has verified semantics
            // yet, so the latency metric answers missing_marker — never zero (spec section 5).
            attemptedSleepMarker: nil,
            // The canonical staging algorithm of the day being scored — the SAME value
            // attachSleepFeatures stamps into its night entries (spec worker step 6 keeps the
            // legacy algorithm-version report untouched; this is the INNER lineage string).
            stageSourceVersion: stageSourceVersion,
            inputRevision: claim.inputRevision)
    }

    /// Instance convenience: thread the day's `v2StageAlgorithmVersion` (the value
    /// `attachSleepFeatures` sends), matching the enrichment's lineage exactly.
    func sleepAnalyticsInput(result: AnalyticsEngine.DayResult,
                             claim: Claim,
                             hr: [HRSample],
                             rr: [RRInterval],
                             gravity: [GravitySample],
                             skinTemp: [SkinTempSample],
                             skinFamily: DeviceFamily,
                             edits: [CandidateSleepEdit],
                             offWristIntervals: [(start: Int, end: Int)]) -> SleepAnalyticsInput? {
        Self.sleepAnalyticsInput(stageSourceVersion: v2StageAlgorithmVersion,
                                 result: result, claim: claim, hr: hr, rr: rr,
                                 gravity: gravity, skinTemp: skinTemp, skinFamily: skinFamily,
                                 edits: edits, offWristIntervals: offWristIntervals)
    }

    // MARK: - Document payload (compute + serialize; bounded failure)

    /// Build and serialize the `daily.sleep_analytics_v1` dictionary for the day's main-night
    /// group. Returns nil on ANY failure (empty fragments, compute/encode error, non-finite
    /// value on the wire); the caller leaves the canonical payload untouched.
    static func sleepAnalyticsPayload(stageSourceVersion: String,
                                      result: AnalyticsEngine.DayResult,
                                      claim: Claim,
                                      hr: [HRSample],
                                      rr: [RRInterval],
                                      gravity: [GravitySample],
                                      skinTemp: [SkinTempSample],
                                      skinFamily: DeviceFamily,
                                      edits: [CandidateSleepEdit],
                                      offWristIntervals: [(start: Int, end: Int)]) -> [String: Any]? {
        guard let input = sleepAnalyticsInput(
            stageSourceVersion: stageSourceVersion, result: result, claim: claim,
            hr: hr, rr: rr, gravity: gravity, skinTemp: skinTemp, skinFamily: skinFamily,
            edits: edits, offWristIntervals: offWristIntervals) else {
            // No main-night group: nothing to compute; the document is withheld (a no_data day
            // has no sessions and never reaches this point, but the adapter stays total).
            logSleepAnalytics(claim: claim, outcome: "withheld", reason: "no_main_night_fragments",
                              fragmentCount: 0, bytes: nil, statuses: nil)
            return nil
        }

        // Compute once, after the effective canonical result is resolved (spec worker step 3).
        // Documented signature: SleepAnalyticsV1.compute(input:config:) -> SleepAnalyticsDocument
        // (non-throwing; the top-level compute() entry point lands with the group computers on
        // the integration branch. If the merged signature ever becomes `throws`, add `try` here.)
        let document = SleepAnalyticsV1.compute(input: input, config: .v1)

        // Encode through Codable, then rehydrate to a JSON dictionary. JSONEncoder refuses
        // non-finite Doubles outright; the recursive check below is the belt-and-suspenders
        // guarantee that nothing NaN/Inf reaches the wire (spec: JSON null is explicit, never
        // NaN or Infinity).
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  isFiniteJSON(json) else {
                logSleepAnalytics(claim: claim, outcome: "withheld", reason: "non_finite_json",
                                  fragmentCount: input.fragments.count, bytes: data.count, statuses: nil)
                return nil
            }
            // The wire keys are snake_case (the shared contract's CodingKeys); the
            // log reads them by the SAME names so no group ever logs ":?"
            // (review P3-1).
            let statuses = [
                "continuity", "stage_dynamics", "movement", "thermal", "prv_diagnostics",
            ].map { key -> String in
                guard let group = json[key] as? [String: Any],
                      let quality = group["quality"] as? [String: Any],
                      let status = quality["status"] as? String else { return key + ":?" }
                return key + ":" + status
            }.joined(separator: ",")
            logSleepAnalytics(claim: claim, outcome: "attached", reason: nil,
                              fragmentCount: input.fragments.count, bytes: data.count, statuses: statuses)
            return json
        } catch {
            logSleepAnalytics(claim: claim, outcome: "withheld", reason: "serialization_failed",
                              fragmentCount: input.fragments.count, bytes: nil, statuses: nil)
            return nil
        }
    }

    /// Instance convenience for the `scoreAndBuildPayloads` call site (threads the day's
    /// `v2StageAlgorithmVersion`, matching `attachSleepFeatures`).
    func sleepAnalyticsPayload(result: AnalyticsEngine.DayResult,
                               claim: Claim,
                               hr: [HRSample],
                               rr: [RRInterval],
                               gravity: [GravitySample],
                               skinTemp: [SkinTempSample],
                               skinFamily: DeviceFamily,
                               edits: [CandidateSleepEdit],
                               offWristIntervals: [(start: Int, end: Int)]) -> [String: Any]? {
        Self.sleepAnalyticsPayload(stageSourceVersion: v2StageAlgorithmVersion,
                                   result: result, claim: claim, hr: hr, rr: rr,
                                   gravity: gravity, skinTemp: skinTemp, skinFamily: skinFamily,
                                   edits: edits, offWristIntervals: offWristIntervals)
    }

    // MARK: - Bounded diagnostics (spec worker step 7)

    /// ONE bounded log line per attach attempt: counts and group statuses, never raw arrays.
    /// Mirrors the worker's `FileHandle.standardError` line style.
    static func logSleepAnalytics(claim: Claim, outcome: String, reason: String?,
                                  fragmentCount: Int, bytes: Int?, statuses: String?) {
        var line = "frwhoop-worker: day \(claim.day) device \(claim.deviceId.prefix(8)) "
            + "sleep_analytics_v1 \(outcome)"
        if let reason = reason { line += " reason=\(reason)" }
        line += " fragments=\(fragmentCount)"
        if let bytes = bytes { line += " bytes=\(bytes)" }
        if let statuses = statuses { line += " statuses=\(statuses)" }
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }

    /// Recursive finite check over a JSON-decoded object tree: every number must be finite.
    /// The document contract forbids NaN/Infinity on the wire; a violation withholds the
    /// document instead of publishing it.
    static func isFiniteJSON(_ value: Any) -> Bool {
        if let n = value as? NSNumber {
            return n.doubleValue.isFinite
        }
        if let dict = value as? [String: Any] {
            for (_, v) in dict where !isFiniteJSON(v) { return false }
            return true
        }
        if let arr = value as? [Any] {
            for v in arr where !isFiniteJSON(v) { return false }
            return true
        }
        return true   // String / Bool / NSNull leaves
    }
}
