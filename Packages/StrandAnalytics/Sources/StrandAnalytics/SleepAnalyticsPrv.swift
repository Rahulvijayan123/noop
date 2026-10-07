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
            return SleepAnalyticsPrvDiagnosticsGroup(
                quality: quality,
                nightlySd1Ms: .disabled(), nightlySd2Ms: .disabled(), nightlyRatio: .disabled(unit: ""),
                eligibleWindowCount: .disabled(), withheldWindowCount: .disabled(),
                rejectionFraction: .disabled(unit: ""), validPairs: .disabled(),
                timingMethod: "disabled", source: "prv_optical", windows: [])
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

        // ── UTC-aligned 5-minute windows inside single fragments ────────────────
        let windowSeconds = config.prvWindowSeconds
        var windows: [SleepAnalyticsPrvWindow] = []
        var withheld = 0
        var withheldByDuration = 0      // review P2-5: clipped tails are withheld AS duration
        var totalValidPairs = 0
        var totalRejected = 0
        var totalOriginalObservations = 0

        for fragment in timeline.fragments {
            // UTC-aligned window starts inside [fragment.start, fragment.end - window).
            var w = fragment.start - fragment.start % windowSeconds + (fragment.start % windowSeconds == 0 ? 0 : windowSeconds)
            // A clipped TAIL window (the fragment ends before a full window fits) is
            // withheld as insufficient_duration (review P2-5), never silently skipped.
            var clippedTailCounted = false
            if w < fragment.end, w + windowSeconds > fragment.end, w >= fragment.start {
                withheld += 1
                withheldByDuration += 1
                clippedTailCounted = true
            }
            // A fragment TOO SHORT for any window at all (its whole span is under one
            // window, so neither a full nor a clipped window fits — e.g. a mid-window
            // start with the end exactly at the next window start) is ALSO withheld
            // as insufficient_duration, not silently skipped (review P2-5 residual).
            if !clippedTailCounted, fragment.end - fragment.start < windowSeconds {
                withheld += 1
                withheldByDuration += 1
            }
            while w + windowSeconds <= fragment.end {
                let wEnd = w + windowSeconds
                // Window pairs: TRUE pairs whose two beats lie inside the window.
                var u: [Double] = []
                var v: [Double] = []
                for i in truePairPositions {
                    let posA = survivorPositions[i - 1], posB = survivorPositions[i]
                    let a = ordered[posA], b = ordered[posB]
                    guard a.ts >= w, a.ts < wEnd, b.ts >= w, b.ts < wEnd else { continue }
                    let aa = cleanValues[i - 1], bb = cleanValues[i]
                    u.append((bb - aa) / 2.0.squareRoot())
                    v.append((aa + bb) / 2.0.squareRoot())
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
                    windows.append(SleepAnalyticsPrvWindow(start: w, sd1Ms: sd1, sd2Ms: sd2,
                                                          pairs: u.count, coverage: coverage))
                    totalValidPairs += u.count
                    totalRejected += rejectedInWindow
                    totalOriginalObservations += originalInWindow
                } else {
                    withheld += 1
                }
                w += windowSeconds
            }
        }

        // ── Nightly summaries: MEDIANS of eligible windows (never concatenated) ─
        let sd1Values = windows.map(\.sd1Ms)
        let sd2Values = windows.map(\.sd2Ms)
        let sd1Metric: SleepAnalyticsMetric
        let sd2Metric: SleepAnalyticsMetric
        let ratioMetric: SleepAnalyticsMetric
        if windows.isEmpty {
            let reason: SleepAnalyticsReason = timeline.fragments.isEmpty ? .noSamples
                : (unresolved > 0 ? .unresolvedAdjacency
                    : (withheldByDuration > 0 && withheld == withheldByDuration
                        ? .insufficientDuration     // only clipped tails: the night is too short
                        : .insufficientCoverage))
            sd1Metric = .unavailable(reason, unit: "ms")
            sd2Metric = .unavailable(reason, unit: "ms")
            ratioMetric = .unavailable(reason, unit: "")
        } else {
            let sd1 = median(sd1Values), sd2 = median(sd2Values)
            sd1Metric = .available(sd1, unit: "ms")
            sd2Metric = .available(sd2, unit: "ms")
            ratioMetric = sd2 > 0
                ? .available(sd1 / sd2, unit: "")
                : .unavailable(.zeroDenominator, unit: "")
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

        return SleepAnalyticsPrvDiagnosticsGroup(
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
