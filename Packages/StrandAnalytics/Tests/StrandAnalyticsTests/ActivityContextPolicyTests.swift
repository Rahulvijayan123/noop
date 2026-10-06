import XCTest
@testable import StrandAnalytics

/// Pure-policy tests for the temporal epoch builder (contract C4 + spec §9/§12).
///
/// Everything here is synthetic and fixed: windows are generated on a 2-s hop grid over the 30-s
/// UTC epochs, and every assertion is exact. No Python, storage or network.
final class ActivityContextPolicyTests: XCTestCase {

    /// A Unix base that is an exact multiple of the 30-s epoch grid (1758000000 / 30 == 58600000),
    /// so epoch boundaries fall exactly on `base + 30k`.
    private let base = 1_758_000_000

    // MARK: - Window helpers

    /// One 4-s window prediction, defaulting to a confident accepted prediction.
    private func window(_ label: MotionLabel, from: Int, prob: Double = 0.95,
                        secondProb: Double = 0.05) -> ActivityWindowPrediction {
        var probs: [String: Double] = [:]
        probs[label.rawValue] = prob
        for other in MotionLabel.allCases where other != label && other != .unknown {
            probs[other.rawValue] = secondProb
        }
        return ActivityWindowPrediction(startTs: from, endTs: from + 4, label: label, probs: probs)
    }

    /// 4-s windows at 2-s hop over `[from, to)`.
    private func run(_ label: MotionLabel, from: Int, to: Int, prob: Double = 0.95) -> [ActivityWindowPrediction] {
        var out: [ActivityWindowPrediction] = []
        var t = from
        while t + 4 <= to {
            out.append(window(label, from: t, prob: prob))
            t += 2
        }
        return out
    }

    /// Abstaining windows (model says unknown) over `[from, to)`.
    private func abstainRun(from: Int, to: Int) -> [ActivityWindowPrediction] {
        var out: [ActivityWindowPrediction] = []
        var t = from
        while t + 4 <= to {
            out.append(ActivityWindowPrediction(startTs: t, endTs: t + 4, label: .unknown,
                                                probs: ["unknown": 0.99, "walking": 0.01]))
            t += 2
        }
        return out
    }

    private func build(_ windows: [ActivityWindowPrediction], runStart: Int? = nil, runEnd: Int? = nil,
                       exerciseSessions: [ExerciseSession] = [],
                       sleepSessions: [SleepSession] = [],
                       postureAnnotations: [PostureAnnotation] = [],
                       wearIntervals: [WearInterval] = [],
                       config: ActivityPolicyConfig = .default) -> ActivityEpochBuild {
        ActivityContextPolicy.buildEpochs(windows: windows,
                                          runStart: runStart ?? base - 60,
                                          runEnd: runEnd ?? base + 60 * 30,
                                          exerciseSessions: exerciseSessions,
                                          sleepSessions: sleepSessions,
                                          postureAnnotations: postureAnnotations,
                                          wearIntervals: wearIntervals,
                                          config: config)
    }

    // MARK: - Grid

    func testBuildsEpochsOnUtc30SecondGrid() {
        let build = self.build(run(.walking, from: base, to: base + 60), runStart: base, runEnd: base + 60)
        XCTAssertEqual(build.epochs.count, 2)
        XCTAssertEqual(build.epochs[0].startTs, base)
        XCTAssertEqual(build.epochs[0].endTs, base + 30)
        XCTAssertEqual(build.epochs[1].startTs, base + 30)
        XCTAssertEqual(build.epochs[1].endTs, base + 60)
        for e in build.epochs {
            XCTAssertEqual(e.startTs % 30, 0)
            XCTAssertEqual(e.motion, .walking)
            XCTAssertEqual(e.observedS, 30)
            XCTAssertEqual(e.validS, 30)
            XCTAssertEqual(e.confidence, 0.95, accuracy: 1e-9)
            XCTAssertEqual(e.posture, .unknown)
            XCTAssertEqual(e.exercise, .unknown)
            XCTAssertEqual(e.sleepState, .unknown)
            XCTAssertEqual(e.wear, .unknown)
            XCTAssertEqual(e.exertion, .active)
        }
        XCTAssertTrue(build.transitions.isEmpty)
    }

    func testPartialEpochsAtRunEdges() {
        // Run starts 7 s into an epoch and ends 7 s into the last epoch.
        let build = self.build(run(.walking, from: base + 7, to: base + 67), runStart: base + 7, runEnd: base + 67)
        XCTAssertEqual(build.epochs.count, 3)
        XCTAssertEqual(build.epochs[0].startTs, base)
        XCTAssertEqual(build.epochs[0].observedS, 23)
        XCTAssertEqual(build.epochs[1].observedS, 30)
        XCTAssertEqual(build.epochs[1].validS, 30)
        XCTAssertEqual(build.epochs[2].startTs, base + 60)
        XCTAssertEqual(build.epochs[2].observedS, 7)
        XCTAssertEqual(build.epochs[2].validS, 7)
        for e in build.epochs { XCTAssertEqual(e.motion, .walking) }
    }

    func testWindowsOutsideRunAreDropped() {
        let ws = run(.walking, from: base, to: base + 60) + run(.running, from: base + 120, to: base + 150)
        let build = self.build(ws, runStart: base, runEnd: base + 60)
        XCTAssertEqual(build.epochs.count, 2)
        XCTAssertTrue(build.epochs.allSatisfy { $0.motion == .walking })
    }

    // MARK: - Causal vote / hysteresis

    func testSingleDisagreeingWindowDoesNotFlip() {
        // Walking, then ONE stationary window, then walking again — a flicker that must not flip.
        var ws = run(.walking, from: base, to: base + 30)
        ws.append(window(.stationary, from: base + 30))
        ws.append(contentsOf: run(.walking, from: base + 32, to: base + 60))
        let build = self.build(ws, runStart: base, runEnd: base + 60)
        XCTAssertTrue(build.transitions.isEmpty, "a single disagreeing vote must not flip the label")
        XCTAssertTrue(build.epochs.allSatisfy { $0.motion == .walking })
    }

    func testTwoConsecutiveDisagreeingVotesFlipAndRecordOffset() {
        var ws = run(.walking, from: base, to: base + 30)
        ws.append(window(.stationary, from: base + 30))
        ws.append(window(.stationary, from: base + 32))
        ws.append(contentsOf: run(.walking, from: base + 34, to: base + 60))
        let build = self.build(ws, runStart: base, runEnd: base + 60)
        // The two stationary windows flip the label, and the following two walking windows flip it
        // back — both causal flips are recorded with their offsets.
        XCTAssertEqual(build.transitions, [
            ActivityTransition(from: .walking, to: .stationary, offset: base + 30),
            ActivityTransition(from: .stationary, to: .walking, offset: base + 34),
        ])
        // The 2-window blip is absorbed by the epoch majority; the causal transition record keeps it.
        XCTAssertTrue(build.epochs.allSatisfy { $0.motion == .walking })
    }

    func testLongDisagreeingRunFlipsEpochLabel() {
        let ws = run(.walking, from: base, to: base + 30) + run(.stationary, from: base + 30, to: base + 60)
        let build = self.build(ws, runStart: base, runEnd: base + 60)
        XCTAssertEqual(build.epochs.count, 2)
        XCTAssertEqual(build.epochs[0].motion, .walking)
        XCTAssertEqual(build.epochs[1].motion, .stationary)
        XCTAssertEqual(build.transitions, [ActivityTransition(from: .walking, to: .stationary, offset: base + 30)])
    }

    func testResetHistoryAtGap() {
        // Walking, gap, ONE stationary window, then walking again. The gap resets hysteresis state,
        // so the lone stationary window after the gap establishes itself immediately and the
        // subsequent walking needs two votes to flip back.
        var ws = run(.walking, from: base, to: base + 30)
        ws.append(window(.stationary, from: base + 100))
        ws.append(contentsOf: run(.walking, from: base + 102, to: base + 130))
        let build = self.build(ws, runStart: base, runEnd: base + 130)
        XCTAssertEqual(build.transitions,
                       [ActivityTransition(from: .stationary, to: .walking, offset: base + 102)],
                       "the gap must clear the pre-gap label so the stationary window establishes")
        // The grid never bridges the gap: no epoch starts inside (base+30, base+90).
        for e in build.epochs {
            XCTAssertFalse(e.startTs > base + 30 && e.startTs < base + 90, "gap must stay explicit")
        }
        XCTAssertEqual(build.epochs.count, 3)
    }

    // MARK: - Abstention

    func testUnknownWindowsAbstainNeverStationary() {
        let build = self.build(abstainRun(from: base, to: base + 60), runStart: base, runEnd: base + 60)
        XCTAssertEqual(build.epochs.count, 2)
        for e in build.epochs {
            XCTAssertEqual(e.motion, .unknown, "abstaining windows must never become stationary")
            XCTAssertEqual(e.validS, 0)
            XCTAssertEqual(e.observedS, 30)
            XCTAssertEqual(e.confidence, 0)
            XCTAssertEqual(e.unknownFraction, 1.0)
        }
        // Negative control: an entirely-unknown run must not be scored as stationary anywhere.
        let status = ActivityContextPolicy.snapshotStatus(epochs: build.epochs)
        XCTAssertEqual(status.0, .partial)
        XCTAssertTrue(status.1.contains("high_unknown_share"))
    }

    func testLowConfidenceWindowAbstains() {
        // Confidence below the 0.80 floor, or a razor-thin top-2 margin, both abstain.
        let lowConf = ActivityWindowPrediction(startTs: base, endTs: base + 4, label: .walking,
                                               probs: ["walking": 0.70, "stationary": 0.30])
        XCTAssertFalse(ActivityContextPolicy.isAccepted(lowConf))
        let thinMargin = ActivityWindowPrediction(startTs: base, endTs: base + 4, label: .walking,
                                                  probs: ["walking": 0.82, "stationary": 0.70])
        XCTAssertFalse(ActivityContextPolicy.isAccepted(thinMargin))
        let ok = ActivityWindowPrediction(startTs: base, endTs: base + 4, label: .walking,
                                          probs: ["walking": 0.90, "stationary": 0.10])
        XCTAssertTrue(ActivityContextPolicy.isAccepted(ok))
        // No probabilities at all (malformed window) abstains.
        XCTAssertFalse(ActivityContextPolicy.isAccepted(
            ActivityWindowPrediction(startTs: base, endTs: base + 4, label: .walking, probs: [:])))

        // A run of thin-margin windows yields an unknown epoch with full observed coverage.
        var ws: [ActivityWindowPrediction] = []
        var t = base
        while t + 4 <= base + 30 {
            ws.append(ActivityWindowPrediction(startTs: t, endTs: t + 4, label: .walking,
                                               probs: ["walking": 0.82, "stationary": 0.70]))
            t += 2
        }
        let build = self.build(ws, runStart: base, runEnd: base + 30)
        XCTAssertEqual(build.epochs.count, 1)
        XCTAssertEqual(build.epochs[0].motion, .unknown)
        XCTAssertEqual(build.epochs[0].observedS, 30)
        XCTAssertEqual(build.epochs[0].validS, 0)
    }

    func testPartialAbstentionCreatesUnknownShareNotLabelShare() {
        // 20 s accepted stationary, then 10 s of unknown windows in the same epoch.
        let ws = run(.stationary, from: base, to: base + 20) + abstainRun(from: base + 20, to: base + 30)
        let build = self.build(ws, runStart: base, runEnd: base + 30)
        XCTAssertEqual(build.epochs.count, 1)
        let e = build.epochs[0]
        XCTAssertEqual(e.motion, .stationary)
        XCTAssertEqual(e.observedS, 30)
        XCTAssertEqual(e.validS, 20)
        XCTAssertEqual(e.unknownFraction, 1.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - Exercise / sleep / wear / posture enrichment

    func testExerciseTriStateFromWorkoutRecords() {
        let session = ExerciseSession(start: base + 60, end: base + 120, avgHR: 120, peakHR: 150,
                                      strain: 8, durationS: 60, zoneTimePct: [:],
                                      avgHRRPct: 0.5, hrmax: 180, hrmaxSource: "observed",
                                      caloriesKcal: 10, caloriesKJ: 40)
        let build = self.build(run(.stationary, from: base, to: base + 120),
                               runStart: base, runEnd: base + 120, exerciseSessions: [session])
        XCTAssertEqual(build.epochs.count, 4)
        XCTAssertEqual(build.epochs[0].exercise, .unknown)
        XCTAssertEqual(build.epochs[1].exercise, .unknown)
        XCTAssertEqual(build.epochs[2].exercise, .true, "overlap with a workout record is true")
        XCTAssertEqual(build.epochs[3].exercise, .true)
        XCTAssertFalse(build.epochs.contains { $0.exercise == .false },
                       "absence of a workout record is never 'false'")
    }

    func testSleepStateFromSleepSessionsWithWakeSegments() {
        let session = SleepSession(start: base + 60, end: base + 120, efficiency: 0.8,
                                   stages: [StageSegment(start: base + 60, end: base + 90, stage: "light"),
                                            StageSegment(start: base + 90, end: base + 120, stage: "wake")],
                                   restingHR: nil, avgHRV: nil)
        let build = self.build(run(.stationary, from: base, to: base + 120),
                               runStart: base, runEnd: base + 120, sleepSessions: [session])
        XCTAssertEqual(build.epochs.count, 4)
        XCTAssertEqual(build.epochs[0].sleepState, .unknown)
        XCTAssertEqual(build.epochs[1].sleepState, .unknown)
        XCTAssertEqual(build.epochs[2].sleepState, .asleep, "non-wake stages of the session are asleep")
        XCTAssertEqual(build.epochs[3].sleepState, .awake, "wake segments are awake")
    }

    func testWearNeverInferredFromStillness() {
        // No wear evidence: everything unknown — quiet IMU never proves on-wrist (C2 guardrail).
        let build = self.build(run(.stationary, from: base, to: base + 60), runStart: base, runEnd: base + 60)
        XCTAssertTrue(build.epochs.allSatisfy { $0.wear == .unknown })

        let on = self.build(run(.stationary, from: base, to: base + 60), runStart: base, runEnd: base + 60,
                            wearIntervals: [WearInterval(start: base - 60, end: base + 60, wear: .onWrist)])
        XCTAssertTrue(on.epochs.allSatisfy { $0.wear == .onWrist })

        let off = self.build(run(.stationary, from: base, to: base + 60), runStart: base, runEnd: base + 60,
                             wearIntervals: [WearInterval(start: base - 60, end: base + 60, wear: .offWrist)])
        XCTAssertTrue(off.epochs.allSatisfy { $0.wear == .offWrist })
    }

    func testPostureOnlyFromUserConfirmedAnnotations() {
        // No annotation: posture stays unknown (automatic posture is not validated in v1).
        let plain = self.build(run(.walking, from: base, to: base + 60), runStart: base, runEnd: base + 60)
        XCTAssertTrue(plain.epochs.allSatisfy { $0.posture == .unknown })

        let annotated = self.build(run(.walking, from: base, to: base + 120), runStart: base, runEnd: base + 120,
                                   postureAnnotations: [PostureAnnotation(start: base + 30, end: base + 90,
                                                                          posture: .sitting)])
        XCTAssertEqual(annotated.epochs[0].posture, .unknown)
        XCTAssertEqual(annotated.epochs[1].posture, .sitting)
        XCTAssertEqual(annotated.epochs[2].posture, .sitting)
        XCTAssertEqual(annotated.epochs[3].posture, .unknown)
    }

    // MARK: - Exertion

    func testExertionActivePostActivityRestingCandidate() {
        // 60 s walking then 11 minutes stationary: 10 min post-activity, then resting_candidate.
        let ws = run(.walking, from: base, to: base + 60) + run(.stationary, from: base + 60, to: base + 720)
        let build = self.build(ws, runStart: base, runEnd: base + 720)
        XCTAssertEqual(build.epochs.count, 24)
        XCTAssertEqual(build.epochs[0].exertion, .active)
        XCTAssertEqual(build.epochs[1].exertion, .active)

        // Epochs whose start is within 600 s after the walking ended are post_activity.
        for e in build.epochs where e.startTs >= base + 60 && e.startTs < base + 660 {
            XCTAssertEqual(e.exertion, .postActivity, "epoch at \(e.startTs - base) should be post_activity")
        }
        // Sustained stillness (>= 300 s) then makes stationary epochs resting_candidate.
        XCTAssertEqual(build.epochs.last!.motion, .stationary)
        XCTAssertEqual(build.epochs.last!.exertion, .restingCandidate)

        // Elapsed post-activity seconds are retained (first post epoch is right after the walk).
        let firstPost = build.epochs.first { $0.exertion == .postActivity }!
        XCTAssertEqual(ActivityContextPolicy.postActivityElapsedS(for: firstPost, epochs: build.epochs), 0)
        let latePost = build.epochs.first { $0.startTs == base + 600 }!
        XCTAssertEqual(ActivityContextPolicy.postActivityElapsedS(for: latePost, epochs: build.epochs), 540)
        XCTAssertNil(ActivityContextPolicy.postActivityElapsedS(for: build.epochs.last!, epochs: build.epochs))
    }

    func testExertionNeverClearedByHR() {
        // The policy API has NO HR input at all, so post_activity is structurally immune to HR.
        // Pin that shape: a post_activity epoch stays post_activity for the full configurable window.
        let ws = run(.walking, from: base, to: base + 30) + run(.stationary, from: base + 30, to: base + 630)
        let build = self.build(ws, runStart: base, runEnd: base + 630)
        let post = build.epochs.filter { $0.exertion == .postActivity }
        XCTAssertEqual(post.count, 20, "600 s of post window / 30-s epochs")
    }

    func testExertionMixedWhenActiveAndSustainedStill() {
        // 300 s stationary before, then 10 s still + 20 s walking inside the boundary epoch: both
        // sides present AND the stillness is sustained -> mixed.
        var ws = run(.stationary, from: base - 300, to: base + 10)
        ws.append(contentsOf: run(.walking, from: base + 10, to: base + 30))
        let build = self.build(ws, runStart: base - 300, runEnd: base + 30)
        let boundary = build.epochs.first { $0.startTs == base }!
        XCTAssertEqual(boundary.motion, .walking, "walking wins the epoch majority")
        XCTAssertEqual(boundary.exertion, .mixed, "both active and sustained-still seconds in one epoch")
    }

    func testRestingCandidateNeverForOtherMovementOrUnknown() {
        // other_movement and unknown epochs must never become resting_candidate.
        let ws = run(.otherMovement, from: base, to: base + 360)
        let build = self.build(ws, runStart: base, runEnd: base + 360)
        XCTAssertTrue(build.epochs.allSatisfy { $0.exertion != .restingCandidate })
        XCTAssertTrue(build.epochs.allSatisfy { $0.exertion == .active || $0.exertion == .unknown })
    }

    // MARK: - Day summary / status / coalescing

    func testDaySummaryAndSnapshotStatus() {
        let full = self.build(run(.walking, from: base, to: base + 300), runStart: base, runEnd: base + 300)
        let summary = ActivityContextPolicy.daySummary(epochs: full.epochs)
        XCTAssertEqual(summary.supportedS, 300)
        XCTAssertEqual(summary.unknownShare, 0)
        XCTAssertEqual(summary.transitions, 0)
        let status = ActivityContextPolicy.snapshotStatus(epochs: full.epochs)
        XCTAssertEqual(status.0, .available)
        XCTAssertTrue(status.1.isEmpty)

        let halfUnknown = self.build(run(.stationary, from: base, to: base + 60)
                                     + abstainRun(from: base + 60, to: base + 120),
                                     runStart: base, runEnd: base + 120)
        let s2 = ActivityContextPolicy.daySummary(epochs: halfUnknown.epochs)
        XCTAssertEqual(s2.supportedS, 60)
        XCTAssertEqual(s2.unknownShare, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ActivityContextPolicy.snapshotStatus(epochs: halfUnknown.epochs).0, .partial)

        XCTAssertEqual(ActivityContextPolicy.snapshotStatus(epochs: []).0, .noData)
        XCTAssertEqual(ActivityContextPolicy.snapshotStatus(epochs: []).1, ["no_epochs"])
    }

    func testNoEpochsIsNoDataNeverStationary() {
        let build = self.build([])
        XCTAssertTrue(build.epochs.isEmpty)
        let status = ActivityContextPolicy.snapshotStatus(epochs: [])
        XCTAssertEqual(status.0, .noData)
        let summary = ActivityContextPolicy.daySummary(epochs: [])
        XCTAssertEqual(summary.supportedS, 0)
        XCTAssertEqual(summary.unknownShare, 1.0)
        XCTAssertEqual(summary.transitions, 0)
    }

    func testCoalescingMergesEquivalentAdjacentEpochsAndKeepsGaps() {
        let ws = run(.walking, from: base, to: base + 60)
            + run(.stationary, from: base + 60, to: base + 150)
            + run(.walking, from: base + 150, to: base + 180)
        let build = self.build(ws, runStart: base, runEnd: base + 180)
        XCTAssertEqual(build.epochs.count, 6)
        let coalesced = ActivityContextPolicy.coalescedEpochs(build.epochs)
        XCTAssertEqual(coalesced.count, 3)
        XCTAssertEqual(coalesced[0].startTs, base)
        XCTAssertEqual(coalesced[0].endTs, base + 60)
        XCTAssertEqual(coalesced[0].motion, .walking)
        XCTAssertEqual(coalesced[0].observedS, 60)
        XCTAssertEqual(coalesced[0].validS, 60)
        XCTAssertEqual(coalesced[1].startTs, base + 60)
        XCTAssertEqual(coalesced[1].endTs, base + 150)
        XCTAssertEqual(coalesced[1].motion, .stationary)
        XCTAssertEqual(coalesced[2].startTs, base + 150)
        XCTAssertEqual(coalesced[2].motion, .walking)

        // A gap must NOT be bridged by coalescing.
        let gapped = self.build(run(.walking, from: base, to: base + 30)
                                + run(.walking, from: base + 60, to: base + 90),
                                runStart: base, runEnd: base + 90)
        XCTAssertEqual(gapped.epochs.count, 2)
        let cg = ActivityContextPolicy.coalescedEpochs(gapped.epochs)
        XCTAssertEqual(cg.count, 2, "non-adjacent epochs never merge")
        XCTAssertEqual(cg[0].endTs, base + 30)
        XCTAssertEqual(cg[1].startTs, base + 60)
    }

    func testConfidenceIsDurationWeightedMeanMaxProb() {
        // Uniform confidence is exact.
        let uniform = self.build(run(.walking, from: base, to: base + 30, prob: 0.90),
                                 runStart: base, runEnd: base + 30)
        XCTAssertEqual(uniform.epochs[0].confidence, 0.90, accuracy: 1e-9)

        // Mixed probabilities yield the duration-weighted mean (each window weighted by its
        // overlap seconds with the epoch, so boundary seconds are counted once).
        var ws: [ActivityWindowPrediction] = []
        var t = base
        while t + 4 <= base + 30 {
            let prob = ((t - base) / 4) % 2 == 0 ? 0.90 : 0.99
            ws.append(window(.walking, from: t, prob: prob))
            t += 2
        }
        let build = self.build(ws, runStart: base, runEnd: base + 30)
        XCTAssertGreaterThan(build.epochs[0].confidence, 0.90)
        XCTAssertLessThan(build.epochs[0].confidence, 0.99)
    }

    // MARK: - Spec §12 negative controls

    /// Negative controls from spec §12: seated gesturing, standing typing, quiet standing,
    /// motionless cycling, driving/passive vibration, stairs, lying awake, tremor-like shaking,
    /// slow/shuffling gait, walker use, treadmill handrail. The policy must never invent posture
    /// (no user confirmation), must not claim sleep, and must not infer wear — and a wrist-still
    /// label is stationary, never anything stronger.
    func testNegativeControlsNeverInventPostureSleepOrWear() {
        let cases: [(String, MotionLabel)] = [
            ("seated gesturing", .stationary),
            ("standing typing", .stationary),
            ("quiet standing", .stationary),
            ("motionless cycling", .stationary),
            ("lying awake", .stationary),
            ("treadmill handrail support", .stationary),
            ("walking", .walking),                  // normal supported gait stays supported
            ("slow/shuffling gait", .walking),
            ("stairs", .otherMovement),
            ("driving / passive vibration", .otherMovement),
            ("tremor-like wrist shaking", .otherMovement),
            ("walker use", .stationary),
        ]
        for (name, label) in cases {
            let build = self.build(run(label, from: base, to: base + 60), runStart: base, runEnd: base + 60)
            XCTAssertEqual(build.epochs.count, 2, name)
            for e in build.epochs {
                XCTAssertEqual(e.motion, label, name)
                XCTAssertEqual(e.posture, .unknown, "\(name): posture must never be invented")
                XCTAssertEqual(e.sleepState, .unknown, "\(name): stillness must never claim sleep")
                XCTAssertEqual(e.wear, .unknown, "\(name): quiet IMU must never claim on-wrist")
            }
        }
    }

    func testOffWristStillnessDoesNotBecomeOnWristOrSleep() {
        // A wrist lying still while off the body is stationary motion — never sleep, never on-wrist.
        let build = self.build(run(.stationary, from: base, to: base + 600),
                               runStart: base, runEnd: base + 600,
                               wearIntervals: [WearInterval(start: base, end: base + 600, wear: .offWrist)])
        for e in build.epochs {
            XCTAssertEqual(e.wear, .offWrist)
            XCTAssertEqual(e.sleepState, .unknown)
        }
    }

    // MARK: - WS-05-F11 regression: second-accurate active/still accounting

    /// The 4-s / 2-s-hop window grid covers each interior second twice. activeS/stillS must count
    /// each REAL second once, so minStillnessS / mixed thresholds measure real time, not
    /// window-covered time (previously ~1.93x, firing minStillnessS=300 at ~150-180 real seconds).
    func testStillnessThresholdMeasuresRealSecondsNotWindowCovered() {
        // 210 real seconds of stationary windows: the 7th epoch has 180 prior real still seconds.
        // Under the old double-count it had ~356 window-covered seconds and wrongly became
        // resting_candidate; second-accurate accounting must NOT fire before 300 real seconds.
        let short = self.build(run(.stationary, from: base, to: base + 210), runStart: base, runEnd: base + 210)
        XCTAssertEqual(short.epochs.count, 7)
        XCTAssertTrue(short.epochs.allSatisfy { $0.exertion != .restingCandidate },
                      "180 real still seconds must not satisfy minStillnessS=300")

        // The finding's literal example: 150 real seconds never fires.
        let at150 = self.build(run(.stationary, from: base, to: base + 150), runStart: base, runEnd: base + 150)
        XCTAssertTrue(at150.epochs.allSatisfy { $0.exertion != .restingCandidate })

        // 330 real seconds: the epoch after 300 real still seconds becomes resting_candidate.
        let long = self.build(run(.stationary, from: base, to: base + 330), runStart: base, runEnd: base + 330)
        XCTAssertEqual(long.epochs.count, 11)
        XCTAssertTrue(long.epochs[0..<10].allSatisfy { $0.exertion != .restingCandidate },
                      "no resting_candidate before 300 real still seconds")
        XCTAssertEqual(long.epochs[10].exertion, .restingCandidate,
                       "300 real still seconds satisfy minStillnessS=300")
    }

    /// `mixed` requires minMixedActiveS/minMixedStillS (10) REAL seconds on both sides. Six real
    /// stationary seconds in the boundary epoch must not fire mixed (the old double-count gave ~11
    /// window-covered still seconds and fired early); exactly 10 real seconds must.
    func testMixedThresholdsMeasureRealSeconds() {
        // Prior 300 s stillness, then 6 real stationary seconds + walking in the boundary epoch.
        var below = run(.stationary, from: base - 300, to: base + 6)
        below.append(contentsOf: run(.walking, from: base + 6, to: base + 30))
        let belowBuild = self.build(below, runStart: base - 300, runEnd: base + 30)
        let boundaryBelow = belowBuild.epochs.first { $0.startTs == base }!
        XCTAssertEqual(boundaryBelow.motion, .walking)
        XCTAssertNotEqual(boundaryBelow.exertion, .mixed,
                          "6 real still seconds < minMixedStillS=10 must not be mixed")

        // 10 real stationary seconds + walking: exactly the thresholds -> mixed.
        var at = run(.stationary, from: base - 300, to: base + 10)
        at.append(contentsOf: run(.walking, from: base + 10, to: base + 30))
        let atBuild = self.build(at, runStart: base - 300, runEnd: base + 30)
        let boundaryAt = atBuild.epochs.first { $0.startTs == base }!
        XCTAssertEqual(boundaryAt.motion, .walking)
        XCTAssertEqual(boundaryAt.exertion, .mixed,
                       "10 real still + 20 real active seconds with sustained stillness is mixed")
    }
}
