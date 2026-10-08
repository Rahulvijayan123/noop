import XCTest
@testable import StrandAnalytics

/// Pure-policy tests for the interval joins, HRV slot / sleep-session alignment, the C4 resting
/// eligibility view, and the C10 snapshot document (contract C4/C10 + spec §9).
final class ActivityContextJoinTests: XCTestCase {

    /// Exact multiple of the 30-s epoch grid (1758000000 / 30 == 58600000).
    private let base = 1_758_000_000

    // MARK: - Helpers (mirror of the policy test helpers)

    private func window(_ label: MotionLabel, from: Int, prob: Double = 0.95) -> ActivityWindowPrediction {
        var probs: [String: Double] = [:]
        probs[label.rawValue] = prob
        for other in MotionLabel.allCases where other != label && other != .unknown {
            probs[other.rawValue] = 0.05
        }
        return ActivityWindowPrediction(startTs: from, endTs: from + 4, label: label, probs: probs)
    }

    private func run(_ label: MotionLabel, from: Int, to: Int) -> [ActivityWindowPrediction] {
        var out: [ActivityWindowPrediction] = []
        var t = from
        while t + 4 <= to {
            out.append(window(label, from: t))
            t += 2
        }
        return out
    }

    private func build(_ windows: [ActivityWindowPrediction], runStart: Int, runEnd: Int,
                       sleepSessions: [SleepSession] = [],
                       wearIntervals: [WearInterval] = [],
                       config: ActivityPolicyConfig = .default) -> [ActivityEpoch] {
        ActivityContextPolicy.buildEpochs(windows: windows, runStart: runStart, runEnd: runEnd,
                                          sleepSessions: sleepSessions, wearIntervals: wearIntervals,
                                          config: config).epochs
    }

    /// Manual epoch with explicit observed/valid seconds (for overlap / partial-epoch
    /// fixtures the builder cannot express directly).
    private func epoch(_ start: Int, _ end: Int, motion: MotionLabel,
                       observedS: Int? = nil, validS: Int? = nil,
                       posture: PostureLabel = .unknown,
                       sleepState: SleepStateLabel = .unknown,
                       wear: WearState = .unknown,
                       exertion: ExertionContext = .unknown,
                       confidence: Double = 0.9) -> ActivityEpoch {
        let obs = observedS ?? (end - start)
        let val = validS ?? obs
        return ActivityEpoch(startTs: start, endTs: end, motion: motion,
                             posture: posture, exercise: .unknown, sleepState: sleepState,
                             exertion: exertion, wear: wear,
                             confidence: confidence, observedS: obs, validS: val)
    }

    // MARK: - context(for:)

    func testDurationWeightedSharesWithPartialOverlap() {
        // Epoch A (base..base+30) walking, epoch B (base+30..base+60) stationary.
        let epochs = build(run(.walking, from: base, to: base + 30)
                           + run(.stationary, from: base + 30, to: base + 60),
                           runStart: base, runEnd: base + 60)
        XCTAssertEqual(epochs[0].motion, .walking)
        XCTAssertEqual(epochs[1].motion, .stationary)

        // Interval [base+10, base+40): 20 s of walking + 10 s of stationary.
        let s = ActivityContextJoin.context(for: base + 10, end: base + 40, epochs: epochs)
        XCTAssertEqual(s.share(of: .walking), 20.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .stationary), 10.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(s.unknownShare, 0, accuracy: 1e-9)
        XCTAssertEqual(s.shares[.running], nil)
        XCTAssertEqual(s.transitions, 1)
        XCTAssertEqual(s.recentActivity, 0, "the walking epoch overlaps the interval start: activity is ongoing")
        XCTAssertEqual(s.postureSource, "none")
    }

    func testUnknownShareFromAbstainedEpoch() {
        // 20 s accepted stationary + 10 s abstained in one epoch.
        var ws = run(.stationary, from: base, to: base + 20)
        var t = base + 20
        while t + 4 <= base + 30 {
            ws.append(ActivityWindowPrediction(startTs: t, endTs: t + 4, label: .unknown,
                                               probs: ["unknown": 0.99]))
            t += 2
        }
        let epochs = build(ws, runStart: base, runEnd: base + 30)
        let s = ActivityContextJoin.context(for: base, end: base + 30, epochs: epochs)
        XCTAssertEqual(s.share(of: .stationary), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.unknownShare, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .stationary) + s.unknownShare, 1.0, accuracy: 1e-9)
        XCTAssertFalse(s.qualityReasons.contains("unknown_motion"),
                       "1/3 unknown is below the 0.5 unknown-motion reason floor")
    }

    func testUnknownEpochContributesOnlyToUnknownShare() {
        // One unknown epoch (abstained) overlapping the interval -> full unknown share.
        var ws: [ActivityWindowPrediction] = []
        var t = base
        while t + 4 <= base + 30 {
            ws.append(ActivityWindowPrediction(startTs: t, endTs: t + 4, label: .unknown,
                                               probs: ["unknown": 0.99]))
            t += 2
        }
        let epochs = build(ws, runStart: base, runEnd: base + 30)
        let s = ActivityContextJoin.context(for: base, end: base + 30, epochs: epochs)
        XCTAssertTrue(s.shares.isEmpty)
        XCTAssertEqual(s.unknownShare, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.recentActivity, nil)
        XCTAssertTrue(s.qualityReasons.contains("unknown_motion"))
        XCTAssertEqual(s.qualityReasons, ["unknown_motion"])
    }

    func testNoOverlappingEpochsIsNoDataNeverStationary() {
        let epochs = build(run(.stationary, from: base, to: base + 60), runStart: base, runEnd: base + 60)
        let s = ActivityContextJoin.context(for: base + 1000, end: base + 1030, epochs: epochs)
        XCTAssertTrue(s.shares.isEmpty)
        XCTAssertEqual(s.unknownShare, 1.0, accuracy: 1e-9)
        XCTAssertTrue(s.qualityReasons.contains("no_data"))
        XCTAssertEqual(s.recentActivity, nil)

        let bad = ActivityContextJoin.context(for: base + 30, end: base + 30, epochs: epochs)
        XCTAssertTrue(bad.qualityReasons.contains("invalid_interval"))
    }

    func testRecentActivityIsMeasuredFromTheIntervalStart() {
        // run1 D3-17: a walk ending 120 s before a 15-min slot. Measured from the slot END it read
        // 1020 s (no recent_activity reason); from the START it is 120 s, inside the 600 s window.
        let epochs = build(run(.walking, from: base - 300, to: base - 120)
                           + run(.stationary, from: base - 120, to: base + 900),
                           runStart: base - 300, runEnd: base + 900)
        let s = ActivityContextJoin.context(for: base, end: base + 900, epochs: epochs)
        XCTAssertEqual(s.recentActivity, 120)
        XCTAssertTrue(s.qualityReasons.contains("recent_activity"))
    }

    func testActivityOngoingAtTheIntervalStartReadsZero() {
        // A walk that began before the interval and is still going as it starts is ongoing: 0 s.
        let epochs = build(run(.walking, from: base - 90, to: base + 30)
                           + run(.stationary, from: base + 30, to: base + 900),
                           runStart: base - 90, runEnd: base + 900)
        let s = ActivityContextJoin.context(for: base + 15, end: base + 900, epochs: epochs)
        XCTAssertEqual(s.recentActivity, 0)
        XCTAssertTrue(s.qualityReasons.contains("recent_activity"))
        // An epoch starting exactly at the interval start covers its start instant: also ongoing.
        let aligned = ActivityContextJoin.context(for: base - 90, end: base + 900, epochs: epochs)
        XCTAssertEqual(aligned.recentActivity, 0)
    }

    func testActivityStartingInsideTheIntervalIsNotRecentActivity() {
        // Review fix: a walk that starts inside the interval (even one still going at its end) is the
        // measurement's own composition, reported through `shares`, not activity PRECEDING it.
        let epochs = build(run(.stationary, from: base, to: base + 60)
                           + run(.walking, from: base + 60, to: base + 150),
                           runStart: base, runEnd: base + 150)
        let s = ActivityContextJoin.context(for: base, end: base + 75, epochs: epochs)
        XCTAssertNil(s.recentActivity)
        XCTAssertFalse(s.qualityReasons.contains("recent_activity"))
        XCTAssertGreaterThan(s.share(of: .walking), 0, "the in-interval walk is still visible in shares")
    }

    func testBriefWalkInsideANightIsNotRecentActivity() {
        // Review fix: an 8 h night (23:00-07:00) with one 30-s supported walking epoch at +3 h (a
        // bathroom trip). Counting in-interval activity as 'ongoing' made the whole night read
        // recentActivity 0 and 'recent_activity', so the nightly hero said "Recent activity".
        let night = 8 * 3600
        let epochs = build(run(.stationary, from: base, to: base + 3 * 3600)
                           + run(.walking, from: base + 3 * 3600, to: base + 3 * 3600 + 30)
                           + run(.stationary, from: base + 3 * 3600 + 30, to: base + night),
                           runStart: base, runEnd: base + night)
        XCTAssertTrue(epochs.contains { $0.motion == .walking && $0.isSupportedNonStationary },
                      "fixture must contain a supported walking epoch")
        let s = ActivityContextJoin.context(for: base, end: base + night, epochs: epochs)
        XCTAssertNil(s.recentActivity)
        XCTAssertFalse(s.qualityReasons.contains("recent_activity"))
        XCTAssertEqual(s.share(of: .walking), 30.0 / Double(night), accuracy: 1e-9)
    }

    func testTransitionAcrossAShortGapIsCounted() {
        // D3-06: stationary [0,30), 3 s gap, walking [33,63): the label changed, a gap in between.
        let epochs = [epoch(base, base + 30, motion: .stationary),
                      epoch(base + 33, base + 63, motion: .walking)]
        let s = ActivityContextJoin.context(for: base, end: base + 63, epochs: epochs)
        XCTAssertEqual(s.transitions, 1)
        let total = s.shares.values.reduce(0, +) + s.unknownShare
        XCTAssertEqual(total, 1.0, accuracy: 1e-9, "the gap seconds still count unknown")
        // A long gap is a real data hole: not counted as a transition.
        let far = [epoch(base, base + 30, motion: .stationary), epoch(base + 90, base + 120, motion: .walking)]
        XCTAssertEqual(ActivityContextJoin.context(for: base, end: base + 120, epochs: far).transitions, 0)
    }

    func testRecentActivityNilWhenNoSupportedActivity() {
        let epochs = build(run(.stationary, from: base, to: base + 120), runStart: base, runEnd: base + 120)
        let s = ActivityContextJoin.context(for: base, end: base + 120, epochs: epochs)
        XCTAssertNil(s.recentActivity)
    }

    func testPostureSourceReflectsUserConfirmation() {
        let epochs = ActivityContextPolicy.buildEpochs(
            windows: run(.walking, from: base, to: base + 60),
            runStart: base, runEnd: base + 60,
            postureAnnotations: [PostureAnnotation(start: base, end: base + 30, posture: .sitting)]).epochs
        let s = ActivityContextJoin.context(for: base, end: base + 60, epochs: epochs)
        XCTAssertEqual(s.postureSource, "user_confirmed")
    }

    // MARK: - Full-support normalization (spec §9 / A02, WS-10-F01/F02, WS-12-F02)

    func testSpec300SecondExampleFullSupportNormalization() {
        // Spec §9 / A02 example: five fully-valid 30-s stationary epochs covering
        // [base, base+150) inside a 300-s support. Every support second must count
        // exactly once: 150 covered-valid seconds -> stationary, 150 uncovered
        // seconds -> unknown. Old behavior returned stationary 1.0 with NO warning
        // at exactly 0.5 coverage; the fixed join must read 0.5/0.5 and fire the
        // low_coverage reason (uncovered time is data-missing, not "no_data").
        let epochs = build(run(.stationary, from: base, to: base + 150),
                           runStart: base, runEnd: base + 150)
        XCTAssertEqual(epochs.count, 5)
        let s = ActivityContextJoin.context(for: base, end: base + 300, epochs: epochs)
        XCTAssertEqual(s.share(of: .stationary), 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.unknownShare, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .stationary) + s.unknownShare, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ActivityContextJoin.coverage(for: base, end: base + 300, epochs: epochs),
                       0.5, accuracy: 1e-9,
                       "coverage is measured against the same full-support duration")
        XCTAssertTrue(s.qualityReasons.contains("low_coverage"), "\(s.qualityReasons)")
        XCTAssertFalse(s.qualityReasons.contains("no_data"),
                       "partial coverage is data-missing, distinguishable from no-data")
    }

    func testUnobservedSecondsInsideEpochCountUnknown() {
        // WS-10-F02: one 30-s epoch with only 16 observed/valid stationary seconds;
        // the remaining 14 grid seconds are unobserved and must count unknown.
        // unknownFraction alone is (observedS-validS)/observedS == 0 here, so the
        // join must use the grid width (validS/durationSeconds) instead of crediting
        // the whole 30-s width to the label.
        let epochs = build(run(.stationary, from: base, to: base + 16),
                           runStart: base, runEnd: base + 16)
        XCTAssertEqual(epochs.count, 1)
        XCTAssertEqual(epochs[0].observedS, 16)
        XCTAssertEqual(epochs[0].validS, 16)
        let s = ActivityContextJoin.context(for: base, end: base + 30, epochs: epochs)
        XCTAssertEqual(s.share(of: .stationary), 16.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(s.unknownShare, 14.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .stationary) + s.unknownShare, 1.0, accuracy: 1e-9)
    }

    func testOverlappingEpochsNeverDoubleCountASecond() {
        // Spec §9 contract 1: overlapping/conflicting epochs resolve deterministically
        // and no support second is double-counted. Documented rule: the earliest-start
        // epoch owns a shared second; ties break by earliest end, then input order.
        // The coarse-policy grid never overlaps by construction, so this only guards
        // malformed/merged input (incl. duplicate copies).
        let a = epoch(base, base + 60, motion: .stationary, observedS: 60, validS: 60)
        let b = epoch(base + 30, base + 90, motion: .walking, observedS: 60, validS: 60)
        let s = ActivityContextJoin.context(for: base, end: base + 90, epochs: [b, a])
        XCTAssertEqual(s.share(of: .stationary), 60.0 / 90.0, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .walking), 30.0 / 90.0, accuracy: 1e-9)
        XCTAssertEqual(s.unknownShare, 0, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .stationary) + s.share(of: .walking) + s.unknownShare,
                       1.0, accuracy: 1e-9)
        XCTAssertEqual(ActivityContextJoin.coverage(for: base, end: base + 90, epochs: [b, a]),
                       1.0, accuracy: 1e-9)

        // A third epoch fully inside an already-claimed span is skipped: no second is
        // counted twice, and the result is identical regardless of input order.
        let c = epoch(base + 40, base + 50, motion: .running, observedS: 10, validS: 10)
        let s2 = ActivityContextJoin.context(for: base, end: base + 90, epochs: [c, a, b])
        XCTAssertEqual(s2.share(of: .running), 0, accuracy: 1e-9)
        XCTAssertEqual(s2.share(of: .stationary), 60.0 / 90.0, accuracy: 1e-9)
        XCTAssertEqual(s2.share(of: .walking), 30.0 / 90.0, accuracy: 1e-9)
        XCTAssertEqual(s2, ActivityContextJoin.context(for: base, end: base + 90, epochs: [a, b, c]))

        // Two identical copies of one epoch must not double-count.
        let dup = epoch(base + 120, base + 150, motion: .stationary, observedS: 30, validS: 30)
        let s3 = ActivityContextJoin.context(for: base + 120, end: base + 150, epochs: [dup, dup])
        XCTAssertEqual(s3.share(of: .stationary), 1.0, accuracy: 1e-9)
        XCTAssertEqual(s3.unknownShare, 0, accuracy: 1e-9)
        XCTAssertEqual(ActivityContextJoin.coverage(for: base + 120, end: base + 150,
                                                    epochs: [dup, dup]), 1.0, accuracy: 1e-9)
    }

    func testGapAndTailConserveDuration() {
        // Covered [0,60) stationary, gap [60,120), covered [120,150) walking, tail
        // [150,180): shares + unknownShare must sum to 1 over the FULL 180-s support.
        let a = epoch(base, base + 60, motion: .stationary, observedS: 60, validS: 60)
        let b = epoch(base + 120, base + 150, motion: .walking, observedS: 30, validS: 30)
        let s = ActivityContextJoin.context(for: base, end: base + 180, epochs: [a, b])
        XCTAssertEqual(s.share(of: .stationary), 60.0 / 180.0, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .walking), 30.0 / 180.0, accuracy: 1e-9)
        XCTAssertEqual(s.unknownShare, 90.0 / 180.0, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .stationary) + s.share(of: .walking) + s.unknownShare,
                       1.0, accuracy: 1e-9)
        XCTAssertEqual(ActivityContextJoin.coverage(for: base, end: base + 180, epochs: [a, b]),
                       90.0 / 180.0, accuracy: 1e-9)
    }

    func testMixedPartialEpochOverlapConservesDuration() {
        // A partially-valid overlapping epoch: only 15 of its 60 grid seconds are
        // observed/valid, so the 30-s span it wins is split 15/45 valid/unknown.
        // Every second of the 90-s support is accounted exactly once.
        let a = epoch(base, base + 60, motion: .stationary, observedS: 60, validS: 60)
        let b = epoch(base + 30, base + 90, motion: .walking, observedS: 15, validS: 15)
        let s = ActivityContextJoin.context(for: base, end: base + 90, epochs: [a, b])
        XCTAssertEqual(s.share(of: .stationary), 60.0 / 90.0, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .walking), 7.5 / 90.0, accuracy: 1e-9)
        XCTAssertEqual(s.unknownShare, 22.5 / 90.0, accuracy: 1e-9)
        XCTAssertEqual(s.share(of: .stationary) + s.share(of: .walking) + s.unknownShare,
                       1.0, accuracy: 1e-9)
    }

    func testHrvSlotHalfEmptyReadsPartialSharesNotFullCoverage() {
        // WS-12-F02: a 900-s slot with 400 s of stationary and 500 s of nothing must
        // read stationary 0.44 / unknown 0.56 over the WHOLE slot — never the old
        // "400 of 400 recognised" (shares 1.0, unknownShare 0).
        let epochs = build(run(.stationary, from: base, to: base + 400),
                           runStart: base, runEnd: base + 400)
        let slot = ActivityContextJoin.hrvSlotContexts(slots: [base], epochs: epochs)[0]
        XCTAssertEqual(slot.shares["stationary"] ?? 0, 400.0 / 900.0, accuracy: 1e-9)
        XCTAssertEqual(slot.unknownShare, 500.0 / 900.0, accuracy: 1e-9)
        XCTAssertEqual((slot.shares["stationary"] ?? 0) + slot.unknownShare, 1.0, accuracy: 1e-9)
    }

    func testSleepSessionContextsInheritFullSupportSemantics() {
        // sleepSessionContexts inherits the corrected arithmetic: a session with 60 s
        // of stationary in a 120-s span reads stationary 0.5 / unknown 0.5.
        let epochs = build(run(.stationary, from: base, to: base + 60),
                           runStart: base, runEnd: base + 60)
        let sessions = ActivityContextJoin.sleepSessionContexts(
            sessions: [(start: base, end: base + 120)], epochs: epochs)
        XCTAssertEqual(sessions[0].shares["stationary"] ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(sessions[0].unknownShare, 0.5, accuracy: 1e-9)
    }

    // MARK: - HRV slots

    func testHrvSlotDurationWeightedOverWholeBucketNotFinalSecond() {
        // Slot [base, base+900): stationary for 870 s, then walking in the FINAL 30-s epoch.
        let epochs = build(run(.stationary, from: base, to: base + 870)
                           + run(.walking, from: base + 870, to: base + 900),
                           runStart: base, runEnd: base + 900)
        XCTAssertEqual(epochs.count, 30)
        XCTAssertEqual(epochs[29].motion, .walking)

        let slots = ActivityContextJoin.hrvSlotContexts(slots: [base], epochs: epochs)
        XCTAssertEqual(slots.count, 1)
        let slot = slots[0]
        XCTAssertEqual(slot.slotS, base)
        XCTAssertEqual(slot.shares["stationary"] ?? 0, 870.0 / 900.0, accuracy: 1e-9,
                       "the slot must read its WHOLE 900-s bucket, not the final-second label")
        XCTAssertEqual(slot.shares["walking"] ?? 0, 30.0 / 900.0, accuracy: 1e-9)
        XCTAssertEqual(slot.unknownShare, 0, accuracy: 1e-9)
        XCTAssertEqual(slot.postActivity, false)
    }

    func testHrvSlotRecentActivityAndPostActivity() {
        // Walking ends just before the slot; the slot sits in the 10-min post window.
        let epochs = build(run(.walking, from: base - 60, to: base)
                           + run(.stationary, from: base, to: base + 900),
                           runStart: base - 60, runEnd: base + 900)
        let slot = ActivityContextJoin.hrvSlotContexts(slots: [base], epochs: epochs)[0]
        XCTAssertEqual(slot.recentActivityS, 0, "last supported epoch ends at slot start: 0 s before it")
        XCTAssertEqual(slot.postActivity, true, "the slot overlaps the post-activity window")
    }

    func testHrvSlotNoData() {
        let epochs = build(run(.stationary, from: base, to: base + 60), runStart: base, runEnd: base + 60)
        let slot = ActivityContextJoin.hrvSlotContexts(slots: [base + 2000], epochs: epochs)[0]
        XCTAssertTrue(slot.shares.isEmpty)
        XCTAssertEqual(slot.unknownShare, 1.0, accuracy: 1e-9)
        XCTAssertNil(slot.recentActivityS)
        XCTAssertEqual(slot.postActivity, false)
    }

    // MARK: - Sleep session alignment

    func testSleepSessionContexts() {
        let epochs = build(run(.stationary, from: base, to: base + 120), runStart: base, runEnd: base + 120)
        let sessions = ActivityContextJoin.sleepSessionContexts(
            sessions: [(start: base + 60, end: base + 120)], epochs: epochs)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].start, base + 60)
        XCTAssertEqual(sessions[0].end, base + 120)
        XCTAssertEqual(sessions[0].shares["stationary"] ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(sessions[0].unknownShare, 0, accuracy: 1e-9)
    }

    // MARK: - Resting eligibility (C4, NEW view)

    /// Baseline eligible construction: 360 s of prior stillness, a fully-stationary 300-s window,
    /// on-wrist evidence, and an awake (wake-segment) sleep context.
    private func eligibleFixture() -> [ActivityEpoch] {
        build(run(.stationary, from: base - 360, to: base + 300),
              runStart: base - 360, runEnd: base + 300,
              sleepSessions: [SleepSession(start: base - 360, end: base + 300, efficiency: 0.5,
                                           stages: [StageSegment(start: base - 360, end: base + 300, stage: "wake")],
                                           restingHR: nil, avgHRV: nil)],
              wearIntervals: [WearInterval(start: base - 360, end: base + 300, wear: .onWrist)])
    }

    func testRestingEligibilityAccepts() {
        let epochs = eligibleFixture()
        let r = ActivityContextJoin.restingEligibility(window: [base, base + 300], priorSeconds: 360, epochs: epochs)
        XCTAssertTrue(r.eligible, "\(r.reasons)")
        XCTAssertTrue(r.reasons.isEmpty)
        XCTAssertEqual(r.stationaryFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.coverageFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.priorStillnessS, 360)
        XCTAssertTrue(r.onWrist)
        XCTAssertTrue(r.awake)
    }

    func testRestingEligibilityRejectsInsufficientStationary() {
        var epochs = eligibleFixture()
        // Walk for 60 s in the middle of the window: 240/300 stationary.
        epochs = ActivityContextPolicy.buildEpochs(
            windows: run(.stationary, from: base - 360, to: base + 120)
                     + run(.walking, from: base + 120, to: base + 180)
                     + run(.stationary, from: base + 180, to: base + 300),
            runStart: base - 360, runEnd: base + 300,
            sleepSessions: [SleepSession(start: base - 360, end: base + 300, efficiency: 0.5,
                                         stages: [StageSegment(start: base - 360, end: base + 300, stage: "wake")],
                                         restingHR: nil, avgHRV: nil)],
            wearIntervals: [WearInterval(start: base - 360, end: base + 300, wear: .onWrist)]).epochs
        let r = ActivityContextJoin.restingEligibility(window: [base, base + 300], priorSeconds: 360, epochs: epochs)
        XCTAssertFalse(r.eligible)
        XCTAssertTrue(r.reasons.contains("insufficient_stationary"), "\(r.reasons)")
        XCTAssertEqual(r.stationaryFraction, 240.0 / 300.0, accuracy: 1e-9)
    }

    func testRestingEligibilityRejectsInsufficientCoverage() {
        // 120 s data, 60 s gap, 120 s data inside the window: 240/300 valid coverage.
        let epochs = build(run(.stationary, from: base - 360, to: base + 120)
                           + run(.stationary, from: base + 180, to: base + 300),
                           runStart: base - 360, runEnd: base + 300,
                           sleepSessions: [SleepSession(start: base - 360, end: base + 300, efficiency: 0.5,
                                                        stages: [StageSegment(start: base - 360, end: base + 300, stage: "wake")],
                                                        restingHR: nil, avgHRV: nil)],
                           wearIntervals: [WearInterval(start: base - 360, end: base + 300, wear: .onWrist)])
        let r = ActivityContextJoin.restingEligibility(window: [base, base + 300], priorSeconds: 360, epochs: epochs)
        XCTAssertFalse(r.eligible)
        XCTAssertTrue(r.reasons.contains("insufficient_coverage"), "\(r.reasons)")
        XCTAssertEqual(r.coverageFraction, 240.0 / 300.0, accuracy: 1e-9)
    }

    func testRestingEligibilityRejectsInsufficientPriorStillness() {
        // Only 120 s of prior stillness, everything else eligible.
        let epochs = build(run(.stationary, from: base - 120, to: base + 300),
                           runStart: base - 120, runEnd: base + 300,
                           sleepSessions: [SleepSession(start: base - 120, end: base + 300, efficiency: 0.5,
                                                        stages: [StageSegment(start: base - 120, end: base + 300, stage: "wake")],
                                                        restingHR: nil, avgHRV: nil)],
                           wearIntervals: [WearInterval(start: base - 120, end: base + 300, wear: .onWrist)])
        let r = ActivityContextJoin.restingEligibility(window: [base, base + 300], priorSeconds: 120, epochs: epochs)
        XCTAssertFalse(r.eligible)
        XCTAssertTrue(r.reasons.contains("insufficient_prior_stillness"), "\(r.reasons)")
        XCTAssertEqual(r.priorStillnessS, 120)
    }

    func testRestingEligibilityRejectsWearUnknownAndOffWrist() {
        // No wear evidence: on-wrist cannot be confirmed from quiet IMU.
        let noWear = ActivityContextPolicy.buildEpochs(
            windows: run(.stationary, from: base - 360, to: base + 300),
            runStart: base - 360, runEnd: base + 300,
            sleepSessions: [SleepSession(start: base - 360, end: base + 300, efficiency: 0.5,
                                         stages: [StageSegment(start: base - 360, end: base + 300, stage: "wake")],
                                         restingHR: nil, avgHRV: nil)]).epochs
        let r1 = ActivityContextJoin.restingEligibility(window: [base, base + 300], priorSeconds: 360, epochs: noWear)
        XCTAssertFalse(r1.eligible)
        XCTAssertTrue(r1.reasons.contains("wear_unknown"), "\(r1.reasons)")
        XCTAssertFalse(r1.onWrist)

        // Explicit off-wrist evidence rejects outright.
        let off = ActivityContextPolicy.buildEpochs(
            windows: run(.stationary, from: base - 360, to: base + 300),
            runStart: base - 360, runEnd: base + 300,
            sleepSessions: [SleepSession(start: base - 360, end: base + 300, efficiency: 0.5,
                                         stages: [StageSegment(start: base - 360, end: base + 300, stage: "wake")],
                                         restingHR: nil, avgHRV: nil)],
            wearIntervals: [WearInterval(start: base - 360, end: base + 300, wear: .offWrist)]).epochs
        let r2 = ActivityContextJoin.restingEligibility(window: [base, base + 300], priorSeconds: 360, epochs: off)
        XCTAssertFalse(r2.eligible)
        XCTAssertTrue(r2.reasons.contains("off_wrist"), "\(r2.reasons)")
    }

    func testRestingEligibilityRejectsSleepUnknownAndAsleep() {
        // No sleep context at all: awake cannot be confirmed.
        let noSleep = build(run(.stationary, from: base - 360, to: base + 300),
                            runStart: base - 360, runEnd: base + 300,
                            wearIntervals: [WearInterval(start: base - 360, end: base + 300, wear: .onWrist)])
        let r1 = ActivityContextJoin.restingEligibility(window: [base, base + 300], priorSeconds: 360, epochs: noSleep)
        XCTAssertFalse(r1.eligible)
        XCTAssertTrue(r1.reasons.contains("sleep_unknown"), "\(r1.reasons)")
        XCTAssertFalse(r1.awake)

        // A sleep session (asleep) covering the window rejects: rest requires awake.
        let asleep = build(run(.stationary, from: base - 360, to: base + 300),
                           runStart: base - 360, runEnd: base + 300,
                           sleepSessions: [SleepSession(start: base - 60, end: base + 300, efficiency: 0.9,
                                                        stages: [StageSegment(start: base - 60, end: base + 300, stage: "deep")],
                                                        restingHR: nil, avgHRV: nil)],
                           wearIntervals: [WearInterval(start: base - 360, end: base + 300, wear: .onWrist)])
        let r2 = ActivityContextJoin.restingEligibility(window: [base, base + 300], priorSeconds: 360, epochs: asleep)
        XCTAssertFalse(r2.eligible)
        XCTAssertTrue(r2.reasons.contains("asleep"), "\(r2.reasons)")
    }

    func testRestingEligibilityCountsUnobservedEpochSecondsAsNotValid() {
        // WS-10-F02 in the eligibility view: an epoch with 20 observed/valid seconds
        // in a 30-s grid provides 20 s of valid coverage, not 30. Old code divided
        // by observedS (validFraction 1.0) and over-credited the whole epoch width.
        let epochs = [epoch(base - 360, base, motion: .stationary, observedS: 360, validS: 360),
                      epoch(base, base + 30, motion: .stationary, observedS: 20, validS: 20)]
        let r = ActivityContextJoin.restingEligibility(
            window: [base, base + 300], priorSeconds: 360, epochs: epochs)
        XCTAssertFalse(r.eligible)
        XCTAssertEqual(r.coverageFraction, 20.0 / 300.0, accuracy: 1e-9)
        XCTAssertTrue(r.reasons.contains("insufficient_coverage"), "\(r.reasons)")
        XCTAssertEqual(r.priorStillnessS, 360, "the 360-s prior stationary run still counts")
    }

    func testJoinAndEligibilityInvariantToNonConsumedEpochFields() {
        // Spec §8 counterfactual replay: hold motion/contact/annotations fixed and
        // vary ONLY fields the coarse-policy path cannot derive from HR. The coarse
        // policy never reads HR (ActivityContextPolicy), so ActivityEpoch carries no
        // HR-bearing field at all; the join/eligibility output must be bit-identical
        // when called with epochs that differ only in fields NOT consumed
        // (confidence, exercise). The GRANULAR HSMM path IS HR-fused upstream
        // (MotionEncoderOutput.classProbs -> ActivityContextModel, WS-08-F01/F02) and
        // must NOT gate resting pools without an hr-free variant — see the rule
        // comment on ActivityContextJoin.restingEligibility.
        let epochs = eligibleFixture()
        let varied = epochs.map { e in
            ActivityEpoch(startTs: e.startTs, endTs: e.endTs, motion: e.motion,
                          posture: e.posture, exercise: .true, sleepState: e.sleepState,
                          exertion: e.exertion, wear: e.wear,
                          confidence: 0.05, observedS: e.observedS, validS: e.validS)
        }
        XCTAssertNotEqual(epochs, varied, "the fixture must actually differ on non-consumed fields")

        let c1 = ActivityContextJoin.context(for: base, end: base + 300, epochs: epochs)
        let c2 = ActivityContextJoin.context(for: base, end: base + 300, epochs: varied)
        XCTAssertEqual(c1, c2, "join output must be bit-identical when only non-consumed fields differ")

        let r1 = ActivityContextJoin.restingEligibility(window: [base, base + 300],
                                                        priorSeconds: 360, epochs: epochs)
        let r2 = ActivityContextJoin.restingEligibility(window: [base, base + 300],
                                                        priorSeconds: 360, epochs: varied)
        XCTAssertEqual(r1, r2, "eligibility must be bit-identical when only non-consumed fields differ")
    }

    // MARK: - Codable / C10 document

    func testActivityContextDocumentCodableExactC10Keys() {
        let epochs = ActivityContextPolicy.buildEpochs(
            windows: run(.walking, from: base, to: base + 60) + run(.stationary, from: base + 60, to: base + 120),
            runStart: base, runEnd: base + 120,
            sleepSessions: [SleepSession(start: base + 60, end: base + 120, efficiency: 0.8,
                                         stages: [StageSegment(start: base + 60, end: base + 120, stage: "light")],
                                         restingHR: nil, avgHRV: nil)]).epochs
        let summary = ActivityContextPolicy.daySummary(epochs: epochs)
        let contexts = ActivityContexts(
            hrvSlots: ActivityContextJoin.hrvSlotContexts(slots: [base], epochs: epochs),
            sleepSessions: ActivityContextJoin.sleepSessionContexts(
                sessions: [(start: base + 60, end: base + 120)], epochs: epochs))
        let doc = ActivityContextDocument(modelVersion: "hart-activity-1",
                                          preprocessingVersion: "hart-pre-1",
                                          inputRevision: 7,
                                          dataThrough: "2026-10-02T00:00:00Z",
                                          status: .available, reasons: [],
                                          epochs: epochs, summary: summary, contexts: contexts)

        let data = try! JSONEncoder().encode(doc)
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["schema_version", "ontology_version", "model_version",
                                       "preprocessing_version", "input_revision", "data_through",
                                       "status", "reasons", "epochs", "summary", "contexts", "join_version"])
        XCTAssertEqual(obj["schema_version"] as? Int, 1)
        // recent_activity_s is measured from the slot start since join-2 (WP6); the marker says so.
        XCTAssertEqual(obj["join_version"] as? String, ActivityContextJoin.version)
        XCTAssertEqual(ActivityContextJoin.version, "join-2")
        XCTAssertEqual(obj["ontology_version"] as? String, "v1")
        XCTAssertEqual(obj["model_version"] as? String, "hart-activity-1")
        XCTAssertEqual(obj["preprocessing_version"] as? String, "hart-pre-1")
        XCTAssertEqual(obj["input_revision"] as? Int, 7)
        XCTAssertEqual(obj["status"] as? String, "available")

        let epoch = (obj["epochs"] as! [[String: Any]]).first!
        XCTAssertEqual(Set(epoch.keys), ["s", "e", "m", "p", "ex", "sl", "ec", "w", "c", "os", "vs"])

        let sum = obj["summary"] as! [String: Any]
        XCTAssertEqual(Set(sum.keys), ["supported_s", "unknown_share", "transitions"])

        let ctx = obj["contexts"] as! [String: Any]
        XCTAssertEqual(Set(ctx.keys), ["hrv_slots", "sleep_sessions"])
        let slot = (ctx["hrv_slots"] as! [[String: Any]]).first!
        XCTAssertEqual(Set(slot.keys), ["slot_s", "shares", "unknown_share", "recent_activity_s", "post_activity"])
        let sleep = (ctx["sleep_sessions"] as! [[String: Any]]).first!
        XCTAssertEqual(Set(sleep.keys), ["start", "end", "shares", "unknown_share"])

        // Full round trip.
        let decoded = try! JSONDecoder().decode(ActivityContextDocument.self, from: data)
        XCTAssertEqual(decoded, doc)

        // A document published before the marker (join-1 semantics) still decodes, with no join version.
        var legacy = obj
        legacy["join_version"] = nil
        let old = try! JSONDecoder().decode(ActivityContextDocument.self,
                                            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.joinVersion)
        XCTAssertEqual(old.contexts, doc.contexts)
    }

    func testActivityContextSummaryCodableRoundTrip() {
        let s = ActivityContextSummary(shares: [.walking: 0.5, .stationary: 0.25], unknownShare: 0.25,
                                       transitions: 2, recentActivity: 120, postureSource: "none",
                                       qualityReasons: ["recent_activity", "unknown_motion"])
        let data = try! JSONEncoder().encode(s)
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let shares = obj["shares"] as! [String: Double]
        XCTAssertEqual(shares["walking"], 0.5)
        XCTAssertEqual(shares["stationary"], 0.25)
        XCTAssertNil(shares["unknown"], "unknown must never appear as a label share key")
        let decoded = try! JSONDecoder().decode(ActivityContextSummary.self, from: data)
        XCTAssertEqual(decoded, s)
    }
}
