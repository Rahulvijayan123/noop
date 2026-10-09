import Foundation
import WhoopProtocol

// SleepAnalyticsPrv.swift — the PRV diagnostics group (docs/sleep-analytics/spec.md
// section 7). Root-owned implementation of the W2 signal-helpers area.
//
// PULSE-RATE VARIABILITY from an OPTICAL interval source: labelled PRV, never
// implied ECG-equivalent HRV, and never estimated from 1 Hz BPM. SD1 is closely
// related to RMSSD and usually redundant (NeuroKit documents this), so the whole
// group stays a DIAGNOSTIC: no dashboard tile, no "autonomic balance" score, and
// SD2 is never called sympathetic tone. SampEn / DFA / multiscale entropy / HR
// fragmentation stay deferred. The CANONICAL nightly RMSSD path is untouched:
// this group only CALLS `HRVAnalyzer`'s public cleaning; nothing in it is modified.
//
// Method (spec section 7):
//   * Beats are deduplicated by OBSERVATION IDENTITY (bucket|rr|seq|ord|channel —
//     the same rule the worker's candidate lane uses), never by RR value: equal
//     legitimate intervals are retained; a byte-identical retransmission collapses.
//   * Timing resolution: beats are ordered by (ts, seq, ord). Whole-second
//     ambiguity (two beats with no ord chain in one second) is UNRESOLVED and the
//     affected pairs are excluded; the method string reports what actually held.
//   * Wall-clock/source changes break adjacency: two beats are adjacent only when
//     the elapsed time between their timestamps is consistent with the first
//     interval duration (within a 250 ms tolerance), or they chain inside the same
//     second through seq/ord. Gaps are never concatenated; removed beats never
//     form new pairs; nothing is sorted by RR value.
//   * Cleaning reuses `HRVAnalyzer.cleanRRGapAware` (range filter + Malik ectopic
//     rejection, gap-aware `contiguous` flags): a pair is TRUE only when the two
//     cleaned beats were adjacent in the original series (no beat removed between).
//   * SD1/SD2 are computed in the DIRECT pair space over the (u, v) axes of every
//     TRUE adjacent cleaned pair, sample stdev (ddof=1), per UTC-aligned 5-minute
//     window entirely inside one fragment; the nightly values are the MEDIANS of
//     the eligible windows' SD1/SD2 (windows preserved, never concatenated); the
//     nightly ratio is the ratio of those two summaries (null when SD2 is zero).
//   * pNN50 (spec-02 §1, docs/spec-02/CONTRACT.md §4.1) uses EXACTLY the SD1/SD2 pair
//     set: `HRVAnalyzer.pnn50GapAware` over the cleaned series with the true-pair mask
//     (cleaner-contiguous AND original ts/seq/ord/source adjacency), per eligible window;
//     the nightly value is the POOLED proportion 100·ΣNN50/Σpairs with its numerator and
//     denominator (never a mean of window percentages, never from minute HR). Optical
//     intervals: a PRV statistic, not ECG pNN50. No eligible window → null with SD1's reason.

extension SleepAnalyticsV1 {

    static func prvGroup(timeline: SleepAnalyticsTimeline,
                         input: SleepAnalyticsInput,
                         config: SleepAnalyticsConfig) -> SleepAnalyticsPrvDiagnosticsGroup {

        // Config-off: the whole group is disabled (spec section 7 — the v1 config
        // ships it enabled, but a disabled config must say so, never fake numbers).
        guard config.prvDiagnosticsEnabled else {
            
        let quality = SleepAnalyticsQuality(
                status: .disabled, fragmentSpanSeconds: timeline.fragmentSpanSeconds,
                groupSpanSeconds: Double(max(0, timeline.windowEnd - timeline.windowStart)),
                observedLabeledSeconds: 0, unknownSeconds: timeline.fragmentSpanSeconds,
                inferredGapAwakeSeconds: timeline.inferredGapIntervals.reduce(0.0) { $0 + Double($1.end - $1.start) },
                inputSupportedSeconds: 0, inputSupportedFraction: nil, labelSupportedFraction: nil,
                sourceResolutionSeconds: nil,
                streamCounts: timeline.streamCounts)
            var disabled = SleepAnalyticsPrvDiagnosticsGroup(
                quality: quality,
                nightlySd1Ms: .disabled(), nightlySd2Ms: .disabled(), nightlyRatio: .disabled(unit: ""),
                eligibleWindowCount: .disabled(), withheldWindowCount: .disabled(),
                rejectionFraction: .disabled(unit: ""), validPairs: .disabled(),
                timingMethod: "disabled", source: "prv_optical", windows: [])
            disabled.nightlyPnn50Pct = .disabled(unit: "%")
            disabled.pnn50PairCount = .disabled()
            disabled.nn50Count = .disabled()
            disabled.pnn50Method = SleepAnalyticsPrv.pnn50Method
            return disabled
        }

        // ── Observation-identity dedup (never by RR value) ──────────────────────
        let deduped = SleepAnalyticsPrv.dedupByObservationIdentity(input.beats)

        // Keep only beats inside fragments (fragment membership is eligibility).
        let inFragments = deduped.filter { beat in
            timeline.fragments.contains { $0.start <= beat.ts && beat.ts < $0.end }
        }

        // ── Ordering: (ts, seq, ord) ────────────────────────────────────────────
        let ordered = inFragments.sorted { a, b in
            if a.ts != b.ts { return a.ts < b.ts }
            if a.seq != b.seq { return a.seq < b.seq }
            return (a.ord ?? Int.min) < (b.ord ?? Int.min)
        }

        // Timing resolution evidence: within one whole second, beats with distinct
        // seq (or a monotonic ord chain) resolve; two beats with the SAME identity
        // fields unresolved (no ord, no distinct seq) leave the ordering ambiguous.
        var ambiguousPairs = 0
        for k in 1..<max(ordered.count, 1) where ordered[k].ts == ordered[k - 1].ts {
            let a = ordered[k - 1], b = ordered[k]
            let resolved = a.seq != b.seq
                || (a.ord != nil && b.ord != nil && a.ord! != b.ord!)
            if !resolved { ambiguousPairs += 1 }
        }
        let timingMethod = ambiguousPairs == 0
            ? "ts_seq_ord_chain"
            : "ts_seq_ord_chain_ambiguous:\(ambiguousPairs)"

        // ── Adjacency in the ORIGINAL (deduped, ordered) series ────────────────
        // Two consecutive ordered beats (a, b) are a TRUE original adjacency when:
        //   * they share a second and chain through distinct seq/ord (sub-second
        //     train order), or
        //   * the wall clock between them matches a's interval duration within a
        //     250 ms tolerance (a coarse-bank timing veto in the same spirit as the
        //     canonical over-count gate: two timestamps one second apart carrying
        //     two ~1 s intervals are two observations, not one adjacency).
        // A wall-clock gap or a source/channel change between them breaks adjacency.
        struct OriginalPair {
            let a: RRInterval
            let b: RRInterval
            let indexA: Int      // index into `ordered`
        }
        var originalPairs: [OriginalPair] = []
        originalPairs.reserveCapacity(ordered.count)
        var unresolved = 0
        func fragmentsIndex(of ts: Int) -> Int? {
            timeline.fragments.firstIndex { $0.start <= ts && ts < $0.end }
        }
        for k in 1..<max(ordered.count, 1) {
            let a = ordered[k - 1], b = ordered[k]
            // Adjacency never crosses a fragment boundary even when timestamps touch
            // (review P3-3: a cross-fragment pair would only inflate the
            // rr_original_pairs diagnostic, but it is not an adjacency at all).
            guard let fragmentA = fragmentsIndex(of: a.ts), fragmentsIndex(of: b.ts) == fragmentA else {
                unresolved += 1
                continue
            }
            if a.ts == b.ts {
                // Same-second chaining needs a DISTINCT seq or ord (review P3-4): two
                // beats with equal ords in one second leave the order ambiguous.
                let chainOK = a.seq != b.seq
                    || (a.ord != nil && b.ord != nil && a.ord! != b.ord!)
                if chainOK { originalPairs.append(OriginalPair(a: a, b: b, indexA: k - 1)) }
                else { unresolved += 1 }
                continue
            }
            if a.srcChannel != b.srcChannel { unresolved += 1; continue }   // source change
            let elapsedMs = Double(b.ts - a.ts) * 1000.0
            let toleranceMs = 250.0
            let durationMs = Double(a.rrMs)
            if abs(elapsedMs - durationMs) <= max(toleranceMs, durationMs * 0.25) {
                originalPairs.append(OriginalPair(a: a, b: b, indexA: k - 1))
            } else {
                unresolved += 1      // wall-clock gap: never concatenated
            }
        }

        // ── Cleaning (the canonical gap-aware path, called not modified) ───────
        // `cleanRRGapAware` keeps each survivor's original index in `contiguous`,
        // so a cleaned pair is TRUE only when no beat was removed between its two
        // beats (spec: a removed ectopic beat must not form a new adjacent pair).
        let series = ordered.map { Double($0.rrMs) }
        let cleaned = HRVAnalyzer.cleanRRGapAware(series)
        let cleanValues = cleaned.nn
        let contiguous = cleaned.contiguous

        // The cleaner's OWN survivor identity (review P1-1): `keptOriginalIndices`
        // carries each survivor's position in `ordered`, so the pairing can never
        // drift from the canonical cleaning (the previous re-derivation mirrored
        // Malik with a different median and could silently flip borderline beats).
        let survivorPositions = cleaned.keptOriginalIndices

        // A cleaned pair (i-1, i) is TRUE when contiguous[i] (original adjacency
        // of the survivors) AND the survivors' original adjacency was a TRUE
        // original pair above (wall-clock/source consistent).
        var truePairPositions: [Int] = []
        truePairPositions.reserveCapacity(cleanValues.count)
        var originalAdjacencyByPos: [Int: Bool] = [:]   // ordered-position → is a true original adjacency start
        for pair in originalPairs { originalAdjacencyByPos[pair.indexA] = true }
        for i in 1..<max(cleanValues.count, 1) where contiguous[i] {
            let posA = survivorPositions[i - 1], posB = survivorPositions[i]
            if originalAdjacencyByPos[posA] == true && posB == posA + 1 {
                truePairPositions.append(i)
            }
        }

        // The contiguity mask over the cleaned series: true at i exactly when (i-1, i) is a TRUE
        // pair above (cleaner-contiguous AND an original timestamp/seq/ord/source adjacency) — the
        // mask `HRVAnalyzer.pnn50GapAware` is called with (spec-02 §1: never the cleaner's mask alone).
        var isTruePair = [Bool](repeating: false, count: cleanValues.count)
        for i in truePairPositions { isTruePair[i] = true }

        // ── UTC-aligned 5-minute windows inside single fragments ────────────────
        let windowSeconds = config.prvWindowSeconds
        var windows: [SleepAnalyticsPrvWindow] = []
        var withheld = 0
        var withheldByDuration = 0      // review P2-5: clipped tails are withheld AS duration
        var totalValidPairs = 0
        var totalNn50 = 0                 // pNN50 numerator, pooled over eligible windows
        var totalPnn50Pairs = 0           // pNN50 denominator (the same pairs as SD1/SD2)
        var totalRejected = 0
        var totalOriginalObservations = 0

        for fragment in timeline.fragments {
            // UTC-aligned window starts inside [fragment.start, fragment.end - window).
            var w = fragment.start - fragment.start % windowSeconds + (fragment.start % windowSeconds == 0 ? 0 : windowSeconds)
            // Full windows first; the clipped TAIL (the first candidate window whose
            // full span exceeds the fragment end while still containing fragment time)
            // is counted AFTER the loop — so a tail after any number of full windows is
            // withheld as insufficient_duration too (review P2-5 + R2), never silently
            // skipped and never double-counted.
            while w + windowSeconds <= fragment.end {
                let wEnd = w + windowSeconds
                // Window pairs: TRUE pairs whose two beats lie inside the window.
                var u: [Double] = []
                var v: [Double] = []
                var windowPairIndices: [Int] = []      // cleaned index i of each pair (i-1, i)
                for i in truePairPositions {
                    let posA = survivorPositions[i - 1], posB = survivorPositions[i]
                    let a = ordered[posA], b = ordered[posB]
                    guard a.ts >= w, a.ts < wEnd, b.ts >= w, b.ts < wEnd else { continue }
                    let aa = cleanValues[i - 1], bb = cleanValues[i]
                    u.append((bb - aa) / 2.0.squareRoot())
                    v.append((aa + bb) / 2.0.squareRoot())
                    windowPairIndices.append(i)
                }
                // Rejection fraction over ORIGINAL deduplicated observations in
                // the window (before cleaning), the spec's denominator. Rejected =
                // range/ectopic-filtered beats ONLY: an edge beat with no partner
                // pair is unpaired, not rejected (a naive pairs-minus-count would
                // misreport every window edge as a rejection).
                let originalInWindow = ordered.filter { $0.ts >= w && $0.ts < wEnd }.count
                let survivorsInWindow = survivorPositions.filter {
                    ordered[$0].ts >= w && ordered[$0].ts < wEnd
                }.count
                let rejectedInWindow = originalInWindow - survivorsInWindow
                // Coverage: the union of TRUSTWORTHY original beat-duration spans —
                // the CLEANED SURVIVORS only (review P3-2: a rejected beat's span is
                // not trustworthy coverage), clipped to the window ÷ window duration.
                let survivors = survivorPositions.map { ordered[$0] }
                let coverage = SleepAnalyticsPrv.windowCoverage(ordered: survivors,
                                                                 wStart: w, wEnd: wEnd)
                let gatesPass = u.count >= config.prvMinValidPairs
                    && coverage >= config.prvMinCoverageFraction
                    && Double(rejectedInWindow) / Double(max(originalInWindow, 1)) <= config.prvMaxRejectedFraction
                if gatesPass, let sd1 = stdev(u), let sd2 = stdev(v) {
                    // pNN50 over EXACTLY this window's SD1/SD2 pair set (spec-02 §1, CONTRACT §4.1).
                    let pnn50 = SleepAnalyticsPrv.windowPnn50(cleanValues: cleanValues,
                                                              truePair: isTruePair,
                                                              pairIndices: windowPairIndices)
                    windows.append(SleepAnalyticsPrvWindow(start: w, sd1Ms: sd1, sd2Ms: sd2,
                                                          pairs: u.count, coverage: coverage,
                                                          pnn50Pct: pnn50?.pct, nn50Count: pnn50?.nn50))
                    totalNn50 += pnn50?.nn50 ?? 0
                    totalPnn50Pairs += pnn50?.pairs ?? 0
                    totalValidPairs += u.count
                    totalRejected += rejectedInWindow
                    totalOriginalObservations += originalInWindow
                } else {
                    withheld += 1
                }
                w += windowSeconds
            }
            // Post-loop: w is now the first candidate whose full window exceeds the
            // fragment end. If it still contains fragment time it is a clipped TAIL —
            // withheld as insufficient_duration (P2-5/R2); a fragment too short for any
            // window at all (neither a full nor a clipped candidate contains fragment
            // time — e.g. a mid-window start ending exactly at the next window start)
            // is withheld the same way (P2-5 residual).
            if w < fragment.end || fragment.end - fragment.start < windowSeconds {
                withheld += 1
                withheldByDuration += 1
            }
        }

        // ── Nightly summaries: MEDIANS of eligible windows (never concatenated) ─
        let sd1Values = windows.map(\.sd1Ms)
        let sd2Values = windows.map(\.sd2Ms)
        let sd1Metric: SleepAnalyticsMetric
        let sd2Metric: SleepAnalyticsMetric
        let ratioMetric: SleepAnalyticsMetric
        let pnn50Metric: SleepAnalyticsMetric
        let pnn50Pairs: SleepAnalyticsCount
        let nn50: SleepAnalyticsCount
        if windows.isEmpty {
            let reason: SleepAnalyticsReason = timeline.fragments.isEmpty ? .noSamples
                : (unresolved > 0 ? .unresolvedAdjacency
                    : (withheldByDuration > 0 && withheld == withheldByDuration
                        ? .insufficientDuration     // only clipped tails: the night is too short
                        : .insufficientCoverage))
            sd1Metric = .unavailable(reason, unit: "ms")
            sd2Metric = .unavailable(reason, unit: "ms")
            ratioMetric = .unavailable(reason, unit: "")
            // No eligible window → null with the SAME reason SD1 carries (CONTRACT §4.1).
            pnn50Metric = .unavailable(reason, unit: "%")
            pnn50Pairs = .unavailable(reason)
            nn50 = .unavailable(reason)
        } else {
            let sd1 = median(sd1Values), sd2 = median(sd2Values)
            sd1Metric = .available(sd1, unit: "ms")
            sd2Metric = .available(sd2, unit: "ms")
            ratioMetric = sd2 > 0
                ? .available(sd1 / sd2, unit: "")
                : .unavailable(.zeroDenominator, unit: "")
            // Pooled proportion 100·ΣNN50/Σpairs over the eligible windows — never a mean of window
            // percentages. Every eligible window has ≥ prvMinValidPairs pairs, so Σpairs > 0.
            pnn50Metric = totalPnn50Pairs > 0
                ? .available(100.0 * Double(totalNn50) / Double(totalPnn50Pairs), unit: "%")
                : .unavailable(.zeroDenominator, unit: "%")
            pnn50Pairs = .available(totalPnn50Pairs)
            nn50 = .available(totalNn50)
        }

        let rejectionFraction: SleepAnalyticsMetric
        if totalOriginalObservations > 0 {
            rejectionFraction = .available(Double(totalRejected) / Double(totalOriginalObservations), unit: "")
        } else {
            rejectionFraction = .unavailable(.noSamples, unit: "")
        }

        let mergedStreamCounts = timeline.streamCounts.merging([
                "rr_received_deduped": input.beats.count,
                "rr_deduped": deduped.count,
                "rr_in_fragments": inFragments.count,
                "rr_original_pairs": originalPairs.count,
                "rr_unresolved_adjacencies": unresolved,
                "rr_cleaned_survivors": cleanValues.count,
                "rr_true_cleaned_pairs": truePairPositions.count,
            ]) { _, new in new }
        let quality = SleepAnalyticsQuality(
            status: windows.isEmpty ? .unavailable : .available,
            fragmentSpanSeconds: timeline.fragmentSpanSeconds,
            groupSpanSeconds: Double(max(0, timeline.windowEnd - timeline.windowStart)),
            observedLabeledSeconds: timeline.totalLabelSupportedSeconds,
            unknownSeconds: max(0, timeline.fragmentSpanSeconds - timeline.totalLabelSupportedSeconds),
            inferredGapAwakeSeconds: timeline.inferredGapIntervals.reduce(0.0) { $0 + Double($1.end - $1.start) },
            inputSupportedSeconds: timeline.totalInputSupportedSeconds,
            inputSupportedFraction: timeline.fragmentSpanSeconds > 0
                ? timeline.totalInputSupportedSeconds / timeline.fragmentSpanSeconds : nil,
            labelSupportedFraction: timeline.fragmentSpanSeconds > 0
                ? timeline.totalLabelSupportedSeconds / timeline.fragmentSpanSeconds : nil,
            sourceResolutionSeconds: nil,
            streamCounts: mergedStreamCounts,
            duplicateFragmentCount: timeline.duplicateFragmentCount > 0 ? timeline.duplicateFragmentCount : nil,
            fragmentOverlapSeconds: timeline.fragmentOverlapSeconds > 0 ? timeline.fragmentOverlapSeconds : nil)

        var group = SleepAnalyticsPrvDiagnosticsGroup(
            quality: quality,
            nightlySd1Ms: sd1Metric,
            nightlySd2Ms: sd2Metric,
            nightlyRatio: ratioMetric,
            eligibleWindowCount: .available(windows.count),
            withheldWindowCount: .available(withheld),
            rejectionFraction: rejectionFraction,
            validPairs: totalValidPairs > 0 ? .available(totalValidPairs) : .unavailable(.noSamples),
            timingMethod: timingMethod,
            source: "prv_optical",
            windows: windows)
        group.nightlyPnn50Pct = pnn50Metric
        group.pnn50PairCount = pnn50Pairs
        group.nn50Count = nn50
        group.pnn50Method = SleepAnalyticsPrv.pnn50Method
        return group
    }

    /// Sample standard deviation (ddof=1), nil below two samples. Identical values
    /// return EXACTLY zero: a naive mean-of-sum on N equal values can leave a
    /// rounding residue that flips a zero-SD2 ratio into a fake 0.0 (pinned by the
    /// constant-intervals test).
    static func stdev(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        if let first = values.first, values.allSatisfy({ $0 == first }) { return 0 }
        let n = Double(values.count)
        let mean = values.reduce(0.0, +) / n
        let ss = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return (ss / (n - 1)).squareRoot()
    }
}

/// The PRV-specific helpers (observation-identity dedup, Malik keep-flags mirror,
/// window coverage) kept in their own namespace for testability.
enum SleepAnalyticsPrv {

    /// How pNN50 is computed (CONTRACT §4.1): `HRVAnalyzer.pnn50GapAware` over the cleaned series with
    /// the ORIGINAL-adjacency mask, per eligible window, pooled 100·ΣNN50/Σpairs.
    static let pnn50Method = "pnn50GapAware_original_adjacency_v1"

    /// pNN50 of one eligible window: `HRVAnalyzer.pnn50GapAware` (the canonical gap-aware statistic,
    /// fixed 50 ms threshold) called on the contiguous cleaned slice that holds the window's pairs, with
    /// the true-pair mask — so exactly the window's SD1/SD2 pair set is counted. `pairIndices` are the
    /// cleaned indices i of the window's pairs (i-1, i), ascending. Returns the percentage plus its
    /// numerator and denominator; nil without a pair.
    static func windowPnn50(cleanValues: [Double], truePair: [Bool],
                            pairIndices: [Int]) -> (pct: Double, nn50: Int, pairs: Int)? {
        guard let first = pairIndices.first, let last = pairIndices.last else { return nil }
        // The slice [first-1, last]: every cleaned beat inside it lies in the window (the series is
        // time-ordered and both ends are window beats). Index 0 of the slice never forms a pair.
        let lo = first - 1
        let nn = Array(cleanValues[lo...last])
        var mask = Array(truePair[lo...last])
        mask[0] = false
        guard let pct = HRVAnalyzer.pnn50GapAware(nn, mask) else { return nil }
        let pairs = mask.reduce(0) { $0 + ($1 ? 1 : 0) }
        // pct = nn50/pairs·100 exactly up to rounding; recover the integer numerator.
        let nn50 = Int((pct * Double(pairs) / 100.0).rounded())
        return (pct, nn50, pairs)
    }

    /// Observation identity (bucket|rr|seq|ord|channel): the same rule the
    /// worker's candidate lane uses. Equal legitimate RR values survive as two
    /// rows; a byte-identical retransmission collapses to one (first wins).
    static func dedupByObservationIdentity(_ beats: [RRInterval]) -> [RRInterval] {
        // ONE-SECOND observation buckets (the worker's `observationBucketSeconds`):
        // identity is (second, rr, seq, ord, channel). Equal legitimate RR values in
        // DIFFERENT seconds survive; a byte-identical retransmission in the same second
        // collapses; the two beats of a sub-second train stay distinct through seq/ord.
        var seen = Set<String>()
        var out: [RRInterval] = []
        out.reserveCapacity(beats.count)
        for beat in beats {
            let bucket = beat.ts / 1          // the observation bucket is one second
            let key = "\(bucket)|\(beat.rrMs)|\(beat.seq)|\(beat.ord.map(String.init) ?? "-")|"
                + "\(beat.srcChannel.map { String($0.rawValue) } ?? "-")"
            if seen.insert(key).inserted { out.append(beat) }
        }
        return out
    }

/// Supported interval-duration coverage of a window: the union of the
    /// original (deduped) beats' own duration spans `[ts, ts + rr/1000)`,
    /// clipped to the window, ÷ window duration. Summed RR values can overcount
    /// overlapping durations, so the union is computed over second-clipped
    /// spans (spec: compute coverage from the union, not summed RR values).
    static func windowCoverage(ordered: [RRInterval], wStart: Int, wEnd: Int) -> Double {
        let duration = Double(wEnd - wStart)
        guard duration > 0 else { return 0 }
        var coveredSeconds = Set<Int>()
        for beat in ordered where beat.ts >= wStart && beat.ts < wEnd {
            let spanEnd = min(wEnd, beat.ts + Int((Double(beat.rrMs) / 1000.0).rounded(.up)))
            for s in beat.ts..<max(beat.ts + 1, spanEnd) where s >= wStart && s < wEnd {
                coveredSeconds.insert(s)
            }
        }
        return Double(coveredSeconds.count) / duration
    }
}
