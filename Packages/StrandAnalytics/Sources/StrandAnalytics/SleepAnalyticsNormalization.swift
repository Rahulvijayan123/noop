import Foundation
import WhoopProtocol

// SleepAnalyticsNormalization.swift — the single timeline normalization every Phase 1 sleep
// analytics group derives from (docs/sleep-analytics/spec.md section 4, "Normalize once, then
// derive all timeline metrics"). ROOT-OWNED shared seam: the continuity/stage-dynamics,
// movement, thermal and PRV group computers all consume the `SleepAnalyticsTimeline` built
// here, so the eight normalization rules have exactly one implementation.
//
// Rules implemented (spec 4.1–4.9):
//   1. Half-open `[start, end)` intervals, elapsed UTC seconds; sorted, clipped to each
//      effective fragment; invalid zero/negative spans discarded and counted (4.1).
//   2. Exact duplicates collapsed; same-label overlaps unioned; conflicting overlaps at equal
//      precedence become `unknown` over the conflict, with the conflicted seconds counted
//      (4.2). Source revision/edits are resolved BEFORE normalization by the adapter — the
//      input's fragments/stages are already the effective ones.
//   3. Labels mapped through the shared vocabulary (`SleepStageVocabulary`); everything not
//      wake/light/deep/rem becomes `unknown`. N1/N2 are never invented from light, and
//      light/deep are never invented from NREM (4.3).
//   4. Native WHOOP fragments: a 30-second epoch grid anchored at the fragment's effective
//      start; an epoch is label-supported when ≥15 distinct seconds carry valid HR or gravity
//      evidence (≥50% for a clipped final epoch), and explicit off-wrist intervals override
//      support. Both the actual distinct input-supported seconds and the label-supported
//      duration are recorded (4.4).
//   5. Timed external hypnograms keep their REAL resolution; sensor support stays unknown
//      (`sensor_support_unknown`). Totals-only imports carry their minutes; no synthetic
//      timeline is manufactured (4.5).
//   6. Uncovered spans inside a fragment and unsupported native epochs are `unknown`; nothing
//      is forward-filled, interpolated, or defaulted to awake/asleep/still (4.6).
//   7. Inter-fragment gaps are retained separately as `inferred_inter_fragment_awake` (the
//      existing canonical bridging assumption) — they never create sensor coverage, completed
//      bouts or observed transitions, and observed WASO stays separate (4.7).
//   8. Discontinuities at fragment/source/resolution boundaries are kept even when timestamps
//      touch: no transition or bout joins across them (4.8).
//   9. Native 30-second labels are reconstructed only where the stager's resolution and
//      alignment are established (the native grid); coarse imports are never subdivided into
//      synthetic 30-second self-transitions (4.9).
//
// The extractor never re-picks the main night, never re-runs a stager, and never rewrites the
// stored hypnogram: this is a read-only view over the effective fragments.

extension SleepAnalyticsV1 {

    /// Normalize the input's effective fragments into the shared timeline (spec 4).
    /// Pure and deterministic. O(n log n) in segment count plus linear passes.
    public static func normalize(input: SleepAnalyticsInput,
                                 config: SleepAnalyticsConfig) -> SleepAnalyticsTimeline {
        // ── Per-second evidence sets (built once; every epoch-support check is O(1)) ──
        // A second carries valid evidence when it has a valid HR sample or a valid gravity
        // sample (engineering presence check, spec 4.4 — NOT a calibrated probability).
        var evidenceSeconds = Set<Int>()
        var hrReceived = 0, hrDuplicate = 0, hrRejected = 0
        var hrSeen = Set<Int>()
        for s in input.hr {
            hrReceived += 1
            if !hrSeen.insert(s.ts).inserted { hrDuplicate += 1; continue }
            if Double(s.bpm) >= config.hrPlausibleMinBpm && Double(s.bpm) <= config.hrPlausibleMaxBpm {
                evidenceSeconds.insert(s.ts)
            } else {
                hrRejected += 1
            }
        }
        var gravityReceived = 0, gravityDuplicate = 0, gravityRejected = 0
        var gravitySeen = Set<Int>()
        for g in input.gravity {
            gravityReceived += 1
            if !gravitySeen.insert(g.ts).inserted { gravityDuplicate += 1; continue }
            let norm = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            if g.x.isFinite && g.y.isFinite && g.z.isFinite
                && norm >= config.gravityNormMinG && norm <= config.gravityNormMaxG {
                evidenceSeconds.insert(g.ts)
            } else {
                gravityRejected += 1
            }
        }

        // ── Fragment spans: validate, sort, keep (no overlap removal across fragments —
        //    fragments of one resolved group are disjoint by construction; a degenerate
        //    duplicate is dropped) ──
        var fragments: [SleepAnalyticsTimeline.FragmentSpan] = []
        var discardedSpanCount = 0
        var discardedSpanSeconds = 0
        var seenFragmentIds = Set<String>()
        for f in input.fragments {
            guard f.end > f.start else { continue }          // invalid span → not a fragment
            guard seenFragmentIds.insert(f.id).inserted else { continue }   // exact duplicate id
            fragments.append(SleepAnalyticsTimeline.FragmentSpan(
                id: f.id, start: f.start, end: f.end,
                sourceKind: f.sourceKind, sourceEpochSeconds: f.sourceEpochSeconds,
                totalsMinutes: f.totalsMinutes))
        }
        fragments.sort { $0.start < $1.start }
        // A later fragment starting inside an earlier one clips at the boundary (equal-
        // precedence overlap between DIFFERENT fragments is impossible from one resolved
        // group; the adapter contract forbids it, and clipping keeps the map disjoint).
        for i in fragments.indices.dropFirst() where fragments[i].start < fragments[i - 1].end {
            fragments[i] = SleepAnalyticsTimeline.FragmentSpan(
                id: fragments[i].id, start: fragments[i - 1].end, end: fragments[i].end,
                sourceKind: fragments[i].sourceKind,
                sourceEpochSeconds: fragments[i].sourceEpochSeconds,
                totalsMinutes: fragments[i].totalsMinutes)
        }

        let windowStart = fragments.first?.start ?? 0
        let windowEnd = fragments.last?.end ?? 0

        // ── Inter-fragment gaps: retained separately, origin inferred_inter_fragment_awake ──
        var inferredGaps: [SleepAnalyticsInterval] = []
        if fragments.count > 1 {
            for i in 1..<fragments.count {
                let prevEnd = fragments[i - 1].end
                let start = fragments[i].start
                if start > prevEnd {
                    inferredGaps.append(SleepAnalyticsInterval(start: prevEnd, end: start))
                }
            }
        }

        // ── Per-fragment normalization ──
        var intervals: [SleepAnalyticsTimeline.Interval] = []
        var conflictSeconds = 0

        for (fragmentIndex, fragment) in fragments.enumerated() {
            let stages = input.fragments.first(where: { $0.id == fragment.id })?.stages ?? []

            switch fragment.sourceKind {
            case .nativeWhoop:
                normalizeNativeFragment(
                    fragment: fragment, fragmentIndex: fragmentIndex, stages: stages,
                    evidenceSeconds: evidenceSeconds, offWrist: input.offWristIntervals,
                    config: config, intervals: &intervals, conflictSeconds: &conflictSeconds,
                    discardedSpanCount: &discardedSpanCount,
                    discardedSpanSeconds: &discardedSpanSeconds)

            case .timestampedExternal:
                normalizeExternalFragment(
                    fragment: fragment, fragmentIndex: fragmentIndex, stages: stages,
                    intervals: &intervals, conflictSeconds: &conflictSeconds,
                    discardedSpanCount: &discardedSpanCount,
                    discardedSpanSeconds: &discardedSpanSeconds)

            case .totalsOnly:
                // No timeline is manufactured from totals (spec 4.5): the fragment span is
                // retained for coverage arithmetic, its uncovered time stays unknown, and
                // the stage summaries read `totalsMinutes` directly.
                break
            }
        }

        // ── Anchors (spec section 4 quality: onset/offset observability) ──
        let asleepIntervals = intervals.filter {
            $0.labelSupported && ($0.label == .light || $0.label == .deep || $0.label == .rem)
        }
        let firstSupportedAsleepStart = asleepIntervals.first?.start
        let lastSupportedAsleepEnd = asleepIntervals.last?.end

        var onsetPrefixObserved = false
        var offsetSuffixObserved = false
        if let onset = firstSupportedAsleepStart {
            // The prefix [windowStart, onset) must contain no unknown interval and no
            // inferred gap, and the first asleep run must not touch its fragment's left
            // edge without an observed preceding wake epoch (spec: left-censored boundary).
            let prefixUnknown = intervals.contains {
                $0.label == .unknown && $0.start < onset && $0.end > windowStart
            }
            let prefixGap = inferredGaps.contains { $0.start < onset && $0.end > windowStart }
            let onsetInterval = intervals.first {
                $0.labelSupported && $0.label != .wake && $0.label != .unknown && $0.start == onset
            }
            let fragmentStart = onsetInterval.flatMap {
                $0.fragmentIndex < fragments.count ? fragments[$0.fragmentIndex].start : nil
            }
            let precededByWake = fragmentStart.map { onset > $0 } ?? false
                && intervals.contains {
                    $0.labelSupported && $0.label == .wake && $0.end <= onset && $0.end > (fragmentStart ?? windowStart)
                }
            onsetPrefixObserved = !prefixUnknown && !prefixGap && precededByWake
        }
        if let offset = lastSupportedAsleepEnd {
            let suffixUnknown = intervals.contains {
                $0.label == .unknown && $0.start < windowEnd && $0.end > offset
            }
            let suffixGap = inferredGaps.contains { $0.start < windowEnd && $0.end > offset }
            let offsetInterval = intervals.last {
                $0.labelSupported && $0.label != .wake && $0.label != .unknown && $0.end == offset
            }
            let fragmentEnd = offsetInterval.flatMap {
                $0.fragmentIndex < fragments.count ? fragments[$0.fragmentIndex].end : nil
            }
            let followedByWake = fragmentEnd.map { offset < $0 } ?? false
                && intervals.contains {
                    $0.labelSupported && $0.label == .wake && $0.start >= offset
                        && $0.start < (fragmentEnd ?? windowEnd)
                }
            offsetSuffixObserved = !suffixUnknown && !suffixGap && followedByWake
        }

        return SleepAnalyticsTimeline(
            windowStart: windowStart,
            windowEnd: windowEnd,
            fragments: fragments,
            intervals: intervals,
            inferredGapIntervals: inferredGaps,
            discardedSpanCount: discardedSpanCount,
            discardedSpanSeconds: discardedSpanSeconds,
            conflictSeconds: conflictSeconds,
            firstSupportedAsleepStart: firstSupportedAsleepStart,
            lastSupportedAsleepEnd: lastSupportedAsleepEnd,
            onsetPrefixObserved: onsetPrefixObserved,
            offsetSuffixObserved: offsetSuffixObserved)
    }

    // MARK: - Native fragment (spec 4.4, 4.9)

    /// Normalize one native WHOOP fragment onto its 30-second epoch grid (anchored at the
    /// fragment's effective start — the stager's own alignment), with the input-support mask.
    private static func normalizeNativeFragment(
        fragment: SleepAnalyticsTimeline.FragmentSpan,
        fragmentIndex: Int,
        stages: [StageSegment],
        evidenceSeconds: Set<Int>,
        offWrist: [SleepAnalyticsInterval],
        config: SleepAnalyticsConfig,
        intervals: inout [SleepAnalyticsTimeline.Interval],
        conflictSeconds: inout Int,
        discardedSpanCount: inout Int,
        discardedSpanSeconds: inout Int) {

        // 4.1: clip to the fragment; drop invalid spans; count them.
        var clipped: [(start: Int, end: Int, label: SleepAnalyticsLabel)] = []
        for seg in stages {
            guard let label = mapStageLabel(seg.stage) else {
                // Unscored/artifact/unknown-named segments never fabricate coverage: their
                // span stays unknown (covered by the uncovered-time rule below).
                if seg.end > seg.start {
                    clipped.append((max(seg.start, fragment.start), min(seg.end, fragment.end), .unknown))
                }
                continue
            }
            guard seg.end > seg.start else {
                discardedSpanCount += 1
                discardedSpanSeconds += max(0, seg.end - seg.start)
                continue
            }
            let s = max(seg.start, fragment.start), e = min(seg.end, fragment.end)
            guard e > s else { continue }                     // fully outside the fragment
            clipped.append((s, e, label))
        }

        // 4.2: collapse exact duplicates; same-label overlaps union naturally at the sweep
        // below; conflicting overlaps become unknown over the conflict.
        let deduped = Dictionary(grouping: clipped, by: { "\($0.start):\($0.end):\($0.label)" })
            .compactMap { $0.value.first }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        // Boundary events for the elementary-slice sweep (conflict detection, spec 4.2).
        var boundaries = Set<Int>()
        for seg in deduped { boundaries.insert(seg.start); boundaries.insert(seg.end) }
        boundaries.insert(fragment.start)
        boundaries.insert(fragment.end)
        let sortedBoundaries = boundaries.filter { $0 >= fragment.start && $0 <= fragment.end }.sorted()

        // 4.4/4.9: the native epoch grid. The stager's resolution and alignment are
        // established for native fragments: epochs are [start, start+30), …, clipped at end.
        let epochSeconds = fragment.sourceEpochSeconds ?? config.nativeEpochSeconds
        let epochStarts = stride(from: fragment.start, to: fragment.end, by: epochSeconds)

        // Slices with resolved labels (conflicts → unknown), used by the epoch majority rule.
        func sliceLabel(_ from: Int, _ to: Int) -> SleepAnalyticsLabel {
            guard to > from else { return .unknown }
            var labels = Set<SleepAnalyticsLabel>()
            for seg in deduped where seg.start < to && seg.end > from {
                labels.insert(seg.label)
            }
            if labels.isEmpty { return .unknown }
            if labels.count > 1 {
                conflictSeconds += to - from
                return .unknown
            }
            return labels.first ?? .unknown
        }

        // Per-epoch: label = the label covering the MAJORITY of the epoch (ties → the label of
        // the earlier covering segment; no coverage → unknown), plus the support mask.
        struct Epoch {
            var start: Int, end: Int
            var label: SleepAnalyticsLabel
            var supported: Bool
            var inputSupportedSeconds: Int
        }
        var epochs: [Epoch] = []
        epochs.reserveCapacity(Int(ceil(Double(fragment.end - fragment.start) / Double(epochSeconds))))
        for epochStart in epochStarts {
            let epochEnd = min(epochStart + epochSeconds, fragment.end)
            let full = epochEnd - epochStart == epochSeconds

            // Majority label over elementary slices (ties → the earlier covering segment
            // wins: slices are visited in ascending order). Each slice's label is resolved
            // EXACTLY once — `sliceLabel` also counts conflicted seconds, so it must never be
            // called twice for the same slice.
            var sliceList: [(Int, Int)] = []
            var b = epochStart
            for next in sortedBoundaries where next > epochStart && next < epochEnd {
                sliceList.append((b, next)); b = next
            }
            if b < epochEnd { sliceList.append((b, epochEnd)) }
            let sliceLabels = sliceList.map { sliceLabel($0.0, $0.1) }
            var counts: [SleepAnalyticsLabel: Int] = [:]
            for (i, label) in sliceLabels.enumerated() {
                counts[label, default: 0] += sliceList[i].1 - sliceList[i].0
            }
            var bestLabel = SleepAnalyticsLabel.unknown
            var bestCount = 0
            for label in sliceLabels {              // ascending → earliest slice wins ties
                let count = counts[label] ?? 0
                if count > bestCount { bestCount = count; bestLabel = label }
            }
            if bestCount == 0 { bestLabel = .unknown }

            // Support mask: ≥15 distinct valid-evidence seconds (≥50% of a clipped epoch),
            // and explicit off-wrist evidence overrides support (spec 4.4).
            var distinct = 0
            for ts in epochStart..<epochEnd where evidenceSeconds.contains(ts) { distinct += 1 }
            let needed = full
                ? config.nativeMinDistinctSupportedSeconds
                : Int(ceil(Double(epochEnd - epochStart) * config.nativeMinSupportFraction))
            let offWristOverride = offWrist.contains { $0.start < epochEnd && epochStart < $0.end }
            let supported = !offWristOverride && distinct >= max(1, needed)

            // Spec 4.6: an unsupported native epoch is UNKNOWN — the stager's carried label
            // never survives without input support (no forward-fill of unsupported labels).
            epochs.append(Epoch(start: epochStart, end: epochEnd,
                                label: supported ? bestLabel : .unknown,
                                supported: supported, inputSupportedSeconds: distinct))
        }

        // Merge adjacent epochs with equal (label, supported) — and count input-supported
        // seconds per merged interval (4.4: qualifying an epoch does not turn its missing raw
        // seconds into observed sensor time; the distinct-second counts stay actual).
        mergeInto(intervals: &intervals, fragmentIndex: fragmentIndex,
                  runs: epochs.map {
                      (start: $0.start, end: $0.end, label: $0.label,
                       supported: $0.supported, inputSupportedSeconds: $0.inputSupportedSeconds)
                  })
    }

    // MARK: - Timed external fragment (spec 4.5, 4.6, 4.9)

    /// Normalize one timed external hypnogram fragment at its REAL resolution. Labels are
    /// supported at the source's own coverage (the segment must tile its span); sensor
    /// support is explicitly unknown (inputSupportedSeconds stays 0); no 30-second grid and
    /// no self-transition subdivision is manufactured.
    private static func normalizeExternalFragment(
        fragment: SleepAnalyticsTimeline.FragmentSpan,
        fragmentIndex: Int,
        stages: [StageSegment],
        intervals: inout [SleepAnalyticsTimeline.Interval],
        conflictSeconds: inout Int,
        discardedSpanCount: inout Int,
        discardedSpanSeconds: inout Int) {

        var clipped: [(start: Int, end: Int, label: SleepAnalyticsLabel)] = []
        for seg in stages {
            let label = mapStageLabel(seg.stage)
            guard seg.end > seg.start else {
                discardedSpanCount += 1
                discardedSpanSeconds += max(0, seg.end - seg.start)
                continue
            }
            let s = max(seg.start, fragment.start), e = min(seg.end, fragment.end)
            guard e > s else { continue }
            clipped.append((s, e, label ?? .unknown))
        }

        var boundaries = Set<Int>()
        for seg in clipped { boundaries.insert(seg.start); boundaries.insert(seg.end) }
        boundaries.insert(fragment.start)
        boundaries.insert(fragment.end)
        let sortedBoundaries = boundaries.filter { $0 >= fragment.start && $0 <= fragment.end }.sorted()

        // Elementary-slice sweep with the SAME conflict rule (spec 4.2 applies to every
        // source): one label → that label; conflicting → unknown over the conflict.
        var runs: [(start: Int, end: Int, label: SleepAnalyticsLabel, supported: Bool,
                    inputSupportedSeconds: Int)] = []
        var b = fragment.start
        for next in sortedBoundaries.dropFirst() {
            guard next > b else { continue }
            var labels = Set<SleepAnalyticsLabel>()
            for seg in clipped where seg.start < next && seg.end > b { labels.insert(seg.label) }
            let label: SleepAnalyticsLabel
            if labels.count == 1 {
                label = labels.first!
            } else {
                if !labels.isEmpty { conflictSeconds += next - b }
                label = .unknown
            }
            // External labels are supported at the source's real coverage; the segment
            // covering a slice IS that coverage. inputSupportedSeconds stays 0: sensor
            // support is explicitly unknown for external sources.
            let supported = labels.count == 1 && label != .unknown
            runs.append((start: b, end: next, label: label, supported: supported,
                         inputSupportedSeconds: 0))
            b = next
        }

        mergeInto(intervals: &intervals, fragmentIndex: fragmentIndex, runs: runs)
    }

    // MARK: - Shared helpers

    /// Map a raw stage string through the shared vocabulary (spec 4.3). Returns nil when the
    /// label is not one of wake/light/deep/rem (the caller keeps the span unknown). "awake"
    /// and "wake" are the same stage (`SleepStageVocabulary`); case/whitespace tolerant.
    /// N1/N2 are never invented from light; NREM never becomes light or deep.
    static func mapStageLabel(_ raw: String) -> SleepAnalyticsLabel? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if SleepStageVocabulary.isWake(s) { return .wake }
        switch s {
        case "light": return .light
        case "deep": return .deep
        case "rem": return .rem
        default: return nil          // "nrem", "uns", "artifact", … → unknown, never invented
        }
    }

    /// Merge adjacent same-(label, supported) runs into timeline intervals within one
    /// fragment. Adjacency is exact (end == next start); any discontinuity keeps them apart
    /// (spec 4.8 — no bout or transition joins across a boundary even when timestamps touch).
    private static func mergeInto(
        intervals: inout [SleepAnalyticsTimeline.Interval],
        fragmentIndex: Int,
        runs: [(start: Int, end: Int, label: SleepAnalyticsLabel, supported: Bool,
                inputSupportedSeconds: Int)]) {
        var current: (start: Int, end: Int, label: SleepAnalyticsLabel, supported: Bool,
                      inputSupportedSeconds: Int)?
        for run in runs {
            if let c = current, c.end == run.start, c.label == run.label,
               c.supported == run.supported {
                current = (c.start, run.end, c.label, c.supported,
                           c.inputSupportedSeconds + run.inputSupportedSeconds)
            } else {
                if let c = current {
                    intervals.append(SleepAnalyticsTimeline.Interval(
                        start: c.start, end: c.end, label: c.label, fragmentIndex: fragmentIndex,
                        labelSupported: c.supported, inputSupportedSeconds: c.inputSupportedSeconds))
                }
                current = run
            }
        }
        if let c = current {
            intervals.append(SleepAnalyticsTimeline.Interval(
                start: c.start, end: c.end, label: c.label, fragmentIndex: fragmentIndex,
                labelSupported: c.supported, inputSupportedSeconds: c.inputSupportedSeconds))
        }
    }
}
