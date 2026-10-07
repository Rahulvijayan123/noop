import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// SleepAnalyticsNormalizationTests — the shared timeline normalization (spec section 4 +
// section 12 "Shared timeline/metrics" rows owned by this file). Every group computer builds
// on `normalize`, so these rules are pinned here once: half-open math, clipping, duplicates,
// conflicts → unknown, vocabulary mapping (no invented N1/N2/NREM splits), the native support
// mask (≥15 distinct seconds, clipped ≥50%, off-wrist override), external real-resolution
// support, totals-only (no manufactured timeline), gaps kept separate, no joins across
// boundaries, and UTC-shift invariance.

final class SleepAnalyticsNormalizationTests: XCTestCase {

    // MARK: - Fixtures

    private let t0 = 1_789_000_000          // aligned to a 30 s boundary? No — epoch grid is
                                            // anchored at the FRAGMENT start, not UTC, so any
                                            // start works (spec 4.9: alignment established by
                                            // the stager at the session start).

    /// The spec section 12 hand fixture: a 6-minute fully supported native timeline.
    /// `[wake, light, light, deep, deep, light, rem, rem, wake, light, light, wake]`
    private func handFixtureStages(start: Int) -> [StageSegment] {
        let labels = ["wake", "light", "light", "deep", "deep", "light",
                     "rem", "rem", "wake", "light", "light", "wake"]
        return labels.enumerated().map { i, l in
            StageSegment(start: start + i * 30, end: start + (i + 1) * 30, stage: l)
        }
    }

    /// Full 1 Hz HR evidence across a span (every second valid → every epoch supported).
    private func fullHR(start: Int, end: Int) -> [HRSample] {
        (start..<end).map { HRSample(ts: $0, bpm: 58) }
    }

    private func makeInput(start: Int, end: Int, stages: [StageSegment],
                           hr: [HRSample]? = nil,
                           offWrist: [SleepAnalyticsInterval] = [],
                           sourceKind: SleepAnalyticsStageSourceKind = .nativeWhoop,
                           sourceEpochSeconds: Int? = 30) -> SleepAnalyticsInput {
        SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: end,
                sourceKind: sourceKind, sourceEpochSeconds: sourceEpochSeconds,
                edited: false, editRevision: nil, stages: stages)],
            timezoneId: "Etc/UTC",
            hr: hr ?? fullHR(start: start, end: end),
            gravity: [], skinTemp: [], beats: [],
            deviceFamily: .whoop5,
            offWristIntervals: offWrist,
            attemptedSleepMarker: nil,
            stageSourceVersion: "sleep-stager-v2-test",
            inputRevision: 1)
    }

    // MARK: - Hand fixture timeline shape

    func testHandFixtureNormalizesToTwelveSupportedEpochsMerged() {
        let start = t0
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 360, stages: handFixtureStages(start: start)),
            config: .v1)
        // All 12 epochs are supported with full 1 Hz evidence; adjacent same-label epochs
        // merge: wake(30) light(60) deep(60) light(30) rem(60) wake(30) light(60) wake(30).
        XCTAssertEqual(timeline.intervals.map { "\($0.label)=\($0.end - $0.start)" },
                       ["wake=30", "light=60", "deep=60", "light=30", "rem=60",
                        "wake=30", "light=60", "wake=30"])
        XCTAssertTrue(timeline.intervals.allSatisfy(\.labelSupported))
        XCTAssertEqual(timeline.firstSupportedAsleepStart, start + 30)
        XCTAssertEqual(timeline.lastSupportedAsleepEnd, start + 330)
        XCTAssertTrue(timeline.onsetPrefixObserved)
        XCTAssertTrue(timeline.offsetSuffixObserved)
        XCTAssertEqual(timeline.discardedSpanCount, 0)
        XCTAssertEqual(timeline.conflictSeconds, 0)
        XCTAssertEqual(timeline.inferredGapIntervals.count, 0)
        XCTAssertEqual(timeline.totalInputSupportedSeconds, 360)
        XCTAssertEqual(timeline.totalLabelSupportedSeconds, 360)
    }

    // MARK: - Empty input

    func testEmptyFragmentsYieldsEmptyTimeline() {
        let timeline = SleepAnalyticsV1.normalize(
            input: SleepAnalyticsInput(
                fragments: [], timezoneId: "Etc/UTC", hr: fullHR(start: 0, end: 60),
                gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
                stageSourceVersion: "sleep-stager-v2-test", inputRevision: 1),
            config: .v1)
        XCTAssertEqual(timeline.intervals.count, 0)
        XCTAssertNil(timeline.firstSupportedAsleepStart)
        XCTAssertNil(timeline.lastSupportedAsleepEnd)
        XCTAssertFalse(timeline.onsetPrefixObserved)
        XCTAssertEqual(timeline.windowStart, 0)
        XCTAssertEqual(timeline.windowEnd, 0)
    }

    // MARK: - Invalid spans are discarded and counted (spec 4.1)

    func testInvalidSpansAreDiscardedAndCounted() {
        let start = t0
        var stages = handFixtureStages(start: start)
        stages.append(StageSegment(start: start + 900, end: start + 900, stage: "light"))   // zero
        stages.append(StageSegment(start: start + 960, end: start + 930, stage: "rem"))    // negative
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 360, stages: stages), config: .v1)
        XCTAssertEqual(timeline.discardedSpanCount, 2)
        XCTAssertEqual(timeline.discardedSpanSeconds, 0)   // zero/negative claim no seconds
        XCTAssertEqual(timeline.intervals.count, 8)        // the valid fixture is untouched
    }

    // MARK: - Duplicates collapse; same-label overlap unions (spec 4.2)

    func testExactDuplicateSegmentsCollapse() {
        let start = t0
        var stages = handFixtureStages(start: start)
        stages.append(contentsOf: handFixtureStages(start: start))   // full duplicate
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 360, stages: stages), config: .v1)
        XCTAssertEqual(timeline.intervals.count, 8)
        XCTAssertEqual(timeline.conflictSeconds, 0)
        XCTAssertEqual(timeline.totalLabelSupportedSeconds, 360)
    }

    func testSameLabelOverlappingSegmentsUnion() {
        let start = t0
        let stages = [
            StageSegment(start: start, end: start + 120, stage: "light"),
            StageSegment(start: start + 60, end: start + 180, stage: "light"),
        ]
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 180, stages: stages), config: .v1)
        XCTAssertEqual(timeline.intervals.count, 1)
        XCTAssertEqual(timeline.intervals[0].label, .light)
        XCTAssertEqual(timeline.intervals[0].end - timeline.intervals[0].start, 180)
        XCTAssertEqual(timeline.conflictSeconds, 0)
    }

    // MARK: - Conflicting overlap becomes unknown (spec 4.2)

    func testConflictingOverlapBecomesUnknownOverConflict() {
        let start = t0
        let stages = [
            StageSegment(start: start, end: start + 120, stage: "light"),
            StageSegment(start: start + 60, end: start + 180, stage: "rem"),
        ]
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 180, stages: stages), config: .v1)
        // [0,60) light; [60,120) conflict → unknown; [120,180) rem.
        XCTAssertEqual(timeline.intervals.map { "\($0.label)=\($0.end - $0.start)" },
                       ["light=60", "unknown=60", "rem=60"])
        XCTAssertEqual(timeline.conflictSeconds, 60)
    }

    // MARK: - Vocabulary mapping (spec 4.3)

    func testAwakeMapsToWakeAndUnmappedLabelsStayUnknown() {
        XCTAssertEqual(SleepAnalyticsV1.mapStageLabel("WAKE"), .wake)
        XCTAssertEqual(SleepAnalyticsV1.mapStageLabel(" awake "), .wake)
        XCTAssertEqual(SleepAnalyticsV1.mapStageLabel("light"), .light)
        XCTAssertEqual(SleepAnalyticsV1.mapStageLabel("deep"), .deep)
        XCTAssertEqual(SleepAnalyticsV1.mapStageLabel("rem"), .rem)
        // No invention: NREM is not split into light/deep, unscored stays unknown.
        XCTAssertNil(SleepAnalyticsV1.mapStageLabel("nrem"))
        XCTAssertNil(SleepAnalyticsV1.mapStageLabel("uns"))
        XCTAssertNil(SleepAnalyticsV1.mapStageLabel("artifact"))
        XCTAssertNil(SleepAnalyticsV1.mapStageLabel("n1"))
        XCTAssertNil(SleepAnalyticsV1.mapStageLabel("n2"))
    }

    /// A 3-class NREM source maps wake/rem through and leaves NREM unknown — never invented
    /// as light or deep (spec 4.3 + section 12 "3-class NREM source").
    func testThreeClassNremSourceKeepsNremUnknown() {
        let start = t0
        let stages = [
            StageSegment(start: start, end: start + 60, stage: "wake"),
            StageSegment(start: start + 60, end: start + 150, stage: "nrem"),
            StageSegment(start: start + 150, end: start + 180, stage: "rem"),
        ]
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 180, stages: stages), config: .v1)
        // Epoch majority: e0-1 wake (60 s), e2-4 nrem→unknown (never invented as light/deep),
        // e5 rem (30 s).
        XCTAssertEqual(timeline.supportedSeconds(of: .rem), 30)
        XCTAssertEqual(timeline.supportedSeconds(of: .wake), 60)
        XCTAssertEqual(timeline.supportedSeconds(of: .light), 0)
        XCTAssertEqual(timeline.supportedSeconds(of: .deep), 0)
        XCTAssertEqual(timeline.intervals.filter { $0.label == .unknown }.reduce(0) {
            $0 + ($1.end - $1.start) }, 90)
    }

    // MARK: - Native support mask (spec 4.4)

    /// Below 15 distinct evidence seconds an epoch's label is unsupported → unknown.
    func testSparseEvidenceEpochsAreUnsupported() {
        let start = t0
        let hr = (start..<start + 360).compactMap { ts -> HRSample? in
            // One second in 30 carries evidence → 1 distinct second per epoch < 15.
            ts % 30 == 0 ? HRSample(ts: ts, bpm: 58) : nil
        }
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 360,
                             stages: handFixtureStages(start: start), hr: hr), config: .v1)
        XCTAssertTrue(timeline.intervals.allSatisfy { !$0.labelSupported })
        XCTAssertEqual(timeline.totalLabelSupportedSeconds, 0)
        XCTAssertEqual(timeline.firstSupportedAsleepStart, nil)
        // Actual input support is still recorded: 12 evidence seconds, not zeroed.
        XCTAssertEqual(timeline.totalInputSupportedSeconds, 12)
    }

    /// The ≥50% rule for a clipped final epoch: 15 s of evidence supports a 20 s clipped epoch
    /// (15/20 = 75% ≥ 50%), while 10 s does not (spec 4.4 last sentence).
    func testClippedEpochUsesHalfFractionRule() {
        let start = t0
        let end = start + 110          // 3 full epochs + a 20 s clipped epoch
        let stages = [StageSegment(start: start, end: end, stage: "light")]
        let hr = (start..<start + 90).map { HRSample(ts: $0, bpm: 58) }
            + (start + 90..<start + 105).map { HRSample(ts: $0, bpm: 58) }   // 15 s in clip
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: end, stages: stages, hr: hr), config: .v1)
        // The clipped epoch (90..110) has 15 distinct evidence seconds (75% ≥ 50%) → the
        // whole night merges into ONE supported light interval; the clipped epoch's real
        // support (15 s of 20) is recorded as input support, never as label seconds.
        XCTAssertEqual(timeline.intervals.count, 1)
        XCTAssertEqual(timeline.intervals[0].label, .light)
        XCTAssertTrue(timeline.intervals[0].labelSupported)
        XCTAssertEqual(timeline.intervals[0].inputSupportedSeconds, 105)
        XCTAssertEqual(timeline.totalLabelSupportedSeconds, 110)

        // Exactly 50% of the clipped epoch (10 s of 20) still clears the ≥50% rule; 9 s
        // does not (spec 4.4: the same ≥50% distinct-second rule against clipped duration).
        let hrHalf = (start..<start + 90).map { HRSample(ts: $0, bpm: 58) }
            + (start + 90..<start + 100).map { HRSample(ts: $0, bpm: 58) }   // 10 s = exactly 50%
        let timelineHalf = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: end, stages: stages, hr: hrHalf), config: .v1)
        XCTAssertTrue(timelineHalf.intervals[0].labelSupported)

        let hrLow = (start..<start + 90).map { HRSample(ts: $0, bpm: 58) }
            + (start + 90..<start + 99).map { HRSample(ts: $0, bpm: 58) }    // 9 s < 50%
        let timeline2 = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: end, stages: stages, hr: hrLow), config: .v1)
        // The unsupported clipped epoch splits the merged run: [start,90) supported light,
        // [90,110) unsupported → unknown.
        XCTAssertEqual(timeline2.intervals.map { "\($0.label)=\($0.labelSupported)" },
                       ["light=true", "unknown=false"])
        XCTAssertEqual(timeline2.totalLabelSupportedSeconds, 90)
    }

    /// Explicit off-wrist intervals override support (spec 4.4).
    func testOffWristIntervalsOverrideSupport() {
        let start = t0
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 360,
                             stages: handFixtureStages(start: start),
                             offWrist: [SleepAnalyticsInterval(start: start + 60, end: start + 120)]),
            config: .v1)
        // Epochs 2-3 (60..120) are overridden → unsupported → unknown, neighbours keep labels.
        XCTAssertTrue(timeline.intervals.contains {
            $0.start == start + 60 && $0.end == start + 120
                && !$0.labelSupported && $0.label == .unknown })
        // Supported light outside the override: e1 + e5 + e9-10 = 30 + 30 + 60.
        XCTAssertEqual(timeline.supportedSeconds(of: .light), 120)
    }

    // MARK: - Uncovered time stays unknown (spec 4.6)

    func testUncoveredSpanInsideFragmentStaysUnknown() {
        let start = t0
        // Stages cover [0,90) and [150,360); [90,150) is uncovered.
        var stages = handFixtureStages(start: start).filter { $0.end <= start + 90 }
        stages.append(StageSegment(start: start + 150, end: start + 360, stage: "rem"))
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 360, stages: stages), config: .v1)
        XCTAssertEqual(timeline.intervals.filter { $0.label == .unknown }.reduce(0) {
            $0 + ($1.end - $1.start) }, 60)   // 90..150 unknown, never forward-filled
    }

    // MARK: - External source: real resolution, sensor support unknown (spec 4.5)

    func testTimedExternalHypnogramKeepsRealResolutionAndUnknownSensorSupport() {
        let start = t0
        // A 60 s-resolution external hypnogram over 3 minutes.
        let stages = [
            StageSegment(start: start, end: start + 60, stage: "light"),
            StageSegment(start: start + 60, end: start + 120, stage: "deep"),
            StageSegment(start: start + 120, end: start + 180, stage: "rem"),
        ]
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 180, stages: stages,
                             hr: [],   // sensor evidence irrelevant: support stays unknown
                             sourceKind: .timestampedExternal, sourceEpochSeconds: 60),
            config: .v1)
        XCTAssertEqual(timeline.intervals.count, 3)          // 60 s runs kept, no 30 s grid
        XCTAssertTrue(timeline.intervals.allSatisfy(\.labelSupported))
        XCTAssertTrue(timeline.intervals.allSatisfy { $0.inputSupportedSeconds == 0 })
        XCTAssertEqual(timeline.totalInputSupportedSeconds, 0)   // sensor_support_unknown
        XCTAssertEqual(timeline.firstSupportedAsleepStart, start)
        // Left-censored: the first asleep run starts at the fragment edge with no observed
        // preceding wake epoch → the prefix is NOT observed (spec section 4 quality).
        XCTAssertFalse(timeline.onsetPrefixObserved)
    }

    // MARK: - Totals-only: no manufactured timeline (spec 4.5)

    func testTotalsOnlyFragmentManufacturesNoTimeline() {
        let start = t0
        let input = SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "import-\(start)", start: start, end: start + 480,
                sourceKind: .totalsOnly, sourceEpochSeconds: nil, edited: false,
                editRevision: nil,
                totalsMinutes: SleepAnalyticsStageMinutes(wake: 40, light: 180, deep: 90, rem: 90),
                stages: [])],
            timezoneId: "Etc/UTC", hr: [], gravity: [], skinTemp: [], beats: [],
            deviceFamily: .whoop5, stageSourceVersion: "import-test", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        XCTAssertEqual(timeline.intervals.count, 0)          // nothing synthetic
        XCTAssertEqual(timeline.fragments.count, 1)
        XCTAssertEqual(timeline.fragments[0].totalsMinutes?.light, 180)
        XCTAssertEqual(timeline.firstSupportedAsleepStart, nil)
        XCTAssertFalse(timeline.onsetPrefixObserved)
    }

    // MARK: - Fragment boundaries and gaps (spec 4.7, 4.8)

    func testSplitNightKeepsGapsSeparateAndNeverJoinsAcrossFragments() {
        let a = t0, b = t0 + 8 * 3600                       // two fragments, 8 h apart
        let fragA = SleepAnalyticsInput.Fragment(
            id: "sleep-test-\(a)", start: a, end: a + 360,
            sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
            stages: [StageSegment(start: a, end: a + 360, stage: "light")])
        let fragB = SleepAnalyticsInput.Fragment(
            id: "sleep-test-\(b)", start: b, end: b + 360,
            sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
            stages: [StageSegment(start: b, end: b + 360, stage: "rem")])
        let input = SleepAnalyticsInput(
            fragments: [fragA, fragB], timezoneId: "Etc/UTC",
            hr: fullHR(start: a, end: a + 360) + fullHR(start: b, end: b + 360),
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "sleep-stager-v2-test", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        XCTAssertEqual(timeline.inferredGapIntervals,
                       [SleepAnalyticsInterval(start: a + 360, end: b)])
        XCTAssertEqual(timeline.windowStart, a)
        XCTAssertEqual(timeline.windowEnd, b + 360)
        // Intervals never cross fragments; the gap creates no interval at all.
        XCTAssertEqual(timeline.intervals.count, 2)
        XCTAssertTrue(timeline.intervals.allSatisfy { $0.end - $0.start == 360 })
        // The gap is inferred-awake, not sensor coverage: input support excludes it.
        XCTAssertEqual(timeline.totalInputSupportedSeconds, 720)
        // Onset prefix: first asleep starts at fragment A's left edge → left-censored.
        XCTAssertFalse(timeline.onsetPrefixObserved)
    }

    /// Two fragments whose timestamps touch: still NO join across the boundary (spec 4.8).
    func testTouchingFragmentsDoNotJoin() {
        let a = t0
        let fragA = SleepAnalyticsInput.Fragment(
            id: "f1", start: a, end: a + 300,
            sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
            stages: [StageSegment(start: a, end: a + 300, stage: "light")])
        let fragB = SleepAnalyticsInput.Fragment(
            id: "f2", start: a + 300, end: a + 600,
            sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
            stages: [StageSegment(start: a + 300, end: a + 600, stage: "light")])
        let input = SleepAnalyticsInput(
            fragments: [fragA, fragB], timezoneId: "Etc/UTC",
            hr: fullHR(start: a, end: a + 600), gravity: [], skinTemp: [], beats: [],
            deviceFamily: .whoop5, stageSourceVersion: "sleep-stager-v2-test", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        XCTAssertEqual(timeline.inferredGapIntervals.count, 0)   // touching: no gap span
        XCTAssertEqual(timeline.intervals.count, 2)              // but never merged into one
        XCTAssertEqual(timeline.intervals[0].end, timeline.intervals[1].start)
    }

    // MARK: - Clipping to effective fragment bounds (spec 4.1)

    func testStagesAreClippedToEffectiveFragmentBounds() {
        let start = t0
        // Segment extends past the fragment end (an edited shorter night): clip.
        let stages = [StageSegment(start: start, end: start + 600, stage: "deep")]
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 180, stages: stages), config: .v1)
        XCTAssertEqual(timeline.intervals.count, 1)
        XCTAssertEqual(timeline.intervals[0].end, start + 180)
        // Uncovered tail (180..600 claimed by the segment) is gone, not unknown-filled.
        XCTAssertEqual(timeline.windowEnd, start + 180)
    }

    // MARK: - Reversed bounds (spec section 12)

    func testReversedFragmentBoundsAreDropped() {
        let start = t0
        let bad = SleepAnalyticsInput.Fragment(
            id: "reversed", start: start + 360, end: start,       // end < start
            sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
            stages: handFixtureStages(start: start))
        let input = SleepAnalyticsInput(
            fragments: [bad], timezoneId: "Etc/UTC", hr: [], gravity: [], skinTemp: [],
            beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "sleep-stager-v2-test", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        XCTAssertEqual(timeline.fragments.count, 0)
        XCTAssertEqual(timeline.intervals.count, 0)
    }

    // MARK: - UTC shift invariance (spec section 12: shift all timestamps by a constant)

    func testUTCTimestampShiftLeavesTimelineUnchanged() {
        func normalized(at start: Int) -> SleepAnalyticsTimeline {
            SleepAnalyticsV1.normalize(
                input: makeInput(start: start, end: start + 360,
                                 stages: handFixtureStages(start: start)), config: .v1)
        }
        let a = normalized(at: t0)
        let b = normalized(at: t0 + 7 * 86400 + 17)      // a week + 17 s later
        func shape(_ t: SleepAnalyticsTimeline) -> [String] {
            t.intervals.map { "\($0.label)=\($0.end - $0.start)-\($0.labelSupported)-\($0.inputSupportedSeconds)" }
        }
        XCTAssertEqual(shape(a), shape(b))
        XCTAssertEqual(a.discardedSpanCount, b.discardedSpanCount)
        XCTAssertEqual(a.conflictSeconds, b.conflictSeconds)
        XCTAssertEqual(a.onsetPrefixObserved, b.onsetPrefixObserved)
        XCTAssertEqual(a.offsetSuffixObserved, b.offsetSuffixObserved)
        XCTAssertEqual(a.totalInputSupportedSeconds, b.totalInputSupportedSeconds)
    }

    // MARK: - Left-censoring: onset at the very start of the fragment

    func testOnsetAtFragmentEdgeIsNotObserved() {
        let start = t0
        // Sleep starts at epoch 0 (no wake before it inside the window).
        let stages = [StageSegment(start: start, end: start + 360, stage: "light")]
        let timeline = SleepAnalyticsV1.normalize(
            input: makeInput(start: start, end: start + 360, stages: stages), config: .v1)
        XCTAssertFalse(timeline.onsetPrefixObserved)
        XCTAssertTrue(timeline.offsetSuffixObserved == false)   // no wake after either
    }

    // MARK: - Huge gap carrying labels (spec section 12 "huge gap carrying labels")

    func testHugeGapBetweenFragmentsCarriesNoLabelsAcross() {
        let a = t0, b = t0 + 10 * 3600     // 10 h apart: far beyond any bridge
        let fragA = SleepAnalyticsInput.Fragment(
            id: "f1", start: a, end: a + 300, sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
            stages: [StageSegment(start: a, end: a + 300, stage: "light")])
        let fragB = SleepAnalyticsInput.Fragment(
            id: "f2", start: b, end: b + 300, sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
            stages: [StageSegment(start: b, end: b + 300, stage: "light")])
        let input = SleepAnalyticsInput(
            fragments: [fragA, fragB], timezoneId: "Etc/UTC",
            hr: fullHR(start: a, end: a + 300) + fullHR(start: b, end: b + 300),
            gravity: [], skinTemp: [], beats: [], deviceFamily: .whoop5,
            stageSourceVersion: "sleep-stager-v2-test", inputRevision: 1)
        let timeline = SleepAnalyticsV1.normalize(input: input, config: .v1)
        XCTAssertEqual(timeline.inferredGapIntervals.count, 1)
        XCTAssertEqual(timeline.inferredGapIntervals[0].end - timeline.inferredGapIntervals[0].start,
                       10 * 3600 - 300)
        XCTAssertEqual(timeline.totalInputSupportedSeconds, 600)   // gap never becomes coverage
    }
}
