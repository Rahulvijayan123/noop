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
        XCTAssertEqual(s.recentActivity, 10, "40 - (end of last walking epoch = base+30)")
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
        XCTAssertEqual(slot.recentActivityS, 900, "last supported epoch ends at slot start")
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
                                       "status", "reasons", "epochs", "summary", "contexts"])
        XCTAssertEqual(obj["schema_version"] as? Int, 1)
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
