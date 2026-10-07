import Foundation
import WhoopProtocol

// SleepAnalyticsContinuity.swift — the continuity group (docs/sleep-analytics/spec.md
// section 5). Root-owned implementation (two timeline-metrics workers stalled before
// writing code; the spec section and the shared contract are unchanged).
//
// OBSERVED SLEEP CONTINUITY over the normalized main-night timeline: wake after onset,
// sleep bouts, estimated awakenings and onset delays. Every stage-derived number is an
// ESTIMATE inherited from the existing stager's labels — none of this is PSG, and no
// clinical SOL, abnormality or risk is computed. Unknown time stays unknown: WASO,
// bouts and transitions are counted only over supported labels inside fragments, and
// inter-fragment gaps are retained SEPARATELY as the existing canonical inferred-awake
// contribution (spec 4.7) — never folded into observed numbers, never sensor coverage.
// Counts can be ZERO with qualifying observed exposure; missing evidence is null with a
// machine-readable reason, never a fabricated zero.

extension SleepAnalyticsV1 {

    static func continuityGroup(timeline: SleepAnalyticsTimeline,
                                input: SleepAnalyticsInput,
                                config: SleepAnalyticsConfig) -> SleepAnalyticsContinuityGroup {

        let fragmentSpan = timeline.fragmentSpanSeconds
        let supportedAsleep = timeline.supportedSeconds(of: .light)
            + timeline.supportedSeconds(of: .deep) + timeline.supportedSeconds(of: .rem)
        let supportedWake = timeline.supportedSeconds(of: .wake)

        // Totals-only fragments carry label MINUTES with no timeline (spec 4.5, review
        // P2-1): their label summaries join as PARTIAL values (the source's own totals
        // at face value) — observed asleep/wake seconds — while every bout/transition/
        // latency metric below answers `unsupported_source` (a totals-only import
        // cannot support them; the timeline-manufacturing ban is spec 4.5).
        let totalsOnlyFragments = timeline.fragments.filter { $0.totalsMinutes != nil }
        var totalsOnlyAsleep = 0.0
        var totalsOnlyWake = 0.0
        for fragment in totalsOnlyFragments {
            guard let minutes = fragment.totalsMinutes else { continue }
            totalsOnlyAsleep += (minutes.light + minutes.deep + minutes.rem) * 60
            totalsOnlyWake += minutes.wake * 60
        }
        let asleepSeconds = supportedAsleep + totalsOnlyAsleep
        let wakeSeconds = supportedWake + totalsOnlyWake

        // ── The sleep period and observed WASO ────────────────────────────────────
        // WASO is supported wake STRICTLY between the first and last observed asleep
        // bounds; initial/terminal wake, unknown time and inter-fragment gaps are all
        // excluded. A gap between fragments inside the period is the canonical
        // INFERRED-awake contribution, reported separately (spec section 5 table).
        let onset = timeline.firstSupportedAsleepStart
        let offset = timeline.lastSupportedAsleepEnd
        func wasoSeconds() -> Double {
            guard let o = onset, let f = offset else { return 0 }
            var seconds = 0.0
            for iv in timeline.intervals where iv.label == .wake && iv.labelSupported {
                let s = max(iv.start, o), e = min(iv.end, f)
                if e > s { seconds += Double(e - s) }
            }
            return seconds
        }
        func inferredGapAwakeWithinPeriod() -> Double {
            guard let o = onset, let f = offset else { return 0 }
            var seconds = 0.0
            for gap in timeline.inferredGapIntervals {
                let s = max(gap.start, o), e = min(gap.end, f)
                if e > s { seconds += Double(e - s) }
            }
            return seconds
        }

        // ── Complete-stage gate (spec section 4 engineering defaults) ─────────────
        // Complete stage summary: ≥95% label-supported coverage of fragment time and,
        // for NATIVE output only, ≥95% actual input-supported seconds. External timed
        // hypnograms can pass the label gate with sensor support explicitly unknown
        // (inputSupportedFraction nil — never 0).
        let labelFraction = fragmentSpan > 0 ? timeline.totalLabelSupportedSeconds / fragmentSpan : nil
        let nativeOnly = timeline.fragments.allSatisfy { $0.sourceKind == .nativeWhoop }
            && !timeline.fragments.isEmpty
        let inputFraction = timeline.inputSupportedFraction(for: fragmentSpan)
        let labelGate = labelFraction.map { $0 >= config.stageSummaryMinLabelSupportedFraction } ?? false
        let inputGate = !nativeOnly
            || (inputFraction.map { $0 >= config.stageSummaryMinInputSupportedFraction } ?? false)
        let completeStageGate = labelGate && inputGate
        // Label summaries are PARTIAL when any totals-only fragment contributed (the
        // source's own totals at face value) or when the complete-stage gate is down.
        let labelSummariesPartial = !totalsOnlyFragments.isEmpty || !completeStageGate
        // Bout/transition/latency metrics need a TIMELINE: a totals-only import answers
        // `unsupported_source` for all of them (review P1-3/P2-1).
        let timelineMetricsSupported = totalsOnlyFragments.isEmpty
        // Label summaries need SLEEP SECONDS (timeline or totals); the timeline-only
        // metrics below gate on the onset themselves.
        let hasSleep = asleepSeconds > 0
        let hasTimelineSleep = asleepSeconds > 0 && onset != nil

        // ── Metric-by-metric (spec section 5 table) ──────────────────────────────
        let observedAsleep: SleepAnalyticsMetric = hasSleep
            ? (labelSummariesPartial ? .partial(asleepSeconds, unit: "s")
                                    : .available(asleepSeconds, unit: "s"))
            : .unavailable(totalsOnlyFragments.isEmpty ? .noObservedSleep : .unsupportedSource)
        // (A totals-only night reports its label summaries WITHOUT an onset; the onset-
        // gated metrics below answer unsupported_source for it.)

        let observedWaso: SleepAnalyticsMetric = hasTimelineSleep
            ? (timelineMetricsSupported
                ? (completeStageGate ? .available(wasoSeconds(), unit: "s")
                                     : .partial(wasoSeconds(), unit: "s"))
                : .unavailable(.unsupportedSource))
            : .unavailable(totalsOnlyFragments.isEmpty ? .noObservedSleep : .unsupportedSource)

        let inferredGapAwake: SleepAnalyticsMetric = hasTimelineSleep
            ? (timelineMetricsSupported ? .available(inferredGapAwakeWithinPeriod(), unit: "s")
                                        : .unavailable(.unsupportedSource))
            : .unavailable(totalsOnlyFragments.isEmpty ? .noObservedSleep : .unsupportedSource)

        // The combined estimate is explicitly an ESTIMATE (name + partial status): it
        // includes the existing canonical gap assumption, and the canonical daily
        // totals are unchanged by it.
        let estimatedWaso: SleepAnalyticsMetric = hasTimelineSleep
            ? (timelineMetricsSupported
                ? .partial(wasoSeconds() + inferredGapAwakeWithinPeriod(), unit: "s")
                : .unavailable(.unsupportedSource))
            : .unavailable(totalsOnlyFragments.isEmpty ? .noObservedSleep : .unsupportedSource)

        // Onset delay from the effective detected-window start: available only when
        // the prefix is OBSERVED; otherwise the value is still reported but partial
        // (a boundary estimate — the true onset could precede the window).
        let onsetDelay: SleepAnalyticsMetric
        if !timelineMetricsSupported {
            onsetDelay = .unavailable(.unsupportedSource)
        } else if let o = onset {
            let delay = Double(o - timeline.windowStart)
            onsetDelay = timeline.onsetPrefixObserved
                ? .available(delay, unit: "s")
                : SleepAnalyticsMetric(value: delay, unit: "s", status: .partial,
                                       reason: .onsetNotObserved)
        } else {
            onsetDelay = .unavailable(timeline.fragments.isEmpty ? .noObservedSleep : .unsupportedSource)
        }

        // Marker-based SOL: Phase 1 wires NO marker (no verified semantics exist), so
        // the metric answers `missing_marker`. The verification logic is still here:
        // a future marker source must precede the supported onset, share owner/device
        // lineage and lie inside a fully observed attempted-sleep interval; a future
        // or mismatched marker is `invalid_marker`, never negative latency.
        let markerLatency: SleepAnalyticsMetric
        if let marker = input.attemptedSleepMarker {
            if let o = onset, marker.ts <= o,
               marker.sourceId == nil || marker.sourceId?.isEmpty == true {
                markerLatency = .available(Double(o - marker.ts), unit: "s")
            } else {
                markerLatency = .unavailable(.invalidMarker)
            }
        } else {
            markerLatency = .unavailable(.missingMarker)
        }

        // REM/deep latency FROM SLEEP ONSET (YASA's default REM latency starts at
        // recording start; this subtracts SOL — the deviation is documented in the
        // spec and pinned by the fixture). Null with `onset_not_observed` when the
        // prefix is unobserved or unknown time between onset and the first occurrence
        // could conceal it; `no_observed_rem`/`no_observed_deep` when none exists.
        func stageLatency(_ label: SleepAnalyticsLabel,
                          noneReason: SleepAnalyticsReason) -> SleepAnalyticsMetric {
            guard timelineMetricsSupported else { return .unavailable(.unsupportedSource) }
            guard let o = onset else { return .unavailable(.noObservedSleep) }
            guard timeline.onsetPrefixObserved else { return .unavailable(.onsetNotObserved) }
            guard let first = timeline.intervals.first(where: {
                $0.label == label && $0.labelSupported && $0.start >= o
            }) else { return .unavailable(noneReason) }
            // An unknown interval between onset and the first occurrence could hide an
            // EARLIER occurrence of the label (a gap conceals its first arrival).
            let concealed = timeline.intervals.contains {
                $0.label == .unknown && $0.start >= o && $0.end <= first.start
            }
            if concealed { return .unavailable(.onsetNotObserved) }
            return completeStageGate
                ? .available(Double(first.start - o), unit: "s")
                : .partial(Double(first.start - o), unit: "s")
        }
        let remLatency = stageLatency(.rem, noneReason: .noObservedRem)
        let deepLatency = stageLatency(.deep, noneReason: .noObservedDeep)

        // ── Sleep bouts and awakenings (label-level, not EEG arousals) ───────────
        // A sleep bout = a maximal run of CONTIGUOUS supported asleep intervals
        // inside one fragment (light/deep/REM changes allowed inside the run); wake,
        // unknown and fragment boundaries split it. Censoring: the run touches an
        // unobserved edge (its fragment's start/end, or an unknown neighbour).
        struct BoutRun { var start: Int; var end: Int; var censored: Bool; var fragmentIndex: Int }
        var bouts: [BoutRun] = []
        var current: BoutRun?
        for (i, iv) in timeline.intervals.enumerated() {
            let isAsleep = (iv.label == .light || iv.label == .deep || iv.label == .rem) && iv.labelSupported
            if isAsleep {
                let fragment = timeline.fragments[iv.fragmentIndex]
                let leftEdgeObserved = iv.start > fragment.start
                let leftNeighbourObserved = i > 0 && timeline.intervals[i - 1].fragmentIndex == iv.fragmentIndex
                    && timeline.intervals[i - 1].labelSupported && timeline.intervals[i - 1].label != .unknown
                    && timeline.intervals[i - 1].end == iv.start
                    && timeline.intervals[i - 1].label == .wake
                if var run = current, run.fragmentIndex == iv.fragmentIndex, run.end == iv.start {
                    run.end = iv.end
                    current = run
                } else {
                    if let run = current { bouts.append(run) }
                    let censored = !(leftEdgeObserved || leftNeighbourObserved)
                    current = BoutRun(start: iv.start, end: iv.end,
                                      censored: censored, fragmentIndex: iv.fragmentIndex)
                }
            } else {
                if let run = current {
                    bouts.append(run)
                    current = nil
                }
            }
        }
        if let run = current { bouts.append(run) }

        // Right-censoring: a bout whose right edge is the fragment end, or whose right
        // neighbour is not an observed wake, is censored.
        for (bi, bout) in bouts.enumerated() {
            let rightInterval = timeline.intervals.first {
                $0.fragmentIndex == bout.fragmentIndex && $0.start >= bout.end && $0.start - bout.end <= 0
            }
            let rightNeighbourObserved = rightInterval.map {
                $0.labelSupported && $0.label == .wake && $0.start == bout.end
            } ?? false
            let fragmentEnd = timeline.fragments[bout.fragmentIndex].end
            if !(rightNeighbourObserved || bout.end < fragmentEnd && rightNeighbourObserved) {
                if bout.end == fragmentEnd || !rightNeighbourObserved {
                    bouts[bi].censored = true
                }
            }
        }

        let longestBout = bouts.map { Double($0.end - $0.start) }.max()
        let longestCensored = bouts.first { Double($0.end - $0.start) == longestBout }?.censored

        let longestBoutMetric: SleepAnalyticsMetric = longestBout.map {
            completeStageGate ? .available($0, unit: "s") : .partial($0, unit: "s")
        } ?? .unavailable(timelineMetricsSupported ? .noObservedSleep : .unsupportedSource)

        // ── Awakenings: wake bouts inside the sleep period ───────────────────────
        // A COMPLETE awakening has an observed sleep→wake entry AND an observed return
        // to sleep (both neighbours supported asleep, same fragment, contiguous).
        // Edge/unknown-censored wake stretches are reported SEPARATELY and never
        // silently counted as complete awakenings.
        var awakeningCount = 0
        var censoredWakeStretches = 0
        for (i, iv) in timeline.intervals.enumerated() where iv.label == .wake && iv.labelSupported {
            guard let o = onset, let f = offset else { break }
            guard iv.start >= o, iv.end <= f, iv.end > iv.start else { continue }
            let leftAsleep = i > 0 && timeline.intervals[i - 1].fragmentIndex == iv.fragmentIndex
                && timeline.intervals[i - 1].labelSupported
                && (timeline.intervals[i - 1].label == .light
                    || timeline.intervals[i - 1].label == .deep
                    || timeline.intervals[i - 1].label == .rem)
                && timeline.intervals[i - 1].end == iv.start
            let rightAsleep = i + 1 < timeline.intervals.count
                && timeline.intervals[i + 1].fragmentIndex == iv.fragmentIndex
                && timeline.intervals[i + 1].labelSupported
                && (timeline.intervals[i + 1].label == .light
                    || timeline.intervals[i + 1].label == .deep
                    || timeline.intervals[i + 1].label == .rem)
                && timeline.intervals[i + 1].start == iv.end
            if leftAsleep && rightAsleep {
                awakeningCount += 1
            } else {
                censoredWakeStretches += 1
            }
        }

        // ── Sleep→wake transitions (incl. terminal observed wake) ────────────────
        var sleepToWakeTransitions = 0
        for i in 1..<max(timeline.intervals.count, 1) {
            let a = timeline.intervals[i - 1], b = timeline.intervals[i]
            guard a.fragmentIndex == b.fragmentIndex, a.end == b.start,
                  a.labelSupported, b.labelSupported else { continue }
            let aAsleep = a.label == .light || a.label == .deep || a.label == .rem
            if aAsleep && b.label == .wake { sleepToWakeTransitions += 1 }
        }

        // Primary per-asleep-hour rate: needs the complete-stage gate AND ≥30 min
        // observed asleep; the COUNT always exists below the gate (spec: counts still
        // exist for short fixtures/naps).
        let asleepHours = supportedAsleep / 3600.0
        let rate: SleepAnalyticsMetric
        if hasSleep, asleepHours > 0 {
            let value = Double(sleepToWakeTransitions) / asleepHours
            if completeStageGate && supportedAsleep >= Double(config.primaryRateMinObservedSeconds) {
                rate = .available(value, unit: "per_h")
            } else {
                rate = SleepAnalyticsMetric(value: value, unit: "per_h", status: .partial,
                                            reason: .insufficientCoverage)
            }
        } else {
            rate = .unavailable(hasSleep ? .zeroDenominator : .noObservedSleep, unit: "per_h")
        }

        let quality = SleepAnalyticsQuality(
            status: asleepSeconds > 0 ? (labelSummariesPartial ? .partial : .available) : .unavailable,
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
            streamCounts: timeline.streamCounts,
            duplicateFragmentCount: timeline.duplicateFragmentCount > 0 ? timeline.duplicateFragmentCount : nil,
            fragmentOverlapSeconds: timeline.fragmentOverlapSeconds > 0 ? timeline.fragmentOverlapSeconds : nil)

        func timelineCount(_ value: Int) -> SleepAnalyticsCount {
            timelineMetricsSupported ? .available(value) : .unavailable(.unsupportedSource)
        }
        return SleepAnalyticsContinuityGroup(
            quality: quality,
            observedAsleepSeconds: observedAsleep,
            observedWasoSeconds: observedWaso,
            inferredGapAwakeSecondsWithinSleepPeriod: inferredGapAwake,
            estimatedWasoIncludingInferredGapsSeconds: estimatedWaso,
            onsetDelayFromWindowSeconds: onsetDelay,
            sleepOnsetLatencyFromMarkerSeconds: markerLatency,
            remLatencyFromSleepOnsetSeconds: remLatency,
            deepLatencyFromSleepOnsetSeconds: deepLatency,
            longestObservedSleepBoutSeconds: longestBoutMetric,
            longestBoutCensored: longestCensored,
            awakeningBoutCount: timelineCount(awakeningCount),
            censoredWakeStretchCount: timelineCount(censoredWakeStretches),
            sleepToWakeTransitionCount: timelineCount(sleepToWakeTransitions),
            sleepToWakeTransitionsPerAsleepHour: timelineMetricsSupported
                ? rate : .unavailable(.unsupportedSource, unit: "per_h"))
    }
}

extension SleepAnalyticsTimeline {
    /// Input-supported fraction of the fragment span, nil when the span is zero OR
    /// when no fragment carries actual sensor evidence (external sources keep sensor
    /// support explicitly unknown — never a fake 0).
    func inputSupportedFraction(for span: Double) -> Double? {
        guard span > 0 else { return nil }
        let hasSensorEvidence = fragments.contains { $0.sourceKind == .nativeWhoop }
        guard hasSensorEvidence else { return nil }
        return totalInputSupportedSeconds / span
    }
}
