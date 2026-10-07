import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// SleepAnalyticsTimelineGroupTests — the continuity and stage-dynamics groups
// (docs/sleep-analytics/spec.md sections 5 + the section 12 rows the base review
// flagged as REQUIRED here). The hand-calculated reference fixture is asserted
// METRIC BY METRIC: observed sleep 270 s, wake 90 s, first asleep 30 s, last
// asleep end 330 s, observed WASO 30 s, longest observed sleep bout 210 s, onset
// delay 30 s (available), REM latency 150 s, deep latency 60 s, one complete
// internal awakening, two sleep→wake changes incl terminal, 7 stage changes
// among 11 eligible pairs, the nonzero epoch counts, and the per-asleep-hour
// rate withheld by the 30-minute floor.

final class SleepAnalyticsTimelineGroupTests: XCTestCase {

    private let t0 = 1_789_000_000

    /// The spec section 12 hand fixture, fully supported (1 Hz HR across the night).
    private func handFixture(start: Int) -> (input: SleepAnalyticsInput,
                                            timeline: SleepAnalyticsTimeline) {
        let labels = ["wake", "light", "light", "deep", "deep", "light",
                     "rem", "rem", "wake", "light", "light", "wake"]
        let stages = labels.enumerated().map { i, l in
            StageSegment(start: start + i * 30, end: start + (i + 1) * 30, stage: l)
        }
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: start + 360,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: stages)],
            timezoneId: "Etc/UTC",
            hr: (start..<start + 360).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "sleep-stager-v2-test", inputRevision: 1)
        return (input, SleepAnalyticsV1.normalize(input: input, config: .v1))
    }

    private func continuity(start: Int = 1_789_000_000) -> SleepAnalyticsContinuityGroup {
        let f = handFixture(start: start)
        return SleepAnalyticsV1.continuityGroup(timeline: f.timeline, input: f.input, config: .v1)
    }

    private func dynamics(start: Int = 1_789_000_000) -> SleepAnalyticsStageDynamicsGroup {
        let f = handFixture(start: start)
        return SleepAnalyticsV1.stageDynamicsGroup(timeline: f.timeline, input: f.input, config: .v1)
    }

    // MARK: - The hand-calculated reference fixture (spec section 12)

    func testHandFixtureContinuityMetricsExactly() {
        let c = continuity()
        XCTAssertEqual(c.observedAsleepSeconds.value, 270)          // light+deep+rem
        XCTAssertEqual(c.observedWasoSeconds.value, 30)             // the wake inside the period
        XCTAssertEqual(c.inferredGapAwakeSecondsWithinSleepPeriod.value, 0)
        XCTAssertEqual(c.estimatedWasoIncludingInferredGapsSeconds.value, 30)
        XCTAssertEqual(c.onsetDelayFromWindowSeconds.value, 30)
        XCTAssertEqual(c.onsetDelayFromWindowSeconds.status, .available)
        XCTAssertEqual(c.remLatencyFromSleepOnsetSeconds.value, 150)   // first REM at 180
        XCTAssertEqual(c.deepLatencyFromSleepOnsetSeconds.value, 60)
        XCTAssertEqual(c.longestObservedSleepBoutSeconds.value, 210)  // 30..240 (light/deep/light)
        XCTAssertEqual(c.longestBoutCensored, false)
        XCTAssertEqual(c.awakeningBoutCount.value, 1)                  // the 240..270 wake
        XCTAssertEqual(c.censoredWakeStretchCount.value, 0)
        XCTAssertEqual(c.sleepToWakeTransitionCount.value, 2)         // incl. terminal wake
        // 270 s < the 1800 s floor → the primary rate is withheld as partial.
        XCTAssertEqual(c.sleepToWakeTransitionsPerAsleepHour.status, .partial)
        XCTAssertEqual(c.sleepToWakeTransitionsPerAsleepHour.reason, .insufficientCoverage)
        XCTAssertEqual(c.sleepToWakeTransitionsPerAsleepHour.value!, 2.0 / (270.0 / 3600.0),
                       accuracy: 1e-9)
        // Quality: 100% label support and input support → the complete-stage gate passes
        // (all "available" statuses above) even though the rate floor withholds the rate.
        XCTAssertEqual(c.quality.labelSupportedFraction!, 1.0, accuracy: 1e-12)
    }

    func testHandFixtureEpochTransitionMatrixExactly() {
        let d = dynamics()
        let m = d.epochTransitions
        XCTAssertNotNil(m)
        // Row/col order [wake, light, deep, rem].
        // W→L=2, L→L=2, L→D=1, D→D=1, D→L=1, L→R=1, R→R=1, R→W=1, L→W=1.
        XCTAssertEqual(m?.counts[0], [0, 2, 0, 0])     // wake → light ×2 (incl. nothing else)
        XCTAssertEqual(m?.counts[1], [1, 2, 1, 1])    // light → wake, light, deep, rem
        XCTAssertEqual(m?.counts[2], [0, 1, 1, 0])    // deep → light, deep
        XCTAssertEqual(m?.counts[3], [1, 0, 0, 1])    // rem → wake, rem
        XCTAssertEqual(m?.rowExposure, [2, 5, 2, 2])
        XCTAssertEqual(m?.eligiblePairCount.value, 11)
        XCTAssertEqual(m?.stageChangeCount.value, 7)
        XCTAssertEqual(m?.epochSeconds, 30)
        // Row-normalized probabilities: wake row 0.5 L / 0.5 nothing else? No: [0, 1.0, 0, 0]
        // — 2 wake→light pairs of exposure 2.
        XCTAssertEqual(m?.rowProbabilities[0]!, [0, 1.0, 0, 0])
        XCTAssertEqual(m?.rowProbabilities[1]!, [0.2, 0.4, 0.2, 0.2])
        XCTAssertEqual(m?.rowProbabilities[2]!, [0, 0.5, 0.5, 0])
        XCTAssertEqual(m?.rowProbabilities[3]!, [0.5, 0, 0, 0.5])
    }

    func testHandFixtureStageSecondsAndBouts() {
        let d = dynamics()
        let byLabel = Dictionary(uniqueKeysWithValues: d.stageSeconds.map { ($0.label, $0.seconds) })
        XCTAssertEqual(byLabel[.wake]?.value, 90)
        XCTAssertEqual(byLabel[.light]?.value, 150)
        XCTAssertEqual(byLabel[.deep]?.value, 60)
        XCTAssertEqual(byLabel[.rem]?.value, 60)
        XCTAssertEqual(byLabel[.unknown]?.value, 0)
        let bouts = Dictionary(uniqueKeysWithValues: d.stageBouts.map { ($0.label, $0) })
        // wake bouts: [0,30) censored-left (fragment edge), [240,270) COMPLETE (rem
        // before, light after), [330,360) censored-right (fragment end edge).
        XCTAssertEqual(bouts[.wake]?.boutCount.value, 3)
        XCTAssertEqual(bouts[.wake]?.completeBoutCount.value, 1)
        XCTAssertEqual(bouts[.wake]?.censoredBoutCount.value, 2)
        XCTAssertEqual(bouts[.wake]?.medianCompleteBoutSeconds.status, .unavailable)
        XCTAssertEqual(bouts[.wake]?.medianCompleteBoutSeconds.reason, .insufficientBouts)
        // light: [30,90) complete (deep before? bounded by wake/deep), [180,240) complete, [270,330) complete
        XCTAssertEqual(bouts[.light]?.boutCount.value, 3)
        XCTAssertEqual(bouts[.light]?.completeBoutCount.value, 3)
        XCTAssertEqual(bouts[.light]?.longestObservedSeconds.value, 60)
        XCTAssertEqual(bouts[.light]?.medianCompleteBoutSeconds.value, 60)
        XCTAssertEqual(bouts[.light]?.p90CompleteBoutSeconds.value, 60)   // n=3, ceil(2.7)=3 → sorted[2]
        // deep: one complete bout [90,150) — quantiles withheld (< 3 complete bouts).
        XCTAssertEqual(bouts[.deep]?.completeBoutCount.value, 1)
        XCTAssertEqual(bouts[.deep]?.medianCompleteBoutSeconds.status, .unavailable)
        XCTAssertEqual(bouts[.deep]?.longestObservedSeconds.value, 60)
        // rem: one complete bout [180,240) (two REM epochs merged, 60 s).
        XCTAssertEqual(bouts[.rem]?.completeBoutCount.value, 1)
        XCTAssertEqual(bouts[.rem]?.longestObservedSeconds.value, 60)
    }

    // MARK: - All-wake fixture: absent rows have NULL probabilities

    func testAllWakeFixtureNullProbabilityRows() {
        let start = t0
        let stages = [StageSegment(start: start, end: start + 360, stage: "wake")]
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: start + 360,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30, stages: stages)],
            timezoneId: "Etc/UTC",
            hr: (start..<start + 360).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let c = SleepAnalyticsV1.continuityGroup(timeline: timeline, input: input, config: .v1)
        XCTAssertEqual(c.observedAsleepSeconds.status, .unavailable)
        XCTAssertEqual(c.observedAsleepSeconds.reason, .noObservedSleep)
        XCTAssertEqual(c.awakeningBoutCount.value, 0)
        XCTAssertEqual(c.sleepToWakeTransitionCount.value, 0)
        let d = SleepAnalyticsV1.stageDynamicsGroup(timeline: timeline, input: input, config: .v1)
        let m = d.epochTransitions
        XCTAssertNotNil(m)
        // Only the wake row has outgoing pairs; light/deep/rem rows are NULL, not zero.
        XCTAssertEqual(m?.rowExposure, [11, 0, 0, 0])
        XCTAssertNil(m?.rowProbabilities[1])
        XCTAssertNil(m?.rowProbabilities[2])
        XCTAssertNil(m?.rowProbabilities[3])
        XCTAssertEqual(m?.rowProbabilities[0]!, [1.0, 0, 0, 0])
        XCTAssertEqual(m?.stageChangeCount.value, 0)
    }

    // MARK: - No REM / no deep

    func testNoRemFixtureRemLatencyNull() {
        let start = t0
        let labels = ["wake", "light", "light", "deep", "deep", "light",
                      "light", "light", "wake", "light", "light", "wake"]
        let stages = labels.enumerated().map { i, l in
            StageSegment(start: start + i * 30, end: start + (i + 1) * 30, stage: l)
        }
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: start + 360,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30, stages: stages)],
            timezoneId: "Etc/UTC",
            hr: (start..<start + 360).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let c = SleepAnalyticsV1.continuityGroup(timeline: timeline, input: input, config: .v1)
        XCTAssertEqual(c.remLatencyFromSleepOnsetSeconds.status, .unavailable)
        XCTAssertEqual(c.remLatencyFromSleepOnsetSeconds.reason, .noObservedRem)
        XCTAssertEqual(c.deepLatencyFromSleepOnsetSeconds.value, 60)
    }

    // MARK: - Empty input

    func testEmptyInputUnavailable() {
        let input = SleepAnalyticsInput(
            fragments: [], timezoneId: "Etc/UTC", hr: [], gravity: [], skinTemp: [],
            beats: [], deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let c = SleepAnalyticsV1.continuityGroup(timeline: timeline, input: input, config: .v1)
        XCTAssertEqual(c.quality.status, .unavailable)
        XCTAssertEqual(c.observedAsleepSeconds.reason, .noObservedSleep)
        XCTAssertEqual(c.sleepToWakeTransitionCount.value, 0)   // count exists: zero exposure
        let d = SleepAnalyticsV1.stageDynamicsGroup(timeline: timeline, input: input, config: .v1)
        XCTAssertEqual(d.quality.status, .unavailable)
    }

    // MARK: - Prefix-gap / onset at edge: latencies withheld

    func testOnsetAtEdgeWithholdsLatencies() {
        let start = t0
        // Sleep starts at epoch 0 (no wake before it inside the window).
        let stages = [StageSegment(start: start, end: start + 360, stage: "light")]
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: start + 360,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30, stages: stages)],
            timezoneId: "Etc/UTC",
            hr: (start..<start + 360).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let c = SleepAnalyticsV1.continuityGroup(timeline: timeline, input: input, config: .v1)
        // The delay is still reported, as a boundary estimate (partial).
        XCTAssertEqual(c.onsetDelayFromWindowSeconds.value, 0)
        XCTAssertEqual(c.onsetDelayFromWindowSeconds.status, .partial)
        XCTAssertEqual(c.onsetDelayFromWindowSeconds.reason, .onsetNotObserved)
        XCTAssertEqual(c.remLatencyFromSleepOnsetSeconds.reason, .onsetNotObserved)
        XCTAssertEqual(c.deepLatencyFromSleepOnsetSeconds.reason, .onsetNotObserved)
        // Marker latency is missing_marker in Phase 1 (no marker source wired).
        XCTAssertEqual(c.sleepOnsetLatencyFromMarkerSeconds.status, .unavailable)
        XCTAssertEqual(c.sleepOnsetLatencyFromMarkerSeconds.reason, .missingMarker)
    }

    // MARK: - Split night: the gap contributes separately, never a transition

    func testSplitNightGapSeparateNeverTransition() {
        let a = t0, b = t0 + 8 * 3600
        let fragA = SleepAnalyticsInput.Fragment(
            id: "f1", start: a, end: a + 300, sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
            stages: [StageSegment(start: a, end: a + 300, stage: "light")])
        let fragB = SleepAnalyticsInput.Fragment(
            id: "f2", start: b, end: b + 300, sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
            stages: [StageSegment(start: b, end: b + 300, stage: "light")])
        let input = SleepAnalyticsInput(
            fragments: [fragA, fragB], timezoneId: "Etc/UTC",
            hr: (a..<a + 300).map { HRSample(ts: $0, bpm: 58) }
                + (b..<b + 300).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let c = SleepAnalyticsV1.continuityGroup(timeline: timeline, input: input, config: .v1)
        // The gap lies OUTSIDE the sleep period (the last asleep ends at a+300... no:
        // the last supported asleep interval is fragment B's) — the gap between a+300
        // and b is INSIDE [onset, offset) and is the canonical inferred-awake time.
        XCTAssertEqual(c.inferredGapAwakeSecondsWithinSleepPeriod.value, 8 * 3600 - 300)
        XCTAssertEqual(c.estimatedWasoIncludingInferredGapsSeconds.status, .partial)
        XCTAssertEqual(c.estimatedWasoIncludingInferredGapsSeconds.value, 8 * 3600 - 300)
        // No observed transition crosses the gap (count 0 — zero with exposure).
        XCTAssertEqual(c.sleepToWakeTransitionCount.value, 0)
        // The sleep period spans the gap; observed WASO (supported wake) stays 0.
        XCTAssertEqual(c.observedWasoSeconds.value, 0)
        // Bouts never join across fragments: longest = 300 (one fragment's run).
        XCTAssertEqual(c.longestObservedSleepBoutSeconds.value, 300)
        // The epoch matrix counts pairs per fragment only (9+9 epochs → 17 pairs).
        let d = SleepAnalyticsV1.stageDynamicsGroup(timeline: timeline, input: input, config: .v1)
        XCTAssertEqual(d.epochTransitions?.eligiblePairCount.value, 18)
    }

    // MARK: - Quantile boundaries

    func testQuantileGatesAndDefinitions() {
        // 3 complete wake-free light bouts of 30/60/90 s → median 60, p90 = sorted[ceil(2.7)-1=2] = 90.
        let start = t0
        let labels = ["wake", "light", "wake", "light", "light", "wake", "light", "light", "light", "wake"]
        let stages = labels.enumerated().map { i, l in
            StageSegment(start: start + i * 30, end: start + (i + 1) * 30, stage: l)
        }
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: start + 300,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30, stages: stages)],
            timezoneId: "Etc/UTC",
            hr: (start..<start + 300).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let d = SleepAnalyticsV1.stageDynamicsGroup(timeline: timeline, input: input, config: .v1)
        let light = d.stageBouts.first { $0.label == .light }
        XCTAssertEqual(light?.completeBoutCount.value, 3)
        XCTAssertEqual(light?.medianCompleteBoutSeconds.value, 60)
        XCTAssertEqual(light?.p90CompleteBoutSeconds.value, 90)
        // Even-n median: two middle values averaged — the 30/60/90 fixture with 4
        // complete bouts is covered by the movement tests' even-n cases.
    }

    // MARK: - Rate gate boundary (30 min observed asleep)

    func testRateGateBoundary() {
        func rate(asleepSeconds: Int) -> SleepAnalyticsMetric {
            let start = t0
            // wake + asleep + wake; onset observed.
            let stages = [
                StageSegment(start: start, end: start + 30, stage: "wake"),
                StageSegment(start: start + 30, end: start + 30 + asleepSeconds, stage: "light"),
                StageSegment(start: start + 30 + asleepSeconds, end: start + 30 + asleepSeconds + 30, stage: "wake"),
            ]
            let input = SleepAnalyticsInput(
                fragments: [SleepAnalyticsInput.Fragment(
                    id: "sleep-test-\(start)", start: start, end: start + 30 + asleepSeconds + 30,
                    sourceKind: .nativeWhoop, sourceEpochSeconds: 30, stages: stages)],
                timezoneId: "Etc/UTC",
                hr: (start..<start + 30 + asleepSeconds + 30).map { HRSample(ts: $0, bpm: 58) },
                gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
                stageSourceVersion: "s", inputRevision: 1)
            let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
            return SleepAnalyticsV1.continuityGroup(timeline: timeline, input: input, config: .v1)
                .sleepToWakeTransitionsPerAsleepHour
        }
        // The boundary at the EPOCH level (the grid resolves sub-epoch spans to whole
        // epochs, so a 1799 s light span label-supports 1800 s): 59 light epochs
        // (1770 s) stay partial; 60 (1800 s) go available.
        XCTAssertEqual(rate(asleepSeconds: 1770).status, .partial)
        XCTAssertEqual(rate(asleepSeconds: 1800).status, .available)
    }

    // MARK: - Timestamp shift invariance

    func testTimestampShiftInvariance() {
        func metrics(at start: Int) -> [String] {
            let c = continuity(start: start)
            let d = dynamics(start: start)
            return [
                "\(c.observedAsleepSeconds.value)", "\(c.observedWasoSeconds.value)",
                "\(c.longestObservedSleepBoutSeconds.value)", "\(c.onsetDelayFromWindowSeconds.value)",
                "\(c.remLatencyFromSleepOnsetSeconds.value)", "\(c.deepLatencyFromSleepOnsetSeconds.value)",
                "\(c.awakeningBoutCount.value)", "\(c.sleepToWakeTransitionCount.value)",
                "\(d.epochTransitions?.eligiblePairCount.value)", "\(d.epochTransitions?.stageChangeCount.value)",
            ]
        }
        XCTAssertEqual(metrics(at: t0), metrics(at: t0 + 7 * 86400 + 17))
    }

    // MARK: - Totals-only fragment

    func testTotalsOnlyFragmentLabelSummariesWithoutBoutsOrMatrix() {
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "import-\(t0)", start: t0, end: t0 + 480,
                sourceKind: .totalsOnly, sourceEpochSeconds: nil,
                totalsMinutes: SleepAnalyticsStageMinutes(wake: 40, light: 180, deep: 90, rem: 90),
                stages: [])],
            timezoneId: "Etc/UTC", hr: [], gravity: [], skinTemp: [], beats: [],
            deviceFamily: .whoop5, stageSourceVersion: "import", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let c = SleepAnalyticsV1.continuityGroup(timeline: timeline, input: input, config: .v1)
        // Label summaries from the totals (PARTIAL, the source's own face value — spec 4.5,
        // review P2-1); every bout/transition/latency metric is unsupported_source.
        XCTAssertEqual(c.quality.status, .partial)
        XCTAssertEqual(c.observedAsleepSeconds.status, .partial)
        XCTAssertEqual(c.observedAsleepSeconds.value, 360 * 60)   // 180+90+90 minutes
        XCTAssertEqual(c.observedWasoSeconds.reason, .unsupportedSource)
        XCTAssertEqual(c.longestObservedSleepBoutSeconds.reason, .unsupportedSource)
        XCTAssertEqual(c.awakeningBoutCount.reason, .unsupportedSource)
        XCTAssertEqual(c.sleepToWakeTransitionCount.reason, .unsupportedSource)
        XCTAssertEqual(c.remLatencyFromSleepOnsetSeconds.reason, .unsupportedSource)
        XCTAssertEqual(c.onsetDelayFromWindowSeconds.reason, .unsupportedSource)
        XCTAssertEqual(c.sleepToWakeTransitionsPerAsleepHour.reason, .unsupportedSource)
        let d = SleepAnalyticsV1.stageDynamicsGroup(timeline: timeline, input: input, config: .v1)
        let byLabel = Dictionary(uniqueKeysWithValues: d.stageSeconds.map { ($0.label, $0.seconds) })
        // Label summaries from the totals, PARTIAL (totals-only provenance).
        XCTAssertEqual(byLabel[.light]?.value, 180 * 60)
        XCTAssertEqual(byLabel[.light]?.status, .partial)
        XCTAssertEqual(byLabel[.deep]?.value, 90 * 60)
        XCTAssertEqual(byLabel[.rem]?.value, 90 * 60)
        XCTAssertEqual(byLabel[.wake]?.value, 40 * 60)
        // No bout/transition matrix from a totals-only import.
        XCTAssertNil(d.epochTransitions)
        XCTAssertEqual(d.quality.streamCounts["totals_only_fragments"], 1)
        for bouts in d.stageBouts {
            // Bout metrics are unsupported_source for a totals-only import (review P1-3):
            // never a fabricated zero count.
            XCTAssertEqual(bouts.boutCount.reason, .unsupportedSource)
            XCTAssertEqual(bouts.completeBoutCount.reason, .unsupportedSource)
            XCTAssertEqual(bouts.censoredBoutCount.reason, .unsupportedSource)
            XCTAssertEqual(bouts.longestObservedSeconds.reason, .unsupportedSource)
            XCTAssertEqual(bouts.medianCompleteBoutSeconds.reason, .unsupportedSource)
        }
    }
}


// Anchor + clipped-window follow-ups (review P2-4 re-verification + P2-5 residual):
// an edited effective start OFF the stager's grid must withhold the epoch matrix
// (unsupported_source) while duration metrics stay computed, and a fragment too
// short for any PRV window reports insufficient_duration.
final class SleepAnalyticsAnchorFollowUpTests: XCTestCase {

    private let t0 = 1_789_000_000

    /// An edited fragment whose EFFECTIVE start sits off the stager's grid (the
    /// anchor is the original session start): the epoch matrix is withheld; the
    /// interval duration metrics stay computed (spec 4.9, review P2-4).
    func testOffGridEditedStartWithholdsEpochMatrix() {
        let sessionStart = t0
        let effectiveStart = t0 + 17          // off the 30 s grid (an edited start)
        let end = effectiveStart + 330        // on the EDITED start's grid (17 + 11×30),
                                              // off the stager's grid
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(sessionStart)", start: effectiveStart, end: end,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                edited: true, editRevision: 5,
                stageGridAnchorSeconds: sessionStart,
                stages: [StageSegment(start: sessionStart, end: end, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (effectiveStart..<end).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        // The anchor is threaded: the timeline fragment carries it and the grid
        // anchors there (P2-4 plumbing).
        XCTAssertEqual(timeline.fragments.first?.stageGridAnchorSeconds, sessionStart)
        XCTAssertEqual(timeline.fragments.first?.gridAnchor, sessionStart)
        // With the anchor, the off-grid EDITED start is DETECTED: the clipped
        // segment's first boundary (the effective start, 17 s off the stager's
        // grid) fails the anchor-relative alignment check → the epoch matrix is
        // withheld as unsupported_source (spec 4.9: the stager never produced
        // epochs on this grid), while duration metrics stay computed.
        XCTAssertFalse(timeline.epochAlignmentEstablished)
        let d = SleepAnalyticsV1.stageDynamicsGroup(timeline: timeline, input: input, config: .v1)
        XCTAssertNil(d.epochTransitions)
        // Duration metrics stay computed from the epoch-derived intervals (the
        // matrix alone is withheld): label-supported light = the anchor-grid epochs
        // inside the edited fragment — 10 full epochs + the 17 s clipped tail the
        // ≥50% rule supports = 317 s of the 343 s span (the 17 s before the first
        // grid point stay unknown, never forward-filled).
        XCTAssertEqual(d.stageSeconds.first { $0.label == .light }?.seconds.value, 317)

        // Now the SAME fragment WITHOUT the anchor (an adapter that did not pass
        // it): the effective start re-anchors the grid; the retained segment
        // boundaries sit OFF that grid → misalignment reported → matrix withheld.
        let input2 = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(sessionStart)", start: effectiveStart, end: end,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                edited: true, editRevision: 5,
                stages: [StageSegment(start: sessionStart, end: end, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (effectiveStart..<end).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline2 = SleepAnalyticsV1.normalize(input: input2, config: .v1)
        XCTAssertNil(timeline2.fragments.first?.stageGridAnchorSeconds)
        XCTAssertEqual(timeline2.fragments.first?.gridAnchor, effectiveStart)
        // WITHOUT the anchor this is the exact left-clipping defeat (review P2-4): the
        // clipped segment boundaries sit trivially on the EDITED start's grid, so
        // alignment "passes" and the matrix is built on a SHIFTED grid the stager
        // never used — the off-grid edit is silently accepted. This is why the worker
        // adapter passes the stager's session start as the anchor: the adapter
        // contract (exact source lineage), not the extractor alone, closes this hole.
        XCTAssertTrue(timeline2.epochAlignmentEstablished)
        let d2 = SleepAnalyticsV1.stageDynamicsGroup(timeline: timeline2, input: input2, config: .v1)
        XCTAssertNotNil(d2.epochTransitions)                  // built — on the shifted grid
        XCTAssertEqual(d2.epochTransitions?.epochSeconds, 30)
        XCTAssertEqual(d2.epochTransitions?.counts.reduce(0) { $0 + $1.reduce(0, +) }, 10)  // 11 epochs → 10 pairs
    }

    /// A fragment too short for any PRV window (mid-window start, end exactly at
    /// the next window start) reports insufficient_duration, not
    /// insufficient_coverage (review P2-5 residual).
    func testFragmentTooShortForAnyPrvWindowReportsInsufficientDuration() {
        let start = t0 - t0 % 300 + 100          // mid-window start
        let end = start + 200                    // ends exactly at the next window start
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "short-\(start)", start: start, end: end,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: start, end: end, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (start..<end).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [],
            beats: (start..<end).map { RRInterval(ts: $0, rrMs: 1000, srcChannel: nil, ord: $0 - start, seq: $0 - start) },
            deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let group = SleepAnalyticsV1.prvGroup(timeline: timeline, input: input, config: .v1)
        XCTAssertEqual(group.eligibleWindowCount.value, 0)
        XCTAssertEqual(group.withheldWindowCount.value, 1)   // too short for any window
        XCTAssertEqual(group.nightlySd1Ms.status, .unavailable)
        XCTAssertEqual(group.nightlySd1Ms.reason, .insufficientDuration)
    }
}


// Review round-3 residuals (R1/R2): the anchor-grid snap with an off-grid
// fragment start after a leading uncovered gap, and PRV clipped tails that
// follow full windows.
final class SleepAnalyticsReviewResidualTests: XCTestCase {

    private let t0 = 1_789_000_000

    /// R1: gridAnchor < fragment.start with an OFF-grid fragment.start and a
    /// leading uncovered gap (the first segment starts after the fragment start,
    /// ON the anchor grid — so alignment passes): the matrix rebuild must still
    /// snap to the ANCHOR's grid, not silently anchor at the off-grid start.
    func testMatrixSnapsToAnchorGridWithOffGridStart() {
        let anchor = t0
        let fragmentStart = t0 + 17          // off-grid effective start
        let end = t0 + 390
        // The segment starts ON the anchor grid (a leading uncovered gap of 13 s)
        // and ends on it, so alignment is ESTABLISHED from the anchor.
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(anchor)", start: fragmentStart, end: end,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                edited: true, editRevision: 3,
                stageGridAnchorSeconds: anchor,
                stages: [StageSegment(start: t0 + 30, end: end, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (fragmentStart..<end).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        XCTAssertTrue(timeline.epochAlignmentEstablished)   // segment boundaries on the anchor grid
        let d = SleepAnalyticsV1.stageDynamicsGroup(timeline: timeline, input: input, config: .v1)
        let matrix = d.epochTransitions
        XCTAssertNotNil(matrix)
        // The matrix grid snaps to the ANCHOR (R1): epochs are [30,60)…[360,390) —
        // the leading off-grid 17 s region carries no epoch — so the epoch count
        // matches the anchor grid, not a grid anchored at the off-grid start.
        // 12 grid points inside [fragmentStart, end) from the anchor grid
        // (30…360): 11 adjacent pairs, all light→light.
        XCTAssertEqual(matrix?.counts[1][1], 11)             // light → light self-transitions
        XCTAssertEqual(matrix?.eligiblePairCount.value, 11)
    }

    /// R2: a fragment that fits one full window plus a clipped tail counts the
    /// tail as withheld (insufficient_duration), e.g. [0, 650) drops [600, 650).
    func testPrvClippedTailAfterFullWindowIsCounted() {
        let start = t0 - t0 % 300
        let end = start + 650               // 2 full windows + a 50 s tail
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: end,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: start, end: end, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (start..<end).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [],
            beats: (start..<end).map { RRInterval(ts: $0, rrMs: 1000, srcChannel: nil, ord: $0 - start, seq: $0 - start) },
            deviceFamily: .whoop5, stageSourceVersion: "s", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        let group = SleepAnalyticsV1.prvGroup(timeline: timeline, input: input, config: .v1)
        // Two full windows (600 s of eligible beats) + the 50 s tail withheld as
        // insufficient_duration (R2 — previously silently dropped).
        XCTAssertEqual(group.eligibleWindowCount.value, 2)
        XCTAssertEqual(group.withheldWindowCount.value, 1)
    }
}
