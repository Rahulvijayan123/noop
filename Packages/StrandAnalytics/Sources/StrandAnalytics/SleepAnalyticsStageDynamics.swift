import Foundation
import WhoopProtocol

// SleepAnalyticsStageDynamics.swift — the stage-dynamics group (docs/sleep-analytics/
// spec.md section 5: stage bouts, per-label seconds, the 4×4 native epoch transition
// matrix). Root-owned implementation (two timeline-metrics workers stalled before
// writing code; the spec section and the shared contract are unchanged).
//
// Descriptive ESTIMATED architecture inherited from the source's labels: no
// probability vectors are constructed from labels, no entropy, no cycle count, no
// clinical abnormality or "optimal transition" score. Bouts are per-label maximal runs
// inside one fragment (never joined across fragment boundaries, even when timestamps
// touch); quantiles need ≥3 complete bouts (nearest-rank p90 = ceil(0.9·n)−1; median =
// mean of the two middle values for even n). The epoch transition matrix exists only
// for genuinely native sources at established alignment (spec 4.9: a coarse import is
// never subdivided into synthetic 30 s self-transitions) and counts only GENUINELY
// ADJACENT valid native epochs, self-transitions included; a row with no outgoing
// pairs has NULL probabilities, never a zero-probability row.

extension SleepAnalyticsV1 {

    static func stageDynamicsGroup(timeline: SleepAnalyticsTimeline,
                                   input: SleepAnalyticsInput,
                                   config: SleepAnalyticsConfig) -> SleepAnalyticsStageDynamicsGroup {

        let fragmentSpan = timeline.fragmentSpanSeconds
        let labelFraction = fragmentSpan > 0 ? timeline.totalLabelSupportedSeconds / fragmentSpan : nil
        let nativeOnly = timeline.fragments.allSatisfy { $0.sourceKind == .nativeWhoop }
            && !timeline.fragments.isEmpty
        let inputFraction = timeline.inputSupportedFraction(for: fragmentSpan)
        let labelGate = labelFraction.map { $0 >= config.stageSummaryMinLabelSupportedFraction } ?? false
        let inputGate = !nativeOnly
            || (inputFraction.map { $0 >= config.stageSummaryMinInputSupportedFraction } ?? false)
        let completeStageGate = labelGate && inputGate

        // ── Per-label seconds (union durations; no overlap double counting — the
        //    normalized intervals are already disjoint) ────────────────────────────
        // A totals-only fragment carries minutes with no timeline (spec 4.5): its
        // label seconds join as PARTIAL values through the fragment's own totals,
        // flagged in streamCounts, and everything bout/transition stays unavailable.
        let totalsOnlyFragments = timeline.fragments.filter { $0.totalsMinutes != nil }
        func stageSeconds(_ label: SleepAnalyticsLabel) -> SleepAnalyticsStageSeconds {
            switch label {
            case .wake, .light, .deep, .rem:
                let supported = timeline.supportedSeconds(of: label)
                var total = supported
                var fromTotalsOnly = 0.0
                for fragment in totalsOnlyFragments {
                    guard let minutes = fragment.totalsMinutes else { continue }
                    let seconds: Double
                    switch label {
                    case .wake: seconds = minutes.wake * 60
                    case .light: seconds = minutes.light * 60
                    case .deep: seconds = minutes.deep * 60
                    case .rem: seconds = minutes.rem * 60
                    default: seconds = 0
                    }
                    fromTotalsOnly += seconds
                    total += seconds
                }
                let metric: SleepAnalyticsMetric
                if total > 0 {
                    let partial = !completeStageGate || fromTotalsOnly > 0
                    metric = partial ? .partial(total, unit: "s") : .available(total, unit: "s")
                } else {
                    metric = .unavailable(.noSamples)
                }
                return SleepAnalyticsStageSeconds(label: label, seconds: metric)
            case .unknown:
                // Unknown time is a TIMELINE quantity: a totals-only group has no
                // timeline, so it is unsupported (review P3-7 alignment); an empty
                // group has no samples.
                let unknown = max(0, fragmentSpan - timeline.totalLabelSupportedSeconds)
                let metric: SleepAnalyticsMetric
                if !totalsOnlyFragments.isEmpty {
                    metric = .unavailable(.unsupportedSource)
                } else if unknown > 0 {
                    metric = .available(unknown, unit: "s")
                } else if timeline.fragments.isEmpty {
                    metric = .unavailable(.noSamples)
                } else {
                    metric = .available(0, unit: "s")
                }
                return SleepAnalyticsStageSeconds(label: .unknown, seconds: metric)
            }
        }
        let stageSecondsList: [SleepAnalyticsStageSeconds] = [
            stageSeconds(.wake), stageSeconds(.light), stageSeconds(.deep),
            stageSeconds(.rem), stageSeconds(.unknown),
        ]

        // ── Stage bouts per label ───────────────────────────────────────────────
        func stageBouts(_ label: SleepAnalyticsLabel) -> SleepAnalyticsStageBouts {
            // A bout = a maximal run of contiguous same-label SUPPORTED intervals in
            // one fragment. Complete = bounded on both sides by a DIFFERENT supported
            // label interval in the same fragment (an observed transition in + out);
            // anything touching a fragment edge or an unknown/unsupported neighbour is
            // censored (reported, never silently counted complete).
            var completeDurations: [Double] = []
            var censoredCount = 0
            var longest = 0.0
            var i = 0
            let intervals = timeline.intervals
            while i < intervals.count {
                guard intervals[i].label == label, intervals[i].labelSupported else {
                    i += 1
                    continue
                }
                var j = i
                while j + 1 < intervals.count,
                      intervals[j + 1].label == label, intervals[j + 1].labelSupported,
                      intervals[j + 1].fragmentIndex == intervals[i].fragmentIndex,
                      intervals[j + 1].start == intervals[j].end {
                    j += 1
                }
                let length = Double(intervals[j].end - intervals[i].start)
                longest = max(longest, length)
                let leftBounded = i > 0
                    && intervals[i - 1].fragmentIndex == intervals[i].fragmentIndex
                    && intervals[i - 1].end == intervals[i].start
                    && intervals[i - 1].labelSupported
                    && intervals[i - 1].label != .unknown
                    && intervals[i - 1].label != label
                let rightBounded = j + 1 < intervals.count
                    && intervals[j + 1].fragmentIndex == intervals[i].fragmentIndex
                    && intervals[j + 1].start == intervals[j].end
                    && intervals[j + 1].labelSupported
                    && intervals[j + 1].label != .unknown
                    && intervals[j + 1].label != label
                if leftBounded && rightBounded {
                    completeDurations.append(length)
                } else {
                    censoredCount += 1
                }
                i = j + 1
            }
            let count = completeDurations.count + censoredCount
            let quantiles = SleepAnalyticsV1.boutQuantiles(complete: completeDurations,
                                                           minBouts: config.minCompleteBoutsForQuantiles)
            // Bout metrics need a TIMELINE: a totals-only import answers
            // `unsupported_source` for every bout metric (review P1-3) — a zero count
            // without qualifying observed exposure would be a fabricated zero.
            func countMetric(_ v: Int) -> SleepAnalyticsCount {
                if !totalsOnlyFragments.isEmpty { return .unavailable(.unsupportedSource) }
                return timeline.fragments.isEmpty ? .unavailable(.noSamples) : .available(v)
            }
            let durationMetric: SleepAnalyticsMetric
            if !totalsOnlyFragments.isEmpty {
                durationMetric = .unavailable(.unsupportedSource)
            } else if count > 0 {
                durationMetric = completeStageGate ? .available(longest, unit: "s") : .partial(longest, unit: "s")
            } else {
                durationMetric = .unavailable(.noSamples)
            }
            let quantileMetrics: (median: SleepAnalyticsMetric, p90: SleepAnalyticsMetric)
            if !totalsOnlyFragments.isEmpty {
                quantileMetrics = (.unavailable(.unsupportedSource, unit: "s"),
                                   .unavailable(.unsupportedSource, unit: "s"))
            } else {
                quantileMetrics = quantiles
            }
            return SleepAnalyticsStageBouts(
                label: label,
                boutCount: countMetric(count),
                completeBoutCount: countMetric(completeDurations.count),
                censoredBoutCount: countMetric(censoredCount),
                longestObservedSeconds: durationMetric,
                medianCompleteBoutSeconds: quantileMetrics.median,
                p90CompleteBoutSeconds: quantileMetrics.p90)
        }
        let stageBoutsList: [SleepAnalyticsStageBouts] = [
            stageBouts(.wake), stageBouts(.light), stageBouts(.deep), stageBouts(.rem),
        ]

        // ── The 4×4 epoch transition matrix (native only, spec 4.9) ──────────────
        // Reconstructed ONLY where the source is native AND the segment boundaries
        // are epoch-aligned from the fragment start (`epochAlignmentEstablished` —
        // the normalization verifies the stager's own grid; an edited misaligned
        // start withholds the matrix as unsupported_source instead of manufacturing
        // boundaries the stager never produced). Each epoch takes the label of its
        // covering interval (native intervals are the merged epoch runs, so the grid
        // subdivides them exactly).
        let matrix: SleepAnalyticsTransitionMatrix?
        var observedBoutChangeCount: SleepAnalyticsCount? = nil
        if nativeOnly && timeline.epochAlignmentEstablished {
            let epochSeconds = timeline.fragments.first?.sourceEpochSeconds ?? config.nativeEpochSeconds
            let order: [SleepAnalyticsLabel] = [.wake, .light, .deep, .rem]
            func labelIndex(_ l: SleepAnalyticsLabel) -> Int? {
                order.firstIndex(of: l)
            }
            var counts = Array(repeating: Array(repeating: 0, count: 4), count: 4)
            var exposure = Array(repeating: 0, count: 4)
            var eligiblePairs = 0
            var stageChanges = 0

            // Per fragment: rebuild the epoch labels, then count adjacent pairs.
            for fragment in timeline.fragments {
                // Epoch grid anchored at the fragment start (the stager's own anchor).
                var epochLabels: [SleepAnalyticsLabel] = []
                var t = fragment.start
                while t < fragment.end {
                    let epochEnd = min(t + epochSeconds, fragment.end)
                    let covering = timeline.intervals.first {
                        $0.fragmentIndex == timeline.fragments.firstIndex(of: fragment)
                            && $0.start <= t && $0.end >= epochEnd
                    }
                    // A valid epoch: fully covered by one SUPPORTED non-unknown label
                    // interval of this fragment (native intervals are epoch-aligned
                    // merged runs, so coverage is exact; a clipped final epoch still
                    // lies inside its interval).
                    if let iv = covering, iv.labelSupported, iv.label != .unknown,
                       let from = labelIndex(iv.label) {
                        epochLabels.append(iv.label)
                        _ = from
                    } else {
                        epochLabels.append(.unknown)
                    }
                    t = epochEnd
                }
                for k in 1..<max(epochLabels.count, 1) {
                    let a = epochLabels[k - 1], b = epochLabels[k]
                    guard let from = labelIndex(a), let to = labelIndex(b) else { continue }
                    counts[from][to] += 1
                    exposure[from] += 1
                    eligiblePairs += 1
                    if a != b { stageChanges += 1 }
                }
            }

            var probabilities: [[Double]?] = []
            for row in 0..<4 {
                if exposure[row] > 0 {
                    probabilities.append((0..<4).map { Double(counts[row][$0]) / Double(exposure[row]) })
                } else {
                    probabilities.append(nil)      // no outgoing pairs → NULL row
                }
            }
            matrix = SleepAnalyticsTransitionMatrix(
                counts: counts,
                rowExposure: exposure,
                rowProbabilities: probabilities,
                epochSeconds: epochSeconds,
                eligiblePairCount: .available(eligiblePairs),
                stageChangeCount: .available(stageChanges),
                observedBoutChangeCount: nil)
        } else if !nativeOnly {
            // Coarse/external source: NO native epoch matrix (never manufactured);
            // the source's REAL-resolution bout changes are exposed separately.
            var boutChanges = 0
            for i in 1..<max(timeline.intervals.count, 1) {
                let a = timeline.intervals[i - 1], b = timeline.intervals[i]
                if a.fragmentIndex == b.fragmentIndex, a.end == b.start,
                   a.labelSupported, b.labelSupported, a.label != b.label,
                   a.label != .unknown, b.label != .unknown {
                    boutChanges += 1
                }
            }
            observedBoutChangeCount = .available(boutChanges)
            matrix = nil
        } else {
            // Native but misaligned: the epoch matrix is unsupported_source.
            matrix = nil
        }

        var streamCounts = timeline.streamCounts
        if !totalsOnlyFragments.isEmpty {
            streamCounts["totals_only_fragments"] = totalsOnlyFragments.count
        }

        let quality = SleepAnalyticsQuality(
            status: timeline.totalLabelSupportedSeconds > 0
                ? (completeStageGate ? .available : .partial) : .unavailable,
            fragmentSpanSeconds: fragmentSpan,
            groupSpanSeconds: Double(max(0, timeline.windowEnd - timeline.windowStart)),
            observedLabeledSeconds: timeline.totalLabelSupportedSeconds,
            unknownSeconds: max(0, fragmentSpan - timeline.totalLabelSupportedSeconds),
            inferredGapAwakeSeconds: timeline.inferredGapIntervals.reduce(0.0) {
                $0 + Double($1.end - $1.start)
            },
            inputSupportedSeconds: timeline.totalInputSupportedSeconds,
            inputSupportedFraction: inputFraction,
            labelSupportedFraction: labelFraction,
            sourceResolutionSeconds: timeline.fragments.first?.sourceEpochSeconds,
            streamCounts: streamCounts,
            duplicateFragmentCount: timeline.duplicateFragmentCount > 0 ? timeline.duplicateFragmentCount : nil,
            fragmentOverlapSeconds: timeline.fragmentOverlapSeconds > 0 ? timeline.fragmentOverlapSeconds : nil)

        return SleepAnalyticsStageDynamicsGroup(
            quality: quality,
            stageSeconds: stageSecondsList,
            stageBouts: stageBoutsList,
            epochTransitions: matrix)
    }
}
